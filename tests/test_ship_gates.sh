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
  ( set -u; WS="$WS"; TASK=T1; REPO=test; BASE_REF=main
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
( set -u; WS="$WS"; TASK=T1; REPO=test; BASE_REF=main; gate(){ :; }; emit(){ :; }
  . "$WS/gate_lane.sh"; gate_lane ) \
  && pass "sin state.json: default full, no bloquea" || fail "sin state.json: bloqueó"

echo "── gates en paralelo: un rojo no esconde a los demás"

run_pargates() {  # run_pargates <security-rc> [precheck]: grupos stub, security parametrizado
  ( set -eu; WS="$WS"; REPO=test; CURRENT_GATE=""; sec_rc="$1"; PRECHECK="${2:-0}"
    emit() { :; }; gate() { CURRENT_GATE="$1"; }
    # run_parallel_gates llama al envoltorio que sella la corrida como
    # evidencia; el stub va sobre ESE nombre. La distinción importa: es la
    # pieza que elimina una corrida entera de la suite por tarea.
    run_lang_gates() { echo LANG-EVIDENCIA; }
    run_lang_gates_sealed() { run_lang_gates; }
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

# precheck: mismos grupos mecánicos, sin el de veredicto (todavía no existe).
# El detalle importa: si el precheck exigiera veredicto, jamás podría correr
# ANTES del review, que es toda su razón de ser.
out="$(run_pargates 0 1 2>&1)"; rc=$?
assert_eq 0 "$rc" "precheck: verde sin veredicto"
assert_contains "$out" "LANG-EVIDENCIA" "precheck: corre los gates mecánicos"
assert_not_contains "$out" "VERDICT-EVIDENCIA" "precheck: NO corre el grupo de veredicto"


echo "── gate_tests_untouched v2: neto real, escape que declara"

extract gate_tests_untouched > "$WS/gate_tests.sh"
grep -q "contabilidad NETA" "$WS/gate_tests.sh" || grep -q "global_na" "$WS/gate_tests.sh" || { echo "no pude extraer gate_tests_untouched"; exit 1; }

run_tests_gate() {  # corre el gate en el repo actual; usa $WS/tasks/T1 para delta
  ( set -u; WS="$WS"; TASK=T1; REPO=test; BASE_REF=main
    gate() { :; }; emit() { :; }
    . "$WS/gate_tests.sh"; gate_tests_untouched )
}
mkdir -p "$WS/tasks/T1"

# fixture base: un archivo de test con contenido realista
mk_test_repo() {  # mk_test_repo <dir>
  mk_repo "$1"
  mkdir -p tests
  cat > tests/auth.test.js <<'FIX'
import { expect } from 'chai'
// this behavior is asserted below
describe('auth', () => {
  it('valida token', () => {
    expect(login('tok')).toEqual(true)
    expect(logout()).toEqual(true)
  })
})
FIX
  git add . && git commit -qm tests
  git update-ref refs/remotes/origin/main HEAD
}

# 1+2. bug de campo EXACTO: import con 'expect' y comentario con 'asserted'
#      MOVIDOS de lugar (no borrados) → no bloquea
mk_test_repo "$WS/g1"
python3 - <<'PY'
lines = open('tests/auth.test.js').read().split('\n')
# mueve el import y el comentario al final del archivo
moved = [l for l in lines if not (l.startswith('import ') or l.startswith('// this'))]
moved += ['// this behavior is asserted below', "import { expect } from 'chai'"]
open('tests/auth.test.js','w').write('\n'.join(moved))
PY
git add . && git commit -qm move
rm -f "$WS/tasks/T1/delta-spec.md"
run_tests_gate >/dev/null 2>&1 && pass "import/comentario movidos: NO bloquea (bug de campo #1)" || fail "import/comentario movidos bloquearon"

# 3. aserción real borrada → bloquea nombrando el archivo
mk_test_repo "$WS/g2"
grep -v "logout" tests/auth.test.js > t.tmp && mv t.tmp tests/auth.test.js
git add . && git commit -qm quita-asercion
out="$(run_tests_gate 2>&1)"; rc=$?
assert_eq 3 "$rc" "aserción neta eliminada: bloquea"
assert_contains "$out" "auth.test.js" "el mensaje nombra el archivo debilitado"

# 4. lo mismo pero DECLARADO en sección MODIFIED con basename → pasa
cat > "$WS/tasks/T1/delta-spec.md" <<'FIX'
## MODIFIED Requirements
- AUTH-2: el logout ya no es parte del flujo; se ajusta auth.test.js
FIX
run_tests_gate >/dev/null 2>&1 && pass "declarado en sección con basename: pasa" || fail "declaración legítima bloqueada"

# 5. la palabra REMOVED en PROSA sin nombrar el archivo → sigue bloqueando
cat > "$WS/tasks/T1/delta-spec.md" <<'FIX'
Contexto: este cambio no tiene nada REMOVED ni MODIFIED de fondo.

## ADDED Requirements
- AUTH-9: nueva validación
FIX
run_tests_gate >/dev/null 2>&1 && fail "la palabra en prosa abrió el escape (bug de campo #2)" || pass "palabra en prosa sin sección+basename: NO abre (bug de campo #2)"
rm -f "$WS/tasks/T1/delta-spec.md"

# 6. xit( añadido → bloquea
mk_test_repo "$WS/g3"
python3 -c "
s=open('tests/auth.test.js').read()
open('tests/auth.test.js','w').write(s.replace(\"it('valida token'\", \"xit('valida token'\"))"
git add . && git commit -qm skip
run_tests_gate >/dev/null 2>&1 && fail "xit( no bloqueó" || pass "xit( añadido: bloquea"

# 7. git mv del archivo de test → no bloquea
mk_test_repo "$WS/g4"
git mv tests/auth.test.js tests/auth.spec.js && git commit -qm rename
run_tests_gate >/dev/null 2>&1 && pass "git mv de test: NO bloquea (rename con -M)" || fail "rename bloqueó"

# 8. bare assert de Python borrado → cuenta y bloquea
mk_test_repo "$WS/g5"
mkdir -p tests && printf 'def test_x():\n    assert calc() == 4\n    assert calc() != 5\n' > tests/test_calc.py
git add . && git commit -qm py && git update-ref refs/remotes/origin/main HEAD
printf 'def test_x():\n    assert calc() == 4\n' > tests/test_calc.py
git add . && git commit -qm quita-bare
run_tests_gate >/dev/null 2>&1 && fail "bare assert borrado no bloqueó" || pass "bare assert de Python borrado: bloquea"

echo
echo "── gate ts: un gate que no puede correr NO reporta rojo"
# Caso de campo: el worktree nace de origin/main, sin node_modules y sin los
# tipos de `astro sync`. tsc escupía 8 errores (import.meta.env, astro:assets)
# que parecían deuda vieja y eran fantasma: con las deps puestas pasó sin
# tocar una línea. Un rojo falso cuesta una ronda y enseña a desconfiar del gate.

extract run_lang_gates > "$WS/lang.sh"
grep -q 'node_modules' "$WS/lang.sh" || { echo "no pude extraer run_lang_gates"; exit 1; }

run_lang() {  # run_lang <dir>: corre run_lang_gates ahí, con la toolchain stubbeada
  ( set -u; cd "$1"; WT="$1"; REPO=fe; TASK=T1; BASE_REF=main
    gate() { :; }; emit() { :; }
    npx() { :; }; npm() { :; }   # la toolchain real no se ejercita aquí
    . "$WS/lang.sh"; run_lang_gates ) 2>&1
}

mk_fe() {  # mk_fe <dir>: proyecto node mínimo en un repo git
  rm -rf "$1"; mkdir -p "$1"; cd "$1"
  git init -q .; git config user.email t@t; git config user.name t
  echo '{"name":"fe"}' > package.json
  echo '{}' > tsconfig.json
  git add -A && git commit -qm init
  git update-ref refs/remotes/origin/main HEAD
  cd "$WS"
}

# 1. sin node_modules → se niega, y lo dice sin fingir un veredicto
mk_fe "$WS/fe1"
out="$(run_lang "$WS/fe1")"; rc=$?
assert_eq 3 "$rc" "sin node_modules: el gate se niega (exit 3)"
assert_contains "$out" "NO PUEDE CORRER" "sin node_modules: dice que no puede correr"
assert_contains "$out" "fantasma" "sin node_modules: avisa que los errores serían fantasma"
assert_contains "$out" "fe.sh 'install'" "sin node_modules: da la remediación exacta"

# 2. Astro sin los tipos generados → se niega citando astro sync
mk_fe "$WS/fe2"; mkdir -p "$WS/fe2/node_modules"; touch "$WS/fe2/astro.config.mjs"
out="$(run_lang "$WS/fe2")"; rc=$?
assert_eq 3 "$rc" "Astro sin .astro/types.d.ts: el gate se niega"
assert_contains "$out" "astro sync" "Astro: la remediación nombra astro sync"
assert_contains "$out" "astro:assets" "Astro: nombra los símbolos que saldrían como fantasma"

# 3. Astro CON los tipos → ya no se niega
mkdir -p "$WS/fe2/.astro" && touch "$WS/fe2/.astro/types.d.ts"
run_lang "$WS/fe2" >/dev/null 2>&1 \
  && pass "Astro con types.d.ts: el gate corre" || fail "Astro preparado: el gate no debió negarse"

# 4. node sin Astro y con deps → corre normal
mk_fe "$WS/fe3"; mkdir -p "$WS/fe3/node_modules"
run_lang "$WS/fe3" >/dev/null 2>&1 \
  && pass "node con deps: el gate corre" || fail "node preparado: el gate no debió negarse"

echo
echo "── gate ts: se cura solo, pero sin tocar el artefacto que juzga"
# Preparar no es verificar: instalar deps no cambia lo que se shippea, es la
# condición para poder mirarlo. La frontera se sostiene con una prueba, no con
# una promesa: si preparar movió un archivo VERSIONADO, el gate se detiene.

mkdir -p "$WS/scripts"
mk_fe_stub() {  # mk_fe_stub <cuerpo> : instala el fe.sh que verá el gate
  printf '#!/usr/bin/env bash\ncd "%s" || exit 1\n%s\n' "$1" "$2" > "$WS/scripts/fe.sh"
}

# 9. la preparación funciona → el gate sigue, y lo dice
mk_fe "$WS/fe8"
mk_fe_stub "$WS/fe8" 'mkdir -p node_modules'
out="$(run_lang "$WS/fe8")"; rc=$?
assert_eq 0 "$rc" "prep exitosa: el gate continúa en vez de devolverte el trabajo"
assert_contains "$out" "preparo la toolchain" "dice que preparó (no lo hace a escondidas)"
assert_contains "$out" "sin tocar archivos versionados" "declara que respetó la frontera"

# 10. astro sync que sí genera los tipos → sigue
mk_fe "$WS/fe9"; touch "$WS/fe9/astro.config.mjs"
cd "$WS/fe9" && git add -A && git commit -qm astro && cd "$WS"
mk_fe_stub "$WS/fe9" 'mkdir -p node_modules'
out="$( ( cd "$WS/fe9"; WT="$WS/fe9"; REPO=fe; TASK=T1; WS="$WS"
          gate() { :; }; npm() { :; }
          npx() { if [ "$*" = "astro sync" ]; then mkdir -p .astro && touch .astro/types.d.ts; fi; }
          . "$WS/lang.sh"; run_lang_gates ) 2>&1 )"; rc=$?
assert_eq 0 "$rc" "astro sync exitoso: el gate continúa"
assert_contains "$out" "types.d.ts" "nombra lo que le faltaba"

# 11. LA FRONTERA: si preparar ensucia un archivo versionado, se detiene
mk_fe "$WS/fe10"; cd "$WS/fe10"
echo '{"lockfileVersion":1}' > package-lock.json
git add -A && git commit -qm lock; cd "$WS"
mk_fe_stub "$WS/fe10" 'mkdir -p node_modules; echo "{\"lockfileVersion\":2}" > package-lock.json'
out="$(run_lang "$WS/fe10")"; rc=$?
assert_eq 3 "$rc" "prep que toca un archivo versionado: el gate se detiene"
assert_contains "$out" "archivos VERSIONADOS" "nombra la frontera cruzada"
assert_contains "$out" "package-lock.json" "muestra qué archivo se movió"
assert_contains "$out" "artefacto que este gate juzga" "explica por qué eso ya no es preparar"

# 12. un install que dice OK pero no deja node_modules no cuela
mk_fe "$WS/fe11"
mk_fe_stub "$WS/fe11" 'exit 0'
out="$(run_lang "$WS/fe11")"; rc=$?
assert_eq 3 "$rc" "prep que miente (exit 0 sin instalar): el gate no le cree"
assert_contains "$out" "no pude instalar" "verifica el resultado, no el exit code"

cd "$WS"

echo
echo "── gate ts: lo que no encuentra qué verificar, lo dice"
# Bug de campo: --precheck no corría ni typecheck ni tests en repos TS, y por
# eso un commit roto llegó hasta el gate de ship. Dos agujeros, los dos
# silenciosos: package.json fuera de la raíz, y TS sin forma declarada de
# chequear. Un gate ausente se lee igual que un gate verde.

# 5. package.json solo en subdirectorios → se niega en vez de ausentarse
mk_fe "$WS/fe4"; cd "$WS/fe4"
rm -f package.json tsconfig.json
mkdir -p apps/web && echo '{"name":"web"}' > apps/web/package.json
git add -A && git commit -qm monorepo; cd "$WS"
out="$(run_lang "$WS/fe4")"; rc=$?
assert_eq 3 "$rc" "package.json solo en subdirs: el gate se niega"
assert_contains "$out" "no tiene package.json en la raíz" "monorepo: nombra la causa"
assert_contains "$out" "apps/web/package.json" "monorepo: muestra dónde sí lo encontró"
assert_contains "$out" "en silencio" "monorepo: dice que antes se saltaba callado"

# 6. TS sin tsconfig y sin script de typecheck → se niega
mk_fe "$WS/fe5"; cd "$WS/fe5"; rm -f tsconfig.json
echo '{"name":"fe","devDependencies":{"typescript":"^5"}}' > package.json
git add -A && git commit -qm ts-sin-config; cd "$WS"
mkdir -p "$WS/fe5/node_modules"
out="$(run_lang "$WS/fe5")"; rc=$?
assert_eq 3 "$rc" "TS sin forma de chequear: el gate se niega"
assert_contains "$out" "no encontró cómo typechequearlo" "TS: nombra la causa exacta"
assert_contains "$out" "typecheck" "TS: la remediación pide declarar el script"

# 7. el script del repo manda sobre tsc (Astro se chequea con astro check)
mk_fe "$WS/fe6"; cd "$WS/fe6"
echo '{"name":"fe","scripts":{"typecheck":"astro check","test":"vitest run"}}' > package.json
git add -A && git commit -qm scripts; cd "$WS"
mkdir -p "$WS/fe6/node_modules"
out="$( ( cd "$WS/fe6"; WT="$WS/fe6"; REPO=fe; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }
          npx() { echo "NO-DEBERIA-CORRER-TSC"; }
          npm() { echo "npm $*"; }
          . "$WS/lang.sh"; run_lang_gates ) 2>&1 )"
assert_contains "$out" "npm run typecheck" "usa el typecheck declarado por el repo"
assert_not_contains "$out" "NO-DEBERIA-CORRER-TSC" "y NO cae a tsc --noEmit cuando el repo ya dijo cómo"
assert_contains "$out" "npm test" "corre los tests declarados"

# 8. sin script test → avisa en vez de callarse (antes: --if-present mudo)
mk_fe "$WS/fe7"; cd "$WS/fe7"; cd "$WS"
mkdir -p "$WS/fe7/node_modules"
out="$(run_lang "$WS/fe7")"
assert_contains "$out" "NO corrió tests" "sin script test: lo dice en vez de callarse"

cd "$WS"

echo
echo "── gate de lenguaje: los stacks que faltaban, y el silencio que quedaba"
# Bug P0: run_lang_gates solo reconocia go/node/python/dart. Un repo Rust,
# Java, Ruby, PHP, .NET o Elixir salia VERDE del precheck con el build roto y
# ship.sh lo pushaba a main. Para un instalador universal era el agujero mas
# grande: solo cuatro stacks se verificaban de verdad.

mk_stack() {  # mk_stack <dir> <archivo-marcador>
  rm -rf "$1"; mkdir -p "$1"; cd "$1"
  git init -q .; git config user.email t@t; git config user.name t
  : > "$2"; git add -A && git commit -qm init
  git update-ref refs/remotes/origin/main HEAD
  cd "$WS"
}
run_lang_bare() {  # sin stubs de toolchain: mide qué dice cuando no está
  ( set -u; cd "$1"; WT="$1"; REPO=r; TASK=T1; BASE_REF=main
    gate() { :; }; emit() { :; }
    . "$WS/lang.sh"; run_lang_gates ) 2>&1
}

# Un stub del binario hace que `command -v` lo encuentre y que la rama corra:
# si el stub imprime, la rama existe. Sin stub correriamos toolchains reales.
check_stack() {  # check_stack <dir> <marcador> <bin> <label> [archivo-extra]
  mk_stack "$1" "$2"
  [ -n "${5:-}" ] && ( cd "$1" && : > "$5" )
  out="$( ( cd "$1"; WT="$1"; REPO=r; TASK=T1; BASE_REF=main
            gate() { :; }; emit() { :; }
            eval "$3() { echo RAN-$3; }"
            . "$WS/lang.sh"; run_lang_gates ) 2>&1 )"
  assert_contains "$out" "RAN-$3" "reconoce $4 por $2 y corre su toolchain"
  cd "$WS"
}
check_stack "$WS/st-rust"   Cargo.toml    cargo   Rust
check_stack "$WS/st-maven"  pom.xml       mvn     Java-Maven
check_stack "$WS/st-elixir" mix.exs       mix     Elixir
check_stack "$WS/st-ruby"   Gemfile       bundle  Ruby        Rakefile
check_stack "$WS/st-php"    composer.json composer PHP        phpunit.xml

