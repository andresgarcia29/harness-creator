#!/usr/bin/env bash
# test_base_branch.sh: la rama trunk no siempre se llama "main".
#
# Catorce ocurrencias de origin/main en ship.sh y seis en worktree-task.sh
# daban por hecho el nombre. Cualquier repo con `master`, `trunk` o `develop`
# (todo GitHub/GitLab pre-2021 sin migrar) moría en la creación del worktree
# con "invalid reference", y de paso block-direct-push tampoco protegía esas
# ramas porque solo bloqueaba `main`: la Ley 1 no aplicaba justo donde más
# falta hacía.
#
# La técnica correcta ya estaba en el repo: skills-sync.sh resuelve la rama
# por defecto con origin/HEAD desde siempre.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

R="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$WS/scripts" "$WS/bin" "$WS/tasks/T1" "$WS/repos" "$WS/worktrees/T1"
sed 's/{{LOOP_BUDGET}}/3/g' "$R/templates/scripts/ship.sh.tmpl" > "$WS/scripts/ship.sh"
cp "$R/templates/scripts/worktree-task.sh" "$WS/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/scripts/gowork.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/scripts/fe.sh"
printf '#!/bin/sh\nexit 0\n' > "$WS/bin/gitleaks"
chmod +x "$WS/scripts"/*.sh "$WS/bin/gitleaks"

# Con un origin REAL (bare): worktree-task.sh hace `fetch origin` sin guarda,
# así que un fixture con refs simuladas no alcanza. Y de paso el test se
# parece más a un workspace de verdad.
mk_repo() {  # mk_repo <nombre> <rama-trunk>
  local bare="$WS/origins/$1.git" r="$WS/repos/$1"
  mkdir -p "$WS/origins"
  git init -q --bare -b "$2" "$bare"
  git init -q -b "$2" "$r"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  echo base > "$r/app.txt"; git -C "$r" add -A; git -C "$r" commit -qm init
  git -C "$r" remote add origin "$bare"
  git -C "$r" push -q origin "$2"
  git -C "$r" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$2"
}

echo "── worktree-task crea el worktree desde la rama trunk real"

mk_repo svc-master master
out="$(bash "$WS/scripts/worktree-task.sh" T1 svc-master 2>&1)"
# En un worktree, .git es un ARCHIVO (apunta al gitdir), no un directorio.
[ -e "$WS/worktrees/T1/svc-master/.git" ] \
  && pass "repo con 'master': el worktree se crea (antes: invalid reference)" \
  || { fail "no se creó el worktree en un repo con master"; echo "$out" | head -3; }
assert_not_contains "$out" "invalid reference" "sin el error que rompía el pipeline"

mk_repo svc-main main
bash "$WS/scripts/worktree-task.sh" T1 svc-main >/dev/null 2>&1
[ -e "$WS/worktrees/T1/svc-main/.git" ] \
  && pass "repo con 'main': sigue funcionando igual" || fail "se rompió el caso normal"

echo
echo "── ship.sh compara contra la rama trunk real, no contra 'main'"

( cd "$WS/worktrees/T1/svc-master" && echo x > f.txt && git add -A \
  && git commit -qm feat --trailer "Task: T1" ) >/dev/null 2>&1
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T1 svc-master 2>&1 )"; rc=$?
assert_eq 0 "$rc" "precheck sobre un repo con 'master': verde"
assert_not_contains "$out" "unknown revision" "no busca una origin/main que no existe"
assert_file "$WS/tasks/T1/precheck-svc-master.json" "y deja su sello"

echo
echo "── una rama base inválida FALLA, no pasa en verde"
# Bug encontrado escribiendo este test: los gates que comparan contra el trunk
# (tests no debilitados, carril, migraciones) envuelven su git en `|| true`
# para tolerar un repo sin cambios. Con una ref inexistente, git falla, el
# `|| true` se lo traga, el diff sale VACÍO y TODOS pasan sin mirar nada: el
# precheck imprimía "✅ precheck verde". Desarmaba justo el gate anti-trampa.
out="$( cd "$WS" && PATH="$WS/bin:$PATH" HARNESS_BASE_BRANCH=no-existe \
        bash scripts/ship.sh --precheck T1 svc-master 2>&1 )"
assert_contains "$out" "no existe la rama base" "rama base inválida: se detecta"
assert_contains "$out" "pasarían en verde sin mirar nada" "y explica por qué eso sería peor que fallar"
assert_not_contains "$out" "precheck verde" "y NO reporta verde (era el bug)"
assert_contains "$out" "HARNESS_BASE_BRANCH" "la remediación nombra el override"

echo
echo "── block-direct-push protege la rama trunk real, y 'main' siempre"

hook="$R/templates/hooks/block-direct-push.sh"
rc_of() {  # rc_of <dir> <comando>
  ( cd "$1" && printf '{"tool_input":{"command":"%s"}}' "$2" | bash "$hook" >/dev/null 2>&1; echo $? )
}
m="$WS/repos/svc-master"
assert_eq 2 "$(rc_of "$m" "git push origin master")" "repo con master: push a master BLOQUEADO"
assert_eq 2 "$(rc_of "$m" "git push origin HEAD:master")" "y también con refspec"
assert_eq 2 "$(rc_of "$m" "git push origin main")" "'main' se bloquea SIEMPRE (nunca se protege de menos)"
assert_eq 0 "$(rc_of "$m" "git push origin task/T1")" "una rama de tarea sí pasa"

echo
echo "── issue #32: un origin/HEAD envenenado no manda al worktree a otra rama"
# El ref local se escribe UNA vez al clonar; un `remote set-head` posterior
# (cualquier flujo que trabaje el clon en otra rama) lo dejaba apuntando ahí
# para siempre, en silencio. Ahora base_branch le pregunta AL REMOTO
# (ls-remote --symref) y sana el ref local de paso; offline cae al local.

mk_repo svc-trunk trunk
# el veneno: una rama vieja publicada y el set-head local apuntándole
git -C "$WS/repos/svc-trunk" checkout -qb task/vieja
git -C "$WS/repos/svc-trunk" push -q origin task/vieja
git -C "$WS/repos/svc-trunk" checkout -q trunk
git -C "$WS/repos/svc-trunk" remote set-head origin task/vieja

extract_bb() {  # extract_bb <archivo> → base_branch() a un archivo sourceable
  awk '/^base_branch\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$1"
}
extract_bb "$WS/scripts/worktree-task.sh" > "$WS/bb-wt.sh"
grep -q "ls-remote" "$WS/bb-wt.sh" || { echo "no pude extraer base_branch de worktree-task"; exit 1; }
b="$( ( set -u; . "$WS/bb-wt.sh"; base_branch "$WS/repos/svc-trunk" ) )"
assert_eq trunk "$b" "worktree-task: el remoto manda, el veneno local no"
assert_eq "origin/trunk" "$(git -C "$WS/repos/svc-trunk" symbolic-ref --short refs/remotes/origin/HEAD)" \
  "y el ref local quedó SANADO (los lectores sin red heredan el valor bueno)"

git -C "$WS/repos/svc-trunk" remote set-head origin task/vieja   # re-envenena
extract_bb "$WS/scripts/ship.sh" > "$WS/bb-ship.sh"
grep -q "ls-remote" "$WS/bb-ship.sh" || { echo "no pude extraer base_branch de ship"; exit 1; }
b="$( ( set -u; . "$WS/bb-ship.sh"; base_branch "$WS/repos/svc-trunk" ) )"
assert_eq trunk "$b" "ship: misma autoridad, mismo resultado"

# offline (sin remote alcanzable): cae al ref local, degradar no es inventar
git -C "$WS/repos/svc-trunk" remote set-head origin task/vieja   # el caso ship lo había sanado
git -C "$WS/repos/svc-trunk" remote set-url origin /ruta/inexistente.git
b="$( ( set -u; . "$WS/bb-wt.sh"; base_branch "$WS/repos/svc-trunk" ) )"
assert_eq "task/vieja" "$b" "offline: cae al ref local tal cual (sin inventar)"
git -C "$WS/repos/svc-trunk" remote set-url origin "$WS/origins/svc-trunk.git"

echo
echo "── el gotcha de set -e que esto destapó"
# `[ -n "$X" ] && VAR=...` devuelve 1 cuando X está vacío y MATA el script con
# set -e. El precheck salía con exit 128 sin imprimir una línea. Se usa `if`.
for f in "$R/templates/scripts/ship.sh.tmpl" "$R/templates/scripts/worktree-task.sh"; do
  if grep -q '\[ -n "${HARNESS_BASE_BRANCH:-}" \] &&' "$f"; then
    fail "$(basename "$f"): volvió el '&&' que mata bajo set -e"
  else
    pass "$(basename "$f"): usa if, no el && que mata bajo set -e"
  fi
done

t_done
