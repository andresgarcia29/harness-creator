#!/usr/bin/env bash
# test_verdict_scaffold.sh: el esqueleto determinista del veredicto contra el
# código REAL del template. Protege: el reviewer solo pone juicio; los campos
# mecánicos salen de fuentes verificables; los fail-closed distinguen sus
# causas (cero evidencia vs evidencia de otro commit vs violación de roles);
# y el scaffold es idempotente a BYTES.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/tasks/T1/evidence" "$WS/worktrees/T1"
cp "$ROOT/templates/scripts/verdict-scaffold.sh" "$ROOT/templates/scripts/change-id.sh" "$WS/scripts/"

# worktree falso con HEAD real y una BASE contra la cual haya diff: sin
# origin/<trunk> no hay cambio que identificar, y patch_id (la identidad que
# deja sobrevivir el veredicto a un rebase) no se podría calcular.
WT1="$WS/worktrees/T1/atlas"
git init -q -b main "$WT1"
git -C "$WT1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$WT1" update-ref refs/remotes/origin/main HEAD
echo "cambio de la tarea" > "$WT1/feature.txt"
git -C "$WT1" add -A
git -C "$WT1" -c user.email=t@t -c user.name=t commit -q -m x
HEAD="$(git -C "$WT1" rev-parse HEAD)"

mk_ev() {  # mk_ev <id> <runner> <kind> <commit>
  jq -n --arg id "$1" --arg r "$2" --arg k "$3" --arg c "$4" \
    '{schema:1, id:$id, task_id:"T1", repo:"atlas", kind:$k, runner:$r,
      commit:$c, commit_after:$c, exit_code:0, output:("evidence/"+$id+".log"),
      output_sha256:"deadbeef"}' > "$WS/tasks/T1/evidence/$1.json"
}

echo "── verdict-scaffold: el reviewer solo pone juicio"

# 1. cero evidencias → exit 3 con remediación de evidence.py
out="$(bash "$WS/scripts/verdict-scaffold.sh" T1 atlas 2>&1)"; rc=$?
assert_eq 3 "$rc" "sin EVs: exit 3"
assert_contains "$out" "evidence.py run" "sin EVs: remediación exacta"

# 2. evidencia de OTRO commit → exit 3 citando el caso (el más común en campo)
mk_ev EV-TEST-aaaaaaaaaaaa impl-atlas test "0000000000000000000000000000000000000000"
out="$(bash "$WS/scripts/verdict-scaffold.sh" T1 atlas 2>&1)"; rc=$?
assert_eq 3 "$rc" "EVs stale: exit 3"
assert_contains "$out" "OTRO commit" "stale: el mensaje distingue la causa"

# 3. happy path: campos deterministas correctos
mk_ev EV-TEST-bbbbbbbbbbbb impl-atlas test "$HEAD"
mk_ev EV-LINT-cccccccccccc impl-atlas lint "$HEAD"
mk_ev EV-TEST-dddddddddddd qa test "$HEAD"
bash "$WS/scripts/verdict-scaffold.sh" T1 atlas revisor-1 >/dev/null 2>&1 \
  && pass "happy path: exit 0" || fail "happy path falló"
V="$WS/tasks/T1/verdict-atlas.json"
assert_eq "$HEAD" "$(jq -r .commit "$V")" "commit = HEAD del worktree"
assert_eq "PENDING_REVIEWER" "$(jq -r .verdict "$V")" "verdict placeholder inescapable"
assert_eq "-1" "$(jq -r .requirements_uncovered "$V")" "requirements_uncovered=-1 (null pasaría el gate)"
assert_eq "3" "$(jq '.evidence | length' "$V")" "los 3 EVs del commit correcto (el stale fuera; el de qa SÍ es evidencia)"
wait_no=$(jq -r '.implementation_agents | join(",")' "$V")
assert_eq "impl-atlas" "$wait_no" "implementation_agents = runners menos qa/reviewer"

# 4. idempotencia con --force. Lo que esta aserción protege es que la SELECCIÓN
# de evidencia sea determinista (el `sort` de $rows): dos scaffolds del mismo
# estado no pueden elegir distinto. `reviewed_at` es deliberadamente volátil
# (sella CUÁNDO se emitió el juicio, y de ahí sale la ventana de vigencia que
# harness-policy.py usa para reusar un veredicto tras un rebase), así que se
# excluye de la comparación en vez de congelarlo: congelarlo haría que un
# re-scaffold heredara la vigencia del anterior, que es justo lo contrario de
# lo que la ventana quiere medir.
stable() { jq -S 'del(.reviewed_at)' "$1" | shasum | cut -d' ' -f1; }
h1="$(stable "$V")"
bash "$WS/scripts/verdict-scaffold.sh" --force T1 atlas revisor-1 >/dev/null 2>&1
h2="$(stable "$V")"
assert_eq "$h1" "$h2" "re-scaffold con --force: idéntico salvo reviewed_at"
[ -n "$(jq -r '.reviewed_at // ""' "$V")" ] \
  && pass "el scaffold sella reviewed_at (la ventana de vigencia lo necesita)" \
  || fail "sin reviewed_at: policy no puede acotar la reutilización del veredicto"
[ -n "$(jq -r '.patch_id // ""' "$V")" ] \
  && pass "el scaffold sella patch_id (identidad del cambio, sobrevive al rebase)" \
  || fail "sin patch_id: un rebase invalidaría el veredicto entero"

# 5. existente sin --force → exit 3 mostrando el commit previo
out="$(bash "$WS/scripts/verdict-scaffold.sh" T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 3 "$rc" "existente sin --force: exit 3"
assert_contains "$out" "$(printf '%s' "$HEAD" | cut -c1-12)" "muestra el commit del veredicto previo"

# 6. runners solo qa/reviewer → violación de roles detectada temprano
rm -f "$V" "$WS"/tasks/T1/evidence/EV-*bbbb* "$WS"/tasks/T1/evidence/EV-*cccc* "$WS"/tasks/T1/evidence/EV-*aaaa*
out="$(bash "$WS/scripts/verdict-scaffold.sh" T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 3 "$rc" "solo qa como runner: exit 3"
assert_contains "$out" "roles" "explica la política de roles"