# Marcador presente pero toolchain ausente: se dice, no se finge un veredicto.
mk_stack "$WS/st-sinbin" Cargo.toml
out="$( ( cd "$WS/st-sinbin"; WT="$WS/st-sinbin"; REPO=r; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }
          PATH=/nonexistent
          . "$WS/lang.sh"; run_lang_gates ) 2>&1 )"
assert_contains "$out" "no está instalado" "marcador sin toolchain: lo dice"
assert_contains "$out" "NO CORRIÓ" "y dice que ese gate no corrió"
cd "$WS"

# El caso que importa: stack no reconocido ya NO pasa callado.
mk_stack "$WS/st-raro" "algo.xyz"
out="$(run_lang_bare "$WS/st-raro")"
assert_contains "$out" "no reconozco el stack" "stack desconocido: lo DICE"
assert_contains "$out" "NO compiló ni testeó nada" "y dice exactamente qué no hizo"
assert_contains "$out" "CONTRIBUTING #8" "y apunta a la regla que lo gobierna"

# Un stack reconocido NO dispara ese aviso.
mk_stack "$WS/st-go" "go.mod"
out="$( ( cd "$WS/st-go"; WT="$WS/st-go"; REPO=r; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }; go() { :; }
          . "$WS/lang.sh"; run_lang_gates ) 2>&1 )"
