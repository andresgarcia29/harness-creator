#!/usr/bin/env bash
# ui-emit.sh — el bus de eventos del harness. Traduce hooks de Claude Code
# a líneas de .harness/events.jsonl, que es lo que lee la UI (make ui).
#
# LEY DE ESTE HOOK: es un OBSERVADOR. Jamás bloquea, jamás decide, jamás
# escribe en stdout. Sale 0 SIEMPRE — incluso roto. Un hook de telemetría
# que puede tumbar el pipeline es un bug, no una feature: los hooks que
# BLOQUEAN (block-direct-push, guard-canonical) son fail-CLOSED a
# propósito; este es fail-OPEN por la razón opuesta.
#
# Se registra en PostToolUse (no Pre: no queremos latencia antes de cada
# tool), SubagentStop, Stop, SessionStart y UserPromptSubmit.
set -u

BUS_DIR="${CLAUDE_PROJECT_DIR:-$PWD}/.harness"
BUS="$BUS_DIR/events.jsonl"
MAX_BYTES=5242880   # 5 MB → rota. Sin server corriendo esto crece igual.

exit_ok() { exit 0; }
trap exit_ok EXIT
command -v jq >/dev/null 2>&1 || exit 0

mkdir -p "$BUS_DIR" 2>/dev/null || exit 0

# Rotación barata: un stat por llamada, portable macOS/Linux.
#
# EL LOCK ES `.owner`, NO EL mkdir. Con varias sesiones escribiendo, dos pueden ver el bus
# pasado de tamaño a la vez y hacer las dos el mv: el segundo .1 pisa al
# primero y se pierde una tanda entera de eventos. mkdir es atómico en todos
# los filesystems que importan, así que rota UNA sola; la otra sigue de largo
# (su evento cae en el bus nuevo, que es exactamente lo correcto).
#
# El mkdir a secas NO sirve para eso: con uutils coreutils (Ubuntu 26.04) hace
# check-then-act y bajo carrera le devuelve 0 a varias a la vez (issue #209).
# Quien rota es quien gana el O_EXCL de `.owner`, que lo hace la propia shell.
mkdir_lock() {  # mkdir_lock <dir> → 0 solo si el lock es NUESTRO
  mkdir "$1" 2>/dev/null || return 1
  ( set -C; : > "$1/.owner" ) 2>/dev/null
}
size=$(stat -f%z "$BUS" 2>/dev/null || stat -c%s "$BUS" 2>/dev/null || echo 0)
if [ "${size:-0}" -gt "$MAX_BYTES" ] && mkdir_lock "$BUS_DIR/.rotating"; then
  # Re-chequeo dentro del lock: si otra sesión ya rotó mientras esperábamos,
  # el bus está chico otra vez y rotar de nuevo tiraría eventos frescos.
  size2=$(stat -f%z "$BUS" 2>/dev/null || stat -c%s "$BUS" 2>/dev/null || echo 0)
  [ "${size2:-0}" -gt "$MAX_BYTES" ] && mv -f "$BUS" "$BUS.1" 2>/dev/null
  rm -rf "$BUS_DIR/.rotating" 2>/dev/null   # rmdir ya no basta: adentro está .owner
fi

payload="$(cat 2>/dev/null)"
[ -n "$payload" ] || exit 0

KIND="${1:-tool}"

# REDACCIÓN (ley de secretos: los valores no van al repo, al chat NI a la
# UI). El summary es lo único que se muestra; se trunca y se tapan las
# formas de secreto más comunes ANTES de tocar el disco.
redact() {
  sed -E \
    -e 's/(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/[REDACTADO:gh]/g' \
    -e 's/\b(hvs|hvb)\.[A-Za-z0-9_-]{20,}/[REDACTADO:vault]/g' \
    -e 's/\bsk-[A-Za-z0-9_-]{20,}/[REDACTADO:key]/g' \
    -e 's/\bxox[baprs]-[A-Za-z0-9-]{10,}/[REDACTADO:slack]/g' \
    -e 's/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}/[REDACTADO:jwt]/g' \
    -e 's/(AKIA|ASIA)[A-Z0-9]{12,}/[REDACTADO:aws]/g' \
    -e 's/lin_api_[A-Za-z0-9]{20,}/[REDACTADO:linear]/g' \
    -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----)/[REDACTADO:privkey]/g' \
    -e 's/((password|passwd|secret|token|api_?key|authorization)["'"'"']?\s*[:=]\s*["'"'"']?)[^"'"'"' ,}]{6,}/\1[REDACTADO]/gI'
}

emit() { printf '%s\n' "$1" >> "$BUS" 2>/dev/null; }

