#!/usr/bin/env bash
# test_prompt_gate_contract.sh: ningún gate puede exigir algo que el prompt
# del responsable no pide.
#
# El bug que abrió esta familia: ship.sh exigía evidencia corrida por un
# implementer (POLICY-ROLE-002) y templates/agents/implementer.md.tmpl no
# mencionaba la evidencia en ninguna de sus líneas. El gate tenía razón, el
# agente también, y el defecto estaba en el medio: se le pedía cumplir un
# contrato que nadie le comunicó.
#
# Este test recorre los gates que exigen un artefacto o una transición y
# comprueba que su productor esté enterado.
set -u
. "$(dirname "$0")/lib.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"

cmd() { cat "$root/templates/commands/$1.md.tmpl"; }

echo "── dag.json: lo exige validate-dag, así que alguien tiene que crearlo"
# Antes, las ÚNICAS menciones en todo el repo eran el validador y la línea de
# /auto que lo invoca: ningún prompt lo nombraba ni definía su esquema, así
# que toda corrida standard/full llegaba al cierre del RFC sin el archivo.
rfc="$(cmd rfc)"
assert_contains "$rfc" "dag.json" "/rfc nombra el artefacto que el gate exige"
assert_contains "$rfc" '"schema": 1' "y da el esquema exacto, no una descripción"
assert_contains "$rfc" "depends_on" "con el campo de dependencias"
assert_contains "$rfc" "DAG-007" "y las reglas que el validador hace cumplir"
assert_contains "$(cat "$root/templates/agents/architect.md.tmpl")" "dag.json" \
  "el architect, que es quien traza el DAG, sabe que va también en JSON"

# El esquema documentado tiene que ser el que el validador acepta de verdad.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sed 's/{{LOOP_BUDGET}}/3/' "$root/templates/policy.json.tmpl" > "$tmp/pol.json"
cat > "$tmp/dag.json" <<'JSON'
{"schema": 1,
 "tasks": [{"id": "T1", "repo": "atlas",  "depends_on": []},
           {"id": "T2", "repo": "proto",  "depends_on": ["T1"]}]}
JSON
python3 "$root/templates/scripts/harness-policy.py" --policy "$tmp/pol.json" \
  validate-dag "$tmp/dag.json" >/dev/null 2>&1 \
  && pass "el esquema que /rfc documenta PASA el validador de verdad" \
  || fail "la doc y el validador no coinciden: el productor seguiría a ciegas"

echo
echo "── la máquina de fases: el flujo manual también tiene que moverla"
# /auto y /review la movían; feature, rfc, implement, ship y archive no la
# mencionaban ni una vez, así que el flujo manual moría en policy con un
# mensaje que no decía cuál de los comandos anteriores se la había saltado.
for c in feature rfc implement review ship archive; do
  assert_contains "$(cmd "$c")" "harness-policy.py" "/$c mueve la fase que le toca"
done
assert_contains "$(cmd feature)" "harness-policy.py init" "/feature abre el estado"
assert_contains "$(cmd rfc)" "transition tasks/\$ARGUMENTS rfc" "/rfc pide intake → rfc"
assert_contains "$(cmd implement)" "implement --actor" "/implement pide su transición"
# `review → ship` cambio de dueño A PROPOSITO: la pide ship.sh tras el push, no
# el prompt. Era la transicion que el orquestador se olvidaba, y entonces
# state.json quedaba en `review` con el codigo ya en main. Lo que el contrato
# exige ahora es que la pida el HECHO y que el prompt NO la duplique.
assert_contains "$(cat "$ROOT/templates/scripts/ship.sh.tmpl")" "transition \"\$WS/tasks/\$TASK\" ship" \
  "ship.sh pide review → ship el mismo, tras el push"
assert_contains "$(cmd ship)" "ya la registró" "y /ship le dice al orquestador que no la duplique"
assert_contains "$(cmd archive)" "archive --actor" "/archive pide deploy → archive"

# El ORDEN importa: pedir review → ship antes de shippear todos los repos es
# justo la trampa que POLICY-SHIP-004 rechaza.
sh="$(cmd ship)"
assert_contains "$sh" "DESPUÉS de que TODOS los repos" "/ship advierte que la fase va al final"
assert_contains "$sh" "POLICY-SHIP-004" "y nombra el gate que lo rechaza si te adelantas"

echo
echo "── el delta-spec express y el gate de tests hablaban idiomas distintos"
# gate_tests_untouched solo acepta declaraciones bajo MODIFIED/REMOVED, pero
# el paso que escribe el delta-spec express solo pedía ADDED. Una tarea
# express que cambiaba un test legítimamente quedaba roja, y su autor nunca
# supo que el mecanismo de declaración existía.
auto="$(cmd auto)"
assert_contains "$auto" "MODIFIED Requirements" "/auto enseña la sección que el gate acepta"
assert_contains "$auto" "nombre el archivo de test" "y que hay que nombrar el archivo"
assert_contains "$auto" "prosa no abre nada" "y que la palabra suelta en prosa no sirve"

# Lo que /auto enseña tiene que ser lo que el gate acepta de verdad.
ship_src="$(cat "$root/templates/scripts/ship.sh.tmpl")"
assert_contains "$ship_src" "MODIFIED|REMOVED" "el gate sigue aceptando exactamente esas dos secciones"

t_done
