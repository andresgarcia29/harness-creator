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
# /smart que lo invoca: ningún prompt lo nombraba ni definía su esquema, así
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
# /smart y /review la movían; feature, rfc, implement, ship y archive no la
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
smart="$(cmd smart)"
assert_contains "$smart" "MODIFIED Requirements" "/smart enseña la sección que el gate acepta"
assert_contains "$smart" "nombre el archivo de test" "y que hay que nombrar el archivo"
assert_contains "$smart" "prosa no abre nada" "y que la palabra suelta en prosa no sirve"

# Lo que /smart enseña tiene que ser lo que el gate acepta de verdad.
ship_src="$(cat "$root/templates/scripts/ship.sh.tmpl")"
assert_contains "$ship_src" "MODIFIED|REMOVED" "el gate sigue aceptando exactamente esas dos secciones"

echo
echo "── reviewer persistente: prompt del loop, prompt del agente y mecanismo, alineados"
revd="$(cat "$root/templates/agents/reviewer.md.tmpl")"
scaffold="$(cat "$root/templates/scripts/verdict-scaffold.sh")"
assert_contains "$(cmd review)" "MISMO agente" "/review ordena continuar el mismo reviewer en ronda ≥2"
assert_contains "$(cmd review)" "MISMA identidad" "/review dice cómo relanzar tras una muerte"
assert_contains "$revd" "SIN memoria" "reviewer.md tiene el modo agente-nuevo"
assert_contains "$revd" "rebased_from" "y sabe de qué campo sale su base"
assert_contains "$scaffold" "rebased_from" "el campo que el prompt promete lo persiste de verdad el scaffold"
assert_contains "$(cmd smart)" "ronda siguiente ≠ agente nuevo" "la ley del watchdog quedó acotada, no derogada"
assert_contains "$(cmd smart)" "~3 min" "y el heartbeat sigue siendo ley"

echo
echo "── el delta viaja al reviewer: prompt y mecanismo"
assert_contains "$(cmd review)" "delta_files" "/review nombra el campo persistido"
assert_contains "$scaffold" "delta_files" "y el scaffold lo escribe de verdad"
assert_contains "$revd" "delta_files" "y el reviewer sin memoria sabe leerlo"

echo
echo "── merge-qa y rebase puro: los comandos que el prompt promete existen"
assert_contains "$(cmd review)" "merge-qa" "/review invoca el merge mecánico por comando"
assert_contains "$scaffold" "merge_qa" "y el scaffold lo implementa"
assert_contains "$(cmd review)" "rebase PURO" "/review distingue el rebase puro (no corras nada)"
assert_contains "$scaffold" "nada que rebasear" "y el scaffold lo detecta solo"

echo
echo "── non_blocking → beads: la cadena queda anclada en AMBOS extremos"
assert_contains "$(cmd review)" "verdict-beads.sh" "/review nombra el comando"
assert_contains "$(cmd archive)" "POLICY-ARCHIVE-002" "/archive nombra el gate"
assert_contains "$revd" "bead" "reviewer.md documenta las dos formas de entrada"
assert_contains "$(cat "$root/templates/scripts/harness-policy.py")" "POLICY-ARCHIVE-002" \
  "y el gate existe en el motor (afirmada en 4 archivos, ejecutada en 1 por fin)"

echo
echo "── \"Read-only sobre código\" deja de ser prosa: el frontmatter lo declara"
# El description del reviewer prometía read-only y el frontmatter no traía
# `tools:`, así que el agente arrancaba con el set COMPLETO (Write incluido):
# la promesa vivía en una frase que nada leía. El flujo real no crea ningún
# archivo (verdict-scaffold.sh deja el esqueleto y el reviewer lo EDITA), así
# que Write y NotebookEdit sobran y su ausencia sí es verificable.
# Solo el frontmatter cuenta: `tools:` en el cuerpo no configura nada, por eso
# el awk corta en el segundo `---`.
rev_tools="$(awk 'NR>1 && /^---$/ {exit} /^tools:/ {print; exit}' \
  "$root/templates/agents/reviewer.md.tmpl")"