echo
echo "── --rebase: el re-review incremental conserva el juicio ajeno al delta"
# El caso de campo: un blocking estrecho obligaba a --force, y --force borraba
# la matriz de compliance ENTERA, incluidos los requirements que el fix ni rozó.

WT="$WS/worktrees/T1/atlas"
gitc() { git -C "$WT" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$WT/tests"
printf 'auth\n' > "$WT/tests/auth.test.js"
printf 'billing\n' > "$WT/tests/billing.test.js"
gitc add -A && gitc commit -q -m "dos suites"
BASE="$(gitc rev-parse HEAD)"

rm -f "$WS"/tasks/T1/evidence/EV-*.json
mk_ev EV-TEST-eeeeeeeeeeee impl-atlas test "$BASE"
bash "$WS/scripts/verdict-scaffold.sh" T1 atlas revisor-1 >/dev/null 2>&1 \
  && pass "rebase: scaffold base verde" || fail "scaffold base falló"

# el reviewer pone su juicio: dos requirements cubiertos, cada uno con su test
jq '.verdict="pass" | .qa="pass" | .requirements_uncovered=0
    | .docs_updated=true | .non_blocking=["nombre de variable pobre"]
    | .compliance=[{id:"AUTH-1",covered:true,tests:["tests/auth.test.js"],note:"cubierto"},
                   {id:"BILL-7",covered:true,tests:["tests/billing.test.js"],note:"cubierto"}]' \
  "$V" > "$V.tmp" && mv "$V.tmp" "$V"

# el implementer corrige SOLO auth y commitea: billing no se tocó
printf 'auth v2\n' > "$WT/tests/auth.test.js"
gitc add -A && gitc commit -q -m "fix del blocking de auth"
NEW="$(gitc rev-parse HEAD)"
mk_ev EV-TEST-ffffffffffff impl-atlas test "$NEW"

out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 0 "$rc" "rebase: exit 0"
assert_eq "$NEW" "$(jq -r .commit "$V")" "rebase: commit = HEAD nuevo"
assert_eq "$BASE" "$(jq -r .rebased_from "$V")" "rebase: deja registro del commit base"

bill="$(jq -c '.compliance[] | select(.id=="BILL-7")' "$V")"
assert_contains "$bill" '"covered":true' "el requirement AJENO al delta conserva covered:true"
assert_contains "$bill" "$BASE" "el arrastrado trae carried_from (auditable)"
assert_not_contains "$bill" "rejudge" "el ajeno al delta NO se manda a re-juzgar"

auth="$(jq -c '.compliance[] | select(.id=="AUTH-1")' "$V")"
assert_contains "$auth" '"covered":false' "el requirement TOCADO por el delta vuelve a pendiente"
assert_contains "$auth" "rejudge" "el tocado dice por qué hay que re-juzgarlo"

assert_eq "PENDING_REVIEWER" "$(jq -r .verdict "$V")" "rebase: el veredicto se re-emite siempre"
assert_eq "pending" "$(jq -r .qa "$V")" "rebase: QA se re-emite siempre (el comportamiento cambió)"
assert_eq "-1" "$(jq -r .requirements_uncovered "$V")" "rebase: requirements_uncovered vuelve al placeholder"
assert_eq "0" "$(jq '.blocking | length' "$V")" "rebase: los blocking se limpian (se están corrigiendo)"
assert_eq "1" "$(jq '.non_blocking | length' "$V")" "rebase: los non_blocking se conservan (son notas)"
assert_eq "true" "$(jq -r .docs_updated "$V")" "rebase: conserva los flags del reviewer"
assert_eq "1" "$(jq '.evidence | length' "$V")" "rebase: la evidencia se REGENERA en el HEAD nuevo"
assert_contains "$out" "1 arrastrada" "rebase: dice cuánto arrastró"

# una entrada sin artefacto citado no se puede probar ajena al delta: re-juzgar
jq '.compliance=[{id:"X-9",covered:true,note:"sin test citado"}]' "$V" > "$V.tmp" && mv "$V.tmp" "$V"
printf 'otra cosa\n' > "$WT/tests/billing.test.js"
gitc add -A && gitc commit -q -m "otro fix"
THIRD="$(gitc rev-parse HEAD)"
mk_ev EV-TEST-999999999999 impl-atlas test "$THIRD"
bash "$WS/scripts/verdict-scaffold.sh" --rebase T1 atlas revisor-1 >/dev/null 2>&1
assert_contains "$(jq -c '.compliance[0]' "$V")" "rejudge" "entrada sin artefacto citado: se re-juzga (sesgo a fail-closed)"

echo
echo "── --rebase: los fail-closed"

out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase --force T1 atlas 2>&1)"; rc=$?
assert_eq 1 "$rc" "--force y --rebase juntos: exit 1"
assert_contains "$out" "opuestos" "explica por qué son incompatibles"

out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 3 "$rc" "rebase sobre el mismo commit: exit 3"
assert_contains "$out" "no hay delta" "dice que no hay delta que rebasear"

mv "$V" "$WS/tasks/T1/guardado.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 3 "$rc" "rebase sin veredicto previo: exit 3"
assert_contains "$out" "no hay veredicto previo" "explica que falta la base"

jq '.commit="0000000000000000000000000000000000000000"' "$WS/tasks/T1/guardado.json" > "$V"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 3 "$rc" "rebase con commit base inexistente: exit 3"
assert_contains "$out" "ya no existe" "no arrastra juicio a ciegas si el commit base desapareció"
rm -f "$V"

# 7. ids inválidos → exit 1 (sin traversal)
bash "$WS/scripts/verdict-scaffold.sh" "../evil" atlas >/dev/null 2>&1 && fail "task traversal pasó" || pass "task-id inválido: exit 1"
bash "$WS/scripts/verdict-scaffold.sh" T1 "re/po" >/dev/null 2>&1 && fail "repo traversal pasó" || pass "repo inválido: exit 1"

