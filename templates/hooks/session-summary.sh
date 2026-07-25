#!/usr/bin/env bash
# session-summary.sh: al cerrar la sesión, escribe en prosa legible lo que el
# harness DECIDIÓ, sacado del ledger y de nada más.
#
# POR QUÉ ES DETERMINISTA: el resumen sale de .harness/events.jsonl, no del
# modelo. Un resumen que el agente redacta de memoria omite justo lo que el
# humano necesita auditar (el gate que se saltó, el supuesto que nadie
# confirmó) porque el que resume es el mismo que decidió. El ledger no tiene
# esa cortesía: si no pasó, no está; si pasó, está.
#
# LEY DE ESTE HOOK: es un OBSERVADOR, como ui-emit.sh. Fail-OPEN, sale 0
# pase lo que pase, jamás bloquea el cierre de una sesión. Un resumen que
# puede colgar la salida es un bug, no una feature.
#
# Se registra en SessionEnd. Escribe .harness/sessions/<session>.md y lo
# repite en stdout.
set -u

exit_ok() { exit 0; }
trap exit_ok EXIT

WS="${CLAUDE_PROJECT_DIR:-$PWD}"
BUS="$WS/.harness/events.jsonl"
OUT_DIR="$WS/.harness/sessions"

command -v jq >/dev/null 2>&1 || exit 0
[ -s "$BUS" ] || exit 0

payload="$(cat 2>/dev/null)"
[ -n "$payload" ] || exit 0
session="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"
[ -n "$session" ] || exit 0

# EL BUS ES COMPARTIDO. En este workspace corren varias sesiones de Claude
# Code a la vez sobre el mismo .harness/events.jsonl, así que "lo que pasó en
# esta sesión" NO es "lo que pasó en esta ventana de tiempo": con diez
# sesiones abiertas, esa cuenta le atribuye a cada una el trabajo de las
# otras. La atribución va por dos caminos según el emisor:
#
#   · ui-emit.sh (tool, prompt, stop, subagent-*) trae .session → por id.
#   · emit.sh (gate, phase, decision, assumption, ship, deploy) NO lo trae:
#     lo escriben scripts fuera de Claude Code, que no conocen la sesión.
#     Se atribuyen por TAREA, y solo entran las tareas que ESTA sesión tocó.
#
# Límite honesto y declarado en el pie del resumen: si dos sesiones trabajan
# la MISMA tarea, sus eventos de harness aparecen en los dos resúmenes. Sin
# propagar el id de sesión hasta emit.sh no hay forma de separarlos, y un
# archivo global de "sesión actual" es justo el estado compartido que
# ui-emit.sh evita a propósito (se pisa entre sesiones).
bus_cat() {  # el bus rotado primero: la rotación no debe dejar un hueco
  [ -f "$BUS.1" ] && cat "$BUS.1" 2>/dev/null
  cat "$BUS" 2>/dev/null
}

mine="$(bus_cat | jq -c --arg s "$session" 'select(.session == $s)' 2>/dev/null)"
[ -n "$mine" ] || exit 0
since="$(printf '%s' "$mine" | jq -r '.ts' 2>/dev/null | sort | head -1)"
[ -n "$since" ] || exit 0
mytasks="$(printf '%s' "$mine" | jq -sc '[.[] | .task // "" | select(. != "")] | unique' 2>/dev/null)"
[ -n "$mytasks" ] || mytasks='[]'