assert_contains "$rev_tools" "tools:" "el reviewer declara tools: en su frontmatter"
assert_not_contains "$rev_tools" "Write" "sin Write: el reviewer no CREA ningún archivo"
assert_not_contains "$rev_tools" "NotebookEdit" "ni NotebookEdit, por la misma razón"
# Lo que el flujo SÍ exige: leer código, buscar, correr git diff y editar el
# veredicto. Quitar cualquiera de estos deja al reviewer sin poder hacer su
# trabajo, que es la otra mitad de este contrato.
for t in Read Grep Glob Bash Edit; do
  assert_contains "$rev_tools" "$t" "conserva $t, que el flujo de review exige"
done
# Edit sin Write solo se sostiene si el prompt sigue diciendo que el archivo
# YA existe: si alguien vuelve a pedirle que regenere el JSON, el set mínimo
# lo deja atascado sin decir por qué. (La aserción de NotebookEdit de arriba
# garantiza que este `*Edit*` es el Edit pelado.)
case "$rev_tools" in
  *Edit*) assert_contains "$revd" "EDITA el archivo, no lo reescribas" \
            "y el cuerpo sigue ordenando EDITAR, que es lo que Edit sin Write permite" ;;
  *) fail "sin Edit el reviewer no puede tocar el veredicto: revisá el set mínimo" ;;
esac
# El campo no es una garantía total y el prompt no debe venderla: `tools:`
# filtra herramientas, no rutas.
assert_contains "$revd" "no rutas" "el cuerpo admite que tools: no distingue rutas"
assert_contains "$revd" "POLICY-ROLE-001/002/003" "y nombra la barrera DURA que sí es ejecutable"
assert_contains "$(cat "$root/templates/scripts/harness-policy.py")" "POLICY-ROLE-003" \
  "que existe de verdad en el motor (el reviewer no puede ser implementador)"

echo
echo "── /quick: el carril que recorta prosa nombra CADA gate que le van a exigir"
# La lección de c767363 aplicada al carril más corto. quick no tiene architect
# ni RFC que expliquen el contrato de paso, así que todo lo que ship.sh y
# policy le van a pedir tiene que estar en su playbook o se descubre por el
# mensaje del gate: una ronda por mecanismo, y el carril "rápido" termina
# siendo el más caro. Este bloque recorre quick.md igual que los de arriba
# recorren a los demás comandos: exigencia por exigencia, con su gate.
quick="$(cmd quick)"
pol_src="$(cat "$root/templates/scripts/harness-policy.py")"