echo
echo "── --rebase conserva implementation_agents (el callejon sin salida del ship)"
# Encontrado pasando una feature real: tras un intento de ship, la unica
# evidencia en el HEAD nuevo es la de `ship`, que esta excluida a proposito de
# implementation_agents (un verificador no puede figurar como implementador).
# Sin arrastrar el campo quedaba VACIO y el scaffold se negaba por politica de
# roles, o sea que toda ronda de rework posterior a un ship moria ahi.
# Los fail-closed de arriba dejaron el veredicto borrado: se reconstruye la
# base (evidencia del implementer + scaffold) antes de probar el arrastre.
rm -f "$WS/tasks/T1/evidence/"EV-*.json
BASE2="$(cd "$WT1" && git rev-parse HEAD)"
mk_ev EV-TEST-dddddddddddd impl-atlas test "$BASE2"
rm -f "$V"
bash "$WS/scripts/verdict-scaffold.sh" T1 atlas revisor-1 >/dev/null 2>&1
assert_contains "$(jq -r '.implementation_agents|join(",")' "$V")" "impl-atlas" \
  "base: el scaffold registra al implementer"

# Ahora el caso: nuevo commit CON contenido (un empty dejaría el patch_id
# idéntico y dispararía el no-op de rebase puro, que es otro camino) y SOLO
# evidencia de ship en el HEAD nuevo
NEW2="$(cd "$WT1" && echo fix2 > fix2.txt && git add -A \
  && git -c user.email=t@t -c user.name=t commit -q -m fix2 && git rev-parse HEAD)"
rm -f "$WS/tasks/T1/evidence/"EV-*.json
mk_ev EV-TEST-eeeeeeeeeeee ship test "$NEW2"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 0 "$rc" "rebase con solo evidencia de ship: no se traba"
agents="$(jq -r '.implementation_agents | join(",")' "$V")"
assert_contains "$agents" "impl-atlas" "arrastra al implementer del veredicto previo"
assert_not_contains "$agents" "ship" "y NO deja que ship figure como implementador"

echo
echo "── delta_files: el delta viaja al reviewer, no se re-deriva"
assert_eq '["fix2.txt"]' "$(jq -c .delta_files "$V")" "rebase: persiste la lista del delta en el veredicto"
assert_contains "$out" "diff " "imprime el comando del delta"
assert_contains "$out" "fix2.txt" "y el comando restringe a los archivos del delta"

echo
echo "── rebase PURO: mismo cambio sobre otra base no cobra reviewer"
# El caso de campo: main se movió, el contenido no; --rebase regeneraba el
# scaffold, reseteaba a PENDING_REVIEWER y cobraba un reviewer por un
# movimiento que nadie miró. Simulación con un commit --allow-empty (el diff
# contra la base no cambia, o sea patch_id idéntico: un rebase puro).
jq '.verdict="pass" | .qa="pass" | .requirements_uncovered=0' "$V" > "$V.tmp" && mv "$V.tmp" "$V"
before_hash="$(shasum "$V" | cut -d' ' -f1)"
( cd "$WT1" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "rebase puro simulado" )
out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 0 "$rc" "rebase puro: exit 0"
after_hash="$(shasum "$V" | cut -d' ' -f1)"
assert_eq "$before_hash" "$after_hash" "el veredicto queda BYTE-IDÉNTICO (no se toca)"
assert_contains "$out" "sigue vigente" "dice que el veredicto sigue vigente"
assert_contains "$out" "NO corras review" "y que NO hay que correr review ni QA"
assert_contains "$out" "--renew" "nombra la válvula para la ventana vencida"

# --renew fuerza el re-scaffold aunque el cambio sea el mismo
mk_ev EV-TEST-renew0000001 impl-atlas test "$(git -C "$WT1" rev-parse HEAD)"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase --renew T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 0 "$rc" "--rebase --renew: exit 0"
assert_eq "PENDING_REVIEWER" "$(jq -r .verdict "$V")" "--renew: el re-scaffold real ocurre (PENDING_REVIEWER)"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --renew T1 atlas 2>&1)"; rc=$?
assert_eq 1 "$rc" "--renew sin --rebase: exit 1"

echo
echo "── --merge-qa: la fusión es un comando, no prosa (mata el tercer SHA)"
HEADQ="$(git -C "$WT1" rev-parse HEAD)"
VPID="$(jq -r .patch_id "$V")"

# qa determinista del MISMO commit: fusiona qa + su evidencia
mk_ev EV-TEST-qa000000001 qa test "$HEADQ"
jq -n --arg c "$HEADQ" '{schema:1, task_id:"T1", repo:"atlas", qa:"pass",
  commit:$c, evidence:["EV-TEST-qa000000001"], notes:"flujo ejercitado"}' \
  > "$WS/tasks/T1/qa-atlas.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas 2>&1)"; rc=$?
assert_eq 0 "$rc" "merge-qa mismo commit: exit 0"
assert_eq "pass" "$(jq -r .qa "$V")" "qa fusionado"
assert_contains "$(jq -c .evidence "$V")" "EV-TEST-qa000000001" "la evidencia de QA se apendea"
assert_eq "flujo ejercitado" "$(jq -r .qa_notes "$V")" "las notas viajan a qa_notes"
assert_eq "PENDING_REVIEWER" "$(jq -r .verdict "$V")" "los campos de JUICIO quedan intactos"

# idempotencia a bytes
h1="$(shasum "$V" | cut -d' ' -f1)"
bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas >/dev/null 2>&1
h2="$(shasum "$V" | cut -d' ' -f1)"
assert_eq "$h1" "$h2" "segunda corrida: byte-idéntico (idempotente)"

# QA de OTRO sha del MISMO cambio: liga por patch_id del EV sellado
OTHER_SHA="1111111111111111111111111111111111111111"
jq -n --arg id EV-TEST-qaequiv0001 --arg c "$OTHER_SHA" --arg p "$VPID" \
  '{schema:1, id:$id, task_id:"T1", repo:"atlas", kind:"test", runner:"qa",
    commit:$c, commit_after:$c, exit_code:0, patch_id:$p,
    output:("evidence/"+$id+".log"), output_sha256:"deadbeef"}' \
  > "$WS/tasks/T1/evidence/EV-TEST-qaequiv0001.json"
