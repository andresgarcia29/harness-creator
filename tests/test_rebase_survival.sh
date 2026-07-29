#!/usr/bin/env bash
# test_rebase_survival.sh: el hallazgo central de la auditoría del trunk
# caliente: con varias personas pusheando al mismo main, el rebase de ship.sh
# reescribía los SHA y tiraba veredicto + evidencia + QA, o sea decenas de
# minutos de juicio de LLM, por un movimiento que el reviewer nunca miró.
#
# Lo que se fija acá:
#   1. change-id.sh: el MISMO cambio sobre otra base da el MISMO id.
#   2. change-id.sh NO es ciego al whitespace (patch-id a secas sí lo es, y en
#      Python/YAML/Makefile la indentación es semántica: sin esto se podría
#      re-indentar DESPUÉS del review conservando el pass).
#   3. Interferencia textual cercana → id distinto → re-review (fail-closed).
#   4. validate-ship reusa el juicio con el mismo patch_id, y NO lo reusa si
#      el cambio cambió, si el veredicto está viejo, o si la base voló lejos.
#   5. evidence.py: la prueba REVISADA y la prueba FRESCA son afirmaciones
#      distintas, y sin la fresca no se pushea un árbol que nadie corrió.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

CHANGE_ID="$ROOT/templates/scripts/change-id.sh"
POLICY_PY="$ROOT/templates/scripts/harness-policy.py"
EVIDENCE_PY="$ROOT/templates/scripts/evidence.py"

g() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

mk_base() {  # mk_base <dir>: repo con origin/main y un archivo Python
  rm -rf "$1"; mkdir -p "$1"
  git init -q -b main "$1"
  printf 'def f():\n    return 1\n\nHELPER = 0\n' > "$1/app.py"
  g "$1" add -A; g "$1" commit -qm base
  g "$1" update-ref refs/remotes/origin/main HEAD
}

echo "── change-id: el mismo cambio sobrevive a que se mueva la base"

R="$WS/r1"; mk_base "$R"
# el cambio de la tarea
printf 'def f():\n    return 2\n\nHELPER = 0\n' > "$R/app.py"
g "$R" add -A; g "$R" commit -qm "mi cambio"
ID_ANTES="$(bash "$CHANGE_ID" "$R" main)"
SHA_ANTES="$(g "$R" rev-parse HEAD)"

# otro workspace pushea a main un archivo AJENO, y nosotros rebaseamos
g "$R" checkout -q -b tmp origin/main
printf 'x = 1\n' > "$R/otro.py"; g "$R" add -A; g "$R" commit -qm "commit de otro"
g "$R" update-ref refs/remotes/origin/main HEAD
g "$R" checkout -q main >/dev/null 2>&1 || g "$R" checkout -q -
g "$R" rebase -q origin/main >/dev/null 2>&1
ID_DESPUES="$(bash "$CHANGE_ID" "$R" main)"
SHA_DESPUES="$(g "$R" rev-parse HEAD)"

[ "$SHA_ANTES" != "$SHA_DESPUES" ] \
  && pass "el rebase SÍ cambió el SHA (la premisa del bug se reproduce)" \
  || fail "el rebase no movió el SHA: el fixture no reproduce el caso"
assert_eq "$ID_ANTES" "$ID_DESPUES" "mismo cambio sobre otra base: MISMO patch_id"

echo "── change-id: lo que NO debe sobrevivir"

