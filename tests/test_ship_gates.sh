#!/usr/bin/env bash
# test_ship_gates.sh — los dos añadidos de velocidad de ship.sh, contra el
# CÓDIGO REAL del template (extraído con awk, como test_ship_lock.sh):
#   · gate_lane: el carril express es una promesa que el diff debe cumplir —
#     contratos/migraciones bloquean; full no se ve afectado. quick hereda esa
#     promesa y suma techos de tamaño (max_files/max_lines del policy): los
#     cuenta contra el merge-base, y si no puede leerlos lo dice en vez de
#     inventarlos.
#   · par/run_parallel_gates: un gate rojo NO oculta a los demás (todos los
#     outputs salen juntos) y el verde agregado exige TODOS los grupos verdes.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

TMPL="$ROOT/templates/scripts/ship.sh.tmpl"

extract() {  # extract <nombre-funcion> — de 'nombre() {' a su '}' de 1er nivel
  awk "/^$1\(\) \{/{f=1} f{print} f&&/^\}/{exit}" "$TMPL"
}
{ extract gate_lane; extract gate_quick_size; } > "$WS/gate_lane.sh"
grep -q 'LANE_GUARD_PATTERN' "$WS/gate_lane.sh" || { echo "no pude extraer gate_lane"; exit 1; }
grep -q 'lane-limits' "$WS/gate_lane.sh" || { echo "no pude extraer gate_quick_size"; exit 1; }
{ extract par; extract close_serial_gate; extract known_bug_cubre
  extract collect_gate_slots
  extract run_phase0_gates; extract run_parallel_gates
  # El knob va DESPUES de las funciones a proposito: se sourcea y recien
  # despues se invoca run_phase0_gates, asi que el orden alcanza. Extraerlo
  # del template (y no redeclararlo aca) es lo que hace que el test mida el
  # default real: si manana el knob cambia de nombre, esto se queda mudo y el
  # grep de abajo lo caza.
  grep -E '^KNOWN_BUG(_USED)?=' "$TMPL"; } > "$WS/pargates.sh"
grep -q 'GDIR' "$WS/pargates.sh" || { echo "no pude extraer par/run_parallel_gates"; exit 1; }
grep -q 'fase 0' "$WS/pargates.sh" || { echo "no pude extraer run_phase0_gates"; exit 1; }
grep -q 'HARNESS_KNOWN_BUG' "$WS/pargates.sh" || { echo "no pude extraer el knob HARNESS_KNOWN_BUG"; exit 1; }
grep -q '^known_bug_cubre() {' "$WS/pargates.sh" || { echo "no pude extraer known_bug_cubre"; exit 1; }

echo "── gate_lane: el carril lo verifica el diff, no la fe"

mk_repo() {  # mk_repo <dir> — repo con origin/main simulado en el commit inicial
  mkdir -p "$1" && cd "$1"
  git init -q . && git config user.email t@t && git config user.name t
  echo base > main.go && git add . && git commit -qm init
  git update-ref refs/remotes/origin/main HEAD
}

# La salida de `lane-limits` se stubea porque lo que se mide acá es el DIENTE
# (contar y comparar), no el productor de los techos. La corrida contra el
# harness-policy.py real está más abajo: si el contrato cambia de forma, ese
# caso muerde y estos siguen midiendo lo suyo.
# LIMOUT/LIMRC en mayúsculas a propósito: bash tiene scope dinámico y un
# `lim_rc` acá lo pisaría el `local lim_rc` de la función bajo prueba, o sea
# que el stub devolvería SIEMPRE 0 y el caso del techo ilegible sería mudo.
run_gate_lane() {  # run_gate_lane <lane-json> [salida-lane-limits] [rc]: en el repo actual
  mkdir -p "$WS/tasks/T1"
  printf '%s' "$1" > "$WS/tasks/T1/state.json"
  # set -euo pipefail: el entorno REAL de ship.sh (mismo motivo que el runner
  # de check_verdict). Con solo `set -u` el test probaría otro shell.
  ( set -euo pipefail; WS="$WS"; TASK=T1; REPO=test; BASE_REF=main
    gate() { :; }; emit() { :; }
    LIMOUT="${2-max_files=8\nmax_lines=200}"; LIMRC="${3:-0}"
    python3() { printf '%b\n' "$LIMOUT"; return "$LIMRC"; }
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

# 3b. express + un .tf SUELTO en la raíz → bloquea (#71)
# Un infra-module lleva los .tf en la RAIZ, sin directorio terraform/. Mientras
# POLICY-LANE-004 rechazaba por el kind del repo este hueco no se notaba, porque
# nada de infra llegaba a un carril corto. Al pasar LANE-004 a aviso, este patrón
# quedó como ÚNICO freno: con el hueco abierto, un quick podía shippear
# terraform crudo sin que nadie lo mirara.
mk_repo "$WS/r3b"
echo 'resource "aws_s3_bucket" "b" {}' > main.tf && git add . && git commit -qm tf
run_gate_lane '{"lane":"express"}'; rc=$?
assert_eq 3 "$rc" "express tocando un .tf en la RAIZ: bloquea (el hueco que dejaba pasar terraform crudo)"

mk_repo "$WS/r3c"
echo 'region = "us-east-1"' > prod.tfvars && git add . && git commit -qm tfvars
run_gate_lane '{"lane":"quick"}'; rc=$?
assert_eq 3 "$rc" "quick tocando un .tfvars: bloquea igual"

# 3d. contra-mitad: el freno es por lo que TOCA, no por donde vive. Un cambio
#     que no roza infra pasa aunque el repo sea un infra-module entero.
mk_repo "$WS/r3d"
printf 'dist/\nnode_modules/\n' > .gitignore && git add . && git commit -qm "dos lineas al gitignore"
run_gate_lane '{"lane":"quick"}' \
  && pass "quick con un .gitignore de dos lineas: pasa (el caso medido del #71)" \
  || fail "el carril rapido sigue cerrado para un cambio que no toca infra"

# 3e. express + un chart de Helm en `chart/` SINGULAR → bloquea (#83)
# El patrón pedía `charts/` en plural, que es la grafía del directorio de
# SUBCHARTS vendoreados, no la del chart propio: medido en una plataforma de 17
# repos con chart, 17 usaban el singular y CERO el plural, o sea que el único
# freno que impide que un carril corto shippee infra no frenaba un solo chart.
mk_repo "$WS/r3e"
mkdir -p chart/templates
printf 'replicas: 3\n' > chart/values.yaml
git add . && git commit -qm chart
run_gate_lane '{"lane":"express"}'; rc=$?
assert_eq 3 "$rc" "express tocando chart/ SINGULAR: bloquea (17 de 17 repos usaban esa grafía)"

mk_repo "$WS/r3f"
mkdir -p charts/subchart && printf 'x: 1\n' > charts/subchart/values.yaml
git add . && git commit -qm subchart
run_gate_lane '{"lane":"quick"}'; rc=$?
assert_eq 3 "$rc" "y el plural sigue bloqueando: el patrón SUMA una grafía, no la cambia"

# 3g. el chart en la RAIZ del repo, sin directorio que lo delate: lo delata su
#     Chart.yaml (el mismo caso que `\.tf$` cubre para un infra-module).
mk_repo "$WS/r3g"
printf 'apiVersion: v2\nname: c\nversion: 0.1.0\n' > Chart.yaml
git add . && git commit -qm chart-raiz
run_gate_lane '{"lane":"express"}'; rc=$?
assert_eq 3 "$rc" "express tocando el Chart.yaml de la raíz: bloquea"

# 4. full + toca proto → NO es asunto de gate_lane (lo custodia buf breaking)
cd "$WS/r2"
run_gate_lane '{"lane":"full"}' \
  && pass "full tocando proto: gate_lane no interviene" || fail "full: gate_lane bloqueó y no debía"

# 5. el TRUNK avanza con un proto ajeno y la rama no lo toca → NO bloquea.
#    Con dos puntos se comparan las PUNTAS: el proto que otro sumó aparece en
#    este diff (como borrado) y el carril acusaba una promesa que nadie rompió.
mk_repo "$WS/r5"
echo x > feature.go && git add . && git commit -qm feat
rama="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q --detach refs/remotes/origin/main
mkdir -p proto && echo 'message Ajeno{}' > proto/ajeno.proto
git add . && git commit -qm "avance ajeno del trunk"
git update-ref refs/remotes/origin/main HEAD
git checkout -q "$rama"
run_gate_lane '{"lane":"express"}' \
  && pass "el trunk avanzó con un proto ajeno: express NO bloquea (ancla en el merge-base)" \
  || fail "express bloqueó por un proto que la rama jamás tocó (diff de puntas)"

echo
echo "── carril quick: la promesa es el TAMAÑO, y el que lo mide es el gate"
# quick recorta deliberación (RFC, DAG, briefs), no verificación. Lo único que
# hace segura esa poda es que el cambio sea chico de verdad, y nadie decide
# "voy a tocar 40 archivos": se llega ahí de a uno. El techo es dato del
# policy; acá se mide que el gate lo pida, lo cuente y lo diga con números.

# q1. quick con diff chico y rutas limpias → pasa
mk_repo "$WS/q1"
echo x > feature.go && git add . && git commit -qm feat
run_gate_lane '{"lane":"quick"}' \
  && pass "quick dentro de los techos y sin rutas prohibidas: pasa" \
  || fail "quick chico y limpio: bloqueó"

# q2. quick hereda ENTERO el patrón de express: un .proto lo tumba
mk_repo "$WS/q2"
mkdir -p proto && echo 'message X{}' > proto/api.proto && git add . && git commit -qm proto
out="$(run_gate_lane '{"lane":"quick"}' 2>&1)"; rc=$?
assert_eq 3 "$rc" "quick tocando proto/: bloquea (exit 3)"
assert_contains "$out" "carril quick, pero el diff toca" "y el mensaje nombra el carril real, no express"

# q3. 9 archivos contra un techo de 8 → rojo con los DOS números
mk_repo "$WS/q3"
for i in 1 2 3 4 5 6 7 8 9; do echo x > "f$i.go"; done
git add . && git commit -qm nueve
out="$(run_gate_lane '{"lane":"quick"}' 2>&1)"; rc=$?
assert_eq 3 "$rc" "quick con 9 archivos: bloquea (exit 3)"
assert_contains "$out" "archivos: 9 (techo 8)" "nombra el conteo real contra el techo"
assert_contains "$out" "--to express" "y la remediación escala a express (no a standard)"
assert_contains "$out" "--reason '9 archivos" "con el motivo ya escrito en el comando"

# q4. 201 líneas contra un techo de 200 → rojo con los DOS números
mk_repo "$WS/q4"
awk 'BEGIN{for(i=1;i<=201;i++) print "linea " i}' > grande.go
git add . && git commit -qm grande
out="$(run_gate_lane '{"lane":"quick"}' 2>&1)"; rc=$?
assert_eq 3 "$rc" "quick con 201 líneas: bloquea (exit 3)"
assert_contains "$out" "líneas cambiadas: 201 (techo 200)" "nombra las líneas reales contra el techo"
assert_not_contains "$out" "no pude leer" "y NO se disfraza del rojo de 'no pude mirar'"

# Y las BAJAS cuentan igual que las altas: borrar 150 líneas es tanto trabajo
# de revisar como escribirlas, y un carril que solo mira lo agregado deja
# pasar como quick un cambio que arrasa medio archivo.
mk_repo "$WS/q4b"
awk 'BEGIN{for(i=1;i<=150;i++) print "viejo " i}' > viejo.go
git add . && git commit -qm viejo
git update-ref refs/remotes/origin/main HEAD
git rm -q viejo.go
awk 'BEGIN{for(i=1;i<=60;i++) print "nuevo " i}' > nuevo.go
git add . && git commit -qm reemplazo
out="$(run_gate_lane '{"lane":"quick"}' 2>&1)"; rc=$?
assert_eq 3 "$rc" "quick que borra 150 y agrega 60: bloquea (las bajas cuentan)"
assert_contains "$out" "líneas cambiadas: 210 (techo 200)" "y suma altas + bajas, no solo altas"

# q5. el MISMO diff en express: los techos son de quick y de nadie más
cd "$WS/q4"
run_gate_lane '{"lane":"express"}' \
  && pass "express con el mismo diff grande: gate_lane no aplica techos" \
  || fail "express: los techos de quick se le aplicaron y no debían"
run_gate_lane '{"lane":"express"}' "POLICY-LANE-001: carril desconocido" 3 \
  && pass "express: ni siquiera le pregunta al policy por los techos" \
  || fail "express consultó lane-limits y murió por una respuesta que no le incumbe"

# q6. TERCER ESTADO: sin techos legibles el gate no inventa ni pasa callado.
# La remediación es OPUESTA a la del exceso (actualizar la instancia o arreglar
# el policy, no escalar el carril), así que el mensaje tiene que ser otro.
cd "$WS/q1"   # diff chico y limpio: lo único que puede tumbarlo es el techo
out="$(run_gate_lane '{"lane":"quick"}' "harness-policy.py: error: invalid choice: 'lane-limits'" 3 2>&1)"; rc=$?
assert_eq 3 "$rc" "lane-limits que no responde: bloquea (exit 3)"
assert_contains "$out" "no pude leer los límites del carril quick" "y lo dice con el motivo verdadero"
assert_contains "$out" "invalid choice" "citando la respuesta real del subcomando"
assert_contains "$out" "workflow.lanes.quick.limits" "y la remediación apunta al policy, no a escalar"
assert_not_contains "$out" "excede lo que quick promete" "sin confundirse con el rojo del exceso"

# stdout vacío con exit 0 ("este carril no promete techo") tampoco es verde
# PARA QUICK: quick ES su techo, así que un carril quick sin límites declarados
# es un policy roto, no un permiso.
out="$(run_gate_lane '{"lane":"quick"}' "" 0 2>&1)"; rc=$?
assert_eq 3 "$rc" "quick sin techos declarados: bloquea en vez de pasar sin medir"
assert_contains "$out" "no pude leer los límites" "con el mismo rojo honesto"

# q7. el techo se mide contra el MERGE-BASE, no contra la punta del trunk.
# Sin eso, un commit ajeno grande que aterrizó en main mientras la tarea
# trabajaba entra en la cuenta como borrado y manda a escalar por trabajo de
# otro. En el precheck (que corre sin rebase) es el caso normal, no el raro.
mk_repo "$WS/q7"
base="$(git rev-parse HEAD)"
echo x > feature.go && git add . && git commit -qm feat
br="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q -b trunk-sim "$base"
awk 'BEGIN{for(i=1;i<=300;i++) print "ajeno " i}' > ajeno.go
git add . && git commit -qm ajeno
git update-ref refs/remotes/origin/main HEAD
git checkout -q "$br"
run_gate_lane '{"lane":"quick"}' \
  && pass "el trunk avanzó 300 líneas ajenas: no se las cobra al carril quick" \
  || fail "las líneas de un commit ajeno del trunk contaron contra el techo"

# q8. y si NI SIQUIERA se puede medir (sin ancestro común), tampoco inventa
mk_repo "$WS/q8"
git checkout -q --orphan huerfano
git rm -rq --cached .
rm -f main.go
echo y > solo.go && git add . && git commit -qm huerfano
out="$(run_gate_lane '{"lane":"quick"}' 2>&1)"; rc=$?
assert_eq 3 "$rc" "sin ancestro común con el trunk: bloquea en vez de contar cero"
assert_contains "$out" "no pude medir el diff" "y dice que no pudo medir, no que el diff cabía"
assert_contains "$out" "no merge base" "citando lo que git contestó de verdad"

# q9. contra el harness-policy.py y el policy.json REALES: si el contrato de
# `lane-limits` cambia de forma, este caso muerde antes que producción.
mkdir -p "$WS/scripts"
cp "$ROOT/templates/scripts/harness-policy.py" "$WS/scripts/harness-policy.py"
sed 's/{{LOOP_BUDGET}}/3/g' "$ROOT/templates/policy.json.tmpl" > "$WS/harness-policy.json"
mkdir -p "$WS/tasks/T1"
printf '{"lane":"quick"}' > "$WS/tasks/T1/state.json"
cd "$WS/q1"
( set -euo pipefail; WS="$WS"; TASK=T1; REPO=test; BASE_REF=main
  gate() { :; }; emit() { :; }
  . "$WS/gate_lane.sh"; gate_lane ) \
  && pass "contra el policy real: los techos de quick se leen y el diff chico pasa" \
  || fail "el gate no supo leer la salida real de harness-policy.py lane-limits"
cd "$WS/q4"
( set -euo pipefail; WS="$WS"; TASK=T1; REPO=test; BASE_REF=main
  gate() { :; }; emit() { :; }
  . "$WS/gate_lane.sh"; gate_lane ) >/dev/null 2>&1 \
  && fail "contra el policy real: 201 líneas pasaron el techo de 200" \
  || pass "contra el policy real: el diff que excede sigue siendo rojo"

echo
# 5. sin state.json → default full, no bloquea (compat con tareas viejas)
cd "$WS/r2"
rm -f "$WS/tasks/T1/state.json"
( set -u; WS="$WS"; TASK=T1; REPO=test; BASE_REF=main; gate(){ :; }; emit(){ :; }
  . "$WS/gate_lane.sh"; gate_lane ) \
  && pass "sin state.json: default full, no bloquea" || fail "sin state.json: bloqueó"

echo "── gates en dos fases: baratos primero, y un rojo no esconde a los demás"
# Caso de campo: un requirements_uncovered=1 (200ms de jq) se descubría tras
# pagar una suite de 10 minutos que corría en paralelo con el slot veredicto.

run_pargates() {  # run_pargates <security-rc> [precheck] [verdict-rc]
  ( set -eu; WS="$WS"; REPO=test; CURRENT_GATE=""
    sec_rc="$1"; PRECHECK="${2:-0}"; verdict_rc="${3:-0}"
    emit() { :; }; gate() { CURRENT_GATE="$1"; }
    # la fase cara llama al envoltorio que sella la corrida como evidencia;
    # el stub va sobre ESE nombre. La distinción importa: es la pieza que
    # elimina una corrida entera de la suite por tarea.
    run_lang_gates() { echo LANG-EVIDENCIA; }
    run_lang_gates_sealed() { run_lang_gates; }
    run_security_gates() { echo SEC-EVIDENCIA; return "$sec_rc"; }
    gate_tests_untouched() { echo TESTS-EVIDENCIA; }
    check_verdict() { echo VERDICT-EVIDENCIA; return "$verdict_rc"; }
    gate_evidence() { echo COMPLIANCE-EVIDENCIA; }
    gate_policy_and_evidence() { echo POLICY-EVIDENCIA; }
    . "$WS/pargates.sh"; run_phase0_gates; run_parallel_gates )
}

out="$(run_pargates 0 2>&1)"; rc=$?
assert_eq 0 "$rc" "todo verde → verde agregado en las dos fases"
assert_contains "$out" "LANG-EVIDENCIA" "el output de cada grupo aparece"
assert_contains "$out" "VERDICT-EVIDENCIA" "la fase 0 corre el veredicto"

out="$(run_pargates 3 2>&1)"; rc=$?
assert_eq 3 "$rc" "un grupo caro rojo → rojo agregado (exit 3)"
assert_contains "$out" "SEC-EVIDENCIA" "el output del grupo rojo aparece"
assert_contains "$out" "LANG-EVIDENCIA" "el rojo NO esconde el output de los verdes"
assert_contains "$out" "security" "el resumen nombra el grupo que falló"

# LA PROPIEDAD NUEVA: un veredicto roto (200ms) corta ANTES de pagar suites
out="$(run_pargates 0 0 3 2>&1)"; rc=$?
assert_eq 3 "$rc" "veredicto rojo en fase 0: rojo agregado"
assert_contains "$out" "VERDICT-EVIDENCIA" "el rojo de fase 0 se reporta"
assert_not_contains "$out" "LANG-EVIDENCIA" "y los gates CAROS jamás llegaron a correr"
assert_not_contains "$out" "SEC-EVIDENCIA" "ninguno de ellos"
assert_contains "$out" "ninguna suite corrió" "y el resumen lo dice con esas palabras"

# todos los rojos de fase 0 JUNTOS (slots separados: set -e no los esconde)
out="$( ( set -eu; WS="$WS"; REPO=test; CURRENT_GATE=""; PRECHECK=0
    emit() { :; }; gate() { CURRENT_GATE="$1"; }
    gate_tests_untouched() { echo TESTS-EVIDENCIA; }
    check_verdict() { echo VERDICT-RED; exit 3; }
    gate_evidence() { echo COMPLIANCE-RED; exit 3; }
    gate_policy_and_evidence() { echo POLICY-EVIDENCIA; }
    . "$WS/pargates.sh"; run_phase0_gates ) 2>&1 )"; rc=$?
