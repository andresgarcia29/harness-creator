#!/usr/bin/env bash
# Hook PreToolUse (Edit|Write|MultiEdit): tres leyes con dientes.
#   LEY 4: nunca editar el clon canónico repos/<x>; el trabajo vive en
#          worktrees/<task>/<repo>.
#   EL PIN ES DE SOLO LECTURA: worktrees/<task>/.review-<repo> es el árbol
#          CLAVADO al commit sellado, y es el que el veredicto juzga. Escribir
#          ahí invalida el juicio en silencio.
#   LEY 0: NINGÚN agente edita el harness mientras hace una tarea. Los gates,
#          los hooks y los denials NO son código de producto: son la ley que
#          juzga al agente que los tocaría. Un agente atascado en el gate 6 al
#          que se le ocurre "arreglar" ship.sh no está pasando el gate — lo
#          está borrando, y con él todos los demás para siempre. Cambiar la ley
#          es trabajo de un humano, en un PR, mirándolo de frente.
# FAIL-CLOSED: sin jq, bloquea por precaución.
set -uo pipefail
input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | grep -qE "/repos/|/\.review-|/\.claude/hooks/|ship\.sh|settings\.json"; then
    echo "⛔ jq no disponible: bloqueo por precaución (Ley 4 / Ley 0). Instala jq." >&2
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
  # ── EL ÁRBOL CLAVADO NO SE MUTA ──────────────────────────────────────
  # Caso de campo: el reviewer hizo verificación por mutación (editar src/
  # para comprobar que un test se pone rojo) sobre el árbol que QA estaba
  # midiendo EN PARALELO. El build de QA absorbió el archivo mutado y un test
  # sin trackear; la medición quedó corrupta y solo se salvó porque QA
  # sospechó. Nada se lo avisó. Un falso rojo cuesta una ronda; un falso verde
  # shippea el bug.
  #
  # El pin además es el árbol que el veredicto SELLA: mutarlo es juzgar un
  # código distinto del que se declara juzgado.
  #
  # No hace falta mutar a mano: `gate_test_muerde` ya corre cada test nuevo
  # contra el árbol base en un worktree TEMPORAL, aislado, en cada precheck.
  "$root"/worktrees/*/.review-*)
    echo "⛔ el árbol clavado es de SOLO LECTURA: $path" >&2
    echo "   worktrees/<task>/.review-<repo> es el árbol sellado que tu veredicto" >&2
    echo "   juzga. Mutarlo invalida el juicio, y en el árbol vivo de al lado hay" >&2
    echo "   un QA midiendo: una mutación ahí le corrompe la medición en silencio." >&2
    echo "   ↳ para probar que un test MUERDE no hace falta mutar: el precheck ya" >&2
    echo "     lo hace aislado (gate_test_muerde, contra el árbol base)." >&2
    echo "   ↳ si necesitás una sonda manual, que sea descartable:" >&2
    echo "     git -C worktrees/<task>/<repo> worktree add --detach /tmp/sonda HEAD" >&2
    echo "     (mutá ahí y borrala con: git worktree remove --force /tmp/sonda)" >&2
    exit 2
    ;;
esac
exit 0
