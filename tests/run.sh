#!/usr/bin/env bash
# tests/run.sh — corre TODA la suite. Cero dependencias fuera de lo que el
# harness ya exige (bash, jq, python3). Cada test es independiente y limpia
# sus temporales; ninguno toca el workspace real ni la red.
#
#   ./tests/run.sh          → todo (~40s; el lock prueba la gracia de 15s real)
#   ./tests/run.sh fast     → salta el test lento del lock
set -u

# Identidad de git para TODA la suite, bash y python. Los tests commitean, y
# hasta acá se lo preguntaban al host: en un runner limpio git muere con
# "fatal: empty ident name", el commit no ocurre, la variable que guardaba su
# sha queda vacía y la aserción de más abajo falla por un motivo que no se
# parece en nada a la causa. Diez commits de CI en rojo, verde en local.
# Va acá además de en lib.sh porque las variables de entorno le GANAN a
# `git config`: un test python que configura el repo igual se rompe si el
# entorno trae un GIT_AUTHOR_NAME vacío.
export GIT_AUTHOR_NAME="harness tests" GIT_AUTHOR_EMAIL="t@t"
export GIT_COMMITTER_NAME="harness tests" GIT_COMMITTER_EMAIL="t@t"

# ── Un test del semáforo NO puede correr DENTRO del semáforo ──────────
# build-slot.sh exporta HARNESS_BUILD_SLOT_HELD=1 a su hijo (re-entrancia, para
# que un docker build interior no se auto-deadlockee), y evidence.py salta el
# wrapper cuando la ve. Las dos conductas son correctas. Lo que rompe es
# heredarlas: si alguien sella esta suite como evidencia
# (`evidence.py run ... -- bash tests/run.sh`), TODA invocación de build-slot
# dentro de los tests se vuelve un exec directo, y entonces los tests que MIDEN
# el semáforo miden un semáforo apagado. Caso de campo (COR-707): concurrencia
# contada 4 con tope 2, el waiter sin bloquearse, y `slot_wrapped: false` en el
# sello. Sueltos pasaban; bajo el wrapper, tres aserciones en rojo.
# Efecto: la suite completa del harness no se podía sellar como evidencia, o sea
# que "corrí la suite entera" no se podía probar con el mecanismo que el propio
# harness exige para probar cualquier cosa.
# Se limpia acá, para TODA la suite, y además en los tests que lo miden, para
# que también sean correctos corriéndolos sueltos bajo un slot tomado.
unset HARNESS_BUILD_SLOT_HELD HARNESS_SLOT_DIR HARNESS_SLOT_N

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
for t in test_emit.sh test_finding.sh test_repo_brief.sh test_bounded.sh test_track_read.sh test_docs.sh test_catalog.sh test_build_slot.sh test_guard_build_slot.sh test_guard_ws_scripts.sh test_guard_broad_add.sh test_gowork_shims.sh test_py_shims.sh test_ship_gates.sh test_stamp_models.sh test_graph_refresh.sh test_pull_all.sh test_skills_sync.sh test_custom_skill.sh test_custom_rule.sh test_verdict_scaffold.sh test_minion_probe.sh test_pipeline_steps.sh test_secrets.sh test_plan_lint.sh test_precheck.sh test_verdict_beads.sh test_ship_wave.sh test_port_forwards.sh test_instance_ship.sh test_harness_bug.sh test_discover.sh test_doctor.sh test_session_summary.sh test_guard_worktree.sh test_guard_canonical.sh test_mem_recall.sh \
          test_deploy_watch.sh test_ui_emit.sh test_vendor_neutrality.sh test_worktree_task.sh test_silent_green.sh test_prompt_gate_contract.sh test_dead_knobs.sh test_concurrency.sh test_base_branch.sh test_forge_tickets.sh test_harness_version.sh test_rebase_survival.sh test_archived_repos.sh test_ci_gates.sh test_update_migrate.sh test_adr_new.sh test_version.sh; do
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
pyrun "metricas del harness" test_metrics.py
pyrun "bascula de costo" test_harness_cost.py
pyrun "nota de tarea" test_task_note.py
pyrun "destino de metricas" test_harness_sink.py

echo
if [ "$failed" -eq 0 ]; then echo "════ SUITE COMPLETA EN VERDE ════"; else echo "════ HAY FALLAS ════"; exit 1; fi
