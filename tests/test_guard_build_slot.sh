#!/usr/bin/env bash
# test_guard_build_slot.sh — el hook bloquea COMANDOS docker build/run, no
# TEXTO que los mencione. Caso de campo: un `git commit` cuyo mensaje decía
# "docker run" quedaba bloqueado porque el grep corría sobre el string entero,
# heredocs y comillas incluidos. Este hook no tenía ni un test.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

HOOK="$ROOT/templates/hooks/guard-build-slot.sh"

run_hook() {  # run_hook <command-string> → rc del hook (2 = bloquea, 0 = pasa)
  jq -nc --arg c "$1" '{tool_input:{command:$c}}' | bash "$HOOK" >/dev/null 2>&1
}

echo "── lo que SÍ es un build/run pelado sigue bloqueado"

run_hook 'docker build .'; assert_eq 2 $? "docker build pelado: bloquea"
run_hook 'docker run -it app'; assert_eq 2 $? "docker run pelado: bloquea"
run_hook 'sudo docker run app'; assert_eq 2 $? "sudo docker run: bloquea"
run_hook 'docker buildx build -t x .'; assert_eq 2 $? "docker buildx build: bloquea"
run_hook 'docker compose build'; assert_eq 2 $? "docker compose build: bloquea"
run_hook 'cd svc && docker build .'; assert_eq 2 $? "tras &&: sigue siendo posición de comando"
run_hook 'FOO=1 docker run app'; assert_eq 2 $? "con asignación de entorno delante: bloquea"
out="$(jq -nc --arg c 'docker build .' '{tool_input:{command:$c}}' | bash "$HOOK" 2>&1 >/dev/null)" || true
assert_contains "$out" "build-slot.sh" "el mensaje da la remediación exacta (el semáforo)"

echo "── texto que MENCIONA docker no es un comando docker"

run_hook 'git commit -m "fix docker run flags"'; assert_eq 0 $? \
  "mensaje de commit inline con 'docker run': PASA (caso de campo)"
run_hook "echo 'usa: docker build .'"; assert_eq 0 $? "echo entrecomillado: PASA"
cmd="$(printf "git commit -F- <<'EOF'\nfix: arregla el docker build de CI\n\ny documenta docker run\nEOF")"
run_hook "$cmd"; assert_eq 0 $? "heredoc de commit que menciona docker build: PASA (caso de campo)"
run_hook 'docker ps --filter name=build'; assert_eq 0 $? "docker ps: no es build ni run"
run_hook 'grep "docker build" README.md'; assert_eq 0 $? "grep del texto: PASA"

echo "── el cuerpo del heredoc no esconde un comando REAL de después"

cmd="$(printf "cat <<'EOF' > nota.md\nno pasa nada\nEOF\ndocker build .")"
run_hook "$cmd"; assert_eq 2 $? "docker build DESPUÉS del heredoc: sigue bloqueado"

echo "── bypass legítimo y fail-open"

run_hook 'bash scripts/build-slot.sh docker build .'; assert_eq 0 $? \
  "envuelto en build-slot.sh: pasa (ya está serializado)"
printf '{"tool_input":{"command":"docker build ."}}' \
  | PATH="$(t_path_without jq)" bash "$HOOK" >/dev/null 2>&1
assert_eq 0 $? "sin jq: fail-open (no bloquea nada)"
printf '' | bash "$HOOK" >/dev/null 2>&1
assert_eq 0 $? "sin payload: fail-open"

t_done
