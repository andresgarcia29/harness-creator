#!/usr/bin/env bash
# test_lane_triado.sh: el carril que salta la SESIÓN del architect, no sus gates.
#
# Un carril nuevo es una promesa repartida en cuatro archivos: el policy (qué
# transiciones tiene), el prompt (cuándo se elige), ship.sh (qué verifica igual)
# y el motor (qué rechaza). Si uno de los cuatro no se enteró, el carril existe
# a medias y lo descubre una corrida en producción. Esto los ata.
set -u
. "$(dirname "$0")/lib.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"

t_ws
mkdir -p "$WS/scripts" "$WS/tasks"
cp "$root/templates/scripts/harness-policy.py" "$WS/scripts/"
sed 's/{{LOOP_BUDGET}}/3/' "$root/templates/policy.json.tmpl" > "$WS/harness-policy.json"
pol() { python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" "$@" 2>&1; }

echo "── el policy declara el carril y su escalera"
assert_eq "true" "$(jq '.workflow.lanes | has("triado")' "$WS/harness-policy.json")" \
  "workflow.lanes.triado existe"
assert_eq '["implement"]' \
  "$(jq -c '.workflow.lanes.triado.allowed_transitions.intake' "$WS/harness-policy.json")" \
  "su intake va derecho a implement: eso, y solo eso, es lo que el carril recorta"
assert_eq "false" \
  "$(jq '.workflow.lanes.triado.allowed_transitions | has("rfc")' "$WS/harness-policy.json")" \
  "y no hay fase rfc en su grafo"
assert_eq "2" "$(jq -r '.workflow.lane_escalation | index("triado")' "$WS/harness-policy.json")" \
  "y vive entre express y standard en la escalera"

echo
echo "── una tarea triado arranca y avanza sin pasar por rfc"
mkdir -p "$WS/tasks/T-OK"
out="$(cd "$WS" && pol init tasks/T-OK --lane triado --repos atlas --delivery review)"
assert_contains "$out" "lane=triado" "init acepta el carril"
out="$(cd "$WS" && pol transition tasks/T-OK implement --actor test)"
assert_contains "$out" "implement" "intake → implement, sin architect de por medio"

echo
echo "── pero es de UN repo: la evidencia del triage cubre el código que miró"
mkdir -p "$WS/tasks/T-DOS"
out="$(cd "$WS" && pol init tasks/T-DOS --lane triado --repos atlas,hermes --delivery review)"; rc=$?
assert_eq 3 "$rc" "dos repos no pasan"
assert_contains "$out" "POLICY-LANE-006" "con código propio"
assert_contains "$out" "archivo:símbolo" "y el motivo REAL: la evidencia, no el DAG"
assert_no_file "$WS/tasks/T-DOS/state.json" "y no deja la tarea a medio abrir"

echo
echo "── escalar a standard devuelve la deliberación que el carril saltó"
out="$(cd "$WS" && pol escalate tasks/T-OK --to standard --actor test --reason "decisión no obvia")"
assert_contains "$out" "triado → standard" "escala hacia arriba"
assert_eq "rfc" "$(jq -r '.phase' "$WS/tasks/T-OK/state.json")" \
  "y vuelve a rfc: la deliberación saltada se recupera, el trabajo no se pierde"

echo
echo "── ship.sh lo verifica con la MISMA vara que express"
ship="$(cat "$root/templates/scripts/ship.sh.tmpl")"
assert_contains "$ship" "express|quick|triado)" \
  "gate_lane incluye triado en la lista de carriles que verifica"
# La prueba de que no es cosmético: el gate extraído tiene que morder.
tmp="$WS/gate"; mkdir -p "$tmp"
awk '/^gate_lane\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' \
  "$root/templates/scripts/ship.sh.tmpl" > "$tmp/gate_lane.sh"
cat > "$tmp/correr.sh" <<'SH'
set -u
gate() { :; }
WS="$TWS"; TASK="$TT"; BASE_REF=main
git() {
  case "$*" in
    *"--name-only"*) printf 'proto/api.proto\n' ;;
    *) : ;;
  esac
}
jq() { printf '%s' "$LANE"; }
. "$GATE"
gate_lane
SH
mkdir -p "$WS/tasks/T-GATE"
probar_gate() {  # probar_gate <carril> → salida del gate
  ( export TWS="$WS" TT=T-GATE GATE="$tmp/gate_lane.sh" LANE="$1"
    bash "$tmp/correr.sh" 2>&1 )
}
out="$(probar_gate triado)"; rc=$?
assert_eq 3 "$rc" "un diff de triado que toca un .proto NO pasa"
assert_contains "$out" "carril triado" "y lo dice por su nombre"
out="$(probar_gate standard)"; rc=$?
assert_eq 0 "$rc" "standard no pasa por acá (ahí el .proto ya se discutió)"

echo
echo "── y el prompt sabe cuándo elegirlo (un carril sin dueño no se usa nunca)"
smart="$(cat "$root/templates/commands/smart.md.tmpl")"
assert_contains "$smart" "| **triado** |" "está en la tabla de carriles"
assert_contains "$smart" "archivo:símbolo" "con la señal que lo habilita"
assert_contains "$smart" "El carril \`triado\`" "y su sección con lo que escribe el orquestador"
assert_contains "$smart" "validate-dag" "que incluye el DAG: triado planifica N tareas, no una"
assert_contains "$smart" "--lane <quick|express|triado|standard|full>" \
  "y el init lo ofrece (con quick, que el router ya clasifica solo)"

t_done
