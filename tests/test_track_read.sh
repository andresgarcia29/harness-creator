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

# 5b. El MCP de Playwright NO es una corrida de tests. El filtro era por
# SUBSTRING desnudo, así que `@playwright/mcp@latest` casaba por el `test` de
# `latest` y cada Chromium por `mcp-chrome-for-testing-*`. Una corrida inventada
# en evidence.log es peor que ninguna: gate_evidence la intersecta con la matriz
# de compliance y da por probado lo que nadie corrió. evidence.py ya cerró estos
# dos exactos mirando la posición de comando; este hook se declaraba su espejo y
# se había quedado atrás (COR-661).
antes="$(cat "$WS/tasks/COR-9/evidence.log")"
payload Bash "{\"command\":\"cd worktrees/COR-9/atlas && npm exec @playwright/mcp@latest --browser chromium\"}" "$WS" | "$HOOK"
payload Bash "{\"command\":\"/tmp/ms-playwright/chromium/chrome --user-data-dir=/tmp/ms-playwright-mcp/mcp-chrome-for-testing-abc\"}" "$WS/worktrees/COR-9/atlas" | "$HOOK"
assert_not_contains "$(cat "$WS/tasks/COR-9/evidence.log")" "playwright/mcp" \
  "el MCP de Playwright NO se registra como corrida de tests"
assert_not_contains "$(cat "$WS/tasks/COR-9/evidence.log")" "mcp-chrome-for-testing" \
  "ni el Chromium que levanta, aunque su ruta diga 'testing'"

# 5c. Y la contra-mitad, que es la que impide arreglar esto apagando el filtro:
# las invocaciones reales de suite se siguen registrando, cada una por su forma.
payload Bash "{\"command\":\"cd worktrees/COR-9/atlas && uv run pytest tests/\"}" "$WS" | "$HOOK"
payload Bash "{\"command\":\"cd worktrees/COR-9/atlas && npm run test\"}" "$WS" | "$HOOK"
payload Bash "{\"command\":\"cd worktrees/COR-9/atlas && npx vitest run src/a.test.ts\"}" "$WS" | "$HOOK"
log="$(cat "$WS/tasks/COR-9/evidence.log")"
assert_contains "$log" "uv run pytest" "el envoltorio no esconde la suite: uv run pytest sí cuenta"
assert_contains "$log" "npm run test" "npm run test también"
assert_contains "$log" "vitest run" "y vitest por su nombre de runner"

# 5d. Un comando que apenas NOMBRA un test no lo corre.
payload Bash "{\"command\":\"cd worktrees/COR-9/atlas && go build ./...\"}" "$WS" | "$HOOK"
assert_not_contains "$(cat "$WS/tasks/COR-9/evidence.log")" "go build" \
  "go build no es go test: el subcomando manda"

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
echo "── Serena: leer por símbolo también es leer"
# El harness le PIDE al implementer que navegue por símbolo, y este hook no
# registraba nada de eso: el agente obediente llegaba a gate_evidence sin una
# línea en el log y el gate lo acusaba de citar lo que "nadie leyó". El camino
# barato para pasarlo era volver a grep, o sea que el incentivo estaba dado
# vuelta contra la propia constitución.

mkdir -p "$WS/worktrees/COR-20/atlas/internal/auth"
echo 'package auth' > "$WS/worktrees/COR-20/atlas/internal/auth/auth.go"

# 15. activate_project fija el ancla: proyecto (para reconstruir rutas) y tarea
jq -nc '{tool_name:"mcp__serena__activate_project",
         tool_input:{project:"'"$WS"'/worktrees/COR-20/atlas"},
         session_id:"sess-serena", cwd:"'"$WS"'"}' | "$HOOK"
assert_file "$WS/.harness/session-task/sess-serena.serena" \
  "activate_project recuerda el proyecto de la sesión"

# 16. find_symbol trae la ruta RELATIVA al proyecto: se reconstruye y la tarea
#     se deriva de la RUTA (kind 'sym'), no del puntero de sesión
jq -nc '{tool_name:"mcp__serena__find_symbol",
         tool_input:{name_path:"Login", relative_path:"internal/auth/auth.go"},
         session_id:"sess-serena", cwd:"'"$WS"'"}' | "$HOOK"
log="$(cat "$WS/tasks/COR-20/evidence.log" 2>/dev/null)"
assert_contains "$log" "internal/auth/auth.go" \
  "find_symbol deja el archivo en evidence.log de SU tarea"
assert_contains "$log" "	sym	" "y con kind 'sym' (lectura simbólica)"
assert_not_contains "$log" "sym-ws" \
  "atribuido por RUTA reconstruida, no por puntero de sesión"