# 2. indentación: `git patch-id` a secas da el mismo id acá (verificado), y por
#    eso change-id.sh usa --verbatim. Si esto se rompe, se abre la puerta a
#    re-indentar después del review conservando el veredicto.
R2="$WS/r2"; mk_base "$R2"
printf 'def f():\n    return 2\n\nHELPER = 0\n' > "$R2/app.py"
g "$R2" add -A; g "$R2" commit -qm "indent 4"
ID_4="$(bash "$CHANGE_ID" "$R2" main)"
g "$R2" reset -q --hard origin/main
printf 'def f():\n  return 2\n\nHELPER = 0\n' > "$R2/app.py"
g "$R2" add -A; g "$R2" commit -qm "indent 2"
ID_2="$(bash "$CHANGE_ID" "$R2" main)"
[ "$ID_4" != "$ID_2" ] \
  && pass "cambiar la indentación cambia el id (whitespace ES semántica en Python)" \
  || fail "id ciego al whitespace: se podría re-indentar tras el review y conservar el pass"

# 3. un commit ajeno que toca líneas ADYACENTES mueve el contexto del diff, así
#    que el id cambia y la tarea cae a re-review. Es fail-closed gratis.
R3="$WS/r3"; mk_base "$R3"
printf 'def f():\n    return 2\n\nHELPER = 0\n' > "$R3/app.py"
g "$R3" add -A; g "$R3" commit -qm mio
ID_LEJOS="$(bash "$CHANGE_ID" "$R3" main)"
g "$R3" checkout -q -b tmp3 origin/main
printf 'def f():\n    return 1\n\nHELPER = 99\n' > "$R3/app.py"   # línea vecina
g "$R3" add -A; g "$R3" commit -qm "otro toca al lado"
g "$R3" update-ref refs/remotes/origin/main HEAD
g "$R3" checkout -q - >/dev/null 2>&1
g "$R3" rebase -q origin/main >/dev/null 2>&1 || g "$R3" rebase --abort >/dev/null 2>&1
ID_CERCA="$(bash "$CHANGE_ID" "$R3" main 2>/dev/null || echo CONFLICTO)"
[ "$ID_LEJOS" != "$ID_CERCA" ] \
  && pass "interferencia en líneas vecinas: id distinto → re-review (fail-closed)" \
  || fail "un cambio ajeno adyacente no alteró el id"

# 4. diff vacío no tiene identidad: no puede haber un id compartido por todas
#    las tareas sin cambios.
R4="$WS/r4"; mk_base "$R4"
bash "$CHANGE_ID" "$R4" main >/dev/null 2>&1 \
  && fail "un diff vacío devolvió id" || pass "diff vacío: sin identidad de cambio (exit != 0)"

echo "── validate-ship: reusa el JUICIO, jamás la PRUEBA"

POL="$WS/policy.json"
cat > "$POL" <<'JSON'
{"schema":1,
 "workflow":{"initial_phase":"intake",
   "phase_order":["intake","rfc","implement","review","ship","deploy","archive"],
   "allowed_transitions":{"intake":["rfc"],"rfc":["implement"],"implement":["review"],
     "review":["implement","ship"],"ship":["deploy"],"deploy":["archive"],"archive":[],"blocked":[]},
   "lanes":{"express":{},"standard":{},"full":{}},
   "lane_escalation":["express","standard","full"],
   "allowed_pause_reasons":["enrichment_questions"]},
 "limits":{"max_review_rounds":3},
 "ship":{"require_independent_review":true,"require_fresh_evidence":true,
   "required_evidence_kinds":["test"],
   "verdict_reuse":{"enabled":true,"max_age_hours":24,"max_base_commits":200}}}
JSON

TD="$WS/tasks/T1"; mkdir -p "$TD"
cat > "$TD/state.json" <<'JSON'
{"schema":1,"task_id":"T1","phase":"review","lane":"full","review_rounds":1,
 "budget_usd":null,"spent_usd":0.0,
 "history":[{"from":"implement","to":"review","actor":"orchestrator"}]}
JSON

