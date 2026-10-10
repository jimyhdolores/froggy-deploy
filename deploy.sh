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

for _lib in common registry git docker db infra state image; do
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
  --no-pull          no actualizar el codigo; desplegar el commit que ya esta en disco
  --no-build         'up -d --force-recreate' sin --build (redespliegue de la misma imagen)
  --branch <rama>    usar esta rama en lugar de APP_BRANCH, solo en esta ejecucion
  --bootstrap-db     ejecutar el SQL de bootstrap aunque la base ya existiera (con salvaguardas)
  --wait-lock        encolarse si hay otro despliegue de la misma app en curso (LOCK_WAIT_MAX)
  --fail-fast        en --all, abortar en el primer fallo (por defecto: continuar y resumir)
  --apps-dir <ruta>  raiz donde viven los repos (por defecto: el padre de este script)
  --dry-run          imprime lo que haria; no clona, no construye, no toca la base
  -h, --help

Solo en modo registro (apps cuyos tiers declaran TIER_*_IMAGE; las publica GitHub Actions):
  --tag <commit>     desplegar las imagenes de un commit ya publicado, sin mover el checkout:
                     la vuelta atras. Pausa el despliegue automatico
  --pull-only        actualizar el codigo, descargar las imagenes y comprobarlas contra la base,
                     sin sustituir nada: prepara una ventana de migracion. Pausa el automatico
  --allow-drift      desplegar aunque la comprobacion previa vea deriva de esquema (ventanas en
                     las que se despliega y DESPUES se migra). Pausa el automatico
  --build-local      via de emergencia: construir en el servidor, como antes. Pausa el automatico
  --pause, --resume  pausar o reanudar el despliegue automatico de la app
  --history          los ultimos despliegues de la app, con sus commits
  --auto --sha <sha> el despliegue que lanza el CI (ci/entry.sh): solo los tiers cuyas fuentes
                     cambiaron, retenido si cambia el esquema, y vuelta atras si algo falla

Ejemplos:
  ./deploy.sh glowpe                 # backend + frontend
  ./deploy.sh glowpe backend         # solo el backend
  ./deploy.sh checkout               # su unico tier: web
  ./deploy.sh --all
  ./deploy.sh tours frontend --no-pull
  ./deploy.sh glowpe --history       # que corre y que corrio antes
  ./deploy.sh glowpe --tag 9e42929   # volver a ese commit

Codigos de salida: 0 ok - 2 uso - 10 entorno - 11 registro - 12 git
                   13 env_file - 14 base de datos - 15 build - 16 verificacion - 17 lock
                   18 retenido (esquema) - 19 imagen no disponible - 20 vuelta atras fallida

Entorno:
  BUILD_CACHE_MAX    tope de la cache de build tras cada despliegue (por defecto 10GB)
  IMAGE_WAIT         segundos esperando a que se publique la imagen (900 a mano, 60 en --auto)
  IMAGE_KEEP         imagenes de commit que se conservan en local por repo (por defecto 5)
  LOCK_WAIT_MAX      tope de --wait-lock en segundos (por defecto 1800)
EOF
}

# --- parseo -------------------------------------------------------------------------------
DRY_RUN=0; NO_PULL=0; NO_BUILD=0; FORCE_BOOTSTRAP=0
WAIT_LOCK=0; FAIL_FAST=0; BRANCH_OVERRIDE=""; MODE=""; TARGET=""; TIERS=()
AUTO=0; TARGET_SHA=""; TAG_REF=""; PULL_ONLY=0; ALLOW_DRIFT=0; BUILD_LOCAL=0; STATE_CMD=""

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
		--auto)         AUTO=1 ;;
		--pull-only)    PULL_ONLY=1 ;;
		--allow-drift)  ALLOW_DRIFT=1 ;;
		--build-local)  BUILD_LOCAL=1 ;;
		--pause)        STATE_CMD=pause ;;
		--resume)       STATE_CMD=resume ;;
		--history)      STATE_CMD=history ;;
		--branch)
			BRANCH_OVERRIDE="${2:-}"
			[ -n "$BRANCH_OVERRIDE" ] || die "$EX_USAGE" "--branch requiere un valor"
			shift ;;
		--apps-dir)
			APPS_DIR="${2:-}"
			[ -d "$APPS_DIR" ] || die "$EX_USAGE" "--apps-dir: no existe '${2:-}'"
			shift ;;
		--sha)
			TARGET_SHA="${2:-}"
			[[ "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]] \
				|| die "$EX_USAGE" "--sha requiere el SHA completo de un commit (40 caracteres hexadecimales)"
			shift ;;
		--tag)
			TAG_REF="${2:-}"
			[ -n "$TAG_REF" ] || die "$EX_USAGE" "--tag requiere un commit"
			shift ;;
		-*)             die "$EX_USAGE" "opcion desconocida: $1 (usa --help)" ;;
		*)
			if [ -z "$TARGET" ]; then TARGET="$1"; else TIERS+=("$1"); fi ;;
	esac
	shift
