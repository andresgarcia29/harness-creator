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

# el frontend: la fuente React (web/src) tiene las 8 vistas y el build
# vendoreado (dist/) existe y trae el placeholder del token — sin dist, el
# panel instalado sirve 404 y nadie compila Node en la máquina del usuario
for v in dash tasks task-detail sessions session-detail costs new-task connections; do
  [ -f "../templates/ui/web/src/views/$v.tsx" ] || { echo "vista perdida: $v"; exit 1; }
done
[ -f ../templates/ui/dist/index.html ] || { echo "falta dist/ (corre npm run build en templates/ui/web)"; exit 1; }
grep -q "__OP_TOKEN__" ../templates/ui/dist/index.html || { echo "dist/index.html sin el placeholder del token anti-CSRF"; exit 1; }
/bin/ls ../templates/ui/dist/assets/*.js >/dev/null 2>&1 || { echo "dist sin assets"; exit 1; }
echo "── frontend: 8 vistas en web/src + dist vendoreado con token ✓"

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
