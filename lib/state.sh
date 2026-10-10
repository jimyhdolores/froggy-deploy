# shellcheck shell=bash
# Estado de cada app en ESTE servidor: la pausa del despliegue automatico y el historial de los
# despliegues en modo registro. Vive en state/, que git ignora: no es configuracion, es lo que ha
# pasado aqui.
[ -n "${_STATE_SH:-}" ] && return 0
_STATE_SH=1

STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/state}"

state_pause_file()   { printf '%s/%s.paused\n' "$STATE_DIR" "$1"; }
state_history_file() { printf '%s/%s.history\n' "$STATE_DIR" "$1"; }

# --- Pausa ------------------------------------------------------------------------------------
# Detiene SOLO el despliegue automatico (--auto); los manuales siguen funcionando. La ponen las
# operaciones que dejan produccion a proposito en un estado que el siguiente push desharia: una
# vuelta atras (a mano con --tag o la automatica), una ventana de migracion preparada (--pull-only)
# o a medias (--allow-drift). La quita un despliegue manual completo y sano, o --resume.
state_pause() {                                 # $1=slug $2=motivo
	if [ "${DRY_RUN:-0}" = "1" ]; then
		log "DRY-RUN  pausar el despliegue automatico de $1: $2"
		return 0
	fi
	mkdir -p "$STATE_DIR"
	printf '%s  %s\n' "$(_ts)" "$2" >"$(state_pause_file "$1")"
	warn "despliegue automatico de $1 EN PAUSA: $2. Lo reanuda un 'deploy $1' manual completo, o 'deploy $1 --resume'"
}

state_resume() {                                # $1=slug
	local file
	file="$(state_pause_file "$1")"
	[ -f "$file" ] || return 0
	if [ "${DRY_RUN:-0}" = "1" ]; then
		log "DRY-RUN  reanudar el despliegue automatico de $1"
		return 0
	fi
	rm -f "$file"
	ok "despliegue automatico de $1 reanudado"
}

state_paused_reason() {                         # $1=slug -> imprime el motivo; devuelve 1 sin pausa
	local file
	file="$(state_pause_file "$1")"
	[ -f "$file" ] || return 1
	cat "$file"
}

# --- Historial --------------------------------------------------------------------------------
# Una linea por tier desplegado: fecha, modo, tier, commit anterior, commit nuevo y resultado,
# separados por tabuladores. Es lo que hay que mirar para una vuelta atras con --tag.
state_history_add() {                           # $1=slug $2=modo $3=tier $4=desde $5=hasta $6=resultado
	[ "${DRY_RUN:-0}" = "1" ] && return 0
	mkdir -p "$STATE_DIR"
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(_ts)" "$2" "$3" "${4:--}" "${5:--}" "$6" \
		>>"$(state_history_file "$1")" 2>/dev/null || true
}

state_history_show() {                          # $1=slug
	local file
	file="$(state_history_file "$1")"
	if [ ! -s "$file" ]; then
		log "$1 aun no tiene historial de despliegues en modo registro"
		return 0
	fi
	printf '%-20s  %-7s  %-9s  %-12s  %-12s  %s\n' FECHA MODO TIER DESDE HASTA RESULTADO
	tail -n "${HISTORY_LINES:-20}" "$file" \
		| awk -F'\t' '{ printf "%-20s  %-7s  %-9s  %-12s  %-12s  %s\n", $1, $2, $3, substr($4, 1, 12), substr($5, 1, 12), $6 }'
	if state_paused_reason "$1" >/dev/null; then
		printf '\nEN PAUSA: %s\n' "$(state_paused_reason "$1")"
	fi
}
