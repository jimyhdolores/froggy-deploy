# shellcheck shell=bash
# Modo registro: el tier no se construye en el servidor. GitHub Actions publica la imagen en GHCR con
# el SHA completo del commit como etiqueta, y este modulo la descarga, la comprueba contra la base y
# sustituye el contenedor.
#
# Un tier esta en modo registro si su .conf declara TIER_<t>_IMAGE. Su compose declara
# `image: <repo>:${IMAGE_TAG:-local}`, y la etiqueta que corre se guarda en el `.env` de la carpeta
# del compose (git lo ignora): asi un `docker compose up` a mano levanta lo desplegado y no otra cosa.
[ -n "${_IMAGE_SH:-}" ] && return 0
_IMAGE_SH=1

# La etiqueta OCI que el job `images` pone a cada imagen: el commit del que sale.
readonly REVISION_LABEL="org.opencontainers.image.revision"

# Para la vuelta atras automatica: los tiers ya sustituidos en esta ejecucion, en orden, y la
# etiqueta con la que corria cada uno. Los lee registry_on_exit.
ROLLBACK_TIERS=()
declare -A ROLLBACK_PREV_TAG=()
# El commit que corria cada tier antes de este despliegue (para el resumen y el historial).
declare -A PREV_REVS=()

tier_compose()  { printf '%s/%s/%s\n' "$APPS_DIR" "$APP_DIR" "$(registry_get "$1" COMPOSE)"; }
tier_tag_file() { printf '%s/.env\n' "$(dirname "$(tier_compose "$1")")"; }
short_rev()     { local r="${1:-}"; printf '%s\n' "${r:0:12}"; }

# La etiqueta con la que corre el tier segun su `.env`, o vacio.
tier_current_tag() {                            # $1=tier
	local file
	file="$(tier_tag_file "$1")"
	[ -f "$file" ] || return 0
	sed -n 's/^IMAGE_TAG=//p' "$file" | tail -1 | tr -d '[:space:]'
}

tier_write_tag() {                              # $1=tier $2=etiqueta
	[ "${DRY_RUN:-0}" = "1" ] && return 0
	printf '# Lo escribe froggy-deploy: la imagen con la que corre este tier. No se edita a mano.\nIMAGE_TAG=%s\n' \
		"$2" >"$(tier_tag_file "$1")"
}

# El commit que corre el contenedor, leido de su etiqueta OCI. Vacio si no corre o si su imagen no
# la lleva (una construida en el servidor).
container_revision() {                          # $1=contenedor
	local rev
	rev="$(_inspect "{{index .Config.Labels \"$REVISION_LABEL\"}}" "$1")"
	case "$rev" in "<novalue>" | "<no value>") rev="" ;; esac
	printf '%s\n' "$rev"
}

image_label() {                                 # $1=imagen $2=etiqueta -> valor o vacio
	local value
	value="$(docker image inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null | tr -d '\r')" || true
	case "$value" in "<novalue>" | "<no value>") value="" ;; esac
	printf '%s\n' "$value"
}

# ¿Cambio algo de estas rutas entre dos commits? Las rutas son pathspecs de git (admiten
# `:(exclude)` y `:(glob)`) separadas por espacios. Se trocean con `read -a` y no con una expansion
# sin comillas, porque `**/*.md` se expandiria contra el directorio actual.
paths_changed() {                               # $1=desde $2=hasta $3=pathspecs
	local specs=() rc=0
	read -r -a specs <<<"$3"
	[ "${#specs[@]}" -gt 0 ] || return 0        # sin rutas declaradas: se asume que cambio
	git -C "$APPS_DIR/$APP_DIR" diff --quiet "$1" "$2" -- "${specs[@]}" || rc=$?
	case "$rc" in
		0) return 1 ;;
		1) return 0 ;;
		*) die "$EX_GIT" "'git diff $1 $2' fallo en $APP_DIR (exit $rc)" ;;
	esac
}