done
APPS_DIR="$(cd "$APPS_DIR" && pwd)"

# El despliegue automatico tiene una sola forma, la que usa ci/entry.sh: todo lo demas lo decide
# una persona.
if [ "$AUTO" = "1" ]; then
	[ -n "$TARGET_SHA" ] || die "$EX_USAGE" "--auto requiere --sha <commit>"
	if [ "${#TIERS[@]}" -gt 0 ] || [ -n "$TAG_REF" ] || [ "$PULL_ONLY$ALLOW_DRIFT$BUILD_LOCAL$NO_PULL" != "0000" ]; then
		die "$EX_USAGE" "--auto no admite tiers ni --tag, --pull-only, --allow-drift, --build-local o --no-pull"
	fi
elif [ -n "$TARGET_SHA" ]; then
	die "$EX_USAGE" "--sha solo va con --auto; para desplegar un commit concreto a mano, --tag"
fi
if [ -n "$TAG_REF" ] && [ "$BUILD_LOCAL" = "1" ]; then
	die "$EX_USAGE" "--tag y --build-local no se combinan: --tag despliega imagenes ya publicadas"
fi

# --- comprobaciones de un tier ------------------------------------------------------------
# Todo lo que se puede comprobar de un tier sin tocar nada: compose y env_file en su sitio, redes
# externas, proyecto compose propio y compose valido. Devuelve 1 solo en un ensayo sobre una app
# que aun no esta clonada: no hay nada mas que recorrer.
tier_check() {
	local tier="$1" rel container env_rel root compose

	rel="$(registry_get "$tier" COMPOSE)"
	container="$(registry_get "$tier" CONTAINER)"
	env_rel="$(registry_get "$tier" ENV_FILE)"

	root="$APPS_DIR/$APP_DIR"
	compose="$root/$rel"

	if [ ! -f "$compose" ]; then
		# En un ensayo sobre una app que aun no esta clonada, el compose no puede existir
		# todavia: el clone no llego a ocurrir. Decirlo, en vez de dar un error de registro
		# que parece un fallo de configuracion y no lo es.
		if [ "${DRY_RUN:-0}" = "1" ] && [ ! -d "$root/.git" ]; then
			warn "no se puede comprobar $rel: el repo aun no esta clonado (el despliegue real lo clonaria antes)"
			return 1
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

	compose_assert_project "$compose" "$container" "$APP_SLUG/$tier"
	compose_validate "$compose"
}

# --- despliegue de un tier (modo build: se construye en el servidor) ----------------------
deploy_tier() {
	local tier="$1" container wait_s

	container="$(registry_get "$tier" CONTAINER)"
	wait_s="$(registry_get "$tier" WAIT)"; wait_s="${wait_s:-60}"

	log "--- $APP_SLUG/$tier -> $container ---"
	tier_check "$tier" || return 0
	compose_up "$(tier_compose "$tier")"
	verify_container "$container" "$wait_s"
	SUMMARY+=("$APP_SLUG/$tier  $container  ${SHA_BEFORE:-nuevo}->${SHA_AFTER}  OK")
}

