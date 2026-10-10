# shellcheck shell=bash
# Actualizacion del codigo antes de construir.
#
# Esto es lo que NINGUN script antiguo hacia: ni una mencion a git en los ocho .sh. El flujo
# real era entrar por SSH, hacer `git pull` a mano y lanzar el script. Si alguien se olvidaba
# del pull, el "despliegue" reconstruia el commit que ya estaba en disco y reportaba exito.
[ -n "${_GIT_SH:-}" ] && return 0
_GIT_SH=1

git_head() { git -C "$1" rev-parse --short HEAD 2>/dev/null || printf 'desconocido'; }

# El SHA completo: es la etiqueta con la que GitHub Actions publica las imagenes, asi que la forma
# corta, de longitud variable, no sirve para buscarlas.
git_full_head() { git -C "$1" rev-parse HEAD 2>/dev/null || printf ''; }

# --tag <ref>: el SHA completo de un commit YA publicado en origin/<rama>, sin mover el checkout.
# Admite la forma corta, que es la que aparece en los logs y en el historial.
git_resolve_published() {                       # $1 = ref -> imprime el SHA completo
	local dest="$APPS_DIR/$APP_DIR" ref="$1" branch="${BRANCH_OVERRIDE:-$APP_BRANCH}" sha
	run git -C "$dest" fetch --prune --tags origin >&2 \
		|| die "$EX_GIT" "'git fetch' de $APP_DIR fallo (revisa red y credenciales)"
	sha="$(git -C "$dest" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null)" \
		|| die "$EX_USAGE" "--tag: '$ref' no es un commit de $APP_DIR"
	git -C "$dest" merge-base --is-ancestor "$sha" "origin/$branch" 2>/dev/null \
		|| die "$EX_USAGE" "--tag: $ref no esta en origin/$branch, y solo los commits de esa rama tienen imagen publicada"
	printf '%s\n' "$sha"
}

