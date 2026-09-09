# shellcheck shell=bash
# Infraestructura compartida: PostgreSQL, Traefik y las bases del registro.
# Absorbe lo que hacian setup.sh y deploy-traefik.sh.
[ -n "${_INFRA_SH:-}" ] && return 0
_INFRA_SH=1

infra_deploy() {
	infra_postgres
	infra_traefik
	infra_databases
}

infra_postgres() {
	log "levantando PostgreSQL"
	run_logged docker compose -f "$SCRIPT_DIR/postgres/docker-compose.yml" up -d \
		|| die "$EX_BUILD" "no se pudo levantar PostgreSQL"
	db_wait_ready 30
	verify_container "$PG_CONTAINER" 60
}

infra_traefik() {
	local acme="$SCRIPT_DIR/acme.json" perms
	if [ ! -f "$acme" ]; then
		run touch "$acme"
		run chmod 600 "$acme"
		ok "acme.json creado con permisos 600"
	else
		# `stat -c` es GNU y `stat -f %Lp` es BSD/macOS: se conserva el fallback del script
		# original para que funcione en ambos.
		perms="$(stat -c '%a' "$acme" 2>/dev/null || stat -f '%Lp' "$acme" 2>/dev/null || printf '')"
		if [ "$perms" != "600" ]; then
			run chmod 600 "$acme"
			ok "acme.json: permisos corregidos a 600"
		else
			ok "acme.json con permisos correctos"
		fi
	fi

	# Cambio deliberado respecto a deploy-traefik.sh, que hacia `down` + `up -d`: este compose
	# DECLARA proxy-network (no la marca como external), asi que el `down` intenta borrar la
	# red a la que estan enganchados todos los contenedores de apps. Docker lo rechaza y solo
	# avisa, pero es un fallo latente. `up -d --force-recreate` recrea el contenedor -que es
	# lo unico necesario para recoger cambios de traefik.yml- sin tocar la red y con menos
	# hueco sin proxy. Sigue sin --build: traefik:v3.6 viene del registro.
	log "recreando Traefik (breve corte del proxy)"
	run_logged docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d --force-recreate \
		|| die "$EX_BUILD" "no se pudo levantar Traefik"
	verify_container traefik 60
}

# Fuente unica de verdad de las bases: salen del registro, no de una lista hardcodeada ni del
# init/ de postgres, que eran dos fuentes que se desincronizaban entre si.
#
# Solo la invoca el subcomando 'infra': machaca las globales APP_* al recargar el registro.
infra_databases() {
	local slug
	for slug in $(registry_slugs); do
		registry_load "$slug"
		if [ "$APP_ENABLED" != "1" ] || [ -z "$APP_DB" ]; then continue; fi
		# if/else y no `db_exists ... && { ...; continue; }`: un && falso como ultima sentencia
		# del cuerpo de un bucle aborta el script bajo `set -e`.
		if db_exists "$APP_DB"; then
			ok "base '$APP_DB' ($slug) ya existe"
		else
			db_create "$APP_DB"
		fi
	done
	registry_reset
}
