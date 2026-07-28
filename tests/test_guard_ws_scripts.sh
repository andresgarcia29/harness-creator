#!/usr/bin/env bash
# test_guard_ws_scripts.sh — `scripts/<x>.sh` relativo desde un worktree no
# resuelve (los scripts del harness viven en la raíz del workspace). Caso de
# campo: 6-8 comandos muertos con "No such file or directory", un round-trip
# perdido cada uno. El hook bloquea SOLO cuando sabe la sustitución exacta.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

HOOK="$ROOT/templates/hooks/guard-ws-scripts.sh"
mkdir -p "$WS/scripts" "$WS/worktrees/T1/repo/scripts"
touch "$WS/scripts/ship.sh" "$WS/scripts/evidence.py" "$WS/worktrees/T1/repo/scripts/own.sh"

run_hook() {  # run_hook <cmd> <cwd> → rc (2 = bloquea, 0 = pasa)
  jq -nc --arg c "$1" --arg d "$2" '{tool_input:{command:$c},cwd:$d}' \
    | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1
}

echo "── el caso de campo: cwd de sesión atorado en el worktree"

run_hook 'bash scripts/ship.sh T1 repo' "$WS/worktrees/T1/repo"
assert_eq 2 $? "bash scripts/ship.sh desde el worktree: bloquea"
run_hook 'python3 scripts/evidence.py run --task-dir T1' "$WS/worktrees/T1/repo"
assert_eq 2 $? "python3 scripts/evidence.py: bloquea (la otra mitad del bug)"
run_hook 'cd worktrees/T1/repo && scripts/ship.sh T1 repo' "$WS"
assert_eq 2 $? "cd al worktree inline + script relativo: bloquea"
out="$(jq -nc --arg c 'bash scripts/ship.sh T1 repo' --arg d "$WS/worktrees/T1/repo" \
  '{tool_input:{command:$c},cwd:$d}' | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" 2>&1 >/dev/null)" || true
assert_contains "$out" '$CLAUDE_PROJECT_DIR/scripts/ship.sh' "el mensaje da la línea corregida exacta"

echo "── lo legítimo pasa (doble existencia, no lista de nombres)"

run_hook 'bash scripts/own.sh' "$WS/worktrees/T1/repo"
assert_eq 0 $? "el repo tiene su PROPIO scripts/own.sh: legítimo"
run_hook 'bash scripts/ship.sh T1 repo' "$WS"
assert_eq 0 $? "desde la raíz del workspace resuelve: pasa"
run_hook 'bash "$CLAUDE_PROJECT_DIR/scripts/ship.sh" T1 repo' "$WS/worktrees/T1/repo"
assert_eq 0 $? "ya corregido con CLAUDE_PROJECT_DIR: pasa"
run_hook 'bash scripts/nope.sh' "$WS/worktrees/T1/repo"
assert_eq 0 $? "el harness NO tiene ese script: sin sustitución no se opina"
run_hook 'git commit -m "corre scripts/ship.sh a mano"' "$WS/worktrees/T1/repo"
assert_eq 0 $? "texto entre comillas no es un comando: pasa"
run_hook 'ls -la' "$WS/worktrees/T1/repo"
assert_eq 0 $? "un comando sin scripts/: pasa"
run_hook 'bash scripts/ship.sh' "$WS/repos/otro"
assert_eq 0 $? "cwd fuera de worktrees/: no es asunto de este hook"

echo "── fail-open"

printf '{"tool_input":{"command":"bash scripts/ship.sh"},"cwd":"%s"}' "$WS/worktrees/T1/repo" \
  | PATH="$(t_path_without jq)" CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 $? "sin jq: fail-open"
printf '' | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 $? "sin payload: fail-open"

t_done
