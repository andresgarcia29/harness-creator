#!/usr/bin/env bash
# test_ship_lock.sh — el lock de ship.sh: las DOS ventanas de muerte que
# costaron un lock inmortal (pid nunca escrito; trap sin LOCK_HELD), más
# respetar a un dueño vivo. Extrae acquire_lock del template y lo ejecuta
# de verdad — si alguien rompe el lock editando el template, esto lo cacha.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

TMPL="$ROOT/templates/scripts/ship.sh.tmpl"

# extraer SOLO acquire_lock (de 'acquire_lock() {' a su '}' de primer nivel)
awk '/^acquire_lock\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$TMPL" > "$WS/lock.sh"
grep -q 'LOCK_HELD=1' "$WS/lock.sh" || { echo "no pude extraer acquire_lock del template"; exit 1; }

run_acquire() {  # run_acquire <lockdir> [timeout]  (timeout portable: macOS no trae coreutils)
  bash -c "
    set -u; LOCKDIR='$1'; REPO=test; LOCK_HELD=''
    . '$WS/lock.sh'; acquire_lock && [ -n \"\$LOCK_HELD\" ] && [ -f '$1/pid' ]
  " &
  local pid=$! rc
  ( sleep "${2:-30}"; kill -9 "$pid" 2>/dev/null ) & local watcher=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return "$rc"
}

echo "── lock de ship.sh"

# 1. libre → adquiere y escribe pid
L="$WS/lock-a"
run_acquire "$L" && pass "lock libre: adquiere y escribe pid" || fail "lock libre: no adquirió"

# 2. huérfano con pid muerto → lo reclama sin esperar
L="$WS/lock-b"; mkdir -p "$L"; echo 99999999 > "$L/pid"
run_acquire "$L" 10 && pass "huérfano (pid muerto): reclamado" || fail "huérfano (pid muerto): no reclamado"

# 3. la ventana inmortal: lock SIN pid → gracia de 15s y reclamo
#    (antes del fix esto colgaba PARA SIEMPRE; el test dura ~16s a propósito)
L="$WS/lock-c"; mkdir -p "$L"
run_acquire "$L" 25 && pass "sin pid: reclamado tras la gracia de 15s (antes: inmortal)" \
                    || fail "sin pid: sigue inmortal — la regresión que ya vivimos"

# 4. dueño VIVO → espera, jamás roba
L="$WS/lock-d"; mkdir -p "$L"; echo $$ > "$L/pid"   # nosotros somos el dueño vivo
if run_acquire "$L" 6; then
  fail "dueño vivo: LE ROBÓ el lock"
else
  [ -d "$L" ] && [ "$(cat "$L/pid")" = "$$" ] \
    && pass "dueño vivo: esperó sin robar" || fail "dueño vivo: el lock quedó tocado"
fi

t_done