assert_not_contains "$out" "no reconozco el stack" "stack reconocido: sin aviso"

cd "$WS"

echo
echo "── check_verdict: cada rechazo nombra su causa y su remediación"
# Bug de campo: verdict:"pass" + qa:"pending" salía como "veredicto no es pass,
# corrige los items blocking", con blocking vacío. La remediación real era
# correr la fase QA. Mensaje que manda a una lista vacía = ronda quemada.

extract check_verdict > "$WS/check_verdict.sh"
grep -q 'qa_state' "$WS/check_verdict.sh" || { echo "no pude extraer check_verdict"; exit 1; }

run_check_verdict() {  # run_check_verdict <verdict-json> [sin-qa] — salida + exit
  mkdir -p "$WS/tasks/T9"
  printf '%s' "$1" > "$WS/tasks/T9/verdict-svc.json"
  # Un qa:"pass" ahora exige artefacto (qa-<repo>.json o evidencia runner=qa).
  # El fixture lo provee salvo que el caso pruebe justamente su ausencia.
  if [ "${2:-}" = "sin-qa" ]; then rm -f "$WS/tasks/T9/qa-svc.json"
  else printf '{"schema":1,"qa":"pass"}' > "$WS/tasks/T9/qa-svc.json"; fi
  ( set -u; WS="$WS"; TASK=T9; REPO=svc; BASE_REF=main
    gate() { :; }
    . "$WS/check_verdict.sh"; check_verdict ) 2>&1
}

