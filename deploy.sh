#!/usr/bin/env bash
#
# froggy-deploy - punto de entrada unico de despliegue.
#
#   ./deploy.sh glowpe            despliega backend y frontend
#   ./deploy.sh glowpe backend    despliega solo ese tier
#   ./deploy.sh --all             infraestructura y todas las apps
#
# Las apps se declaran en apps.d/<slug>.conf. Anadir una app = crear un fichero ahi.
#
# `set -E` es imprescindible: sin el, el trap ERR de lib/common.sh no se hereda dentro de las
# funciones y los fallos se pierden.
set -Eeuo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ] \
	|| { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
	printf 'ERROR: se requiere bash >= 4.2 (compgen -v, expansion indirecta). Actual: %s\n' \
		"$BASH_VERSION" >&2
	exit 10
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_DIR="$SCRIPT_DIR/apps.d"
LOG_DIR="$SCRIPT_DIR/logs"
LOCK_DIR="$SCRIPT_DIR/.locks"
# Configurable a proposito: los scripts antiguos fijaban APPS_DIR="$SCRIPT_DIR/.." sin
# alternativa, lo que hacia imposible probarlos fuera del servidor.
APPS_DIR="${FROGGY_APPS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

for _lib in common registry git docker db infra; do
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/lib/$_lib.sh"
done

usage() {
	cat <<'EOF'
Uso: ./deploy.sh <objetivo> [tier...] [opciones]

Objetivos:
  <app>            despliega TODOS los tiers de la app (ver --list)
  <app> <tier>...  despliega solo esos tiers
  infra            PostgreSQL + Traefik + bases de datos del registro
  traefik          solo Traefik (acme.json + recreate)
  postgres         solo PostgreSQL + bases de datos
  doctor           valida el registro contra el disco, sin tocar nada
  --all            infraestructura y despues todas las apps habilitadas
  --list           lista el registro y sale

Opciones:
  --no-pull          no actualizar el codigo; reconstruir el commit que ya esta en disco
  --no-build         'up -d --force-recreate' sin --build (redespliegue de la misma imagen)
  --branch <rama>    usar esta rama en lugar de APP_BRANCH, solo en esta ejecucion
  --bootstrap-db     ejecutar el SQL de bootstrap aunque la base ya existiera (con salvaguardas)
  --wait-lock        encolarse si hay otro despliegue de la misma app en curso
  --fail-fast        en --all, abortar en el primer fallo (por defecto: continuar y resumir)
  --apps-dir <ruta>  raiz donde viven los repos (por defecto: el padre de este script)
  --dry-run          imprime lo que haria; no clona, no construye, no toca la base
  -h, --help

Ejemplos:
  ./deploy.sh glowpe                 # backend + frontend
  ./deploy.sh glowpe backend         # solo el backend
  ./deploy.sh checkout               # su unico tier: web
  ./deploy.sh --all
  ./deploy.sh tours frontend --no-pull

Codigos de salida: 0 ok - 2 uso - 10 entorno - 11 registro - 12 git
                   13 env_file - 14 base de datos - 15 build - 16 verificacion - 17 lock
EOF
}

# --- parseo -------------------------------------------------------------------------------
DRY_RUN=0; NO_PULL=0; NO_BUILD=0; FORCE_BOOTSTRAP=0
WAIT_LOCK=0; FAIL_FAST=0; BRANCH_OVERRIDE=""; MODE=""; TARGET=""; TIERS=()

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help)      usage; exit 0 ;;
		--list)         MODE=list ;;
		--all)          MODE=all ;;
		--dry-run)      DRY_RUN=1 ;;
		--no-pull)      NO_PULL=1 ;;
		--no-build)     NO_BUILD=1 ;;
		--bootstrap-db) FORCE_BOOTSTRAP=1 ;;
		--wait-lock)    WAIT_LOCK=1 ;;
		--fail-fast)    FAIL_FAST=1 ;;
		--branch)
			BRANCH_OVERRIDE="${2:-}"
			[ -n "$BRANCH_OVERRIDE" ] || die "$EX_USAGE" "--branch requiere un valor"
			shift ;;
		--apps-dir)
			APPS_DIR="${2:-}"
			[ -d "$APPS_DIR" ] || die "$EX_USAGE" "--apps-dir: no existe '${2:-}'"
			shift ;;
		-*)             die "$EX_USAGE" "opcion desconocida: $1 (usa --help)" ;;
		*)
			if [ -z "$TARGET" ]; then TARGET="$1"; else TIERS+=("$1"); fi ;;
	esac
	shift
