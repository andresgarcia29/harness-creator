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
# pid_alive va junto: acquire_lock la usa para distinguir "el dueño murió" de
# "no pude saberlo" (pid ilegible, o EPERM porque el proceso es de otro
# usuario). Leer los tres casos como "muerto" liberaba locks VIVOS.
# mkdir_lock también: es el primitivo con el que acquire_lock TOMA el lock, y
# desde el issue #209 no es `mkdir` a secas (con uutils coreutils el binario
# hace check-then-act y bajo carrera le dice que sí a varios).
{ awk '/^mkdir_lock\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$TMPL"
  awk '/^pid_alive\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$TMPL"
  awk '/^acquire_lock\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$TMPL"; } > "$WS/lock.sh"
grep -q 'LOCK_HELD=1' "$WS/lock.sh" || { echo "no pude extraer acquire_lock del template"; exit 1; }
grep -q 'pid_alive' "$WS/lock.sh" || { echo "no pude extraer pid_alive del template"; exit 1; }
grep -q 'mkdir_lock() {' "$WS/lock.sh" || { echo "no pude extraer mkdir_lock del template"; exit 1; }

run_acquire() {  # run_acquire <lockdir> [timeout]  (timeout portable: macOS no trae coreutils)
  bash -c "
    set -euo pipefail; LOCKDIR='$1'; REPO=test; LOCK_HELD=''
    # acquire_lock SUELTO, no dentro de un && : llamar una funcion como parte
    # de una AND-list SUPRIME set -e en todo su cuerpo, y entonces el test mide
    # el harness en vez del codigo. Asi sobrevivia el deadlock del lock huerfano.
    . '$WS/lock.sh'
    acquire_lock
    [ -n \"\$LOCK_HELD\" ]
    [ -f '$1/pid' ]
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

echo
echo "── 'no pude mirar' no libera un lock"
# kill -0 falla en tres casos y antes se leían todos como "muerto": proceso
# inexistente (muerto de verdad), pid ilegible, y EPERM (existe pero es de
# otro usuario, o sea VIVO). Robarle el lock a un vivo mete dos ships
# concurrentes en el mismo repo.
LOCKDIR="$WS/ilegible.lock.d"; mkdir -p "$LOCKDIR"; printf 'no-soy-un-pid' > "$LOCKDIR/pid"
out="$( ( set -euo pipefail; LOCKDIR="$LOCKDIR"; . "$WS/lock.sh"
          if pid_alive "$(cat "$LOCKDIR/pid")"; then rc=0; else rc=$?; fi; echo "rc=$rc" ) 2>&1 )"
assert_contains "$out" "rc=2" "pid ilegible: 'no se pudo saber', no 'muerto'"

out="$( ( set -euo pipefail; . "$WS/lock.sh"; if pid_alive ""; then rc=0; else rc=$?; fi; echo "rc=$rc" ) 2>&1 )"
assert_contains "$out" "rc=2" "pid vacío: tampoco se lee como muerto"

out="$( ( set -euo pipefail; . "$WS/lock.sh"; if pid_alive 1; then rc=0; else rc=$?; fi; echo "rc=$rc" ) 2>&1 )"
assert_contains "$out" "rc=0" "pid 1 (init, de root): VIVO aunque kill -0 dé EPERM"

out="$( ( set -euo pipefail; . "$WS/lock.sh"; if pid_alive 99999999; then rc=0; else rc=$?; fi; echo "rc=$rc" ) 2>&1 )"
assert_contains "$out" "rc=1" "pid inexistente: muerto de verdad, ese sí se reclama"

t_done
