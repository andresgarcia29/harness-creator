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

echo
echo "── modo creación: dos creadores del mismo (task, repo) no se pisan"
# Caso de campo: /auto lanza la creación en paralelo; entre el chequeo "ya
# existe" y el worktree add hay un fetch de por medio, y dos procesos pasaban
# juntos. El segundo moría mudo a mitad del bucle (el error iba a /dev/null) o,
# peor, dos implementers terminaban compartiendo árbol y un git add se llevaba
# el trabajo del otro.

mk_origin_base() {  # <repo>: canónico con origin REAL (el modo creación fetchea)
  local o="$WS/origins/$1" r="$WS/repos/$1"
  mkdir -p "$o" && git init -q "$o"
  git -C "$o" config user.email t@t; git -C "$o" config user.name t
  echo base > "$o/f.txt"; git -C "$o" add -A; git -C "$o" commit -qm init
  git clone -q "$o" "$r" 2>/dev/null
}

# 1. camino feliz: crea worktree y rama, y no deja lock atrás
mk_origin_base repoC
out="$(bash "$WS/scripts/worktree-task.sh" T10 repoC 2>&1)"; rc=$?
assert_eq 0 "$rc" "creación normal: sale 0"
[ -d "$WS/worktrees/T10/repoC" ] && pass "el worktree existe" || fail "no creó el worktree"
branch_exists repoC T10 && pass "la rama task/T10 existe" || fail "no creó la rama"
assert_no_file "$WS/locks/wt-T10__repoC.lock.d" "el lock de creación se libera al terminar"

# 2. re-entrada: ya existe, no revienta
out="$(bash "$WS/scripts/worktree-task.sh" T10 repoC 2>&1)"; rc=$?
assert_eq 0 "$rc" "re-correr con el worktree ya creado: sale 0"
assert_contains "$out" "ya existe" "y lo dice"

# 3. lock tomado por un proceso VIVO: el segundo creador se niega con mensaje
mk_origin_base repoD
mkdir -p "$WS/locks/wt-T11__repoD.lock.d"
echo $$ > "$WS/locks/wt-T11__repoD.lock.d/pid"     # este shell: bien vivo
out="$(HARNESS_WT_LOCK_WAIT=2 bash "$WS/scripts/worktree-task.sh" T11 repoD 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "lock ocupado por proceso vivo: el segundo claim se RECHAZA" \
  || fail "dos creadores concurrentes pasaron a la vez"
assert_contains "$out" "está creando el worktree" "nombra la causa"
assert_contains "$out" "rm -rf" "y da la salida manual exacta si el dueño murió"
rm -rf "$WS/locks/wt-T11__repoD.lock.d"

# 4. lock huérfano (pid muerto): se reclama solo y la creación sigue
sh -c 'exit 0' & dead_pid=$!; wait "$dead_pid" 2>/dev/null
mkdir -p "$WS/locks/wt-T12__repoD.lock.d"
echo "$dead_pid" > "$WS/locks/wt-T12__repoD.lock.d/pid"
out="$(bash "$WS/scripts/worktree-task.sh" T12 repoD 2>&1)"; rc=$?
assert_eq 0 "$rc" "lock huérfano: se reclama y la creación termina"
assert_contains "$out" "huérfano" "y lo dice"

# 5. concurrencia real: dos procesos a la vez, cero muertes mudas
mk_origin_base repoE
bash "$WS/scripts/worktree-task.sh" T13 repoE >"$WS/c1.out" 2>&1 & p1=$!
bash "$WS/scripts/worktree-task.sh" T13 repoE >"$WS/c2.out" 2>&1 & p2=$!
wait "$p1"; rc1=$?; wait "$p2"; rc2=$?
assert_eq "0 0" "$rc1 $rc2" "dos creadores en paralelo: ambos salen 0 (uno crea, el otro ve 'ya existe' o espera)"
[ -d "$WS/worktrees/T13/repoE" ] && pass "el worktree quedó creado una sola vez" || fail "no quedó worktree"
n="$(ls -d "$WS/locks/wt-T13__"*.lock.d 2>/dev/null | wc -l | tr -d ' ')"
assert_eq 0 "$n" "sin locks huérfanos después de la carrera"

# 6. --rm limpia también los locks de creación de la tarea
mkdir -p "$WS/locks/wt-T13__repoE.lock.d"
bash "$WS/scripts/worktree-task.sh" --rm T13 >/dev/null 2>&1
assert_no_file "$WS/locks/wt-T13__repoE.lock.d" "--rm purga los locks de creación de la tarea"

t_done
