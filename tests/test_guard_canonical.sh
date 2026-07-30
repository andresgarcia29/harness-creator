#!/usr/bin/env bash
# test_guard_canonical.sh: LEY 0 con dientes. El harness no se edita durante
# una tarea.
#
# CASO DE CAMPO que obliga a este test: un agente haciendo una tarea de
# PRODUCTO tropieza con un gate que le da un falso rojo, se pone a "arreglar"
# el harness en medio de la tarea y entra en bucle. El encabezado de
# guard-canonical.sh DECLARABA la Ley 0 desde el primer dia, pero el `case`
# real solo cubria repos/ y el pin .review-*: con jq presente, scripts/,
# .claude/hooks/ y settings.json quedaban editables. La ley existia en la
# prosa y no en el codigo, que es la peor forma de tenerla: el humano cree
# que hay guarda y no la hay.
#
# La otra mitad del test es que la ley NO SE DERRAME. Un guard que bloquea de
# mas es un guard que alguien desactiva: un script NUEVO bajo scripts/ es de
# la instancia (pipeline-step-creator declara `run: scripts/mi.sh`), y el
# trabajo legitimo sobre el repo del plugin dentro de un worktree tampoco es
# "editar el harness de esta instancia".
set -u
. "$(dirname "$0")/lib.sh"
t_ws

HOOK="$ROOT/templates/hooks/guard-canonical.sh"

# Un workspace con la forma real de una instancia instalada.
mkdir -p "$WS/scripts/smoke" "$WS/scripts/cronjobs/jobs" "$WS/.claude/hooks" \
         "$WS/.claude/skills/mi-skill" "$WS/.claude/commands" \
         "$WS/repos/videocore" "$WS/worktrees/T1/.review-videocore" \
         "$WS/worktrees/T1/videocore/src" \
         "$WS/worktrees/T1/harness-creator/templates/scripts" \
         "$WS/tasks/T1"
: > "$WS/scripts/ship.sh"
: > "$WS/scripts/smoke/svc.sh"
: > "$WS/scripts/cronjobs/jobs/local-x.sh"
: > "$WS/.claude/settings.json"
: > "$WS/harness-policy.json"
# el bus de verdad: la ventana de escape tiene que EMITIR, y eso solo se
# comprueba con el emit.sh real escribiendo su jsonl real.
cp "$ROOT/templates/scripts/emit.sh" "$WS/scripts/emit.sh"

rc() {  # rc <path> → exit code; stderr queda en $WS/canon.err
  printf '{"tool_input":{"file_path":"%s"}}' "$1" \
    | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" 2>"$WS/canon.err" >/dev/null
  echo $?
}

echo "── el juez no se edita: scripts, hooks y la politica"

assert_eq 2 "$(rc "$WS/scripts/ship.sh")" "un script del harness que YA EXISTE: bloqueado"
err="$(cat "$WS/canon.err")"
assert_contains "$err" "Ley 0" "el mensaje nombra la ley que corta el bucle"
assert_contains "$err" "harness-bug.sh report" "y da el canal de vuelta (reportar, no arreglar)"
assert_contains "$err" "HARNESS_KNOWN_BUG" "y como desbloquear SU ship declarando el bug"
assert_contains "$err" "harness-update" "y remite al playbook que si puede tocarlo"
# la llave del escape NO se imprime: darsela al agente en bucle es no tener ley
assert_not_contains "$err" "update-in-progress" "el bloqueo NO entrega el comando que abre la ventana"

assert_eq 2 "$(rc "$WS/.claude/hooks/nuevo-hook.sh")" \
  "un hook NUEVO tambien es escribir ley: bloqueado aunque no exista"
assert_eq 2 "$(rc "$WS/.claude/settings.json")" \
  "settings.json es quien CABLEA los hooks: bloqueado"
assert_eq 2 "$(rc "$WS/harness-policy.json")" \
  "la politica es la ley escrita en datos: bloqueada"

echo
echo "── la ley no se derrama: lo que es de la INSTANCIA se escribe"

assert_eq 0 "$(rc "$WS/scripts/nuevo-paso.sh")" \
  "un script NUEVO bajo scripts/ es de la instancia (pipeline-step-creator lo declara)"