# --- despliegue automatico: que tiers, y la guarda del esquema ----------------------------
# --auto despliega solo los tiers que cambiaron entre el commit que corren y el destino, comparando
# las rutas de TIER_*_SOURCES (lo que copia su Dockerfile): un commit de documentacion no reinicia
# la API. Y retiene si entre lo que corre y el destino cambian las rutas de APP_SCHEMA_PATHS: la
# ventana de migracion la lleva una persona. La comprobacion previa no basta para eso, porque la
# sonda de deriva no ve cambios de precision ni de escala.
auto_select_tiers() {                           # $1=commit destino ; reescribe SELECTED
	local expected="$1" tier container rev changed=() specs=()
	for tier in "${SELECTED[@]}"; do
		container="$(registry_get "$tier" CONTAINER)"
		rev="$(container_revision "$container")"
		PREV_REVS[$tier]="$rev"
		if [ -z "$rev" ]; then
			die "$EX_HELD" "RETENIDO: no se sabe que commit corre $container (su imagen no lleva $REVISION_LABEL: se construyo en el servidor). Un 'deploy $APP_SLUG' manual lo resuelve"
		fi
		if [ "$rev" = "$expected" ]; then
			log "AUTO: $tier ya corre $(short_rev "$expected")"
			continue
		fi
		if [ -n "$APP_SCHEMA_PATHS" ] && paths_changed "$rev" "$expected" "$APP_SCHEMA_PATHS"; then
			read -r -a specs <<<"$APP_SCHEMA_PATHS"
			git -C "$APPS_DIR/$APP_DIR" diff --stat "$rev" "$expected" -- "${specs[@]}" 2>/dev/null \
				| sed 's/^/    /' >&2 || true
			die "$EX_HELD" "RETENIDO: entre $(short_rev "$rev") y $(short_rev "$expected") cambia el esquema (arriba). La ventana de migracion la lleva una persona: 'deploy $APP_SLUG --pull-only', dump, script con --apply, y 'deploy $APP_SLUG'"
		fi
		if paths_changed "$rev" "$expected" "$(registry_get "$tier" SOURCES)"; then
			changed+=("$tier")
		else
			log "AUTO: $tier sin cambios en sus fuentes entre $(short_rev "$rev") y $(short_rev "$expected")"
		fi
	done
	SELECTED=(${changed[@]+"${changed[@]}"})
}

# --- despliegue de una app en modo registro (TIER_*_IMAGE) --------------------------------
# Las imagenes las publica GitHub Actions: aqui solo se descargan y se arrancan, en dos fases.
# Primero se prepara TODO (comprobaciones, descarga y comprobacion previa de cada tier) y solo
# despues se sustituye nada: si algo falla al preparar, produccion no se ha tocado.
cmd_app_registry() {
	local tier tag expected reason mode=manual

	[ -z "$BRANCH_OVERRIDE" ] \
		|| die "$EX_USAGE" "--branch no aplica en modo registro: solo los commits de $APP_BRANCH tienen imagen publicada"
	[ "$NO_BUILD" != "1" ] || warn "--no-build sobra en modo registro: aqui no se construye nada"

	if [ "$AUTO" = "1" ]; then
		mode=auto
		[ "$APP_AUTO_DEPLOY" = "1" ] \
			|| die "$EX_USAGE" "$APP_SLUG no admite el despliegue automatico (APP_AUTO_DEPLOY en $(registry_file "$APP_SLUG"))"
		# Antes de tocar el checkout: una ventana de migracion en curso tampoco quiere que se mueva.
		if reason="$(state_paused_reason "$APP_SLUG")"; then
			NOOP_REASON="en pausa desde $reason"
			log "AUTO: $NOOP_REASON. Lo reanuda un 'deploy $APP_SLUG' manual completo, o --resume"
			return 0
		fi
	fi

	# 1. Que commit se despliega.
	if [ -n "$TAG_REF" ]; then
		mode=tag
		[ -d "$APPS_DIR/$APP_DIR/.git" ] || die "$EX_GIT" "$APP_DIR no esta clonado: --tag necesita su historial"
		expected="$(git_resolve_published "$TAG_REF")"
		SHA_BEFORE="$(git_head "$APPS_DIR/$APP_DIR")"
		SHA_AFTER="$SHA_BEFORE"
		log "--tag: imagenes de $(short_rev "$expected"); el checkout se queda en $SHA_BEFORE"
	else
		git_ensure_repo
		if [ "${STALE:-0}" = "1" ]; then
			NOOP_REASON="obsoleto: el checkout ya esta en $SHA_BEFORE, por delante de $(short_rev "$TARGET_SHA")"
			log "AUTO: $NOOP_REASON; lo despliega su propia ejecucion"
			return 0
		fi
		expected="$SHA_FULL"
	fi
	tag="$expected"
	if [ "$BUILD_LOCAL" = "1" ]; then
		mode=local
		tag="local-$(short_rev "$expected")"
	fi

	# 2. Las guardas del despliegue automatico.
	if [ "$AUTO" = "1" ]; then
		auto_select_tiers "$expected"
		if [ "${#SELECTED[@]}" -eq 0 ]; then
			NOOP_REASON="ningun tier cambio entre lo que corre y $(short_rev "$expected")"
			log "AUTO: $NOOP_REASON"
			return 0
		fi
	fi
	log "tiers: ${SELECTED[*]} -> $(short_rev "$tag")"

	db_ensure

	# 3. Preparar todo.
	for tier in "${SELECTED[@]}"; do
		log "--- comprobando $APP_SLUG/$tier ---"
		tier_check "$tier" || return 0
	done
	for tier in "${SELECTED[@]}"; do
		if [ "$BUILD_LOCAL" = "1" ]; then
			image_build_local "$tier" "$tag"
		else
			image_pull "$(registry_get "$tier" IMAGE):$tag"
		fi
	done
	for tier in "${SELECTED[@]}"; do
		if [ "$(registry_get "$tier" PREFLIGHT)" = "1" ]; then
			REPORT_ONLY="$PULL_ONLY" image_preflight "$tier" "$tag"
		fi
	done
	if [ "$PULL_ONLY" = "1" ]; then
		state_pause "$APP_SLUG" "ventana de migracion preparada con --pull-only ($(short_rev "$expected"))"
		NOOP_REASON="imagenes de $(short_rev "$expected") listas; no se ha sustituido nada"
		ok "$NOOP_REASON. La ventana se cierra con 'deploy $APP_SLUG'"
		return 0
	fi

	# 4. Aplicar, tier a tier. Si algo falla, registry_on_exit vuelve atras (solo en --auto).
	ON_EXIT_HOOK=registry_on_exit
	for tier in "${SELECTED[@]}"; do
		tier_apply "$tier" "$tag" "$([ "$BUILD_LOCAL" = "1" ] || printf '%s' "$expected")"
	done
	ROLLBACK_TIERS=()
	ON_EXIT_HOOK=""

	# 5. Despues: historial, pausa y limpieza.
	for tier in "${SELECTED[@]}"; do
		state_history_add "$APP_SLUG" "$mode" "$tier" "${PREV_REVS[$tier]:-}" "$expected" "OK"
		image_retain "$(registry_get "$tier" IMAGE)" "$tag"
	done
	case "$mode" in
		tag)   state_pause "$APP_SLUG" "vuelta atras a mano con --tag $(short_rev "$expected")" ;;
		local) state_pause "$APP_SLUG" "desplegado con --build-local: su imagen no lleva etiqueta de revision" ;;
		manual)
			if [ "$ALLOW_DRIFT" = "1" ]; then
				state_pause "$APP_SLUG" "desplegado con --allow-drift: la migracion sigue pendiente"
			elif [ "${#SELECTED[@]}" -eq "$(wc -w <<<"$APP_TIERS")" ]; then
				state_resume "$APP_SLUG"
			fi
			;;
	esac
	docker_builder_gc
}

