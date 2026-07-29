#!/usr/bin/env bash
# test_guard_worktree.sh: un worktree tiene UN dueño a la vez.
# Con varias sesiones sobre el mismo workspace, dos implementers en el mismo
# árbol se pisan archivos e índice de git. El síntoma que ve el humano es
# "cambios que se deshacen solos", y para entonces ya no se sabe quién perdió
# qué. Este hook es la única guarda que cubre ese tramo.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

HOOK="$ROOT/templates/hooks/guard-worktree.sh"
mkdir -p "$WS/worktrees/T1/videocore/src" "$WS/repos/videocore"

edit() {  # edit <session> <path> [ttl]: simula un Edit del hook PreToolUse
  local ttl="${3:-3600}"
  printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" \
    | CLAUDE_PROJECT_DIR="$WS" HARNESS_WORKTREE_TTL="$ttl" bash "$HOOK" 2>&1
}
rc_of() {  # rc_of <session> <path> [ttl]
  local ttl="${3:-3600}"
  printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" \
    | CLAUDE_PROJECT_DIR="$WS" HARNESS_WORKTREE_TTL="$ttl" bash "$HOOK" >/dev/null 2>&1
  echo $?
}

F="$WS/worktrees/T1/videocore/src/app.ts"
CLAIM="$WS/.harness/claims/T1__videocore.json"

echo "── el primero reclama, el segundo se bloquea"

assert_eq 0 "$(rc_of sess-A "$F")" "primera escritura de A: pasa"
assert_file "$CLAIM" "queda el reclamo del worktree"
assert_eq "sess-A" "$(jq -r .session "$CLAIM")" "el reclamo guarda la sesión dueña"

assert_eq 0 "$(rc_of sess-A "$WS/worktrees/T1/videocore/otro.ts")" "A sigue escribiendo en su worktree: pasa"

assert_eq 2 "$(rc_of sess-B "$F")" "B en el MISMO worktree: bloqueado (exit 2)"
out="$(edit sess-B "$F")"
assert_contains "$out" "worktree ocupado" "el bloqueo dice qué pasó"
assert_contains "$out" "sess-A" "nombra a la sesión que lo tiene"
assert_contains "$out" "se deshacen solos" "explica el síntoma que evita"
assert_contains "$out" "rm .harness/claims" "da la salida si la otra sesión murió"
assert_eq "sess-A" "$(jq -r .session "$CLAIM")" "un bloqueo NO le roba el reclamo al dueño"

echo
echo "── el reclamo es por worktree, no por sesión ni por repo"

mkdir -p "$WS/worktrees/T2/videocore/src"
assert_eq 0 "$(rc_of sess-B "$WS/worktrees/T2/videocore/src/x.ts")" "B en OTRA tarea del mismo repo: pasa"
mkdir -p "$WS/worktrees/T1/design-system/src"
assert_eq 0 "$(rc_of sess-B "$WS/worktrees/T1/design-system/src/x.ts")" "B en otro repo de la MISMA tarea: pasa"

echo
echo "── caducidad: un dueño que ya no trabaja no traba a nadie"

# TTL de 0 s: el reclamo de A cuenta como abandonado de inmediato
out="$(edit sess-B "$F" 0)"
assert_contains "$out" "lo tomo yo" "reclamo caducado: la otra sesión lo toma"
assert_eq "sess-B" "$(jq -r .session "$CLAIM")" "tras caducar, el reclamo cambia de dueño"
assert_eq 2 "$(rc_of sess-A "$F")" "y ahora el bloqueado es A"

echo
echo "── fuera del worktree, este hook no opina"

assert_eq 0 "$(rc_of sess-B "$WS/repos/videocore/x.ts")" "clon canónico: no es asunto de este hook (lo cubre guard-canonical)"
assert_eq 0 "$(rc_of sess-B "$WS/tasks/T1/plan.md")" "artefactos de la tarea: pasa"
assert_eq 0 "$(rc_of sess-B "$WS/worktrees/T1")" "ruta incompleta de worktree: no revienta, pasa"

echo
echo "── fail-open: coordinar no justifica frenar el trabajo"

assert_eq 0 "$(printf '%s' '{}' | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1; echo $?)" "payload sin path ni sesión: pasa"
assert_eq 0 "$(printf '%s' 'no soy json' | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1; echo $?)" "payload corrupto: pasa"
assert_eq 0 "$(printf '' | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1; echo $?)" "payload vacío: pasa"

echo
echo "── el ÁRBOL CLAVADO es de solo lectura (guard-canonical, fail-CLOSED)"
# guard-worktree coordina entre sesiones, pero reviewer, QA e implementer
# lanzados como subagentes de la MISMA sesión comparten session_id: el claim se
# refresca y pasan los tres. Ahí no hay guarda.
#
# Caso de campo: el reviewer hizo verificación por mutación (editar src/ para
# comprobar que un test se pone rojo) sobre el árbol que QA medía EN PARALELO.
# El build de QA absorbió el archivo mutado y un test sin trackear, y la
# medición quedó corrupta. QA lo cazó por diligencia, no porque algo se lo
# avisara. Un falso rojo cuesta una ronda; un falso verde shippea el bug.
#
# El pin worktrees/<task>/.review-<repo> es además el árbol que el veredicto
# SELLA: mutarlo es juzgar un código distinto del que se declara juzgado.
CANON="$ROOT/templates/hooks/guard-canonical.sh"
mkdir -p "$WS/worktrees/T1/.review-videocore/src"
canon_rc() {  # canon_rc <path> → exit code, stderr en $WS/canon.err
  printf '{"tool_input":{"file_path":"%s"}}' "$1" \
    | CLAUDE_PROJECT_DIR="$WS" bash "$CANON" 2>"$WS/canon.err" >/dev/null
  echo $?
}
assert_eq 2 "$(canon_rc "$WS/worktrees/T1/.review-videocore/src/app.ts")" \
  "escribir en el árbol clavado: BLOQUEADO"
canon_err="$(cat "$WS/canon.err")"
assert_contains "$canon_err" "SOLO LECTURA" "el mensaje nombra la ley"
assert_contains "$canon_err" "QA midiendo" "y por qué importa (hay alguien midiendo al lado)"
assert_contains "$canon_err" "gate_test_muerde" "y dice que la mutación ya se hace mecánicamente"
assert_contains "$canon_err" "worktree add --detach" "con la sonda descartable como alternativa exacta"

# LA LEY NO SE DERRAMA: el árbol vivo es del implementer y ahí sí se escribe.
# Un guard que bloquea de más es un guard que alguien desactiva.
assert_eq 0 "$(canon_rc "$WS/worktrees/T1/videocore/src/app.ts")" \
  "el árbol VIVO sigue siendo escribible (es del implementer)"
assert_eq 2 "$(canon_rc "$WS/repos/videocore/src/app.ts")" \
  "y el clon canónico sigue bloqueado (Ley 4 intacta)"

# Sin jq el hook es fail-CLOSED, y el pin tiene que entrar en esa red.
NOJQ2="$(t_path_without jq)"
printf '{"tool_input":{"file_path":"%s"}}' "$WS/worktrees/T1/.review-videocore/x.ts" \
  | PATH="$NOJQ2" CLAUDE_PROJECT_DIR="$WS" bash "$CANON" >/dev/null 2>&1
[ $? -eq 2 ] && pass "sin jq: el pin también se bloquea por precaución" \
  || fail "sin jq el pin quedaba desprotegido"

t_done