# En QUÉ máquina pasó. Este hook produce la mayoría de los eventos del bus, y
# mientras el panel era uno solo en 127.0.0.1 la respuesta era obvia: en esta.
# Al juntar los ledgers de varios VPS en una vista de flota deja de serlo, y un
# evento que no dice de dónde sale no se puede ni ordenar ni depurar. Se fija a
# mano con HARNESS_HOST_ID cuando el hostname no dice nada útil.
HOST_ID="${HARNESS_HOST_ID:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo sin-nombre)}"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# La tarea se DERIVA del cwd (worktrees/<task>/<repo>), nunca de un archivo
# compartido: con diez sesiones abiertas, un .harness/current-task global se
# pisa entre sesiones y etiqueta los eventos con la tarea equivocada. Sin estado
# compartido no hay estado que corromper.
cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)"
case "$cwd" in
  */worktrees/*) task="$(printf '%s' "${cwd#*/worktrees/}" | cut -d/ -f1)" ;;
  *) task="" ;;
esac

case "$KIND" in
  tool)
    line="$(printf '%s' "$payload" | jq -c --arg ts "$ts" --arg task "${task:-}" --arg host "$HOST_ID" '
      {ts: $ts, kind: "tool", task: $task, host: $host,
       session: (.session_id // ""),
       agent: (.agent_id // "main"),
       tool: (.tool_name // "?"),
       summary: (
         (.tool_input.command // .tool_input.file_path // .tool_input.pattern //
          .tool_input.description // .tool_input.prompt // "") | tostring | .[0:200]),
       ok: ((.tool_response.success // true) | tostring)}' 2>/dev/null | redact)"
    ;;
  tool-start)
    # POR QUÉ EXISTE: el watchdog declara "atascado" tras ~3 min sin tool
    # calls, pero un gate de navegador (Playwright, WebKit) es UNA llamada
    # bloqueante de 9 a 10 minutos: por definición no produce eventos nuevos
    # mientras corre. Con solo PostToolUse el bus no puede distinguir "no
    # está trabajando" de "está trabajando en algo lento", y el watchdog
    # mataba agentes SANOS y los relanzaba con el modelo de escalación, que
    # es el caro. Pasó en campo.
    #
    # Registrado SOLO en Bash y async, a propósito: la cabecera de este
    # archivo dice que se evitó PreToolUse por latencia, y esa preocupación
    # sigue siendo válida para Read/Grep, que son las llamadas frecuentes.
    # Bash es donde viven las llamadas largas y es una fracción del total.
    line="$(printf '%s' "$payload" | jq -c --arg ts "$ts" --arg task "${task:-}" --arg host "$HOST_ID" '
      {ts: $ts, kind: "tool-start", task: $task, host: $host,
       session: (.session_id // ""),
       agent: (.agent_id // "main"),
       tool: (.tool_name // "?"),
       summary: ((.tool_input.command // .tool_input.description // "")
                 | tostring | .[0:200])}' 2>/dev/null | redact)"
    ;;
  subagent-start|subagent-stop|stop|session-start|prompt)
    # CONTEXTO POR TURNO (issue #206). El harness medía el ARRANQUE, y el
    # arranque es el 15-24% del input: lo que pesa es lo que arrastra cada
    # turno (mediana 266k-348k, máximo 579k en tres sesiones reales), y de eso
    # no había señal en vivo en ningún lado; ccusage es post-mortem. El último
    # `usage` del transcript es justo lo que el próximo turno va a cargar.
    # Fail-open en todo: sin transcript, sin jq de más, sin campo raro, ctx 0 y
    # el evento sale igual. Un bus que se calla por no poder contar es peor que
    # un número ausente.
    ctx=0
    tp="$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)"
    if [ -n "$tp" ] && [ -f "$tp" ]; then
      ctx="$(tail -n 60 "$tp" 2>/dev/null | jq -rs '
        [ .[]? | .message?.usage? | select(. != null)
          | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
             + (.cache_creation_input_tokens // 0)) ] | last // 0' 2>/dev/null)"
      case "$ctx" in ''|*[!0-9]*) ctx=0 ;; esac
    fi
    line="$(printf '%s' "$payload" | jq -c --arg ts "$ts" --arg k "$KIND" --arg task "${task:-}" --arg host "$HOST_ID" --argjson ctx "$ctx" '
      {ts: $ts, kind: $k, task: $task, host: $host,
       session: (.session_id // ""),
       agent: (.agent_id // "main"),
       ctx: $ctx,
       summary: ((.prompt // .reason // "") | tostring | .[0:200])}' 2>/dev/null | redact)"
    ;;
  *) exit 0 ;;
esac

[ -n "${line:-}" ] && emit "$line"
exit 0