# --- despliegue de una app ----------------------------------------------------------------
cmd_app() {
	local slug="$1" tier
	local selected=()

	registry_load "$slug"

	# La pausa y el historial son estado del servidor: no despliegan nada, ni toman el lock.
	case "$STATE_CMD" in
		pause)   state_pause "$slug" "a mano (--pause)"; return 0 ;;
		resume)  state_resume "$slug"; return 0 ;;
		history) state_history_show "$slug"; return 0 ;;
	esac

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

	if registry_uses_images; then
		SELECTED=("${selected[@]}")
		cmd_app_registry
		return 0
	fi
	if [ "$AUTO$PULL_ONLY$ALLOW_DRIFT$BUILD_LOCAL" != "0000" ] || [ -n "$TAG_REF" ]; then
		die "$EX_USAGE" "--auto, --tag, --pull-only, --allow-drift y --build-local son del modo registro, y $slug construye en el servidor"
	fi

	# Orden deliberado: git primero (los compose y el .sql de bootstrap salen del repo), la
	# base despues, y solo entonces los contenedores.
	git_ensure_repo
	db_ensure
	for tier in "${selected[@]}"; do
		deploy_tier "$tier"
	done

	# Al final y solo si todos los tiers quedaron sanos: un despliegue fallido sale antes por `die`,
	# y recortar la cache entonces solo haria mas lento el reintento.
	docker_builder_gc
}

cmd_list() {
	local slug tier rev
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
			if [ -n "$(registry_get "$tier" IMAGE)" ]; then
				rev="$(container_revision "$(registry_get "$tier" CONTAINER)" 2>/dev/null)"
				printf '                            imagen %s, corre %s\n' "$(registry_get "$tier" IMAGE)" \
					"${rev:+$(short_rev "$rev")}${rev:--}"
			fi
		done
		[ -z "$APP_DB" ] || printf '            base de datos: %s\n' "$APP_DB"
		[ "$APP_AUTO_DEPLOY" != "1" ] || printf '            despliegue automatico desde el CI%s\n' \
			"$(state_paused_reason "$slug" >/dev/null && printf ' - EN PAUSA: %s' "$(state_paused_reason "$slug")")"
	done
	registry_reset
	printf '\nRaiz de repos: %s\n' "$APPS_DIR"
}

