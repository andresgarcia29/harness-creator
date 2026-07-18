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

# el frontend: la fuente React (web/src) tiene las vistas y el build
# vendoreado (dist/) existe y trae el placeholder del token — sin dist, el
# panel instalado sirve 404 y nadie compila Node en la máquina del usuario
for v in dash tasks task-detail sessions session-detail costs new-task connections docs tools terminals; do
  [ -f "../templates/ui/web/src/views/$v.tsx" ] || { echo "vista perdida: $v"; exit 1; }
done
# el wizard de init (servido por el daemon Go): raíz + pantallas
for v in index stepper step-shell log-tail; do
  [ -f "../templates/ui/web/src/views/init/$v.tsx" ] || { echo "init perdido: $v"; exit 1; }
done
for v in welcome github clone requirements discover agents mcps sessions done browse-dialog placeholder; do
  [ -f "../templates/ui/web/src/views/init/steps/$v.tsx" ] || { echo "paso de init perdido: $v"; exit 1; }
done
grep -q '"init"' ../templates/ui/web/src/lib/router.ts || { echo "la ruta init no está en el router"; exit 1; }
grep -q 'init?: InitState' ../templates/ui/web/src/lib/harness.ts || { echo "el snapshot no tipa init"; exit 1; }
[ -f ../templates/ui/dist/index.html ] || { echo "falta dist/ (corre npm run build en templates/ui/web)"; exit 1; }
grep -q "__OP_TOKEN__" ../templates/ui/dist/index.html || { echo "dist/index.html sin el placeholder del token anti-CSRF"; exit 1; }
/bin/ls ../templates/ui/dist/assets/*.js >/dev/null 2>&1 || { echo "dist sin assets"; exit 1; }
# dist al día: el marcador del wizard debe estar en el bundle vendoreado
grep -q "harness-init-wizard" ../templates/ui/dist/assets/*.js || { echo "dist desactualizado: sin el wizard de init (re-corre npm run build)"; exit 1; }
echo "── frontend: 11 vistas + wizard init (9 pantallas) + dist vendoreado al día ✓"

failed=0
for t in test_emit.sh test_track_read.sh; do
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

echo
if [ "$failed" -eq 0 ]; then echo "════ SUITE COMPLETA EN VERDE ════"; else echo "════ HAY FALLAS ════"; exit 1; fi
