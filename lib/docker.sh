# shellcheck shell=bash
# Guardas de entorno, arranque de compose y verificacion REAL del contenedor.
[ -n "${_DOCKER_SH:-}" ] && return 0
_DOCKER_SH=1

docker_require() {
	command -v docker >/dev/null 2>&1 \
		|| die "$EX_ENV" "Docker no esta instalado. Instalalo con: curl -fsSL https://get.docker.com | sh"
	docker compose version >/dev/null 2>&1 \
		|| die "$EX_ENV" "falta el plugin 'docker compose' (v2)"
	docker info >/dev/null 2>&1 \
		|| die "$EX_ENV" "el daemon de Docker no responde (revisa permisos del socket, o 'systemctl start docker')"
}

docker_require_network() {
	docker network inspect "$1" >/dev/null 2>&1 && return 0
	# En un ensayo no se aborta por una precondicion de infraestructura: en una maquina de
	# desarrollo esa red no existe nunca, y abortar aqui dejaria el dry-run sin recorrer el
	# resto del camino, que es justo para lo que sirve.
	if [ "${DRY_RUN:-0}" = "1" ]; then
		warn "la red externa '$1' no existe (en un despliegue real esto abortaria)"
		return 0
	fi
	die "$EX_ENV" "la red externa '$1' no existe. Ejecuta primero: ./deploy.sh infra"
}

# `config -q` valida la sintaxis del compose Y que existan los env_file que referencia, antes
# de lanzar un build que puede durar minutos.
compose_validate() {
	local compose="$1" out
	[ "${DRY_RUN:-0}" = "1" ] && return 0
	if ! out="$(docker compose -f "$compose" config -q 2>&1)"; then
		printf '%s\n' "$out" | sed 's/^/    /' >&2
		die "$EX_BUILD" "el compose $compose no es valido"
	fi
}

compose_up() {
	local compose="$1"
	local args=(-f "$compose" up -d --force-recreate)
	[ "${NO_BUILD:-0}" = "1" ] || args+=(--build)
	run_logged docker compose "${args[@]}" \
		|| die "$EX_BUILD" "'docker compose up' fallo para $compose"
}

# Sustituye a `docker ps ... | grep -E "NAMES|<contenedor>"`, que era un no-op: el patron
# siempre casaba con la cabecera NAMES de la tabla, asi que grep jamas devolvia 1 y un
# contenedor en 'Restarting (1)' se reportaba como despliegue correcto.
# Docker Desktop en Windows termina las lineas con CRLF: sin limpiarlo, un `case "$status" in
# running)` no casaria nunca con "running\r". En Linux no cambia nada.
# El `|| true` es necesario, no decorativo: con `pipefail`, si el contenedor no existe el
# pipeline falla y dispara el trap ERR, ensuciando la salida con un error ya contemplado.
# Quien llama distingue el fallo por la cadena vacia.
_inspect() {                                    # $1=formato  $2=contenedor
	docker inspect -f "$1" "$2" 2>/dev/null | tr -d '[:space:]' || true
}

verify_container() {                            # $1=nombre  $2=presupuesto en segundos
	local name="$1" budget="${2:-60}"
	local waited=0 status health started first_started=""

	if [ "${DRY_RUN:-0}" = "1" ]; then log "DRY-RUN  verificar $name"; return 0; fi

	while :; do
		status="$(_inspect '{{.State.Status}}' "$name")"
		if [ -z "$status" ]; then
			die "$EX_VERIFY" "el contenedor '$name' no existe tras el despliegue (revisa TIER_*_CONTAINER en el registro)"
		fi
		health="$(_inspect '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name")"
		health="${health:-none}"
		started="$(_inspect '{{.State.StartedAt}}' "$name")"
		[ -n "$first_started" ] || first_started="$started"

		case "$status" in
			exited|dead)
				_verify_fail "$name" "el contenedor termino en estado '$status'"
				;;
			restarting)
				: ;;                            # dentro del presupuesto aun puede recuperarse
			running)
				case "$health" in
					healthy)
						ok "$name: running / healthy"
						return 0
						;;
					unhealthy)
						_verify_fail "$name" "el healthcheck reporta 'unhealthy'"
						;;
					starting)
						: ;;
					none)
						# Sin HEALTHCHECK no hay senal de aplicacion. Lo unico observable es que
						# lleve un rato corriendo SIN reiniciarse: si StartedAt cambia dentro de
						# la ventana, es un crash-loop, aunque `docker ps` lo muestre como "Up".
						if [ "$waited" -ge "${STABLE_WINDOW:-15}" ]; then
							if [ "$started" = "$first_started" ]; then
								ok "$name: running y estable ${waited}s (no declara healthcheck)"
								return 0
							fi
							_verify_fail "$name" "reinicio durante la ventana de observacion: crash-loop"
						fi
						;;
				esac
				;;
		esac

		if [ "$waited" -ge "$budget" ]; then
			_verify_fail "$name" "no alcanzo un estado sano en ${budget}s (status=$status health=$health)"
		fi
		sleep 3
		waited=$((waited + 3))
	done
}

_verify_fail() {
	local name="$1" reason="$2" restarts
	# RestartCount cuelga de la RAIZ del objeto de inspeccion, no de .State (a diferencia de
	# Status, Health y StartedAt). Con '{{.State.RestartCount}}' el campo sale siempre vacio.
	restarts="$(_inspect '{{.RestartCount}}' "$name")"
	restarts="${restarts:-?}"
	warn "$name: $reason (RestartCount=$restarts)"
	warn "ultimas 40 lineas de log de $name:"
	docker logs --tail 40 "$name" 2>&1 | sed 's/^/    /' >&2 || true
	die "$EX_VERIFY" "verificacion de '$name' fallida"
}
