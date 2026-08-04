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
# Caso de campo: /smart lanza la creación en paralelo; entre el chequeo "ya
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


echo
echo "── #76: las DEPENDENCIAS del go.work tambien se refrescan al crear el worktree"
# Un repo Go del monorepo depende de otros por `replace` relativo, y el go.work
# de la tarea los resuelve contra repos/ canonico. Si uno de esos clones quedo
# atras, `go build` falla en CUALQUIER tarea del repo, INCLUIDA LA BASE SIN
# CAMBIOS, con un error que no habla de staleness sino de un simbolo que no
# existe (`req.GetTokenDirect undefined`). El precheck sale rojo por una causa
# que no es del cambio; costo media hora diagnosticarlo.
# pull-all.sh no alcanza: SALTA los clones con cambios versionados (correcto) y
# deja la dependencia vieja igual.
D="$WS/d76"; mkdir -p "$D/scripts" "$D/worktrees"
cp "$ROOT/templates/scripts/worktree-task.sh" "$D/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$D/scripts/fe.sh"
chmod +x "$D/scripts"/*.sh

# gowork.sh stubbeado: escribe el go.work de la tarea apuntando a repos/pkg, que
# es exactamente el artefacto que worktree-task tiene que leer para saber QUE
# clones va a compilar esta tarea.
cat > "$D/scripts/gowork.sh" <<'STUB'
#!/usr/bin/env bash
WS="$(cd "$(dirname "$0")/.." && pwd)"
task="${1:-}"
[ -d "$WS/worktrees/$task" ] || exit 0
cat > "$WS/worktrees/$task/go.work" <<EOF
go 1.22

use (
	./svc
	../../repos/pkg
)

replace example.com/pkg v0.0.0 => ../../repos/pkg
EOF
STUB
chmod +x "$D/scripts/gowork.sh"

# origin de verdad (bare) para que el pull tenga de donde traer.
mk_con_origin() {  # mk_con_origin <repo>
  local r="$D/repos/$1" o="$D/origins/$1.git"
  mkdir -p "$r" "$o"; git init -q --bare -b main "$o"
  git init -q -b main "$r"
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  echo v1 > "$r/f.txt"; git -C "$r" add -A; git -C "$r" commit -qm v1
  git -C "$r" remote add origin "$o"
  git -C "$r" push -q origin main
  git -C "$r" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
}
avanza_origin() {  # avanza_origin <repo>: un commit que el clon canonico NO tiene
  local o="$D/origins/$1.git" c="$WS/clone-$1"
  rm -rf "$c"; git clone -q "$o" "$c"
  git -C "$c" config user.email t@t; git -C "$c" config user.name t
  echo v2 > "$c/f.txt"; git -C "$c" add -A; git -C "$c" commit -qm v2
  git -C "$c" push -q origin main
  git -C "$c" rev-parse HEAD
}

mk_con_origin svc
mk_con_origin pkg
PKG_NUEVO="$(avanza_origin pkg)"
PKG_ANTES="$( git -C "$D/repos/pkg" rev-parse HEAD )"
[ "$PKG_NUEVO" != "$PKG_ANTES" ] || fail "el fixture no dejo a pkg atrasado"

out76="$(bash "$D/scripts/worktree-task.sh" T76 svc 2>&1)" || true
PKG_DESPUES="$( git -C "$D/repos/pkg" rev-parse HEAD )"
# RED-FIRST: hoy nadie refresca pkg, asi que quedaba en PKG_ANTES.
assert_eq "$PKG_NUEVO" "$PKG_DESPUES" \
  "la dependencia del go.work queda AL DIA (antes se descubria por un simbolo faltante)"

echo
echo "── pero un clon con trabajo versionado NUNCA se pisa"
# Es el invariante de pull-all.sh y la unica forma de que este script destruya
# algo. Se avisa, no se fuerza.
PKG_NUEVO2="$(avanza_origin pkg)"
( cd "$D/repos/pkg"; echo "de otro" > wip.txt; git add wip.txt )
PKG_SUCIO="$( git -C "$D/repos/pkg" rev-parse HEAD )"
rm -rf "$D/worktrees/T77"
out77="$(bash "$D/scripts/worktree-task.sh" T77 svc 2>&1)" || true
assert_eq "$PKG_SUCIO" "$( git -C "$D/repos/pkg" rev-parse HEAD )" \
  "clon con cambios versionados: el HEAD NO se movio"
[ -n "$( git -C "$D/repos/pkg" status --porcelain )" ] \
  && pass "y su trabajo sigue ahi (nada se barrio)" \
  || fail "se perdio el trabajo versionado del clon canonico"
assert_contains "$out77" "no está limpio" "lo dice en vez de callarse"
assert_contains "$out77" "DEPENDENCIA del go.work" \
  "y nombra la CONSECUENCIA, no solo el hecho"
assert_contains "$out77" "símbolos que no existen" \
  "para que el rojo del compilador no sea una sorpresa"

echo
echo "── un repo sin Go no genera ruido de dependencias"
rm -f "$D/scripts/gowork.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$D/scripts/gowork.sh"; chmod +x "$D/scripts/gowork.sh"
rm -rf "$D/worktrees/T78"
out78="$(bash "$D/scripts/worktree-task.sh" T78 svc 2>&1)" || true
assert_not_contains "$out78" "DEPENDENCIA del go.work" \
  "sin go.work no hay nada que refrescar, y no se inventa un aviso"

t_done