assert_eq 3 "$rc" "dos slots de fase 0 rojos: rojo agregado"
assert_contains "$out" "VERDICT-RED" "el primer rojo se reporta"
assert_contains "$out" "COMPLIANCE-RED" "y el segundo TAMBIÉN (no se esconden entre sí)"

# precheck: fase 0 sin slots de veredicto (todavía no existe).
# El detalle importa: si el precheck exigiera veredicto, jamás podría correr
# ANTES del review, que es toda su razón de ser.
out="$(run_pargates 0 1 2>&1)"; rc=$?
assert_eq 0 "$rc" "precheck: verde sin veredicto"
assert_contains "$out" "LANG-EVIDENCIA" "precheck: corre los gates mecánicos"
assert_contains "$out" "TESTS-EVIDENCIA" "precheck: la fase 0 corre tests-no-debilitados"
assert_not_contains "$out" "VERDICT-EVIDENCIA" "precheck: NO corre el grupo de veredicto"

echo
echo "── HARNESS_KNOWN_BUG: la unica salida legitima cuando el rojo es del harness"
# Caso de campo: un agente en una tarea de PRODUCTO choca con un gate del
# HARNESS que da falso rojo. Hoy sus dos opciones son ilegitimas (arreglar el
# harness, que no es su tarea y descarrila la corrida en un bucle) o quedarse
# bloqueado. El knob abre UNA salida: declarar el bug ya reportado y seguir.
# Lo que se mide aca son los CANDADOS, porque un knob sin candados es una
# puerta trasera para saltarse gates.
KB_BIN="$WS/kbbin"; mkdir -p "$KB_BIN" "$WS/.harness"
KB_URL="https://github.com/anthropics/harness-creator/issues/77"
kb_ledger_on() {  # la fila que solo puede haber puesto harness-bug.sh report|record
  printf '{"ts":"2026-07-30T00:00:00Z","epoch":1,"fp":"deadbeef","file":"scripts/ship.sh","url":"%s","status":"creado"}\n' \
    "$KB_URL" > "$WS/.harness/upstream-issues.jsonl"
}
kb_ledger_off() { rm -f "$WS/.harness/upstream-issues.jsonl"; }
kb_gh_off() { rm -f "$KB_BIN/gh"; }
kb_gh_state() {  # stub de gh que contesta el estado pedido
  printf '#!/bin/sh\necho %s\n' "$1" > "$KB_BIN/gh"; chmod +x "$KB_BIN/gh"
}

run_kb() {  # run_kb <valor-del-knob> "<slots rojos>": las dos fases con esos slots en rojo
  ( set -eu; WS="$WS"; REPO=test; CURRENT_GATE=""; PRECHECK=0
    PATH="$KB_BIN:$PATH"
    HARNESS_KNOWN_BUG="$1"; export HARNESS_KNOWN_BUG
    KB_ROJOS=" $2 "
    emit() { :; }; gate() { CURRENT_GATE="$1"; }
    # KB_ROJOS en mayusculas por el scope dinamico de bash: un `rojos` local
    # de la funcion bajo prueba lo pisaria y todos los slots saldrian verdes.
    kb_rojo() { case "$KB_ROJOS" in *" $1 "*) return 3 ;; esac; return 0; }
    gate_tests_untouched()     { echo TESTS-EVIDENCIA;      kb_rojo tests; }
    check_verdict()            { echo VERDICT-EVIDENCIA;    kb_rojo veredicto; }
    gate_evidence()            { echo COMPLIANCE-EVIDENCIA; kb_rojo compliance; }
    gate_policy_and_evidence() { echo POLICY-EVIDENCIA;     kb_rojo policy; }
    run_lang_gates_sealed()    { echo LANG-EVIDENCIA;       kb_rojo lang; }
    run_security_gates()       { echo SEC-EVIDENCIA;        kb_rojo security; }
    . "$WS/pargates.sh"; run_phase0_gates; run_parallel_gates )
}

# 1. el camino feliz: slot declarable, reportado, y sin gh para verificar estado
kb_ledger_on; kb_gh_off
out="$(run_kb "tests=$KB_URL" "tests" 2>&1)"; rc=$?
assert_eq 0 "$rc" "slot 'tests' rojo + knob + fila en el ledger: el ship sigue (exit 0)"
assert_contains "$out" "condición DECLARADA" "y NO se disfraza de verde: lo dice con esas palabras"
assert_contains "$out" "$KB_URL" "citando el issue que lo respalda"
assert_contains "$out" "TESTS-EVIDENCIA" "sin esconder la salida del gate que igual salio roja"
assert_contains "$out" "sin verificar" "y declara que no pudo confirmar el estado del issue"

# 2. sin fila en el ledger: reportar es la PRECONDICION, no un tramite posterior
kb_ledger_off; kb_gh_off
out="$(run_kb "tests=$KB_URL" "tests" 2>&1)"; rc=$?
assert_eq 3 "$rc" "knob sin reporte previo: sigue rojo (exit 3)"
assert_contains "$out" "PRECONDICIÓN" "y dice que reportar es la precondicion de desbloquearse"
assert_contains "$out" "harness-bug.sh" "con el comando que la cumple"

# 3. LA DEFENSA PRINCIPAL: security no es declarable. Un secreto filtrado jamas
#    es un bug del harness, y ese slot junta gitleaks con semgrep: abrir uno
#    seria abrir los dos.
kb_ledger_on; kb_gh_off
out="$(run_kb "security=$KB_URL" "security" 2>&1)"; rc=$?
assert_eq 3 "$rc" "knob sobre 'security': rechazado aunque el reporte exista (exit 3)"
assert_contains "$out" "no se rodean" "y dice por que ese slot no se negocia"

# 4. veredicto tampoco: sin veredicto no hubo review
out="$(run_kb "veredicto=$KB_URL" "veredicto" 2>&1)"; rc=$?
assert_eq 3 "$rc" "knob sobre 'veredicto': rechazado (exit 3)"
assert_contains "$out" "no se rodean" "por el mismo motivo estructural"

# 5. issue CERRADO = workaround vencido: el fix existe, hay que traerlo
kb_ledger_on; kb_gh_state CLOSED
out="$(run_kb "tests=$KB_URL" "tests" 2>&1)"; rc=$?
assert_eq 3 "$rc" "issue cerrado: el workaround caduca (exit 3)"
assert_contains "$out" "CERRADO" "y lo nombra"
assert_contains "$out" "harness-update" "mandando a traer el fix, no a re-declarar"

# 5b. contra-mitad: con el issue ABIERTO el mismo stub deja pasar. Sin esto,
#     el caso de arriba pasaria igual con un gh que siempre falla.
kb_gh_state OPEN
out="$(run_kb "tests=$KB_URL" "tests" 2>&1)"; rc=$?
assert_eq 0 "$rc" "el mismo gh contestando OPEN: el ship sigue (exit 0)"
assert_not_contains "$out" "sin verificar" "y con gh contestando NO declara estado desconocido"

# 6. UN solo slot por invocacion: el otro rojo sigue mordiendo
kb_gh_off
out="$(run_kb "tests=$KB_URL" "tests lang" 2>&1)"; rc=$?
assert_eq 3 "$rc" "dos slots rojos y knob para uno: el otro sigue bloqueando (exit 3)"
assert_contains "$out" "condición DECLARADA" "el declarado se declara"
assert_contains "$out" "lang" "y el resumen nombra al que sigue rojo"

# 7. REGRESION: sin knob, un slot rojo es rojo y nada cambio
out="$(run_kb "" "tests" 2>&1)"; rc=$?
assert_eq 3 "$rc" "sin knob: el rojo de siempre sigue siendo rojo (exit 3)"
assert_not_contains "$out" "BUG CONOCIDO" "y no aparece ni una linea del camino declarado"

# 8. la url tiene que tener forma de issue del forge: un slot=cualquier-cosa no
#    es una declaracion, es un salto sin rastro.
kb_ledger_on
out="$(run_kb "tests=porque-si" "tests" 2>&1)"; rc=$?
assert_eq 3 "$rc" "knob sin url de issue: rechazado (exit 3)"
assert_contains "$out" "https://github.com/" "diciendo que forma se espera"
kb_ledger_off; kb_gh_off

# el preflight existe y precede estructuralmente al lock
extract gate_ship_preflight > "$WS/preflight.sh"
grep -q "sin lock" "$WS/preflight.sh" || { echo "no pude extraer gate_ship_preflight"; exit 1; }
pf_line="$(grep -n '^gate_ship_preflight$' "$TMPL" | head -1 | cut -d: -f1)"
lk_line="$(grep -n '^acquire_lock$' "$TMPL" | head -1 | cut -d: -f1)"
[ -n "$pf_line" ] && [ -n "$lk_line" ] && [ "$pf_line" -lt "$lk_line" ] \
  && pass "gate_ship_preflight se invoca ANTES de acquire_lock (un ship condenado no retiene el lock)" \
  || fail "el preflight no precede al lock (pf=$pf_line lock=$lk_line)"


echo
echo "── cada gate dice CUÁNTO tardó (dur), y medirlo no cuesta un fork"
# La duración se derivaba restando el ts de dos eventos `gate` consecutivos.
# Con dos ships de la MISMA tarea intercalados en el bus (ship-wave corre los
# repos en paralelo) esa resta mide el hueco entre corridas distintas y le
# atribuye el tiempo al gate equivocado. Ahora lo dice quien sí sabe cuándo
# empezó su propio gate, con el builtin SECONDS: cero forks en el camino
# caliente de cada gate de cada repo.
extract gate > "$WS/gatefn.sh"
grep -q 'CURRENT_GATE="$1"' "$WS/gatefn.sh" || { echo "no pude extraer gate()"; exit 1; }

# emit de captura: imprime los 5 argumentos, el 5º es el que importa
EMIT_STUB='emit() { printf "EMIT|%s|%s|%s|%s|%s\n" "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}"; }'

dur_de() {  # dur_de <salida> <nombre-del-gate> → el 5º argumento de ese emit
  printf '%s\n' "$1" | awk -F'|' -v g="$2" '$1=="EMIT" && $3==g {print $6; exit}'
}
assert_num() {  # assert_num <valor> <nombre>
  case "${1:-}" in
    ''|*[!0-9]*) fail "$2 (esperaba un entero, fue '${1:-}')" ;;
    *)           pass "$2" ;;
  esac
}

# gate(): al abrir el siguiente, el anterior se cierra CON su duración
out="$( ( set -euo pipefail
  eval "$EMIT_STUB"
  . "$WS/gatefn.sh"
  gate uno; gate dos; gate tres ) 2>&1 )"
assert_num "$(dur_de "$out" uno)" "gate(): el cierre de 'uno' lleva un dur numérico"
assert_num "$(dur_de "$out" dos)" "gate(): el cierre de 'dos' lleva un dur numérico"
assert_eq "true" "$(printf '%s\n' "$out" | awk -F'|' '$3=="uno"{print $4; exit}')" \
  "gate(): el ok del cierre no se movió de sitio por meter dur detrás"

# el primer gate no puede morir por _G0 sin declarar: bajo `set -u` una
# variable sin inicializar mata el ship entero, y esto corre en todos.
( set -euo pipefail; eval "$EMIT_STUB"; . "$WS/gatefn.sh"; CURRENT_GATE="viejo"; gate nuevo ) >/dev/null 2>&1 \
  && pass "gate(): con CURRENT_GATE heredado y _G0 sin declarar NO revienta bajo set -u" \
  || fail "gate(): _G0 sin inicializar mata el script bajo set -u"

# la medición es del builtin, no de un proceso: `date` acá costaría un
# fork+exec por gate y por repo, que es justo lo que no se puede pagar.
grep -q 'SECONDS' "$WS/gatefn.sh" \
  && pass "gate() mide con el builtin SECONDS" || fail "gate() no usa SECONDS"
grep -qE '(^|[^a-z_])date[[:space:]]' "$WS/gatefn.sh" \
  && fail "gate() llama a date: un fork por gate y por repo" \
  || pass "gate() NO llama a date (cero forks en el camino caliente)"

# close_serial_gate: mismo contrato que gate()
out="$( ( set -euo pipefail; eval "$EMIT_STUB"
  CURRENT_GATE="serial"; _G0=$SECONDS
  . "$WS/pargates.sh"; close_serial_gate ) 2>&1 )"
assert_num "$(dur_de "$out" serial)" "close_serial_gate: cierra con dur numérico"

# par/group_exit: los slots paralelos son EL caso que rompía la resta de
# timestamps, así que son los que más necesitan el dur explícito.
out="$( ( set -eu; WS="$WS"; REPO=test; GDIR="$WS/gd"; PAR_PIDS=""; PAR_SLOTS=""
  mkdir -p "$GDIR"
  eval "$EMIT_STUB"
  gate() { CURRENT_GATE="$1"; }
  g_ok() { gate "en-paralelo"; }
  . "$WS/pargates.sh"
  par slot1 g_ok
  for p in $PAR_PIDS; do wait "$p" 2>/dev/null || true; done
  cat "$GDIR/slot1.out"; rm -rf "$GDIR" ) 2>&1 )"
assert_num "$(dur_de "$out" en-paralelo)" "par/group_exit: el gate de un slot paralelo cierra con dur numérico"

# y ningún cierre de gate se quedó sin instrumentar en el template
sin_dur="$(grep -c 'emit gate "$CURRENT_GATE"' "$TMPL" 2>/dev/null || true)"
con_dur="$(grep 'emit gate "$CURRENT_GATE"' "$TMPL" 2>/dev/null | grep -c 'SECONDS' || true)"
assert_eq "$sin_dur" "$con_dur" "TODOS los cierres de gate del template pasan dur ($sin_dur sitios)"


