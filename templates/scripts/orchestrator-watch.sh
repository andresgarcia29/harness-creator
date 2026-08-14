#!/usr/bin/env bash
# orchestrator-watch.sh: el watchdog del ORQUESTADOR. Cero tokens.
#
# POR QUÉ EXISTE, con el número delante: sobre 37 corridas de /smart-main con
# 30.067 eventos de bus fechados, el 51% del reloj (34,4 h de 67,9 h) son huecos
# de más de 20 minutos SIN UN SOLO EVENTO. No son fases lentas: son sesiones
# muertas o varadas que nadie relanza. Los peores: 249, 206, 182, 172, 167 y
# 160 minutos. El watchdog de smart.md vigila a los SUBAGENTES; a la sesión
# principal, que es la que orquesta, no la vigilaba nadie, y cuando muere se
# lleva el reloj entero hasta que un humano mira el panel.
#
# Este script es el que mira. No razona, no gasta un token, y lo único que
# sabe hacer es volver a poner en marcha lo que ya estaba en marcha:
# `/smart <task-id>` RETOMA por state.json (es su contrato desde el paso 0),
# así que relanzar es idempotente por construcción.
#
# Uso:
#   orchestrator-watch.sh status            qué ve, sin tocar nada (default)
#   orchestrator-watch.sh once              una pasada: relanza lo varado
#   orchestrator-watch.sh daemon            once en bucle cada INTERVAL
#
# Perillas (segundos):
#   HARNESS_ORCH_IDLE      720   sin eventos de bus = varado (12 min)
#   HARNESS_ORCH_INTERVAL  120   cada cuánto mira el modo daemon
#   HARNESS_ORCH_MAX       2     relanzamientos sin progreso antes del humano
#   HARNESS_ORCH_HANDOFF   60    quietud mínima para tomar un relevo de fase
#   HARNESS_ORCH_HANDOFF_TTL 21600  edad máxima de un marcador de relevo (6 h)
#   HARNESS_ORCH_OFF             cualquier valor = no relanza nada (kill switch)
#
# ── Y LAS PERILLAS QUE IMPIDEN QUE EL VIGILANTE SE COMA LA MÁQUINA ────
# No son de tiempo: son de CANTIDAD, y existen porque los límites de arriba son
# todos POR TAREA (el lease y MAX_TRIES) y ninguno mira el agregado. Cada
# `claude -p` es un pipeline entero que dura horas con su flota MCP completa, así
# que las sesiones no se van: se acumulan pasada tras pasada.
#
#   HARNESS_ORCH_MAX_LIVE     3     sesiones VIVAS lanzadas por este vigilante
#   HARNESS_ORCH_MAX_PER_PASS 2     relanzamientos por pasada (rampa, no escalón)
#   HARNESS_ORCH_MIN_FREE_MB  2048  piso de memoria libre para lanzar
#   HARNESS_ORCH_MAX_AGE_H    48    horas en la misma fase antes de escalar a
#                                   humano en vez de seguir relanzando
#
# El kill switch también es un ARCHIVO (.harness/orch-watch.off), porque quien
# lo necesita a las tres de la mañana no está para exportar variables.
set -uo pipefail

WS="$(cd "$(dirname "$0")/.." && pwd)"
IDLE="${HARNESS_ORCH_IDLE:-720}"
INTERVAL="${HARNESS_ORCH_INTERVAL:-120}"
MAX_TRIES="${HARNESS_ORCH_MAX:-2}"
HANDOFF_GRACE="${HARNESS_ORCH_HANDOFF:-60}"
HANDOFF_TTL="${HARNESS_ORCH_HANDOFF_TTL:-21600}"
MAX_LIVE="${HARNESS_ORCH_MAX_LIVE:-3}"
MAX_PER_PASS="${HARNESS_ORCH_MAX_PER_PASS:-2}"
MIN_FREE_MB="${HARNESS_ORCH_MIN_FREE_MB:-2048}"
MAX_AGE_H="${HARNESS_ORCH_MAX_AGE_H:-48}"
BUS="$WS/.harness/events.jsonl"
CLAIMS="$WS/.harness/claims"
STATE_DIR="$WS/.harness/orch-watch"

