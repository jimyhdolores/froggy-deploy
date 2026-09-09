<#
.SYNOPSIS
    Configura ESTA maquina Windows para desplegar en el servidor con el comando `deploy`.

.DESCRIPTION
    Equivalente de client/install.sh para quien no tenga Git Bash. Hace dos cosas, ambas
    idempotentes (se puede reejecutar sin duplicar nada):
      1. Anade un `Host froggy` a ~/.ssh/config
      2. Anade la funcion `deploy` al perfil de PowerShell

    Lo que NO hace, porque es un secreto y no puede viajar en un repositorio: darte la clave
    privada. O la copias desde otra maquina, o generas una nueva y autorizas su .pub en el
    servidor. El script te guia si no la encuentra.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File client\install.ps1 -ServerHost 5.78.155.68 -Key ~\.ssh\id_rsa_codeabien
#>
param(
    [Parameter(Mandatory = $true)][string]$ServerHost,
    [string]$User = 'root',
    [string]$Key = '',
    [string]$Alias = 'froggy',
    [string]$RemoteDir = '~/apps/froggy-deploy'
)

$ErrorActionPreference = 'Stop'
$begin = '# >>> froggy-deploy >>>'
$end = '# <<< froggy-deploy <<<'

function Write-Ok   { param($m) Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }

# Reescribe el bloque delimitado en lugar de anadirlo al final: asi cambiar la IP es
# reejecutar el script, y no quedan dos `Host froggy` (openssh se queda con el primero,
# lo que despista muchisimo).
function Set-Block {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path | Out-Null }

    $lines = @(Get-Content -Path $Path -ErrorAction SilentlyContinue)
    if ($lines -contains $begin) {
        Copy-Item $Path "$Path.bak" -Force
        $kept = @()
        $inside = $false
        foreach ($line in $lines) {
            if ($line -eq $begin) { $inside = $true; continue }
            if ($line -eq $end)   { $inside = $false; continue }
            if (-not $inside)     { $kept += $line }
        }
        $lines = $kept
    }
    $out = $lines + @($begin) + $Content.Split("`n") + @($end)
    # UTF8 sin BOM: un BOM al principio de ~/.ssh/config hace que openssh no lo interprete.
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $out, $enc)
}

# --- 1. La clave privada -------------------------------------------------------------------
if (-not $Key) {
    foreach ($candidate in @("$HOME\.ssh\id_ed25519", "$HOME\.ssh\id_rsa", "$HOME\.ssh\id_rsa_codeabien")) {
        if (Test-Path $candidate) { $Key = $candidate; break }
    }
}
$keyExpanded = $Key -replace '^~', $HOME
if (-not $Key -or -not (Test-Path $keyExpanded)) {
    Write-Warn "No se encontro una clave privada."
    Write-Host ""
    Write-Host "Esta maquina necesita una clave que el servidor acepte. Dos caminos:"
    Write-Host ""
    Write-Host "  a) Copiar la que ya usas en otra maquina, a $HOME\.ssh\"
    Write-Host ""
    Write-Host "  b) Generar una nueva y autorizarla en el servidor:"
    Write-Host "       ssh-keygen -t ed25519 -f `"$HOME\.ssh\id_$Alias`""
    Write-Host "       type `"$HOME\.ssh\id_$Alias.pub`" | ssh $User@$ServerHost `"cat >> ~/.ssh/authorized_keys`""
    Write-Host ""
    Write-Host "Despues, vuelve a ejecutar este script con -Key <ruta>."
    exit 1
}
Write-Ok "clave privada: $Key"

# --- 2. ~/.ssh/config ----------------------------------------------------------------------
# Con la ruta en formato POSIX: openssh en Windows la entiende y evita el infierno de las
# barras invertidas dentro del fichero de configuracion.
$keyForConfig = ($Key -replace '\\', '/') -replace [regex]::Escape(($HOME -replace '\\', '/')), '~'
$sshConfig = Join-Path $HOME '.ssh\config'

$existing = @(Get-Content $sshConfig -ErrorAction SilentlyContinue)
if (($existing -notcontains $begin) -and ($existing -match "^\s*Host\s+$Alias\s*$")) {
    Write-Warn "ya existe un 'Host $Alias' que este script no gestiona. Revisa $sshConfig a mano"
    Write-Warn "o usa -Alias <otro-nombre>. No se toca nada."
    exit 1
}

Set-Block -Path $sshConfig -Content @"
# Servidor de despliegue. Lo usa la funcion ``deploy`` y la skill de Claude Code.
Host $Alias
  HostName $ServerHost
  User $User
  IdentityFile $keyForConfig
  ServerAliveInterval 30
"@
Write-Ok "~/.ssh/config: Host $Alias -> $User@$ServerHost"

# --- 3. La funcion `deploy` en el perfil ---------------------------------------------------
# Se cubren los perfiles de Windows PowerShell 5.1 y de PowerShell 7, que viven en carpetas
# distintas: asi el comando existe en el que el usuario abra.
$profiles = @(
    (Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
)
foreach ($p in $profiles) {
    Set-Block -Path $p -Content @"
# Despliegue en el servidor.  Uso:  deploy glowpe   |   deploy glowpe backend
function deploy {
    if (`$args.Count -eq 0) {
        Write-Host "Uso: deploy <app> [tier] [opciones]"
        Write-Host "     deploy --list      lista las apps"
        Write-Host "     deploy doctor      diagnostico, sin desplegar"
        return
    }
    `$remoteArgs = `$args -join ' '
    ssh $Alias "bash $RemoteDir/deploy.sh `$remoteArgs"
}
"@
    Write-Ok "PowerShell: $p"
}

# --- 4. Comprobar que de verdad conecta ----------------------------------------------------
Write-Host ""
Write-Host "Probando la conexion..."
$null = ssh -o BatchMode=yes -o ConnectTimeout=15 $Alias 'echo ok' 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok "conexion con $Alias establecida"
    $null = ssh -o BatchMode=yes $Alias "test -f $RemoteDir/deploy.sh" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "deploy.sh encontrado en el servidor"
        Write-Host ""
        Write-Host "Listo. Abre una terminal NUEVA y prueba:"
        Write-Host "    deploy --list"
        Write-Host "    deploy doctor"
    } else {
        Write-Warn "conecta, pero no hay $RemoteDir/deploy.sh en el servidor."
        Write-Host "    En el servidor: git clone git@github.com:jimyhdolores/froggy-deploy.git ~/apps/froggy-deploy"
    }
} else {
    Write-Warn "no se pudo conectar a $User@$ServerHost con esa clave."
    Write-Host ""
    Write-Host "Comprueba a mano y mira el motivo:"
    Write-Host "    ssh -v $Alias"
    exit 1
}