echo
echo "── gate_rename: un renombre a ciegas deja rastro, y el gate lo nombra"
# POR QUE: la constitucion pide edicion simbolica y eso vivia en prosa en DOS
# lugares sin frenar a nadie. Caso de campo: un renombre con `sed -i` sobre
# cuatro archivos en un repo con homonimos vivos; no se rompio nada, pero se
# supo SOLO porque el operador se lo pidio al reviewer como punto de atencion.
# El gate AVISA y no bloquea a proposito: decidir desde el texto si un
# sobreviviente es legitimo es justo lo que el texto no puede hacer.
RN="$WS/rn"; rm -rf "$RN"; mkdir -p "$RN"; ( cd "$RN"
  git init -q -b main && git config user.email t@t && git config user.name t
  printf 'func SubscribeMessages() {}\n' > a.go
  printf 'x := SubscribeMessages\ny := SubscribeMessages\n' > b.go
  printf 'legacy := SubscribeMessages\n' > c.go
  git add . && git commit -qm base && git branch -f origin/main main
  git checkout -qb w
  sed -i.bak 's/SubscribeMessages/SubscribeWebhookFields/g' a.go b.go
  rm -f ./*.bak && git commit -qam "renombre a medias" ) >/dev/null 2>&1

cat > "$RN/probe.sh" <<'PEOF'
set -uo pipefail
BASE_REF=main; REPO=demo
gate() { echo "── gate: $1 ──"; }
emit() { :; }
PEOF
sed -n "/^gate_rename() {/,/^}/p" "$ROOT/templates/scripts/ship.sh.tmpl" >> "$RN/probe.sh"
echo 'gate_rename; echo "RC=$?"' >> "$RN/probe.sh"

out="$(cd "$RN" && bash probe.sh 2>&1)"
assert_contains "$out" "TODAVÍA viven en el árbol" "el renombre incompleto se detecta"
assert_contains "$out" "c.go" "y NOMBRA el archivo que quedo atras"
assert_contains "$out" "SubscribeMessages" "con el identificador exacto"
assert_contains "$out" "rename_symbol" "y dice cual es la herramienta que lo evitaba"
assert_contains "$out" "RC=0" "AVISA, no bloquea: un gate que muerde sobre una heuristica es un gate que alguien apaga"

# ── issue #98: el gate se apagaba en SILENCIO con el awk de fabrica de Ubuntu
# mawk (Debian, Ubuntu y cualquier contenedor minimo) no soporta intervalos ERE,
# asi que `{5,}` partia los identificadores en trozos de seis, ningun par
# llegaba al umbral y el gate salia por "sin renombres en masa": exit 0, sin una
# palabra, indistinguible de un renombre completo. El CI no lo veia porque los
# runners de GitHub traen gawk. Dos redes, y las dos hacen falta:
#   1. ESTATICA, y muerde en cualquier maquina: el awk del gate no puede volver
#      a usar un intervalo. Es la unica que corre en macOS y en el CI actual.
#   2. DE CONDUCTA, cuando mawk existe: se corre el mismo probe con mawk
#      resolviendo `awk` y se exige el MISMO aviso (igual que test_emit.sh
#      ejercita dash cuando esta).
# Sin los comentarios: el que explica POR QUE no se usa `{5,}` tiene que poder
# escribir `{5,}`. Lo que no puede volver es el intervalo en el CODIGO.
rn_awk="$(sed -n "/^gate_rename() {/,/^}/p" "$ROOT/templates/scripts/ship.sh.tmpl" \
  | grep -v '^[[:space:]]*#')"
case "$rn_awk" in
  *"{"[0-9]*)
    fail "gate_rename volvio a usar un intervalo ERE en su awk: mawk no los soporta y el gate se apaga en silencio (#98)" ;;
  *) pass "gate_rename no usa intervalos ERE (mawk los ignora y el gate quedaria mudo)" ;;
esac

if command -v mawk >/dev/null 2>&1; then
  MAWKBIN="$RN/mawkbin"; mkdir -p "$MAWKBIN"
  printf '#!/bin/sh\nexec mawk "$@"\n' > "$MAWKBIN/awk"; chmod +x "$MAWKBIN/awk"
  out="$(cd "$RN" && PATH="$MAWKBIN:$PATH" bash probe.sh 2>&1)"
  assert_contains "$out" "TODAVÍA viven en el árbol" "bajo mawk el gate sigue avisando"
  assert_contains "$out" "SubscribeMessages" "y bajo mawk nombra el identificador entero, no un trozo"
  assert_not_contains "$out" "sin renombres en masa" \
    "bajo mawk NO se degrada al silencio (que se lee igual que un renombre completo)"
else
  echo "  · mawk no esta instalado: la pata de conducta no corre (la estatica ya mordio)"
fi

# CONTRA-MITAD: un renombre COMPLETO no dice nada. Si avisara igual seria ruido
# permanente sobre la operacion mas comun de un refactor.
( cd "$RN" && sed -i.bak 's/SubscribeMessages/SubscribeWebhookFields/g' c.go && rm -f ./*.bak && git commit -qam "completo" ) >/dev/null 2>&1
out="$(cd "$RN" && bash probe.sh 2>&1)"
assert_contains "$out" "renombres completos" "un renombre completo no genera ruido"
assert_not_contains "$out" "TODAVÍA viven" "y no inventa un sobreviviente"

echo "── gate_tests_untouched v2: neto real, escape que declara"

# delta_seccion viaja CON el gate: es quien lee el delta-spec, y sin ella
# el gate extraido muere con 127 en vez de decir lo que decide.
{ extract delta_seccion; extract gate_tests_untouched; } > "$WS/gate_tests.sh"
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

# 9. archivo de test AÑADIDO con un guard .skip( y aserciones nuevas → NO bloquea,
#    pero lo NOMBRA. En un archivo de alta todas las líneas son "+": el guard de
#    entorno que Playwright pide daba neto 1 y salía exit 3 sin salida legítima.
mk_test_repo "$WS/g6"
mkdir -p e2e
cat > e2e/dashboard.spec.ts <<'FIX'
import { test, expect } from '@playwright/test'
test('dashboard responsive', async ({ page }) => {
  test.skip(!reachable, 'no hay servidor')
  expect(await page.title()).toBe('Dashboard')
  expect(await page.locator('nav').count()).toBe(1)
})
FIX
git add . && git commit -qm spec-nuevo
rm -f "$WS/tasks/T1/delta-spec.md"
out="$(run_tests_gate 2>&1)"; rc=$?
assert_eq 0 "$rc" "test AÑADIDO con .skip( de guard: NO bloquea"
# El texto DISTINTIVO de la línea nueva, no el basename: el mensaje de bloqueo
# viejo también nombra el archivo, así que assertear solo 'dashboard.spec.ts'
# pasaba igual contra el árbol base y no probaba nada. Esta línea es el único
# rastro auditable que queda del skip que ya no se cuenta.
assert_contains "$out" "test AÑADIDO con 1 skips/only: e2e/dashboard.spec.ts" \
  "la línea informativa dice que es de ALTA y nombra el archivo"

# 10. el MISMO .skip( pero sobre un archivo de test que YA existía → bloquea
mk_test_repo "$WS/g7"
python3 -c "
s=open('tests/auth.test.js').read()
open('tests/auth.test.js','w').write(s.replace(\"  it('valida token', () => {\", \"  it('valida token', () => {\n    test.skip(!reachable, 'no hay servidor')\"))"
git add . && git commit -qm skip-en-existente
out="$(run_tests_gate 2>&1)"; rc=$?
assert_eq 3 "$rc" ".skip( añadido a un archivo de test EXISTENTE: bloquea"
assert_contains "$out" "auth.test.js" "el mensaje nombra el archivo existente debilitado"

# 11. test BORRADO sin declarar → bloquea nombrando el archivo. GATE-2 lo exige
#     y la suite no lo probaba: el único `git rm` de tests que había es el de
#     tests/__pycache__, que asegura lo CONTRARIO. Importa junto al cambio de
#     archivos de alta, porque la lista `added` vive pegada a `deleted` y se
#     reporta en el mismo bucle: un error de una podría tapar a la otra.
mk_test_repo "$WS/g8"
git rm -q tests/auth.test.js && git commit -qm borra-test
rm -f "$WS/tasks/T1/delta-spec.md"
out="$(run_tests_gate 2>&1)"; rc=$?
assert_eq 3 "$rc" "test BORRADO sin declarar: bloquea"
assert_contains "$out" "test BORRADO sin declarar: tests/auth.test.js" \
  "el mensaje distingue el borrado y nombra el archivo"

# 12. el TRUNK avanza con tests ajenos y la rama no toca ninguno → NO bloquea.
#     Con dos puntos, el diff de puntas INVIERTE el avance del trunk: el test
#     que otro AGREGÓ se lee acá como borrado y la aserción que otro AÑADIÓ
#     como aserción eliminada. El gate acusaba de debilitar a quien no tocó
#     un solo test. El precheck corre SIN rebase, así que es el caso normal.
mk_test_repo "$WS/g9"
echo x > feature.go && git add . && git commit -qm feat
rama="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q --detach refs/remotes/origin/main
cat > tests/pagos.test.js <<'FIX'
describe('pagos', () => {
  it('cobra', () => {
    expect(pay()).toEqual(true)
  })
})
FIX
python3 -c "
s=open('tests/auth.test.js').read()
open('tests/auth.test.js','w').write(s.replace(\"    expect(logout()).toEqual(true)\", \"    expect(logout()).toEqual(true)\n    expect(audit()).toEqual(true)\"))"
git add . && git commit -qm "avance ajeno del trunk"
git update-ref refs/remotes/origin/main HEAD
git checkout -q "$rama"
rm -f "$WS/tasks/T1/delta-spec.md"
out="$(run_tests_gate 2>&1)"; rc=$?
assert_eq 0 "$rc" "el trunk avanzó con tests ajenos: NO bloquea (ancla en el merge-base)"
assert_not_contains "$out" "BORRADO" "ni acusa el borrado del test que OTRO agregó"
assert_not_contains "$out" "aserciones netas eliminadas" "ni invierte la aserción ajena"

# Y la regla queda fijada en el template, no solo en este caso: ningún `git
# diff` contra el trunk puede volver a comparar PUNTAS. rev-list/log/gitleaks
# sí usan dos puntos, y a propósito: cuentan los commits DE LA RAMA.
dosdot="$(grep -nE 'git diff[^|)]*origin/\$BASE_REF"?\.\.HEAD' "$TMPL" || true)"
assert_eq "" "$dosdot" \
  "ningún git diff del template compara PUNTAS contra origin/\$BASE_REF"

echo
echo "── gate_test_muerde: un test que no puede fallar no prueba nada"
# Caso de campo: un assert que evaluaba ANTES de que llegara el dato pasó la
# suite, pasó el precheck, y la ronda 3 entera (commit, precheck, dos sellos de
# evidencia, dos agentes) se pagó por un test vacuo. gate_tests_untouched no lo
# ve (no hay aserción DEBILITADA: hay una NUEVA que no muerde) y el
# mutation-sentinel contesta al día siguiente. La única pregunta que lo caza es
# mecánica: ¿este test falla sobre el árbol base?

# bounded.sh va PRIMERO: con_limite delega en run_bounded, y sin el helper el
# gate extraido muere con 127 igual que sin delta_seccion. ship.sh lo sourcea
# de scripts/bounded.sh; aca se pega el template real, no una imitacion.
cat "$ROOT/templates/scripts/bounded.sh" > "$WS/gate_muerde.sh"
extract muerde_limpia >> "$WS/gate_muerde.sh"
# delta_seccion, declara_tests_nuevos y muerde_go_base_compila viajan CON el
# gate: son sus tres lecturas (el delta-spec, el diff y el grafo de modulos de
# la base). Sin ellas el gate extraido muere con 127 en vez de decidir.
for fn in delta_seccion declara_tests_nuevos muerde_pytest muerde_go \
          muerde_go_base_compila muerde_tf muerde_tf_root muerde_tf_base_init \
          muerde_node con_limite muerde_node_colecta_en muerde_node_colecta muerde_corre \
          muerde_corre_grupo muerde_salto gate_test_muerde; do
  extract "$fn" >> "$WS/gate_muerde.sh"
done
grep -q 'MUERDE_VACUOS' "$WS/gate_muerde.sh" || { echo "no pude extraer gate_test_muerde"; exit 1; }
grep -q 'worktree remove --force' "$WS/gate_muerde.sh" || { echo "no pude extraer muerde_limpia"; exit 1; }

# Los DOS gates miran archivos de test, pero NO con el mismo alcance, y la
# diferencia es deliberada: untouched protege la SUITE por RUTA (borrar un
# helper de tests/ debilita la red), mientras que muerde COPIA lo que matchea
# al árbol base y le corre un runner encima. Con el patrón por directorio, la
# implementación que vive bajo tests/ viajaba a la base junto a su propio test
# (el test pasaba ahí por construcción: falso rojo) y un helper sin casos hacía
# salir 1 al runner, que el gate cobraba como MUERDE (falso verde).
# Lo que se fija acá es la relación que no puede romperse: SUBSET.
pat_untouched="$(sed -n 's/.*TEST_PATH_PATTERN:-\(.*\)}".*/\1/p' "$WS/gate_tests.sh" | head -1)"
pat_muerde="$(sed -n 's/.*TEST_FILE_PATTERN:-\(.*\)}".*/\1/p' "$WS/gate_muerde.sh" | head -1)"
[ -n "$pat_untouched" ] && pass "extraje el patrón de test de gate_tests_untouched (vacío haría vacuo el chequeo)" \
  || fail "no extraje el patrón de gate_tests_untouched"
[ -n "$pat_muerde" ] && pass "extraje el patrón de ARCHIVO de gate_test_muerde" \
  || fail "no extraje TEST_FILE_PATTERN de gate_test_muerde"
if echo "tests/helpers/pagos.ts" | grep -qE "$pat_muerde"; then
  fail "un helper bajo tests/ entró al alcance de muerde (el falso rojo y el falso verde de COR-651)"
else
  pass "la implementación que vive bajo tests/ NO es un archivo de test para muerde"
fi
subset_ok=1
for f in src/pagos.test.ts tests/test_calc.py e2e/checkout.spec.ts pkg/x_test.go spec/carro_spec.rb \
         infra/tests/kargo.tftest.hcl; do
  echo "$f" | grep -qE "$pat_muerde"    || { fail "muerde perdió de vista $f"; subset_ok=0; }
  echo "$f" | grep -qE "$pat_untouched" || { fail "subset roto: muerde corre $f pero untouched no lo protege"; subset_ok=0; }
done
[ "$subset_ok" -eq 1 ] && pass "muerde corre solo ARCHIVOS de test, y untouched los protege a todos (subset)"
art_untouched="$(grep 'TEST_ARTIFACT_PATTERN:-' "$WS/gate_tests.sh" | head -1 | tr -d '[:space:]')"
art_muerde="$(grep 'TEST_ARTIFACT_PATTERN:-' "$WS/gate_muerde.sh" | head -1 | tr -d '[:space:]')"
assert_eq "$art_untouched" "$art_muerde" "y excluyen los MISMOS artefactos compilados"

# pytest de palo, hermético: modela la ÚNICA distinción que este gate mide.
#   · un test cuyo nombre dice "vacuo" pasa en cualquier árbol
#   · el resto necesita feature.py, que solo existe en HEAD: sobre la base
#     revienta como reventaría un ImportError del módulo que aún no existe
mkdir -p "$WS/bin-muerde" "$WS/tmp-muerde" "$WS/tasks/TM"
cat > "$WS/bin-muerde/pytest" <<'SH'
#!/bin/sh
for a in "$@"; do t="$a"; done
case "$t" in *vacuo*) echo "1 passed"; exit 0 ;; esac
# exit 5 = "no collected any tests", el código que pytest reserva para eso
case "$t" in *sincasos*) echo "no tests ran in 0.01s"; exit 5 ;; esac
if [ -f feature.py ]; then echo "1 passed"; exit 0; fi
echo "ImportError: cannot import name 'feature'"
exit 1
SH
chmod +x "$WS/bin-muerde/pytest"

run_muerde() {  # corre el gate en el repo actual (que hace de worktree)
  ( set -euo pipefail; WS="$WS"; TASK=TM; REPO=test; BASE_REF=main; WT="$PWD"
    PATH="$WS/bin-muerde:$PATH"; TMPDIR="$WS/tmp-muerde"
    gate() { :; }; emit() { echo "EMIT $*"; }
    . "$WS/gate_muerde.sh"; gate_test_muerde ) 2>&1
}
mk_muerde_repo() {  # mk_muerde_repo <dir>: base con un test viejo, origin/main al día
  mk_repo "$1"
  mkdir -p tests
  printf 'def test_viejo():\n    import app\n' > tests/test_viejo.py
  git add -A && git commit -qm tests
  git update-ref refs/remotes/origin/main HEAD
  rm -f "$WS/tasks/TM/delta-spec.md"
}

# (a) test NUEVO que falla sobre la base y pasa en HEAD → verde
mk_muerde_repo "$WS/mu1"
echo 'def f(): pass' > feature.py
printf 'def test_feature():\n    import feature\n' > tests/test_feature.py
git add -A && git commit -qm feat
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "test nuevo que falla sobre la base: verde (muerde)"
assert_contains "$out" "MUERDE" "y lo dice, en vez de pasar callado"
# COR-683: un precheck estuvo 41 minutos colgado en este gate sin UNA linea de
# salida, asi que el reporte no pudo decir en que archivo. La corrida real no
# lleva timeout a proposito (una suite grande tarda minutos y un timeout ahi
# fabricaria falsos rojos), pero el cuelgue deja de ser silencioso.
assert_contains "$out" "corriendo sobre la base: tests/test_feature.py" \
  "anuncia la unidad ANTES de correrla: un cuelgue se puede nombrar"

# Y el arbol base ve el node_modules del worktree por enlace: sin eso, vitest no
# puede cargar su config (que importa de vitest/config) y el gate no ejecuta una
# sola asercion. El enlace tiene que existir ANTES de invocar al runner.
sh_src="$(cat "$TMPL")"
assert_contains "$sh_src" 'ln -s "$WT/node_modules" "$MUERDE_BASE/node_modules"' \
  "el arbol base recibe node_modules prestado del worktree"
enlace_ln="$(grep -n 'ln -s "\$WT/node_modules"' "$TMPL" | cut -d: -f1)"
corre_ln="$(grep -n 'muerde_corre_grupo node' "$TMPL" | tail -1 | cut -d: -f1)"
[ -n "$enlace_ln" ] && [ -n "$corre_ln" ] && [ "$enlace_ln" -lt "$corre_ln" ] \
  && pass "y el enlace se crea ANTES de invocar al runner de node (COR-683)" \
  || fail "el runner de node corre antes del enlace: vitest no cargaria su config"
assert_contains "$out" "ImportError" "mostrando el motivo real del fallo sobre la base"

# (b) test NUEVO que pasa en los DOS árboles → rojo con nombre y remediación
mk_muerde_repo "$WS/mu2"
printf 'def test_vacuo():\n    assert True\n' > tests/test_vacuo.py
git add -A && git commit -qm "un test que no puede fallar"
out="$(run_muerde)"; rc=$?
assert_eq 3 "$rc" "test nuevo que pasa TAMBIÉN sobre la base: bloquea (exit 3)"
assert_contains "$out" "tests/test_vacuo.py" "nombrando el archivo exacto"
assert_contains "$out" "pasa sin tu fix" "con la remediación que explica qué está mal"
assert_contains "$out" "rojo sobre la base, verde" "y qué se espera del test"
assert_contains "$out" "MODIFIED" "y el escape para un refactor de test"

# (g) la limpieza es del TRAP, así que ocurre también con el gate rojo. Un
# worktree fantasma queda registrado en el repo y el próximo `worktree add`
# sobre ese path se niega: la basura de este gate rompería al siguiente.
assert_eq "1" "$(git worktree list | grep -c .)" \
  "gate ROJO: el worktree temporal se limpió igual (git worktree list sano)"
assert_eq "" "$(ls -A "$WS/tmp-muerde" 2>/dev/null)" "y no dejó el directorio temporal"

# (c) test MODIFICADO y NO nombrado: fuera del alcance a propósito. Un retoque
# cosmético pasa sobre la base legítimamente, y ponerlo rojo fabricaría el falso
# rojo que enseña a desconfiar del gate.
mk_muerde_repo "$WS/mu3"
printf 'def test_vacuo_viejo():\n    assert True\n' > tests/test_vacuo_viejo.py
git add -A && git commit -qm "el test ya existía"
git update-ref refs/remotes/origin/main HEAD
printf 'def test_vacuo_viejo():\n    assert True  # retoque\n' > tests/test_vacuo_viejo.py
git add -A && git commit -qm cosmetico
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "test MODIFICADO y no nombrado: el gate NO lo mira (verde)"
assert_not_contains "$out" "test_vacuo_viejo.py" "ni lo nombra: está fuera del alcance"
assert_contains "$out" "sin tests nuevos que verificar" "y dice que no había nada en alcance"

# (d) el MISMO archivo, nombrado por basename bajo ADDED → entra al alcance
cat > "$WS/tasks/TM/delta-spec.md" <<'FIX'
## ADDED Requirements
- R1: el caso nuevo queda cubierto por tests/test_vacuo_viejo.py
FIX
out="$(run_muerde)"; rc=$?
assert_eq 3 "$rc" "el mismo archivo NOMBRADO bajo ADDED: entra al alcance y es rojo"
assert_contains "$out" "test_vacuo_viejo.py" "nombrándolo en el rojo"

# ...y la remediación que el rojo imprime FUNCIONA: declararlo bajo MODIFIED lo
# saca del alcance. Una remediación que no funcionara sería peor que ninguna.
cat > "$WS/tasks/TM/delta-spec.md" <<'FIX'
## ADDED Requirements
- R1: el caso nuevo queda cubierto por tests/test_vacuo_viejo.py

## MODIFIED Requirements
- R2: es un refactor de tests/test_vacuo_viejo.py, no conducta nueva
FIX
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "declarado bajo MODIFIED: sale del alcance (la remediación impresa funciona)"
assert_contains "$out" "fuera del alcance" "y queda dicho, no borrado en silencio"
rm -f "$WS/tasks/TM/delta-spec.md"

# (d2) El escape excusa un REFACTOR, jamás un caso NUEVO del mismo archivo.
# Caso de campo (COR-667): cualquier fix que cambie una firma obliga a declarar
# MODIFIED su archivo de test, y con eso el archivo se autoexcluía ENTERO. En
# video-forge, cost_test.go se declaró MODIFIED (cambiaban las llamadas) y
# además agregaba el único test que probaba el fix; el precheck imprimió "sin
# tests nuevos que verificar" y salió verde sin mirarlo. El patrón es común, no
# excepcional, y un gate que da la señal de seguridad sin la seguridad es peor
# que no tenerlo.
mk_muerde_repo "$WS/mu12"
printf 'def test_firma_vieja():\n    assert True\n' > tests/test_firma.py
git add -A && git commit -qm "el test que ya existia"
git update-ref refs/remotes/origin/main HEAD
# el fix cambia la firma del test viejo Y agrega el caso que prueba el cambio
printf 'def test_firma_vieja(ctx):\n    assert True\n\ndef test_caso_nuevo():\n    import feature\n' > tests/test_firma.py
git add -A && git commit -qm "cambia la firma y agrega el caso nuevo"
cat > "$WS/tasks/TM/delta-spec.md" <<'FIX'
## MODIFIED Requirements
- R1: cambia la firma de las llamadas en tests/test_firma.py
FIX
out="$(run_muerde)"; rc=$?
assert_contains "$out" "AGREGA tests nuevos: sigue en el alcance" \
  "declarar MODIFIED no licencia saltarse un caso NUEVO del mismo archivo"
assert_contains "$out" "MUERDE" "el caso nuevo SÍ se corre contra la base"
assert_not_contains "$out" "sin tests nuevos que verificar" \
  "y el gate ya no miente diciendo que no había nada que mirar"
assert_eq 0 "$rc" "y con el caso nuevo mordiendo, el gate sale verde"
rm -f "$WS/tasks/TM/delta-spec.md"

# (e) stack sin runner dirigido: ni verde mudo ni rojo inventado
mk_muerde_repo "$WS/mu4"
printf 'assert true\n' > tests/algo_spec.rb
git add -A && git commit -qm ruby
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "stack sin runner dirigido: NO bloquea (un rojo ahí sería inventado)"
assert_contains "$out" "NO pude verificar contra la base" "pero lo DICE"
assert_contains "$out" "tests/algo_spec.rb" "nombrando el archivo que no miró"
assert_contains "$out" "NO dice verde ni rojo" "sin disfrazar el salto de verificación"
assert_contains "$out" "EMIT assumption" "y el supuesto viaja al bus, como hacen sus vecinos"

# (f) sin tests nuevos: no-op silencioso y sin costo (ni worktree temporal)
mk_muerde_repo "$WS/mu5"
echo 'algo nuevo' > otro.go
git add -A && git commit -qm "solo código"
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "sin tests nuevos: verde sin hacer nada"
assert_contains "$out" "sin tests nuevos que verificar" "con UNA línea, no un informe"
assert_not_contains "$out" "❌" "sin ruido de rojo"
assert_eq "1" "$(git worktree list | grep -c .)" "y sin pagar el checkout del árbol base"

# ── el alcance por ARCHIVO, no por directorio, y la COLECCIÓN antes del rojo ──
# node_modules NO se versiona: el gate ya presta el del worktree por enlace, así
# que el runner de palo vive fuera del árbol que se juzga, como en la realidad.
mk_node_muerde() {  # mk_node_muerde <dir> <package.json> <bin> <script-stub>
  mk_muerde_repo "$1"
  printf 'node_modules/\n' > .gitignore
  printf '%s\n' "$2" > package.json
  mkdir -p "node_modules/.bin"
  printf '%s\n' "$4" > "node_modules/.bin/$3"
  chmod +x "node_modules/.bin/$3"
  git add -A && git commit -qm node
  git update-ref refs/remotes/origin/main HEAD
}
PKG_VITEST='{"devDependencies":{"vitest":"^2"}}'
# vitest de palo: `list` colecta lo que le pasen; `run` pasa solo si el helper
# está en el cwd (o sea, solo si el gate lo copió al árbol base, que es el bug).
STUB_VITEST='#!/bin/sh
# La sonda pasa `list --watch=false <archivo>` (sin --watch=false, vitest 1.6
# arranca en watch y cuelga el gate para siempre, #57). El stub tiene que
# saltar el subcomando Y los flags, o "colecta" el flag en vez del archivo.
sub=""
case "$1" in list|run) sub="$1"; shift ;; esac
for a; do case "$a" in --*) ;; *) t="$a" ;; esac; done
if [ "$sub" = list ]; then echo "$t"; exit 0; fi
case "$t" in *helpers*) echo "No test files found"; exit 1 ;; esac
if [ -f tests/helpers/flujo.ts ]; then echo "1 passed"; exit 0; fi
echo "Cannot resolve ./helpers/flujo"; exit 1'

# (h) falso VERDE de COR-651: un helper sin casos bajo tests/ hacía salir 1 al
#     runner ("No test files found") y el gate cobraba ese exit como MUERDE.
mk_node_muerde "$WS/mu6" "$PKG_VITEST" vitest "$STUB_VITEST"
mkdir -p tests/helpers && printf 'export const pago = 1\n' > tests/helpers/pagos.ts
git add -A && git commit -qm helper
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "un helper bajo tests/ no es un test: verde sin correr nada"
assert_contains "$out" "sin tests nuevos que verificar" "y queda fuera del alcance"
assert_not_contains "$out" "MUERDE" "su 'No test files found' ya no compra una verificación"