doctor_check_crlf() {
	local file bad=0
	for file in "$SCRIPT_DIR"/deploy.sh "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR"/ci/*.sh "$REGISTRY_DIR"/*.conf; do
		[ -e "$file" ] || continue
		if grep -qU $'\r' "$file" 2>/dev/null; then
			warn "CRLF detectado en $file - corrigelo con: sed -i 's/\\r\$//' '$file'"
			bad=1
		fi
	done
	[ "$bad" -eq 0 ] && ok "todos los ficheros del despliegue estan en LF"
	return 0
}

# Lo mismo que compose_assert_project comprueba tier a tier al desplegar, pero de todo el registro
# a la vez y sin desplegar nada: proyectos compose compartidos y, si hay Docker, contenedores que
# siguen bajo un proyecto que su compose ya no declara (el proximo deploy se detendria).
doctor_check_compose_projects() {
	local owners dups line project owner slug tier container actual have_docker=0

	owners="$(registry_project_owners)"
	dups="$(sort <<<"$owners" \
		| awk '{ n[$1]++; o[$1] = o[$1] " " $2 } END { for (p in n) if (n[p] > 1) print p ":" o[p] }' \
		| sort)"
	if [ -n "$dups" ]; then
		while IFS= read -r line; do
			warn "proyecto compose compartido -> $line (desplegar uno recrearia el contenedor del otro)"
		done <<<"$dups"
	else
		ok "cada tier y la infraestructura tienen su propio proyecto compose"
	fi

	docker info >/dev/null 2>&1 && have_docker=1
	if [ "$have_docker" -eq 0 ]; then
		warn "sin Docker: no se comprueba a que proyecto pertenece cada contenedor"
		return 0
	fi
	while read -r project owner; do
		case "$owner" in infra/*) continue ;; esac
		slug="${owner%/*}" tier="${owner#*/}"
		container="$( (registry_load "$slug"; registry_get "$tier" CONTAINER) )"
		actual="$(_inspect '{{index .Config.Labels "com.docker.compose.project"}}' "$container")"
		case "$actual" in
			"" | "<novalue>" | "$project") ;;
			*) warn "$container corre bajo el proyecto '$actual' y su compose declara '$project': el proximo 'deploy $slug $tier' se detendra con los pasos del cambio (README, \"Proyecto compose propio\")" ;;
		esac
	done <<<"$owners"
	return 0
}

# Lo que el modo registro necesita del servidor: el login en GHCR (las imagenes son privadas) y que
# cada compose declare la imagen que el registro dice.
doctor_check_images() {                         # usa la app ya cargada
	local tier compose repo declared reason
	registry_uses_images || return 0
	if [ -f "$HOME/.docker/config.json" ] && grep -q '"ghcr.io"' "$HOME/.docker/config.json"; then
		ok "  hay login en ghcr.io (si el token caduco, los despliegues saldran con 19)"
	else
		warn "  sin login en ghcr.io: las imagenes son privadas. Token classic con read:packages y 'docker login ghcr.io'"
	fi
	for tier in $APP_TIERS; do
		compose="$APPS_DIR/$APP_DIR/$(registry_get "$tier" COMPOSE)"
		repo="$(registry_get "$tier" IMAGE)"
		[ -f "$compose" ] || continue
		declared="$(sed -n -E 's/^[[:space:]]*image:[[:space:]]*["'\'']?([^"'\''[:space:]]+).*/\1/p' "$compose" | head -1)"
		case "$declared" in
			"$repo:"*) ok "  $tier: el compose declara $declared" ;;
			*) warn "  $tier: TIER_${tier}_IMAGE='$repo' pero el compose declara '${declared:-ninguna imagen}'" ;;
		esac
	done
	if reason="$(state_paused_reason "$APP_SLUG")"; then
		warn "  despliegue automatico EN PAUSA desde $reason"
	fi
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
		doctor_check_images
	done
	registry_reset
	printf '\n'
	doctor_check_compose_projects
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
SELECTED=()
NOOP_REASON=""                                  # por que una ejecucion correcta no desplego nada
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
if [ -n "$NOOP_REASON" ]; then
	ok "nada que desplegar: $NOOP_REASON"
elif [ -z "$STATE_CMD" ]; then
	ok "despliegue completado"
fi