# 1. todo verde → pasa
out="$(run_check_verdict '{"verdict":"pass","qa":"pass","blocking":[],"requirements_uncovered":0}')"
assert_eq 0 $? "verdict pass + qa pass + 0 uncovered: pasa"

# 2. review con blocking → nombra al review, cuenta los blocking
out="$(run_check_verdict '{"verdict":"fail","qa":"pass","blocking":[{"a":1},{"b":2}],"requirements_uncovered":0}')"
assert_eq 3 $? "review fail: rechaza con exit 3"
assert_contains "$out" "el review no es pass" "review fail: nombra al review, no a QA"
assert_contains "$out" "los 2 items blocking" "review fail: cuenta los blocking reales"

# 3. el bug de campo: review pass, QA nunca corrió
out="$(run_check_verdict '{"verdict":"pass","qa":"pending","blocking":[],"requirements_uncovered":0}')"
assert_eq 3 $? "qa pending: rechaza con exit 3"
assert_contains "$out" "QA no es pass (qa=pending)" "qa pending: nombra a QA, no al review"
assert_not_contains "$out" "items blocking" "qa pending: NO manda a una lista blocking vacía"
assert_contains "$out" "evidence.py run" "qa pending: ofrece la ruta determinista (sin navegador)"
assert_contains "$out" "qa-svc.json" "qa pending: dice dónde escribir el resultado"

