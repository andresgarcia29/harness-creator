#!/usr/bin/env bash
# track-read.sh — el libro de a bordo de la evidencia. PostToolUse sobre
# Read/Grep/Glob/Bash y sobre las tools de Serena: apunta QUÉ artefactos abrió
# realmente un agente, en tasks/<id>/evidence.log. ship.sh (gate_evidence)
# intersecta lo CITADO por la compliance matrix con lo LEÍDO aquí.
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
  printf '%s\n' "$1" > "$STATE_DIR/$sid" 2>/dev/null || true
  # ── Y EL PUNTERO INVERSO: qué sesión maneja ESTA tarea ──
  # El id de sesión solo existe acá, dentro del payload del hook. Sin el
  # inverso, `harness-policy.py transition` no tiene forma de estampar en
  # state.json quién manejó cada fase, y "el orquestador arrastró una sesión
  # por toda la tarea" queda como algo que solo se puede ver leyendo
  # transcripts a posteriori. Este archivo tiene UN escritor por tarea a la vez
  # en la práctica, y si dos sesiones se la disputan gana la última, que es
  # justamente la que está manejando.
  ok_id "$1" || return 0
  [ -d "$WS/tasks/$1" ] || return 0
  printf '%s\n' "$sid" > "$WS/tasks/$1/.session" 2>/dev/null || true; }

recall_task() { ok_id "$sid" || return 0
  head -1 "$STATE_DIR/$sid" 2>/dev/null; }

