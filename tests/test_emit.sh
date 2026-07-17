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

# 6. sin kind → no escribe, no falla
before="$(wc -l < "$WS/.harness/events.jsonl")"
"$EMIT"
assert_eq "0" "$?" "sin argumentos: exit 0"
assert_eq "$before" "$(wc -l < "$WS/.harness/events.jsonl")" "sin argumentos: no escribe basura"

t_done
