#!/usr/bin/env bash
#
# Configura ESTA maquina para desplegar en el servidor con el comando `deploy`.
#
#   bash client/install.sh --host 5.78.155.68 --key ~/.ssh/id_rsa_codeabien
#
# Hace tres cosas, todas idempotentes (se puede reejecutar sin duplicar nada):
#   1. Anade un `Host froggy` a ~/.ssh/config
#   2. Anade la funcion `deploy` a ~/.bashrc
#   3. En Windows, anade la misma funcion al perfil de PowerShell
#
# Lo que NO hace, porque es un secreto y no puede viajar en un repositorio: darte la clave
# privada. O la copias desde otra maquina, o generas una nueva y anades su .pub al
# ~/.ssh/authorized_keys del servidor. El script te guia si no la encuentra.
set -euo pipefail

ALIAS="froggy"
HOST=""
USERNAME="root"
KEY=""
REMOTE_DIR='~/apps/froggy-deploy'
SKIP_PS=0

BEGIN='# >>> froggy-deploy >>>'
END='# <<< froggy-deploy <<<'

usage() {
	cat <<'EOF'
Uso: bash client/install.sh --host <ip-o-dominio> [opciones]

  --host <ip>       IP o dominio del servidor            (obligatorio)
  --user <usuario>  usuario SSH                          (por defecto: root)
  --key <ruta>      clave privada                        (por defecto: se autodetecta)
  --alias <nombre>  nombre del Host en ~/.ssh/config     (por defecto: froggy)
  --no-powershell   no tocar el perfil de PowerShell
  -h, --help

Ejemplo:
  bash client/install.sh --host 5.78.155.68 --key ~/.ssh/id_rsa_codeabien
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--host)  HOST="${2:-}"; shift ;;
		--user)  USERNAME="${2:-}"; shift ;;
		--key)   KEY="${2:-}"; shift ;;
		--alias) ALIAS="${2:-}"; shift ;;
		--no-powershell) SKIP_PS=1 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: opcion desconocida: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

[ -n "$HOST" ] || { echo "ERROR: falta --host" >&2; usage >&2; exit 2; }