jq -n --arg c "$OTHER_SHA" '{schema:1, task_id:"T1", repo:"atlas", qa:"pass",
  commit:$c, evidence:["EV-TEST-qaequiv0001"]}' > "$WS/tasks/T1/qa-atlas.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas 2>&1)"; rc=$?
assert_eq 0 "$rc" "QA de otro sha con EV del MISMO cambio: fusiona por equivalencia"

# discrepancia REAL: otro commit sin ningún EV que los ligue → exit 3
jq -n --arg c "$OTHER_SHA" '{schema:1, task_id:"T1", repo:"atlas", qa:"pass",
  commit:$c, evidence:[]}' > "$WS/tasks/T1/qa-atlas.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas 2>&1)"; rc=$?
assert_eq 3 "$rc" "commits distintos sin EV que los ligue: exit 3"
assert_contains "$out" "re-corre QA" "con la remediación exacta"

# EV citado por QA de OTRO cambio → exit 3 nombrando la causa
jq -n --arg id EV-TEST-qaotro00001 --arg c "$OTHER_SHA" \
  '{schema:1, id:$id, task_id:"T1", repo:"atlas", kind:"test", runner:"qa",
    commit:$c, commit_after:$c, exit_code:0, patch_id:"OTRO-CAMBIO",
    output:("evidence/"+$id+".log"), output_sha256:"deadbeef"}' \
  > "$WS/tasks/T1/evidence/EV-TEST-qaotro00001.json"
jq -n --arg c "$OTHER_SHA" '{schema:1, task_id:"T1", repo:"atlas", qa:"pass",
  commit:$c, evidence:["EV-TEST-qaotro00001"]}' > "$WS/tasks/T1/qa-atlas.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas 2>&1)"; rc=$?
assert_eq 3 "$rc" "EV de QA de OTRO cambio: exit 3"
assert_contains "$out" "OTRO cambio" "nombra la causa"
assert_contains "$out" "evidence_baseline" "y ofrece el campo para el rojo primero, que antes no tenía salida"

# ── el rojo primero: la prueba vive en OTRO commit por definición ──────
# Caso de campo (COR-650): el requirement se demuestra corriendo el test sobre
# el árbol BASE, así que ese EV se sella en otro SHA y en rojo. Exigirle
# igualdad de commit y exit 0 lo volvía inaceptable SIEMPRE, y el agente QA
# terminaba inventando campos ad hoc que ningún gate leía.
PARENT="$(git -C "$WT1" rev-parse "$HEADQ^")"
jq -n --arg id EV-TEST-rojobase001 --arg c "$PARENT" \
  '{schema:1, id:$id, task_id:"T1", repo:"atlas", kind:"test", runner:"qa",
    commit:$c, commit_after:$c, exit_code:1,
    output:("evidence/"+$id+".log"), output_sha256:"deadbeef"}' \
  > "$WS/tasks/T1/evidence/EV-TEST-rojobase001.json"
jq -n --arg c "$HEADQ" '{schema:1, task_id:"T1", repo:"atlas", qa:"pass", commit:$c,
  evidence:["EV-TEST-qa000000001"], evidence_baseline:["EV-TEST-rojobase001"]}' \
  > "$WS/tasks/T1/qa-atlas.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas 2>&1)"; rc=$?
assert_eq 0 "$rc" "baseline sellado sobre un ANCESTRO: merge-qa lo acepta"
assert_contains "$(jq -c '.evidence_baseline' "$V")" "EV-TEST-rojobase001" \
  "el rojo primero queda citado y auditable en el veredicto"
assert_not_contains "$(jq -c '.evidence' "$V")" "EV-TEST-rojobase001" \
  "sin colarse en evidence[], que sigue exigiendo verde y commit exacto"

# la contra-mitad: un baseline de un commit AJENO (no ancestro) no prueba nada
jq -n --arg id EV-TEST-rojoajeno01 --arg c "$OTHER_SHA" \
  '{schema:1, id:$id, task_id:"T1", repo:"atlas", kind:"test", runner:"qa",
    commit:$c, commit_after:$c, exit_code:1,
    output:("evidence/"+$id+".log"), output_sha256:"deadbeef"}' \
  > "$WS/tasks/T1/evidence/EV-TEST-rojoajeno01.json"
jq -n --arg c "$HEADQ" '{schema:1, task_id:"T1", repo:"atlas", qa:"pass", commit:$c,
  evidence:["EV-TEST-qa000000001"], evidence_baseline:["EV-TEST-rojoajeno01"]}' \
  > "$WS/tasks/T1/qa-atlas.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas 2>&1)"; rc=$?
assert_eq 3 "$rc" "baseline de un commit ajeno (no ancestro): exit 3"
assert_contains "$out" "NO es ancestro" "y lo dice: probar el pasado de ESTE cambio es el punto"

# exclusión de flags y qa:"fail" también mecánico
out="$(bash "$WS/scripts/verdict-scaffold.sh" --merge-qa --force T1 atlas 2>&1)"; rc=$?
assert_eq 1 "$rc" "--merge-qa --force: exit 1"
jq -n --arg c "$HEADQ" '{schema:1, task_id:"T1", repo:"atlas", qa:"fail",
  commit:$c, evidence:["EV-TEST-qa000000001"]}' > "$WS/tasks/T1/qa-atlas.json"
bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas >/dev/null 2>&1
assert_eq "fail" "$(jq -r .qa "$V")" "qa fail se fusiona igual de mecánico"

# ── QA sellada bajo CONTENCIÓN: fusiona y DECLARA (antes: exit 3) ──────
# ESTE CASO CAMBIÓ DE SENTIDO, por el mismo motivo que el bloque de más abajo:
# merge_qa exige exit_code 0 ANTES de mirar el sello, así que el EV que llegaba
# a la rama de contención YA ERA VERDE, y la contención produce timeouts (rojos)
# que exit_code ya rechaza. Rechazarlo mandaba a "re-sellá con la máquina
# descargada", que es una espera sin condición de salida: 5 minutos de trabajo
# convertidos en 3 horas en campo.
jq -n --arg id EV-TEST-qasuspect01 --arg c "$HEADQ" \
  '{schema:1, id:$id, task_id:"T1", repo:"atlas", kind:"test", runner:"qa",
    commit:$c, commit_after:$c, exit_code:0, contention:{suspect:true},
    output:("evidence/"+$id+".log"), output_sha256:"deadbeef"}' \
  > "$WS/tasks/T1/evidence/EV-TEST-qasuspect01.json"
