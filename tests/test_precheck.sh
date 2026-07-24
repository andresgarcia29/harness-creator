#!/usr/bin/env bash
# test_precheck.sh — `ship.sh --precheck`: los gates mecánicos ANTES de gastar
# una ronda de reviewer. Contra el CÓDIGO REAL del template (instanciado con
# sed, como haría el generador). Lo que se verifica es lo que hace de esto una
# ganancia de velocidad y no un gate más:
#   · verde deja sello con el commit revisado (lo lee /review)
#   · rojo deja sello ok:false, sale != 0 y dice que NO se entregue a review
#   · nunca pide veredicto (el reviewer todavía no existe) ni hace push
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/bin" "$WS/tasks/T1" "$WS/repos" "$WS/worktrees/T1"
sed 's/{{LOOP_BUDGET}}/3/g' "$ROOT/templates/scripts/ship.sh.tmpl" > "$WS/scripts/ship.sh"
bash -n "$WS/scripts/ship.sh" && pass "ship.sh instanciado: sintaxis válida" \
  || { fail "ship.sh instanciado: error de sintaxis"; t_done; }

# gitleaks stubeado: el precheck lo corre siempre y en CI no está instalado.
stub_gitleaks() { printf '#!/bin/sh\n%s\n' "$1" > "$WS/bin/gitleaks"; chmod +x "$WS/bin/gitleaks"; }

git init -q "$WS/repos/svc"
( cd "$WS/repos/svc"
  git config user.email t@t; git config user.name t
  echo base > app.txt; git add .; git commit -qm init
  git update-ref refs/remotes/origin/main HEAD )
cp -R "$WS/repos/svc" "$WS/worktrees/T1/svc"
( cd "$WS/worktrees/T1/svc"; echo nuevo > feature.txt; git add .; git commit -qm feat )
head="$( cd "$WS/worktrees/T1/svc" && git rev-parse HEAD )"

run_precheck() { ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T1 svc 2>&1 ); }

echo "── precheck verde"
stub_gitleaks 'exit 0'
out="$(run_precheck)"; rc=$?
assert_eq 0 "$rc" "worktree limpio: exit 0"
assert_contains "$out" "sin veredicto: precheck" "no corre el grupo de veredicto"
assert_not_contains "$out" "veredicto de review" "no exige verdict-<repo>.json"
assert_file "$WS/tasks/T1/precheck-svc.json" "deja el sello que lee /review"
sello="$(cat "$WS/tasks/T1/precheck-svc.json")"
assert_contains "$sello" '"ok":true' "sello verde"
assert_contains "$sello" "$head" "el sello ata al HEAD revisado (un commit nuevo lo invalida)"

echo "── precheck rojo"
stub_gitleaks 'echo "leak: token en app.txt"; exit 1'
out="$(run_precheck)"; rc=$?
[ "$rc" -ne 0 ] && pass "gate rojo: exit != 0" || fail "gate rojo: salió 0"
assert_contains "$out" "NO entregues a review" "el mensaje es el prompt del fix"
assert_contains "$out" "NO consume presupuesto de loop" "deja claro que no cuenta como ronda"
sello="$(cat "$WS/tasks/T1/precheck-svc.json")"
assert_contains "$sello" '"ok":false' "sello rojo (el /review no debe lanzar a nadie)"

echo "── el precheck no toca main"
( cd "$WS/repos/svc" && git rev-parse origin/main ) > "$WS/before"
stub_gitleaks 'exit 0'; run_precheck >/dev/null 2>&1
( cd "$WS/repos/svc" && git rev-parse origin/main ) > "$WS/after"
assert_eq "$(cat "$WS/before")" "$(cat "$WS/after")" "origin/main intacto: no hay push en precheck"
assert_no_file "$WS/locks/svc.lock.d" "no toma el lock de ship (no serializa a nadie)"

t_done