# 16b. gate_evidence matchea por substring, así que la cita worktree-relativa
#      del reviewer (internal/auth/auth.go) casa con lo registrado. Esta es la
#      mitad que hacía impasable el gate para quien usaba Serena.
assert_contains "$log" "worktrees/COR-20/atlas/internal/auth/auth.go" \
  "la ruta queda completa: casa con la cita worktree-relativa y con la del ws"

# 17. editar un símbolo cuenta igual que leerlo
jq -nc '{tool_name:"mcp__serena__replace_symbol_body",
         tool_input:{name_path:"Login", relative_path:"internal/auth/auth.go", body:"x"},
         session_id:"sess-serena", cwd:"'"$WS"'"}' | "$HOOK"
assert_contains "$(cat "$WS/tasks/COR-20/evidence.log")" "sym" \
  "replace_symbol_body también registra (nadie reemplaza lo que no vio)"

# 18. sin activate_project previo se cae al workspace y se marca 'sym-ws':
#     peor atribución, pero registro al fin (antes no había ninguno)
payload Read "{\"file_path\":\"$WS/worktrees/COR-21/atlas/x.go\"}" | "$HOOK"
jq -nc '{tool_name:"mcp__serena__get_symbols_overview",
         tool_input:{relative_path:"internal/pay.go"},
         session_id:"sess-test", cwd:"'"$WS"'"}' | "$HOOK"
assert_contains "$(cat "$WS/tasks/COR-21/evidence.log" 2>/dev/null)" "sym-ws" \
  "sin proyecto activado: se atribuye por sesión y queda marcado sym-ws"

# 19. una tool de Serena que no lee nada no inventa evidencia
antes="$(cat "$WS/tasks/COR-20/evidence.log")"
jq -nc '{tool_name:"mcp__serena__list_dir", tool_input:{relative_path:"internal"},
         session_id:"sess-serena", cwd:"'"$WS"'"}' | "$HOOK"
assert_eq "$antes" "$(cat "$WS/tasks/COR-20/evidence.log")" \
  "list_dir no es una lectura: no toca el log"

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

echo
echo "── #114: una tarea ARCHIVADA no se resucita"
# El mkdir -p era incondicional, asi que este hook recreaba tasks/<id>/ despues
# de que /archive lo movio. No era una carrera: era el ORDEN del playbook (mover
# artefactos en el 3, retirar worktrees en el 5), asi que le pasaba a TODA tarea
# archivada al pie de la letra. Y una tarea archivada con directorio vuelve a
# parecer viva para todo lo que mire el filesystem, que es justo lo que el paso
# de retirar worktrees existe para evitar: ningun hook conoce el estado
# "archivada", todos derivan la tarea de la RUTA.
mkdir -p "$WS/tasks/archive/2026-08-09-COR-944"
payload Read "{\"file_path\":\"$WS/worktrees/COR-944/atlas/repo.go\"}" | "$HOOK"
assert_no_file "$WS/tasks/COR-944/evidence.log" \
  "#114: el hook NO recrea tasks/<id>/ de una tarea ya archivada"
[ ! -d "$WS/tasks/COR-944" ] && pass "#114: ni siquiera el directorio" \
  || fail "#114: recreo tasks/COR-944/, que es el estado que /archive existe para evitar"
assert_contains "$(cat "$WS/tasks/archive/2026-08-09-COR-944/evidence.log" 2>/dev/null)" "repo.go" \
  "#114: la evidencia se escribe donde la tarea vive ahora (el archive es su audit trail), no se tira"

# Dos archivados del mismo id: no se elige. Escribir en la tarea equivocada es
# peor que no escribir, porque gate_evidence citaria una corrida ajena.
mkdir -p "$WS/tasks/archive/2026-08-01-COR-777" "$WS/tasks/archive/2026-08-09-COR-777"
payload Read "{\"file_path\":\"$WS/worktrees/COR-777/atlas/dup.go\"}" | "$HOOK"
[ ! -d "$WS/tasks/COR-777" ] && pass "#114: con dos archivados del mismo id tampoco resucita" \
  || fail "#114: recreo tasks/COR-777/"
for d in "$WS/tasks/archive/2026-08-01-COR-777" "$WS/tasks/archive/2026-08-09-COR-777"; do
  assert_no_file "$d/evidence.log" "y no adivina cuál de los dos: $(basename "$d")"
done

# La tarea VIVA sigue igual: el directorio se crea como siempre.
payload Read "{\"file_path\":\"$WS/worktrees/COR-31/atlas/vivo.go\"}" | "$HOOK"
assert_contains "$(cat "$WS/tasks/COR-31/evidence.log" 2>/dev/null)" "vivo.go" \
  "una tarea viva sin directorio previo lo sigue creando (no se rompe el caso normal)"

t_done
