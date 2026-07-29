#!/usr/bin/env bash
# test_guard_broad_add.sh: el diente contra el `git add` amplio en un worktree
# que varias tareas del DAG comparten.
#
# CASO DE CAMPO: worktree-task.sh crea el árbol en worktrees/<task-id>/<repo>,
# o sea UNO por (tarea, repo). La doctrina del harness decía lo contrario
# ("cada tarea tiene su worktree"), y sobre esa premisa falsa se lanzaron dos
# tareas del mismo repo en paralelo: el `git add -A` de una se llevó SEIS
# archivos de la otra a su commit. No se perdió trabajo, pero la atribución
# quedó mezclada y el index quedó a merced de una carrera.
#
# Lo que este test protege, y que es lo difícil de un hook así: que muerda
# donde hay riesgo y NO donde no lo hay. Un guard que bloquea de más se
# desactiva, y entonces no protege nada.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

HOOK="$ROOT/templates/hooks/guard-broad-add.sh"
mkdir -p "$WS/tasks/T1" "$WS/worktrees/T1/acme" "$WS/tasks/T2" "$WS/worktrees/T2/acme"

# T1: DOS tareas del DAG sobre el mismo repo (el caso del incidente).
cat > "$WS/tasks/T1/dag.json" <<'JSON'
{"schema":1,"tasks":[
  {"id":"T1-a","repo":"acme","depends_on":[]},
  {"id":"T1-b","repo":"acme","depends_on":["T1-a"]},
  {"id":"T1-c","repo":"otro","depends_on":[]}]}
JSON
# T2: UNA sola tarea del repo. Ahí el add amplio es legítimo.
cat > "$WS/tasks/T2/dag.json" <<'JSON'
{"schema":1,"tasks":[{"id":"T2-a","repo":"acme","depends_on":[]}]}
JSON

corre() {  # corre <comando> [cwd] → exit code del hook
  local cmd="$1" cwd="${2:-$WS}"
  printf '%s' "$(jq -n --arg c "$cmd" --arg w "$cwd" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$w}')" \
    | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" 2>"$WS/err.txt"
}
err() { cat "$WS/err.txt" 2>/dev/null; }

echo "── lo que TIENE que bloquear: add amplio en árbol compartido"

for flag in "-A" "--all" "-u" "--update" "."; do
  corre "git -C $WS/worktrees/T1/acme add $flag"
  [ $? -eq 2 ] && pass "git add $flag en worktree compartido: bloqueado" \
    || fail "git add $flag pasó: el árbol lo comparten dos tareas del DAG"
done
corre "git -C $WS/worktrees/T1/acme add -A"
assert_contains "$(err)" "COMPARTIDO" "el mensaje nombra el problema real"
assert_contains "$(err)" "POR NOMBRE" "y da la remediación exacta"
assert_contains "$(err)" "status --porcelain" "con el comando para ver qué es tuyo"

# commit -a mete al index igual que un add amplio
corre "git -C $WS/worktrees/T1/acme commit -am 'wip'"
[ $? -eq 2 ] && pass "git commit -am: bloqueado (mete al index igual)" \
  || fail "git commit -am pasó"
corre "git -C $WS/worktrees/T1/acme commit --all -m x"
[ $? -eq 2 ] && pass "git commit --all: bloqueado" || fail "git commit --all pasó"

# La tarea también se deriva del cwd, no solo del -C
corre "git add -A" "$WS/worktrees/T1/acme"
[ $? -eq 2 ] && pass "sin -C, la tarea sale del cwd: bloqueado" \
  || fail "con la ruta solo en el cwd no bloqueó"

echo
echo "── lo que NO puede bloquear: si muerde de más, alguien lo apaga"

corre "git -C $WS/worktrees/T2/acme add -A"
[ $? -eq 0 ] && pass "UNA sola tarea del repo en el DAG: el add amplio es legítimo" \
  || fail "bloqueó un add amplio donde nadie comparte el árbol"

corre "git -C $WS/worktrees/T1/acme add src/main.go internal/db.go"
[ $? -eq 0 ] && pass "add por nombre: pasa (es justo lo que se pide)" \
  || fail "bloqueó un add explícito"

# El hook juzga COMANDOS, no texto: un mensaje de commit que MENCIONA el patrón
# no es el patrón. Es la misma lección que ya pagó guard-build-slot.
corre "git -C $WS/worktrees/T1/acme commit -m 'docs: prohibido git add -A en worktrees'"
[ $? -eq 0 ] && pass "un mensaje de commit que MENCIONA 'git add -A' no es un add amplio" \
  || fail "bloqueó por el texto del mensaje, no por el comando"

corre "cat <<'EOF' > nota.md
recordá no usar git add -A acá
EOF" "$WS/worktrees/T1/acme"
[ $? -eq 0 ] && pass "el cuerpo de un heredoc tampoco es un comando" \
  || fail "bloqueó por el contenido de un heredoc"

corre "git add -A" "$WS"
[ $? -eq 0 ] && pass "fuera de un worktree: no es asunto de este hook" \
  || fail "bloqueó un add amplio fuera de worktrees/"

rm -f "$WS/tasks/T1/dag.json"
corre "git -C $WS/worktrees/T1/acme add -A"
[ $? -eq 0 ] && pass "sin dag.json no hay tareas hermanas declaradas: pasa" \
  || fail "bloqueó sin poder saber si el árbol es compartido"
cat > "$WS/tasks/T1/dag.json" <<'JSON'
{"schema":1,"tasks":[
  {"id":"T1-a","repo":"acme","depends_on":[]},
  {"id":"T1-b","repo":"acme","depends_on":["T1-a"]}]}
JSON

echo
echo "── sin jq: fail-CLOSED (el daño es silencioso y difícil de deshacer)"
NOJQ="$(t_path_without jq)"
printf '%s' "$(jq -n --arg c "git -C $WS/worktrees/T1/acme add -A" --arg w "$WS" \
  '{tool_name:"Bash", tool_input:{command:$c}, cwd:$w}')" \
  | PATH="$NOJQ" CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" 2>"$WS/err.txt"
[ $? -eq 2 ] && pass "sin jq y con add amplio en un worktree: bloquea por precaución" \
  || fail "sin jq dejó pasar un add amplio"
assert_contains "$(err)" "jq" "y dice que la causa es la herramienta ausente"
printf '%s' "$(jq -n --arg c "git add src/main.go" --arg w "$WS" \
  '{tool_name:"Bash", tool_input:{command:$c}, cwd:$w}')" \
  | PATH="$NOJQ" CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" 2>/dev/null
[ $? -eq 0 ] && pass "sin jq, un add por nombre sigue pasando (fail-closed acotado)" \
  || fail "sin jq bloqueó todo, que es un guard que alguien va a apagar"

echo
echo "── el hook está cableado y registrado (si no, no corre nunca)"
assert_contains "$(cat "$ROOT/templates/settings.json.tmpl")" "guard-broad-add.sh" \
  "settings.json.tmpl lo registra en PreToolUse Bash"
assert_contains "$(cat "$ROOT/skills/harness-init/SKILL.md")" "guard-broad-add.sh" \
  "y la tabla de generación lo declara (un template sin fila ahí no se instala)"

t_done
