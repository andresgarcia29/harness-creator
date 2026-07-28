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

# 3d. Los artefactos de tasks/<id>/ se derivan de la RUTA, no de la sesión.
#     Son los más citables por la compliance matrix (sello del precheck,
#     manifiestos EV-*.json, delta-spec) y antes caían en el caso por defecto
#     de task_of: citarlos daba SIEMPRE "citado pero NADIE LO LEYÓ" y el ship
#     quedaba sin salida, con el mensaje del gate empujando a abrir el archivo,
#     que era justo lo único que no se registraba.
mkdir -p "$WS/tasks/COR-11/evidence"
echo '{}' > "$WS/tasks/COR-11/precheck-atlas.json"
jq -nc '{tool_name:"Read", tool_input:{file_path:"'"$WS"'/tasks/COR-11/precheck-atlas.json"},
         session_id:"sess-virgen-2", cwd:"'"$WS"'"}' | "$HOOK"
assert_contains "$(cat "$WS/tasks/COR-11/evidence.log" 2>/dev/null)" "precheck-atlas.json" \
  "un sello de precheck SÍ se registra, aunque la sesión no haya tocado un worktree"
assert_not_contains "$(cat "$WS/tasks/COR-11/evidence.log" 2>/dev/null)" "read-ws" \
  "y se atribuye por RUTA (kind 'read'), no por puntero de sesión"

# 4. id con caracteres raros → no construye rutas con él
payload Read "{\"file_path\":\"$WS/worktrees/../../../etc/x/repo/f.go\"}" | "$HOOK"
assert_no_file "$WS/tasks/../../../etc" "id malicioso no crea rutas fuera de tasks/"

# 5. Bash con test: la tarea viene del TEXTO del comando (el cwd del hook es la raíz)
payload Bash "{\"command\":\"cd worktrees/COR-9/atlas && go test ./...\"}" "$WS" | "$HOOK"
assert_contains "$(cat "$WS/tasks/COR-9/evidence.log")" "go test" "un test que corrió queda como evidencia 'ran'"

# 6. fail-open: payload roto sale 0
echo "esto no es json" | "$HOOK"
assert_eq "0" "$?" "payload roto: exit 0 (observa, jamás bloquea)"

echo
echo "── leer por Bash también es leer (caso de campo)"
# El reviewer inspecciona con git show / rg / cat / sed -n, que es exactamente
# lo que la economía de tokens le pide, y nada quedaba en evidence.log:
# gate_evidence lo acusaba de no leer lo que sí leyó. El criterio nuevo es que
# el token resuelva a un archivo REAL, no la extensión ni que huela a test.

mkdir -p "$WS/worktrees/COR-12/atlas/docs"
echo 'x' > "$WS/worktrees/COR-12/atlas/docs/esquema.sql"
echo 'y' > "$WS/worktrees/COR-12/atlas/nota.md"

# 7. cat de un .sql (extensión que el filtro viejo ignoraba) → ran-file
payload Bash "{\"command\":\"cat worktrees/COR-12/atlas/docs/esquema.sql\"}" "$WS" | "$HOOK"
assert_contains "$(cat "$WS/tasks/COR-12/evidence.log" 2>/dev/null)" "esquema.sql" \
  "cat de un archivo real: queda como ran-file (aunque sea .sql)"

# 8. grep -n sobre un .md → ran-file (los flags no se confunden con rutas)
payload Bash "{\"command\":\"grep -n titulo worktrees/COR-12/atlas/nota.md\"}" "$WS" | "$HOOK"
assert_contains "$(cat "$WS/tasks/COR-12/evidence.log")" "nota.md" \
  "grep sobre un archivo real: queda registrado"

# 9. pytest con archivo::caso → el ARCHIVO queda registrado
mkdir -p "$WS/worktrees/COR-12/atlas/tests"
printf 'def test_a():\n    pass\n' > "$WS/worktrees/COR-12/atlas/tests/test_a.py"
payload Bash "{\"command\":\"pytest worktrees/COR-12/atlas/tests/test_a.py::test_a\"}" "$WS" | "$HOOK"
assert_contains "$(cat "$WS/tasks/COR-12/evidence.log")" "tests/test_a.py" \
  "cita pytest archivo::caso: el archivo base queda en el log"

# 10. un token que NO resuelve a archivo no inventa evidencia
payload Bash "{\"command\":\"cat worktrees/COR-12/atlas/no-existe.txt\"}" "$WS" | "$HOOK"
assert_not_contains "$(cat "$WS/tasks/COR-12/evidence.log")" "no-existe.txt" \
  "un archivo inexistente no deja rastro (leer de verdad es el criterio)"

echo
echo "── mark-read.sh: el registro de lecturas SIN el hook (otros agentes)"
# Caso de campo: operando el harness desde otro agente (AGENTS.md lo promete),
# evidence.log no existía jamás y gate_evidence era impasable; la salida era
# editar el log a mano, que anula el gate. Este es el camino legítimo.

MARK="$ROOT/templates/scripts/mark-read.sh"
mkdir -p "$WS/scripts"; cp "$MARK" "$WS/scripts/mark-read.sh"

# 11. archivo real del worktree, citado con ::caso: se registra tal cual
out="$(bash "$WS/scripts/mark-read.sh" COR-12 "tests/test_a.py::test_a" 2>&1)"; rc=$?
assert_eq 0 "$rc" "cita con ::caso de un archivo real del worktree: sale 0"
assert_contains "$(cat "$WS/tasks/COR-12/evidence.log")" "tests/test_a.py::test_a" \
  "la cita queda registrada TAL CUAL (gate_evidence la matchea directa)"

# 12. archivo del workspace por ruta relativa
echo x > "$WS/docs-adr.md"
bash "$WS/scripts/mark-read.sh" COR-12 "docs-adr.md" >/dev/null 2>&1
assert_contains "$(cat "$WS/tasks/COR-12/evidence.log")" "docs-adr.md" \
  "un archivo del workspace también se puede registrar"

# 13. ruta inexistente: se niega con exit 3 y lo dice
out="$(bash "$WS/scripts/mark-read.sh" COR-12 "no/existe.go" 2>&1)"; rc=$?
assert_eq 3 "$rc" "ruta inexistente: exit 3"
assert_contains "$out" "NO existe" "y nombra la ruta rechazada"
assert_not_contains "$(cat "$WS/tasks/COR-12/evidence.log")" "no/existe.go" \
  "y NO queda registrada (registrar fantasmas anularía el gate)"

# 14. task-id hostil: rechazado sin construir rutas
out="$(bash "$WS/scripts/mark-read.sh" "../evil" "x.go" 2>&1)"; rc=$?
assert_eq 2 "$rc" "task-id con traversal: rechazado"

t_done