jq -n --arg c "$HEADQ" '{schema:1, task_id:"T1", repo:"atlas", qa:"pass",
  commit:$c, evidence:["EV-TEST-qasuspect01"]}' > "$WS/tasks/T1/qa-atlas.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas 2>&1)"; rc=$?
assert_eq 0 "$rc" "EV de QA suspect del commit CORRECTO: fusiona (antes: exit 3)"
assert_contains "$(jq -c .evidence "$V")" "EV-TEST-qasuspect01" "el EV de QA entra al veredicto"
assert_contains "$(jq -c '.evidence_under_contention' "$V")" "EV-TEST-qasuspect01" \
  "y queda DECLARADO, que es lo que el reviewer necesita para juzgarlo"
assert_contains "$out" "CONTENCIÓN" "el merge lo dice por pantalla, no solo en el JSON"
assert_contains "$out" "SALTAN" "nombrando el residuo: guards de entorno que saltan tests"

# La contra-mitad, que NO cambió: un EV de OTRO cambio sigue rechazado, y su
# mensaje sigue siendo el del cambio ajeno, jamás el de contención.
jq -n --arg c "$OTHER_SHA" '{schema:1, task_id:"T1", repo:"atlas", qa:"pass",
  commit:$c, evidence:["EV-TEST-qaotro00001"]}' > "$WS/tasks/T1/qa-atlas.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas 2>&1)"; rc=$?
assert_eq 3 "$rc" "EV de QA de OTRO cambio: sigue siendo exit 3"
assert_contains "$out" "OTRO cambio" "con SU diagnóstico"
assert_not_contains "$out" "CONTENCIÓN" "sin confundirlo con el de contención"

# La otra mitad que NO cambió: el EV de QA del commit correcto pero en ROJO
# bajo carga. Ese sí sigue rechazado, y con el diagnóstico de COR-655: el
# commit es el bueno, y re-sellar puede cambiar el resultado porque la
# contención produce timeouts.
jq -n --arg id EV-TEST-qarojo00001 --arg c "$HEADQ" \
  '{schema:1, id:$id, task_id:"T1", repo:"atlas", kind:"test", runner:"qa",
    commit:$c, commit_after:$c, exit_code:1, contention:{suspect:true},
    output:("evidence/"+$id+".log"), output_sha256:"deadbeef"}' \
  > "$WS/tasks/T1/evidence/EV-TEST-qarojo00001.json"
jq -n --arg c "$HEADQ" '{schema:1, task_id:"T1", repo:"atlas", qa:"pass",
  commit:$c, evidence:["EV-TEST-qarojo00001"]}' > "$WS/tasks/T1/qa-atlas.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --merge-qa T1 atlas 2>&1)"; rc=$?
assert_eq 3 "$rc" "EV de QA en ROJO bajo contención: exit 3"
assert_contains "$out" "ROJO" "nombrando el rojo, que es lo que descalifica"
assert_not_contains "$out" "OTRO cambio" "y no un commit ajeno que no lo es (COR-655)"

echo
echo "── el ÁRBOL CLAVADO: el reviewer juzga el commit sellado, no el árbol vivo"
# P1 de campo: el reviewer leía worktrees/<task>/<repo> mientras el implementer
# (dueño del claim) seguía editándolo sin commitear. El veredicto sellaba X y el
# juicio era de X más ediciones transitorias: un verde irreproducible. El
# scaffold clava un checkout DESACOPLADO en worktrees/<task>/.review-<repo>
# (bajo worktrees/<task>/ para que track-read.sh derive la tarea de la RUTA y
# las lecturas del reviewer se atribuyan solas).

mkdir -p "$WS/tasks/T5/evidence" "$WS/repos/beta"
git init -q -b main "$WS/repos/beta"
git -C "$WS/repos/beta" commit -q --allow-empty -m base
git -C "$WS/repos/beta" update-ref refs/remotes/origin/main HEAD
WT5="$WS/worktrees/T5/beta"
PIN5="$WS/worktrees/T5/.review-beta"
V5="$WS/tasks/T5/verdict-beta.json"
git -C "$WS/repos/beta" worktree add -q -b task/T5 "$WT5" HEAD
g5() { git -C "$WT5" "$@"; }
mk_ev5() {  # mk_ev5 <id> <commit>
  jq -n --arg id "$1" --arg c "$2" \
    '{schema:1, id:$id, task_id:"T5", repo:"beta", kind:"test", runner:"impl-beta",
      commit:$c, commit_after:$c, exit_code:0, output:("evidence/"+$id+".log"),
      output_sha256:"deadbeef"}' > "$WS/tasks/T5/evidence/$1.json"
}

printf 'v1\n' > "$WT5/app.txt"
g5 add -A; g5 commit -q -m v1
H5A="$(g5 rev-parse HEAD)"
mk_ev5 EV-TEST-pin000000001 "$H5A"

# (a) el implementer deja ediciones SIN COMMITEAR encima: el pin sella el commit
printf 'edicion transitoria\n' >> "$WT5/app.txt"
out="$(bash "$WS/scripts/verdict-scaffold.sh" T5 beta revisor-5 2>&1)"; rc=$?
assert_eq 0 "$rc" "pin: el scaffold sale 0"
[ -d "$PIN5" ] && pass "clava worktrees/T5/.review-beta (la ruta que track-read atribuye a T5)" \
  || fail "no creó el árbol clavado"
assert_eq "$H5A" "$(git -C "$PIN5" rev-parse HEAD)" "el pin está en el commit SELLADO"
assert_eq "$H5A" "$(jq -r .commit "$V5")" "y es el mismo commit que sella el veredicto"
assert_not_contains "$(cat "$PIN5/app.txt")" "edicion transitoria" \
  "el pin NO contiene las ediciones sin commitear del worktree vivo"
