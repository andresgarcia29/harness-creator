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
assert_contains "$rfc" '"schema": 2' "y da el esquema exacto, no una descripción"
assert_contains "$rfc" '"files"' "incluido files[], que es lo que POLICY-DAG-011 exige"
assert_contains "$rfc" "DAG-011" "y la regla que lo hace obligatorio"
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

# Y el ejemplo de schema 2 que /rfc imprime, TAL CUAL: dos nodos del mismo repo
# en paralelo por files[] disjuntos. Si ese ejemplo no pasara, el prompt estaría
# enseñando a escribir un DAG que el gate rechaza.
cat > "$tmp/dag2.json" <<'JSON'
{"schema": 2,
 "tasks": [{"id": "T1", "repo": "atlas", "depends_on": [],
            "files": ["internal/ratelimit/limiter.go"]},
           {"id": "T2", "repo": "atlas", "depends_on": [],
            "files": ["internal/http/middleware.go"]},
           {"id": "T3", "repo": "proto", "depends_on": ["T1"],
            "files": ["gateway/v1/limits.proto"]}]}
JSON
python3 "$root/templates/scripts/harness-policy.py" --policy "$tmp/pol.json" \
  validate-dag "$tmp/dag2.json" >/dev/null 2>&1 \
  && pass "y el ejemplo de schema 2 (paralelo intra-repo) también" \
  || fail "el ejemplo de schema 2 de /rfc no pasa el validador"

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
echo "── 'el test tiene que morder': el gate lo exige, así que los prompts lo piden"
# La lección de c767363 (el gate exige lo que ningún prompt pidió) aplicada al
# gate más nuevo: gate_test_muerde corre cada test NUEVO contra el árbol base y
# se pone rojo si pasa en los dos. Quien escribe el test tiene que enterarse
# ANTES de escribirlo, o el mecanismo se descubre por el mensaje del gate: una
# ronda por implementer, que es justo la ronda que este gate vino a ahorrar.
assert_contains "$ship_src" "gate_test_muerde" "el gate existe en ship.sh (si no, esto exigiría prosa sin diente)"
for c in implement quick smart; do
  assert_contains "$(cmd "$c")" "gate_test_muerde" "/$c nombra el gate que va a correr sus tests contra la base"
done
# El texto exacto varía por comando (implement habla del contexto del
# implementer, quick de vos mismo), así que se exige la REGLA, no una frase
# copiada: el test tiene que fallar sin el fix, y el precheck lo comprueba.
impl="$(cmd implement)"; qk="$(cmd quick)"; sm="$(cmd smart)"
assert_contains "$impl" "FALLAR sin el fix" "/implement pasa la regla del rojo primero al implementer"
assert_contains "$impl" "los dos árboles" "y dice cuál es el rojo (pasar en base y en HEAD)"
assert_contains "$qk" "FALLE sin tu fix" "/quick la pide en el paso de implementar"
assert_contains "$qk" "árbol base" "nombrando el árbol contra el que se comprueba"
assert_contains "$sm" "FALLE sin el fix" "/smart la pide donde instruye la implementación"
assert_contains "$sm" "árbol base" "con el mismo mecanismo, no una versión propia"
# Y el opt-in del delta-spec: nombrar un test bajo ADDED lo mete al chequeo
# aunque el archivo ya existiera. Sin esta línea, el paso que escribe el
# delta-spec no sabe que ese basename tiene consecuencias ejecutables.
assert_contains "$qk" "bajo \`ADDED\` lo mete" "/quick dice que nombrar el basename bajo ADDED mete el test al chequeo"
assert_contains "$qk" "aunque ese archivo ya existiera" "y que vale para un archivo existente"

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

echo
echo "── la entrega es un DATO que declara la invocación, no una pregunta al chat"
# El dolor real: el agente terminaba de implementar y preguntaba "no commiteé ni
# shippeé, ¿lo llevo por /review + ship?". La invocación YA había contestado eso,
# pero en ninguna parte quedaba escrito, así que la decisión se re-litigaba al
# final, con el humano lejos. Ahora la entrega es el campo `delivery` de
# state.json y lo declara el init. Este bloque ata cada entrada a lo que
# registra: un comando que promete una entrega y no la registra deja al ship
# decidiendo por el flow del workspace, que es justo la conducta vieja.
smart="$(cmd smart)"
assert_contains "$smart" "--repos <repo1,repo2> --delivery review" \
  "el init de /smart declara --delivery review en el MISMO comando, no en un párrafo aparte"
