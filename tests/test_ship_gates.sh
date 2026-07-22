#!/usr/bin/env bash
# test_ship_gates.sh — los dos añadidos de velocidad de ship.sh, contra el
# CÓDIGO REAL del template (extraído con awk, como test_ship_lock.sh):
#   · gate_lane: el carril express es una promesa que el diff debe cumplir —
#     contratos/migraciones bloquean; full no se ve afectado.
#   · par/run_parallel_gates: un gate rojo NO oculta a los demás (todos los
#     outputs salen juntos) y el verde agregado exige TODOS los grupos verdes.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

TMPL="$ROOT/templates/scripts/ship.sh.tmpl"

extract() {  # extract <nombre-funcion> — de 'nombre() {' a su '}' de 1er nivel
  awk "/^$1\(\) \{/{f=1} f{print} f&&/^\}/{exit}" "$TMPL"
}
extract gate_lane > "$WS/gate_lane.sh"
grep -q 'LANE_GUARD_PATTERN' "$WS/gate_lane.sh" || { echo "no pude extraer gate_lane"; exit 1; }
{ extract par; extract run_parallel_gates; } > "$WS/pargates.sh"
grep -q 'GDIR' "$WS/pargates.sh" || { echo "no pude extraer par/run_parallel_gates"; exit 1; }

echo "── gate_lane: el carril lo verifica el diff, no la fe"

mk_repo() {  # mk_repo <dir> — repo con origin/main simulado en el commit inicial
  mkdir -p "$1" && cd "$1"
  git init -q . && git config user.email t@t && git config user.name t
  echo base > main.go && git add . && git commit -qm init
  git update-ref refs/remotes/origin/main HEAD
}

run_gate_lane() {  # run_gate_lane <lane-json> — corre gate_lane en el repo actual
  mkdir -p "$WS/tasks/T1"
  printf '%s' "$1" > "$WS/tasks/T1/state.json"
  ( set -u; WS="$WS"; TASK=T1; REPO=test
    gate() { :; }; emit() { :; }
    . "$WS/gate_lane.sh"; gate_lane )
}

# 1. express + diff limpio → pasa
mk_repo "$WS/r1"
echo x > feature.go && git add . && git commit -qm feat
run_gate_lane '{"lane":"express"}' \
  && pass "express con diff limpio: pasa" || fail "express con diff limpio: bloqueó"

# 2. express + toca proto/ → bloquea con exit 3
mk_repo "$WS/r2"
mkdir -p proto && echo 'message X{}' > proto/api.proto && git add . && git commit -qm proto
run_gate_lane '{"lane":"express"}'; rc=$?
assert_eq 3 "$rc" "express tocando proto/: bloquea (exit 3)"

# 3. express + migración SQL → bloquea
mk_repo "$WS/r3"
mkdir -p migrations && echo 'ALTER TABLE x;' > migrations/001.sql && git add . && git commit -qm mig
run_gate_lane '{"lane":"express"}'; rc=$?
assert_eq 3 "$rc" "express tocando migrations/: bloquea"

# 4. full + toca proto → NO es asunto de gate_lane (lo custodia buf breaking)
cd "$WS/r2"
run_gate_lane '{"lane":"full"}' \
  && pass "full tocando proto: gate_lane no interviene" || fail "full: gate_lane bloqueó y no debía"

# 5. sin state.json → default full, no bloquea (compat con tareas viejas)
cd "$WS/r2"
rm -f "$WS/tasks/T1/state.json"
( set -u; WS="$WS"; TASK=T1; REPO=test; gate(){ :; }; emit(){ :; }
  . "$WS/gate_lane.sh"; gate_lane ) \
  && pass "sin state.json: default full, no bloquea" || fail "sin state.json: bloqueó"

echo "── gates en paralelo: un rojo no esconde a los demás"

run_pargates() {  # run_pargates <security-rc> — grupos stub, security parametrizado
  ( set -eu; WS="$WS"; REPO=test; CURRENT_GATE=""; sec_rc="$1"
    emit() { :; }; gate() { CURRENT_GATE="$1"; }
    run_lang_gates() { echo LANG-EVIDENCIA; }
    run_security_gates() { echo SEC-EVIDENCIA; return "$sec_rc"; }
    gate_tests_untouched() { echo TESTS-EVIDENCIA; }
    check_verdict() { echo VERDICT-EVIDENCIA; }
    gate_evidence() { :; }
    gate_policy_and_evidence() { :; }
    . "$WS/pargates.sh"; run_parallel_gates )
}

out="$(run_pargates 0 2>&1)"; rc=$?
assert_eq 0 "$rc" "todos los grupos verdes → verde agregado"
assert_contains "$out" "LANG-EVIDENCIA" "el output de cada grupo aparece"

out="$(run_pargates 3 2>&1)"; rc=$?
assert_eq 3 "$rc" "un grupo rojo → rojo agregado (exit 3)"
assert_contains "$out" "SEC-EVIDENCIA" "el output del grupo rojo aparece"
assert_contains "$out" "LANG-EVIDENCIA" "el rojo NO esconde el output de los verdes"
assert_contains "$out" "security" "el resumen nombra el grupo que falló"

t_done