# --- Descarga ---------------------------------------------------------------------------------
# En manual espera a que GitHub Actions publique la imagen, porque un push recien hecho tarda unos
# minutos en tenerla. En --auto apenas espera: el job de despliegue solo corre cuando el de imagenes
# ya termino.
image_pull() {                                  # $1=referencia completa
	local ref="$1" out waited=0 max
	if [ "${AUTO:-0}" = "1" ]; then max="${IMAGE_WAIT:-60}"; else max="${IMAGE_WAIT:-900}"; fi
	if [ "${DRY_RUN:-0}" = "1" ]; then
		log "DRY-RUN  docker pull $ref"
		return 0
	fi
	# La etiqueta es el SHA del commit y no se reescribe: si ya esta en local, es esa imagen. Asi
	# una vuelta atras reciente no depende ni de la red ni del token.
	if docker image inspect "$ref" >/dev/null 2>&1; then
		ok "imagen ya en local: $ref"
		return 0
	fi
	while :; do
		if out="$(docker pull -q "$ref" 2>&1)"; then
			ok "imagen lista: $ref"
			return 0
		fi
		case "$out" in
			*[Uu]nauthorized* | *"no basic auth credentials"*)
				die "$EX_IMAGE" "GHCR rechaza la descarga de $ref: falta el login o el token caduco.
    Crea un token classic con solo read:packages y ejecuta en el servidor: docker login ghcr.io -u <usuario>" ;;
			*"manifest unknown"* | *"not found"*) ;;
			*) die "$EX_IMAGE" "no se pudo descargar $ref: $out" ;;
		esac
		if [ "$waited" -ge "$max" ]; then
			die "$EX_IMAGE" "$ref no esta publicada tras ${waited}s. Mira el run de GitHub Actions de ese commit: si el job 'images' fallo, no hay nada que desplegar"
		fi
		log "esperando a que GitHub Actions publique $ref (${waited}s)..."
		sleep 15
		waited=$((waited + 15))
	done
}

# La via de emergencia (--build-local): construir en el servidor, como antes del modo registro.
# La etiqueta es `local-<sha>`, que nunca existe en GHCR, y la imagen no lleva etiqueta de revision.
image_build_local() {                           # $1=tier $2=etiqueta
	local compose
	compose="$(tier_compose "$1")"
	run_logged env IMAGE_TAG="$2" docker compose -f "$compose" build \
		|| die "$EX_BUILD" "el build local de $APP_SLUG/$1 fallo"
}

# --- Comprobacion previa ------------------------------------------------------------------------
# La imagen nueva se lanza en un contenedor efimero contra la base de produccion, ANTES de sustituir
# el contenedor que sirve, con las variables que ella misma declara en la etiqueta
# `froggy.preflight`. Glowpe compara entonces sus entidades con el esquema de todos los tenants y
# sale con 3 si no encajan (SCHEMA_CHECK_ONLY, apps/backend/src/main.ts).
#
# Lo que la hace segura:
# - `-l traefik.enable=false`: el efimero hereda las etiquetas del servicio, entre ellas el router de
#   Traefik, y sin esto Traefik le mandaria trafico.
# - La etiqueta `froggy.preflight` es obligatoria. Una imagen que no la lleva arrancaria como un
#   backend normal, crones incluidos, en paralelo con el de produccion, y no saldria nunca.
# - `timeout` y el `rm -f` por etiqueta: si aun asi no sale, no cuelga el despliegue ni deja un
#   contenedor huerfano.
# - La imagen tiene que estar ya en local: `run` no tiene --no-build y, con `build:` en el compose,
#   compose la construiria aqui.
#
# REPORT_ONLY=1 (--pull-only) solo informa: en la preparacion de una ventana de migracion la deriva
# es lo esperado.
image_preflight() {                             # $1=tier $2=etiqueta
	local tier="$1" tag="$2" compose ref vars service out rc=0 kv summary
	local args=()
	compose="$(tier_compose "$tier")"
	ref="$(registry_get "$tier" IMAGE):$tag"
	if [ "${DRY_RUN:-0}" = "1" ]; then
		log "DRY-RUN  comprobacion previa de $ref contra la base"
		return 0
	fi

	docker image inspect "$ref" >/dev/null 2>&1 \
		|| die "$EX_IMAGE" "falta $ref en local: no se lanza la comprobacion previa"
	vars="$(image_label "$ref" froggy.preflight)"
	[ -n "$vars" ] \
		|| die "$EX_HELD" "$ref no declara la etiqueta froggy.preflight: no sabe comprobarse contra la base, y no se despliega a ciegas"
	for kv in $vars; do args+=(-e "$kv"); done
	service="$(docker compose -f "$compose" config --services | sed -n 1p)"

	log "comprobacion previa de $APP_SLUG/$tier ($(short_rev "$tag")) contra la base..."
	out="$(IMAGE_TAG="$tag" timeout "${PREFLIGHT_TIMEOUT:-180}" docker compose -f "$compose" run --rm \
		--no-deps --pull never -T -l traefik.enable=false -l froggy.oneoff=preflight \
		"${args[@]}" "$service" 2>&1)" || rc=$?
	docker ps -aq --filter label=froggy.oneoff=preflight | xargs -r docker rm -f >/dev/null 2>&1 || true
	printf '%s\n' "$out" >>"$LOG_FILE" 2>/dev/null || true

	case "$rc" in
		0)
			summary="$(printf '%s\n' "$out" | grep -E '^(Comprobados|Sin tenants)' | tail -1 || true)"
			ok "comprobacion previa limpia${summary:+: $summary}"
			;;
		3)
			printf '%s\n' "$out" | grep -vE '^\{"level' | sed 's/^/    /' >&2
			if [ "${REPORT_ONLY:-0}" = "1" ]; then
				warn "deriva de esquema (arriba): es lo esperado antes de migrar"
			elif [ "${ALLOW_DRIFT:-0}" = "1" ]; then
				warn "deriva de esquema (arriba), pero --allow-drift: se despliega igual"
			else
				die "$EX_HELD" "RETENIDO: la imagen $(short_rev "$tag") no encaja con el esquema de la base (arriba). Es una ventana de migracion: 'deploy $APP_SLUG --pull-only', dump, script con --apply, y 'deploy $APP_SLUG'. Si el orden es desplegar y despues migrar: --allow-drift"
			fi
			;;
		*)
			printf '%s\n' "$out" | grep -vE '^\{"level' | tail -15 | sed 's/^/    /' >&2
			if [ "${REPORT_ONLY:-0}" = "1" ]; then
				warn "la comprobacion previa no pudo completarse (exit $rc): revisa la salida de arriba"
			else
				die "$EX_HELD" "RETENIDO: la comprobacion previa de $(short_rev "$tag") no pudo completarse (exit $rc) por algo que no es la deriva: revisa la salida de arriba"
			fi
			;;
	esac
}