mk_verdict() {  # mk_verdict <commit> <patch_id> <reviewed_at>
  jq -n --arg c "$1" --arg p "$2" --arg t "$3" \
    '{schema:1, task_id:"T1", repo:"atlas", commit:$c, patch_id:$p, reviewed_at:$t,
      reviewer:"reviewer", implementation_agents:["impl-atlas"],
      verdict:"pass", qa:"pass", evidence:["EV-TEST-aaaaaaaaaaaa"],
      blocking:[], non_blocking:[], docs_updated:true, compliance:[],
      requirements_uncovered:0, snapshots_updated_justified:true}' > "$TD/verdict-atlas.json"
}
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VS() { python3 "$POLICY_PY" --policy "$POL" validate-ship "$TD" \
         --verdict "$TD/verdict-atlas.json" "$@" 2>&1; }

# el caso que rompía todo: SHA distinto, mismo cambio
mk_verdict "aaaa111" "PID-IGUAL" "$NOW"
out="$(VS --commit "bbbb222" --patch-id "PID-IGUAL" --base-moved 3)"; rc=$?
assert_eq 0 "$rc" "SHA distinto + patch_id igual: el veredicto se reusa"
assert_contains "$out" "veredicto reusado" "dice explícitamente que lo reusó"
assert_contains "$out" "REVIEWED_COMMIT=aaaa111" "publica el commit revisado para evidence.py"

# el cambio cambió de verdad → re-review
out="$(VS --commit "bbbb222" --patch-id "PID-OTRO" --base-moved 3)"; rc=$?
assert_eq 3 "$rc" "patch_id distinto: NO se reusa"
assert_contains "$out" "NO es el que se revisó" "nombra la causa real"
assert_contains "$out" "verdict-scaffold.sh --rebase" "da la remediación exacta"

# sin patch_id en el veredicto (instancia vieja) → comportamiento estricto
mk_verdict "aaaa111" "" "$NOW"
out="$(VS --commit "bbbb222" --patch-id "PID-IGUAL")"; rc=$?
assert_eq 3 "$rc" "veredicto sin patch_id: exige commit exacto (sin aflojar)"
assert_contains "$out" "no declara patch_id" "explica por qué no puede reusar"

# el juicio caduca en el TIEMPO aunque el texto sea idéntico
VIEJO="$(python3 -c "import datetime as d;print((d.datetime.now(d.timezone.utc)-d.timedelta(hours=48)).isoformat().replace('+00:00','Z'))")"
mk_verdict "aaaa111" "PID-IGUAL" "$VIEJO"
out="$(VS --commit "bbbb222" --patch-id "PID-IGUAL")"; rc=$?
assert_eq 3 "$rc" "veredicto de 48h con ventana de 24h: NO se reusa"
assert_contains "$out" "el trunk de abajo ya no" "explica que el texto igual no basta"

# la base voló demasiado lejos
mk_verdict "aaaa111" "PID-IGUAL" "$NOW"
out="$(VS --commit "bbbb222" --patch-id "PID-IGUAL" --base-moved 500)"; rc=$?
assert_eq 3 "$rc" "base +500 commits con tope 200: NO se reusa"

# mismo commit: el camino de siempre, sin necesitar patch_id
mk_verdict "cccc333" "PID-IGUAL" "$NOW"
out="$(VS --commit "cccc333")"; rc=$?
assert_eq 0 "$rc" "commit idéntico: pasa como siempre (compat)"
assert_not_contains "$out" "veredicto reusado" "commit idéntico: no anuncia reutilización"

echo "── evidence: prueba REVISADA y prueba FRESCA son cosas distintas"

mkdir -p "$TD/evidence"
mk_ev() {  # mk_ev <id> <runner> <commit>
  printf 'salida del test\n' > "$TD/evidence/$1.log"
  local h; h="$(shasum -a 256 "$TD/evidence/$1.log" | cut -d' ' -f1)"
  jq -n --arg id "$1" --arg r "$2" --arg c "$3" --arg h "$h" \
    '{schema:1, id:$id, task_id:"T1", repo:"atlas", kind:"test", runner:$r,
      commit:$c, commit_after:$c, exit_code:0,
      output:("evidence/"+$id+".log"), output_sha256:$h}' > "$TD/evidence/$1.json"
}
mk_ev EV-TEST-aaaaaaaaaaaa impl-atlas "aaaa111"
mk_verdict "aaaa111" "PID-IGUAL" "$NOW"
EV() { python3 "$EVIDENCE_PY" verify --task-dir "$TD" --repo atlas "$@" 2>&1; }