assert_contains "$(cat "$WT5/app.txt")" "edicion transitoria" \
  "(el worktree vivo SÍ las tiene: el fixture reproduce el P1 de verdad)"
git -C "$PIN5" symbolic-ref -q HEAD >/dev/null 2>&1 \
  && fail "el pin tiene rama: podría esconder trabajo y --rm no podría borrarlo sin drama" \
  || pass "el pin es detached (sin rama que conservar)"
assert_contains "$out" "worktrees/T5/.review-beta" "el scaffold dice dónde quedó el árbol clavado"

# (b) --rebase re-clava al commit nuevo
printf 'v2\n' > "$WT5/app.txt"
g5 add -A; g5 commit -q -m "fix del blocking"
H5B="$(g5 rev-parse HEAD)"
mk_ev5 EV-TEST-pin000000002 "$H5B"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase T5 beta revisor-5 2>&1)"; rc=$?
assert_eq 0 "$rc" "rebase: exit 0"
assert_eq "$H5B" "$(jq -r .commit "$V5")" "rebase: el veredicto sella el commit nuevo"
assert_eq "$H5B" "$(git -C "$PIN5" rev-parse HEAD)" "rebase: el pin se RE-CLAVA al commit nuevo"
assert_contains "$(cat "$PIN5/app.txt")" "v2" "y su contenido es el del commit nuevo"
assert_contains "$out" "worktrees/T5/.review-beta diff" \
  "el comando de delta corre en el árbol clavado, no en el vivo"

# (c) si el pin falla, el scaffold NO muere: lo declara y deja el supuesto al bus.
# Fallo inyectado con un shim de git que rechaza SOLO el subcomando worktree
# (repo raro, disco, metadata que no se deja podar: la clase entera).
cp "$ROOT/templates/scripts/emit.sh" "$WS/scripts/"
mkdir -p "$WS/.shim"
REAL_GIT="$(command -v git)"
cat > "$WS/.shim/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = "worktree" ] && { echo "fatal: shim de test: git worktree no disponible" >&2; exit 128; }
done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$WS/.shim/git"
rm -rf "$PIN5"        # pin roto: metadata viva, dir ausente
printf 'v3\n' > "$WT5/app.txt"; g5 add -A; g5 commit -q -m v3
H5C="$(g5 rev-parse HEAD)"
mk_ev5 EV-TEST-pin000000003 "$H5C"
out="$(PATH="$WS/.shim:$PATH" CLAUDE_PROJECT_DIR="$WS" \
  bash "$WS/scripts/verdict-scaffold.sh" --rebase T5 beta revisor-5 2>&1)"; rc=$?
assert_eq 0 "$rc" "pin imposible: el scaffold NO muere (sería un falso rojo)"
assert_eq "$H5C" "$(jq -r .commit "$V5")" "y el veredicto se sella igual"
assert_contains "$out" "no pude clavar" "lo DICE (nada de degradar en silencio)"
assert_contains "$out" "shim de test" "con el motivo REAL de git, no un resumen inventado"
assert_contains "$out" "SUPUESTO" "declara el supuesto que queda abierto"
assert_contains "$(cat "$WS/.harness/events.jsonl" 2>&1)" "assumption" "y lo deja en el bus"
assert_contains "$out" "worktrees/T5/beta diff" "sin pin, el delta cae al worktree vivo (no miente la ruta)"

# el pin roto no es permanente: el siguiente scaffold lo rehace
printf 'v4\n' > "$WT5/app.txt"; g5 add -A; g5 commit -q -m v4
H5D="$(g5 rev-parse HEAD)"
mk_ev5 EV-TEST-pin000000004 "$H5D"
bash "$WS/scripts/verdict-scaffold.sh" --rebase T5 beta revisor-5 >/dev/null 2>&1
assert_eq "$H5D" "$(git -C "$PIN5" rev-parse HEAD)" \
  "un pin roto ('missing but already registered') se rehace en el scaffold siguiente"

echo
echo "── --rm limpia el pin (un huérfano deja la metadata del repo rota)"
cp "$ROOT/templates/scripts/worktree-task.sh" "$WS/scripts/"
out="$(bash "$WS/scripts/worktree-task.sh" --rm T5 2>&1)"
assert_no_file "$PIN5" "--rm borra el árbol clavado"
assert_contains "$out" "pin de review" "y lo dice"
# La metadata es la prueba dura, no que el dir se haya ido: `worktree add` en la
# ruta de un pin huérfano a veces muere ("missing but already registered") y a
# veces ni reconoce la colisión y registra una entrada basura más. Lo que no
# puede quedar es la entrada.
assert_not_contains "$(git -C "$WS/repos/beta" worktree list --porcelain)" ".review-beta" \
  "git worktree list queda sin el pin: cero metadata huérfana"

# El otro huérfano, y el que ningún glob de directorios ve: el DIR del pin ya no
# está pero la metadata sigue registrada.
git -C "$WS/repos/beta" worktree add -q "$WT5" task/T5
git -C "$WS/repos/beta" worktree add -q --detach "$PIN5" HEAD
rm -rf "$PIN5"
bash "$WS/scripts/worktree-task.sh" --rm T5 >/dev/null 2>&1
assert_not_contains "$(git -C "$WS/repos/beta" worktree list --porcelain)" ".review-beta" \
  "--rm poda también el pin registrado cuyo dir ya no existe"

