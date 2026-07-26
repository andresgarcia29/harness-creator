#!/usr/bin/env bash
# test_ci_gates.sh: los gates del harness corriendo en infra NEUTRAL.
#
# Hasta aca los gates corrian en la laptop del que pushea. Con un equipo, "los
# sistemas deterministas verifican" es cierto solo hasta la laptop menos
# actualizada: cualquiera puede editar su ship.sh local. El modo --ci mueve la
# verificacion a un runner que nadie controla desde su maquina, corriendo EL
# MISMO codigo: un workflow que reimplemente los gates se desincroniza en la
# primera version y entonces CI y local dicen cosas distintas del mismo commit.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

TMPL="$ROOT/templates/scripts/ship.sh.tmpl"
mkdir -p "$WS/plugin/scripts"
sed -e 's/{{LOOP_BUDGET}}/3/g' -e 's/{{FLOW}}/trunk/g' "$TMPL" > "$WS/plugin/scripts/ship.sh"
chmod +x "$WS/plugin/scripts/ship.sh"

mk_repo() {  # mk_repo <dir>: checkout PELADO, sin layout de workspace
  rm -rf "$1"; mkdir -p "$1"; cd "$1"
  git init -q .; git config user.email t@t; git config user.name t
  printf 'package main\n' > main.go 2>/dev/null
  echo base > app.txt; git add -A; git commit -qm base >/dev/null
  git update-ref refs/remotes/origin/main HEAD
  cd "$WS"
}
run_ci() { ( cd "$1" && bash "$WS/plugin/scripts/ship.sh" --ci demo 2>&1 ); }

echo "── corre sobre un checkout pelado, sin workspace"
mk_repo "$WS/r1"
( cd "$WS/r1"; echo x > f.txt; git add -A; git commit -qm feat >/dev/null )
out="$(run_ci "$WS/r1")"; rc=$?
assert_eq 0 "$rc" "checkout sin tasks/ ni repos/: los gates corren igual"
assert_contains "$out" "modo CI" "lo declara"
assert_contains "$out" "infra neutral" "y dice por que existe"

echo "── NO inventa artefactos del workspace"
assert_no_file "$WS/plugin/tasks" "no crea tasks/ en el checkout del harness"
assert_no_file "$WS/r1/tasks" "ni en el repo"
n="$(find "$WS" -name 'EV-*.json' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$n" "y NO sella evidencia: no hay veredicto que respaldar"

echo "── un gate rojo sigue siendo rojo (no se afloja por estar en CI)"
mk_repo "$WS/r2"
( cd "$WS/r2"; mkdir -p tests
  printf 'def test_a():\n    assert 1 == 1\n    assert 2 == 2\n' > tests/test_x.py
  git add -A; git commit -qm tests >/dev/null; git update-ref refs/remotes/origin/main HEAD
  printf 'def test_a():\n    assert 1 == 1\n' > tests/test_x.py
  git add -A; git commit -qm debilita >/dev/null )
out="$(run_ci "$WS/r2")"; rc=$?
assert_eq 3 "$rc" "test debilitado: bloquea tambien en CI"
assert_contains "$out" "DEBILITA" "nombrando la causa"

echo "── la declaracion puede venir por env (en CI no hay tasks/<id>/)"
printf '## MODIFIED Requirements\n- X-1: se ajusta tests/test_x.py\n' > "$WS/decl.md"
out="$( cd "$WS/r2" && HARNESS_DELTA_SPEC_FILE="$WS/decl.md" bash "$WS/plugin/scripts/ship.sh" --ci demo 2>&1 )"; rc=$?
assert_eq 0 "$rc" "declarado en el cuerpo del PR: pasa"
assert_contains "$out" "DECLARADOS" "y queda en el registro"

echo "── el workflow llama al MISMO codigo, no a una copia"
wf="$(cat "$ROOT/templates/ci/harness-gates.yml.tmpl")"
assert_contains "$wf" "ship.sh --ci" "el workflow invoca ship.sh, no reimplementa gates"
assert_contains "$wf" "merge_group" "y se engancha a la cola de merge"
assert_contains "$wf" "fetch-depth: 0" "con historia completa: un checkout superficial deja el diff vacio"
assert_contains "$wf" "HARNESS_DELTA_SPEC_FILE" "y pasa la declaracion del PR"
upd="$(cat "$ROOT/commands/harness-update.md")"
assert_contains "$upd" "Gates-en-CI" "el updater lo trata como paquete atado con ship.sh"

t_done