assert_contains "$smart" "delivery: review" "/smart nombra el valor que queda en state.json"
assert_contains "$smart" "PUBLICA NADA" "y declara arriba que no publica"
assert_contains "$smart" "Commits locales en el worktree SÍ" \
  "sin prohibir los commits locales, que son los que sostienen precheck, evidencia y review"

# Los wrappers: cada uno nombra SU entrega y el archivo al que delega. Sin las
# dos cosas no es un wrapper, es un comando huérfano que el agente completa a
# ojo.
pr="$(cmd smart-pr)"
mn="$(cmd smart-main)"
assert_contains "$pr" "--delivery prs" "/smart-pr registra su entrega en el init"
assert_contains "$pr" 'commands/smart.md' "/smart-pr nombra el archivo al que delega, con su ruta"
assert_contains "$mn" "--delivery trunk" "/smart-main registra su entrega en el init"
assert_contains "$mn" 'commands/smart.md' "/smart-main nombra el archivo al que delega, con su ruta"

# Lo que los tres comandos mandan correr tiene que EXISTIR y aceptar lo que
# prometen. Sin esto, "--delivery review" y el "go" auditable son dos frases
# bonitas y el agente descubre por el error de argparse que el paso 0.2 le pidió
# un flag que nadie implementó.
dws="$tmp/dws"
mkdir -p "$dws/tasks/SMART-uno"
dout="$(python3 "$polpy" --policy "$tmp/pol.json" init "$dws/tasks/SMART-uno" \
  --lane express --repos atlas --delivery review 2>&1)"
drc=$?
if [ "$drc" -eq 0 ]; then
  assert_contains "$dout" "delivery=review" "init acepta --delivery review y lo declara (es el comando del paso 0.2)"
else
  fail "init --delivery review salió $drc: el paso 0.2 de /smart manda correr algo que no funciona · $dout"
fi
dout="$(python3 "$polpy" --policy "$tmp/pol.json" delivery "$dws/tasks/SMART-uno" \
  --to prs --actor humano 2>&1)"
drc=$?
if [ "$drc" -eq 0 ]; then
  assert_contains "$dout" "review → prs" "el 'go' del reporte es una transición que el motor ejecuta de verdad"
else
  fail "delivery --to prs salió $drc: el reporte final de /smart imprime un comando que no corre · $dout"
fi

# La remediación del exit 8 va DONDE el humano la va a leer: el reporte final.
# En cualquier otra sección es una nota que nadie abre cuando la necesita.
rep="$(printf '%s\n' "$smart" | awk '/^## Reporte final/{f=1} f{print}')"
if [ -z "$rep" ]; then
  fail "no encontré la sección del reporte final en smart.md: sin ella no puedo verificar dónde queda la remediación del exit 8, y esto NO es verde"
else
  assert_contains "$rep" "exit 8" "el reporte de /smart nombra el código con que ship.sh se niega a publicar"
  assert_contains "$rep" "delivery tasks/<id> --to prs" "y el comando literal para pasar a rama + PR"
  assert_contains "$rep" "delivery tasks/<id> --to trunk" "y el de ir directo a la trunk"
  assert_contains "$rep" "ship.sh <id> <repo>" "con el ship que va DESPUÉS: son dos comandos, no uno"
  assert_contains "$rep" "worktrees/<id>/<repo>" "y dice dónde quedó el trabajo, para no buscarlo a mano"
fi