# el árbol que se pushea NO es el revisado y nadie lo corrió → fail-closed
out="$(EV --commit "bbbb222" --reviewed-commit "aaaa111" \
        --verdict "$TD/verdict-atlas.json" --require-kind test --require-fresh-kind test)"; rc=$?
assert_eq 3 "$rc" "sin evidencia del árbol integrado: NO se pushea"
assert_contains "$out" "evidencia FRESCA" "nombra exactamente lo que falta"

# ship corre la suite sobre el árbol integrado y sella SU evidencia
mk_ev EV-TEST-bbbbbbbbbbbb ship "bbbb222"
out="$(EV --commit "bbbb222" --reviewed-commit "aaaa111" \
        --verdict "$TD/verdict-atlas.json" --require-kind test --require-fresh-kind test)"; rc=$?
assert_eq 0 "$rc" "con evidencia fresca de ship: pasa"
assert_contains "$out" "evidencia fresca" "declara que verificó el árbol que aterriza"
assert_contains "$out" "ship" "nombra al runner que la produjo"

# la evidencia del review sigue atada a lo que el reviewer miró
out="$(EV --commit "bbbb222" --reviewed-commit "zzzz999" \
        --verdict "$TD/verdict-atlas.json" --require-kind test)"; rc=$?
assert_eq 3 "$rc" "veredicto de otro commit revisado: sigue rechazando"

# sin --reviewed-commit el contrato es el histórico (compat)
mk_verdict "bbbb222" "PID-IGUAL" "$NOW"
mk_ev EV-TEST-aaaaaaaaaaaa impl-atlas "bbbb222"
out="$(EV --commit "bbbb222" --verdict "$TD/verdict-atlas.json" --require-kind test)"; rc=$?
assert_eq 0 "$rc" "sin --reviewed-commit: comportamiento histórico intacto"

echo "── los TRES SHAs del caso de campo: la citada sobrevive por patch_id"
# EV sellado en C1 (precheck del implementer), veredicto en R, HEAD en H.
# Antes: 'commit=C1; se esperaba R' tras pagar lock y suite, 8-9 veces por
# corrida. Ahora: mismo cambio (patch_id) => la citada pasa; la FRESCA la
# aporta el EV runner=ship sobre H, y sigue siendo SHA-estricta.
mk_ev_pid() {  # mk_ev_pid <id> <runner> <commit> <patch-id>
  printf 'salida del test\n' > "$TD/evidence/$1.log"
  local h; h="$(shasum -a 256 "$TD/evidence/$1.log" | cut -d' ' -f1)"
  jq -n --arg id "$1" --arg r "$2" --arg c "$3" --arg h "$h" --arg p "$4" \
    '{schema:1, id:$id, task_id:"T1", repo:"atlas", kind:"test", runner:$r,
      commit:$c, commit_after:$c, exit_code:0, patch_id:$p,
      output:("evidence/"+$id+".log"), output_sha256:$h}' > "$TD/evidence/$1.json"
}
jq -n --arg t "$NOW" \
  '{schema:1, task_id:"T1", repo:"atlas", commit:"523767e", patch_id:"PID-CAMPO",
    reviewed_at:$t, reviewer:"reviewer", implementation_agents:["impl-atlas"],
    verdict:"pass", qa:"pass", evidence:["EV-TEST-cd4552b00001"],
    blocking:[], non_blocking:[], docs_updated:true, compliance:[],
    requirements_uncovered:0, snapshots_updated_justified:true}' > "$TD/verdict-atlas.json"