# (i) falso ROJO de COR-651: la implementación que vive bajo tests/ viajaba al
#     árbol base junto a su propio test, el test pasaba ahí POR CONSTRUCCIÓN y
#     el gate lo declaraba vacuo. Un archivo NUEVO no tiene escape legítimo.
mk_node_muerde "$WS/mu7" "$PKG_VITEST" vitest "$STUB_VITEST"
mkdir -p tests/helpers
printf 'export const flujoNuevo = 1\n' > tests/helpers/flujo.ts
printf "import { flujoNuevo } from './helpers/flujo'\ntest('paga', () => {})\n" > tests/pago.test.ts
git add -A && git commit -qm feat-y-test
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "el test importa un helper NUEVO de tests/: muerde (la base no lo tiene)"
assert_contains "$out" "MUERDE" "porque el helper ya no viaja al árbol base con él"
assert_not_contains "$out" "PASA sobre el árbol base" "sin el falso rojo que no tenía salida"

# (j0) #57: la sonda NO puede colgarse. `vitest list` en vitest 1.6 no es un
# subcomando: es un filtro de nombre, y fuera de CI el runner arranca en modo
# WATCH. Si algun test falla imprime "Watching for file changes..." y se queda
# ahi: el command-substitution no cierra NUNCA. Medido en campo: 25 minutos a
# 1% de CPU sin una linea de salida, y le pasa a TODA tarea de frontend que
# cumpla el rojo primero, porque ahi el test nuevo es rojo sobre la base por
# definicion. El stub reproduce ese runner: se cuelga salvo que le llegue CI.
STUB_VITEST_WATCH='#!/bin/sh
if [ -z "$CI" ]; then
  echo "FAIL  Tests failed. Watching for file changes..."
  while :; do sleep 1; done
fi
case "$1" in list) shift ;; run) shift ;; esac
for a; do case "$a" in --*) ;; *) t="$a" ;; esac; done
echo "$t"
[ -f feature.ts ] && exit 0
exit 1'
mk_node_muerde "$WS/mu13" "$PKG_VITEST" vitest "$STUB_VITEST_WATCH"
printf "test('x', () => {})\n" > tests/pago.test.ts
git add -A && git commit -qm "test nuevo, rojo sobre la base"
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "el gate TERMINA aunque el runner se colgaria sin CI (#57)"
assert_contains "$out" "MUERDE" "y llega a su veredicto en vez de quedarse esperando"

# La tercera capa, probada aparte para no pagar el timeout en la suite: un
# comando que ignora todo y se cuelga igual tiene un limite duro de tiempo.
# con_limite delega en run_bounded (scripts/bounded.sh), asi que el test lo
# sourcea igual que lo hace ship.sh de verdad.
extract con_limite > "$WS/limite.sh"
t0=$(date +%s)
( . "$ROOT/templates/scripts/bounded.sh"; . "$WS/limite.sh"; con_limite 1 sleep 30 ) >/dev/null 2>&1 || true
t1=$(date +%s)
[ $((t1 - t0)) -le 5 ] \
  && pass "con_limite corta un comando colgado (una sonda no puede ser eterna)" \
  || fail "con_limite no corto: la sonda puede colgar el gate entero"

# El caso que el idiom viejo NO cubria y es JUSTO el de un runner de node: la
# sonda deja un hijo que hereda stdout. El padre moria y el $( ) seguia
# bloqueado hasta que el nieto terminaba (medido: 20s con un limite de 2).
cat > "$WS/sonda-con-hijo.sh" <<'EOF'
#!/bin/sh
sleep 30 &
echo "colectando"
wait
EOF
chmod +x "$WS/sonda-con-hijo.sh"
t0=$(date +%s)
( . "$ROOT/templates/scripts/bounded.sh"; . "$WS/limite.sh"
  out="$(con_limite 1 "$WS/sonda-con-hijo.sh")" ) >/dev/null 2>&1 || true
t1=$(date +%s)
[ $((t1 - t0)) -le 8 ] \
  && pass "con_limite corta la sonda que dejo un hijo vivo (el \$( ) no espera al nieto)" \
  || fail "el nieto sostuvo el pipe $((t1 - t0))s: la sonda sigue pudiendo colgar el gate"

