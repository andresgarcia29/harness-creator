#!/usr/bin/env bash
# test_session_summary.sh: el hook de fin de sesión, contra el ledger real.
# Lo que se protege:
#   · el resumen sale del ledger, no del modelo: si un gate rojo está en
#     events.jsonl, TIENE que aparecer, lo diga o no el agente.
#   · acota por sesión: no arrastra los eventos de la sesión anterior.
#   · incluye los eventos de emit.sh, que NO llevan campo session (se acotan
#     por tiempo). Si esto se rompe, el resumen pierde justo las decisiones
#     del harness y queda como una lista de tools, que es inútil.
#   · fail-OPEN: sale 0 con el bus vacío, roto o ausente.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

HOOK="$ROOT/templates/hooks/session-summary.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null

BUS="$WS/.harness/events.jsonl"
mkdir -p "$WS/.harness"

run_hook() {  # run_hook <session-id>: alimenta el payload del hook por stdin
  ( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" \
      printf '{"session_id":"%s","cwd":"%s","reason":"exit"}' "$1" "$WS" \
      | bash "$HOOK" 2>/dev/null )
}

echo "── el resumen sale del ledger, no de la memoria del agente"

# Sesión previa (no debe aparecer) + sesión actual con los dos esquemas:
# ui-emit.sh (con .session) y emit.sh (sin .session, se acota por tiempo).
cat > "$BUS" <<'JSONL'
{"ts":"2026-07-24T09:00:00Z","kind":"gate","task":"T0","actor":"harness","summary":"gate de una sesion vieja","ok":false}
{"ts":"2026-07-24T10:00:00Z","kind":"prompt","task":"","session":"sess-actual","agent":"main","summary":"arranca"}
{"ts":"2026-07-24T10:05:00Z","kind":"phase","task":"T1","actor":"orchestrator","summary":"implement to review"}
{"ts":"2026-07-24T10:10:00Z","kind":"gate","task":"T1","actor":"harness","summary":"veredicto de review: qa=pending","ok":false}
{"ts":"2026-07-24T10:12:00Z","kind":"gate","task":"T1","actor":"harness","summary":"tests verdes","ok":true}
{"ts":"2026-07-24T10:20:00Z","kind":"assumption","task":"T1","actor":"implementer","summary":"asumi que el endpoint acepta null"}
{"ts":"2026-07-24T10:30:00Z","kind":"decision","task":"T1","actor":"architect","summary":"se parte el servicio en dos"}
{"ts":"2026-07-24T10:40:00Z","kind":"stop","task":"T1","actor":"harness","summary":"espero al humano por ADR-42"}
{"ts":"2026-07-24T11:30:00Z","kind":"tool","task":"T1","session":"sess-actual","agent":"main","tool":"Bash","summary":"ls","ok":"true"}
JSONL

out="$(run_hook sess-actual)"

assert_contains "$out" "qa=pending" "el gate rojo aparece (es lo que el humano necesita ver)"
assert_contains "$out" "Supuestos (audita esto primero)" "los supuestos van primero, antes que nada"
assert_contains "$out" "endpoint acepta null" "el supuesto sin confirmar aparece"
assert_contains "$out" "espero al humano" "la parada aparece"
assert_contains "$out" "se parte el servicio" "la decisión aparece"
assert_contains "$out" "T1" "etiqueta la tarea"
assert_not_contains "$out" "sesion vieja" "NO arrastra eventos de la sesión anterior"

# Los eventos de emit.sh no llevan .session: si el hook filtrara por sesión en
# vez de por tiempo, este bloque entero desaparecería y el resumen sería inútil.
assert_contains "$out" "Cambios de fase" "incluye eventos de emit.sh (sin campo session)"
assert_contains "$out" "Gates: 2, de los cuales 1 en rojo" "cuenta gates rojos y verdes por separado"
assert_contains "$out" "PARADAS: 1" "la parada se cuenta en el encabezado"
assert_contains "$out" "1h 30m" "calcula la duración de la sesión"

echo
echo "── bus compartido: 10 sesiones sobre el mismo .harness/"
# Bug de campo (introducido y cazado el mismo día): la ventana se acotaba solo
# por TIEMPO, así que el resumen de una sesión reclamaba los gates, supuestos y
# paradas de las otras nueve. "Lo que pasó en esta sesión" no es "lo que pasó
# en esta ventana" cuando el bus es compartido.
cat > "$BUS" <<'JSONL'
{"ts":"2026-07-24T10:00:00Z","kind":"prompt","task":"","session":"sess-A","agent":"main","summary":"arranca A"}
{"ts":"2026-07-24T10:01:00Z","kind":"prompt","task":"","session":"sess-B","agent":"main","summary":"arranca B"}
{"ts":"2026-07-24T10:02:00Z","kind":"tool","task":"T-A","session":"sess-A","agent":"main","tool":"Bash","summary":"cosa de A","ok":"true"}
{"ts":"2026-07-24T10:03:00Z","kind":"tool","task":"T-B","session":"sess-B","agent":"main","tool":"Bash","summary":"cosa de B","ok":"true"}
{"ts":"2026-07-24T10:05:00Z","kind":"gate","task":"T-A","actor":"harness","summary":"gate rojo de la tarea A","ok":false}
{"ts":"2026-07-24T10:06:00Z","kind":"gate","task":"T-B","actor":"harness","summary":"gate rojo de la tarea B","ok":false}
{"ts":"2026-07-24T10:07:00Z","kind":"assumption","task":"T-B","actor":"impl","summary":"supuesto que es de B"}
{"ts":"2026-07-24T10:08:00Z","kind":"stop","task":"T-B","actor":"harness","summary":"parada de B"}
JSONL

out="$(run_hook sess-A)"
assert_contains "$out" "gate rojo de la tarea A" "sesión A: ve su propio gate"
assert_not_contains "$out" "tarea B" "sesión A: NO reclama el gate de B"
assert_not_contains "$out" "supuesto que es de B" "sesión A: NO reclama el supuesto de B"
assert_not_contains "$out" "parada de B" "sesión A: NO reclama la parada de B"
assert_not_contains "$out" "T-B" "sesión A: no lista la tarea de B como tocada"
assert_contains "$out" "Gates: 1" "sesión A: cuenta solo sus gates"

out="$(run_hook sess-B)"
assert_contains "$out" "tarea B" "sesión B: ve su propio gate"
assert_contains "$out" "parada de B" "sesión B: ve su propia parada"
assert_not_contains "$out" "tarea A" "sesión B: NO reclama el gate de A"

# Una sesión que no tocó ninguna tarea no puede adoptar eventos de harness
# ajenos: sin tarea no hay atribución posible, y el silencio es la respuesta
# honesta.
printf '{"ts":"2026-07-24T10:09:00Z","kind":"prompt","task":"","session":"sess-C","agent":"main","summary":"solo pregunta"}\n' >> "$BUS"
out="$(run_hook sess-C)"
assert_contains "$out" "no registró decisiones" "sesión sin tarea: no adopta eventos ajenos"
assert_not_contains "$out" "tarea A" "sesión sin tarea: no reclama nada de A"

# La rotación del bus (5 MB) no debe dejar un hueco en el resumen: con diez
# sesiones escribiendo, rotar a mitad de sesión es mucho más probable.
mv "$BUS" "$BUS.1"
printf '{"ts":"2026-07-24T10:30:00Z","kind":"gate","task":"T-A","actor":"harness","summary":"gate posterior a la rotacion","ok":false}\n' > "$BUS"
out="$(run_hook sess-A)"
assert_contains "$out" "gate rojo de la tarea A" "rotación: sigue viendo lo anterior (bus .1)"
assert_contains "$out" "posterior a la rotacion" "rotación: y también lo nuevo"
rm -f "$BUS.1"

echo
echo "── persistencia y fail-open"

assert_file "$WS/.harness/sessions/sess-actual.md" "escribe .harness/sessions/<id>.md"

# El puntero de tarea de track-read.sh muere con su sesión: si no, se acumula
# uno por sesión para siempre.
mkdir -p "$WS/.harness/session-task"
touch "$WS/.harness/session-task/sess-actual" "$WS/.harness/session-task/sess-otra"
run_hook sess-actual >/dev/null 2>&1
assert_no_file "$WS/.harness/session-task/sess-actual" "borra SU puntero de tarea al cerrar"
assert_file "$WS/.harness/session-task/sess-otra" "no toca el puntero de las otras sesiones"

# Y lo borra aunque no haya resumen que escribir (el bus vacío sale temprano).
touch "$WS/.harness/session-task/sess-vacia"
bus_backup="$(cat "$BUS")"; : > "$BUS"
run_hook sess-vacia >/dev/null 2>&1
assert_no_file "$WS/.harness/session-task/sess-vacia" "limpia el puntero incluso sin resumen"
printf '%s\n' "$bus_backup" > "$BUS"

# Sesión desconocida: no hay ventana que acotar, así que no inventa un resumen.
out="$(run_hook sess-fantasma)"; st=$?
assert_eq 0 "$st" "sesión sin eventos: sale 0"
assert_eq "" "$out" "sesión sin eventos: no inventa un resumen"

: > "$BUS"
run_hook sess-actual >/dev/null 2>&1
assert_eq 0 $? "bus vacío: sale 0 (fail-open)"

printf 'esto no es json\n{"roto\n' > "$BUS"
run_hook sess-actual >/dev/null 2>&1
assert_eq 0 $? "bus corrupto: sale 0 (fail-open)"

rm -rf "$WS/.harness"
run_hook sess-actual >/dev/null 2>&1
assert_eq 0 $? "sin .harness/: sale 0 (fail-open)"

t_done