mk_ev_pid EV-TEST-cd4552b00001 impl-atlas "cd4552b" "PID-CAMPO"   # el tercer SHA
mk_ev_pid EV-TEST-a4a851000001 ship       "a4a8510" "PID-CAMPO"   # la fresca en HEAD
out="$(EV --commit "a4a8510" --reviewed-commit "523767e" \
        --verdict "$TD/verdict-atlas.json" --require-kind test --require-fresh-kind test)"; rc=$?
assert_eq 0 "$rc" "EV@C1 + verdict@R + HEAD@H con el mismo patch_id: PASA de punta a punta"
assert_contains "$out" "MISMO cambio" "y lo anuncia como reuso, no en silencio"

# con patch_id DISTINTO en el EV citado: rechazo legítimo con remediación
mk_ev_pid EV-TEST-cd4552b00001 impl-atlas "cd4552b" "PID-OTRO"
out="$(EV --commit "a4a8510" --reviewed-commit "523767e" \
        --verdict "$TD/verdict-atlas.json" --require-kind test)"; rc=$?
assert_eq 3 "$rc" "EV de OTRO cambio: sigue rechazando"
assert_contains "$out" "OTRO cambio" "y el mensaje ya dice la causa real"

echo "── las perillas de evidencia del policy dejaron de estar muertas"
out="$(python3 "$POLICY_PY" --policy "$POL" evidence-policy --field required_evidence_kinds)"
assert_eq "test" "$out" "required_evidence_kinds se LEE del policy"
python3 - "$POL" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["ship"]["required_evidence_kinds"] = ["test", "lint"]
json.dump(p, open(sys.argv[1], "w"))
PY
out="$(python3 "$POLICY_PY" --policy "$POL" evidence-policy --field required_evidence_kinds | tr '\n' ' ')"
assert_contains "$out" "lint" "editar la perilla cambia lo que se exige (antes no hacía nada)"

echo "── el presupuesto de rondas se cuenta por REPO"
# Antes era por TAREA: tres repos con UN fix normal cada uno agotaban el
# presupuesto y escalaban a humano sin que nada estuviera mal. El loop de un
# repo no dice nada sobre la convergencia de otro.
TD2="$WS/tasks/T2"; mkdir -p "$TD2"
python3 "$POLICY_PY" --policy "$POL" init "$TD2" --lane full >/dev/null 2>&1
TR() { python3 "$POLICY_PY" --policy "$POL" transition "$TD2" "$1" --actor o ${2:+--repo "$2"} 2>&1; }
TR rfc >/dev/null; TR implement >/dev/null
for r in atlas hermes proto; do
  TR review "$r" >/dev/null || fail "primera ronda de $r rechazada"
  TR implement >/dev/null
done
TR review atlas >/dev/null 2>&1 \
  && pass "3 repos con 1 ronda cada uno: el presupuesto NO se agota" \
  || fail "el presupuesto se agotó con una ronda por repo"
rounds="$(jq -r '.review_rounds_by_repo | to_entries | map("\(.key)=\(.value)") | join(",")' "$TD2/state.json")"
assert_contains "$rounds" "atlas=2" "cuenta las rondas de cada repo por separado"
assert_contains "$rounds" "hermes=1" "y no le cobra a hermes las de atlas"

# un repo que de verdad no converge sí se corta, y el mensaje lo aísla
TR implement >/dev/null; TR review atlas >/dev/null
TR implement >/dev/null
out="$(TR review atlas)"; rc=$?
assert_eq 3 "$rc" "un repo que no converge sí agota SU presupuesto"
assert_contains "$out" "repo atlas" "y el mensaje nombra al repo, no a la tarea"
assert_contains "$out" "no se ven afectados" "y aclara que los otros repos siguen"

