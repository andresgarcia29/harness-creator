#!/usr/bin/env bash
# Hook PreToolUse (Edit|Write|MultiEdit) — LEY 4: nunca editar el clon
# canónico repos/<x>; el trabajo vive en worktrees/<task>/<repo>.
# FAIL-CLOSED: sin jq, bloquea ediciones que mencionen /repos/.
set -uo pipefail
input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | grep -q "/repos/"; then
    echo "⛔ jq no disponible: bloqueo edición bajo repos/ por precaución. Instala jq." >&2
    exit 2
  fi
  exit 0
fi

path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[ -n "$path" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
case "$path" in
  "$root"/repos/*)
    echo "⛔ edición del clon canónico bloqueada (Ley 4): $path" >&2
    echo "   Crea tu worktree: scripts/worktree-task.sh <task-id> <repo> y edita ahí." >&2
    exit 2
    ;;
esac
exit 0
