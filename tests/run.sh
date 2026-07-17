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

# el frontend al menos tiene que PARSEAR (los typos de CSS no los ve nadie más)
if command -v node >/dev/null; then
  node -e "
    const s=require('fs').readFileSync('../templates/ui/app.html','utf8');
    const m=s.match(/<script>\s*\n?const PHASES[\s\S]*<\/script>/);
    new Function(m[0].replace(/<\/?script>/g,'').replace('const PHASES','var PHASES'));
    for (const v of ['dash','tasks','task','sessions','session','costs','nuevaTarea','connections'])
      if (!s.includes('function '+v+'(')) throw new Error('vista perdida: '+v);
  " && echo "── app.html: parsea y las 8 vistas existen ✓" || exit 1
else
  echo "── app.html: sin node, no verificado (instálalo para cubrir el frontend)"
fi

failed=0
for t in test_emit.sh test_track_read.sh; do
  echo; bash "$t" || failed=1
done
if [ "${1:-}" != "fast" ]; then
  echo; bash test_ship_lock.sh || failed=1
else
  echo; echo "── lock de ship.sh: saltado (modo fast)"
fi
echo; echo "── server.py (lógica)"; python3 test_server.py -v 2>&1 | tail -3 || failed=1
[ "${PIPESTATUS[0]:-0}" = "0" ] || failed=1
echo; echo "── server.py (HTTP end-to-end)"; python3 test_op_http.py -v 2>&1 | tail -3 || failed=1
[ "${PIPESTATUS[0]:-0}" = "0" ] || failed=1

echo
if [ "$failed" -eq 0 ]; then echo "════ SUITE COMPLETA EN VERDE ════"; else echo "════ HAY FALLAS ════"; exit 1; fi