echo "── con flow: prs no se archiva lo que todavia no mergeo (POLICY-SHIP-005)"
# Estaba en el prompt de /archive y solo ahi. La prosa no frena a nadie, que es
# la leccion que este repo ya aprendio en otros seis lugares. Archivar un PR
# abierto fusiona el delta-spec en la spec maestra: la spec pasa a describir
# algo que no existe. Es spec rot al reves, y mas dificil de ver que el normal
# porque la spec parece adelantada en vez de vieja.
TD3="$WS/tasks/T3"; mkdir -p "$TD3"
python3 "$POLICY_PY" --policy "$POL" init "$TD3" --lane full >/dev/null
for ph in rfc implement review; do
  python3 "$POLICY_PY" --policy "$POL" transition "$TD3" $ph --actor o >/dev/null
done
printf '%s\n' '{"repo":"web","sha":"aaa","branch":"task/T3","pr":"http://pr/1","landed":false}' > "$TD3/ship.log"
python3 "$POLICY_PY" --policy "$POL" transition "$TD3" ship --actor o >/dev/null
out="$(python3 "$POLICY_PY" --policy "$POL" transition "$TD3" deploy --actor o 2>&1)"; rc=$?
assert_eq 3 "$rc" "PR sin mergear: no se avanza a deploy"
assert_contains "$out" "POLICY-SHIP-005" "con su codigo propio"
assert_contains "$out" "web" "nombrando el repo que falta"
assert_contains "$out" "spec" "y explicando el costo real de archivarlo"

# Cuando el PR mergea, el ship.log registra la entrada aterrizada y se destraba
printf '%s\n' '{"repo":"web","sha":"bbb","landed":true}' >> "$TD3/ship.log"
python3 "$POLICY_PY" --policy "$POL" transition "$TD3" deploy --actor o >/dev/null 2>&1 \
  && pass "tras el merge, deploy se destraba" || fail "sigue trabado despues del merge"

# COMPAT: flow: trunk no escribe `landed`, y un campo AUSENTE no es false
# (confundir esas dos cosas fue justo el bug del // de jq)
TD4="$WS/tasks/T4"; mkdir -p "$TD4"
python3 "$POLICY_PY" --policy "$POL" init "$TD4" --lane full >/dev/null
for ph in rfc implement review; do
  python3 "$POLICY_PY" --policy "$POL" transition "$TD4" $ph --actor o >/dev/null
done
printf '%s\n' '{"repo":"api","sha":"ccc","short":"ccc"}' > "$TD4/ship.log"
python3 "$POLICY_PY" --policy "$POL" transition "$TD4" ship --actor o >/dev/null
python3 "$POLICY_PY" --policy "$POL" transition "$TD4" deploy --actor o >/dev/null 2>&1 \
  && pass "flow: trunk (sin campo landed) no se ve afectado" || fail "el gate rompio la compat con trunk"

# ── EL CABLEADO, NO SOLO LAS PIEZAS ───────────────────────────────────
# Los tres eslabones de la supervivencia al rebase (change-id.sh, la ventana de
# harness-policy.py, la equivalencia de evidence.py) estaban probados cada uno
# contra su codigo real, pero la funcion que los CONECTA no la ejecutaba nadie:
# en tests/test_ship_gates.sh gate_policy_and_evidence esta stubbeada, que es lo
# correcto ahi (mide el fan-out, no el gate) y dejaba el cable al aire.
#
# Lo que quedaba sin diente: borrar el `${pid:+--patch-id "$pid"}` o romper el
# `sed -n 's/^REVIEWED_COMMIT=//p'` deja la suite VERDE y devuelve el bucle
# ceremonial de POLICY-SHIP-002 a produccion. Fail-closed, si, pero el bug
# renace intacto. Aca se ejecuta la funcion REAL extraida del template, sobre
# git de verdad, con la base movida y el SHA reescrito por un rebase real.
echo "── el cableado de ship.sh: extraido del template y ejecutado de verdad"

