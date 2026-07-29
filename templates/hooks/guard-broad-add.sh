#!/usr/bin/env bash
# guard-broad-add.sh — PreToolUse (Bash): BLOQUEA `git add` amplio (-A, --all,
# ".", -u) y `git commit -a` dentro de un worktree que COMPARTEN varias tareas
# del DAG.
#
# POR QUÉ EXISTE: worktree-task.sh crea el árbol en worktrees/<task-id>/<repo>,
# o sea UNO por (tarea, repo). Todas las tareas del DAG de esa tarea comparten
# ese árbol, la rama task/<id> y el index de git. La doctrina decía lo
# contrario ("cada tarea tiene su worktree"), y sobre esa premisa falsa se
# lanzaban tareas del mismo repo en paralelo.
#
# Caso de campo: dos tareas del mismo repo en vuelo a la vez, y el `git add -A`
# de una se llevó 6 archivos de la otra a su commit. No se perdió trabajo
# (mismo trailer Task:), pero la atribución quedó mezclada y el index quedó a
# merced de una carrera. La regla vive también en el prompt del implementer,
# pero una regla que solo vive en prosa no frena a nadie.
#
# POLICY-DAG-010 ataca la otra mitad: impide PLANIFICAR dos tareas del mismo
# repo sin orden. Este hook cubre lo que igual llegue al index, y solo muerde
# cuando el riesgo existe de verdad: con una sola tarea del repo en el DAG, un
# add amplio es legítimo y pasa.
#
# Contrato Claude Code: exit 2 + stderr = bloquear la tool call.
set -uo pipefail
input="$(cat)"

# ── El hook juzga COMANDOS, no texto ─────────────────────────────────
# Misma lección que guard-build-slot: un `git commit -m "no uses git add -A"`
# no es un add amplio. Se descartan los cuerpos de heredoc y los tramos
# entrecomillados antes de mirar. El orden importa: heredoc primero, porque su
# delimitador suele venir entrecomillado.
sanitize() {
  printf '%s\n' "$1" | awk '
    BEGIN { q = sprintf("%c", 39); skip = 0 }
    skip == 1 {
      t = $0; gsub(/^[[:space:]]+/, "", t)
      if (t == delim) skip = 0
      next
    }
    {
      line = $0
      if (match(line, "<<-?[[:space:]]*[\"" q "]?[A-Za-z_][A-Za-z0-9_]+")) {
        delim = substr(line, RSTART, RLENGTH)
        sub("^<<-?[[:space:]]*", "", delim)
        gsub("[\"" q "]", "", delim)
        skip = 1
        line = substr(line, 1, RSTART - 1)
      }
      gsub("\"[^\"]*\"", "", line)
      gsub(q "[^" q "]*" q, "", line)
      print line
    }
  ' 2>/dev/null
}

# ¿Es un add amplio o un commit -a? Se exige `git` en posición de comando.
es_amplio() {
  printf '%s' "$1" | grep -Eq \
    '(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+add([[:space:]]+-[^[:space:]]+)*[[:space:]]+(-A|--all|-u|--update|\.)([[:space:]]|$)' && return 0
  printf '%s' "$1" | grep -Eq \
    '(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+add[[:space:]]+(-A|--all|-u|--update|\.)([[:space:]]|$)' && return 0
  printf '%s' "$1" | grep -Eq \
    '(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+commit[[:space:]]+(-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|$)' && return 0
  return 1
}

# La tarea sale de la RUTA del worktree que el comando toca: worktrees/<id>/...
# Se mira el `-C <ruta>`, un `cd <ruta>` del propio comando, y el cwd del hook.
tarea_de() {
  case "$1" in
    */worktrees/*) printf '%s' "${1#*/worktrees/}" | cut -d/ -f1 ;;
    worktrees/*)   printf '%s' "${1#worktrees/}"   | cut -d/ -f1 ;;
    *) : ;;
  esac
}

if ! command -v jq >/dev/null 2>&1; then
  # FAIL-CLOSED sin jq, igual que guard-canonical: sin poder leer el DAG no se
  # puede saber si el worktree es compartido, y el daño (commits mezclados) es
  # silencioso y difícil de deshacer.
  #
  # Acá NO se puede usar es_amplio ni sanitize: sin jq lo único que hay es el
  # JSON crudo, donde el comando entero viene entrecomillado, así que el
  # saneador de comillas lo borraría y el ancla de "posición de comando" nunca
  # matchearía. Se mira el patrón directo, más laxo a propósito, y acotado a
  # que la ruta mencione un worktree: un `git add` por nombre sigue pasando,
  # porque un guard que bloquea de más es un guard que alguien desactiva.
  if printf '%s' "$input" | grep -qE 'worktrees/' \
     && printf '%s' "$input" | grep -qE 'git[^"]*(add[^"]*[[:space:]](-A|--all|-u|--update|\.)([[:space:]]|\\|")|commit[[:space:]]+(-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|\\|"))'; then
    echo "⛔ jq no disponible: bloqueo por precaución un 'git add' amplio en un worktree." >&2
    echo "   Sin jq no puedo leer el dag.json para saber si otra tarea comparte este árbol." >&2
    echo "   ↳ agregá tus archivos por nombre, o instalá jq." >&2
    exit 2
  fi
  exit 0
fi

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[ -n "$cmd" ] || exit 0
sanitized="$(sanitize "$cmd")" || sanitized="$cmd"
es_amplio "$sanitized" || exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
task=""
for cand in $sanitized; do
  case "$cand" in *worktrees/*) task="$(tarea_de "$cand")"; [ -n "$task" ] && break ;; esac
done
[ -n "$task" ] || task="$(tarea_de "$cwd")"
[ -n "$task" ] || exit 0                      # fuera de un worktree: no es asunto de este hook
case "$task" in *[!A-Za-z0-9._-]*) exit 0 ;; esac

dag="$root/tasks/$task/dag.json"
[ -f "$dag" ] || exit 0                       # sin DAG no hay tareas hermanas que pisar

# ¿Cuál es el repo del worktree que se está tocando, y cuántas tareas del DAG
# lo comparten? Con una sola, el add amplio es legítimo y no se molesta a nadie.
repo=""
for cand in $sanitized; do
  case "$cand" in
    */worktrees/"$task"/*|worktrees/"$task"/*)
      repo="$(printf '%s' "${cand#*worktrees/"$task"/}" | cut -d/ -f1)" ;;
  esac
  [ -n "$repo" ] && break
done
[ -n "$repo" ] || repo="$(printf '%s' "${cwd#*worktrees/"$task"/}" | cut -d/ -f1)"
[ -n "$repo" ] || exit 0

n="$(jq -r --arg r "$repo" '[.tasks[]? | select(.repo == $r)] | length' "$dag" 2>/dev/null)" || n=""
case "$n" in ''|*[!0-9]*) n=0 ;; esac
[ "$n" -ge 2 ] || exit 0

echo "⛔ 'git add' amplio en un worktree COMPARTIDO: $repo (tarea $task)" >&2
echo "   El DAG declara $n tareas sobre '$repo', y todas comparten el mismo árbol" >&2
echo "   worktrees/$task/$repo, la misma rama y el mismo index de git." >&2
echo "   Un add amplio se lleva los archivos de la tarea vecina a TU commit:" >&2
echo "   pasó de verdad, seis archivos, y la atribución quedó mezclada." >&2
echo "   ↳ remediación: mirá qué es tuyo y agregalo POR NOMBRE:" >&2
echo "     git -C worktrees/$task/$repo status --porcelain" >&2
echo "     git -C worktrees/$task/$repo add <ruta> <ruta>" >&2
exit 2