say() { printf '%s\n' "$*"; }
ok()  { printf '[OK] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }

# --- 1. La clave privada -------------------------------------------------------------------
if [ -z "$KEY" ]; then
	for candidate in ~/.ssh/id_ed25519 ~/.ssh/id_rsa ~/.ssh/id_rsa_codeabien; do
		if [ -f "$candidate" ]; then KEY="$candidate"; break; fi
	done
fi

if [ -z "$KEY" ] || [ ! -f "${KEY/#\~/$HOME}" ]; then
	warn "No se encontro una clave privada${KEY:+ en $KEY}."
	say ""
	say "Esta maquina necesita una clave que el servidor acepte. Dos caminos:"
	say ""
	say "  a) Copiar la que ya usas en otra maquina:"
	say "       scp otra-pc:~/.ssh/id_rsa_codeabien ~/.ssh/"
	say "       chmod 600 ~/.ssh/id_rsa_codeabien"
	say ""
	say "  b) Generar una nueva y autorizarla en el servidor:"
	say "       ssh-keygen -t ed25519 -C \"$(whoami)@$(hostname)\" -f ~/.ssh/id_${ALIAS}"
	say "       ssh-copy-id -i ~/.ssh/id_${ALIAS}.pub ${USERNAME}@${HOST}"
	say "     (o pega el contenido de id_${ALIAS}.pub en ~/.ssh/authorized_keys del servidor)"
	say ""
	say "Despues, vuelve a ejecutar este script con --key <ruta-de-la-clave>."
	exit 1
fi

KEY_EXPANDED="${KEY/#\~/$HOME}"
chmod 600 "$KEY_EXPANDED" 2>/dev/null || true
ok "clave privada: $KEY"

# --- 2. ~/.ssh/config ----------------------------------------------------------------------
SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh" 2>/dev/null || true
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG" 2>/dev/null || true

# Se reescribe el bloque entero en vez de anadirlo: asi cambiar la IP es reejecutar el script,
# y no quedan dos `Host froggy` (openssh se queda con el primero, lo que despista muchisimo).
if grep -q "^$BEGIN\$" "$SSH_CONFIG" 2>/dev/null; then
	cp "$SSH_CONFIG" "$SSH_CONFIG.bak"
	sed -i.tmp "/^$BEGIN\$/,/^$END\$/d" "$SSH_CONFIG" && rm -f "$SSH_CONFIG.tmp"
	say "bloque anterior sustituido (copia en $SSH_CONFIG.bak)"
elif grep -qE "^[[:space:]]*Host[[:space:]]+$ALIAS([[:space:]]|\$)" "$SSH_CONFIG" 2>/dev/null; then
	warn "ya existe un 'Host $ALIAS' que este script no gestiona. Revisa $SSH_CONFIG a mano"
	warn "o usa --alias <otro-nombre>. No se toca nada."
	exit 1
fi

cat >>"$SSH_CONFIG" <<EOF
$BEGIN
# Servidor de despliegue. Lo usa la funcion \`deploy\` y la skill de Claude Code.
Host $ALIAS
  HostName $HOST
  User $USERNAME
  IdentityFile $KEY
  ServerAliveInterval 30
$END
EOF
ok "~/.ssh/config: Host $ALIAS -> $USERNAME@$HOST"

# --- 3. La funcion `deploy` en bash --------------------------------------------------------
add_bash_function() {
	local rc="$HOME/.bashrc"
	touch "$rc"
	if grep -q "^$BEGIN\$" "$rc" 2>/dev/null; then
		cp "$rc" "$rc.bak"
		sed -i.tmp "/^$BEGIN\$/,/^$END\$/d" "$rc" && rm -f "$rc.tmp"
	fi
	cat >>"$rc" <<EOF
$BEGIN
# Despliegue en el servidor. Todo el trabajo lo hace deploy.sh alli; esto solo evita
# teclear la linea de ssh entera.  Uso:  deploy glowpe   |   deploy glowpe backend
deploy() {
	if [ \$# -eq 0 ]; then
		echo "Uso: deploy <app> [tier] [opciones]"
		echo "     deploy --list      lista las apps"
		echo "     deploy doctor      diagnostico, sin desplegar"
		return 2
	fi
	ssh $ALIAS "bash $REMOTE_DIR/deploy.sh \$*"
}
$END
EOF
	ok "~/.bashrc: funcion deploy"
}
add_bash_function

# --- 4. La funcion `deploy` en PowerShell (solo Windows) -----------------------------------
add_powershell_function() {
	local docs profile_path
	# En Git Bash, $USERPROFILE apunta al perfil de Windows. Se prueban las dos rutas porque
	# Windows PowerShell 5.1 y PowerShell 7 usan carpetas distintas.
	docs="${USERPROFILE:-$HOME}/Documents"
	for candidate in \
		"$docs/WindowsPowerShell/Microsoft.PowerShell_profile.ps1" \
		"$docs/PowerShell/Microsoft.PowerShell_profile.ps1"; do
		profile_path="$candidate"
		mkdir -p "$(dirname "$profile_path")"
		touch "$profile_path"
		if grep -q "^$BEGIN\$" "$profile_path" 2>/dev/null; then
			cp "$profile_path" "$profile_path.bak"
			sed -i.tmp "/^$BEGIN\$/,/^$END\$/d" "$profile_path" && rm -f "$profile_path.tmp"
		fi
		cat >>"$profile_path" <<EOF
$BEGIN
# Despliegue en el servidor.  Uso:  deploy glowpe   |   deploy glowpe backend
function deploy {
    if (\$args.Count -eq 0) {
        Write-Host "Uso: deploy <app> [tier] [opciones]"
        Write-Host "     deploy --list      lista las apps"
        Write-Host "     deploy doctor      diagnostico, sin desplegar"
        return
    }
    \$remoteArgs = \$args -join ' '
    ssh $ALIAS "bash $REMOTE_DIR/deploy.sh \$remoteArgs"
}
$END
EOF
		ok "PowerShell: $(basename "$(dirname "$profile_path")")/$(basename "$profile_path")"
	done
}

case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*)
		if [ "$SKIP_PS" -eq 1 ]; then
			say "PowerShell omitido (--no-powershell)"
		else
			add_powershell_function
		fi ;;
	*) : ;;                                 # Linux y macOS no tienen perfil de PowerShell
esac

# --- 5. Comprobar que de verdad conecta ----------------------------------------------------
say ""
say "Probando la conexion..."
if ssh -o BatchMode=yes -o ConnectTimeout=15 "$ALIAS" 'echo ok' >/dev/null 2>&1; then
	ok "conexion con $ALIAS establecida"
	say ""
	if ssh -o BatchMode=yes "$ALIAS" "test -f $REMOTE_DIR/deploy.sh" 2>/dev/null; then
		ok "deploy.sh encontrado en el servidor"
		say ""
		say "Listo. Abre una terminal NUEVA y prueba:"
		say "    deploy --list"
		say "    deploy doctor"
	else
		warn "conecta, pero no hay $REMOTE_DIR/deploy.sh en el servidor."
		say "    En el servidor: git clone git@github.com:jimyhdolores/froggy-deploy.git ~/apps/froggy-deploy"
	fi
else
	warn "no se pudo conectar a $USERNAME@$HOST con esa clave."
	say ""
	say "Comprueba a mano y mira el motivo:"
	say "    ssh -v $ALIAS"
	say ""
	say "Lo mas comun es que la clave publica no este autorizada en el servidor:"
	say "    ssh-copy-id -i ${KEY}.pub ${USERNAME}@${HOST}"
	exit 1
fi