# 4. QA corrió y falló → remediación opuesta a la de pending
out="$(run_check_verdict '{"verdict":"pass","qa":"fail","blocking":[],"requirements_uncovered":0}')"
assert_eq 3 $? "qa fail: rechaza con exit 3"
assert_contains "$out" "regrésalas al implementer" "qa fail: manda al implementer, no a correr QA"
assert_not_contains "$out" "evidence.py run" "qa fail: NO repite la receta de 'nunca corrió'"

# 5. el gate de compliance sigue vivo detrás de los dos anteriores
out="$(run_check_verdict '{"verdict":"pass","qa":"pass","blocking":[],"requirements_uncovered":2}')"
assert_eq 3 $? "requirements sin cubrir: rechaza con exit 3"
assert_contains "$out" "2 requirements del delta-spec" "compliance: cuenta los uncovered"

echo
echo "── artefactos compilados NO son tests (falso positivo que costaba una ronda)"
# El patron matchea por RUTA, y `/tests?/` atrapa todo lo que cuelgue de tests/,
# incluidos los .pyc de __pycache__. Dejar de versionarlos (que es lo correcto)
# se leia como "test BORRADO sin declarar" y bloqueaba el ship.
mk_test_repo "$WS/g9"
mkdir -p tests/__pycache__ && printf 'binario\n' > tests/__pycache__/test_health.cpython-310.pyc
git add -A && git commit -qm "versiona el pyc por accidente"
git update-ref refs/remotes/origin/main HEAD
git rm -r -q --cached tests/__pycache__ && git commit -qm "deja de versionar artefactos"
rm -f "$WS/tasks/T1/delta-spec.md"
run_tests_gate >/dev/null 2>&1 \
  && pass "borrar un .pyc de tests/: NO bloquea" \
  || fail "un .pyc borrado se leyo como test eliminado (falso positivo)"