# Deja SHA_BEFORE, SHA_AFTER (cortos, para el resumen) y SHA_FULL en el ambito global. Se llama
# UNA vez por app: backend y frontend comparten el mismo arbol de trabajo.
#
# Con TARGET_SHA (el despliegue automatico) avanza exactamente hasta ese commit y no hasta la punta
# de la rama: el compose y los scripts del checkout tienen que ser los de la imagen que se despliega.
# Si el checkout ya esta por delante de el, otro despliegue mas nuevo llego antes: STALE=1 y nada
# que hacer.
git_ensure_repo() {
	local dest="$APPS_DIR/$APP_DIR"
	local branch="${BRANCH_OVERRIDE:-$APP_BRANCH}"
	local current dirty count

	# --- caso 1: no existe -> clonar ------------------------------------------------------
	if [ ! -d "$dest/.git" ]; then
		if [ -e "$dest" ]; then
			die "$EX_GIT" "$dest existe pero no es un repositorio git. Muevelo o borralo a mano."
		fi
		log "clonando $APP_REPO -> $dest (rama $branch)"
		# El destino va EXPLICITO: sin el, `git clone .../app-glowpe.git` crearia app-glowpe/
		# y el registro (APP_DIR=glowpe) apuntaria a la nada.
		run git clone --branch "$branch" "$APP_REPO" "$dest" \
			|| die "$EX_GIT" "el clone de $APP_REPO fallo"
		SHA_BEFORE=""
		SHA_AFTER="$(git_head "$dest")"
		SHA_FULL="$(git_full_head "$dest")"
		ok "clonado en $SHA_AFTER"
		# Un clon recien hecho queda en la punta de la rama. Si el CI pidio un commit anterior,
		# la ejecucion de la punta ya lo cubre: este queda obsoleto.
		if [ -n "${TARGET_SHA:-}" ] && [ "${DRY_RUN:-0}" != "1" ] && [ "$TARGET_SHA" != "$SHA_FULL" ]; then
			STALE=1
		fi
		return 0
	fi

	SHA_BEFORE="$(git_head "$dest")"

	# --- caso 2: rama distinta de la declarada -> abortar ---------------------------------
	current="$(git -C "$dest" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'DETACHED')"
	if [ "$current" != "$branch" ]; then
		die "$EX_GIT" "$APP_DIR esta en la rama '$current' y el registro espera '$branch'.
    Opciones: corregir APP_BRANCH en $(registry_file "$APP_SLUG"),
              repetir con --branch $current,
              o cambiar de rama en el servidor a mano."
	fi

	# --- caso 3: arbol sucio -> mostrar QUE, y abortar ------------------------------------
	# `dirty=$(git ...)` a secas ABORTA bajo `set -e` si git falla, y con 2>/dev/null aborta
	# ademas en silencio: es exactamente el bug que tenia setup.sh en su linea 59. De ahi el
	# `if !` explicito, que distingue "git fallo" de "no hay cambios".
	if ! dirty="$(git -C "$dest" status --porcelain)"; then
		die "$EX_GIT" "'git status' fallo en $dest"
	fi
	if [ -n "$dirty" ]; then
		printf '%s\n' "$dirty" | sed 's/^/    /' >&2
		die "$EX_GIT" "$APP_DIR tiene cambios locales sin commitear (arriba).
    El despliegue no los toca. Revisalos en el servidor y decide: 'git stash' o 'git commit'
    para conservarlos, 'git reset --hard' para descartarlos."
	fi

	# --- caso 4: --no-pull -> desplegar lo que hay, pero DECIRLO --------------------------
	if [ "${NO_PULL:-0}" = "1" ]; then
		warn "--no-pull: se despliega el commit que ya esta en disco ($SHA_BEFORE)"
		SHA_AFTER="$SHA_BEFORE"
		SHA_FULL="$(git_full_head "$dest")"
		return 0
	fi

	run git -C "$dest" fetch --prune --tags origin \
		|| die "$EX_GIT" "'git fetch' de $APP_DIR fallo (revisa red y credenciales)"

	# --ff-only y NO `git pull`: si el servidor tiene commits propios queremos un fallo
	# ruidoso, no un merge automatico generado por un script de despliegue.
	if [ "${DRY_RUN:-0}" != "1" ]; then
		local target="origin/$branch"
		if [ -n "${TARGET_SHA:-}" ]; then
			# El SHA llega de fuera (del CI). Tiene que ser de la rama desplegada: `fetch` trae
			# todas, y un ff-only a un commit de otra rama moveria el checkout fuera de ella.
			git -C "$dest" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null \
				|| die "$EX_GIT" "el commit $TARGET_SHA no existe en origin"
			git -C "$dest" merge-base --is-ancestor "$TARGET_SHA" "origin/$branch" \
				|| die "$EX_GIT" "$TARGET_SHA no esta en origin/$branch"
			if [ "$TARGET_SHA" != "$(git_full_head "$dest")" ] \
				&& git -C "$dest" merge-base --is-ancestor "$TARGET_SHA" HEAD; then
				STALE=1
				SHA_AFTER="$SHA_BEFORE"
				SHA_FULL="$(git_full_head "$dest")"
				return 0
			fi
			target="$TARGET_SHA"
		fi
		if ! git -C "$dest" merge --ff-only "$target"; then
			die "$EX_GIT" "$APP_DIR ha divergido de origin/$branch: el fast-forward es imposible.
    Resuelvelo a mano antes de desplegar."
		fi
	fi

	SHA_FULL="$(git_full_head "$dest")"
	SHA_AFTER="$(git_head "$dest")"
	if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then
		log "codigo: $SHA_AFTER (sin cambios respecto al despliegue anterior)"
	else
		count="$(git -C "$dest" rev-list --count "$SHA_BEFORE..$SHA_AFTER" 2>/dev/null || printf '?')"
		ok "codigo: $SHA_BEFORE -> $SHA_AFTER (+$count commits)"
		git -C "$dest" log --oneline "$SHA_BEFORE..$SHA_AFTER" 2>/dev/null | head -10 | sed 's/^/    /' || true
	fi
}