# --- Sustitucion y vuelta atras ----------------------------------------------------------------
# Antes de sustituir el contenedor se etiqueta su imagen como `<repo>:rollback`. Asi la vuelta atras
# no depende de que su etiqueta original siga existiendo en local.
tier_apply() {                                  # $1=tier $2=etiqueta $3=commit esperado (vacio: no se comprueba)
	local tier="$1" tag="$2" expected="$3" compose container wait_s repo prev_id rev
	compose="$(tier_compose "$tier")"
	container="$(registry_get "$tier" CONTAINER)"
	wait_s="$(registry_get "$tier" WAIT)"; wait_s="${wait_s:-60}"
	repo="$(registry_get "$tier" IMAGE)"

	log "--- $APP_SLUG/$tier -> $container ($(short_rev "$tag")) ---"
	if [ "${DRY_RUN:-0}" = "1" ]; then
		log "DRY-RUN  IMAGE_TAG=$tag docker compose -f $compose up -d --force-recreate --no-build --pull never"
		log "DRY-RUN  verificar $container"
		return 0
	fi

	[ -n "${PREV_REVS[$tier]+x}" ] || PREV_REVS[$tier]="$(container_revision "$container")"
	prev_id="$(_inspect '{{.Image}}' "$container")"
	if [ -n "$prev_id" ]; then
		docker tag "$prev_id" "$repo:rollback"
		ROLLBACK_PREV_TAG[$tier]="$(tier_current_tag "$tier")"
		ROLLBACK_TIERS+=("$tier")
	fi

	tier_write_tag "$tier" "$tag"
	run_logged docker compose -f "$compose" up -d --force-recreate --no-build --pull never \
		|| die "$EX_BUILD" "'docker compose up' fallo para $compose"
	verify_container "$container" "$wait_s"

	if [ -n "$expected" ]; then
		rev="$(container_revision "$container")"
		[ "$rev" = "$expected" ] \
			|| die "$EX_VERIFY" "$container corre la revision '${rev:-desconocida}' y se esperaba $expected"
	fi
	SUMMARY+=("$APP_SLUG/$tier  $container  $(short_rev "${PREV_REVS[$tier]:-?}")->$(short_rev "${expected:-$tag}")  OK")
}