# (j) COR-656: vitest declarado pero con un include que no alcanza a e2e/. La
#     invocación salía 1 ("No test files found") y el gate, que por decisión
#     escrita no juzga el MOTIVO del fallo, lo cobraba como MUERDE.
STUB_VITEST_SRC='#!/bin/sh
sub=""
case "$1" in list|run) sub="$1"; shift ;; esac
for a; do case "$a" in --*) ;; *) t="$a" ;; esac; done
if [ "$sub" = list ]; then
  case "$t" in src/*) echo "$t"; exit 0 ;; esac
fi
echo "No test files found"; exit 1'
mk_node_muerde "$WS/mu8" "$PKG_VITEST" vitest "$STUB_VITEST_SRC"
mkdir -p e2e && printf "test('checkout', () => {})\n" > e2e/checkout.spec.ts
git add -A && git commit -qm e2e
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "spec fuera del include del runner: ni verde ni rojo"
assert_contains "$out" "COLECTA" "lo dice: ningún runner declarado lo colecta"
assert_contains "$out" "EMIT assumption" "y el supuesto viaja al bus"
assert_not_contains "$out" "o sea que MUERDE" "sin cobrar como verificación el exit del runner equivocado"
# #85: y ademas DICE lo que el runner contesto. Sin esa linea, "el include no
# alcanza", "la config no carga" y "la sonda se paso del tiempo" aterrizaban en
# el mismo mensaje, y el operador no tenia por donde empezar a mirar.
assert_contains "$out" "No test files found" "y muestra lo que el runner contestó, no solo la conclusión del gate"

# (j2) #85: la sonda pregunta sobre el ARBOL BASE, y la config del runner NO
# viaja ahi (no es un archivo de test). Un paquete nuevo, o un include nuevo en
# vitest.config, hacen que la base no colecte un archivo que TU arbol colecta
# sin chistar: el gate decia "ningun runner lo COLECTA" y apagaba su garantia
# como si el archivo fuera incolectable. Caso de campo: un test bajo
# packages/<pkg>/src/ que el propio vitest.config incluye y que `vitest run`
# corre perfecto. Son dos diagnosticos distintos y ahora se distinguen.
STUB_VITEST_CFG='#!/bin/sh
sub=""
case "$1" in list|run) sub="$1"; shift ;; esac
for a; do case "$a" in --*) ;; *) t="$a" ;; esac; done
if [ ! -f vitest.config.ts ]; then
  echo "Error: cannot load config: no vitest.config.ts en este arbol"; exit 1
fi
if [ "$sub" = list ]; then echo "$t"; exit 0; fi
echo "$t"; exit 1'
mk_node_muerde "$WS/mu14" "$PKG_VITEST" vitest "$STUB_VITEST_CFG"
mkdir -p packages/ui/src
printf "export default { test: { include: ['packages/**'] } }\n" > vitest.config.ts
printf "test('tokens', () => {})\n" > packages/ui/src/tokens.test.ts
git add -A && git commit -qm "paquete nuevo con su include"
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "config del runner que solo existe en tu rama: ni verde ni rojo"
assert_contains "$out" "ÁRBOL BASE" "el mensaje dice DONDE no se colecta, que es todo el punto"
assert_contains "$out" "cannot load config" "y muestra el motivo real que dio el runner"
assert_contains "$out" "tu árbol SÍ lo colecta" "la segunda sonda separa 'incolectable' de 'la base no lo alcanza'"
assert_contains "$out" "EMIT assumption" "y el tramo sin red viaja como supuesto igual"

# (j3) #85: una sonda CORTADA no contesto "no colecta", no contesto NADA, y
# decir lo contrario es el mismo silencio con otro disfraz. El limite real son
# 120s: aca se sustituye el acotador por uno de 1s para no pagarlos en la suite
# (el acotador de verdad ya tiene sus propios casos, arriba).
mkdir -p "$WS/hang/node_modules/.bin" "$WS/hang/base"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$WS/hang/node_modules/.bin/vitest"
chmod +x "$WS/hang/node_modules/.bin/vitest"
out="$( . "$WS/gate_muerde.sh"
        WT="$WS/hang"; MUERDE_NODE_RUNNERS="vitest"
        con_limite() { run_bounded 1 2 "${@:2}"; }
        muerde_node_colecta_en "$WS/hang/base" x.test.ts || true
        printf '%s' "${MUERDE_COLECTA_DIAG:-}" )"
assert_contains "$out" "se pasó del límite" "una sonda cortada se reporta como timeout, no como 'no colecta'"

# (k) COR-656: con @playwright/test declarado e instalado, el spec e2e SÍ se
#     verifica. Antes muerde_node devolvía 1 ('no declara vitest ni jest') y el
#     tramo entero quedaba sin mirar.
PKG_PW='{"devDependencies":{"@playwright/test":"^1"}}'
STUB_PW='#!/bin/sh
[ "$1" = "test" ] || exit 2
shift
if [ "$1" = "--list" ]; then shift; echo "$1"; exit 0; fi
if [ -f feature.ts ]; then echo "1 passed"; exit 0; fi
echo "cannot find ./feature"; exit 1'
mk_node_muerde "$WS/mu9" "$PKG_PW" playwright "$STUB_PW"
mkdir -p e2e
printf 'export const f = 1\n' > feature.ts
printf "test('flujo', () => {})\n" > e2e/flujo.spec.ts
git add -A && git commit -qm pw
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "spec e2e con @playwright/test declarado: se verifica de verdad"
assert_contains "$out" "MUERDE" "y falla sobre la base, como debe"
assert_not_contains "$out" "NO pude verificar" "sin declararse ciego por no conocer el runner"

# (l) pytest exit 5 = 'no colecté ningún caso': ahí no corrió NINGÚN test, así
#     que ese rojo no dice nada del cambio.
mk_muerde_repo "$WS/mu10"
printf 'def _fabrica_sincasos():\n    return 1\n' > tests/test_sincasos.py
git add -A && git commit -qm "archivo test_ sin casos"
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "pytest exit 5 (nada colectado): no bloquea"
assert_contains "$out" "no colectó ningún caso" "y lo dice como tramo sin red"
assert_contains "$out" "EMIT assumption" "con el supuesto en el bus"
assert_not_contains "$out" "o sea que MUERDE" "sin cobrarlo como verificación"

# (m) el falso verde de Go en monorepo. El arreglo (muerde_go_base_compila)
#     estaba puesto pero SIN un solo test que lo fijara, o sea que la próxima
#     edición podía devolverlo sin que nadie se enterara. En un monorepo con
#     `replace ... => ../../pkg`, el worktree temporal nace sin el go.work que
#     hace resolver ese replace: la base ni compila. El gate leía ese fallo de
#     COMPILACIÓN como "el test MUERDE" y salía verde con cualquier contenido.
cat > "$WS/bin-muerde/go" <<'SH'
#!/bin/sh
# La base no resuelve su grafo de módulos: build y test fallan por lo MISMO,
# que es justo la ambigüedad que el gate tiene que deshacer.
echo "pkg@v0.0.0: replacement directory ../../pkg does not exist" >&2
exit 1
SH
chmod +x "$WS/bin-muerde/go"
mk_muerde_repo "$WS/mu11"
printf 'package svc\n\nfunc TestNuevo(t *testing.T) {}\n' > svc_test.go
git add -A && git commit -qm "test go en un monorepo cuya base no compila"
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "la base Go no compila: el gate no inventa un rojo"
assert_contains "$out" "el ÁRBOL BASE no compila sin tu cambio" "y dice que quedó ciego"
assert_contains "$out" "EMIT assumption" "con el supuesto en el bus"
assert_not_contains "$out" "o sea que MUERDE" "sin cobrar el fallo de compilación como verificación"
rm -f "$WS/bin-muerde/go"

# (m2) #75: la ceguera del (m) era el estado NORMAL en los SEIS servicios Go de
#      la plataforma (atlas, hermes, muse, apollo, argos, gateway), porque todos
#      usan ese layout. O sea que el gate mas caro del precheck no verificaba
#      nada en ninguno, y su verde declaraba un tramo sin mirar.
#      La pieza que lo arregla ya existia: gowork.sh sabe armar el go.work con
#      los replaces resueltos contra repos/ canonico. Solo faltaba que el gate
#      la apuntara al arbol base (gowork.sh --base).
#      El stub modela la unica distincion que importa: CON go.work el modulo
#      resuelve y el test corre (y falla, o sea MUERDE); SIN go.work no compila.
cp "$ROOT/templates/scripts/gowork.sh" "$WS/scripts/gowork.sh" 2>/dev/null || \
  { mkdir -p "$WS/scripts"; cp "$ROOT/templates/scripts/gowork.sh" "$WS/scripts/gowork.sh"; }
cat > "$WS/bin-muerde/go" <<'SH'
#!/bin/sh
if [ -f ./go.work ]; then
  # con el go.work el grafo resuelve: el test nuevo corre y falla sobre la base
  case "$1" in
    build) exit 0 ;;
    test)  echo "--- FAIL: TestNuevo (undefined)"; exit 1 ;;
  esac
  exit 0
fi
echo "pkg@v0.0.0: replacement directory ../../pkg does not exist" >&2
exit 1
SH
chmod +x "$WS/bin-muerde/go"
mkdir -p "$WS/repos/pkg"
printf 'module example.com/pkg\n\ngo 1.21\n' > "$WS/repos/pkg/go.mod"
mk_muerde_repo "$WS/mu11b"
printf 'module example.com/svc\n\ngo 1.22\n\nrequire example.com/pkg v0.0.0\n\nreplace example.com/pkg => ../../pkg\n' > go.mod
printf 'package svc\n\nfunc TestNuevo(t *testing.T) {}\n' > svc_test.go
git add -A && git commit -qm "test go en monorepo, con el go.work armado por el gate"
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "#75: el gate VERIFICA en un monorepo Go (antes quedaba ciego siempre)"
assert_contains "$out" "MUERDE" "y llega a un veredicto de verdad"
assert_not_contains "$out" "el ÁRBOL BASE no compila sin tu cambio" \
  "sin declarar la ceguera que era el estado normal en los seis servicios Go"

# La degradacion del #43 NO se revierte: sin gowork.sh disponible, el gate
# sigue declarando la ceguera en vez de inventar un verde.
mv "$WS/scripts/gowork.sh" "$WS/scripts/gowork.sh.off"
mk_muerde_repo "$WS/mu11c"
printf 'module example.com/svc\n\ngo 1.22\n\nrequire example.com/pkg v0.0.0\n\nreplace example.com/pkg => ../../pkg\n' > go.mod
printf 'package svc\n\nfunc TestNuevo(t *testing.T) {}\n' > svc_test.go
git add -A && git commit -qm "sin gowork.sh en la instancia"
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "sin gowork.sh: el gate no inventa un rojo"
assert_contains "$out" "el ÁRBOL BASE no compila sin tu cambio" "y la ceguera del #43 sigue diciendose"
assert_contains "$out" "EMIT assumption" "con su supuesto en el bus"
mv "$WS/scripts/gowork.sh.off" "$WS/scripts/gowork.sh"
rm -f "$WS/bin-muerde/go"

# (n) COR-625: un .tftest.hcl NI SIQUIERA entraba al alcance del gate (el
#     patron no lo miraba) y no habia runner para el. Un repo de infra sumaba
#     tests nuevos y este gate salia verde sin haber corrido ninguno.
#     El stub modela la unica distincion que importa: el test "vacuo" pasa
#     sobre la base (no muerde), el otro falla porque el modulo nuevo no
#     existe ahi todavia.
cat > "$WS/bin-muerde/terraform" <<'SH'
#!/bin/sh
case "$1" in
  init) exit 0 ;;
  test) for a in "$@"; do case "$a" in -filter=*vacuo*) echo "pasa en la base"; exit 0 ;; esac; done
        echo "fallo: el modulo nuevo no existe en la base"; exit 1 ;;
esac
exit 0
SH
chmod +x "$WS/bin-muerde/terraform"

mk_muerde_repo "$WS/mu-tf1"
mkdir -p tests && printf 'run "x" {}\n' > tests/muerde.tftest.hcl
git add -A && git commit -qm tftest
out="$(run_muerde)"; rc=$?
assert_eq 0 "$rc" "tftest que falla sobre la base: verde (muerde)"
assert_contains "$out" "tests/muerde.tftest.hcl" "el gate lo miro (antes ni entraba al alcance)"
assert_contains "$out" "MUERDE" "y lo dice"

mk_muerde_repo "$WS/mu-tf2"
mkdir -p tests && printf 'run "x" {}\n' > tests/vacuo.tftest.hcl
git add -A && git commit -qm vacuo
out="$(run_muerde)"; rc=$?
assert_eq 3 "$rc" "tftest que pasa TAMBIEN sobre la base: bloquea (exit 3)"
assert_contains "$out" "tests/vacuo.tftest.hcl" "nombrando el archivo exacto"
rm -f "$WS/bin-muerde/terraform"

# ── DÓNDE corre: --precheck y --ci, jamás el camino de ship ──────────
# El ship reintenta el push hasta 20 veces por contención: meterlo ahí pagaría un
# checkout del árbol base por intento para reconfirmar una respuesta que no
# cambia (el test es el mismo y el merge-base también). No es un agujero: /review
# no lanza a nadie sin el sello del precheck.
n_inv="$(grep -c '^ *gate_test_muerde$' "$TMPL")"
assert_eq 2 "$n_inv" "se invoca exactamente dos veces (precheck y CI), en ningún otro lado"
loop_line="$(grep -n '^# ── Loop de ship' "$TMPL" | head -1 | cut -d: -f1)"
ultima_inv="$(grep -n '^ *gate_test_muerde$' "$TMPL" | tail -1 | cut -d: -f1)"
[ -n "$loop_line" ] && [ -n "$ultima_inv" ] && [ "$ultima_inv" -lt "$loop_line" ] \
  && pass "las dos invocaciones están ANTES del loop de ship (no se paga por intento de push)" \
  || fail "gate_test_muerde se invoca dentro del loop de ship (muerde=$ultima_inv loop=$loop_line)"
# Y DESPUÉS de la fase 0 barata: descubrir un test vacuo tras pagar la suite
# completa es el orden que este archivo ya corrigió una vez.
tras_fase0="$(grep -A6 '^ *run_phase0_gates$' "$TMPL" | grep -c 'gate_test_muerde')"
assert_eq 2 "$tras_fase0" "y las dos van DESPUÉS de run_phase0_gates (los baratos primero)"

cd "$WS"

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
assert_contains "$out" "no tiene package.json en la raíz" "monorepo: nombra la causa"
assert_contains "$out" "apps/web/package.json" "monorepo: muestra dónde sí lo encontró"
assert_contains "$out" "tramo SIN MIRAR" "monorepo: dice que no es un verde"
# NO bloquea, misma correccion que del lado Python (#60): un exit 3 aca inventa
# un veredicto sobre el CODIGO cuando la verdad es "no encontre que mirar". El
# silencio era el bug, y sigue cerrado porque esto se dice y viaja al bus.
assert_eq 0 "$rc" "declara el tramo sin mirar, pero NO bloquea"

# Y un package.json bajo un directorio GENERADO no dice que el repo sea TS.
mk_fe "$WS/fe4b"; cd "$WS/fe4b"
rm -f package.json tsconfig.json
mkdir -p gen/ts && echo '{"name":"protos"}' > gen/ts/package.json
git add -A && git commit -qm generado; cd "$WS"
out="$(run_lang "$WS/fe4b")"; rc=$?
assert_eq 0 "$rc" "package.json solo bajo gen/: el repo no es TS"
assert_not_contains "$out" "no tiene package.json en la raíz" \
  "y no molesta con un aviso sobre codigo generado"

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

# ── Helm: un chart TAMBIEN es un stack (#80) ──────────────────────────
# Caso de campo: una library chart de la que dependen todos los servicios de
# una plataforma aterrizaba en main con `verificado: ninguno`. No tiene go.mod
# ni package.json, asi que caia al aviso de stack no reconocido, que NO
# bloquea: un cambio suyo re-renderiza la plataforma entera y ningun gate
# automatico miraba una linea. Aca se mide con un helm de palo: lo que se
# prueba es la RAMA (que exista, que lintee y que renderice), no helm.
mk_helm_repo() {  # mk_helm_repo <dir> <ruta-Chart.yaml> [type]
  mk_stack "$1" .gitkeep
  cd "$1"
  mkdir -p "$(dirname "$2")"
  { printf 'apiVersion: v2\nname: c\nversion: 0.1.0\n'
    [ -n "${3:-}" ] && printf 'type: %s\n' "$3"; } > "$2"
  git add -A && git commit -qm chart
  cd "$WS"
}
# El stub deja rastro en un ARCHIVO ademas de en stdout: `helm template` va a
# /dev/null en el gate (lo que importa es su exit, no el YAML), asi que medir
# solo stdout no distingue "lo renderizo" de "ni lo intento".
HELMLOG="$WS/helm.log"
run_helm() {  # run_helm <dir> <stub-helm> → stdout; el log queda en $HELMLOG
  # OJO: esto se invoca dentro de un $( ), o sea en un subshell. Cualquier
  # variable que se asigne aca muere con el; el ARCHIVO, no.
  : > "$HELMLOG"
  ( cd "$1"; WT="$1"; REPO=r; TASK=T1; BASE_REF=main; HELMLOG="$HELMLOG"
    gate() { :; }; emit() { echo "EMIT $*"; }
    eval "$2"
    . "$WS/lang.sh"; run_lang_gates ) 2>&1
}
HELM_STUB='helm() { echo "HELM $*" >> "$HELMLOG"; echo "HELM $*"; }'

mk_helm_repo "$WS/st-helm" chart/Chart.yaml
out="$(run_helm "$WS/st-helm" "$HELM_STUB")"; log="$(cat "$HELMLOG")"
assert_not_contains "$out" "no reconozco el stack" "un repo con Chart.yaml YA es un stack reconocido"
assert_contains "$log" "HELM lint chart" "lo lintea"
assert_contains "$log" "HELM template chart" "y lo renderiza (el 'compila' de un chart)"

# La library chart del caso de campo: `helm template` sale rojo POR DISEÑO
# ("library charts are not installable"), asi que cobrarlo seria inventar un
# veredicto sobre el chart mas compartido del repo.
mk_helm_repo "$WS/st-helm-lib" Chart.yaml library
out="$(run_helm "$WS/st-helm-lib" "$HELM_STUB")"; log="$(cat "$HELMLOG")"
assert_contains "$log" "HELM lint ." "la library chart de la raiz se lintea"
assert_not_contains "$log" "HELM template" "y NO se renderiza: no es instalable"

# El gate NO puede ensuciar lo que juzga (la leccion de tf_limpio): resolver
# dependencias escribe Chart.lock y charts/*.tgz DENTRO del arbol juzgado, y
# ademas evidence.py rechaza el sello por arbol sucio. Se declara, no se toca.
mk_stack "$WS/st-helm-deps" .gitkeep
cd "$WS/st-helm-deps"
mkdir -p chart
printf 'apiVersion: v2\nname: c\nversion: 0.1.0\ndependencies:\n  - name: lib\n    version: 1.0.0\n    repository: file://../lib\n' > chart/Chart.yaml
git add -A && git commit -qm deps
cd "$WS"
out="$(run_helm "$WS/st-helm-deps" "$HELM_STUB")"; log="$(cat "$HELMLOG")"
assert_not_contains "$log" "HELM lint" "con dependencies sin vendorear NO lintea: resolverlas ensucia el arbol"
assert_contains "$out" "sin vendorear" "y lo dice, con su remediacion"
assert_contains "$out" "EMIT assumption" "el tramo sin mirar viaja como supuesto"

# Contra-mitad 1: con las dependencias vendoreadas SI se lintea. El salto es
# por no poder resolverlas sin escribir, no por tener dependencias.
cd "$WS/st-helm-deps"; mkdir -p chart/charts
printf 'apiVersion: v2\nname: lib\nversion: 1.0.0\n' > chart/charts/lib.yaml
git add -A && git commit -qm vendored; cd "$WS"
out="$(run_helm "$WS/st-helm-deps" "$HELM_STUB")"; log="$(cat "$HELMLOG")"
assert_contains "$log" "HELM lint chart" "con las deps vendoreadas: se lintea igual que cualquier chart"

# Contra-mitad 2: `dependencies: []` DECLARA que no hay ninguna. Saltarse ese
# chart seria negarle el gate por una linea que dice justo lo contrario.
mk_stack "$WS/st-helm-vacio" .gitkeep
cd "$WS/st-helm-vacio"; mkdir -p chart
printf 'apiVersion: v2\nname: c\nversion: 0.1.0\ndependencies: []\n' > chart/Chart.yaml
git add -A && git commit -qm sin-deps; cd "$WS"
out="$(run_helm "$WS/st-helm-vacio" "$HELM_STUB")"; log="$(cat "$HELMLOG")"
assert_contains "$log" "HELM lint chart" "'dependencies: []' no es tener dependencias: el chart se lintea"

# ── UN GATE DURO NECESITA UN VERDE ALCANZABLE ─────────────────────────
# `helm lint` renderiza con los valores por defecto, asi que un chart que EXIGE
# valores de entorno (un `required` sin default) saldria rojo SIEMPRE. La salida
# no la inventa este script: es la convencion de chart-testing, que lintea una
# vez por cada <chart>/ci/*-values.yaml. Sin ella el gate seria un dead-end.
mk_helm_repo "$WS/st-helm-ci" chart/Chart.yaml
cd "$WS/st-helm-ci"; mkdir -p chart/ci
printf 'image: {tag: prod}\n'    > chart/ci/prod-values.yaml
printf 'image: {tag: minimal}\n' > chart/ci/minimal-values.yaml
git add -A && git commit -qm ci-values; cd "$WS"
out="$(run_helm "$WS/st-helm-ci" "$HELM_STUB")"; log="$(cat "$HELMLOG")"
assert_contains "$log" "--values chart/ci/prod-values.yaml" "usa los valores de ci/ (la convencion de chart-testing)"
assert_contains "$log" "--values chart/ci/minimal-values.yaml" "y uno por caso: mezclarlos renderiza un chart que no es ninguno"

# Y el rojo trae su remediacion, que es la ley de la casa: el mensaje ES el
# prompt. Sin ella, un chart que pide valores es un rojo sin salida.
HELM_STUB_ROJO='helm() { if [ "$1" = "lint" ]; then echo "Error: required value not set"; return 1; fi; echo "HELM $*"; }'
out="$(run_helm "$WS/st-helm" "$HELM_STUB_ROJO")"; rc=$?
assert_eq 3 "$rc" "helm lint rojo: el gate bloquea (exit 3), no lo deja pasar"
assert_contains "$out" "ci/<caso>-values.yaml" "y el rojo nombra la salida legitima, no deja al operador sin camino"

# lint y template PARSEAN y RENDERIZAN, pero ninguno AFIRMA nada sobre lo
# renderizado: sin el plugin de unittest el sello no puede decir "corri tests".
out="$(run_helm "$WS/st-helm" "$HELM_STUB")"
assert_contains "$out" "helm-unittest" "sin el plugin, dice que NO corrio tests"
HELM_STUB_UT='helm() { if [ "$1" = "plugin" ]; then echo "unittest 0.5.0"; else echo "HELM $*" >> "$HELMLOG"; echo "HELM $*"; fi; }'
cd "$WS/st-helm"; mkdir -p chart/tests
printf 'suite: x\n' > chart/tests/values_test.yaml
git add -A && git commit -qm unittest; cd "$WS"
out="$(run_helm "$WS/st-helm" "$HELM_STUB_UT")"; log="$(cat "$HELMLOG")"
assert_contains "$log" "HELM unittest chart" "con el plugin instalado y tests presentes, los corre"
assert_not_contains "$out" "falta el plugin" "y ya no avisa de lo que si esta"

# Marcador presente y toolchain ausente: la rama pasa por need(), igual que los
# otros seis stacks (un PATH vacío acá no sirve de prueba: la deteccion misma
# necesita git, asi que mediria otra cosa). El caso vivo lo cubre st-sinbin.
grep -q 'need helm Helm' "$WS/lang.sh" \
  && pass "la rama helm pasa por need(): sin la toolchain se dice, no se finge" \
  || fail "la rama helm no usa need(): un chart sin helm saldria verde sin mirar nada"
cd "$WS"

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

# COR-101: pyproject.toml SOLO en subdirectorio (monorepo, services/, src/).
# La rama Python es `if [ -f pyproject.toml ]` a secas: no entraba, ni ruff ni
# pytest corrian, y el precheck salia verde. La guarda espejo del lado TS ya
# existia, y esa asimetria fue justo lo que delato el agujero.
mk_stack "$WS/st-py-sub" README.md
( cd "$WS/st-py-sub"; mkdir -p services/api
  printf '[project]\nname="api"\nversion="0.1"\n' > services/api/pyproject.toml
  git add -A && git commit -qm sub )
out="$(run_lang_bare "$WS/st-py-sub")"; rc=$?
assert_contains "$out" "el gate python NO PUEDE CORRER" "y dice que el gate no pudo correr"
assert_contains "$out" "ni ruff ni pytest" "nombrando exactamente lo que no se verifico"
assert_contains "$out" "services/api/pyproject.toml" "y el subdirectorio donde si vive"
# run_lang_bare silencia emit, asi que el supuesto se comprueba aparte: que se
# DIGA en consola no alcanza, el humano mira el panel y el veredicto hereda el bus.
out_emit="$( ( set -u; cd "$WS/st-py-sub"; WT="$WS/st-py-sub"; REPO=r; TASK=T1; BASE_REF=main
               gate() { :; }; emit() { echo "EMIT $*"; }
               . "$WS/lang.sh"; run_lang_gates ) 2>&1 )"
assert_contains "$out_emit" "EMIT assumption" "el supuesto viaja al bus, no solo a la consola"
# Y NO bloquea: el silencio era el bug, no la ausencia. Un exit 3 aca inventa un
# veredicto sobre el CODIGO cuando la verdad es "no encontre que mirar", que es
# lo que el resto del archivo tiene prohibido. Costo caro (#60): un repo de
# contratos puros quedo imposible de entregar, y era la RAIZ del DAG.
assert_eq 0 "$rc" "declara el tramo sin mirar, pero NO bloquea (#60)"

# Un artefacto GENERADO no es señal de que el repo sea de ese lenguaje: el unico
# pyproject de un repo de contratos es el wheel que produce su generador.
mk_stack "$WS/st-py-gen" README.md
( cd "$WS/st-py-gen"; mkdir -p gen/python
  printf '[project]\nname="protos"\nversion="0.1"\n' > gen/python/pyproject.toml
  git add -A && git commit -qm generado )
out="$(run_lang_bare "$WS/st-py-gen")"; rc=$?
assert_eq 0 "$rc" "pyproject solo bajo gen/: el repo no es Python, no hay nada que decir"
assert_not_contains "$out" "el gate python NO PUEDE CORRER" \
  "y no molesta con un aviso sobre codigo generado"

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
  # set -euo pipefail: el ENTORNO REAL de ship.sh. El issue #33 (grep -l sin
  # matches + pipefail = muerte muda) era invisible justo porque este runner
  # corría la función extraída sin pipefail: el test probaba otro shell.
  ( set -euo pipefail; WS="$WS"; TASK=T9; REPO=svc; BASE_REF=main
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

echo
echo "── issue #29: ruff y pytest son del PROYECTO, no del sistema"
# `uv sync` los deja en .venv/bin, FUERA del PATH. Llamarlos pelados da 127 y
# NINGUN repo Python podia shippear. La linea de pytest ya pasaba por `uv run`;
# la de ruff no, y esa asimetria era todo el bug.
mk_py() {  # mk_py <dir> [con-tests]
  rm -rf "$1"; mkdir -p "$1"; cd "$1"
  git init -q .; git config user.email t@t; git config user.name t
  printf '[project]\nname="x"\nversion="0.1"\n\n[tool.pytest.ini_options]\npythonpath=["."]\n' > pyproject.toml
  [ -n "${2:-}" ] && { mkdir -p tests; printf 'def test_ok():\n    assert True\n' > tests/test_a.py; }
  git add -A && git commit -qm init >/dev/null
  git update-ref refs/remotes/origin/main HEAD
  cd "$WS"
}
run_py() {  # run_py <dir> <PATH>
  ( set -euo pipefail; cd "$1"; PATH="$2"; WT="$1"; REPO=x; TASK=T1; BASE_REF=main; WS="$WS"
    gate() { :; }; emit() { :; }
    . "$WS/lang.sh"; run_lang_gates; echo "TESTS_RAN=$TESTS_RAN" ) 2>&1
}

# 1. sin ruff, sin pytest, sin uv: NO puede salir 127
mk_py "$WS/py1"
out="$(run_py "$WS/py1" /usr/bin:/bin)"; rc=$?
assert_eq 0 "$rc" "sin herramientas: no revienta con 127 (era el bug de #29)"
assert_contains "$out" "no encuentro ruff" "dice que el lint no corrio"
assert_contains "$out" "no encuentro pytest" "y que los tests tampoco"
assert_contains "$out" "TESTS_RAN=0" "y NO afirma haber testeado"

# 2. con uv, ruff se invoca POR uv (el bug era que solo pytest lo hacia)
# El stub deja rastro en un log, no en stdout: su stdout es el JSON que el
# ratchet consume, y lo que se mide aca es QUIEN invoca, no que imprime.
mkdir -p "$WS/stub"
cat > "$WS/stub/uv" <<'SH'
#!/bin/sh
echo "UVRUN $*" >> "$UVLOG"
case "$2" in
  ruff) [ "$3" = "--version" ] && { echo "ruff 0.0.0-stub"; exit 0; }; echo '[]'; exit 0 ;;
esac
exit 0
SH
chmod +x "$WS/stub/uv"
export UVLOG="$WS/uv-calls.log"; : > "$UVLOG"
mk_py "$WS/py2"
out="$(run_py "$WS/py2" "$WS/stub:/usr/bin:/bin")"
calls="$(cat "$UVLOG")"
assert_contains "$calls" "UVRUN run ruff check" "con uv presente, ruff se invoca por uv run"
assert_contains "$calls" "UVRUN run pytest" "y pytest tambien (no se rompio lo que andaba)"

# 3. el marcador mide lo que el sello afirma: TESTS RAN, no "reconoci el stack"
if command -v pytest >/dev/null 2>&1 && command -v ruff >/dev/null 2>&1; then
  # uv que falla: fuerza la rama de binario pelado y evita que `uv run` salga a
  # sincronizar un venv (la suite es hermetica, no baja nada de la red).
  mkdir -p "$WS/nouv"; printf '#!/bin/sh\nexit 2\n' > "$WS/nouv/uv"; chmod +x "$WS/nouv/uv"
  mk_py "$WS/py3" tests
  out="$(run_py "$WS/py3" "$WS/nouv:$PATH")"
  assert_contains "$out" "TESTS_RAN=1" "con la toolchain real: declara que SI corrio"
else
  pass "toolchain real: saltado (falta ruff/pytest en esta maquina)"
fi

echo
echo "── issue #30: uv presente y ruff ausente del venv no puede matar el gate"
# `uv run ruff` sale 2 ("Failed to spawn: ruff") y bajo set -e mataba el gate
# ANTES del else honesto: la rama que explica como arreglarlo era inalcanzable.
mkdir -p "$WS/stub2"; printf '#!/bin/sh\necho "error: Failed to spawn: $2" >&2\nexit 2\n' > "$WS/stub2/uv"
chmod +x "$WS/stub2/uv"
mk_py "$WS/py30"
out="$(run_py "$WS/py30" "$WS/stub2:/usr/bin:/bin")"; rc=$?
assert_eq 0 "$rc" "uv sin ruff en el venv: el gate NO muere con exit 2"
assert_contains "$out" "no encuentro ruff" "y SI llega a la rama que explica como arreglarlo"
assert_contains "$out" "no encuentro pytest" "lo mismo para pytest (misma trampa)"
assert_contains "$out" "TESTS_RAN=0" "y no afirma haber testeado"

echo
echo "── COR-698: pytest exit 5 ('no colecté ningún test') no es un fallo"
# Un repo de contratos puros (cero tests Python) con pyproject en la raíz: el
# gate SI corre pytest, pytest sale 5, y bajo `set -e` eso mataba el ship para
# siempre. Es una causa ambiental disfrazada de defecto de codigo, la misma
# familia que el disco lleno. La contra-mitad importa igual: un 1 (tests que
# FALLARON) tiene que seguir matando el ship, o el arreglo seria un falso verde.
mkdir -p "$WS/stub5"
printf '#!/bin/sh\nexit 2\n' > "$WS/stub5/uv"                      # fuerza binario pelado
printf '#!/bin/sh\necho "no tests ran"\nexit 5\n' > "$WS/stub5/pytest"
printf '#!/bin/sh\n[ "$1" = "check" ] && { echo "[]"; exit 0; }\nexit 0\n' > "$WS/stub5/ruff"
chmod +x "$WS/stub5/uv" "$WS/stub5/pytest" "$WS/stub5/ruff"
mk_py "$WS/py698"
out="$(run_py "$WS/py698" "$WS/stub5:/usr/bin:/bin")"; rc=$?
assert_eq 0 "$rc" "pytest exit 5: el gate NO muere (antes: ship imposible para siempre)"
assert_contains "$out" "no colectó NINGÚN test" "y lo DICE, no pasa en silencio"
assert_contains "$out" "SIN VERIFICAR" "nombrando lo que quedó sin mirar"
assert_contains "$out" "collect-only" "con la remediación ejecutable"
assert_contains "$out" "TESTS_RAN=0" "y NO afirma haber testeado: el sello dirá 'ninguno'"

# la contra-mitad: un rojo de verdad sigue siendo un rojo
printf '#!/bin/sh\necho "1 failed"\nexit 1\n' > "$WS/stub5/pytest"; chmod +x "$WS/stub5/pytest"
mk_py "$WS/py698b"
out="$(run_py "$WS/py698b" "$WS/stub5:/usr/bin:/bin")"; rc=$?
assert_eq 1 "$rc" "pytest exit 1 (tests ROJOS): sigue matando el ship"
assert_not_contains "$out" "TESTS_RAN=0" "y ni siquiera llega a imprimir el marcador"

echo
echo "── issue #31: ruff ratchetea igual que buf, la deuda de main no bloquea"
# Medido en un repo real: 144 violaciones heredadas en main dejaban a TODA
# tarea de ese repo sin poder llegar a review, sin haber tocado una sola.
# El stub reporta una violacion por archivo .py que diga VIOLA: asi la baseline
# tiene que ser un CHECKOUT de origin/main de verdad para que el ratchet ande.
mkdir -p "$WS/stubruff"
cat > "$WS/stubruff/ruff" <<'SH'
#!/bin/sh
[ "$1" = "--version" ] && { echo "ruff 0.0.0-stub"; exit 0; }
for a in "$@"; do root="$a"; done
printf '['; sep=""; n=0
for f in "$root"/*.py; do
  [ -f "$f" ] || continue
  grep -q VIOLA "$f" || continue
  printf '%s{"filename":"%s","code":"F401","message":"import sin usar"}' "$sep" "$f"
  sep=","; n=$((n+1))
done
printf ']\n'
[ "$n" -eq 0 ] || exit 1
SH
chmod +x "$WS/stubruff/ruff"
mk_py_debt() {  # mk_py_debt <dir> — main YA trae deuda de lint
  mk_py "$1"; cd "$1"
  printf 'import os  # VIOLA\n' > deuda.py
  git add -A; git commit -qm deuda >/dev/null
  git update-ref refs/remotes/origin/main HEAD
  cd "$WS"
}

# 1. deuda preexistente y cero cambios propios: pasa, y lo dice
mk_py_debt "$WS/py31a"
out="$(run_py "$WS/py31a" "$WS/stubruff:/usr/bin:/bin")"; rc=$?
assert_eq 0 "$rc" "deuda heredada en main: NO bloquea (era el bug de #31)"
assert_contains "$out" "PREEXISTENTES" "y la cuenta queda dicha, no escondida"

# 2. una violacion NUEVA sobre esa misma deuda: bloquea con exit 3
mk_py_debt "$WS/py31b"; cd "$WS/py31b"
printf 'import sys  # VIOLA\n' > nueva.py
git add -A; git commit -qm nueva >/dev/null
cd "$WS"
out="$(run_py "$WS/py31b" "$WS/stubruff:/usr/bin:/bin")"; rc=$?
assert_eq 3 "$rc" "violacion nueva: bloquea (el ratchet no es una amnistia)"
assert_contains "$out" "nueva.py" "y nombra SOLO la que introdujo el cambio"
assert_not_contains "$out" "deuda.py: F401" "sin arrastrar la deuda ajena al error"
sh="$(cat "$TMPL")"
assert_contains "$sh" "TESTS_RAN" "el gate distingue 'corri tests' de 'reconoci el stack'"
assert_not_contains "$sh" 'printf ../%s.. "${LANG_SEEN:-0}" > "$WS/tasks' "y el sello ya no usa LANG_SEEN como prueba"

echo
echo "── terraform: el repo infra deja de pasar el precheck sin validar nada"
# Caso de campo: los repos terraform pasaban el precheck sin verificar NADA
# (caian al aviso de stack no reconocido, que no bloquea) y son justo los que
# auto-aplican produccion al mergear.

# 1. tf en raiz, CLI stubbeada: corre fmt + init + validate, stack reconocido
# El stub deja rastro en un log (mismo patron que UVLOG): el init manda su
# stdout a /dev/null en el template, asi que el rastro no puede ir por stdout.
mk_stack "$WS/st-tf" main.tf
export TFLOG="$WS/tf-calls.log"; : > "$TFLOG"
out="$( ( cd "$WS/st-tf"; WT="$WS/st-tf"; REPO=r; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }
          terraform() { echo "TF $* pwd=${PWD##*/}" >> "$TFLOG"; echo "TF $* pwd=${PWD##*/}"; }
          . "$WS/lang.sh"; run_lang_gates; echo "TESTS_RAN=$TESTS_RAN" ) 2>&1 )"
