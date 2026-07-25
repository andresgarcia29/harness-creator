#!/usr/bin/env bash
# track-read.sh — el libro de a bordo de la evidencia. PostToolUse sobre
# Read/Grep/Glob/Bash: apunta QUÉ artefactos abrió realmente un agente, en
# tasks/<id>/evidence.log. ship.sh (gate_evidence) intersecta lo CITADO por la
# compliance matrix con lo LEÍDO aquí.
#
# POR QUÉ EXISTE: el reviewer escribe una matriz que dice "AUTH-3 está cubierto
# por auth_test.go". Nada comprobaba que hubiera abierto auth_test.go. La ley del
# harness es que los agentes proponen y los sistemas deterministas verifican;
# sin este registro, el verificador proponía.
#
# ── LA TAREA SE DERIVA DE LA RUTA, NO SE GUARDA ──
# La primera versión leía .harness/current-task: UN archivo global. Con dos
# sesiones abiertas (y tenemos diez) la segunda pisaba a la primera y la
# evidencia se apuntaba en la tarea EQUIVOCADA — un gate podía pasar con
# evidencia de otro trabajo. Peor: nadie escribía ese archivo, así que el hook
# salía siempre sin registrar nada y gate_evidence bloqueaba TODOS los ships.
#
# La ruta ya dice la tarea: worktrees/<task>/<repo>/... La derivamos de ahí.
# Sin estado compartido no hay estado que corromper: diez sesiones en diez
# worktrees se atribuyen solas, y no hay archivo que se pueda quedar rancio.
# Es la misma lección que el lock de ship.sh — el estado compartido es el bug.
#
# Como ui-emit.sh: OBSERVA, jamás bloquea, sale 0 SIEMPRE (fail-open). Los que
# bloquean (block-direct-push, guard-canonical) son fail-CLOSED a propósito.
set -u

exit_ok() { exit 0; }
trap exit_ok EXIT
command -v jq >/dev/null 2>&1 || exit 0

WS="${CLAUDE_PROJECT_DIR:-$PWD}"

