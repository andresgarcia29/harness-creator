#!/usr/bin/env bash
# track-read.sh — el libro de a bordo de la evidencia. PostToolUse sobre
# Read/Bash/Grep: apunta QUÉ artefactos abrió realmente un agente.
#
# POR QUÉ EXISTE: el reviewer escribe una compliance matrix que dice "el
# requirement AUTH-3 está cubierto por auth_test.go". Nada comprobaba que
# hubiera abierto auth_test.go. Un agente puede afirmar cobertura sin mirar —
# no por mentir, sino porque es lo más barato. Este hook convierte "lo leí"
# en un hecho verificable: ship.sh (gate_evidence) intersecta lo citado con
# lo leído. La ley del harness es que los agentes proponen y los sistemas
# deterministas verifican; sin este registro, el verificador proponía.
#
# Como ui-emit.sh: OBSERVA, jamás bloquea, sale 0 SIEMPRE (fail-open). Los
# que bloquean son block-direct-push y guard-canonical, y esos son fail-closed
# a propósito. Un hook de telemetría que tumba el pipeline es un bug.
set -u

exit_ok() { exit 0; }
trap exit_ok EXIT
command -v jq >/dev/null 2>&1 || exit 0

WS="${CLAUDE_PROJECT_DIR:-$PWD}"
TASK="$(cat "$WS/.harness/current-task" 2>/dev/null | head -1 | tr -d '\n')"
[ -n "$TASK" ] || exit 0                       # sin tarea activa no hay nada que probar
LOG="$WS/tasks/$TASK/evidence.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0

payload="$(cat 2>/dev/null)"; [ -n "$payload" ] || exit 0
tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

emit() { printf '%s\t%s\t%s\n' "$ts" "$1" "$2" >> "$LOG" 2>/dev/null; }

case "$tool" in
  Read|NotebookRead)
    p="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"
    [ -n "$p" ] && emit read "${p#"$WS"/}"
    ;;
  Grep|Glob)
    p="$(printf '%s' "$payload" | jq -r '.tool_input.path // ""' 2>/dev/null)"
    [ -n "$p" ] && emit scan "${p#"$WS"/}"
    ;;
  Bash)
    # Un test que CORRIÓ es la evidencia más fuerte que hay. Registramos el
    # comando y los archivos que nombra: `go test ./auth/...`, `pytest x_test.py`.
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)"
    [ -n "$cmd" ] || exit 0
    case "$cmd" in
      *test*|*spec*|*pytest*|*jest*|*vitest*|*rspec*|*"go test"*|*gradle*|*mvn*|*cargo*)
        emit ran "$(printf '%s' "$cmd" | cut -c1-160)"
        for tok in $cmd; do
          case "$tok" in
            -*|*=*) continue ;;
            *test*|*spec*|*.go|*.py|*.ts|*.js|*.rs|*.java|*.rb)
              emit ran-file "${tok#"$WS"/}" ;;
          esac
        done
        ;;
    esac
    ;;
esac
exit 0