SHIP_TMPL="$ROOT/templates/scripts/ship.sh.tmpl"
awk '/^gate_policy_and_evidence\(\) \{/{f=1} f{print} f&&/^\}/{exit}' \
  "$SHIP_TMPL" > "$WS/gate_pe.sh"
grep -q 'change-id.sh' "$WS/gate_pe.sh" \
  || fail "no pude extraer gate_policy_and_evidence del template"

# El workspace que la funcion espera: scripts/ REALES, no copias de mentira.
GWS="$WS/gws"; mkdir -p "$GWS/scripts" "$GWS/tasks/T9/evidence"
cp "$CHANGE_ID" "$GWS/scripts/change-id.sh"
cp "$POLICY_PY" "$GWS/scripts/harness-policy.py"
cp "$EVIDENCE_PY" "$GWS/scripts/evidence.py"
cp "$POL" "$GWS/harness-policy.json"
python3 - "$GWS/harness-policy.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["ship"]["required_evidence_kinds"] = ["test"]   # el test de arriba le metio lint
json.dump(p, open(sys.argv[1], "w"))
PY
cat > "$GWS/tasks/T9/state.json" <<'JSON'
{"schema":1,"task_id":"T9","phase":"review","lane":"full","review_rounds":1,
 "budget_usd":null,"spent_usd":0.0,
 "history":[{"from":"implement","to":"review","actor":"orchestrator"}]}
JSON

# Un worktree con el caso de campo entero: el reviewer sello sobre R, despues
# main avanzo con un commit ajeno (el "chore: Update image tag" del reporte) y
# el rebase reescribio el SHA sin tocar una linea de lo revisado.
GWT="$GWS/worktrees/T9/atlas"; mk_base "$GWT"
printf 'def f():\n    return 2\n\nHELPER = 0\n' > "$GWT/app.py"
g "$GWT" add -A; g "$GWT" commit -qm "el cambio de la tarea"
REVISADO="$(g "$GWT" rev-parse HEAD)"
PID_REAL="$(bash "$CHANGE_ID" "$GWT" main)"
g "$GWT" checkout -q -b upstream origin/main
printf 'image: v2\n' > "$GWT/deploy.yaml"
g "$GWT" add -A; g "$GWT" commit -qm "chore: Update image tag"
g "$GWT" update-ref refs/remotes/origin/main HEAD
g "$GWT" checkout -q - >/dev/null 2>&1
g "$GWT" rebase -q origin/main >/dev/null 2>&1
HEAD_NUEVO="$(g "$GWT" rev-parse HEAD)"
[ "$REVISADO" != "$HEAD_NUEVO" ] \
  && pass "el rebase reescribio el SHA (el caso de campo se reproduce)" \
  || fail "el fixture no movio el SHA: no prueba nada"

TD9="$GWS/tasks/T9"
jq -n --arg c "$REVISADO" --arg p "$PID_REAL" --arg t "$NOW" \
  '{schema:1, task_id:"T9", repo:"atlas", commit:$c, patch_id:$p, reviewed_at:$t,
    reviewer:"reviewer", implementation_agents:["impl-atlas"],
    verdict:"pass", qa:"pass", evidence:["EV-TEST-cableado0001"],
    blocking:[], non_blocking:[], docs_updated:true, compliance:[],
    requirements_uncovered:0, snapshots_updated_justified:true}' \
  > "$TD9/verdict-atlas.json"
# La evidencia citada quedo sellada en un TERCER SHA (el precheck del
# implementer, antes del review), que es lo que el reporte llama "huerfana":
# sobrevive solo si el cableado le pasa el REVIEWED_COMMIT que publico policy
# Y evidence.py resuelve la equivalencia por patch_id.
printf 'ok\n' > "$TD9/evidence/EV-TEST-cableado0001.log"
EVH="$(shasum -a 256 "$TD9/evidence/EV-TEST-cableado0001.log" | cut -d' ' -f1)"
jq -n --arg c "cd4552b0000000000000000000000000000000a" --arg p "$PID_REAL" --arg h "$EVH" \
  '{schema:1, id:"EV-TEST-cableado0001", task_id:"T9", repo:"atlas", kind:"test",
    runner:"impl-atlas", commit:$c, commit_after:$c, exit_code:0, patch_id:$p,
    output:"evidence/EV-TEST-cableado0001.log", output_sha256:$h}' \
  > "$TD9/evidence/EV-TEST-cableado0001.json"

