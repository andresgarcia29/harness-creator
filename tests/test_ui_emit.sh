#!/usr/bin/env bash
# test_ui_emit.sh: el bus del panel (ui-emit.sh).
# Lo que se protege aquí es el par tool-start / tool, que es lo que le permite
# al watchdog distinguir "no está trabajando" de "está trabajando en algo
# lento". Sin el evento de arranque, un gate de navegador (una sola llamada
# bloqueante de 9 a 10 minutos) se ve idéntico a un agente colgado, y el
# watchdog mata a uno sano y lo relanza con el modelo de escalación, que es el
# caro. Pasó en campo con un QA corriendo WebKit.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

HOOK="$ROOT/templates/hooks/ui-emit.sh"
BUS="$WS/.harness/events.jsonl"
mkdir -p "$WS/worktrees/T1/atlas"

fire() {  # fire <kind> <json-de-tool_input> [tool]
  jq -nc --arg t "${3:-Bash}" --argjson i "$2" --arg c "$WS/worktrees/T1/atlas" \
     '{tool_name:$t, tool_input:$i, session_id:"sess-1", cwd:$c,
       tool_response:{success:true}}' \
    | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" "$1"
}
bus() { cat "$BUS" 2>/dev/null; }

echo "── tool-start: el bus dice cuándo ARRANCA una llamada, no solo cuándo termina"

fire tool-start '{"command":"npx playwright test --project=webkit"}'
assert_contains "$(bus)" '"kind":"tool-start"' "emite el evento de arranque"
assert_contains "$(bus)" "playwright test" "guarda qué comando arrancó"
assert_contains "$(bus)" '"task":"T1"' "deriva la tarea del cwd, como el resto del bus"
assert_contains "$(bus)" '"session":"sess-1"' "etiqueta la sesión (el bus es compartido)"

# El par completo: con el cierre presente, la llamada YA no está en vuelo.
fire tool '{"command":"npx playwright test --project=webkit"}'
starts=$(bus | jq -s '[.[] | select(.kind=="tool-start")] | length')
ends=$(bus | jq -s '[.[] | select(.kind=="tool")] | length')
assert_eq "$starts" "$ends" "arranque y cierre quedan pareados (así se ve una llamada terminada)"

echo
echo "── una llamada en vuelo se distingue de un agente atascado"

: > "$BUS"
fire tool-start '{"command":"npx playwright test --project=webkit"}'
inflight=$(bus | jq -s '[.[] | select(.kind=="tool-start")] | length')
closed=$(bus | jq -s '[.[] | select(.kind=="tool")] | length')
assert_eq 1 "$inflight" "hay un arranque"
assert_eq 0 "$closed" "y ningún cierre: la llamada sigue corriendo"
[ "$inflight" -gt "$closed" ] \
  && pass "el watchdog puede ver que hay trabajo EN VUELO y no matar a un sano" \
  || fail "sin este par, un gate de navegador se ve igual que un atasco"

echo
echo "── leyes del bus: redacta y jamás bloquea"

: > "$BUS"
fire tool-start '{"command":"deploy --token ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
assert_contains "$(bus)" "REDACTADO" "redacta secretos ANTES de tocar disco"
assert_not_contains "$(bus)" "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "el token no llega al bus"

printf 'no soy json' | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" tool-start >/dev/null 2>&1
assert_eq 0 $? "payload corrupto: sale 0 (observa, jamás bloquea)"
printf '' | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" tool-start >/dev/null 2>&1
assert_eq 0 $? "payload vacío: sale 0"
fire kind-inventado '{"command":"x"}' >/dev/null 2>&1
assert_eq 0 $? "kind desconocido: sale 0 sin escribir basura"

t_done