done
APPS_DIR="$(cd "$APPS_DIR" && pwd)"

# --- despliegue de un tier ----------------------------------------------------------------
deploy_tier() {
	local tier="$1" rel container env_rel wait_s root compose

	rel="$(registry_get "$tier" COMPOSE)"
	container="$(registry_get "$tier" CONTAINER)"
	env_rel="$(registry_get "$tier" ENV_FILE)"
	wait_s="$(registry_get "$tier" WAIT)"; wait_s="${wait_s:-60}"

	root="$APPS_DIR/$APP_DIR"
	compose="$root/$rel"

	log "--- $APP_SLUG/$tier -> $container ---"
	if [ ! -f "$compose" ]; then
		# En un ensayo sobre una app que aun no esta clonada, el compose no puede existir
		# todavia: el clone no llego a ocurrir. Decirlo, en vez de dar un error de registro
		# que parece un fallo de configuracion y no lo es.
		if [ "${DRY_RUN:-0}" = "1" ] && [ ! -d "$root/.git" ]; then
			warn "no se puede comprobar $rel: el repo aun no esta clonado (el despliegue real lo clonaria antes)"
			return 0
		fi
		die "$EX_REGISTRY" "no existe $compose (revisa TIER_${tier}_COMPOSE en $(registry_file "$APP_SLUG"))"
	fi

	if [ -n "$env_rel" ]; then
		[ -f "$root/$env_rel" ] \
			|| die "$EX_ENVFILE" "falta $root/$env_rel. No esta versionado: copialo del gestor de secretos.
    Si la app trae un .env.example, ese es el molde."
	fi

	docker_require_network proxy-network
	if grep -q 'postgres-network' "$compose"; then
		docker_require_network postgres-network
	fi

	compose_validate "$compose"
	compose_up "$compose"
	verify_container "$container" "$wait_s"
	SUMMARY+=("$APP_SLUG/$tier  $container  ${SHA_BEFORE:-nuevo}->${SHA_AFTER}  OK")
}

# --- despliegue de una app ----------------------------------------------------------------
cmd_app() {
	local slug="$1" tier
	local selected=()

	registry_load "$slug"
	LOG_FILE="$(log_open "$slug")"
	lock_acquire "$slug"
	docker_require

	if [ "${#TIERS[@]}" -eq 0 ]; then
		read -r -a selected <<<"$APP_TIERS"     # todos, en el orden que fija el registro
	else
		for tier in "${TIERS[@]}"; do
			registry_has_tier "$tier" \
				|| die "$EX_USAGE" "'$slug' no tiene el tier '$tier'. Tiers validos: $APP_TIERS"
			selected+=("$tier")
		done
	fi

	log "=== $APP_NAME [$slug] :: ${selected[*]} ==="
	log "raiz de repos: $APPS_DIR - log: $LOG_FILE"

	# Orden deliberado: git primero (los compose y el .sql de bootstrap salen del repo), la
	# base despues, y solo entonces los contenedores.
	git_ensure_repo
	db_ensure
	for tier in "${selected[@]}"; do
		deploy_tier "$tier"
	done
}

cmd_list() {
	local slug tier
	printf '\n%-10s  %-22s  %-16s  %-8s  %s\n' SLUG NOMBRE DIRECTORIO RAMA TIERS
	printf '%s\n' "----------------------------------------------------------------------------------"
	for slug in $(registry_slugs); do
		registry_load "$slug"
		printf '%-10s  %-22s  %-16s  %-8s  %s' \
			"$slug" "$APP_NAME" "$APP_DIR" "$APP_BRANCH" "$APP_TIERS"
		[ "$APP_ENABLED" = "1" ] || printf '  (deshabilitada)'
		printf '\n'
		for tier in $APP_TIERS; do
			printf '            %-12s -> %-14s %s\n' \
				"$tier" "$(registry_get "$tier" CONTAINER)" "$(registry_get "$tier" COMPOSE)"
		done
		[ -z "$APP_DB" ] || printf '            base de datos: %s\n' "$APP_DB"
	done
	registry_reset
	printf '\nRaiz de repos: %s\n' "$APPS_DIR"
}

