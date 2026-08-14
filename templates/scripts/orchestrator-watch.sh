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
# El kill switch también es un ARCHIVO (.harness/orch-watch.off), porque quien
# lo necesita a las tres de la mañana no está para exportar variables.
set -uo pipefail

WS="$(cd "$(dirname "$0")/.." && pwd)"
IDLE="${HARNESS_ORCH_IDLE:-720}"
INTERVAL="${HARNESS_ORCH_INTERVAL:-120}"
MAX_TRIES="${HARNESS_ORCH_MAX:-2}"
HANDOFF_GRACE="${HARNESS_ORCH_HANDOFF:-60}"
HANDOFF_TTL="${HARNESS_ORCH_HANDOFF_TTL:-21600}"
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

# ── "SIN EVENTOS" NO ES "SIN TRABAJAR" ────────────────────────────────
# Es la misma acotación que smart.md le pone al watchdog de subagentes, y por
# el mismo caso de campo: un gate de navegador es UNA llamada bloqueante de
# nueve minutos que, por definición, no produce eventos mientras corre. El bus
# emite `tool-start` en cada Bash, así que la pregunta es determinista: si el
# último `tool-start` de la tarea NO tiene un `tool` posterior, hay una llamada
# EN VUELO y la sesión está trabajando. Matar a un orquestador sano cuesta
# doble: pierde lo que tenía en vuelo y lo relanza con el modelo caro.
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

lease_taken() {  # lease_taken <task-id> → 0 si alguien más la tiene ahora
  local task="$1" d="$CLAIMS/orch-$task.lock.d" pid at age
  [ -d "$d" ] || return 1
  pid="$(cat "$d/pid" 2>/dev/null || true)"
  at="$(cat "$d/at" 2>/dev/null || echo 0)"
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  age=$(( $(now_epoch) - at ))
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0                       # el relanzado sigue vivo: es suyo
  fi
  if [ "$age" -lt "$LEASE_TTL" ] && [ -z "$pid" ]; then
    return 0                       # lease sin pid y fresco: alguien lo está tomando
  fi
  rm -rf "$d" 2>/dev/null || true   # huérfano: el proceso murió o caducó
  return 1
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
escalate_to_human() {  # escalate_to_human <task-id> <n>
  local task="$1" n="$2"
  python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" \
    pause "$WS/tasks/$task" \
    --reason orchestrator_stalled --actor orchestrator-watch \
    --detail "relanzada $n veces sin que cambien ni la fase ni el HEAD de sus worktrees" \
    >/dev/null 2>&1 \
    || echo "   ⚠️  no pude registrar la pausa por policy (¿tarea ya bloqueada?)"
  emit stop "$task: la relancé $n veces y no avanza (misma fase, mismo HEAD). Necesito que la mires." "" "$task"
  echo "   ⛔ $task: $n relanzamientos sin progreso → parada a humano (orchestrator_stalled)"
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
  echo "   ▶️  $task relanzada (pid $pid) → tasks/$task/orchestrator-watch.log"
  emit phase "$task: la sesión estaba varada, la relancé sola" "" "$task"
  return 0
}

# ── UNA PASADA ────────────────────────────────────────────────────────
# `act=0` es status: mira, cuenta y no toca. Es el modo por defecto porque un
# script que puede gastar dinero no debería hacerlo por invocarse sin argumentos.
pass_once() {  # pass_once <act 0|1>
  local act="$1" st task phase idle_for n fp fp_now prev vistas=0 varadas=0
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
      elif take_lease "$task"; then
        # Se consume ANTES de relanzar: si el relanzamiento falla, la tarea
        # cae en la regla de silencio de siempre. Un marcador que sobrevive es
        # un relanzamiento por pasada.
        rm -f "$WS/tasks/$task/handoff.json" 2>/dev/null || true
        echo "🔁 $task: relevo de fase ($phase), arranco sesión nueva"
        if relaunch "$task"; then
          continue
        fi
        rm -rf "${CLAIMS:?}/orch-$task.lock.d" 2>/dev/null || true
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
    else
      rm -rf "${CLAIMS:?}/orch-$task.lock.d" 2>/dev/null || true
    fi
  done
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
