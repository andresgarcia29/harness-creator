#!/usr/bin/env bash
# test_emit.sh — el bus (emit.sh): shape del evento, redacción, fail-open,
# y que sea sourceable desde sh/zsh sin reventar a quien lo sourcea.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

EMIT="$ROOT/templates/scripts/emit.sh"
export CLAUDE_PROJECT_DIR="$WS"

echo "── emit.sh"

# 1. shape: una línea JSON con ts/kind/task/actor/summary
"$EMIT" phase "arrancó implement" "" COR-1
line="$(tail -1 "$WS/.harness/events.jsonl")"
# validar por jq, no por texto: jq -nc compacta y el espaciado no es contrato
for f in ts kind task actor summary; do
  v="$(printf '%s' "$line" | jq -r ".$f")"
  [ -n "$v" ] && [ "$v" != "null" ] && pass "campo $f presente ($v)" || fail "campo $f ausente"
done
assert_eq "COR-1" "$(printf '%s' "$line" | jq -r .task)" "task como 4º argumento"

# 2. ok es booleano JSON, no string
"$EMIT" gate "gate_secrets" false COR-1
assert_eq "false" "$(tail -1 "$WS/.harness/events.jsonl" | jq -r '.ok|type=="boolean"' >/dev/null && tail -1 "$WS/.harness/events.jsonl" | jq -r .ok)" "ok=false es booleano"

# 3. redacción ANTES de escribir (la ley de secretos aplica al bus).
#    Todas las familias — el \b de sk-/vault/slack/jwt no matcheaba en el sed
#    de macOS y esas llaves viajaban SIN redactar; este test cachó el bug.
"$EMIT" decision "usé ghp_0123456789012345678901234567890 sk-abcdefghijklmnopqrstuvwx lin_api_ABCDEFGHIJ0123456789xx hvs.AbCdEfGhIjKlMnOpQrStUv xoxb-1234567890-abcdef eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdef AKIA0123456789AB"
line="$(tail -1 "$WS/.harness/events.jsonl")"
assert_not_contains "$line" "ghp_0123456789012345678901234567890" "token de GitHub redactado"
assert_not_contains "$line" "sk-abcdefghijklmnopqrstuvwx" "api key redactada"
assert_not_contains "$line" "lin_api_ABCDEFGHIJ0123456789" "token de Linear redactado"
assert_not_contains "$line" "hvs.AbCdEfGhIjKlMnOpQrStUv" "token de Vault redactado"
assert_not_contains "$line" "xoxb-1234567890" "token de Slack redactado"
assert_not_contains "$line" "eyJzdWIiOiIxIn0" "JWT redactado"
assert_not_contains "$line" "AKIA0123456789AB" "llave AWS redactada"
assert_contains "$line" "REDACTADO" "marca de redacción visible"

# 4. FAIL-OPEN: sin permisos de escritura sale 0 igual
RO="$WS/ro"; mkdir -p "$RO/.harness"; chmod 555 "$RO/.harness" "$RO"
( export CLAUDE_PROJECT_DIR="$RO"; "$EMIT" phase "no puedo escribir" )
assert_eq "0" "$?" "fail-open: exit 0 aunque el bus no sea escribible"
chmod 755 "$RO/.harness" "$RO"

# 5. sourceable desde sh y zsh con set -u (la guardia de BASH_SOURCE)
sh -uc ". '$EMIT' && emit phase 'desde sh'" && pass "sourceable desde sh -u" || fail "revienta al sourcearlo desde sh -u"
if command -v zsh >/dev/null; then
  zsh -uc ". '$EMIT' && emit phase 'desde zsh'" && pass "sourceable desde zsh -u" || fail "revienta al sourcearlo desde zsh -u"
fi
# dash = el sh real de Debian/Ubuntu. El sh de macOS es bash disfrazado y
# TOLERA bashisms (${VAR[0]}): sin este caso, un bashism pasa en Mac y
# revienta en el CI de Linux — nos pasó con ${BASH_SOURCE[0]:-}.
if command -v dash >/dev/null; then
  dash -uc ". '$EMIT' && emit phase 'desde dash'" && pass "sourceable desde dash -u (el sh de Ubuntu)" || fail "revienta al sourcearlo desde dash -u"
fi

# 6. `dur`: el 5º argumento, opcional, NÚMERO y no string.
#    Existe porque la duración de un gate se derivaba restando timestamps de
#    eventos `gate` consecutivos, y con dos ships de la misma tarea
#    intercalados en el bus esa resta le atribuye el tiempo al gate equivocado.
"$EMIT" gate x true T1 12
line="$(tail -1 "$WS/.harness/events.jsonl")"
printf '%s' "$line" | jq -e '.dur == 12' >/dev/null 2>&1 \
  && pass "dur presente y con el valor pasado" || fail "dur ausente o distinto (línea: $line)"
printf '%s' "$line" | jq -e '.dur | type == "number"' >/dev/null 2>&1 \
  && pass "dur es número JSON, no string" || fail "dur no es número (línea: $line)"
# y el resto del evento no se movió por llevar dur encima
assert_eq "true" "$(printf '%s' "$line" | jq -r '.ok')" "con dur, ok sigue siendo booleano true"
assert_eq "T1" "$(printf '%s' "$line" | jq -r '.task')" "con dur, task sigue en su lugar"
assert_eq "x" "$(printf '%s' "$line" | jq -r '.summary')" "con dur, summary sigue en su lugar"

