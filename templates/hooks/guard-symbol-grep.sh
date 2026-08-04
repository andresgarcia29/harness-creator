#!/usr/bin/env bash
# guard-symbol-grep.sh: hook PreToolUse (Grep) que avisa UNA VEZ POR TAREA
# cuando alguien grepea un SÍMBOLO dentro de un worktree teniendo Serena
# configurada.
#
# POR QUÉ EXISTE: la constitución pide edición simbólica ("Implementación →
# edición simbólica (Serena), no archivos enteros" en CLAUDE.md, y el contrato
# del implementer lo repite), pero en campo Serena casi no se usaba y el grep
# ganaba siempre. Ese pedido ya vivía en prosa en DOS lugares y no frenaba a
# nadie: misma lección que guard-broad-add. La otra mitad del incentivo la
# arregla track-read.sh, que hasta ahora no registraba las lecturas de Serena y
# por eso gate_evidence castigaba justo al agente que obedecía.
#
# ── POR QUÉ AVISA Y NO PROHÍBE ───────────────────────────────────────
# grep es la herramienta CORRECTA para un montón de cosas: un string de
# configuración, una clave de YAML, un mensaje de error, un TODO. Un guard que
# bloquee Grep de plano se lleva puesto todo eso, y un guard que bloquea de más
# es un guard que alguien desactiva (guard-broad-add aprendió lo mismo).
#
# Por eso muerde solo en la intersección estrecha donde Serena es
# objetivamente mejor (patrón con FORMA DE SÍMBOLO, dentro de un worktree, con
# Serena en el .mcp.json), y muerde UNA sola vez por tarea: el mensaje dice
# explícitamente que repetir el mismo grep pasa. No hay forma de que este hook
# deje a nadie atascado, que es la condición para poder ponerlo en el camino de
# una tool tan usada.
#
# LO QUE NO CUBRE, dicho de frente: `rg`/`grep` por Bash (vigilar eso pedía
# adivinar el patrón dentro de una línea de shell, con falsos positivos
# garantizados sobre la tool más usada del harness), y un Grep SIN `path`,
# porque el cwd que llega en el payload es el de la sesión (la raíz del
# workspace) y no dice en qué worktree se está trabajando. En los dos casos
# calla: la precisión vale más que la cobertura en un aviso que no debe
# volverse ruido.
#
# Contrato Claude Code: exit 2 + stderr = bloquear la tool call.
set -uo pipefail
input="$(cat 2>/dev/null)"
[ -n "$input" ] || exit 0

# FAIL-OPEN sin jq, al revés que guard-canonical y guard-broad-add. Aquellos
# protegen algo irreversible (un push a trunk, un commit con archivos ajenos) y
# ahí el silencio es peor que el bloqueo. Acá lo único en juego son tokens: un
# bloqueo a ciegas de Grep costaría más de lo que ahorra.
command -v jq >/dev/null 2>&1 || exit 0

WS="${CLAUDE_PROJECT_DIR:-$PWD}"

# ── ¿hay Serena de verdad? ───────────────────────────────────────────
# Las capabilities son opt-in por workspace. Recomendar find_symbol donde no
# hay servidor que lo sirva es mandar al agente contra una tool inexistente,
# que es el modo de fallo #1 de las skills que prometen MCPs.
[ -f "$WS/.mcp.json" ] || exit 0
jq -e '.mcpServers.serena // .mcpServers["serena"]' "$WS/.mcp.json" >/dev/null 2>&1 || exit 0

pattern="$(printf '%s' "$input" | jq -r '.tool_input.pattern // ""' 2>/dev/null)"
[ -n "$pattern" ] || exit 0
path="$(printf '%s' "$input" | jq -r '.tool_input.path // ""' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"