# El proyecto que la sesión activó en Serena, al lado del puntero de tarea y
# con la misma disciplina: por session_id, jamás global. Ver el bloque SERENA
# de más abajo para por qué hace falta.
remember_proj() { ok_id "$sid" || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$STATE_DIR/$sid.serena" 2>/dev/null || true; }

recall_proj() { ok_id "$sid" || return 0
  head -1 "$STATE_DIR/$sid.serena" 2>/dev/null; }

# ── ¿este comando CORRE una suite? ───────────────────────────────────
# Antes se decidía por SUBSTRING desnudo (*test*|*spec*|...), y eso marcaba
# como corrida de tests al MCP de Playwright que trae el propio harness:
# `npm exec @playwright/mcp@latest` casa por el `test` de `latest`, y cada
# Chromium con `--user-data-dir=.../mcp-chrome-for-testing-*` también. Una
# corrida inventada en evidence.log es peor que ninguna: gate_evidence la
# intersecta con la matriz de compliance y da por probado lo que nadie corrió.
#
# evidence.py cerró esos dos falsos positivos mirando la POSICIÓN DE COMANDO y
# exigiendo token DELIMITADO; su _TEST_TOKENS se declaraba "espejo de
# track-read.sh" y el espejo se había quedado atrás (COR-661). Misma regla acá.
nombra_suite() {  # nombra_suite <palabra>: `test:unit` sí, `latest` no
  case " $(printf '%s' "$1" | tr ':.@/_-' '      ') " in
    *" test "*|*" tests "*|*" spec "*|*" specs "*) return 0 ;;
  esac
  return 1
}
palabra_cmd() {  # el nombre con el que se INVOCA: basename sin extensión
  local w="${1##*/}"
  case "$w" in *.exe|*.sh|*.bash|*.py|*.js|*.mjs|*.cjs) w="${w%.*}" ;; esac
  printf '%s' "$w"
}
segmento_suite() {  # segmento_suite <un solo comando, sin separadores>
  local head w
  # Sin globbing: el comando trae `./...` y `tests/*.py`, y expandirlos acá
  # cambiaría lo que se juzga por lo que haya en disco.
  set -f
  # shellcheck disable=SC2086
  set -- $1
  set +f
  # 1. saltar envoltorios, sus flags y las asignaciones de entorno
  while [ $# -gt 0 ]; do
    case "$1" in -*) shift; continue ;; esac
    case "${1%%/*}" in *=*) shift; continue ;; esac
    case "$(palabra_cmd "$1")" in
      sh|bash|zsh|dash|ksh|env|setsid|nohup|time|nice|ionice|stdbuf|sudo|doas|timeout|python|python2|python3|node|uv|uvx|npx|poetry|pdm|pipenv|hatch|rye)
        shift; continue ;;
    esac
    break
  done
  [ $# -gt 0 ] || return 1
  head="$(palabra_cmd "$1")"
  # `uv run pytest`: el subcomando del envoltorio tampoco dice nada del
  # trabajo. Solo si es la PALABRA suelta: `bash tests/run.sh` trae una ruta,
  # y ahí `run` es el nombre del script, no un subcomando que saltar.
  case "$1" in
    */*) : ;;
    *) case "$head" in
         run|exec) shift; [ $# -gt 0 ] || return 1; head="$(palabra_cmd "$1")" ;;
       esac ;;
  esac
  case "$head" in pytest|py.test|jest|vitest|rspec|phpunit|tox|nose2) return 0 ;; esac
  # 2. con estos manda el SUBCOMANDO: `go test` sí, `go build` no
  case "$head" in
    go|cargo|mvn|gradle|gradlew|dotnet|swift|make|npm|pnpm|yarn|bun|deno) ;;
    *) nombra_suite "$head"; return $? ;;
  esac
  shift
  while [ $# -gt 0 ]; do
    case "$1" in -*) shift; continue ;; esac
    w="$(palabra_cmd "$1")"
    case "$w" in run|exec) shift; continue ;; esac   # `npm run <script>`
    case "$w" in pytest|py.test|jest|vitest|rspec|phpunit|tox|nose2) return 0 ;; esac
    nombra_suite "$w"; return $?
  done
  return 1
}
corre_suite() {  # corre_suite <la línea entera del agente>
  local seg segs
  # Segmento por segmento: el comando típico es `cd <worktree> && go test ./...`
  # y el head de la cadena entera sería `cd`, o sea que ninguna corrida real se
  # reconocería. Cada tramo se juzga solo.
  segs="$(printf '%s' "$1" | tr ';|&' '\n\n\n')"
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    if segmento_suite "$seg"; then return 0; fi
  done <<SEGEOF
$segs
SEGEOF
  return 1
}

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
  # id raro → no construimos rutas con él. `.` y `..` van aparte porque PASAN
  # el filtro de caracteres (el punto es legítimo en un task-id) y son justo
  # los dos que se salen de tasks/: un id `..` escribiría el evidence.log en la
  # raíz del workspace, donde ningún gate lo va a buscar.
  case "$task" in *[!A-Za-z0-9._-]*|.|..) return 0 ;; esac
  # ── UNA TAREA ARCHIVADA NO SE RESUCITA (#114) ───────────────────────
  # El `mkdir -p` de acá abajo era incondicional, así que este hook RECREABA
  # `tasks/<id>/` después de que /archive lo movió a `tasks/archive/<fecha>-<id>/`.
  # No es una carrera ni depende de la máquina: es el ORDEN del playbook (mueve
  # los artefactos en el paso 3 y retira los worktrees en el 5), así que le
  # pasaba a TODA tarea archivada al pie de la letra. Medido: un `worktree-task.sh
  # --rm` posterior al archivado dejaba `tasks/COR-944/evidence.log` con una sola
  # línea, y una tarea archivada con directorio vuelve a parecer viva para todo
  # lo que mire el filesystem, que es exactamente lo que el paso 5 existe para
  # evitar (ningún hook conoce el estado "archivada": todos derivan de la RUTA).
  #
  # El playbook además cambia el orden, que elimina la causa. Esto cubre lo otro:
  # CUALQUIER hook que dispare después del archivado, hoy o mañana. La evidencia
  # no se tira, se escribe donde la tarea vive ahora, que es su audit trail.
  local dir="$WS/tasks/$task" n c
  if [ ! -d "$dir" ]; then
    # Glob directo y NO `set --`: los posicionales de esta función son el kind y
    # la ruta que se van a escribir dos líneas más abajo, y pisarlos acá dejaba
    # el hook muriendo con "$2: unbound variable" bajo `set -u`.
    n=0
    for c in "$WS"/tasks/archive/*-"$task"; do
      [ -d "$c" ] && { n=$((n+1)); dir="$c"; }
    done
    case "$n" in
      0) dir="$WS/tasks/$task" ;;  # no está archivada: es una tarea viva sin dir todavía
      1) : ;;                      # archivada: su evidencia va a su audit trail
      # Dos archivados del mismo id: NO se elige. Escribir en la tarea
      # equivocada es peor que no escribir, porque gate_evidence citaría
      # después una corrida que pertenece a otra.
      *) return 0 ;;
    esac
  fi
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' "$ts" "$sid" "$1" "$2" >> "$dir/evidence.log" 2>/dev/null
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

    # ── UN TOKEN RELATIVO NO SE RESUELVE CONTRA UN SOLO DIRECTORIO (#127) ──
    # El `cwd` que llega en el payload es el de la SESIÓN, y en un SUBAGENTE no
    # es el árbol donde está mirando: un reviewer que corre
    # `sed -n '1406p' bun.lock` desde su pin dejaba `$WS/bun.lock`, que no
    # existe, y la lectura no se registraba. Después `gate_evidence` lo acusaba
    # de citar algo que "nadie leyó" y el ship rebotaba tres veces sobre una
    # lectura que SÍ ocurrió (y que el reviewer citaba textual).
    # Lo delator del caso: las lecturas por `Read` del MISMO subagente sí
    # quedaban, porque esas traen la ruta completa. Era la vía Bash la que se
    # perdía, y se perdía SOLO en subagentes, que es donde más se usa.
    #
    # Se prueban, en orden y sin inventar nada: el cwd reportado, un `cd` al
    # principio del propio comando (que es donde el agente dice dónde está), la
    # raíz del workspace, el proyecto que la sesión activó en Serena, y por
    # último los árboles de la tarea que esta sesión ya tocó (worktree y pin de
    # review). Solo se registra lo que EXISTE como archivo: sigue sin haber
    # forma de anotar una lectura que no pasó.
    cd_dir=""
    case "$cmd" in
      "cd "*)
        cd_dir="${cmd#cd }"; cd_dir="${cd_dir%%&&*}"; cd_dir="${cd_dir%%;*}"
        cd_dir="${cd_dir%"${cd_dir##*[! ]}"}"          # sin espacios al final
        cd_dir="$(printf '%s' "$cd_dir" | tr -d "\"'")"
        case "$cd_dir" in /*) : ;; *) cd_dir="$WS/$cd_dir" ;; esac ;;
    esac
    resuelve_rel() {  # resuelve_rel <token> → ruta existente, o vacío
      local b="$1" c d
      case "$b" in /*) [ -f "$b" ] && printf '%s' "$b"; return 0 ;; esac
      for c in "$cwd" "$cd_dir" "$WS" "$(recall_proj)"; do
        [ -n "$c" ] || continue
        [ -f "$c/$b" ] && { printf '%s' "$c/$b"; return 0; }
      done
      # Los árboles de la tarea que esta sesión ya tocó. Es el caso del
      # subagente: su cwd no dice nada, pero su tarea sí, y el archivo que cita
      # vive en SU árbol. El glob está acotado a esa tarea, no barre el disco.
      local task; task="$(recall_task)"
      case "$task" in ''|*[!A-Za-z0-9._-]*|.|..) return 0 ;; esac
      for d in "$WS/worktrees/$task"/*/ "$WS/worktrees/$task"/.review-*/; do
        [ -d "$d" ] || continue
        [ -f "$d$b" ] && { printf '%s' "$d$b"; return 0; }
      done
      return 0
    }
    # El cwd del hook es el de la SESIÓN (la raíz del workspace), no el del
    # comando: un "cd worktrees/COR-42/atlas && go test" corre en el worktree
    # pero el cwd reportado es la raíz. La tarea viene del TEXTO del comando.
    hint="$cwd"
    case "$cmd" in *worktrees/*) hint="worktrees/${cmd#*worktrees/}" ;; esac
    if corre_suite "$cmd"; then
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
    fi
    # ── LEER POR BASH TAMBIÉN ES LEER ──
    # Caso de campo: el reviewer inspecciona con git show, rg, cat o sed -n
    # (exactamente lo que la economía de tokens le pide: la ventana, no el
    # archivo entero) y NADA quedaba en evidence.log, así que gate_evidence
    # lo acusaba de no leer lo que sí leyó. El gate castigaba la conducta que
    # la constitución recomienda. El criterio ya no es la extensión ni que el
    # comando parezca de tests: es que el token RESUELVA a un archivo real
    # bajo el workspace. Acotado (40 tokens) y fail-open, como todo el hook.
    n=0
    for tok in $cmd; do
      n=$((n+1)); [ "$n" -gt 40 ] && break
      case "$tok" in
        -*|*=*) continue ;;           # flags y asignaciones no son artefactos
        *[/.]*) : ;;                  # solo tokens que parecen ruta/archivo
        *) continue ;;
      esac
      base="${tok%%::*}"              # pytest cita archivo::caso; el archivo es la base
      t="$(resuelve_rel "$base")"
      if [ -n "$t" ]; then
        emit ran-file "${base#"$WS"/}" "$t"
      fi
    done
    ;;

  # ── SERENA: LEER POR SÍMBOLO TAMBIÉN ES LEER ──────────────────────
  # El harness le pide al implementer que navegue y edite por símbolo
  # (find_symbol, find_referencing_symbols) en vez de abrir archivos enteros:
  # es el ahorro de tokens más grande de la implementación. Pero este hook solo
  # miraba Read/Grep/Glob/Bash, así que el agente OBEDIENTE no dejaba ni una
  # línea en evidence.log, y gate_evidence lo acusaba después de citar
  # artefactos que "nadie leyó". O sea: el gate castigaba exactamente la
  # conducta que la constitución exige, y el camino barato para pasarlo era
  # volver a grep. Un incentivo invertido no se arregla con otra frase en el
  # prompt; se arregla acá.
  #
  # LA RUTA VIENE RELATIVA AL PROYECTO ACTIVADO, no al workspace: Serena es
  # por-proyecto y el implementer hace activate_project sobre su worktree.
  # Por eso se recuerda ese proyecto (por sesión) y se reconstruye la ruta
  # completa: así la tarea se sigue derivando de la RUTA, que es la ley de
  # este hook, en vez de depender del puntero de sesión.
  mcp__serena__*)
    op="${tool#mcp__serena__}"
    case "$op" in
      activate_project)
        # El ancla de todo lo que sigue. También fija el puntero de tarea si la
        # ruta la trae, que es el caso normal: worktrees/<task>/<repo>.
        proj="$(printf '%s' "$payload" | jq -r '.tool_input.project // .tool_input.project_root // ""' 2>/dev/null)"
        [ -n "$proj" ] || exit 0
        remember_proj "$proj"
        t="$(task_of "$proj")"; [ -n "$t" ] && remember_task "$t"
        ;;
      find_symbol|find_referencing_symbols|get_symbols_overview|read_file|search_for_pattern|replace_symbol_body|insert_after_symbol|insert_before_symbol|replace_regex)
        # Editar un símbolo cuenta igual que leerlo: nadie reemplaza el cuerpo
        # de una función sin haber visto lo que reemplaza.
        rp="$(printf '%s' "$payload" | jq -r '.tool_input.relative_path // ""' 2>/dev/null)"
        [ -n "$rp" ] || exit 0
        case "$rp" in
          /*) t="$rp" ;;
          *) proj="$(recall_proj)"
             # Sin activate_project visto (sesión reanudada, hook que se perdió
             # el evento) se cae al workspace: la tarea saldrá del puntero de
             # sesión y el registro quedará marcado `sym-ws`. Peor atribución,
             # pero registro al fin: gate_evidence matchea por substring, así
             # que la cita del reviewer casa igual.
             if [ -n "$proj" ]; then t="$proj/$rp"; else t="$WS/$rp"; fi ;;
        esac
        emit sym "${t#"$WS"/}" "$t"
        ;;
    esac
    ;;
esac
exit 0