# task_of <ruta> → el id de la tarea dueña de esa ruta, o vacío.
# Acepta rutas absolutas o relativas al workspace.
task_of() {
  case "$1" in
    */worktrees/*) printf '%s' "${1#*/worktrees/}" | cut -d/ -f1 ;;
    worktrees/*)   printf '%s' "${1#worktrees/}"   | cut -d/ -f1 ;;
    # tasks/<id>/... TAMBIÉN lleva la tarea en la ruta, así que se deriva
    # igual que un worktree: exacto, y sin depender de que la sesión haya
    # tocado un worktree antes.
    #
    # POR QUÉ IMPORTA: gate_evidence exige que el reviewer haya ABIERTO el
    # artefacto que cita, y los artefactos más citables viven acá (el sello
    # del precheck, los manifiestos EV-*.json, el delta-spec). Sin este caso,
    # citarlos daba SIEMPRE "citado pero NADIE LO LEYÓ" y el ship quedaba sin
    # salida: el mensaje del gate te empuja a abrir el archivo, y abrirlo era
    # justo lo único que no se registraba. Costó dos rondas del presupuesto de
    # autofix y una acusación injusta a un reviewer que sí había verificado.
    */tasks/*)     printf '%s' "${1#*/tasks/}"     | cut -d/ -f1 ;;
    tasks/*)       printf '%s' "${1#tasks/}"       | cut -d/ -f1 ;;
    *) : ;;
  esac
}

payload="$(cat 2>/dev/null)"; [ -n "$payload" ] || exit 0
tool="$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"

# ── LECTURAS DEL WORKSPACE, NO SOLO DEL WORKTREE ──
# Bug de campo: gate_evidence acepta artefactos relativos al WORKSPACE (busca
# en "$WS/$art" además de "$WT/$art"), pero este hook solo registraba lo que
# colgaba de worktrees/. O sea que citar scripts/ship.sh o docs/adr/007.md como
# evidencia de compliance daba SIEMPRE "citado pero NADIE LO LEYÓ": las dos
# mitades del mismo gate no se ponían de acuerdo.
#
# La ruta de un archivo del workspace no dice a qué tarea pertenece, así que se
# usa la última tarea que ESTA sesión tocó. Y no, esto no reintroduce el
# .harness/current-task global que causó el bug de arriba: aquel era UNO para
# todas las sesiones y por eso se pisaban. Este va indexado por session_id, así
# que diez sesiones tienen diez punteros y ninguno se pisa. Se refresca en cada
# lectura dentro de un worktree, así que sigue a la sesión sola.
STATE_DIR="$WS/.harness/session-task"
ok_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

remember_task() { ok_id "$sid" || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$STATE_DIR/$sid" 2>/dev/null || true; }

recall_task() { ok_id "$sid" || return 0
  head -1 "$STATE_DIR/$sid" 2>/dev/null; }

# emit <kind> <ruta-o-cmd> <ruta-para-derivar-tarea>
emit() {
  local task kind="$1"; task="$(task_of "$3")"
  if [ -n "$task" ]; then
    remember_task "$task"
  else
    # Fuera de un worktree solo cuenta lo que cae DENTRO del workspace: un Read
    # de /etc/hosts o del home no es evidencia de ninguna tarea.
    case "$3" in /*) case "$3" in "$WS"/*) : ;; *) return 0 ;; esac ;; esac
    task="$(recall_task)"
    [ -n "$task" ] || return 0        # la sesión aún no tocó ningún worktree
    kind="$kind-ws"                   # marcado: se atribuyó por sesión, no por ruta
  fi
  set -- "$kind" "$2" "$3"
  case "$task" in *[!A-Za-z0-9._-]*) return 0 ;; esac   # id raro → no construimos rutas con él
  local log="$WS/tasks/$task/evidence.log"
  mkdir -p "$WS/tasks/$task" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' "$ts" "$sid" "$1" "$2" >> "$log" 2>/dev/null
}

case "$tool" in
  Read|NotebookRead)
    p="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"
    [ -n "$p" ] && emit read "${p#"$WS"/}" "$p"
    ;;
  Grep|Glob)
    p="$(printf '%s' "$payload" | jq -r '.tool_input.path // ""' 2>/dev/null)"
    [ -n "$p" ] && emit scan "${p#"$WS"/}" "$p"
    ;;
  Bash)
    # Un test que CORRIÓ es la evidencia más fuerte que hay. La tarea se deriva
    # del directorio donde corrió (cwd del tool), que también es el worktree.
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)"
    [ -n "$cmd" ] || exit 0
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)"
    # El cwd del hook es el de la SESIÓN (la raíz del workspace), no el del
    # comando: un "cd worktrees/COR-42/atlas && go test" corre en el worktree
    # pero el cwd reportado es la raíz. La tarea viene del TEXTO del comando.
    hint="$cwd"
    case "$cmd" in *worktrees/*) hint="worktrees/${cmd#*worktrees/}" ;; esac
    case "$cmd" in
      *test*|*spec*|*pytest*|*jest*|*vitest*|*rspec*|*"go test"*|*gradle*|*mvn*|*cargo*)
        emit ran "$(printf '%s' "$cmd" | cut -c1-160)" "$hint"
        for tok in $cmd; do
          case "$tok" in
            -*|*=*) continue ;;
            *[/.]*) : ;;              # solo tokens que parecen ruta/archivo
            *) continue ;;            # ("test" de "go test" no es un artefacto)
          esac
          case "$tok" in
            *test*|*spec*|*.go|*.py|*.ts|*.js|*.rs|*.java|*.rb)
              # la ruta del archivo de test manda sobre el cwd si trae worktree
              t="$tok"; case "$t" in /*) : ;; *) t="$cwd/$tok" ;; esac
              emit ran-file "${tok#"$WS"/}" "$t" ;;
          esac
        done
        ;;
    esac
    ;;
esac
exit 0
