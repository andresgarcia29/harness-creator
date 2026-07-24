#!/usr/bin/env bash
# tests/run.sh — corre TODA la suite. Cero dependencias fuera de lo que el
# harness ya exige (bash, jq, python3). Cada test es independiente y limpia
# sus temporales; ninguno toca el workspace real ni la red.
#
#   ./tests/run.sh          → todo (~40s; el lock prueba la gracia de 15s real)
#   ./tests/run.sh fast     → salta el test lento del lock
set -u
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "falta jq (los hooks y el bus lo usan)"; exit 1; }
command -v python3 >/dev/null || { echo "falta python3 (el panel lo usa)"; exit 1; }

# el frontend: el SOURCE del panel vive en harness-ui (ADR-0003) y ahí se testea
# su estructura (npm test). Aquí solo validamos el build vendoreado (dist/), que
# scripts/sync-ui.sh reconstruye desde harness-ui — sin dist, el panel instalado
# sirve 404 y nadie compila Node en la máquina del usuario.
[ -f ../templates/ui/dist/index.html ] || { echo "falta dist/ (corre scripts/sync-ui.sh desde harness-ui)"; exit 1; }
grep -q "__OP_TOKEN__" ../templates/ui/dist/index.html || { echo "dist/index.html sin el placeholder del token anti-CSRF"; exit 1; }
/bin/ls ../templates/ui/dist/assets/*.js >/dev/null 2>&1 || { echo "dist sin assets"; exit 1; }
# dist al día: el marcador del wizard debe estar en el bundle vendoreado
grep -q "harness-init-wizard" ../templates/ui/dist/assets/*.js || { echo "dist desactualizado: re-corre scripts/sync-ui.sh"; exit 1; }
echo "── frontend: dist del panel vendoreado al día (source + estructura en harness-ui) ✓"

failed=0
for t in test_emit.sh test_track_read.sh test_docs.sh test_catalog.sh test_build_slot.sh test_gowork_shims.sh test_ship_gates.sh test_stamp_models.sh test_graph_refresh.sh test_pull_all.sh test_skills_sync.sh test_verdict_scaffold.sh test_minion_probe.sh test_pipeline_steps.sh test_secrets.sh test_plan_lint.sh test_precheck.sh test_harness_bug.sh test_discover.sh test_doctor.sh; do
  echo; bash "$t" || failed=1
done
if [ "${1:-}" != "fast" ]; then
  echo; bash test_ship_lock.sh || failed=1
else
  echo; echo "── lock de ship.sh: saltado (modo fast)"
fi
# en verde: 3 líneas; en rojo: la salida COMPLETA (un tail que esconde el
# traceback convierte cada falla en una sesión de adivinanza — nos pasó)
pyrun() {
  echo; echo "── $1"
  out="$(python3 "$2" -v 2>&1)" && echo "$out" | tail -3 || { echo "$out"; failed=1; }
}
pyrun "server.py (lógica)" test_server.py
pyrun "server.py (HTTP end-to-end)" test_op_http.py
pyrun "evidence v1" test_evidence.py
pyrun "policy engine v1" test_policy.py

echo
if [ "$failed" -eq 0 ]; then echo "════ SUITE COMPLETA EN VERDE ════"; else echo "════ HAY FALLAS ════"; exit 1; fi
