#!/usr/bin/env bash
# test_track_read.sh — la evidencia (track-read.sh): dentro de un worktree la
# tarea se DERIVA de la ruta (jamás de estado global), ids raros no construyen
# rutas, los archivos del workspace se atribuyen a la tarea de la sesión (con
# puntero por session_id, no compartido) y fuera del workspace no hay evidencia
# que apuntar.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

# El workspace va ANIDADO 3 niveles dentro del tmp: la aserción del id
# malicioso comprueba que tasks/../../../etc no exista, y en el /tmp plano
# de Linux esa ruta resolvía al /etc REAL del sistema (falso rojo que macOS,
# con su /var/folders profundo, nunca veía). Anidado, el traversal se queda
# dentro del sandbox del test en cualquier OS.
WSROOT="$WS"; WS="$WS/nivel1/nivel2/nivel3"; mkdir -p "$WS"
trap 'rm -rf "$WSROOT"' EXIT

HOOK="$ROOT/templates/hooks/track-read.sh"
export CLAUDE_PROJECT_DIR="$WS"

payload() {  # payload <tool> <json-de-tool_input> [cwd]
  jq -nc --arg t "$1" --argjson i "$2" --arg c "${3:-$WS}" \
    '{tool_name:$t, tool_input:$i, session_id:"sess-test", cwd:$c}'
}

echo "── track-read.sh"

# 1. Read dentro de un worktree → evidencia en LA tarea de esa ruta
payload Read "{\"file_path\":\"$WS/worktrees/COR-9/atlas/auth.go\"}" | "$HOOK"
assert_file "$WS/tasks/COR-9/evidence.log" "Read en worktree apunta evidencia"
assert_contains "$(cat "$WS/tasks/COR-9/evidence.log")" "auth.go" "la ruta leída queda en el log"

# 2. dos tareas, cero contaminación cruzada
payload Read "{\"file_path\":\"$WS/worktrees/COR-10/atlas/pay.go\"}" | "$HOOK"
assert_not_contains "$(cat "$WS/tasks/COR-9/evidence.log")" "pay.go" "COR-9 no ve lecturas de COR-10"
assert_contains "$(cat "$WS/tasks/COR-10/evidence.log")" "pay.go" "COR-10 tiene su propia evidencia"

# 3. archivos del WORKSPACE: sí son evidencia, atribuida a la tarea de la sesión.
#    Antes se descartaban, y como gate_evidence SÍ acepta artefactos relativos al
#    workspace (busca en "$WS/$art" además de "$WT/$art"), citar scripts/ship.sh
#    o un ADR daba siempre "citado pero NADIE LO LEYÓ": las dos mitades del mismo
#    gate no se ponían de acuerdo y ningún script del workspace podía sustentar
#    un requirement.
payload Read "{\"file_path\":\"$WS/scripts/ship.sh\"}" | "$HOOK"
assert_contains "$(cat "$WS/tasks/COR-10/evidence.log")" "scripts/ship.sh" \
  "un archivo del workspace SÍ es evidencia (la tarea sale de la sesión)"
assert_contains "$(cat "$WS/tasks/COR-10/evidence.log")" "read-ws" \
  "queda marcado read-ws: se atribuyó por sesión, no por ruta"
assert_not_contains "$(cat "$WS/tasks/COR-9/evidence.log")" "scripts/ship.sh" \
  "va a la tarea ACTUAL de la sesión, no a todas"

# 3b. fuera del WORKSPACE no es evidencia de nada, por más sesión que haya
payload Read "{\"file_path\":\"/etc/hosts\"}" | "$HOOK"
found=$(grep -rl "/etc/hosts" "$WS/tasks" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$found" "leer fuera del workspace no se atribuye a nadie"

# 3c. una sesión que todavía no tocó ningún worktree no tiene a quién atribuir.
#     Esto es lo que distingue el puntero por sesión del .harness/current-task
#     global que causó el bug original: sin tarea propia, se calla.
jq -nc '{tool_name:"Read", tool_input:{file_path:"'"$WS"'/README.md"},
         session_id:"sess-virgen", cwd:"'"$WS"'"}' | "$HOOK"
found=$(grep -rl "README.md" "$WS/tasks" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0" "$found" "sesión sin worktree previo: no adopta una tarea ajena"

# 4. id con caracteres raros → no construye rutas con él
payload Read "{\"file_path\":\"$WS/worktrees/../../../etc/x/repo/f.go\"}" | "$HOOK"
assert_no_file "$WS/tasks/../../../etc" "id malicioso no crea rutas fuera de tasks/"

# 5. Bash con test: la tarea viene del TEXTO del comando (el cwd del hook es la raíz)
payload Bash "{\"command\":\"cd worktrees/COR-9/atlas && go test ./...\"}" "$WS" | "$HOOK"
assert_contains "$(cat "$WS/tasks/COR-9/evidence.log")" "go test" "un test que corrió queda como evidencia 'ran'"

# 6. fail-open: payload roto sale 0
echo "esto no es json" | "$HOOK"
assert_eq "0" "$?" "payload roto: exit 0 (observa, jamás bloquea)"

t_done
