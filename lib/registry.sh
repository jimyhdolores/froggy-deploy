# shellcheck shell=bash
# El registro: carga y valida los apps.d/<slug>.conf.
#
# Los .conf se leen con `source`, asi que ejecutan codigo arbitrario. Es aceptable porque
# viven en el mismo repositorio que este script: misma frontera de confianza. Aun asi,
# registry_validate comprueba que APP_DIR sea un nombre simple, no una ruta.
[ -n "${_REGISTRY_SH:-}" ] && return 0
_REGISTRY_SH=1

REGISTRY_APP_KEYS="APP_NAME APP_REPO APP_DIR APP_BRANCH APP_TIERS"
REGISTRY_TIER_KEYS="COMPOSE CONTAINER"          # obligatorias por cada tier

registry_file() { printf '%s/%s.conf\n' "$REGISTRY_DIR" "$1"; }

registry_slugs() {                              # orden lexicografico = determinista
	local file
	for file in "$REGISTRY_DIR"/*.conf; do
		[ -e "$file" ] || continue
		basename "$file" .conf
	done
}

# Evita que el estado de una app contamine a la siguiente en --all.
registry_reset() {
	local var
	for var in APP_SLUG APP_NAME APP_REPO APP_DIR APP_BRANCH APP_TIERS \
		APP_ENABLED APP_DB APP_DB_BOOTSTRAP_SQL; do
		unset "$var" || true
	done
	for var in $(compgen -v TIER_ 2>/dev/null || true); do
		unset "$var" || true
	done
}

registry_load() {                               # $1 = slug
	local slug="$1" file
	file="$(registry_file "$slug")"
	if [ ! -f "$file" ]; then
		die "$EX_USAGE" "app desconocida: '$slug'. Disponibles: $(registry_slugs | tr '\n' ' ')"
	fi
	registry_reset
	# shellcheck disable=SC1090
	source "$file" || die "$EX_REGISTRY" "no se pudo interpretar $file"
	APP_SLUG="$slug"
	: "${APP_ENABLED:=1}" "${APP_DB:=}" "${APP_DB_BOOTSTRAP_SQL:=}"
	registry_validate "$file"
}

registry_validate() {
	local file="$1" key tier ref
	for key in $REGISTRY_APP_KEYS; do
		[ -n "${!key-}" ] || die "$EX_REGISTRY" "$file: falta la clave obligatoria $key"
	done
	# if/then y NO `[[ ... ]] && die`: bajo `set -e`, un `&&` cuya condicion es falsa hace que
	# la sentencia devuelva 1 y aborte el script entero.
	if [[ "$APP_DIR" == */* || "$APP_DIR" == .* ]]; then
		die "$EX_REGISTRY" "$file: APP_DIR debe ser un nombre de directorio simple, no una ruta"
	fi
	for tier in $APP_TIERS; do
		for key in $REGISTRY_TIER_KEYS; do
			ref="TIER_${tier}_${key}"
			[ -n "${!ref-}" ] || die "$EX_REGISTRY" "$file: falta $ref ('$tier' esta en APP_TIERS)"
		done
	done
}

registry_get() {                                # $1=tier $2=clave -> valor o vacio
	local ref="TIER_${1}_${2}"
	printf '%s\n' "${!ref-}"
}

registry_has_tier() {                           # $1=tier ; usa el APP_TIERS ya cargado
	case " $APP_TIERS " in
		*" $1 "*) return 0 ;;
		*) return 1 ;;
	esac
}
