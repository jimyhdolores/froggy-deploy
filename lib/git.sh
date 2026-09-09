# shellcheck shell=bash
# Actualizacion del codigo antes de construir.
#
# Esto es lo que NINGUN script antiguo hacia: ni una mencion a git en los ocho .sh. El flujo
# real era entrar por SSH, hacer `git pull` a mano y lanzar el script. Si alguien se olvidaba
# del pull, el "despliegue" reconstruia el commit que ya estaba en disco y reportaba exito.
[ -n "${_GIT_SH:-}" ] && return 0
_GIT_SH=1

git_head() { git -C "$1" rev-parse --short HEAD 2>/dev/null || printf 'desconocido'; }

# Deja SHA_BEFORE y SHA_AFTER en el ambito global. Se llama UNA vez por app: backend y
# frontend comparten el mismo arbol de trabajo.
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
		ok "clonado en $SHA_AFTER"
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
		warn "--no-pull: se reconstruye el commit que ya esta en disco ($SHA_BEFORE)"
		SHA_AFTER="$SHA_BEFORE"
		return 0
	fi

	run git -C "$dest" fetch --prune --tags origin \
		|| die "$EX_GIT" "'git fetch' de $APP_DIR fallo (revisa red y credenciales)"

	# --ff-only y NO `git pull`: si el servidor tiene commits propios queremos un fallo
	# ruidoso, no un merge automatico generado por un script de despliegue.
	if [ "${DRY_RUN:-0}" != "1" ]; then
		if ! git -C "$dest" merge --ff-only "origin/$branch"; then
			die "$EX_GIT" "$APP_DIR ha divergido de origin/$branch: el fast-forward es imposible.
    Resuelvelo a mano antes de desplegar."
		fi
	fi

	SHA_AFTER="$(git_head "$dest")"
	if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then
		log "codigo: $SHA_AFTER (sin cambios respecto al despliegue anterior)"
	else
		count="$(git -C "$dest" rev-list --count "$SHA_BEFORE..$SHA_AFTER" 2>/dev/null || printf '?')"
		ok "codigo: $SHA_BEFORE -> $SHA_AFTER (+$count commits)"
		git -C "$dest" log --oneline "$SHA_BEFORE..$SHA_AFTER" 2>/dev/null | head -10 | sed 's/^/    /' || true
	fi
}