# 6b. sin 5º argumento → la clave NO aparece. Compat hacia atrás: un llamador
#     viejo produce el MISMO objeto de siempre, sin claves nuevas.
"$EMIT" gate x true T1
line="$(tail -1 "$WS/.harness/events.jsonl")"
printf '%s' "$line" | jq -e 'has("dur") | not' >/dev/null 2>&1 \
  && pass "sin 5º argumento: el objeto sale SIN la clave dur" || fail "apareció dur sin pedirlo (línea: $line)"

# 6c. un dur basura NO puede romper la línea del bus. El bus es fail-open por
#     ley: se descarta el dato malo, jamás el evento.
"$EMIT" gate x true T1 basura
line="$(tail -1 "$WS/.harness/events.jsonl")"
printf '%s' "$line" | jq -e . >/dev/null 2>&1 \
  && pass "dur basura: la línea sigue siendo JSON válido" || fail "dur basura rompió la línea (línea: $line)"
printf '%s' "$line" | jq -e 'has("dur") | not' >/dev/null 2>&1 \
  && pass "dur basura: sale sin la clave dur" || fail "dur basura se coló al bus (línea: $line)"
assert_eq "x" "$(printf '%s' "$line" | jq -r '.summary')" "dur basura: el evento se emite igual"
# "007" es dígitos pero NO es JSON válido: si se colara, jq muere y el evento
# entero se pierde en silencio. Es el borde que hace que validar no alcance con
# "son todos números".
"$EMIT" gate ceros true T1 007
line="$(tail -1 "$WS/.harness/events.jsonl")"
assert_eq "ceros" "$(printf '%s' "$line" | jq -r '.summary')" "dur con ceros a la izquierda: el evento no se pierde"
printf '%s' "$line" | jq -e 'has("dur") | not' >/dev/null 2>&1 \
  && pass "dur con ceros a la izquierda: descartado, no emitido" || fail "007 se coló como dur (línea: $line)"
# 0 SÍ es un dur legítimo: un gate que tarda menos de un segundo existe.
"$EMIT" gate rapido true T1 0
tail -1 "$WS/.harness/events.jsonl" | jq -e '.dur == 0' >/dev/null 2>&1 \
  && pass "dur 0 es un valor válido (gate de menos de un segundo)" || fail "dur 0 se descartó"

# 6d. el 5º argumento llega también por la forma SOURCEADA (las dos formas de
#     usar emit.sh tienen que aceptarlo, no solo el CLI).
( . "$EMIT" && emit gate "sourceado" true T1 7 )
tail -1 "$WS/.harness/events.jsonl" | jq -e '.dur == 7' >/dev/null 2>&1 \
  && pass "sourceado: emit acepta el 5º argumento igual que el CLI" || fail "sourceado: se perdió dur"

# 7. sin kind → no escribe, no falla
before="$(wc -l < "$WS/.harness/events.jsonl")"
"$EMIT"
assert_eq "0" "$?" "sin argumentos: exit 0"
assert_eq "$before" "$(wc -l < "$WS/.harness/events.jsonl")" "sin argumentos: no escribe basura"

echo
echo "── DÓNDE nace el bus: el workspace se BUSCA, no se asume el cwd"
# El comentario de _emit_ws prometía una búsqueda hacia arriba que el código no
# hacía: devolvía el valor tal cual, así que sin CLAUDE_PROJECT_DIR ni WS caía
# en $PWD y el bus nacía en CUALQUIER directorio. Caso de campo (COR-675): con
# el cwd dentro de worktrees/<task>/<repo>, el harness dejaba un `.harness/`
# untracked en el árbol del CLIENTE (dos gates discrepando sobre qué es un árbol
# limpio, y un `git add -A` habría commiteado telemetría en el repo ajeno). Y
# ahora pesa más: las métricas leen ESTE bus, así que los eventos repartidos
# entre varios events.jsonl corrompen la medición en silencio.
BWS="$WS/buscado"
mkdir -p "$BWS/.harness" "$BWS/worktrees/T9/repo/src/deep" "$WS/sin-ancestro/a/b"

# desde un subdirectorio PROFUNDO, sin señal explícita: sube hasta la raíz real
( cd "$BWS/worktrees/T9/repo/src/deep" \
  && env -u CLAUDE_PROJECT_DIR -u WS bash "$EMIT" phase "desde el fondo" "" T9 )
[ -f "$BWS/.harness/events.jsonl" ] \
  && pass "el evento aterriza en el .harness/ de la RAÍZ del workspace" \
  || fail "el evento no llegó a la raíz: el bus volvió a nacer donde estaba el cwd"
assert_no_file "$BWS/worktrees/T9/repo/src/deep/.harness/events.jsonl" \
  "y NO deja un .harness/ suelto en el árbol del cliente"

# la señal EXPLÍCITA gana: es lo que dicen el cliente y el propio harness
mkdir -p "$WS/explicito"
( cd "$BWS/worktrees/T9/repo" \
  && env -u WS CLAUDE_PROJECT_DIR="$WS/explicito" bash "$EMIT" phase "explícito" "" T9 )
[ -f "$WS/explicito/.harness/events.jsonl" ] \
  && pass "CLAUDE_PROJECT_DIR le gana a la búsqueda (es la señal del cliente)" \
  || fail "se ignoró CLAUDE_PROJECT_DIR"

# sin NINGÚN ancestro con .harness/ ni CLAUDE.md: no cuelga y no inventa.
# Fail-open por ley: el bus jamás puede tumbar a quien lo invoca.
( cd "$WS/sin-ancestro/a/b" \
  && env -u CLAUDE_PROJECT_DIR -u WS bash "$EMIT" phase "huérfano" "" T9 )
assert_eq "0" "$?" "sin workspace que encontrar: sigue saliendo 0"

t_done