echo
echo "── un EV sellado bajo contención ENTRA al veredicto, DECLARADO"
# ESTE BLOQUE CAMBIÓ DE SENTIDO A PROPÓSITO, y su historia importa porque la
# conducta vieja costó caro. Antes afirmaba lo contrario ("un EV marcado por
# contención NO entra al veredicto"): el scaffold lo excluía para que la
# remediación de gate_preflight fuera alcanzable.
#
# CASO DE CAMPO MEDIDO: esa exclusión convirtió una tarea de 5 minutos en 3
# HORAS y hubo que matarla. El agente sellaba, el scaffold salía exit 3 por
# contención, y volvía a sellar esperando a que la máquina se calmara: un
# bucle sin condición de salida, porque la carga no dependía de él.
#
# Y el gate bloqueaba justo la única clase de resultado que la contención NO
# puede falsificar: la elegibilidad exige exit_code 0 ANTES de mirar el sello,
# o sea que todo EV que llega al chequeo de contención YA SALIÓ VERDE, y la
# contención produce TIMEOUTS, o sea ROJOS. Un rojo ya lo rechaza exit_code.
#
# Así que la contención deja de EXCLUIR y pasa a DECLARARSE: el EV entra y el
# veredicto lo lista en evidence_under_contention. El residuo real que queda
# (una suite cuyos guards de entorno SALTAN tests cuando un servicio está
# lento sale verde con MENOS tests corridos) es JUICIO del reviewer, y para
# juzgarlo tiene que saberlo: taparlo no lo hacía desaparecer.
mkdir -p "$WS/tasks/T6/evidence" "$WS/worktrees/T6"
WT6="$WS/worktrees/T6/atlas"
git init -q -b main "$WT6"
git -C "$WT6" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$WT6" update-ref refs/remotes/origin/main HEAD
echo "cambio de la tarea" > "$WT6/feature.txt"
git -C "$WT6" add -A
git -C "$WT6" -c user.email=t@t -c user.name=t commit -q -m x
H6="$(git -C "$WT6" rev-parse HEAD)"

mk_ev6() {  # mk_ev6 <id> <commit> <suspect true|false>
  jq -n --arg id "$1" --arg c "$2" --argjson s "$3" \
    '{schema:1, id:$id, task_id:"T6", repo:"atlas", kind:"test",
      runner:"impl-atlas", commit:$c, commit_after:$c, exit_code:0,
      output:("evidence/"+$id+".log"), output_sha256:"deadbeef",
      contention:{suspect:$s}}' > "$WS/tasks/T6/evidence/$1.json"
}

# (a) dos EVs del MISMO commit, uno marcado y otro limpio: entran los DOS, y
# solo el marcado queda declarado.
mk_ev6 EV-TEST-c0ntam1nad0 "$H6" true
mk_ev6 EV-TEST-l1mp10l1mp1 "$H6" false
bash "$WS/scripts/verdict-scaffold.sh" T6 atlas revisor-6 >/dev/null 2>&1 \
  && pass "con evidencia verde del commit: exit 0" || fail "el scaffold falló con evidencia verde"
V6="$WS/tasks/T6/verdict-atlas.json"
assert_eq "EV-TEST-c0ntam1nad0,EV-TEST-l1mp10l1mp1" "$(jq -r '.evidence | join(",")' "$V6")" \
  "cita los dos: la contención ya no descarta un verde"
assert_eq "EV-TEST-c0ntam1nad0" "$(jq -r '.evidence_under_contention | join(",")' "$V6")" \
  "y DECLARA solo el sellado bajo carga, que es lo que el reviewer tiene que mirar"

# el campo es ADITIVO: sin EV bajo contención, el veredicto no lo inventa
rm -f "$WS/tasks/T6/evidence/EV-TEST-c0ntam1nad0.json" "$V6"
bash "$WS/scripts/verdict-scaffold.sh" T6 atlas revisor-6 >/dev/null 2>&1
assert_eq "false" "$(jq 'has("evidence_under_contention")' "$V6")" \
  "sin contención, el veredicto no inventa el campo"

# (b) el que causaba el bucle de 3 horas: el ÚNICO EV está marcado.
mk_ev6 EV-TEST-c0ntam1nad0 "$H6" true
rm -f "$WS/tasks/T6/evidence/EV-TEST-l1mp10l1mp1.json" "$V6"
out="$(bash "$WS/scripts/verdict-scaffold.sh" T6 atlas revisor-6 2>&1)"; rc=$?
assert_eq 0 "$rc" "único EV sellado bajo contención: exit 0 (antes: exit 3, y a re-sellar para siempre)"
assert_eq "EV-TEST-c0ntam1nad0" "$(jq -r '.evidence | join(",")' "$V6")" \
  "el EV entra: es un VERDE, y la contención produce rojos, no verdes falsos"
assert_eq "EV-TEST-c0ntam1nad0" "$(jq -r '.evidence_under_contention | join(",")' "$V6")" \
  "y queda declarado, no colado en silencio"
# El razonamiento va A PANTALLA: un veredicto que declara un campo que nadie
# explica se lee como ruido y el reviewer lo saltea.
assert_contains "$out" "CONTENCIÓN" "el scaffold lo DICE, no solo lo escribe en el JSON"
assert_contains "$out" "SALTAN" "y nombra el residuo concreto: guards de entorno que saltan tests"
assert_not_contains "$out" "OTRO commit" "sin culpar a un HEAD que nadie movió"

# (c) REGRESIÓN: la contención dejó de excluir, pero el commit ajeno NO. Un EV
# de otro cambio, marcado o no, sigue afuera y con SU diagnóstico.
rm -f "$V6"
mk_ev6 EV-TEST-4jen0suspec "0000000000000000000000000000000000000000" true
rm -f "$WS/tasks/T6/evidence/EV-TEST-c0ntam1nad0.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" T6 atlas revisor-6 2>&1)"; rc=$?
assert_eq 3 "$rc" "EV de OTRO commit (aunque esté marcado): sigue siendo exit 3"
assert_contains "$out" "OTRO commit" "y su mensaje sigue siendo el del commit ajeno"
assert_contains "$out" "evidence.py run" "con la remediación de sellar sobre el HEAD actual"
rm -f "$WS/tasks/T6/evidence/EV-TEST-4jen0suspec.json"

# (d) El diagnóstico de COR-655 sobrevive, MUDADO al único caso donde la
# contención sigue explicando por qué falta un verde: el EV del commit correcto
# que salió en ROJO bajo carga. Ahí re-sellar SÍ puede cambiar el resultado
# (la contención produce timeouts), al revés que con un verde.
rm -f "$V6"
jq -n --arg id EV-TEST-r0j0b4j0c4r --arg c "$H6" \
  '{schema:1, id:$id, task_id:"T6", repo:"atlas", kind:"test", runner:"impl-atlas",
    commit:$c, commit_after:$c, exit_code:1, contention:{suspect:true},
    output:("evidence/"+$id+".log"), output_sha256:"deadbeef"}' \
  > "$WS/tasks/T6/evidence/EV-TEST-r0j0b4j0c4r.json"
