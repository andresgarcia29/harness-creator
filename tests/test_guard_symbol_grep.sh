#!/usr/bin/env bash
# test_guard_symbol_grep.sh: el aviso que empuja de grep a Serena.
#
# POR QUÉ EXISTE EL HOOK: la constitución pide edición simbólica en DOS lugares
# (CLAUDE.md y el contrato del implementer) y en campo Serena casi no se usaba.
# Una regla que solo vive en prosa no frena a nadie.
#
# LO QUE ESTE TEST PROTEGE, que es lo difícil de un aviso puesto sobre la tool
# más usada del harness: que muerda SOLO en la intersección estrecha donde
# Serena gana, que se calle en todo lo demás, y sobre todo que NUNCA deje a
# nadie atascado. Un guard que bloquea de más es un guard que alguien
# desactiva, y ahí deja de proteger nada.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

HOOK="$ROOT/templates/hooks/guard-symbol-grep.sh"
mkdir -p "$WS/worktrees/COR-30/atlas" "$WS/tasks/COR-30"
echo '{"mcpServers":{"serena":{"command":"uvx","args":[]}}}' > "$WS/.mcp.json"

corre() {  # corre <patrón> [path] [cwd] → exit code del hook
  local pat="$1" path="${2:-$WS/worktrees/COR-30/atlas}" cwd="${3:-$WS}"
  jq -nc --arg p "$pat" --arg d "$path" --arg w "$cwd" \
    '{tool_name:"Grep", tool_input:{pattern:$p, path:$d}, cwd:$w}' \
    | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" 2>"$WS/err.txt"
}
err() { cat "$WS/err.txt" 2>/dev/null; }
limpia() { rm -f "$WS/tasks/COR-30/.serena-nudge"; }

echo "── muerde donde Serena gana"

# 1. identificador COMPUESTO dentro de un worktree: el caso central
corre "parseHeaders"; rc=$?
assert_eq 2 "$rc" "camelCase dentro de un worktree: avisa"
assert_contains "$(err)" "find_symbol" "y nombra la tool que sí sirve"
assert_contains "$(err)" "activate_project" "recordando que Serena es POR-PROYECTO"

# 2. snake_case también
limpia; corre "parse_headers"; rc=$?
assert_eq 2 "$rc" "snake_case también es forma de símbolo"

# 3. una DECLARACIÓN, con y sin el atajo de regex para el espacio
limpia; corre 'func Login'; rc=$?
assert_eq 2 "$rc" "'func Login' es buscar una definición"
limpia; corre 'func\s+Login'; rc=$?
assert_eq 2 "$rc" "y el atajo \\s+ es el MISMO pedido, no una regex distinta"
limpia; corre 'class UserRepo'; rc=$?
assert_eq 2 "$rc" "'class UserRepo' idem"

echo
echo "── se calla donde grep es la herramienta correcta"

# 4. una palabra suelta de prosa NO es un símbolo. Este es el falso positivo
#    que volvería ruido al aviso: 'error', 'titulo', 'timeout' viven en YAML,
#    logs y mensajes de usuario tanto como en código.
limpia; corre "timeout"; rc=$?
assert_eq 0 "$rc" "palabra simple: no avisa (grep es lo correcto ahí)"
limpia; corre "TODO"; rc=$?
assert_eq 0 "$rc" "un TODO tampoco"

# 5. una regex de verdad se deja pasar entera: quien la escribe sabe qué busca
#    y find_symbol no le da nada mejor.
limpia; corre 'apiKey=[A-Za-z0-9]{20,}'; rc=$?
assert_eq 0 "$rc" "una regex real pasa (Serena no la sirve mejor)"
limpia; corre 'user\.name|user\.email'; rc=$?
assert_eq 0 "$rc" "alternancia con metacaracteres: pasa"

# 6. FUERA de un worktree no es asunto de este hook: el orquestador y el
#    arquitecto grepean el workspace todo el tiempo y Serena ni siquiera está
#    activada sobre él.
limpia; corre "parseHeaders" "$WS/docs" "$WS"; rc=$?
assert_eq 0 "$rc" "fuera de un worktree: no se mete"

# 7. sin Serena en el .mcp.json el aviso mandaría al agente contra una tool
#    inexistente, que es el modo de fallo #1 de prometer MCPs ausentes.
limpia; echo '{"mcpServers":{"context7":{}}}' > "$WS/.mcp.json"
corre "parseHeaders"; rc=$?
assert_eq 0 "$rc" "sin serena en .mcp.json: se calla"
limpia; rm -f "$WS/.mcp.json"
corre "parseHeaders"; rc=$?
assert_eq 0 "$rc" "sin .mcp.json siquiera: se calla"
echo '{"mcpServers":{"serena":{"command":"uvx","args":[]}}}' > "$WS/.mcp.json"

echo
echo "── nunca deja a nadie atascado (la condición para poder existir)"

# 8. UNA vez por tarea. La segunda pasada del MISMO grep pasa, y el propio
#    mensaje lo dice: sin esa salida garantizada, un agente que de verdad
#    buscaba texto quedaría en un lazo contra el hook.
limpia; corre "parseHeaders"; rc=$?
assert_eq 2 "$rc" "primera vez: avisa"
assert_contains "$(err)" "repetí el mismo Grep" "y el mensaje promete la salida"
corre "parseHeaders"; rc=$?
assert_eq 0 "$rc" "segunda vez: pasa (el aviso no vuelve)"
corre "otraFuncion"; rc=$?
assert_eq 0 "$rc" "y ya no vuelve para NINGÚN patrón de esa tarea"

# 9. la marca es POR TAREA: otra tarea empieza con su propio aviso
mkdir -p "$WS/worktrees/COR-31/atlas" "$WS/tasks/COR-31"
corre "parseHeaders" "$WS/worktrees/COR-31/atlas"; rc=$?
assert_eq 2 "$rc" "otra tarea, otro aviso (la marca no es global)"

# 10. FAIL-OPEN sin jq, al revés que los guards que protegen algo irreversible:
#     acá lo único en juego son tokens, y un bloqueo a ciegas de Grep cuesta
#     más de lo que ahorra.
limpia
out=$(jq -nc '{tool_name:"Grep", tool_input:{pattern:"parseHeaders",
       path:"'"$WS"'/worktrees/COR-30/atlas"}, cwd:"'"$WS"'"}' \
  | PATH="$(t_path_without jq)" CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" 2>&1)
assert_eq 0 "$?" "sin jq: fail-OPEN (lo que arriesga son tokens, no un push)"

# 11. payload roto no rompe nada
echo "esto no es json" | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 "$?" "payload roto: exit 0"

# 12. task-id hostil no construye rutas. `..` PASA el filtro de caracteres (el
#     punto es legítimo en un task-id) y `$WS/tasks/../.serena-nudge` es
#     exactamente `$WS/.serena-nudge`: la marca se escapaba de tasks/.
limpia
jq -nc '{tool_name:"Grep", tool_input:{pattern:"parseHeaders",
         path:"'"$WS"'/worktrees/../../../etc/x/repo"}, cwd:"'"$WS"'"}' \
  | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1
assert_no_file "$WS/.serena-nudge" "id '..' no escribe la marca fuera de tasks/"

t_done