doctor_check_crlf() {
	local file bad=0
	for file in "$SCRIPT_DIR"/deploy.sh "$SCRIPT_DIR"/lib/*.sh "$REGISTRY_DIR"/*.conf; do
		[ -e "$file" ] || continue
		if grep -qU $'\r' "$file" 2>/dev/null; then
			warn "CRLF detectado en $file - corrigelo con: sed -i 's/\\r\$//' '$file'"
			bad=1
		fi
	done
	[ "$bad" -eq 0 ] && ok "todos los ficheros del despliegue estan en LF"
	return 0
}

cmd_doctor() {
	local slug tier compose container declared root
	for slug in $(registry_slugs); do
		registry_load "$slug"                   # ya valida las claves obligatorias
		root="$APPS_DIR/$APP_DIR"
		printf '\n== %s (%s) ==\n' "$slug" "$APP_NAME"
		if [ ! -d "$root/.git" ]; then
			warn "  el repo no esta clonado en $root (deploy.sh lo clonaria)"
			continue
		fi
		for tier in $APP_TIERS; do
			compose="$root/$(registry_get "$tier" COMPOSE)"
			container="$(registry_get "$tier" CONTAINER)"
			if [ -f "$compose" ]; then
				ok "  $tier: compose OK"
				# Deriva registro <-> compose: el container_name declarado tiene que coincidir,
				# o verify_container buscaria un contenedor que nunca va a existir.
				declared="$(grep -E '^[[:space:]]*container_name:' "$compose" | head -1 \
					| sed 's/.*: *//' | tr -d '"'"'"' ')"
				[ "$declared" = "$container" ] \
					|| warn "  $tier: TIER_${tier}_CONTAINER='$container' pero el compose dice '$declared'"
			else
				warn "  $tier: FALTA $compose"
			fi
			declared="$(registry_get "$tier" ENV_FILE)"
			if [ -n "$declared" ]; then
				if [ -f "$root/$declared" ]; then
					ok "  $tier: env_file OK"
				else
					warn "  $tier: FALTA $root/$declared"
				fi
			fi
		done
		if [ -n "$APP_DB_BOOTSTRAP_SQL" ]; then
			if [ -f "$root/$APP_DB_BOOTSTRAP_SQL" ]; then
				ok "  bootstrap SQL OK"
			else
				warn "  FALTA $root/$APP_DB_BOOTSTRAP_SQL"
			fi
		fi
	done
	registry_reset
	printf '\n'
	doctor_check_crlf
}

cmd_all() {
	local slug rc first_rc=0 failed=()
	LOG_FILE="$(log_open all)"
	docker_require
	infra_deploy
	for slug in $(registry_slugs); do
		registry_load "$slug"
		if [ "$APP_ENABLED" != "1" ]; then log "omitida (APP_ENABLED=0): $slug"; continue; fi
		# Subshell: aisla las globales APP_*/TIER_* entre apps y evita que el fallo de una
		# aborte el resto. El lock de cada app lo libera el trap EXIT del propio subshell.
		rc=0
		( TIERS=(); cmd_app "$slug" ) || rc=$?
		if [ "$rc" -ne 0 ]; then
			failed+=("$slug(exit $rc)")
			[ "$first_rc" -ne 0 ] || first_rc="$rc"
			[ "$FAIL_FAST" -eq 0 ] || break
		fi
	done
	if [ "${#failed[@]}" -gt 0 ]; then
		warn "apps con fallo: ${failed[*]}"
		exit "$first_rc"
	fi
}

# --- dispatch -----------------------------------------------------------------------------
SUMMARY=()
case "${MODE:-app}" in
	list)
		cmd_list
		exit 0
		;;
	all)
		cmd_all
		;;
	app)
		case "$TARGET" in
			"")       usage >&2; exit "$EX_USAGE" ;;
			doctor)   cmd_doctor; exit 0 ;;
			infra)    LOG_FILE="$(log_open infra)";    docker_require; infra_deploy ;;
			traefik)  LOG_FILE="$(log_open traefik)";  docker_require; infra_traefik ;;
			postgres) LOG_FILE="$(log_open postgres)"; docker_require; infra_postgres; infra_databases ;;
			*)        cmd_app "$TARGET" ;;
		esac
		;;
esac

if [ "${#SUMMARY[@]}" -gt 0 ]; then
	log "=== resumen ==="
	printf '  %s\n' "${SUMMARY[@]}"
fi
ok "despliegue completado"