# El otro extremo del contrato lo implementa ship.sh. Mientras ese carril no
# aterrice, esto no es verde ni rojo: es "no pude mirar", declarado.
ship_tmpl="$(cat "$root/templates/scripts/ship.sh.tmpl")"
case "$ship_tmpl" in
  *"exit 8"*)
    assert_contains "$ship_tmpl" "delivery" \
      "ship.sh se niega a publicar por la entrega declarada, que es el 8 que el reporte promete" ;;
  *)
    echo "  ! no pude mirar: ship.sh.tmpl todavía no asigna exit 8, así que la remediación"
    echo "    que /smart imprime no tiene aún su contraparte ejecutable. NO es un verde:"
    echo "    es que la mitad del contrato (el gate) sigue sin existir." ;;
esac

echo
echo "── ampliar el alcance: el prompt manda un comando que el motor tiene"
# Caso de campo: el enrichment descubrió que el bug vivía también en otros dos
# repos; worktree-task.sh los aceptó, pero state.repos quedó con tres de cinco
# y la fase avanzó a ship sin el veredicto del repo nuevo. init no se re-corre
# y editar state.json a mano está prohibido: si el prompt no nombra la vía
# registrada, el orquestador vuelve a la edición a mano.
assert_contains "$smart" "harness-policy.py repos" \
  "/smart manda registrar el repo descubierto por el comando, no a mano"
assert_contains "$pol_src" "POLICY-REPOS-002" \
  "y el motor declara el rechazo de sumar un repo cuando ya no hay review posible"

echo
echo "── el árbol compartido: cada regla nueva tiene su diente y su prompt"
# Dos bugs de campo por lo mismo: agentes concurrentes sobre un árbol mutable.
# (1) el reviewer mutó src/ para verificar mientras QA medía sobre ese árbol;
# (2) dos implementers del mismo repo compartieron worktree y el `git add`
# amplio de uno se llevó seis archivos del otro. Acá se ata cada prosa a su
# mecanismo: una regla que solo vive en el prompt se erosiona sin que nadie
# lo note, y un mecanismo que ningún prompt explica se lee como un bug.

rev="$(cat "$root/templates/agents/reviewer.md.tmpl")"
assert_contains "$rev" ".review-" \
  "el reviewer trabaja sobre el ÁRBOL CLAVADO, y su prompt lo nombra"
assert_contains "$rev" "verificación por mutación" \
  "y tiene prohibida la mutación sobre árboles compartidos"
assert_contains "$rev" "gate_test_muerde" \
  "con la alternativa que YA existe y corre aislada"
assert_contains "$rev" "worktree add --detach" \
  "y la sonda descartable para cuando de verdad haga falta"
assert_contains "$(cat "$root/templates/hooks/guard-canonical.sh")" ".review-" \
  "y el hook lo hace cumplir (la prosa sola no frena a nadie)"

qa="$(cat "$root/templates/agents/qa.md.tmpl")"
assert_contains "$qa" "status --porcelain" \
  "QA comprueba la identidad del ÁRBOL antes de medir"
assert_contains "$qa" "CONTAMINADA" \
  "y sabe qué hacer si aparece suciedad a mitad de corrida"

impl="$(cat "$root/templates/agents/implementer.md.tmpl")"
assert_contains "$impl" "git add -A" \
  "el implementer tiene prohibido el add amplio"
assert_contains "$impl" "guard-broad-add" \
  "y sabe que hay un hook que lo bloquea"
assert_contains "$(cat "$root/templates/settings.json.tmpl")" "guard-broad-add.sh" \
  "que está registrado de verdad (si no, es un hook que nunca corre)"

# La premisa FALSA que originó el bug: 'cada tarea tiene su worktree'.
rfc="$(cat "$root/templates/commands/rfc.md.tmpl")"
assert_not_contains "$rfc" "cada tarea tiene su worktree" \
  "rfc.md ya no afirma la premisa falsa que justificaba el paralelo intra-repo"
assert_contains "$rfc" "POLICY-DAG-010" \
  "y cita el gate que rechaza el plan sin ordenar"
arch="$(cat "$root/templates/agents/architect.md.tmpl")"
assert_contains "$arch" "POLICY-DAG-010" \
  "el architect, que es quien escribe el DAG, también lo cita"
assert_contains "$(cat "$root/templates/scripts/harness-policy.py")" "POLICY-DAG-010" \
  "y el código lo implementa de verdad"

t_done