assert_eq 0 "$(rc "$WS/scripts/smoke/svc.sh")" "scripts/smoke/ es de la instancia (tabla de owner_of)"
assert_eq 0 "$(rc "$WS/scripts/cronjobs/jobs/local-x.sh")" "scripts/cronjobs/ tambien"
assert_eq 0 "$(rc "$WS/worktrees/T1/harness-creator/templates/scripts/ship.sh.tmpl")" \
  "trabajar sobre el REPO del plugin en un worktree es la tarea, no una violacion"
assert_eq 0 "$(rc "$WS/.claude/skills/mi-skill/SKILL.md")" "las skills locales son ley del workspace, no del harness"
assert_eq 0 "$(rc "$WS/.claude/commands/mio.md")" "los comandos locales tampoco los juzga esta ley"
assert_eq 0 "$(rc "$WS/tasks/T1/plan.md")" "los artefactos de la tarea: pasan"
assert_eq 0 "$(rc "$WS/worktrees/T1/videocore/src/app.ts")" "y el arbol vivo del implementer: pasa"

echo
echo "── la ventana de /harness-update: abusable, pero JAMAS silenciosa"
# No puede ser una variable de entorno: los hooks de Edit/Write corren en un
# proceso aparte y no ven lo que el agente exporto en un Bash previo.

mkdir -p "$WS/.harness"
touch "$WS/.harness/update-in-progress"
assert_eq 0 "$(rc "$WS/scripts/ship.sh")" "con la ventana abierta, /harness-update puede reescribir el harness"
bus="$WS/.harness/events.jsonl"
assert_file "$bus" "cada escritura bajo la ventana deja rastro en el bus"
busline="$(cat "$bus" 2>/dev/null)"
assert_contains "$busline" '"kind":"assumption"' "y el rastro es una ASSUMPTION (alguien asumio que podia)"
assert_contains "$busline" "Ley 0" "que nombra la ley que se salteo"
assert_contains "$busline" "ship.sh" "y el archivo exacto que se toco"

: > "$bus"
touch -t 202001010000 "$WS/.harness/update-in-progress"
assert_eq 2 "$(rc "$WS/scripts/ship.sh")" \
  "una ventana vieja no deroga la ley para siempre (caduca a la hora)"
assert_eq "" "$(cat "$bus")" "y una escritura bloqueada no emite assumption"
rm -f "$WS/.harness/update-in-progress"

echo
echo "── regresiones: las leyes que ya mordian siguen mordiendo"

assert_eq 2 "$(rc "$WS/repos/videocore/src/app.ts")" "el clon canonico sigue bloqueado (Ley 4)"
assert_contains "$(cat "$WS/canon.err")" "Ley 4" "con su mensaje intacto"
assert_eq 2 "$(rc "$WS/worktrees/T1/.review-videocore/x.ts")" "el arbol clavado sigue de SOLO LECTURA"
assert_contains "$(cat "$WS/canon.err")" "SOLO LECTURA" "con su mensaje intacto"

echo
echo "── fail-CLOSED sin jq, y fail-OPEN ante un payload que no dice nada"

NOJQ="$(t_path_without jq)"
nojq_rc() {
  printf '{"tool_input":{"file_path":"%s"}}' "$1" \
    | PATH="$NOJQ" CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1
  echo $?
}
assert_eq 2 "$(nojq_rc "$WS/scripts/ship.sh")" "sin jq: ship.sh se bloquea por precaucion"
assert_eq 2 "$(nojq_rc "$WS/.claude/hooks/guard-canonical.sh")" "sin jq: los hooks tambien"
assert_eq 2 "$(nojq_rc "$WS/harness-policy.json")" "sin jq: la politica entra en la misma red (paridad)"
assert_eq 2 "$(nojq_rc "$WS/repos/videocore/x.ts")" "sin jq: el clon canonico tambien"

# Un payload que no nombra archivo no es una violacion: es un evento que este
# hook no sabe juzgar. Bloquear ahi seria frenar trabajo por ruido.
assert_eq 0 "$(printf '%s' '{}' | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1; echo $?)" \
  "payload sin path: pasa"
assert_eq 0 "$(printf '%s' 'no soy json' | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1; echo $?)" \
  "payload corrupto: pasa"
assert_eq 0 "$(printf '' | CLAUDE_PROJECT_DIR="$WS" bash "$HOOK" >/dev/null 2>&1; echo $?)" \
  "payload vacio: pasa"

t_done