# shellcheck source=/dev/null
[ -f "$WS/scripts/emit.sh" ] && . "$WS/scripts/emit.sh" || emit() { :; }

# ── FASES DONDE NO HAY NADA QUE RELANZAR ──────────────────────────────
# `archive` terminó. `blocked` es una parada REGISTRADA: la tarea espera a un
# humano, y relanzarla sería pasarle por encima a la única señal que el harness
# tiene para pedir ayuda. `deploy` sí se vigila: deploy-watch corre aparte, pero
# la sesión que tiene que archivar al verde es esta misma.
terminal_phase() {  # terminal_phase <fase> → 0 si no hay nada que relanzar
  case "$1" in archive|blocked|"") return 0 ;; *) return 1 ;; esac
}

now_epoch() { date -u +%s; }

# ── EL RELOJ SE LEE DEL BUS, QUE ES LO ÚNICO COMPARTIDO ────────────────
# No se le pregunta al proceso (puede estar en otra máquina, en otro tmux o
# muerto sin dejar cadáver): se le pregunta al rastro que deja trabajar. Cuentan
# los eventos de ESTA tarea, que son los que ui-emit.sh etiqueta desde el cwd
# del worktree y los que emit.sh etiqueta con su 4º argumento.
#
# El piso es el mtime de state.json: una tarea recién iniciada que todavía no
# emitió nada NO lleva varada desde 1970.
last_event_epoch() {  # last_event_epoch <task-id> → epoch del último rastro
  local task="$1" ts="" floor=0 f m st="$WS/tasks/$task/state.json"
  if [ -f "$BUS" ] && command -v jq >/dev/null 2>&1; then
    ts="$(jq -r --arg t "$task" 'select(.task == $t) | .ts // empty' "$BUS" 2>/dev/null | tail -1)"
  fi
  floor="$(stat -f%m "$st" 2>/dev/null || stat -c%Y "$st" 2>/dev/null || echo 0)"
  case "$floor" in ''|*[!0-9]*) floor=0 ;; esac
  # ── LOS LOGS DE LA TAREA TAMBIÉN SON RASTRO ─────────────────────────
  # Un `deploy-watch` puede pasarse 39 minutos mirando un deploy (medido) y
  # emite al bus SOLO en los hitos: entre uno y otro la tarea se ve callada sin
  # estarlo, y relanzar ahí es levantar un orquestador sobre un deploy en vuelo.
  # Su log, en cambio, crece en cada poll. Cuesta un stat por archivo y cierra
  # justo la ventana donde este vigilante se pisaría con el otro.
  for f in "$WS/tasks/$task"/*.log; do
    [ -f "$f" ] || continue
    # NUESTRO propio log de relanzamiento no cuenta: si contara, el vigilante
    # se leería a sí mismo como actividad de la tarea y un `claude -p` que
    # muere en el arranque parecería una sesión trabajando.
    case "$f" in */orchestrator-watch.log) continue ;; esac
    m="$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)"
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    [ "$m" -gt "$floor" ] && floor="$m"
  done
  local e=0
  [ -n "$ts" ] && e="$(iso_to_epoch "$ts")"
  [ "$e" -gt "$floor" ] && { printf '%s' "$e"; return 0; }
  printf '%s' "$floor"
}

# ISO-8601 UTC → epoch, portable. BSD pide -j -f, GNU pide -d, y ninguno de los
# dos falla de forma parecida: sin las dos ramas, este script mide el tiempo
# solo en la mitad de las máquinas donde corre.
iso_to_epoch() {  # iso_to_epoch <2026-08-10T06:08:55Z> → epoch, 0 si no se pudo
  local iso="$1" e=""
  e="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)" \
    || e="$(date -u -d "$iso" +%s 2>/dev/null)" || e=""
  case "$e" in ''|*[!0-9]*) e=0 ;; esac
  printf '%s' "$e"
}

handoff_vencido() {  # handoff_vencido <task-id> → 0 si el marcador ya no vale
  local m
  m="$(stat -f%m "$WS/tasks/$1/handoff.json" 2>/dev/null \
       || stat -c%Y "$WS/tasks/$1/handoff.json" 2>/dev/null || echo 0)"
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  # Sin mtime legible NO se caduca: perder un relevo legítimo cuesta una tarea
  # varada, y esta guarda existe para lo contrario.
  [ "$m" -gt 0 ] || return 1
  [ "$(( $(now_epoch) - m ))" -gt "$HANDOFF_TTL" ]
}