# ── la tarea sale de la RUTA, igual que en track-read ────────────────
task_of() {
  case "$1" in
    */worktrees/*) printf '%s' "${1#*/worktrees/}" | cut -d/ -f1 ;;
    worktrees/*)   printf '%s' "${1#worktrees/}"   | cut -d/ -f1 ;;
    *) : ;;
  esac
}
task="$(task_of "$path")"
[ -n "$task" ] || task="$(task_of "$cwd")"
[ -n "$task" ] || exit 0                  # fuera de un worktree no es asunto de este hook
# `.` y `..` pasan el filtro de caracteres (el punto es legítimo en un task-id)
# y son justo los dos que se salen de tasks/: worktrees/../x da un id `..` y la
# marca terminaría escrita en la raíz del workspace. Se nombran aparte.
case "$task" in *[!A-Za-z0-9._-]*|.|..) exit 0 ;; esac

# ── ¿el patrón tiene FORMA DE SÍMBOLO? ───────────────────────────────
# El filtro entero vive acá, y es a propósito conservador: ante la duda, deja
# pasar. Dos familias, las dos inequívocas:
#
#   1. una DECLARACIÓN: `func Login`, `def parse_headers`, `class UserRepo`.
#      Quien busca eso está buscando una definición, que es literalmente lo que
#      find_symbol devuelve.
#   2. un identificador COMPUESTO suelto: camelCase, snake_case, PascalCase.
#      Se exige la composición: `titulo` o `error` son palabras que aparecen en
#      prosa, YAML y logs, y nadie quiere un aviso por buscarlas.
#
# Un patrón con metacaracteres de regex (fuera de los de la familia 1) se deja
# pasar entero: quien escribe una regex de verdad sabe lo que busca y Serena no
# le sirve mejor.
es_simbolo() {
  local norm
  # `func\s+Login` y `func Login` son el mismo pedido: los atajos de regex para
  # espacio se normalizan antes de juzgar la familia 1.
  norm="$(printf '%s' "$1" | sed -e 's/\\s[+*]*/ /g' -e 's/\[[[:space:]]*\][+*]*/ /g')"
  printf '%s' "$norm" | grep -Eq \
    '^[[:space:]]*(func|fn|def|class|type|struct|interface|impl|module|trait|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
    && return 0
  # Familia 2 sobre el patrón ORIGINAL: identificador solo, sin espacios ni
  # metacaracteres, y COMPUESTO.
  case "$1" in
    *[!A-Za-z0-9_]*) return 1 ;;           # cualquier cosa que no sea identificador
    ???*) : ;;                             # menos de 3 caracteres no dice nada
    *) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '(_[A-Za-z0-9]|[a-z][A-Z])' && return 0
  return 1
}
es_simbolo "$pattern" || exit 0

# ── una sola vez por tarea ───────────────────────────────────────────
# El marcador se crea ANTES de bloquear: si algo fallara entre el bloqueo y la
# marca, el agente quedaría en un lazo con el mismo aviso para siempre, que es
# exactamente el fallo que este diseño no se puede permitir.
marca="$WS/tasks/$task/.serena-nudge"
[ -e "$marca" ] && exit 0
mkdir -p "$WS/tasks/$task" 2>/dev/null || exit 0
: > "$marca" 2>/dev/null || exit 0

{
  echo "⛔ grep de un SÍMBOLO dentro de un worktree, teniendo Serena activa."
  echo "   patrón: $pattern    tarea: $task"
  echo "   find_symbol te devuelve la definición Y el cuerpo en una sola tool"
  echo "   call. El grep te devuelve N líneas sueltas y después hay que abrir"
  echo "   los archivos igual: pagás el retrieval dos veces."
  echo "   ↳ 1. mcp__serena__activate_project → worktrees/$task/<repo>"
  echo "        (Serena es POR-PROYECTO; sin esto sus tools no operan)"
  echo "     2. mcp__serena__find_symbol con name_path=\"$pattern\""
  echo "        ¿quién lo usa? → mcp__serena__find_referencing_symbols"
  echo "        ¿qué hay en el archivo? → mcp__serena__get_symbols_overview"
  echo "   Si de verdad buscabas TEXTO y no un símbolo (config, string de UI,"
  echo "   mensaje de log), repetí el mismo Grep y pasa: este aviso salta UNA"
  echo "   vez por tarea y no vuelve."
} >&2
exit 2
