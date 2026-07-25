#!/usr/bin/env bash
# test_worktree_task.sh: --rm no puede destruir trabajo sin publicar.
#
# Bug P0: el chequeo era `git status --porcelain` (solo detecta cambios SIN
# commitear) y después `git branch -D`, que fuerza el borrado ignorando si la
# rama tiene commits sin mergear. Un worktree con trabajo commiteado y no
# shippeado queda "limpio" para ese chequeo, así que se borraba. En una tarea
# multi-repo el golpe es peor: /ship corre `--rm <task>` sobre TODOS los repos,
# así que shippear el repo A destruía la rama lista del repo B. Recuperable
# solo por reflog, cosa que ningún agente del harness sabe hacer.
#
# `git branch -d` (minúscula) YA implementa el chequeo correcto: se niega si la
# rama tiene commits sin mergear. El bug era estar pisándolo con la mayúscula.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts"; cp "$ROOT/templates/scripts/worktree-task.sh" "$WS/scripts/"
# gowork.sh y fe.sh son best-effort dentro del script: stubs para aislar.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/scripts/gowork.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/scripts/fe.sh"
chmod +x "$WS/scripts"/*.sh

mk_base() {  # mk_base <repo>: clon canónico con origin/main simulado
  local r="$WS/repos/$1"
  mkdir -p "$r" && git init -q "$r"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  echo base > "$r/f.txt"; git -C "$r" add -A; git -C "$r" commit -qm init
  git -C "$r" update-ref refs/remotes/origin/main HEAD
}
mk_wt() {  # mk_wt <repo> <task>: worktree en rama task/<task>
  git -C "$WS/repos/$1" worktree add -q -b "task/$2" "$WS/worktrees/$2/$1" HEAD
}
branch_exists() { git -C "$WS/repos/$1" show-ref --verify --quiet "refs/heads/task/$2"; }

echo "── una rama con trabajo sin publicar NO se borra"

mk_base repoB
mk_wt repoB T1
( cd "$WS/worktrees/T1/repoB" && echo trabajo > nuevo.txt \
  && git add -A && git commit -qm "trabajo listo, sin shippear" )

out="$(bash "$WS/scripts/worktree-task.sh" --rm T1 2>&1)"
branch_exists repoB T1 \
  && pass "la rama con commits sin publicar SOBREVIVE al --rm" \
  || fail "se destruyó trabajo sin publicar: el bug volvió"
assert_contains "$out" "CONSERVO la rama" "lo dice en vez de borrar en silencio"
assert_contains "$out" "1 commit(s) sin publicar" "cuenta cuántos commits salvó"
assert_contains "$out" "branch -D" "y da el comando explícito por si de verdad querés descartarlo"

echo
echo "── una rama ya publicada sí se limpia (el camino feliz no se rompe)"

mk_base repoA
mk_wt repoA T2
# Sin commits propios: la rama está en el mismo punto que main, o sea mergeada.
out="$(bash "$WS/scripts/worktree-task.sh" --rm T2 2>&1)"
branch_exists repoA T2 \
  && fail "la rama ya publicada debería haberse limpiado" \
  || pass "rama sin trabajo pendiente: se borra normalmente"
assert_contains "$out" "ya está publicado" "explica por qué fue seguro borrarla"

echo
echo "── el caso multi-repo que originó el bug"

mk_base ds; mk_base vc
mk_wt ds T3; mk_wt vc T3
( cd "$WS/worktrees/T3/vc" && echo pendiente > x.txt \
  && git add -A && git commit -qm "videocore listo, aún sin ship" )
# design-system ya shippeó; el /ship corre --rm sobre TODA la tarea.
bash "$WS/scripts/worktree-task.sh" --rm T3 >/dev/null 2>&1
branch_exists vc T3 \
  && pass "shippear un repo NO destruye la rama pendiente del otro" \
  || fail "el --rm de la tarea se llevó el trabajo del repo que faltaba"
branch_exists ds T3 \
  && fail "la rama del repo ya publicado debió limpiarse" \
  || pass "y el repo ya publicado sí se limpia"

echo
echo "── 'no pude mirar' no es 'está limpio'"

mk_base roto
mk_wt roto T4
rm -rf "$WS/worktrees/T4/roto/.git"   # worktree corrupto: git status falla
out="$(bash "$WS/scripts/worktree-task.sh" --rm T4 2>&1)"
assert_contains "$out" "no pude inspeccionar" "un git que falla NO se lee como árbol limpio"
branch_exists roto T4 \
  && pass "ante la duda, la rama se conserva" \
  || fail "se borró la rama de un worktree que no se pudo inspeccionar"

t_done
