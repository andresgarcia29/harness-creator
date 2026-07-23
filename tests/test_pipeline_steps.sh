#!/usr/bin/env bash
# test_pipeline_steps.sh: los pasos custom del pipeline contra el código REAL.
# Protege: el orden es determinista (order+filename), un gate rojo PARA la
# tarea con la razón cerrada custom_step_failed (fail-closed: sin result
# también es rojo), verde/advisory no paran, y el doctor caza needs_mcp
# ausente. Estilo extract/ejecución real de la suite.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/.claude/pipeline" "$WS/tasks/T1/pipeline"
cp "$ROOT/templates/scripts/pipeline-steps.sh" "$WS/scripts/"
cp "$ROOT/templates/scripts/harness-policy.py" "$WS/scripts/"
cp "$ROOT/templates/policy.json" "$WS/harness-policy.json"

echo "── pipeline-steps: orden determinista"

for spec in "30-c 30 ship" "10-a 10 ship" "20-b 20 ship" "z-nodef _ ship" "x-other _ deploy"; do
  set -- $spec
  if [ "$2" = "_" ]; then printf -- '---\nafter: %s\n---\n' "$3" > "$WS/.claude/pipeline/$1.md"
  else printf -- '---\nafter: %s\norder: %s\n---\n' "$3" "$2" > "$WS/.claude/pipeline/$1.md"; fi
done
got="$(cd "$WS" && bash scripts/pipeline-steps.sh list T1 ship | xargs -n1 basename | sed 's/.md//' | tr '\n' ' ')"
assert_eq "10-a 20-b 30-c z-nodef " "$got" "orden por (order, filename); default 100 al final"
other="$(cd "$WS" && bash scripts/pipeline-steps.sh list T1 deploy | xargs -n1 basename)"
assert_eq "x-other.md" "$other" "list filtra por fase (after:)"

echo "── pipeline-steps: el gate para con custom_step_failed"

# limpiar los de orden y dejar UN gate en ship
rm -f "$WS/.claude/pipeline/"*.md
printf -- '---\nstep: e2e\nafter: ship\ngate: true\n---\n# e2e\n' > "$WS/.claude/pipeline/e2e.md"
python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" init "$WS/tasks/T1" >/dev/null

# a) sin result → fail-closed → rojo → pause
out="$(cd "$WS" && bash scripts/pipeline-steps.sh gate T1 ship 2>&1)"; rc=$?
assert_eq 3 "$rc" "gate sin result: exit 3 (fail-closed)"
assert_eq "blocked" "$(jq -r .phase "$WS/tasks/T1/state.json")" "la tarea queda blocked"
assert_eq "custom_step_failed" "$(jq -r '.history[-1].reason' "$WS/tasks/T1/state.json")" "razón: custom_step_failed"
grep -q "custom_step_failed" "$ROOT/templates/policy.json" || fail "policy.json no lista custom_step_failed"

# b) result ok:true → verde → no para
python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" resume "$WS/tasks/T1" --actor human >/dev/null
printf '{"schema":1,"step":"e2e","ok":true,"summary":"14/14 verdes"}' > "$WS/tasks/T1/pipeline/e2e.json"
(cd "$WS" && bash scripts/pipeline-steps.sh gate T1 ship >/dev/null 2>&1) && pass "gate verde: no para" || fail "gate verde paró"

# c) advisory (gate:false) rojo → no para
printf -- '---\nstep: adv\nafter: ship\ngate: false\n---\n' > "$WS/.claude/pipeline/adv.md"
rm -f "$WS/.claude/pipeline/e2e.md" "$WS/tasks/T1/pipeline/e2e.json"
printf '{"schema":1,"step":"adv","ok":false,"summary":"solo avisa"}' > "$WS/tasks/T1/pipeline/adv.json"
(cd "$WS" && bash scripts/pipeline-steps.sh gate T1 ship >/dev/null 2>&1) && pass "advisory rojo: continúa" || fail "advisory rojo paró"

echo "── doctor: caza needs_mcp ausente en un playbook"

# workspace mínimo para que el doctor arranque
cp "$ROOT/scripts/doctor.sh" "$WS/scripts/doctor.sh"
printf -- '---\nafter: ship\ngate: true\nneeds_mcp: corvux-e2e\n---\n# e2e\n' > "$WS/.claude/pipeline/needs.md"
printf '{"mcpServers":{}}' > "$WS/.mcp.json"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "corvux-e2e" "doctor nombra el MCP faltante"
printf '{"mcpServers":{"corvux-e2e":{"command":"x"}}}' > "$WS/.mcp.json"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
echo "$out" | grep -q "corvux-e2e.*ausente\|ausente.*corvux-e2e" && fail "aún flag con MCP presente" || pass "MCP presente: sin flag"
grep -q "needs_mcp" "$ROOT/scripts/doctor.sh" || fail "check needs_mcp ausente en doctor.sh"

# ids inválidos → exit 1
bash "$WS/scripts/pipeline-steps.sh" list "../evil" ship >/dev/null 2>&1 && fail "task traversal pasó" || pass "task-id inválido: exit 1"
bash "$WS/scripts/pipeline-steps.sh" list T1 nofase >/dev/null 2>&1 && fail "fase inválida pasó" || pass "fase inválida: exit 1"

t_done