calls="$(cat "$TFLOG")"
assert_contains "$calls" "TF fmt -check -recursive" "tf raiz: corre fmt -check"
assert_contains "$calls" "TF init -backend=false" "tf raiz: init sin backend"
assert_contains "$calls" "TF validate" "tf raiz: corre validate"
assert_not_contains "$out" "no reconozco el stack" "tf: el stack se reconoce"
assert_contains "$out" "TESTS_RAN=0" "validate NO cuenta como suite de tests"

# 2. tf sin CLI: degrada honesto (patron need), no finge ni revienta.
# t_path_without y no PATH=/nonexistent: la deteccion usa git ls-files, y un
# PATH vacio mata a git ANTES de llegar a la rama que se quiere probar.
out="$( ( cd "$WS/st-tf"; WT="$WS/st-tf"; REPO=r; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }; PATH="$(t_path_without terraform)"
          . "$WS/lang.sh"; run_lang_gates ) 2>&1 )"; rc=$?
assert_eq 0 "$rc" "tf sin terraform CLI: degrada, no bloquea"
assert_contains "$out" "no está instalado" "tf sin CLI: lo dice"
assert_not_contains "$out" "no reconozco el stack" "tf sin CLI: el stack igual se reconoce"

# 3. tf SOLO en subdir (envs/prod): validate corre CON cd a ese dir
mk_stack "$WS/st-tf-sub" README.md
( cd "$WS/st-tf-sub"; mkdir -p envs/prod; : > envs/prod/main.tf
  git add -A && git commit -qm tf )
out="$( ( cd "$WS/st-tf-sub"; WT="$WS/st-tf-sub"; REPO=r; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }
          terraform() { echo "TF $* pwd=${PWD##*/}"; }
          . "$WS/lang.sh"; run_lang_gates ) 2>&1 )"
assert_contains "$out" "envs/prod" "tf subdir: nombra el dir que valida"
assert_contains "$out" "TF validate pwd=prod" "tf subdir: validate corre EN el subdir"

# 4. validate rojo bloquea (fail-closed con la CLI presente). El set -e es el
# del entorno real: ship.sh corre bajo set -euo pipefail.
( set -e; cd "$WS/st-tf"; WT="$WS/st-tf"; REPO=r; TASK=T1; BASE_REF=main
  gate() { :; }; emit() { :; }
  terraform() { if [ "$1" = "validate" ]; then return 1; fi; return 0; }
  . "$WS/lang.sh"; run_lang_gates ) >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "validate rojo: el gate bloquea" || fail "validate rojo salio verde"

# 5. COR-416/347: el gate NO puede ensuciar el arbol que juzga. `terraform
# init` escribe .terraform/ y .terraform.lock.hcl en el modulo: la primera
# corrida del precheck sellaba con arbol limpio y la segunda lo encontraba
# sucio POR ARTEFACTOS DEL PROPIO GATE. Visto en dos repos independientes.
mk_stack "$WS/st-tf-sucio" main.tf
out="$( ( cd "$WS/st-tf-sucio"; WT="$WS/st-tf-sucio"; REPO=r; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }
          terraform() {
            if [ "$1" = "init" ]; then
              printf 'hashes que init inventa\n' > .terraform.lock.hcl
              mkdir -p "${TF_DATA_DIR:-.terraform}/plugin"
            fi
            echo "TF $* pwd=${PWD##*/}"
          }
          . "$WS/lang.sh"; run_lang_gates
          echo "PORCELAIN:[$(git status --porcelain)]"
          if [ -d .terraform ]; then echo "QUEDO .terraform"; fi ) 2>&1 )"
assert_contains "$out" "PORCELAIN:[]" "el gate terraform NO deja el worktree sucio (COR-416/347)"
assert_not_contains "$out" "QUEDO .terraform" "y los plugins no aterrizan en el modulo"

# 6. Un lock COMMITEADO es parte del artefacto juzgado: init lo reescribe con
# hashes de plataforma, y el gate tiene que devolverlo intacto.
mk_stack "$WS/st-tf-lock" main.tf
( cd "$WS/st-tf-lock"; printf 'LOCK-ORIGINAL\n' > .terraform.lock.hcl
  git add -A && git commit -qm lock )
out="$( ( cd "$WS/st-tf-lock"; WT="$WS/st-tf-lock"; REPO=r; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }
          terraform() {
            if [ "$1" = "init" ]; then printf 'REESCRITO-POR-INIT\n' > .terraform.lock.hcl; fi
            echo "TF $* pwd=${PWD##*/}"
          }
          . "$WS/lang.sh"; run_lang_gates
          echo "LOCK:[$(cat .terraform.lock.hcl)]"
          echo "PORCELAIN:[$(git status --porcelain)]" ) 2>&1 )"
assert_contains "$out" "LOCK:[LOCK-ORIGINAL]" "el lock commiteado vuelve intacto aunque init lo reescriba"
assert_contains "$out" "PORCELAIN:[]" "y el arbol versionado queda igual que antes del gate"

# 6b. #57 del reves, y es el que faltaba: en un repo SIN lock commiteado, la
# limpieza corria ANTES del subcomando y borraba el lock que init acababa de
# escribir. Sin lock, validate ya no resuelve los providers que init instalo:
# "Missing required provider" para todos, con el diff VACIO. El gate salia rojo
# SIEMPRE y sin camino legitimo a verde. Solo se veia en repos sin lock
# commiteado, por eso paso desapercibido.
mk_stack "$WS/st-tf-sinlock" main.tf
out="$( ( cd "$WS/st-tf-sinlock"; WT="$WS/st-tf-sinlock"; REPO=r; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }
          terraform() {
            if [ "$1" = "init" ]; then printf 'CREADO-POR-INIT\n' > .terraform.lock.hcl; return 0; fi
            # Solo validate y test resuelven providers: fmt no toca el lock, y
            # exigirselo seria modelar mal y romper el gate por otro lado.
            # Con `if` y no `case`: un `)` de patron dentro de $( ) le corta el
            # command-substitution al parser y el subshell entero se lee como
            # un nombre de archivo. Ya nos costo una vuelta aca mismo.
            if [ "$1" = validate ] || [ "$1" = test ]; then
              if [ ! -f .terraform.lock.hcl ]; then
                echo "Error: Missing required provider"; return 1
              fi
              echo "TF $* con lock:[$(cat .terraform.lock.hcl)]"
            else
              echo "TF $*"
            fi
          }
          . "$WS/lang.sh"; run_lang_gates
          echo "PORCELAIN:[$(git status --porcelain)]" ) 2>&1 )"
assert_contains "$out" "con lock:[CREADO-POR-INIT]" \
  "sin lock commiteado, el subcomando corre CON el lock que init creo (#56)"
assert_not_contains "$out" "Missing required provider" \
  "y no se lo borra debajo: el gate ya no se ensucia a si mismo hasta el rojo"
assert_contains "$out" "PORCELAIN:[]" \
  "y el lock que no estaba commiteado igual se limpia DESPUES, no antes"

# 7. COR-625: validate PARSEA, test EJECUTA. Un repo de infra con
# tests/*.tftest.hcl pasaba el precheck sin correr un solo test suyo.
mk_stack "$WS/st-tf-test" README.md
( cd "$WS/st-tf-test"; mkdir -p infra/tests; : > infra/main.tf
  printf 'run "x" {}\n' > infra/tests/kargo.tftest.hcl
  git add -A && git commit -qm tftest )
out="$( ( cd "$WS/st-tf-test"; WT="$WS/st-tf-test"; REPO=r; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }
          terraform() { echo "TF $* pwd=${PWD##*/}"; }
          . "$WS/lang.sh"; run_lang_gates; echo "TESTS_RAN=$TESTS_RAN" ) 2>&1 )"
assert_contains "$out" "TF test pwd=infra" "terraform test corre EN la raiz del modulo (el sufijo tests/ se recorta)"
assert_contains "$out" "TESTS_RAN=1" "y ESO si es una suite: TESTS_RAN=1"
cd "$WS"

echo
echo "── go en subdir con package.json en la raiz (bug de campo del controller/)"
mk_fe "$WS/go-sub"; cd "$WS/go-sub"
mkdir -p controller && : > controller/go.mod
rm -f tsconfig.json
echo '{"name":"x","scripts":{"typecheck":"true","test":"true"}}' > package.json
git add -A && git commit -qm gosub; mkdir -p node_modules; cd "$WS"
out="$( ( cd "$WS/go-sub"; WT="$WS/go-sub"; REPO=r; TASK=T1; BASE_REF=main
          gate() { :; }; emit() { :; }; npm() { :; }; npx() { :; }
          go() { echo "GO $* pwd=${PWD##*/}"; }
          . "$WS/lang.sh"; run_lang_gates; echo "TESTS_RAN=$TESTS_RAN" ) 2>&1 )"
assert_contains "$out" "GO test ./... pwd=controller" "go.mod en controller/: los tests Go SI corren"
assert_contains "$out" "TESTS_RAN=1" "y cuentan como suite"

# go.mod vendored NO dispara la rama
mk_stack "$WS/go-vendor" README.md
( cd "$WS/go-vendor"; mkdir -p vendor/dep; : > vendor/dep/go.mod
  git add -A && git commit -qm vendor )
out="$(run_lang_bare "$WS/go-vendor")"
assert_contains "$out" "no reconozco el stack" "go.mod de vendor/ no cuenta como stack"
cd "$WS"

echo
echo "── gate_evidence: juzga el fondo (el archivo), no la forma de la cita"
# Caso de campo: cuatro ships frenados con el review CORRECTO porque la cita
# venia como tests/x.py::caso (pytest) o archivo:NN y el -e se aplicaba a la
# cadena entera, que jamas existe en disco. El gate rechazaba exactamente la
# conducta que el prompt del reviewer pide: citar el caso concreto que abrio.

extract gate_evidence > "$WS/gate_evidence.sh"
grep -q 'NADIE LO LEYÓ' "$WS/gate_evidence.sh" || { echo "no pude extraer gate_evidence"; exit 1; }

mkdir -p "$WS/tasks/TEV" "$WS/wt-ev/tests"
printf 'def test_caso():\n    assert True\n' > "$WS/wt-ev/tests/test_a.py"
: > "$WS/wt-ev/main.go"

run_gate_evidence() {  # run_gate_evidence <compliance-json> [evidence-log]
  printf '{"schema":1,"compliance":%s}' "$1" > "$WS/tasks/TEV/verdict-ev.json"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$WS/tasks/TEV/evidence.log"
  else rm -f "$WS/tasks/TEV/evidence.log"; fi
  ( set -u; WS="$WS"; WT="$WS/wt-ev"; TASK=TEV; REPO=ev
    gate() { :; }
    . "$WS/gate_evidence.sh"; gate_evidence ) 2>&1
}

# 1. cita pytest archivo::caso, con el archivo leido tal cual la corrio el reviewer
ts="2026-07-27T10:00:00Z	sid	ran	pytest tests/test_a.py::test_caso"
out="$(run_gate_evidence '[{"req":"R1","covered":true,"tests":["tests/test_a.py::test_caso"]}]' "$ts")"
assert_eq 0 $? "cita archivo::caso con el archivo real: PASA"
assert_not_contains "$out" "NO EXISTE" "el ::caso no se lee como parte de la ruta"

# 2. cita archivo:NN, con la lectura registrada solo como archivo pelado
ts="2026-07-27T10:00:00Z	sid	read	main.go"
out="$(run_gate_evidence '[{"req":"R2","covered":true,"tests":["main.go:42"]}]' "$ts")"
assert_eq 0 $? "cita archivo:NN leida como archivo pelado: PASA"

# 3. el gate sigue vivo: archivo inexistente bloquea aunque traiga ::caso
out="$(run_gate_evidence '[{"req":"R3","covered":true,"tests":["tests/no_existe.py::caso"]}]' "x")"
assert_eq 3 $? "archivo inexistente con ::caso: sigue bloqueando"
assert_contains "$out" "NO EXISTE" "y nombra la causa real"

# 4. y archivo existente que nadie leyo sigue bloqueando
out="$(run_gate_evidence '[{"req":"R4","covered":true,"tests":["main.go"]}]' "otra-cosa")"
assert_eq 3 $? "archivo jamas leido: sigue bloqueando"
assert_contains "$out" "NADIE LO LEYÓ" "con el mensaje de siempre"

echo
echo "── la entrega la declara la invocación: ship.sh obedece, no pregunta"
# El dolor de campo: el implementer terminaba y preguntaba en el chat "no
# commiteé ni shippeé, ¿lo llevo por /review + ship?". La respuesta ya la dio
# quien invocó (/smart = review, /smart-pr = prs, /smart-main = trunk) y viaja
# como dato en state.json. Lo que se fija acá es que ship.sh la LEA y la
# obedezca: que se niegue a publicar cuando la entrega dice que no, que la
# entrega de la tarea gane al flow del workspace, y que un dato ilegible no se
# disfrace de "lo de siempre".

# El bloque REAL del template: desde el default de DELIVERY hasta el marcador
# que cierra la puerta efectiva. Es código de nivel superior (no una función),
# así que se extrae por marcadores en vez de por firma.
awk '/^DELIVERY=flow$/{f=1} f{print} /^# fin-puerta-efectiva/{if(f) exit}' "$TMPL" \
  > "$WS/puerta-raw.sh"
grep -q 'delivery-mode' "$WS/puerta-raw.sh" || { echo "no pude extraer la consulta de delivery-mode"; exit 1; }
grep -q 'FLOW_MODE=trunk' "$WS/puerta-raw.sh" || { echo "no pude extraer el case del flow"; exit 1; }
grep -q 'fin-puerta-efectiva' "$WS/puerta-raw.sh" || { echo "la extracción no llegó al marcador de cierre"; exit 1; }

puerta() {  # puerta <flow-workspace> <salida-delivery-mode> [rc] [precheck] → salida + exit
  # DMOUT/DMRC en mayúsculas: bash tiene scope dinámico y un `dm_out` acá lo
  # pisaría el `local` de resolve_delivery (misma lección que LIMOUT/LIMRC).
  sed "s/{{FLOW}}/$1/" "$WS/puerta-raw.sh" > "$WS/puerta.sh"
  ( set -euo pipefail
    WS="$WS"; TASK=T1; REPO=svc
    PRECHECK="${4:-0}"; LANG_ONLY=0; CI_MODE=0
    DMOUT="$2"; DMRC="${3:-0}"
    python3() { printf '%b' "$DMOUT"; return "$DMRC"; }
    . "$WS/puerta.sh"
    echo "FLOW_MODE=$FLOW_MODE" ) 2>&1
}

# (b) delivery=trunk con flow prs del workspace → gana la tarea
out="$(puerta prs trunk)"; rc=$?
assert_eq 0 "$rc" "delivery trunk sobre flow prs: la puerta se resuelve sin negarse"
assert_contains "$out" "FLOW_MODE=trunk" "delivery trunk OVERRIDEA el flow prs del workspace"
assert_contains "$out" "manda sobre flow: prs" "y lo dice, en vez de cambiar la puerta en silencio"

# (c) delivery=prs con flow trunk del workspace → gana la tarea, del otro lado
out="$(puerta trunk prs)"; rc=$?
assert_eq 0 "$rc" "delivery prs sobre flow trunk: se resuelve"
assert_contains "$out" "FLOW_MODE=prs" "delivery prs OVERRIDEA el flow trunk (la simétrica)"

# (c2) #58: flow trunk-merge-commit. Es trunk (misma puerta, mismos gates) pero
# aterriza con merge commit para que revertir sea UN comando.
out="$(puerta trunk-merge-commit trunk)"; rc=$?
assert_eq 0 "$rc" "flow trunk-merge-commit: es una puerta implementada, no un rojo"
assert_contains "$out" "FLOW_MODE=trunk" "usa la puerta trunk (mismos gates, mismo push directo)"
out="$(puerta trunk-merge-commit trunk 0 0; echo)"
( set -euo pipefail; WS="$WS"; TASK=T1; REPO=svc; PRECHECK=0; LANG_ONLY=0; CI_MODE=0
  DMOUT="trunk"; DMRC=0; python3() { printf '%b' "$DMOUT"; }
  sed "s/{{FLOW}}/trunk-merge-commit/" "$WS/puerta-raw.sh" > "$WS/puerta-mc.sh"
  . "$WS/puerta-mc.sh"; echo "LAND_MERGE=$LAND_MERGE" ) 2>&1 | grep -q "LAND_MERGE=1" \
  && pass "y enciende el modo merge commit" || fail "flow trunk-merge-commit no encendió LAND_MERGE"

# Un flow que NO se implementa sigue siendo rojo, y el mensaje nombra los TRES.
out="$(puerta gitflow trunk 2>&1)" || true
assert_contains "$out" "trunk-merge-commit" "el rechazo de un flow ajeno nombra los tres implementados"

echo
echo "── #67: el flow vigente es el del answers, no el sellado en la instalación"
# El bug: {{FLOW}} se sustituía UNA vez al instalar y ship.sh no volvía a abrir
# el archivo, así que editar harness-answers.yaml no cambiaba cómo aterrizaba el
# ship (y el rechazo decía "harness-answers.yaml declara..." nombrando un
# archivo que nunca había leído). El que pedía merge commit para poder revertir
# de un tirón recibía un fast-forward sin una línea de aviso.
PUERTA_BLK="$WS/puerta-ans.sh"
puerta_ans() {  # puerta_ans <sellado> <caso> <answers|SIN-ANSWERS> → salida + exit
  PUERTA_ANS="$WS/ans-$2"; rm -rf "$PUERTA_ANS"; mkdir -p "$PUERTA_ANS"
  # %b y no %s: los casos multilínea llegan con \n (un answers de verdad tiene
  # más de una clave, y la anidada solo se puede probar con varias líneas).
  [ "$3" = "SIN-ANSWERS" ] || printf '%b\n' "$3" > "$PUERTA_ANS/harness-answers.yaml"
  sed "s/{{FLOW}}/$1/" "$WS/puerta-raw.sh" > "$PUERTA_BLK"
  ( set -euo pipefail
    WS="$PUERTA_ANS"; TASK=T1; REPO=svc
    PRECHECK=0; LANG_ONLY=0; CI_MODE=0
    DMOUT="flow"; DMRC=0
    python3() { printf '%b' "$DMOUT"; return "$DMRC"; }
    . "$PUERTA_BLK"
    echo "FLOW_MODE=$FLOW_MODE LAND_MERGE=$LAND_MERGE FUENTE=$FLOW_SRC" ) 2>&1
}

# EL CASO DEL CAMPO: el humano editó el answers a trunk-merge-commit y el
# ship.sh instalado sigue sellado en trunk. Antes: fast-forward en silencio.
out="$(puerta_ans trunk edita 'flow: trunk-merge-commit')"; rc=$?
assert_eq 0 "$rc" "answers editado a trunk-merge-commit: la puerta se resuelve"
assert_contains "$out" "LAND_MERGE=1" "y aterriza con merge commit, aunque el sellado diga trunk"
assert_contains "$out" "FUENTE=harness-answers.yaml" "porque el valor salió del archivo, no del literal"

out="$(puerta_ans trunk aprs 'flow: prs')"
assert_contains "$out" "FLOW_MODE=prs" "y del otro lado igual: answers prs sobre sellado trunk"

# El sellado sigue siendo el respaldo: sin archivo, o sin la clave, no cambia
# nada de lo que las instancias de hoy ya hacen.
out="$(puerta_ans trunk-merge-commit sinarch SIN-ANSWERS)"
assert_contains "$out" "LAND_MERGE=1" "sin harness-answers.yaml: manda el valor sellado"
assert_contains "$out" "FUENTE=scripts/ship.sh" "y lo dice sin nombrar un archivo que no abrió"
out="$(puerta_ans trunk-merge-commit sinclave 'project:\n  name: x')"
assert_contains "$out" "LAND_MERGE=1" "answers sin la clave flow: manda el sellado"
# Un placeholder crudo en el answers es una instancia generada a medias, no una
# respuesta: el sellado es mejor dato que un literal sin sustituir.
out="$(puerta_ans prs placeholder 'flow: {{FLOW}}')"
assert_contains "$out" "FLOW_MODE=prs" "placeholder sin sustituir en el answers: manda el sellado"