out="$(bash "$WS/scripts/verdict-scaffold.sh" T6 atlas revisor-6 2>&1)"; rc=$?
assert_eq 3 "$rc" "EV en ROJO bajo contención: exit 3 (un rojo no lo salva ningún sello)"
assert_contains "$out" "ROJO" "el diagnóstico dice que el problema es el rojo"
assert_contains "$out" "CONTENCIÓN" "y que la carga puede ser su causa"
assert_not_contains "$out" "OTRO commit" "sin culpar a un HEAD que nadie movió (COR-655)"
rm -f "$WS/tasks/T6/evidence/EV-TEST-r0j0b4j0c4r.json"

echo
echo "── el veredicto HEREDA la condición declarada del precheck (bug conocido)"
# Caso de campo: un agente choca con un gate del harness que da falso rojo,
# lo declara con HARNESS_KNOWN_BUG (que exige el issue ya reportado) y sigue.
# Ese slot NO se verificó. Si el veredicto no lo hereda, el reviewer juzga un
# verde que no es verde del todo y nadie se lo dijo.
mk_ev6 EV-TEST-h3r3d4d0001 "$H6" false
rm -f "$V6"
cat > "$WS/tasks/T6/precheck-atlas.json" <<'PK'
{"schema":1,"ok":true,"commit":"x","known_bug":{"slot":"tests","url":"https://github.com/o/r/issues/77"}}
PK
out="$(bash "$WS/scripts/verdict-scaffold.sh" T6 atlas revisor-6 2>&1)"; rc=$?
assert_eq 0 "$rc" "el scaffold sale igual de verde"
assert_eq "https://github.com/o/r/issues/77" "$(jq -r '.known_bug.url' "$V6")" \
  "y el veredicto hereda el issue del bug conocido"
assert_eq "tests" "$(jq -r '.known_bug.slot' "$V6")" "nombrando el slot que quedó sin verificar"
assert_contains "$out" "HEREDA una condición declarada" "y se lo dice al reviewer en la cara"

# Sin el campo en el sello, el veredicto queda EXACTAMENTE como antes: aditivo
# y fail-open, o sea que esto no puede romper a quien no lo usa.
rm -f "$V6"
printf '{"schema":1,"ok":true,"commit":"x"}\n' > "$WS/tasks/T6/precheck-atlas.json"
bash "$WS/scripts/verdict-scaffold.sh" T6 atlas revisor-6 >/dev/null 2>&1
assert_eq "false" "$(jq 'has("known_bug")' "$V6")" \
  "sin bug declarado, el veredicto no inventa el campo"
rm -f "$WS/tasks/T6/precheck-atlas.json" "$V6" \
      "$WS/tasks/T6/evidence/EV-TEST-h3r3d4d0001.json"

echo
echo "── --rebase --renew con el MISMO commit: re-liga la evidencia y CONSERVA el juicio"
# Caso de campo (COR-360): un veredicto ya juzgado cita evidencia que dejó de
# valer (se re-selló, se movió el archivo, cambió qué EV la respalda) y el
# commit NO se movió: --rebase se negaba ("no hay delta que rebasear") y
# --force borraba el juicio, así que la única salida era pagar un re-review
# completo de un diff idéntico al ya aprobado. La evidencia caduca; el juicio
# no. El REBIND sigue siendo válido y es lo único que re-liga sin re-juzgar.
mk_ev6 EV-TEST-l1mp10l1mp1 "$H6" false
mk_ev6 EV-TEST-c0ntam1nad0 "$H6" true
rm -f "$V6"
bash "$WS/scripts/verdict-scaffold.sh" T6 atlas revisor-6 >/dev/null 2>&1
# el reviewer ya escribió su juicio, y el veredicto cita una sola evidencia
jq '.verdict="pass" | .qa="pass" | .requirements_uncovered=0
    | .compliance=[{id:"R-1",covered:true,tests:["t.js"]}]
    | .evidence=["EV-TEST-c0ntam1nad0"] | del(.evidence_under_contention)' \
  "$V6" > "$V6.tmp" && mv "$V6.tmp" "$V6"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase --renew T6 atlas revisor-6 2>&1)"; rc=$?
assert_eq 0 "$rc" "rebind: exit 0 con el commit sin moverse"
assert_contains "$out" "rebind" "y lo llama por su nombre, no 're-review incremental'"
assert_eq "pass" "$(jq -r .verdict "$V6")" "rebind: el juicio se CONSERVA (no vuelve a PENDING)"
assert_eq "EV-TEST-c0ntam1nad0,EV-TEST-l1mp10l1mp1" "$(jq -r '.evidence | join(",")' "$V6")" \
  "rebind: re-liga toda la evidencia elegible del commit"
# El rebind también DECLARA: si re-ligó un EV sellado bajo carga, el campo
# tiene que aparecer aunque el veredicto previo no lo trajera. Si no, el
# rebind sería la puerta trasera por donde la contención entra sin decirlo.
assert_eq "EV-TEST-c0ntam1nad0" "$(jq -r '.evidence_under_contention | join(",")' "$V6")" \
  "rebind: la declaración de contención se recalcula, no se hereda del previo"
assert_eq "1" "$(jq '.compliance | length' "$V6")" "rebind: la matriz de compliance sobrevive entera"
assert_eq "0" "$(jq '.requirements_uncovered' "$V6")" "y los campos de juicio del reviewer también"

# Sin --renew el mismo commit sigue siendo un error, pero ahora ENSEÑA la salida
jq '.evidence=["EV-TEST-c0ntam1nad0"]' "$V6" > "$V6.tmp" && mv "$V6.tmp" "$V6"
out="$(bash "$WS/scripts/verdict-scaffold.sh" --rebase T6 atlas revisor-6 2>&1)"; rc=$?
assert_eq 3 "$rc" "--rebase solo, con el commit sin moverse: sigue siendo exit 3"
assert_contains "$out" "--rebase --renew" "pero nombra el camino de vuelta, que antes no existía"

t_done
