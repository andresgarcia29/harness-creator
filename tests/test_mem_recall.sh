#!/usr/bin/env bash
# test_mem_recall.sh: la memoria episodica se LEE, no solo se escribe (#101).
#
# CASO DE CAMPO: la capability `engram` se instalaba como MCP y su proposito en
# el catalogo declara el contrato de lectura ("mem_search al iniciar, mem_save
# al cerrar"), pero el generador no emitia UN SOLO artefacto que lo ejecutara:
# cero menciones en settings.json.tmpl y cero en templates/hooks/. Medido en una
# instancia real: 288 observaciones acumuladas y 0 consultadas.
#
# Es el "consejo vacio" que la regla 1 de CONTRIBUTING prohibe: una herramienta
# con instalador y alimentador, sin vigilante ni EJECUTOR. Este test cubre los
# dos eslabones que faltaban y, sobre todo, la mitad que evita el remedio peor
# que la enfermedad: un hook que le cueste tokens a quien NO eligio engram.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

HOOK="$ROOT/templates/hooks/mem-recall.sh"

corre() {  # corre → stdout del hook con el .mcp.json que haya en $WS
  CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" 2>"$WS/mem.err"
}

echo "── el hook solo habla donde engram existe"

# 1. sin .mcp.json: ni una palabra, y sale 0 (fail-open de observador)
out="$(corre)"; rc=$?
assert_eq 0 "$rc" "sin .mcp.json: sale 0 (un observador no tumba una sesion)"
assert_eq "" "$out" "y no imprime nada: no hay engram que recordar"

# 2. con OTROS MCPs pero sin engram: sigue mudo. Es la mitad que hace seguro
#    instalarlo en todas las instancias: quien no eligio engram no paga tokens.
printf '{"mcpServers":{"serena":{"command":"serena"},"context7":{}}}\n' > "$WS/.mcp.json"
out="$(corre)"
assert_eq "" "$out" "con otros MCPs y sin engram: sigue mudo (no cuesta un token)"

# 3. con engram: imprime el recordatorio, y NOMBRA las herramientas
printf '{"mcpServers":{"engram":{"command":"engram","args":["mcp"]}}}\n' > "$WS/.mcp.json"
out="$(corre)"; rc=$?
assert_eq 0 "$rc" "con engram: sigue saliendo 0"
assert_contains "$out" "mem_context" "nombra la herramienta del estado reciente"
assert_contains "$out" "mem_search" "y la de la busqueda por palabras del pedido"
assert_contains "$out" "mem_save" "y la del cierre, que es la mitad que ya funcionaba"
# La regla que evita que la memoria le gane al codigo: una observacion vieja no
# manda sobre el arbol que el agente tiene delante.
assert_contains "$out" "manda el árbol" "y declara que ante contradiccion gana el arbol"

# 4. jq ausente: el recordatorio NO puede depender de una herramienta opcional
mkdir -p "$WS/bin"
out="$(PATH="$WS/bin:/usr/bin:/bin" CLAUDE_PROJECT_DIR="$WS" bash "$HOOK")"
assert_contains "$out" "mem_context" "sin jq en el PATH el hook sigue hablando (usa grep)"

# 5. un .mcp.json ilegible no tumba nada
printf 'esto no es json {{{\n' > "$WS/.mcp.json"
out="$(corre)"; rc=$?
assert_eq 0 "$rc" "un .mcp.json corrupto: fail-open, sale 0"

echo
echo "── la cadena de la regla 1, entera y verificable"
# Un hook en disco que settings.json no cablea es una proteccion que el humano
# cree tener y no tiene: es la leccion que harness-update.md ya escribe para los
# otros diez hooks. Se verifica en los tres artefactos, no en la prosa.
sj="$(cat "$ROOT/templates/settings.json.tmpl")"
assert_contains "$sj" "mem-recall.sh" "settings.json.tmpl CABLEA el hook"
assert_contains "$sj" "SessionStart" "y lo hace en SessionStart (antes del primer turno)"
python3 -c "import json,sys; json.load(open('$ROOT/templates/settings.json.tmpl'))" \
  && pass "settings.json.tmpl sigue siendo JSON valido" \
  || fail "settings.json.tmpl dejo de ser JSON valido"
assert_contains "$(cat "$ROOT/skills/harness-init/SKILL.md")" '`.claude/hooks/mem-recall.sh`' \
  "esta en la tabla de generacion (regla 2: sin fila no se instala)"
assert_contains "$(cat "$ROOT/commands/harness-update.md")" "mem-recall" \
  "y el updater lo clasifica, o las instancias no lo reciben"
# El vigilante: sin esto la cadena queda en tres cuartos y el modo de fallo es
# justo el silencioso (engram elegido, hook sin cablear, memoria muerta).
#
# SE MIDE LA CONDUCTA, NO EL TEXTO. La primera version de estos tres casos
# grepeaba "mem-recall.sh" dentro de doctor.sh, y el mutante que reemplazaba la
# condicion por `if true` SOBREVIVIO: el string seguia ahi, en el mensaje. Un
# test que busca el nombre del archivo comprueba que alguien lo escribio, no que
# el chequeo muerda. Se corre el doctor de verdad, con los dos workspaces.
mkdir -p "$WS/doc/.claude"
printf '{"mcpServers":{"engram":{"command":"engram"}}}\n' > "$WS/doc/.mcp.json"

printf '{"hooks":{}}\n' > "$WS/doc/.claude/settings.json"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS/doc" 2>&1 || true)"
assert_contains "$out" "no la lee nadie" \
  "engram cableado a medias: el doctor lo DICE (y con el sintoma, no con el nombre del archivo)"

printf '{"hooks":{"SessionStart":[{"hooks":[{"command":".claude/hooks/mem-recall.sh"}]}]}}\n' \
  > "$WS/doc/.claude/settings.json"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS/doc" 2>&1 || true)"
assert_not_contains "$out" "no la lee nadie" \
  "y con el hook cableado se calla: un vigilante que grita siempre no se lee"
assert_contains "$out" "engram con su lector cableado" "lo confirma en positivo"

# Y la tercera mitad, la que evita el aviso molesto: sin engram no opina.
# Se miran las DOS salidas del bloque, no solo el aviso: con el hook cableado y
# sin engram, comprobar unicamente que no avise deja pasar un doctor que opina
# igual (dice el ok). Ese mutante sobrevivio la primera vez.
rm -f "$WS/doc/.mcp.json"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS/doc" 2>&1 || true)"
assert_not_contains "$out" "no la lee nadie" \
  "sin engram en .mcp.json el doctor no avisa"
assert_not_contains "$out" "engram con su lector cableado" \
  "y tampoco lo confirma: de un MCP que no esta no se opina en ninguna direccion"

t_done