# El parser del knob: comillas, comentario al margen, y NADA de claves anidadas
# homónimas (deploy.<repo>.flow no es el flujo del workspace).
out="$(puerta_ans trunk comillas 'flow: "trunk-merge-commit"   # lo edité yo')"
assert_contains "$out" "LAND_MERGE=1" "el valor se lee con comillas y comentario al margen"
out="$(puerta_ans trunk anidada 'deploy:\n  svc:\n    flow: prs')"
assert_contains "$out" "FLOW_MODE=trunk" "una clave flow anidada NO se confunde con el knob de primer nivel"

# Y el rechazo nombra la fuente REAL, que es lo que hacía imposible depurarlo.
out="$(puerta_ans trunk ajeno 'flow: gitflow')"; rc=$?
assert_eq 7 "$rc" "un flow ajeno en el answers frena el ship (exit 7)"
assert_contains "$out" "harness-answers.yaml declara flow: gitflow" "y el rechazo nombra el archivo que SÍ leyó"
assert_contains "$out" "se relee en cada corrida" "con la remediación correcta: editar el answers alcanza"
out="$(puerta_ans gitflow sellado SIN-ANSWERS)"; rc=$?
assert_eq 7 "$rc" "un flow ajeno sellado también frena"
assert_contains "$out" "el valor sellado al instalar) declara flow: gitflow" \
  "y ahí el mensaje NO le echa la culpa a un archivo que no existe"

echo
echo "── #58: el merge commit se arma sin tocar el árbol, y es revertible de un tirón"
# Caso de campo: un humano autoriza un cambio grande y pide poder deshacerlo. Con
# fast-forward hay que conocer el rango exacto; con merge commit es un comando.
# Lo que se prueba acá es la PROPIEDAD que el humano compró: `git revert -m 1`
# deshace el trabajo de la tarea y deja el trunk como estaba.
MC="$WS/mergecommit"; mkdir -p "$MC"; ( cd "$MC"
  git init -q .; git config user.email t@t; git config user.name t
  echo base > app.txt; git add -A; git commit -qm base
  git update-ref refs/remotes/origin/main HEAD
  BASE_TREE="$(git rev-parse 'HEAD^{tree}')"
  echo tarea >> app.txt; echo nuevo > feature.txt; git add -A; git commit -qm "trabajo de la tarea"
  # el mismo plumbing que usa ship.sh: árbol de HEAD, primer padre el trunk
  m="$(git commit-tree "$(git rev-parse 'HEAD^{tree}')" \
        -p "$(git rev-parse origin/main)" -p "$(git rev-parse HEAD)" -m "merge: T1 en svc")"
  # reset --hard y no checkout: HEAD ya está en esa rama, así que un checkout
  # no re-sincroniza índice ni árbol y el revert operaría sobre otro estado.
  git update-ref "refs/heads/$(git rev-parse --abbrev-ref HEAD)" "$m"
  git reset -q --hard "$m"
  echo "PADRES:[$(git rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')]"
  echo "CONTENIDO:[$(cat app.txt | tr '\n' ' ')]"
  git revert -m 1 --no-edit HEAD >/dev/null   # git revert NO acepta -q
  echo "TRAS_REVERT:[$(git rev-parse 'HEAD^{tree}')]"
  echo "ESPERADO:[$BASE_TREE]"
  echo "FEATURE_TRAS_REVERT:[$([ -f feature.txt ] && echo si || echo no)]" ) > "$WS/mc.out" 2>&1
mcout="$(cat "$WS/mc.out")"
assert_contains "$mcout" "PADRES:[3]" "el commit que aterriza tiene DOS padres (es un merge, no un fast-forward)"
assert_contains "$mcout" "CONTENIDO:[base tarea ]" "y su árbol es el resultado de la tarea, no una fusión inventada"
tras="$(printf '%s' "$mcout" | sed -n 's/^TRAS_REVERT:\[\(.*\)\]$/\1/p')"
esp="$(printf '%s' "$mcout" | sed -n 's/^ESPERADO:\[\(.*\)\]$/\1/p')"
assert_eq "$esp" "$tras" "git revert -m 1 devuelve el árbol EXACTO de antes de la tarea"
assert_contains "$mcout" "FEATURE_TRAS_REVERT:[no]" "incluidos los archivos que la tarea agregó"

echo
echo "── #68: el merge que aterriza declara el bump que trae (o dice que no trae)"
# Caso de campo: el merge decía "merge: <task> en <repo>", que no matchea ningún
# prefijo de conventional commits. El CI condiciona el build al bump semver del
# commit que llega a la trunk, así que salió bump_type=none, build SKIPPED: main
# avanzó con el cambio y NO se construyó ni se desplegó nada. El fast-forward no
# tenía el problema porque el CI ve los commits de la rama con sus prefijos; el
# merge los esconde detrás de UN mensaje, y ese mensaje tiene que decir lo mismo.
{ extract merge_bump_type; extract merge_commit_message; } > "$WS/mergemsg.sh"
grep -q 'BREAKING CHANGE' "$WS/mergemsg.sh" || { echo "no pude extraer merge_bump_type"; exit 1; }
grep -q 'Task: %s' "$WS/mergemsg.sh" || { echo "no pude extraer merge_commit_message"; exit 1; }

BR="$WS/bump"; mkdir -p "$BR"
( cd "$BR"; git init -q .; git config user.email t@t; git config user.name t
  echo base > app.txt; git add -A; git commit -qm "chore: base"
  git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
bump() {  # bump <asunto>... → el tipo que declararía el merge de esos commits
  ( set -euo pipefail; cd "$BR"
    git checkout -q -B probe origin/main
    for s in "$@"; do echo "$s" >> app.txt; git commit -qam "$s"; done
    . "$WS/mergemsg.sh"
    merge_bump_type "origin/main..HEAD" ) 2>&1
}
assert_eq "fix" "$(bump "chore: mueve cosas" "fix(api): arregla el 500")" \
  "un fix entre chores: el merge declara fix (patch), que es lo que trae"
assert_eq "feat" "$(bump "fix: parche" "feat: endpoint nuevo" "docs: notas")" \
  "el tipo más FUERTE gana, no el del último commit (el CI vería el feat)"
assert_eq "feat!" "$(bump "feat: endpoint" "refactor!: cambia el contrato")" \
  "un breaking con ! no se pierde en el merge: viaja como feat!"
assert_eq "feat!" "$(bump "$(printf 'perf: mas rapido\n\nBREAKING CHANGE: cambia el contrato')")" \
  "y el breaking declarado en el CUERPO tampoco (las dos grafías cuentan)"
assert_eq "chore" "$(bump "chore: sube dependencia")" \
  "un chore-only sigue siendo chore: NO se inventa un fix que dispararía un release"
assert_eq "" "$(bump "arregla el bug del login" "otro arreglo")" \
  "sin un solo commit conventional NO hay tipo que declarar (vacío, no inventado)"

# El mensaje: asunto conventional cuando hay bump, `merge:` cuando no, y el
# trailer Task: en los dos (es lo que ata el commit a la tarea).
( set -euo pipefail; . "$WS/mergemsg.sh"
  merge_commit_message "feat!" "AUTO-1" "svc" "main" ) > "$WS/msg-con.txt" 2>&1
( set -euo pipefail; . "$WS/mergemsg.sh"
  merge_commit_message "" "AUTO-1" "svc" "main" ) > "$WS/msg-sin.txt" 2>&1
assert_eq "feat!: AUTO-1 en svc (merge)" "$(head -1 "$WS/msg-con.txt")" \
  "con bump, el asunto es conventional y sigue diciendo que es un merge"
assert_eq "merge: AUTO-1 en svc" "$(head -1 "$WS/msg-sin.txt")" \
  "sin bump, el asunto no finge uno"
assert_contains "$(cat "$WS/msg-con.txt")" "Task: AUTO-1" "el trailer Task: sobrevive al cambio de asunto"
assert_contains "$(cat "$WS/msg-sin.txt")" "Task: AUTO-1" "en las dos formas del mensaje"
assert_contains "$(cat "$WS/msg-con.txt")" "revert -m 1" "y el cuerpo dice cómo deshacerlo (la razón del modo)"

# E2E con el plumbing real: el merge que ship.sh arma con este mensaje tiene que
# seguir siendo revertible de un tirón. Un asunto conventional no puede costar la
# propiedad que #58 compró.
( set -euo pipefail; cd "$BR"
  git checkout -q -B e2e origin/main
  BASE_TREE="$(git rev-parse 'HEAD^{tree}')"
  echo tarea >> app.txt; git commit -qam "feat(api): el trabajo de la tarea"
  . "$WS/mergemsg.sh"
  t="$(merge_bump_type "origin/main..HEAD")"
  m="$(git commit-tree "$(git rev-parse 'HEAD^{tree}')" \
        -p "$(git rev-parse origin/main)" -p "$(git rev-parse HEAD)" \
        -m "$(merge_commit_message "$t" T1 svc main)")"
  git update-ref refs/heads/e2e "$m"; git reset -q --hard "$m"
  echo "ASUNTO:[$(git log -1 --format=%s)]"
  echo "PADRES:[$(git rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')]"
  git revert -m 1 --no-edit HEAD >/dev/null
  echo "REVERT_OK:[$([ "$(git rev-parse 'HEAD^{tree}')" = "$BASE_TREE" ] && echo si || echo no)]"
) > "$WS/e2e.out" 2>&1
e2e="$(cat "$WS/e2e.out")"
assert_contains "$e2e" "ASUNTO:[feat: T1 en svc (merge)]" "el commit que aterriza de verdad lleva el prefijo (el CI ya puede bumpear)"
assert_contains "$e2e" "PADRES:[3]" "y sigue siendo un merge de dos padres"
assert_contains "$e2e" "REVERT_OK:[si]" "y git revert -m 1 sigue devolviendo el árbol de antes de la tarea"

# (d) sin campo delivery (el subcomando contesta 'flow') → conducta de HOY
out="$(puerta prs flow)"
assert_contains "$out" "FLOW_MODE=prs" "sin delivery declarado: manda el flow prs del workspace"
assert_not_contains "$out" "entrega declarada" "y no anuncia una entrega que nadie declaró"
out="$(puerta trunk flow)"
assert_contains "$out" "FLOW_MODE=trunk" "sin delivery declarado: manda el flow trunk (compat con tareas viejas y /quick)"

# ...y la entrega que coincide con el flow no inventa un override que anunciar
out="$(puerta prs prs)"
assert_contains "$out" "FLOW_MODE=prs" "delivery prs con flow prs: misma puerta"
assert_not_contains "$out" "manda sobre" "sin anunciar un override que no ocurrió"

# (e) delivery-mode ilegible → tercer estado honesto, NUNCA el flow del workspace
out="$(puerta prs "harness-policy.py: error: argument action: invalid choice: 'delivery-mode'" 3)"; rc=$?
assert_eq 2 "$rc" "delivery-mode que no responde: ship se niega (exit 2)"
assert_contains "$out" "no pude leer la entrega declarada" "y nombra el motivo real"
assert_contains "$out" "invalid choice" "citando lo que contestó el subcomando"
assert_contains "$out" "la instancia está atrasada" "con SU remediación (actualizar la instancia)"
assert_not_contains "$out" "FLOW_MODE=" "y NO cae callado al flow del workspace"
assert_not_contains "$out" "delivery: review" "sin disfrazarse del rechazo de review (otra causa, otro mensaje)"

# salida vacía con exit 0 tampoco es una respuesta: sin dato no se publica
out="$(puerta prs "" 0)"; rc=$?
assert_eq 2 "$rc" "delivery-mode mudo (exit 0 sin salida): se niega igual"
assert_contains "$out" "no imprimió nada" "y dice exactamente qué pasó"

# una respuesta que no está en el vocabulario no se aproxima: se declara ilegible
out="$(puerta prs "staging" 0)"; rc=$?
assert_eq 2 "$rc" "modo desconocido ('staging'): se niega en vez de adivinar la puerta"

# (5) --precheck NO cambia: no publica, así que la entrega no le concierne.
# Con el subcomando ROTO (rc 3), un precheck que preguntara moriría acá.
out="$(puerta prs "invalid choice: 'delivery-mode'" 3 1)"; rc=$?
assert_eq 0 "$rc" "--precheck con delivery-mode roto: sigue como siempre"
assert_contains "$out" "FLOW_MODE=prs" "el precheck resuelve por el flow del workspace"
assert_not_contains "$out" "no pude leer la entrega" "y ni siquiera le pregunta a la entrega"

echo
echo "── delivery=review: el ship se niega ANTES del lock, y no es un rojo"
# End-to-end contra el script REAL instanciado: lo que importa no es solo el
# código de salida, es DÓNDE se niega. Si la negación viviera después del
# preflight o del lock, un /smart dejaría el repo serializado y la historia
# rebaseada por una tarea que pidió no publicar nada.
DWS="$WS/dws"
mkdir -p "$DWS/scripts" "$DWS/tasks/T1" "$DWS/repos" "$DWS/worktrees/T1"
sed 's/{{LOOP_BUDGET}}/3/g; s/{{FLOW}}/trunk/g' "$TMPL" > "$DWS/scripts/ship.sh"
# harness-policy.py de palo que implementa el CONTRATO de delivery-mode (una
# línea con review|prs|trunk|flow). El productor real es del carril D1; lo que
# este test mide es el consumidor.
cat > "$DWS/scripts/harness-policy.py" <<'PY'
import json, os, sys
argv = sys.argv[1:]
if "delivery-mode" not in argv:
    sys.exit(0)
p = os.path.join(argv[argv.index("delivery-mode") + 1], "state.json")
try:
    d = json.load(open(p)).get("delivery", "")
except Exception as e:                       # noqa: BLE001
    print("POLICY-DELIVERY-002: no pude leer %s: %s" % (p, e))
    sys.exit(3)
print(d if d else "flow")
PY
printf '{"lane":"full","phase":"review","delivery":"review"}' > "$DWS/tasks/T1/state.json"
mk_repo "$DWS/repos/svc"
cp -R "$DWS/repos/svc" "$DWS/worktrees/T1/svc"
( cd "$DWS/worktrees/T1/svc"; echo nuevo > feature.go; git add .; git commit -qm "feat

Task: T1" )
cd "$WS"
out="$( cd "$DWS" && bash scripts/ship.sh T1 svc 2>&1 )"; rc=$?
assert_eq 8 "$rc" "delivery review: exit 8 propio (no 3: no es un gate rojo)"
assert_contains "$out" "SIN publicación (delivery: review)" "nombra la entrega declarada"
assert_contains "$out" "No es un rojo" "y dice que esto es lo pedido, no una falla"
assert_contains "$out" "harness-policy.py delivery tasks/T1 --to prs --actor humano" \
  "con la remediación EXACTA de promoción (transición auditable, no una frase de chat)"
assert_contains "$out" "scripts/ship.sh T1 svc" "y el comando para re-correr después"
assert_no_file "$DWS/locks/svc.lock.d" "se niega SIN tomar el lock del repo"
assert_not_contains "$out" "══ ship svc" "jamás entra al loop de ship (ni fetch, ni rebase, ni push)"
assert_not_contains "$out" "ship.sh implementa tres" "y NO se confunde con el rechazo de flow no implementado (exit 7)"

# Y el ORDEN es estructural, no una casualidad de este fixture: la consulta de
# la entrega precede al lock y al loop de ship en el archivo. Mismo método que
# usa el preflight más arriba, porque la propiedad es la misma (no retener nada
# que después haya que soltar).
rd_line="$(grep -n '^  resolve_delivery$' "$TMPL" | head -1 | cut -d: -f1)"
lk_line="$(grep -n '^acquire_lock$' "$TMPL" | head -1 | cut -d: -f1)"
[ -n "$rd_line" ] && [ -n "$lk_line" ] && [ "$rd_line" -lt "$lk_line" ] \
  && pass "resolve_delivery se invoca ANTES de acquire_lock (estructural)" \
  || fail "la consulta de la entrega no precede al lock (delivery=$rd_line lock=$lk_line)"
# ...y DESPUÉS de la puerta de la instancia: un ship mal invocado (el repo de la
# instancia) tiene que seguir recibiendo SU error, no uno sobre la entrega.
is_line="$(grep -n 'scripts/instance-ship.sh' "$TMPL" | head -1 | cut -d: -f1)"
[ -n "$is_line" ] && [ "$is_line" -lt "$rd_line" ] \
  && pass "y DESPUÉS del '¿existe el repo?' (el error real no queda tapado)" \
  || fail "la entrega se consulta antes de saber si el repo existe (repo=$is_line delivery=$rd_line)"

# La otra mitad: el MISMO workspace con la entrega promovida a trunk deja de
# negarse acá y sigue su camino. Sin esto, un ship que se negara SIEMPRE pasaría
# la mitad de arriba.
printf '{"lane":"full","phase":"review","delivery":"trunk"}' > "$DWS/tasks/T1/state.json"
out="$( cd "$DWS" && bash scripts/ship.sh T1 svc 2>&1 )"; rc=$?
assert_not_contains "$out" "delivery: review" "promovida a trunk: ya no se niega por entrega"
[ "$rc" -ne 8 ] && pass "promovida a trunk: el ship avanza (falla más adelante por lo suyo, no por la entrega)" \
  || fail "con delivery trunk sigue saliendo 8"

echo
echo "── contra el harness-policy.py REAL: el contrato de delivery-mode, entero"
# Mismo motivo que el caso de lane-limits contra el policy real: los casos de
# arriba miden el DIENTE (qué hace ship.sh con cada respuesta) con un productor
# de palo. Si el contrato cambia de forma, esto muerde antes que producción.
cp "$ROOT/templates/scripts/harness-policy.py" "$DWS/scripts/harness-policy.py"

printf '{"schema":1,"lane":"full","phase":"review","delivery":"review"}' > "$DWS/tasks/T1/state.json"
out="$( cd "$DWS" && bash scripts/ship.sh T1 svc 2>&1 )"; rc=$?
assert_eq 8 "$rc" "productor real + delivery review: exit 8"
assert_contains "$out" "SIN publicación (delivery: review)" "y el mismo mensaje de dos partes"

# Sin campo delivery: la tarea es de antes de esta decisión (o de /quick) y
# ship.sh no cambia de conducta. Falla más adelante por lo suyo (no hay
# veredicto en este fixture), que es exactamente lo de siempre.
printf '{"schema":1,"lane":"full","phase":"review"}' > "$DWS/tasks/T1/state.json"
out="$( cd "$DWS" && bash scripts/ship.sh T1 svc 2>&1 )"; rc=$?
assert_not_contains "$out" "no pude leer la entrega declarada" \
  "productor real sin campo delivery: NO es un ilegible (es 'flow', compat)"
[ "$rc" -ne 8 ] && pass "sin campo delivery: no se niega por entrega (conducta de hoy)" \
  || fail "una tarea sin delivery recibió el rechazo de review"

# state.json editado a mano con una entrega fuera del catálogo: el productor
# sale 3 y ship.sh lo trata como el tercer estado, no como 'flow'.
printf '{"schema":1,"lane":"full","phase":"review","delivery":"staging"}' > "$DWS/tasks/T1/state.json"
out="$( cd "$DWS" && bash scripts/ship.sh T1 svc 2>&1 )"; rc=$?
assert_eq 2 "$rc" "productor real + entrega fuera del catálogo: ship se niega (exit 2)"
assert_contains "$out" "no pude leer la entrega declarada" "con el rechazo honesto"
assert_contains "$out" "POLICY-DELIVERY-001" "citando el código real del productor"

echo
echo "── el rojo que no es del código: disco lleno"
# Caso de campo: 3 de 8 corridas de la MISMA suite rojas con el disco al 100 por
# ciento (56K libres de 193G); dos ni colectaron el archivo de test porque los
# workers murieron por ENOSPC. Con 29G libres, 16 de 16 verdes. El daño no es la
# corrida perdida: es que ese rojo se lee igual que un defecto y manda al agente
# a arreglar lo que no está roto.
extract gate_espacio_en_disco > "$WS/disco.sh"
grep -q 'ENOSPC' "$WS/disco.sh" || fail "no pude extraer gate_espacio_en_disco del template"

corre_disco() {  # corre_disco <kb-libres-simulados> <min-gb> → salida, con RC=<n>
  # El gate hace `exit 3`, así que el rc se captura del subshell entero y se
  # anexa a la salida: un `echo` después del exit nunca correría.
  local salida rc
  salida="$( WS="$WS"; WT="$WS"; REPO=svc
    HARNESS_MIN_FREE_GB="$2"
    gate() { echo "── gate: $1 ──"; }
    emit() { :; }
    # df stubeado: lo que se mide es la DECISIÓN, no el df del host (que no se
    # puede llenar en un test). El formato imita el -P real.
    KB="$1"
    df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 100 100 %s 100%% /\n' "$KB"; }
    # shellcheck disable=SC1090
    . "$WS/disco.sh"
    gate_espacio_en_disco 2>&1 )"; rc=$?
  printf '%s\nRC=%s\n' "$salida" "$rc"
}

out="$(corre_disco 56 2)"          # 56K libres: el caso de campo literal
assert_contains "$out" "RC=3" "con el disco lleno el gate se NIEGA a correr (fail-closed)"
assert_contains "$out" "NO ES TU CÓDIGO, ES EL DISCO" "y lo dice con todas las letras"
assert_contains "$out" "ENOSPC" "explicando por qué el rojo no significaría nada"
assert_contains "$out" "worktree-task.sh --rm" "con la remediación ejecutable"
assert_contains "$out" "HARNESS_MIN_FREE_GB=0" "y el escape declarado para quien insista"

out="$(corre_disco 31457280 2)"    # 30G libres
assert_contains "$out" "RC=0" "con espacio de sobra no molesta"
assert_not_contains "$out" "DISCO" "y ni siquiera imprime el gate"

# El umbral es configurable: una suite de Go con cachés y una de docs no
# necesitan lo mismo, y cablear un número sería el eje que no se despacha.
out="$(corre_disco 5242880 2)"     # 5G libres, mínimo 2G
assert_contains "$out" "RC=0" "5G con mínimo 2G: pasa"
out="$(corre_disco 5242880 10)"    # 5G libres, mínimo 10G
assert_contains "$out" "RC=3" "5G con mínimo 10G: se niega (el umbral manda)"
out="$(corre_disco 56 0)"
assert_contains "$out" "RC=0" "HARNESS_MIN_FREE_GB=0 apaga el gate explícitamente"

# UN GATE QUE NO PUEDE MEDIR NO REPORTA ROJO: la ley de la casa. Un df que no
# devuelve un número es ceguera, y la ceguera no es un defecto del código.
salida_ceguera="$( WS="$WS"; WT="$WS"; REPO=svc; HARNESS_MIN_FREE_GB=2
        gate() { echo "── gate: $1 ──"; }; emit() { :; }
        df() { echo "df: ilegible"; return 1; }
        . "$WS/disco.sh"; gate_espacio_en_disco 2>&1 )"; rc_ceguera=$?