# Corre en un subshell (registry_on_exit): un `die` dentro solo corta este tier. Bajo el `|| true`
# del trap, `set -e` no aplica aqui, asi que cada paso comprueba su resultado.
tier_rollback() {                               # $1=tier
	local tier="$1" compose container wait_s repo prev
	compose="$(tier_compose "$tier")"
	container="$(registry_get "$tier" CONTAINER)"
	wait_s="$(registry_get "$tier" WAIT)"; wait_s="${wait_s:-60}"
	repo="$(registry_get "$tier" IMAGE)"
	prev="${ROLLBACK_PREV_TAG[$tier]:-}"

	tier_write_tag "$tier" rollback || return 1
	run_logged docker compose -f "$compose" up -d --force-recreate --no-build --pull never || return 1
	verify_container "$container" "$wait_s" || return 1
	# Si la etiqueta de antes sigue apuntando a la misma imagen, se restaura en el `.env`: es la que
	# dice de que commit es.
	if [ -n "$prev" ] && [ "$(docker image inspect -f '{{.Id}}' "$repo:$prev" 2>/dev/null)" \
		= "$(docker image inspect -f '{{.Id}}' "$repo:rollback" 2>/dev/null)" ]; then
		tier_write_tag "$tier" "$prev"
	fi
}

# ON_EXIT_HOOK del despliegue automatico (lib/common.sh). Si la ejecucion falla con algun tier ya
# sustituido, se vuelve a las imagenes anteriores en orden inverso y se pausa el despliegue
# automatico: el siguiente push no debe repetir lo que acaba de fallar sin que nadie lo mire.
# Solo en --auto: a mano, el bucle de reinicio puede ser justo lo esperado (una ventana desplegar y
# luego migrar).
registry_on_exit() {                            # $1=codigo de salida
	local rc="$1" i tier failed=0
	[ "$rc" -ne 0 ] || return 0
	[ "${AUTO:-0}" = "1" ] || return 0
	[ "${#ROLLBACK_TIERS[@]}" -gt 0 ] || return 0

	warn "el despliegue fallo (exit $rc) con ${ROLLBACK_TIERS[*]} ya sustituido: se vuelve a las imagenes anteriores"
	for ((i = ${#ROLLBACK_TIERS[@]} - 1; i >= 0; i--)); do
		tier="${ROLLBACK_TIERS[$i]}"
		if (tier_rollback "$tier"); then
			ok "$APP_SLUG/$tier: de vuelta en la imagen anterior"
			state_history_add "$APP_SLUG" auto "$tier" "${TARGET_SHA:-}" "${PREV_REVS[$tier]:-}" "revertido"
		else
			failed=1
			warn "$APP_SLUG/$tier: la vuelta atras TAMBIEN fallo. Revisalo ya: puede estar caido"
			state_history_add "$APP_SLUG" auto "$tier" "${TARGET_SHA:-}" "${PREV_REVS[$tier]:-}" "REVERSION FALLIDA"
		fi
	done
	ROLLBACK_TIERS=()
	state_pause "$APP_SLUG" "vuelta atras automatica: fallo el despliegue de $(short_rev "${TARGET_SHA:-}") (exit $rc)"
	[ "$failed" -eq 0 ] || EXIT_OVERRIDE="$EX_ROLLBACK"
}

# --- Retencion ----------------------------------------------------------------------------------
# Conserva en local las IMAGE_KEEP (5) etiquetas de commit mas recientes de cada repo, ademas de la
# que corre y de `rollback`. Con una etiqueta por commit ninguna imagen queda colgante, y
# `image prune` no recogeria ninguna.
image_retain() {                                # $1=repo $2=etiqueta en uso
	local repo="$1" keep="$2" tag n=0
	[ "${DRY_RUN:-0}" = "1" ] && return 0
	while read -r tag; do
		case "$tag" in "$keep" | rollback) continue ;; esac
		[[ "$tag" =~ ^[0-9a-f]{40}$ ]] || continue
		n=$((n + 1))
		[ "$n" -gt "${IMAGE_KEEP:-5}" ] || continue
		docker rmi "$repo:$tag" >/dev/null 2>&1 || warn "no se pudo borrar $repo:$tag"
	done < <(docker images "$repo" --format '{{.Tag}}' 2>/dev/null | tr -d '\r')
}
