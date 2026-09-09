# shellcheck shell=bash
# PostgreSQL compartido: espera, creacion de bases y bootstrap de esquemas.
[ -n "${_DB_SH:-}" ] && return 0
_DB_SH=1

PG_CONTAINER="${PG_CONTAINER:-postgres_shared}"
PG_USER="${PG_USER:-postgres}"

db_wait_ready() {
	local tries="${1:-30}"
	[ "${DRY_RUN:-0}" = "1" ] && return 0
	log "esperando a que $PG_CONTAINER acepte conexiones..."
	while ! docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" >/dev/null 2>&1; do
		tries=$((tries - 1))
		if [ "$tries" -le 0 ]; then
			die "$EX_DB" "PostgreSQL no respondio. Revisa: docker logs $PG_CONTAINER"
		fi
		sleep 2
	done
	ok "PostgreSQL listo"
}

db_exists() {                                   # $1 = nombre de base
	local out
	# setup.sh hacia `EXISTS=$(docker exec ... 2>/dev/null)`. Bajo `set -e` eso ABORTA el
	# script si docker falla, y con stderr suprimido aborta sin explicar nada. Aqui el fallo
	# de docker se distingue explicitamente de "la base no existe".
	if ! out="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -tAc \
		"SELECT 1 FROM pg_database WHERE datname = '$1'")"; then
		die "$EX_DB" "no se pudo consultar PostgreSQL en $PG_CONTAINER"
	fi
	[ "$(printf '%s' "$out" | tr -d '[:space:]')" = "1" ]
}

db_create() {
	log "creando base de datos '$1'"
	run docker exec "$PG_CONTAINER" psql -U "$PG_USER" -c "CREATE DATABASE \"$1\";" \
		|| die "$EX_DB" "no se pudo crear la base '$1'"
	ok "base '$1' creada"
}

# Define DB_CREATED. Se llama DESPUES de git_ensure_repo: el .sql de bootstrap vive dentro
# del repositorio de la app, asi que tiene que estar ya actualizado.
db_ensure() {
	DB_CREATED=0
	if [ -z "$APP_DB" ]; then
		log "'$APP_SLUG' no declara base de datos"
		return 0
	fi
	db_wait_ready
	if [ "${DRY_RUN:-0}" = "1" ]; then log "DRY-RUN  asegurar base '$APP_DB'"; return 0; fi
	if db_exists "$APP_DB"; then
		ok "base '$APP_DB' ya existe"
	else
		db_create "$APP_DB"
		DB_CREATED=1
	fi
	db_bootstrap_if_needed
}

# El bootstrap no es una operacion repetible: es una operacion de UNA SOLA VEZ. La
# idempotencia se consigue no repitiendola, no haciendola reentrante.
db_bootstrap_if_needed() {
	[ -n "$APP_DB_BOOTSTRAP_SQL" ] || return 0
	local sql="$APPS_DIR/$APP_DIR/$APP_DB_BOOTSTRAP_SQL" schemas

	# BARRERA 1 - solo en la misma invocacion que creo la base.
	if [ "$DB_CREATED" != "1" ] && [ "${FORCE_BOOTSTRAP:-0}" != "1" ]; then
		log "bootstrap SQL omitido: '$APP_DB' ya existia (fuerzalo con --bootstrap-db)"
		return 0
	fi
	[ -f "$sql" ] || die "$EX_DB" "el registro declara APP_DB_BOOTSTRAP_SQL pero no existe $sql"

	# BARRERA 2 - la base tiene que estar vacia de esquemas de usuario.
	# init-glowpe-db.sql empieza con DROP SCHEMA "tenant"/"finance" CASCADE. Sobre una base ya
	# provisionada eso arrastra las claves foraneas de los esquemas de tenant y deja la base
	# mutilada devolviendo exito. El propio .sql tiene su salvaguarda (RAISE EXCEPTION salvo
	# force_reset); esta es la segunda, del lado del despliegue.
	if ! schemas="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$APP_DB" -tAc \
		"SELECT count(*) FROM pg_namespace
		  WHERE nspname NOT LIKE 'pg\\_%'
		    AND nspname NOT IN ('information_schema', 'public')")"; then
		die "$EX_DB" "no se pudieron inspeccionar los esquemas de '$APP_DB'"
	fi
	schemas="$(printf '%s' "$schemas" | tr -d '[:space:]')"
	if [ "$schemas" != "0" ]; then
		warn "'$APP_DB' ya tiene $schemas esquemas de usuario: NO se ejecuta el bootstrap SQL."
		warn "Una reconstruccion deliberada es una operacion MANUAL, no de despliegue:"
		warn "  PGOPTIONS=\"-c ${APP_SLUG}.force_reset=yes\" psql -v ON_ERROR_STOP=1 -f <sql>"
		return 0
	fi

	log "ejecutando bootstrap SQL de '$APP_SLUG' sobre '$APP_DB'"
	# Por stdin: el .sql no tiene metacomandos \i ni COPY, asi que no hace falta docker cp.
	# ON_ERROR_STOP=1 es OBLIGATORIO: sin el, psql sale con 0 aunque fallen todas las sentencias.
	if ! docker exec -i "$PG_CONTAINER" \
		psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$APP_DB" <"$sql" >>"$LOG_FILE" 2>&1; then
		tail -30 "$LOG_FILE" | sed 's/^/    /' >&2
		die "$EX_DB" "el bootstrap SQL de '$APP_SLUG' fallo (traza arriba y en $LOG_FILE)"
	fi
	ok "esquemas globales de '$APP_DB' creados"
}