assert_eq 0 "$rc_ceguera" "df ilegible: NO inventa un rojo (se ausenta)"
assert_not_contains "$salida_ceguera" "DISCO" "y no imprime un veredicto que no puede sostener"

# MANDA EL MÁS APRETADO DE LOS DOS. El caso de campo fue el disco RAÍZ, y los
# workers de test escriben su spill en TMPDIR, que muy seguido vive en otro
# filesystem que el worktree. Mirar solo el worktree dejaba pasar el escenario
# exacto del reporte: worktree holgado, raíz llena, suite roja por ENOSPC.
cat > "$WS/dos-fs.sh" <<'STUB'
# df stubeado con DOS sistemas de archivos: el worktree holgado y el de
# temporales al 100 por ciento. La invocación real es `df -Pk <punto>`, así que
# el punto de montaje es $2 (no $3: los flags van juntos en un solo argumento).
df() {
  if [ "$2" = "/tmp-simulado" ]; then
    printf 'F B U Avail C M\n/dev/root 100 100 56 100%% /\n'
  else
    printf 'F B U Avail C M\n/dev/wt 100 1 31457280 1%% /wt\n'
  fi
}
STUB
salida_dos="$( WS="$WS"; WT="$WS"; REPO=svc; HARNESS_MIN_FREE_GB=2
        TMPDIR=/tmp-simulado
        gate() { echo "── gate: $1 ──"; }; emit() { :; }
        . "$WS/dos-fs.sh"
        . "$WS/disco.sh"; gate_espacio_en_disco 2>&1 )"; rc_dos=$?
assert_eq 3 "$rc_dos" "worktree holgado pero TMPDIR lleno: igual se niega (manda el peor)"
assert_contains "$salida_dos" "NO ES TU CÓDIGO" "y con el mismo diagnóstico"

echo
echo "── semgrep: el ignore por defecto escondía los tests, y el gate salía verde"
# Caso de campo: semgrep trae un .semgrepignore propio que excluye *_test.go.
# Como ship.sh escanea el DIRECTORIO ('.'), las ramas de las reglas que apuntan
# a tests NUNCA se evaluaban: todo el workspace mostraba 0 matches de
# "no sleep en tests" para Go, y eso se leyó como ausencia de deuda cuando era
# un gate ciego. Un falso verde es peor que un rojo: nadie lo investiga.
extract semgrep_test_globs > "$WS/sgglobs.sh"
grep -q 'include:' "$WS/sgglobs.sh" || fail "no pude extraer semgrep_test_globs del template"
. "$WS/sgglobs.sh"

# Los globs salen de las REGLAS, no de una lista cableada en el gate: si mañana
# una regla mira *.spec.rb, la segunda pasada la sigue sola.
globs="$(semgrep_test_globs "$ROOT/templates/semgrep-rules.yaml.tmpl" | tr '\n' ' ')"
assert_contains "$globs" "*_test.go" "los globs salen de las reglas reales (Go)"
assert_contains "$globs" "test_*.py" "y de las demás ramas declaradas (Python)"
assert_contains "$globs" "*.spec.ts" "sin una lista cableada que envejezca en el gate"
assert_eq "" "$(semgrep_test_globs "$WS/no-existe.yaml")" \
  "sin archivo de reglas no imprime nada (la segunda pasada no corre)"
printf 'rules:\n  - id: x\n    pattern: foo(...)\n' > "$WS/sinincludes.yaml"
assert_eq "" "$(semgrep_test_globs "$WS/sinincludes.yaml")" \
  "reglas sin include: tampoco (un gate sin qué mirar se ausenta, no inventa rojo)"

if command -v semgrep >/dev/null 2>&1; then
  # La prueba que importa: MISMO archivo, dos formas de invocar, dos resultados.
  SG="$WS/sg"; mkdir -p "$SG/repo"
  cat > "$SG/rules.yaml" <<'YAML'
rules:
  - id: no-sleep-en-tests
    languages: [go]
    severity: ERROR
    message: sleep en test
    pattern: time.Sleep(...)
    paths:
      include: ["*_test.go"]
YAML
  cat > "$SG/repo/app_test.go" <<'GO'
package app
import ("testing"; "time")
func TestX(t *testing.T) { time.Sleep(time.Second) }
GO
  ( cd "$SG/repo" && git init -q . && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
  dir_out="$( cd "$SG/repo" && semgrep scan --config "$SG/rules.yaml" --error --quiet . 2>&1 )"
  assert_not_contains "$dir_out" "sleep en test" \
    "la premisa del bug se reproduce: el escaneo de directorio NO ve el _test.go"
  tgt_out="$( cd "$SG/repo" && semgrep scan --config "$SG/rules.yaml" --error --quiet app_test.go 2>&1 )"
  assert_contains "$tgt_out" "sleep en test" \
    "y como target EXPLÍCITO sí lo ve (que es lo que hace la segunda pasada)"
  # Y el gate tiene que encontrar ese archivo por sí solo, desde los globs.
  found="$( cd "$SG/repo" && for g in $(semgrep_test_globs "$SG/rules.yaml"); do
              git ls-files -- "$g"; done )"
  assert_eq "app_test.go" "$found" "el gate resuelve el target desde los globs de la regla"

  # ── EL RATCHET: encender un gate ciego no puede murar el repo ──────
  # Del otro lado de un gate que estuvo ciego hay deuda que nadie pudo ver (el
  # propio reporte lo dice: "era un falso verde, no una ausencia de deuda").
  # Bloquear todo pondría en rojo cada ship hasta que alguien limpie sleeps que
  # no escribió: la misma trampa que el ratchet de buf lint existe para evitar.
  ( cd "$SG/repo" && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
  # un archivo de test NUEVO con la violación: ese SÍ es tuyo
  cat > "$SG/repo/nuevo_test.go" <<'GO'
package app
import ("testing"; "time")
func TestY(t *testing.T) { time.Sleep(time.Second) }
GO
  ( cd "$SG/repo" && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm nuevo ) >/dev/null 2>&1
  tocados="$( cd "$SG/repo" && for g in $(semgrep_test_globs "$SG/rules.yaml"); do
                git diff --name-only --diff-filter=d "origin/main...HEAD" -- "$g"; done )"
  assert_eq "nuevo_test.go" "$tocados" \
    "el bloqueo mira SOLO los tests que este cambio tocó (el viejo no es tuyo)"
  todos="$( cd "$SG/repo" && for g in $(semgrep_test_globs "$SG/rules.yaml"); do
              git ls-files -- "$g"; done | sort | tr '\n' ' ' )"
  assert_contains "$todos" "app_test.go" "y el aviso sí cuenta la deuda preexistente"
  assert_contains "$todos" "nuevo_test.go" "junto con la nueva"
else
  echo "  ! semgrep no instalado: los dos casos end-to-end no corrieron."
  echo "    NO es un verde: la lógica de globs sí se probó arriba, pero la"
  echo "    diferencia directorio-vs-target (que es el bug) quedó sin ejercitar."
fi

echo
echo "── request_ship_phase: quien mueve la fase es el PUSH, y se ejecuta de verdad"
# Tres bugs de campo distintos nacieron de que la transicion review->ship la
# pedia el orquestador: si se adelantaba, los repos que faltaban se quedaban sin
# camino (validate-ship exige phase=review y no hay arista ship->review).
# La solucion fue mover el dueno: la registra ship.sh tras cada push. Pero la
# funcion solo estaba cubierta por asserts de PRESENCIA DE TEXTO en el template,
# o sea que nadie la ejecutaba: podia romperse entera con la suite en verde.
# Aca se extrae del template y se corre contra el harness-policy.py REAL.
RSP_FN="$WS/rsp.sh"
extract request_ship_phase > "$RSP_FN"
grep -q 'POLICY-SHIP-004' "$RSP_FN" || fail "no pude extraer request_ship_phase del template"

RWS="$WS/rsp-ws"; mkdir -p "$RWS/scripts" "$RWS/tasks/T1"
cp "$ROOT/templates/scripts/harness-policy.py" "$RWS/scripts/"
cat > "$RWS/harness-policy.json" <<'JSON'
{"schema":1,
 "workflow":{"initial_phase":"intake",
   "phase_order":["intake","rfc","implement","review","ship","deploy","archive"],
   "allowed_transitions":{"intake":["rfc"],"rfc":["implement"],"implement":["review"],
     "review":["implement","ship"],"ship":["deploy"],"deploy":["archive"],"archive":[],"blocked":[]},
   "lanes":{"express":{},"standard":{},"full":{}},
   "lane_escalation":["express","standard","full"],
   "allowed_pause_reasons":["enrichment_questions"]},
 "limits":{"max_review_rounds":3},
 "ship":{"require_independent_review":true}}
JSON
cat > "$RWS/tasks/T1/state.json" <<'JSON'
{"schema":1,"task_id":"T1","phase":"review","lane":"full","review_rounds":1,
 "budget_usd":null,"spent_usd":0.0,"repos":["svc","api"],
 "history":[{"from":"implement","to":"review","actor":"orchestrator"}]}
JSON
mk_verdict_rsp() {  # mk_verdict_rsp <repo>
  jq -n --arg r "$1" '{schema:1, task_id:"T1", repo:$r, commit:"aaa", reviewer:"rev",
    implementation_agents:["impl"], verdict:"pass", qa:"pass", evidence:[],
    blocking:[], non_blocking:[], docs_updated:true, compliance:[],
    requirements_uncovered:0, snapshots_updated_justified:true}' > "$RWS/tasks/T1/verdict-$1.json"
}
corre_rsp() { ( WS="$RWS"; TASK=T1; . "$RSP_FN"; request_ship_phase 2>&1 ); }

# (a) faltan repos por shippear: NO avanza, y lo dice como lo correcto
mk_verdict_rsp svc; mk_verdict_rsp api
printf '%s\n' '{"repo":"svc","sha":"aaa"}' > "$RWS/tasks/T1/ship.log"
out="$(corre_rsp)"; rc=$?
assert_eq 0 "$rc" "faltando un repo: fail-open, el push ya ocurrio (exit 0)"
assert_contains "$out" "sigue en review" "y lo declara como lo CORRECTO, no como un fallo"
assert_eq "review" "$(jq -r .phase "$RWS/tasks/T1/state.json")" "la fase no se movio"

# (b) shippeo el ultimo repo: ahora si avanza, y queda en el estado
printf '%s\n' '{"repo":"api","sha":"bbb"}' >> "$RWS/tasks/T1/ship.log"
out="$(corre_rsp)"; rc=$?
assert_eq 0 "$rc" "con todos los repos shippeados: exit 0"
assert_contains "$out" "la registró el push" "y declara quien movio la fase"
assert_eq "ship" "$(jq -r .phase "$RWS/tasks/T1/state.json")" "la fase avanzo a ship SOLA"

# (c) segunda llamada sobre una fase ya avanzada: no la mueve ni miente
out="$(corre_rsp)"; rc=$?
assert_eq 0 "$rc" "re-invocada sobre una fase ya avanzada: exit 0"
assert_contains "$out" "ya estaba avanzada" "y lo dice en vez de fingir que la movio"

# (d) sin state.json no hay nada que registrar: muda y fail-open
rm -f "$RWS/tasks/T1/state.json"
out="$(corre_rsp)"; rc=$?
assert_eq 0 "$rc" "sin state.json: exit 0 (fail-open, el push ya ocurrio)"
assert_eq "" "$out" "y muda: no inventa un fallo donde no hay tarea"


echo "── delta_seccion: una subsección no apaga la sección (caso de campo)"
# El parser apagaba la sección con CUALQUIER línea que empezara por '#', así que
# un '### SOC-M1' bajo '## MODIFIED Requirements' descartaba todo lo de abajo. La
# remediación que el propio gate imprime pide nombrar cada archivo BAJO ese
# encabezado: el operador hacía exactamente lo que le mandaban y seguía en rojo.
extract delta_seccion > "$WS/delta.sh"
grep -q 'insec' "$WS/delta.sh" || { echo "no pude extraer delta_seccion"; exit 1; }
. "$WS/delta.sh"

cat > "$WS/delta.md" <<'DELTAEOF'
# Delta-spec
prosa suelta que no declara nada

## ADDED Requirements
### SOC-A1
- nuevo_test.go

## MODIFIED Requirements
### SOC-M1
El test cambia de forma: llm_metering_usecase_test.go

### SOC-M2
- admin_finance_test.go

## Notas
no_declarado_test.go
DELTAEOF

out="$(delta_seccion "$WS/delta.md" '(MODIFIED|REMOVED)')"
assert_contains "$out" "llm_metering_usecase_test.go" "el contenido bajo un ### anidado SI cuenta"
assert_contains "$out" "admin_finance_test.go" "y el de la segunda subseccion tambien"
assert_not_contains "$out" "no_declarado_test.go" "pero un ## del mismo nivel SI cierra la seccion"
assert_not_contains "$out" "prosa suelta" "y lo anterior al encabezado nunca entra"

out="$(delta_seccion "$WS/delta.md" 'ADDED')"
assert_contains "$out" "nuevo_test.go" "la misma regla aplica a ADDED"
assert_not_contains "$out" "llm_metering_usecase_test.go" "sin llevarse lo de MODIFIED"

echo "── declara_tests_nuevos: un test nuevo dentro de un archivo que ya existia"
# El gate razonaba por ARCHIVO (solo los AÑADIDOS entraban al alcance), y el caso
# mas comun en la practica es agregar un Test dentro de un archivo viejo: su
# capacidad de morder no se verificaba nunca.
extract declara_tests_nuevos > "$WS/decl.sh"
grep -q 'Benchmark' "$WS/decl.sh" || { echo "no pude extraer declara_tests_nuevos"; exit 1; }
. "$WS/decl.sh"

mk_repo "$WS/declrepo" >/dev/null 2>&1
BASE_REF=main
cat > svc_test.go <<'GOEOF'
package svc
import "testing"
func TestViejo(t *testing.T) {}
GOEOF
git add -A >/dev/null && git commit -qm "test viejo" >/dev/null
git update-ref refs/remotes/origin/main HEAD

cat >> svc_test.go <<'GOEOF'

func TestNuevo(t *testing.T) {}
GOEOF
git add -A >/dev/null && git commit -qm "test nuevo en archivo existente" >/dev/null
if declara_tests_nuevos svc_test.go; then
  pass "ve el Test nuevo dentro de un archivo que ya existia"
else
  fail "ve el Test nuevo dentro de un archivo que ya existia"
fi

# Contra-mitad: sin ella, cualquier retoque a un archivo de test entraria al
# alcance y haria pagar un checkout del arbol base para nada.
git update-ref refs/remotes/origin/main HEAD
cat >> svc_test.go <<'GOEOF'

func ayudante() int { return 7 }
GOEOF
git add -A >/dev/null && git commit -qm "solo un helper" >/dev/null
if declara_tests_nuevos svc_test.go; then
  fail "un helper que no declara test NO entra al alcance"
else
  pass "un helper que no declara test NO entra al alcance"
fi

# ── RENOMBRAR EL TITULO DE UN it() NO ES UN TEST NUEVO (#82/#84) ──────
# Mirar solo las lineas `+` contaba como test NUEVO lo que era un RENAME: el
# diff trae una linea añadida y una eliminada (neto 0 declaraciones) y el grep
# matcheaba igual. Consecuencia medida: el archivo perdia el escape MODIFIED
# del delta-spec y volvia al alcance de gate_test_muerde, que le exige ser rojo
# sobre la base. Un guard de forma NUNCA puede serlo, asi que corregirle un
# typo al titulo de un test no tenia un solo camino verde y el gate empujaba a
# dejar escritos nombres de test que MIENTEN.
mk_repo "$WS/declrename" >/dev/null 2>&1
BASE_REF=main
cat > a.test.ts <<'TSEOF'
describe("x", () => {
  it("sin metrica el contador no se pinta", () => { expect(1).toBe(1) })
  it("con metrica el contador se pinta", () => { expect(1).toBe(1) })
})
TSEOF
git add -A >/dev/null && git commit -qm "dos casos" >/dev/null
git update-ref refs/remotes/origin/main HEAD
sed 's/sin metrica el/sin métrica el/' a.test.ts > a.tmp && mv a.tmp a.test.ts
git add -A >/dev/null && git commit -qm "tilde en el titulo" >/dev/null
if declara_tests_nuevos a.test.ts; then
  fail "renombrar el titulo de un it() NO cuenta como test nuevo (neto 0)"
else
  pass "renombrar el titulo de un it() NO cuenta como test nuevo (neto 0)"
fi

# Contra-mitad, y es la guarda que motivo el conteo (COR-667): un archivo que
# ADEMAS de tocarse agrega un caso de verdad sube el neto y sigue en el alcance.
git update-ref refs/remotes/origin/main HEAD
cat > a.test.ts <<'TSEOF'
describe("x", () => {
  it("sin métrica el contador NO se pinta", () => { expect(1).toBe(1) })
  it("con metrica el contador se pinta", () => { expect(1).toBe(1) })
  it("con metrica en cero el contador se pinta igual", () => { expect(1).toBe(1) })
})
TSEOF
git add -A >/dev/null && git commit -qm "un caso mas, y otro rename" >/dev/null
if declara_tests_nuevos a.test.ts; then
  pass "un caso NUEVO sube el neto y sigue en el alcance (la guarda de COR-667 intacta)"
else
  fail "un caso NUEVO sube el neto y sigue en el alcance (la guarda de COR-667 intacta)"
fi

# Reordenar casos: mismas declaraciones, otro orden. Neto 0, refactor puro.
git update-ref refs/remotes/origin/main HEAD
cat > a.test.ts <<'TSEOF'
describe("x", () => {
  it("con metrica en cero el contador se pinta igual", () => { expect(1).toBe(1) })
  it("con metrica el contador se pinta", () => { expect(1).toBe(1) })
  it("sin métrica el contador NO se pinta", () => { expect(1).toBe(1) })
})
TSEOF
git add -A >/dev/null && git commit -qm "reordenar" >/dev/null
if declara_tests_nuevos a.test.ts; then
  fail "reordenar casos existentes tampoco es declarar tests nuevos"
else
  pass "reordenar casos existentes tampoco es declarar tests nuevos"
fi

t_done