corre_gate() {  # corre_gate <archivo-con-la-funcion> [worktree] [repo]
  local fn="$1" wt="${2:-$GWT}" repo="${3:-atlas}"
  ( cd "$wt" || exit 9
    WS="$GWS"; TASK=T9; REPO="$repo"; WT="$wt"; BASE_REF=main
    gate() { echo "── gate: $1 ──"; }
    # shellcheck disable=SC1090
    . "$fn"
    gate_policy_and_evidence 2>&1 )
}
out="$(corre_gate "$WS/gate_pe.sh")"; rc=$?
assert_eq 0 "$rc" "el gate real pasa con el SHA reescrito por el rebase"
assert_contains "$out" "veredicto reusado" "el cableado SI le pasa --patch-id a policy"
assert_contains "$out" "MISMO cambio" "y evidence.py recibe el REVIEWED_COMMIT que policy publico"

# El diente: si alguien corta el cable del patch_id, esto tiene que ponerse rojo.
# Sin esta mutacion el bloque de arriba pasaria igual con el cable cortado, y un
# test que no puede fallar no prueba nada (la misma ley que gate_test_muerde).
sed 's/\${pid:+--patch-id "\$pid"}//' "$WS/gate_pe.sh" > "$WS/gate_pe_roto.sh"
cmp -s "$WS/gate_pe.sh" "$WS/gate_pe_roto.sh" \
  && fail "la mutacion no cambio nada: el test no puede morder" \
  || pass "la mutacion corta el cable de verdad"
out="$(corre_gate "$WS/gate_pe_roto.sh")" || true
assert_not_contains "$out" "veredicto reusado" "cortar el cable del patch_id SI rompe el gate (el test muerde)"
assert_contains "$out" "falta --patch-id" "y el rojo nombra el cable cortado"

# ── CUANDO NO HAY IDENTIDAD, EL ROJO TIENE QUE DECIR POR QUE ──────────
# change-id.sh sabe exactamente por que no pudo calcular el id (diff vacio, o
# no existe origin/<base>) y lo dice por stderr, pero el gate lo tiraba a
# /dev/null. El operador se quedaba con "POLICY-SHIP-002: falta --patch-id",
# que nombra el sintoma y no la causa, y encima suena a bug del harness cuando
# suele ser un worktree sin commits propios. La ley de la casa es que el
# mensaje de un gate es un prompt: causa + remediacion, no solo el codigo.
GWT2="$GWS/worktrees/T9/vacio"; mk_base "$GWT2"   # HEAD == origin/main: sin cambio
jq -n --arg t "$NOW" \
  '{schema:1, task_id:"T9", repo:"vacio", commit:"0000000000000000000000000000000000000000",
    patch_id:"PID-CUALQUIERA", reviewed_at:$t, reviewer:"reviewer",
    implementation_agents:["impl"], verdict:"pass", qa:"pass", evidence:[],
    blocking:[], non_blocking:[], docs_updated:true, compliance:[],
    requirements_uncovered:0, snapshots_updated_justified:true}' \
  > "$TD9/verdict-vacio.json"
out="$(corre_gate "$WS/gate_pe.sh" "$GWT2" vacio)" || true
assert_contains "$out" "vacío" "sin identidad de cambio, el gate DICE la causa (no solo el codigo)"
assert_contains "$out" "patch_id" "y nombra lo que no pudo calcular"

t_done