events="$(bus_cat | jq -c --arg s "$session" --arg since "$since" --argjson mine "$mytasks" '
  select(.ts >= $since)
  | select(if (.session // "") != "" then .session == $s
           else (.task // "") as $t
                | ($t != "" and (($mine | index($t)) != null)) end)' 2>/dev/null)"
[ -n "$events" ] || exit 0

# Duración legible. El parseo de fecha difiere entre BSD y GNU; si ninguno
# puede, el resumen sale igual y solo se calla la duración.
epoch() {
  date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null \
    || date -d "$1" +%s 2>/dev/null || echo ""
}
last="$(printf '%s' "$events" | jq -r '.ts' | sort | tail -1)"
dur=""
a="$(epoch "$since")"; b="$(epoch "$last")"
if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -ge "$a" ] 2>/dev/null; then
  mins=$(( (b - a) / 60 ))
  if [ "$mins" -ge 60 ]; then dur="$((mins / 60))h $((mins % 60))m"; else dur="${mins}m"; fi
fi

mkdir -p "$OUT_DIR" 2>/dev/null || exit 0
OUT="$OUT_DIR/$session.md"

# ok llega como booleano (emit.sh, --argjson) o como string (ui-emit.sh,
# tostring). Normalizar a texto evita que un gate rojo se cuente como verde.
count() { printf '%s' "$events" | jq -r --arg k "$1" 'select(.kind == $k) | .kind' | wc -l | tr -d ' '; }
red() { printf '%s' "$events" | jq -r 'select(.kind == "gate") | select((.ok|tostring) == "false") | .kind' | wc -l | tr -d ' '; }

tasks="$(printf '%s' "$events" | jq -r '.task // "" | select(. != "")' | sort -u | tr '\n' ' ' | sed 's/ $//')"
gates="$(count gate)"; gates_red="$(red)"
decisions="$(count decision)"; assumptions="$(count assumption)"
stops="$(count stop)"; ships="$(count ship)"; deploys="$(count deploy)"

# El bloque de una sección: título y viñetas, o nada si no hubo eventos.
section() {  # section <título> <kind> [solo-rojos]
  local title="$1" kind="$2" only_red="${3:-}" body
  if [ -n "$only_red" ]; then
    body="$(printf '%s' "$events" | jq -r --arg k "$kind" '
      select(.kind == $k) | select((.ok|tostring) == "false")
      | "- " + (if (.task // "") != "" then "[" + .task + "] " else "" end) + (.summary // "(sin detalle)")')"
  else
    body="$(printf '%s' "$events" | jq -r --arg k "$kind" '
      select(.kind == $k)
      | "- " + (if (.task // "") != "" then "[" + .task + "] " else "" end) + (.summary // "(sin detalle)")')"
  fi
  [ -n "$body" ] || return 0
  printf '\n## %s\n%s\n' "$title" "$body"
}

{
  printf '# Sesión %s\n\n' "${session:0:8}"
  printf 'Del %s al %s' "$since" "$last"
  [ -n "$dur" ] && printf ' (%s)' "$dur"
  printf '.\n'
  [ -n "$tasks" ] && printf 'Tareas tocadas: %s.\n' "$tasks"

  printf '\n## En una línea\n'
  if [ "$gates" -gt 0 ]; then
    printf -- '- Gates: %s, de los cuales %s en rojo.\n' "$gates" "$gates_red"
  fi
  [ "$ships" -gt 0 ] && printf -- '- Ships: %s.\n' "$ships"
  [ "$deploys" -gt 0 ] && printf -- '- Deploys: %s.\n' "$deploys"
  [ "$decisions" -gt 0 ] && printf -- '- Decisiones registradas: %s.\n' "$decisions"
  [ "$assumptions" -gt 0 ] && printf -- '- Supuestos sin confirmar: %s.\n' "$assumptions"
  if [ "$stops" -gt 0 ]; then
    printf -- '- PARADAS: %s. La sesión terminó esperando a un humano.\n' "$stops"
  fi
  if [ "$gates$ships$deploys$decisions$assumptions$stops" = "000000" ]; then
    printf -- '- El harness no registró decisiones en esta sesión.\n'
  fi

  section "Supuestos (audita esto primero)" assumption
  section "Paradas" stop
  section "Gates en rojo" gate rojos
  section "Decisiones" decision
  section "Cambios de fase" phase
  section "Ships" ship
  section "Deploys" deploy

  printf '\nFuente: .harness/events.jsonl. Este resumen sale del ledger, no de\n'
  printf 'la memoria del agente: lo que no se emitió, no aparece.\n'
  printf 'El bus es compartido con las demás sesiones del workspace: los eventos\n'
  printf 'de Claude Code se filtran por id de sesión y los del harness (gates,\n'
  printf 'fases, supuestos) por tarea. Dos sesiones sobre la MISMA tarea comparten\n'
  printf 'esos eventos en ambos resúmenes.\n'
} > "$OUT" 2>/dev/null || exit 0

cat "$OUT" 2>/dev/null
exit 0