assert_contains "$quick" "gate_trailer" "/quick nombra el gate del trailer"
assert_contains "$quick" "Task: <id>" "y dice cuál es, desde el primer commit"
assert_contains "$quick" "gate_tests_untouched" "/quick nombra el gate de tests debilitados"
assert_contains "$quick" "MODIFIED Requirements" "y la sección que ese gate acepta como declaración"
assert_contains "$quick" "nombra el archivo de test" "y que hay que nombrar el archivo"
assert_contains "$quick" "prosa no abre nada" "y que la palabra suelta en prosa no declara nada"
assert_contains "$quick" "POLICY-ROLE-002" "/quick nombra el gate de la evidencia de implementación"
assert_contains "$quick" "--runner implementer" "y cómo sellarla si el precheck no pudo"
assert_contains "$quick" "--precheck" "/quick pasa el precheck antes de gastar reviewer"
assert_contains "$quick" "verificado" "y lee cuánto se miró (un ok:true no siempre es un verde verificado)"
assert_contains "$quick" "POLICY-ROLE-001/002/003" "/quick sabe que el reviewer independiente no se negocia"
assert_contains "$quick" "gate_evidence" "/quick nombra el gate que audita la compliance matrix"
assert_contains "$quick" "requirements_uncovered" "y el campo que el veredicto tiene que traer en cero"
assert_contains "$quick" "--runner qa" "/quick usa el QA determinista de /review, con su runner"
assert_contains "$quick" "verdict-scaffold.sh" "y el scaffold que escribe los campos mecánicos"
assert_contains "$quick" "verdict-beads.sh" "y manda los non_blocking a beads, no a otra ronda"
assert_contains "$quick" "harness-policy.py init tasks/<id> --lane quick" "/quick abre el estado con su carril"
assert_contains "$quick" "transition tasks/<id> implement" "y pide la transición que el carril permite"
# `review → ship` cambió de dueño a propósito (la pide ship.sh tras el push).
# Un playbook que la duplica devuelve el rechazo de policy sin decir quién se
# adelantó, que es justo el fallo que ese cambio de dueño vino a cerrar.
assert_contains "$quick" "ya la registró" "/quick no duplica review → ship"
assert_not_contains "$quick" "transition tasks/<id> ship" "y no la pide por su cuenta"
assert_contains "$quick" "gate_lane" "/quick nombra el gate que verifica su promesa de tamaño"
assert_contains "$quick" "escalate tasks/<id> --to express" "con la remediación exacta cuando el diff no cabe"
assert_contains "$quick" "lane-limits quick" "y de dónde salen los techos (el policy, no una copia en prosa)"
assert_contains "$quick" "POLICY-LANE-005" "/quick nombra el rechazo del multi-repo"
assert_contains "$pol_src" "POLICY-LANE-005" "que existe en el motor (quick es de UN repo, y lo hace cumplir init)"

# Lo que el playbook manda correr tiene que existir y aceptar lo que promete.
# Sin esto, "quick es de UN repo" y "el techo lo lee el gate" son dos frases:
# quien las hace verdad es el motor, y este test las ejecuta.
polpy="$root/templates/scripts/harness-policy.py"
qws="$tmp/qws"
mkdir -p "$qws/tasks/QUICK-uno" "$qws/tasks/QUICK-dos"
# La salida se CAPTURA con su stderr y se imprime al fallar: un `2>/dev/null`
# acá convertiría "el motor rechazó por otro motivo" en "el motor rechazó",
# que es la clase de silencio que estos tests existen para no tener.
qout="$(python3 "$polpy" --policy "$tmp/pol.json" lane-limits quick 2>&1)"
qrc=$?
if [ "$qrc" -eq 0 ]; then
  assert_contains "$qout" "max_files=" "el comando de techos que /quick nombra existe y el carril los declara"
else
  fail "lane-limits quick salió $qrc: /quick promete un techo que nadie puede leer · $qout"
fi
qout="$(python3 "$polpy" --policy "$tmp/pol.json" init "$qws/tasks/QUICK-uno" \
  --lane quick --repos atlas 2>&1)"
qrc=$?
if [ "$qrc" -eq 0 ]; then
  pass "init acepta el carril quick con UN repo (es el comando del paso 2)"
else
  fail "init --lane quick salió $qrc: el paso 2 manda correr algo que no funciona · $qout"
fi
qout="$(python3 "$polpy" --policy "$tmp/pol.json" init "$qws/tasks/QUICK-dos" \
  --lane quick --repos atlas,hermes 2>&1)"
qrc=$?
if [ "$qrc" -eq 3 ]; then
  assert_contains "$qout" "POLICY-LANE-005" "y rechaza el segundo repo con el código que el playbook cita"
else
  fail "init --lane quick con dos repos salió $qrc: 'quick es de UN repo' es solo una frase · $qout"
fi
qout="$(python3 "$polpy" --policy "$tmp/pol.json" transition "$qws/tasks/QUICK-uno" implement \
  --actor orchestrator 2>&1)"
qrc=$?
if [ "$qrc" -eq 0 ]; then
  pass "el carril permite intake → implement sin pasar por rfc, como promete el paso 2"
else
  fail "transition intake → implement salió $qrc en quick: el paso 2 promete un camino cerrado · $qout"
fi

t_done
