# shellcheck shell=bash
# Utilidades compartidas: codigos de salida, registro, ejecucion, lock y traps.
[ -n "${_COMMON_SH:-}" ] && return 0
_COMMON_SH=1

# --- Codigos de salida, uno por clase de fallo --------------------------------------------
# Existen para que quien invoque deploy.sh (la skill de Claude, un cron, una persona) sepa
# QUE fallo sin tener que interpretar el texto. Los scripts antiguos solo usaban 0 y 1.
readonly EX_OK=0
readonly EX_USAGE=2       # argumentos, app o tier inexistente
readonly EX_ENV=10        # falta docker / plugin compose / red externa / bash < 4.2
readonly EX_REGISTRY=11   # .conf incompleto o incoherente con el disco
readonly EX_GIT=12        # clone/fetch fallo, arbol sucio, rama distinta, divergencia
readonly EX_ENVFILE=13    # env_file requerido ausente
readonly EX_DB=14         # postgres inalcanzable, CREATE DATABASE o bootstrap fallo
readonly EX_BUILD=15      # docker compose build/up fallo
readonly EX_VERIFY=16     # el contenedor no quedo sano
readonly EX_LOCK=17       # otro despliegue de la misma app en curso

LOG_FILE="${LOG_FILE:-/dev/null}"

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Sin tuberia a `tee`: asi un fallo al escribir el log no aborta el despliegue bajo `set -e`
# ni contamina el estado de salida de la sentencia.
_emit() {
	local line="[$(_ts)] $1"
	printf '%s\n' "$line"
	if [ "$LOG_FILE" != "/dev/null" ]; then
		printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
	fi
}

log()  { _emit "$*"; }
ok()   { _emit "[OK] $*"; }
warn() { _emit "[WARN] $*" >&2; }
die()  { local code="$1"; shift; _emit "[ERROR] $*" >&2; exit "$code"; }

# --- Ejecucion con dry-run ----------------------------------------------------------------
# run() NO admite tuberias ni redirecciones: para eso, proteger con `if [ "$DRY_RUN" = 1 ]`.
run() {
	if [ "${DRY_RUN:-0}" = "1" ]; then _emit "DRY-RUN  $*"; return 0; fi
	_emit "\$ $*"
	"$@"
}

# Igual que run(), pero ademas vuelca la salida del comando al log. `set -o pipefail`
# garantiza que el estado que sale es el del comando, no el de tee.
run_logged() {
	if [ "${DRY_RUN:-0}" = "1" ]; then _emit "DRY-RUN  $*"; return 0; fi
	_emit "\$ $*"
	"$@" 2>&1 | tee -a "$LOG_FILE"
}

# --- Log por invocacion -------------------------------------------------------------------
log_open() {                                    # $1 = etiqueta -> imprime la ruta del log
	if [ "${DRY_RUN:-0}" = "1" ]; then printf '/dev/null\n'; return 0; fi
	mkdir -p "$LOG_DIR"
	local file
	file="$LOG_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-$1.log"
	: >"$file"
	# Rotacion: conservar los 50 mas recientes. Acotado a los .log que creo este script.
	ls -1t "$LOG_DIR"/*.log 2>/dev/null | tail -n +51 | while read -r old; do
		rm -f "$old"
	done
	printf '%s\n' "$file"
}

# --- Lock por app -------------------------------------------------------------------------
# `mkdir` y no `flock`: mkdir es atomico en cualquier POSIX, y flock no existe en msys, lo
# que impediria probar el script fuera del servidor.
LOCK_PATH=""

lock_acquire() {
	# En dos sentencias a proposito: `local a="$1" b="...$a..."` NO funciona bajo `set -u`,
	# porque bash expande todos los argumentos de `local` ANTES de crear las variables, asi
	# que ahi $key todavia no existe.
	local key="$1" owner path
	path="$LOCK_DIR/$key.lock"
	[ "${DRY_RUN:-0}" = "1" ] && return 0
	mkdir -p "$LOCK_DIR"
	while ! mkdir "$path" 2>/dev/null; do
		owner="$(cat "$path/pid" 2>/dev/null || true)"
		if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
			warn "lock huerfano de un proceso muerto (pid $owner): se recupera"
			rm -rf "$path"
			continue
		fi
		if [ "${WAIT_LOCK:-0}" != "1" ]; then
			die "$EX_LOCK" "ya hay un despliegue de '$key' en curso (pid ${owner:-?}). Encola con --wait-lock."
		fi
		log "esperando el lock de '$key' (pid ${owner:-?})..."
		sleep 5
	done
	printf '%s\n' "$$" >"$path/pid"
	LOCK_PATH="$path"
}

lock_release() {
	if [ -n "$LOCK_PATH" ]; then rm -rf "$LOCK_PATH"; LOCK_PATH=""; fi
	return 0
}

# --- Traps --------------------------------------------------------------------------------
# `set -E` en deploy.sh es imprescindible para que el trap ERR se herede dentro de funciones.
_on_err()  { _emit "[ERROR] exit $? en la linea ${BASH_LINENO[0]}: $BASH_COMMAND" >&2; }
_on_exit() { lock_release; }
trap _on_err ERR
trap _on_exit EXIT