# ── "SIN EVENTOS" NO ES "SIN TRABAJAR" ────────────────────────────────
# Es la misma acotación que smart.md le pone al watchdog de subagentes, y por
# el mismo caso de campo: un gate de navegador es UNA llamada bloqueante de
# nueve minutos que, por definición, no produce eventos mientras corre. El bus
# emite `tool-start` en cada Bash, así que la pregunta es determinista: si el
# último `tool-start` de la tarea NO tiene un `tool` posterior, hay una llamada
# EN VUELO y la sesión está trabajando. Matar a un orquestador sano cuesta
# doble: pierde lo que tenía en vuelo y lo relanza con el modelo caro.
call_in_flight() {  # call_in_flight <task-id> → 0 si hay una llamada abierta
  [ -f "$BUS" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local kind
  kind="$(jq -r --arg t "$1" 'select(.task == $t) | select(.kind == "tool-start" or .kind == "tool") | .kind' \
    "$BUS" 2>/dev/null | tail -1)"
  [ "$kind" = "tool-start" ]
}

# ── LA HUELLA DEL PROGRESO ────────────────────────────────────────────
# "Dos relanzamientos sin progreso" necesita una definición EJECUTABLE de
# progreso, o el contador castiga a una tarea que sí avanzó. Progreso = cambió
# la fase, o cambió el HEAD de alguno de sus worktrees. Las dos cosas son
# observables desde afuera y ninguna depende de que un agente las declare.
progress_fingerprint() {  # progress_fingerprint <task-id> → fase + HEADs
  local task="$1" phase wt out=""
  phase="$(jq -r '.phase // ""' "$WS/tasks/$task/state.json" 2>/dev/null || echo "")"
  for wt in "$WS/worktrees/$task"/*/; do
    [ -d "$wt" ] || continue
    out="$out $(basename "$wt")=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo '?')"
  done
  printf '%s|%s' "$phase" "$out"
}

# ── EL LEASE: UN RELANZADOR A LA VEZ, POR TAREA ───────────────────────
# mkdir es atómico en todo filesystem que importe (mismo patrón que el lock de
# creación de worktree-task.sh y el de ship.sh). Sin esto, dos pollers en dos
# máquinas que comparten el workspace por NFS lanzan DOS orquestadores sobre la
# misma tarea, que es exactamente el accidente que guard-worktree existe para
# frenar aguas abajo, y frenarlo aguas abajo ya cuesta una sesión pagada.
#
# El lease guarda el PID del claude que lanzamos: mientras ese proceso viva, la
# tarea tiene dueño y no se vuelve a tocar aunque el bus siga callado (un
# `claude -p` arranca en frío y tarda en emitir su primer evento).
LEASE_TTL="${HARNESS_ORCH_LEASE_TTL:-3600}"

# ── UN PID NO ES UNA IDENTIDAD: LOS PIDS SE RECICLAN ──────────────────
# `kill -0 $pid` contesta "hay UN proceso con ese número", no "sigue vivo EL
# proceso que lancé". Después de un reinicio los PIDs se reasignan desde abajo,
# así que un lease viejo puede apuntar a un número que ahora es de otro proceso
# del mismo usuario y dar "esta tarea tiene dueño" para siempre, para una sesión
# que no existe. Caso de campo: 346 directorios de claim sobrevivieron a un
# reinicio, muchos con PIDs del rango de 2.000.000; hoy no colisionan porque los
# PIDs post-reinicio son bajos, y es cuestión de que el contador suba.
#
# La identidad barata que sí distingue: el INSTANTE DE ARRANQUE del proceso. Un
# PID reciclado arranca después, así que su marca no coincide. Linux lo tiene en
# el campo 22 de /proc/<pid>/stat (se cuenta DESPUÉS del último ')' porque el
# comm puede traer espacios y paréntesis); BSD y macOS lo dan con `ps -o lstart`.
pid_identity() {  # pid_identity <pid> → marca de arranque, o vacío
  local pid="$1" stat rest
  if [ -r "/proc/$pid/stat" ]; then
    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 0
    rest="${stat#*) }"
    printf '%s' "$rest" | awk '{print $20}'
    return 0
  fi
  ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

pid_vivo() {  # pid_vivo <pid> <identidad-guardada> → 0 si es EL proceso que lancé
  local pid="$1" want="${2:-}" now
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$want" ] || return 2        # sin identidad guardada: que decida el TTL
  now="$(pid_identity "$pid")"
  [ -n "$now" ] || return 0         # no pude leerla: el kill -0 manda, como antes
  [ "$now" = "$want" ]
}

lease_taken() {  # lease_taken <task-id> → 0 si alguien más la tiene ahora
  local task="$1" d="$CLAIMS/orch-$task.lock.d" pid pidid at age rc
  [ -d "$d" ] || return 1
  pid="$(cat "$d/pid" 2>/dev/null || true)"
  pidid="$(cat "$d/pidid" 2>/dev/null || true)"
  at="$(cat "$d/at" 2>/dev/null || echo 0)"
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  age=$(( $(now_epoch) - at ))
  pid_vivo "$pid" "$pidid"; rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0                       # el relanzado sigue vivo: es suyo
  fi
  # rc=2 es un lease de una versión anterior (pid sin identidad). No se le cree
  # al número pelado, que es justo el agujero: se le cobra el TTL como a
  # cualquier lease sin dueño demostrable.
  if [ "$age" -lt "$LEASE_TTL" ] && { [ -z "$pid" ] || [ "$rc" -eq 2 ]; }; then
    return 0                       # fresco: alguien lo está tomando
  fi
  rm -rf "$d" 2>/dev/null || true   # huérfano: el proceso murió o caducó
  return 1
}

# ── EL TOPE QUE FALTABA: CUÁNTAS SESIONES HAY VIVAS ───────────────────
# POR QUÉ EXISTE, con el número delante: el 2026-08-14 este vigilante relanzó
# 125 sesiones en 71 minutos (29 en UNA sola pasada) sobre un backlog de tareas
# de días atrás que cruzaban el umbral de silencio a la vez. Medido en esa
# máquina: 1,15 GB por sesión (claude ~500 MB más serena, playwright-mcp,
# context7, npm exec y mcp-grafana), o sea ~140 GB pedidos contra 12 GB de RAM
# y 8 de swap. No hay OOM-killer ni panic en el journal: la máquina dejó de
# poder hacer nada y hubo que reiniciarla a mano.
#
# El dato para contarlas ya estaba: el lease guarda el PID del `claude` que
# lanzamos. Contar sesiones vivas es contar leases con PID vivo, sin mecanismo
# nuevo y sin preguntarle nada al sistema de procesos que no sepamos ya.
live_sessions() {  # → cuántas sesiones lanzadas por este vigilante siguen vivas
  local d pid pidid n=0
  for d in "$CLAIMS"/orch-*.lock.d; do
    [ -d "$d" ] || continue
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    [ -n "$pid" ] || continue
    pidid="$(cat "$d/pidid" 2>/dev/null || true)"
    pid_vivo "$pid" "$pidid" && n=$((n+1))
  done
  printf '%s' "$n"
}

# ── EL PISO DE MEMORIA: EL FAIL-SAFE DE VERDAD ────────────────────────
# Un tope de sesiones mal calibrado en una máquina más chica reproduce el
# incidente igual. Esto es lo que lo habría evitado incluso con el tope puesto en
# un número equivocado, y cuesta una lectura de /proc/meminfo.
#
# Fail-OPEN a propósito: si no se puede medir (un SO que no conocemos), el
# vigilante sigue funcionando como antes y lo DICE una vez. Un watchdog que se
# apaga solo porque no supo leer la memoria es un watchdog que no vigila.
mem_libre_mb() {  # → MB disponibles, o vacío si no se pudo medir
  local kb pages size
  if [ -r /proc/meminfo ]; then
    kb="$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)"
    case "${kb:-}" in ''|*[!0-9]*) return 0 ;; esac
    printf '%s' $(( kb / 1024 ))
    return 0
  fi
  command -v vm_stat >/dev/null 2>&1 || return 0
  size="$(sysctl -n hw.pagesize 2>/dev/null)"
  case "${size:-}" in ''|*[!0-9]*) size=4096 ;; esac
  # Libre = free + inactive + speculative: son las páginas que el kernel puede
  # entregar sin swapear, que es lo mismo que MemAvailable aproxima en Linux.
  pages="$(vm_stat 2>/dev/null | awk -F: '
    /Pages free/         { gsub(/[^0-9]/, "", $2); f = $2 }
    /Pages inactive/     { gsub(/[^0-9]/, "", $2); i = $2 }
    /Pages speculative/  { gsub(/[^0-9]/, "", $2); s = $2 }
    END { print f + i + s }')"
  case "${pages:-}" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' $(( pages * size / 1024 / 1024 ))
}

# ── UNA TAREA DE HACE CINCO DÍAS NO ES UNA SESIÓN QUE SE MURIÓ ────────
# Es el punto de diseño del incidente: casi todas las 83 varadas eran de días
# atrás, o sea tareas ABANDONADAS. Relanzarlas no las va a terminar, y son
# exactamente las que llenaron la cola. Por encima del techo se escala a humano
# por el camino que ya existe, que además las saca de la cola para siempre:
# `pause` deja la fase en `blocked`, y `blocked` es terminal para este vigilante.
tarea_abandonada() {  # tarea_abandonada <task-id> → 0 si lleva demasiado en fase
  local since
  since="$(jq -r '.phase_since // ""' "$WS/tasks/$1/state.json" 2>/dev/null || echo "")"
  [ -n "$since" ] || return 1       # sin dato no se afirma nada
  since="$(iso_to_epoch "$since")"
  [ "$since" -gt 0 ] || return 1
  [ "$(( $(now_epoch) - since ))" -gt "$(( MAX_AGE_H * 3600 ))" ]
}

take_lease() {  # take_lease <task-id> → 0 si es nuestro
  local task="$1" d="$CLAIMS/orch-$task.lock.d"
  mkdir -p "$CLAIMS" 2>/dev/null || return 1
  mkdir "$d" 2>/dev/null || return 1
  now_epoch > "$d/at" 2>/dev/null || true
  printf '%s\n' "$task" > "$d/task" 2>/dev/null || true
  return 0
}

# ── EL REGISTRO DE INTENTOS ───────────────────────────────────────────
# Vive fuera de tasks/<id> a propósito: tasks/ es de la TAREA y lo leen agentes;
# esto es del vigilante. Un JSON por tarea, escrito con tmp+mv.
attempts_of() {  # attempts_of <task-id> → "<n> <huella>"
  local f="$STATE_DIR/$1.json" n fp
  [ -f "$f" ] || { printf '0 '; return 0; }
  n="$(jq -r '.attempts // 0' "$f" 2>/dev/null || echo 0)"
  fp="$(jq -r '.fingerprint // ""' "$f" 2>/dev/null || echo "")"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s %s' "$n" "$fp"
}

record_attempt() {  # record_attempt <task-id> <n> <huella>
  local f="$STATE_DIR/$1.json" tmp
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  tmp="$(mktemp "$STATE_DIR/.$1.XXXXXX" 2>/dev/null)" || return 0
  jq -nc --arg t "$1" --argjson n "$2" --arg fp "$3" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$t, attempts:$n, fingerprint:$fp, at:$at}' > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
}

# ── LA PARADA A HUMANO ES UNA PAUSA REGISTRADA, NO UN echo ────────────
# Si se relanzó MAX_TRIES veces y la huella no se movió, el problema no es que
# la sesión muriera: es que la tarea no puede avanzar sola. Eso ya tiene forma
# en el harness (`harness-policy.py pause`) y tiene código propio en el policy
# (`orchestrator_stalled`), porque una parada que solo existe en la consola de
# un daemon no la ve nadie.
escalate_to_human() {  # escalate_to_human <task-id> <n> [motivo]
  local task="$1" n="$2"
  # El motivo viaja como DETALLE, no como código: `orchestrator_stalled` es el
  # que el policy declara en `allowed_pause_reasons`, y agregar uno nuevo dejaría
  # a toda instancia ya instalada sin poder registrar la pausa. Las dos causas
  # (no avanza, o lleva días abandonada) terminan en la misma parada, que es lo
  # correcto: en las dos el vigilante deja de poder ayudar solo.
  local motivo="${3:-relanzada $n veces sin que cambien ni la fase ni el HEAD de sus worktrees}"
  python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" \
    pause "$WS/tasks/$task" \
    --reason orchestrator_stalled --actor orchestrator-watch \
    --detail "$motivo" \
    >/dev/null 2>&1 \
    || echo "   ⚠️  no pude registrar la pausa por policy (¿tarea ya bloqueada?)"
  emit stop "$task: $motivo. Necesito que la mires." "" "$task"
  echo "   ⛔ $task: parada a humano (orchestrator_stalled): $motivo"
}

relaunch() {  # relaunch <task-id>
  local task="$1" pid
  if [ -n "${HARNESS_ORCH_OFF:-}" ] || [ -f "$WS/.harness/orch-watch.off" ]; then
    echo "   ⏸️  kill switch activo: NO relanzo $task"
    return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    # Fail-HONESTO: sin CLI no hay relanzamiento, y callarlo dejaría un
    # vigilante que no vigila reportando pasadas limpias.
    echo "   ⚠️  no encuentro el CLI 'claude': no puedo relanzar $task"
    return 1
  fi
  mkdir -p "$WS/tasks/$task" 2>/dev/null || true
  # `-p` (headless) y el modelo NO se fija acá: /smart lee su propio
  # `preferred_model` de task.md. Salida a un log de la tarea, que es donde el
  # humano ya busca cuando algo sale raro.
  nohup claude -p "/smart $task" >>"$WS/tasks/$task/orchestrator-watch.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$CLAIMS/orch-$task.lock.d/pid" 2>/dev/null || true
  # La identidad va JUNTO al pid y en el mismo momento: es lo que distingue a
  # este proceso de otro que herede su número después de un reinicio.
  printf '%s\n' "$(pid_identity "$pid")" > "$CLAIMS/orch-$task.lock.d/pidid" 2>/dev/null || true
  echo "   ▶️  $task relanzada (pid $pid) → tasks/$task/orchestrator-watch.log"
  emit phase "$task: la sesión estaba varada, la relancé sola" "" "$task"
  return 0
}

# ── UNA PASADA ────────────────────────────────────────────────────────
# `act=0` es status: mira, cuenta y no toca. Es el modo por defecto porque un
# script que puede gastar dinero no debería hacerlo por invocarse sin argumentos.
pass_once() {  # pass_once <act 0|1>
  local act="$1" st task phase idle_for n fp fp_now prev vistas=0 varadas=0
  local candidatos="" vivas
  # El TAB es el separador de la cola de candidatos: los task-id no lo admiten
  # (worktree-task.sh los acota a [A-Za-z0-9._-]) y `sort -t` lo necesita como
  # un carácter real, no como la escape de bash.
  local TAB; TAB="$(printf '\t')"
  for st in "$WS"/tasks/*/state.json; do
    [ -f "$st" ] || continue
    task="$(basename "$(dirname "$st")")"
    phase="$(jq -r '.phase // ""' "$st" 2>/dev/null || echo "")"
    terminal_phase "$phase" && continue
    vistas=$((vistas+1))
    idle_for=$(( $(now_epoch) - $(last_event_epoch "$task") ))
    # ── EL RELEVO DE FASE: una fase, una sesión ─────────────────────────
    # `harness-policy.py transition` deja `tasks/<id>/handoff.json` cuando la
    # fase avanza. El orquestador cierra su turno ahí, y quien arranca la
    # sesión siguiente es este vigilante: un prompt no puede terminarse a sí
    # mismo ni relanzarse, así que el corte lo tiene que ejecutar algo de
    # afuera, y esto ya sabe hacerlo.
    #
    # POR QUÉ CON GRACIA Y NO AL INSTANTE: si el orquestador NO cerró su turno
    # (un prompt viejo, o un modelo que ignoró la instrucción), relanzar al
    # instante deja DOS sesiones sobre la misma tarea, que es peor que el
    # problema que vino a arreglar. Sus eventos de bus corren el reloj, así que
    # con actividad el relevo no se toma; con el turno cerrado se toma en 60s
    # en vez de los 12 minutos de la regla de silencio.
    # ── UN MARCADOR HUÉRFANO NO ES UN RELEVO PENDIENTE ──────────────────
    # El marcador lo deja la transición y lo consume la pasada siguiente, así
    # que su vida normal se mide en minutos. Los que quedan de tareas viejas
    # (el daemon no corría, o el relanzamiento nunca ocurrió) NO caducan solos,
    # y al arrancar el vigilante disparan una sesión por cada uno. Caso de
    # campo: 19 marcadores viejos acumulados, o sea 19 sesiones ajenas al
    # pedido; con ese riesgo delante, el pipeline entero se corrió en UNA sola
    # sesión y el relevo por fase quedó desactivado de hecho. El contexto del
    # orquestador subió 230k → 357k monótonamente y se llevó el 40% del costo
    # de la tarea. Un mecanismo que se vuelve inusable en cuanto se acumula
    # basura, se llena de basura solo.
    if [ -f "$WS/tasks/$task/handoff.json" ] && handoff_vencido "$task"; then
      echo "   🗑️  $task ($phase): marcador de relevo huérfano (más de $((HANDOFF_TTL / 3600))h), lo caduco"
      [ "$act" = "1" ] && rm -f "$WS/tasks/$task/handoff.json" 2>/dev/null
    fi
    if [ "$act" = "1" ] && [ -f "$WS/tasks/$task/handoff.json" ] \
       && [ "$idle_for" -ge "$HANDOFF_GRACE" ] && ! call_in_flight "$task"; then
      if lease_taken "$task"; then
        echo "   ⏳ $task ($phase): relevo pendiente, pero ya tiene dueño"
      else
        # Los relevos van PRIMERO en la cola (clase 0): son el camino sano, el de
        # una fase que acaba de avanzar con la sesión esperando, y son los que
        # menos se parecen a una tarea abandonada. Pero pasan por los MISMOS
        # topes: este camino también llama a relaunch, y el incidente no
        # distingue de dónde salió la sesión que se comió la RAM.
        candidatos="$candidatos$(printf '0\t0\t%s\t%s\t%s' "$idle_for" "$task" "$phase")
"
      fi
    fi
    [ "$idle_for" -ge "$IDLE" ] || continue
    if call_in_flight "$task"; then
      echo "   ⏳ $task ($phase): ${idle_for}s sin eventos, pero hay una llamada EN VUELO, la dejo"
      continue
    fi
    varadas=$((varadas+1))
    echo "🕳️  $task ($phase): $((idle_for / 60)) min sin un solo evento de bus"
    [ "$act" = "1" ] || continue
    lease_taken "$task" && { echo "   → ya tiene dueño (lease vivo), no la toco"; continue; }
    # El techo de antigüedad va ANTES de encolar: una tarea abandonada no compite
    # por un slot, se escala y sale de la cola para siempre.
    if tarea_abandonada "$task"; then
      escalate_to_human "$task" "$(attempts_of "$task" | cut -d' ' -f1)" \
        "lleva más de ${MAX_AGE_H}h en la fase $phase: no es una sesión que murió hace un rato, es una tarea abandonada, y relanzarla no la va a terminar"
      continue
    fi
    prev="$(attempts_of "$task")"
    n="${prev%% *}"
    candidatos="$candidatos$(printf '1\t%s\t%s\t%s\t%s' "$n" "$idle_for" "$task" "$phase")
"
  done

  # ── EL TOPE, QUE ES LO QUE FALTABA ──────────────────────────────────
  # Hasta acá se decidía Y se lanzaba en el mismo bucle, o sea que "cuántas van"
  # no existía como pregunta. Ahora se junta la cola primero y se sirve después,
  # con los tres frenos puestos y en orden JUSTO: menos intentos primero (el
  # ledger ya lo tenía) y desempate por más tiempo callada. Con el glob
  # alfabético de antes, cuando el tope muerde los slots se los llevan siempre
  # las mismas tareas y la cola de atrás no avanza nunca.
  local lanzadas=0 libre="" clase intentos
  candidatos="$(printf '%s' "$candidatos" | grep -v '^$' | sort -t"$TAB" -k1,1 -k2,2n -k3,3nr)"
  while IFS="$TAB" read -r clase intentos idle_for task phase; do
    [ -n "${task:-}" ] || continue
    if [ "$lanzadas" -ge "$MAX_PER_PASS" ]; then
      echo "   ⏸️  $task ($phase): ya lancé $MAX_PER_PASS en esta pasada (rampa), queda para la próxima"
      continue
    fi
    vivas="$(live_sessions)"
    if [ "$vivas" -ge "$MAX_LIVE" ]; then
      echo "   ⏸️  $task ($phase): $vivas sesión(es) viva(s), tope $MAX_LIVE, la dejo para la próxima pasada"
      continue
    fi
    libre="$(mem_libre_mb)"
    if [ -n "$libre" ] && [ "$libre" -lt "$MIN_FREE_MB" ]; then
      echo "   🧠 $task ($phase): ${libre} MB libres (piso $MIN_FREE_MB): NO lanzo."
      echo "      Una sesión con su flota MCP pesa ~1 GB; lanzar acá es el camino"
      echo "      al reinicio a mano. Cerrá sesiones o subí HARNESS_ORCH_MIN_FREE_MB."
      continue
    fi
    if [ "$clase" = "0" ]; then
      take_lease "$task" || { echo "   → otro poller la tomó primero"; continue; }
      # Se consume ANTES de relanzar: si el relanzamiento falla, la tarea cae en
      # la regla de silencio de siempre. Un marcador que sobrevive es un
      # relanzamiento por pasada.
      rm -f "$WS/tasks/$task/handoff.json" 2>/dev/null || true
      echo "🔁 $task: relevo de fase ($phase), arranco sesión nueva"
      if relaunch "$task"; then
        lanzadas=$((lanzadas+1))
      else
        rm -rf "${CLAIMS:?}/orch-$task.lock.d" 2>/dev/null || true
      fi
      continue
    fi
    fp_now="$(progress_fingerprint "$task")"
    prev="$(attempts_of "$task")"
    n="${prev%% *}"
    fp="${prev#* }"
    if [ "$fp" = "$fp_now" ] && [ "$n" -ge "$MAX_TRIES" ]; then
      escalate_to_human "$task" "$n"
      continue
    fi
    # Huella distinta = la tarea SÍ avanzó desde el último relanzamiento: el
    # contador vuelve a cero. Sin esto, una tarea larga que se cuelga tres veces
    # en tres fases distintas se declara atascada habiendo progresado siempre.
    [ "$fp" = "$fp_now" ] || n=0
    take_lease "$task" || { echo "   → otro poller la tomó primero"; continue; }
    if relaunch "$task"; then
      record_attempt "$task" "$((n+1))" "$fp_now"
      lanzadas=$((lanzadas+1))
    else
      rm -rf "${CLAIMS:?}/orch-$task.lock.d" 2>/dev/null || true
    fi
  done <<CANDEOF
$candidatos
CANDEOF
  # ── LA OTRA SEÑAL: tiempo EN FASE, no silencio de bus (#155) ────────
  # Las dos son ortogonales y hacen falta las dos. El silencio de arriba caza a
  # la tarea cuyo agente murió callado. NO caza a la que sigue emitiendo (o cuyo
  # daemon no corre) y aun así lleva 12 horas en `implement` con el trabajo hecho
  # y el precheck verde: eso es lo que pasó tres veces el mismo día y lo detectó
  # un humano mirando timestamps a mano.
  # La cuenta vive en harness-policy.py, que es LA autoridad sobre state.json;
  # acá solo se la corre. Fail-open: el detector no puede tumbar al vigilante.
  python3 "$WS/scripts/harness-policy.py" stale "$WS/tasks" 2>/dev/null \
    | while IFS="$(printf '\t')" read -r t p m resto; do
        [ -n "$t" ] || continue
        echo "🐢 $t ($p): ${m} min en la misma fase $resto"
      done
  echo "── $vistas tarea(s) en fase no terminal · $varadas varada(s)"
}

case "${1:-status}" in
  status) pass_once 0 ;;
  once)   pass_once 1 ;;
  daemon)
    echo "orchestrator-watch: cada ${INTERVAL}s, varado a los ${IDLE}s. Ctrl-C para salir."
    while :; do
      pass_once 1
      sleep "$INTERVAL"
    done
    ;;
  *)
    echo "uso: orchestrator-watch.sh [status|once|daemon]" >&2
    exit 2 ;;
esac