# Y el gate real sigue vivo: borrar un test DE VERDAD sigue bloqueando
mk_test_repo "$WS/g10"
git rm -q tests/auth.test.js && git commit -qm "borra un test de verdad"
run_tests_gate >/dev/null 2>&1 \
  && fail "borrar un test real dejo de bloquear" \
  || pass "borrar un test real sigue bloqueando (no se aflojo el gate)"

echo
echo "── un qa:\"pass\" sin artefacto detras NO pasa"
# Demostrado en una corrida real: una tarea shippeo con qa:"pass", sin
# qa-<repo>.json y sin una sola evidencia de runner=qa. check_verdict leia SOLO
# el campo del veredicto, o sea que la afirmacion mas cara del pipeline
# ("alguien ejercito el comportamiento") era palabra de agente sin respaldo.
out="$(run_check_verdict '{"verdict":"pass","qa":"pass","blocking":[],"requirements_uncovered":0}' sin-qa)"
assert_eq 3 $? "qa pass sin qa-<repo>.json ni evidencia de qa: rechaza"
assert_contains "$out" "no hay NADA que lo respalde" "nombra la causa"
assert_contains "$out" "runner qa" "y dice como producir el respaldo"

# Con evidencia de runner=qa (la via determinista) alcanza, sin el json
mkdir -p "$WS/tasks/T9/evidence"
printf '{"schema":1,"runner": "qa","kind":"test"}' > "$WS/tasks/T9/evidence/EV-TEST-qa1.json"
out="$(run_check_verdict '{"verdict":"pass","qa":"pass","blocking":[],"requirements_uncovered":0}' sin-qa)"
assert_eq 0 $? "evidencia con runner=qa: alcanza como respaldo"
rm -f "$WS/tasks/T9/evidence/EV-TEST-qa1.json"

t_done
