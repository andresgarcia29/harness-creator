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
# El policy de la instancia se RENDERIZA: max_review_rounds sale de loop_budget
sed 's/{{LOOP_BUDGET}}/3/g' "$ROOT/templates/policy.json.tmpl" > "$WS/harness-policy.json"

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
grep -q "custom_step_failed" "$ROOT/templates/policy.json.tmpl" || fail "policy.json no lista custom_step_failed"

# b) result ok:true → verde → no para
python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" resume "$WS/tasks/T1" --actor human >/dev/null
printf '{"schema":1,"step":"e2e","ok":true,"summary":"14/14 verdes"}' > "$WS/tasks/T1/pipeline/e2e.json"
(cd "$WS" && bash scripts/pipeline-steps.sh gate T1 ship >/dev/null 2>&1) && pass "gate verde: no para" || fail "gate verde paró"

# c) advisory (gate:false) rojo → no para
printf -- '---\nstep: adv\nafter: ship\ngate: false\n---\n' > "$WS/.claude/pipeline/adv.md"
rm -f "$WS/.claude/pipeline/e2e.md" "$WS/tasks/T1/pipeline/e2e.json"
printf '{"schema":1,"step":"adv","ok":false,"summary":"solo avisa"}' > "$WS/tasks/T1/pipeline/adv.json"
(cd "$WS" && bash scripts/pipeline-steps.sh gate T1 ship >/dev/null 2>&1) && pass "advisory rojo: continúa" || fail "advisory rojo paró"

echo "── el gate CORRE los pasos 'run:' que no dejaron result (#154)"
# Caso de campo: un paso determinista salió verde, su result quedó en disco con
# ok:true, y el gate paró la tarea con "sin resultado". El gate había mirado
# ANTES de que el paso escribiera: el orden vivía en la prosa de /smart, no en
# código. Ahora el gate no confía en el orden, lo corre él y después juzga.
rm -f "$WS/.claude/pipeline/"*.md "$WS/tasks/T1/pipeline/"*.json
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/scripts/paso-verde.sh"
printf '#!/usr/bin/env bash\necho "el detalle del rojo"; exit 1\n' > "$WS/scripts/paso-rojo.sh"
printf '#!/usr/bin/env bash\nmkdir -p "tasks/$HARNESS_TASK/pipeline"\nprintf %%s "{\\"schema\\":1,\\"step\\":\\"propio\\",\\"ok\\":true,\\"summary\\":\\"sin duplicados en 7 specs\\"}" > "tasks/$HARNESS_TASK/pipeline/propio.json"\n' > "$WS/scripts/paso-propio.sh"

printf -- '---\nstep: verde\nafter: ship\ngate: true\nrun: scripts/paso-verde.sh\n---\n' > "$WS/.claude/pipeline/verde.md"
(cd "$WS" && bash scripts/pipeline-steps.sh gate T1 ship >/dev/null 2>&1) \
  && pass "paso 'run:' sin result: el gate lo corre y NO para la tarea sana" \
  || fail "el gate paró un paso 'run:' verde por no haberlo corrido"
assert_eq "true" "$(jq -r .ok "$WS/tasks/T1/pipeline/verde.json")" "y deja el result derivado del exit code (el contrato que la doc prometía)"

# Un paso que SÍ se escribe su result manda: trae summary y evidencia propios.
rm -f "$WS/.claude/pipeline/"*.md "$WS/tasks/T1/pipeline/"*.json
printf -- '---\nstep: propio\nafter: ship\ngate: true\nrun: scripts/paso-propio.sh\n---\n' > "$WS/.claude/pipeline/propio.md"
(cd "$WS" && bash scripts/pipeline-steps.sh gate T1 ship >/dev/null 2>&1) || fail "el gate paró un paso que se escribió su propio result verde"
assert_eq "sin duplicados en 7 specs" "$(jq -r .summary "$WS/tasks/T1/pipeline/propio.json")" "el result propio del paso manda: el gate no lo pisa con el derivado"

# Y un rojo REAL sigue parando: el backstop mide, no perdona.
rm -f "$WS/.claude/pipeline/"*.md "$WS/tasks/T1/pipeline/"*.json
printf -- '---\nstep: rojo\nafter: ship\ngate: true\nrun: scripts/paso-rojo.sh\n---\n' > "$WS/.claude/pipeline/rojo.md"
out="$(cd "$WS" && bash scripts/pipeline-steps.sh gate T1 ship 2>&1)"; rc=$?
assert_eq 3 "$rc" "paso 'run:' que sale rojo al correrlo: exit 3 (para, como debe)"
assert_contains "$out" "el detalle del rojo" "y muestra lo que el paso imprimió, no solo el exit code"
assert_eq "false" "$(jq -r .ok "$WS/tasks/T1/pipeline/rojo.json")" "con el result derivado en ok:false"
python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" resume "$WS/tasks/T1" --actor human >/dev/null

# El fail-closed del paso AGÉNTICO no se toca: ése no tiene qué correr.
rm -f "$WS/.claude/pipeline/"*.md "$WS/tasks/T1/pipeline/"*.json
printf -- '---\nstep: agentico\nafter: ship\ngate: true\n---\n' > "$WS/.claude/pipeline/agentico.md"
(cd "$WS" && bash scripts/pipeline-steps.sh gate T1 ship >/dev/null 2>&1); rc=$?
assert_eq 3 "$rc" "paso agéntico sin result: sigue rojo (un agente que se calla no pasa un gate)"
python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" resume "$WS/tasks/T1" --actor human >/dev/null

# Higiene de la ruta: el backstop NO ejecuta lo que no está bajo scripts/.
rm -f "$WS/.claude/pipeline/"*.md "$WS/tasks/T1/pipeline/"*.json
printf '#!/usr/bin/env bash\ntouch "$WS_MARCA"\n' > "$WS/fuera.sh"
printf -- '---\nstep: fuera\nafter: ship\ngate: true\nrun: ../fuera.sh\n---\n' > "$WS/.claude/pipeline/fuera.md"
(cd "$WS" && WS_MARCA="$WS/corrio-lo-que-no-debia" bash scripts/pipeline-steps.sh gate T1 ship >/dev/null 2>&1); rc=$?
assert_eq 3 "$rc" "run: con traversal: no se ejecuta, y sin result el gate sigue siendo rojo"
assert_no_file "$WS/corrio-lo-que-no-debia" "y de verdad no corrió nada fuera de scripts/"
python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" resume "$WS/tasks/T1" --actor human >/dev/null
rm -f "$WS/.claude/pipeline/"*.md "$WS/tasks/T1/pipeline/"*.json

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
