#!/usr/bin/env bash
#
# Comando forzado de la llave SSH del despliegue automatico (GitHub Actions). En authorized_keys:
#
#   restrict,command="/bin/bash /root/apps/froggy-deploy/ci/entry.sh" ssh-ed25519 AAAA... github-actions
#
# Con `command=`, sshd ejecuta ESTO sea cual sea el comando que pida el cliente, y deja lo pedido en
# SSH_ORIGINAL_COMMAND. Asi la llave guardada en GitHub solo sirve para una cosa: desplegar un commit
# ya publicado de una app que admite el despliegue automatico. Lo pedido se valida aqui y se pasa a
# deploy.sh como argumentos, nunca a un shell. `restrict` quita ademas la terminal, el reenvio de
# puertos y el del agente.
#
# Se invoca con /bin/bash y no por su ruta porque git no conserva el bit de ejecucion en este repo
# (core.filemode=false en las maquinas Windows desde las que se edita).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/logs"

read -r app sha extra <<<"${SSH_ORIGINAL_COMMAND:-}" || true
if ! [[ "${app:-}" =~ ^[a-z0-9-]+$ && "${sha:-}" =~ ^[0-9a-f]{40}$ && -z "${extra:-}" ]]; then
	printf 'uso: <app> <sha completo del commit>\n' >&2
	exit 2
fi

mkdir -p "$LOG_DIR"
out="$(mktemp "$LOG_DIR/ci-XXXXXXXX.out")"
rc_file="$out.rc"

# Desacoplado de esta conexion: si el SSH se corta (el job de Actions se cancela, agota su tiempo, o
# la red falla), deploy.sh sigue hasta el final en vez de morir a medias con el contenedor viejo ya
# retirado. Su codigo de salida queda en $rc_file. Sin setsid (Git Bash, al ensayarlo en Windows),
# basta nohup.
detach=(nohup)
command -v setsid >/dev/null 2>&1 && detach=(setsid nohup)
"${detach[@]}" bash -c '"$1" "$2" --auto --sha "$3" --wait-lock >"$4" 2>&1; echo "$?" >"$5"' \
	_ "$ROOT/deploy.sh" "$app" "$sha" "$out" "$rc_file" </dev/null >/dev/null 2>&1 &

# Se sigue la salida mientras no aparezca el codigo. No se espera al proceso por su pid: setsid
# puede bifurcarse, y entonces el pid de $! no es el de deploy.sh.
tail -n +1 -f "$out" &
tail_pid=$!
while [ ! -s "$rc_file" ]; do
	sleep 2
done
sleep 1                                         # que tail escriba las ultimas lineas
kill "$tail_pid" 2>/dev/null || true

# Rotacion, como la de logs/*.log: las 50 salidas mas recientes.
ls -1t "$LOG_DIR"/ci-*.out 2>/dev/null | tail -n +51 | while read -r old; do
	rm -f "$old" "$old.rc"
done

exit "$(cat "$rc_file")"
