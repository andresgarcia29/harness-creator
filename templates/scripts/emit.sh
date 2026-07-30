#!/usr/bin/env bash
# emit.sh — el bus del harness. Lo que este sistema DECIDE y lo que NO deja hacer.
#
# Dos formas de usarlo:
#   source scripts/emit.sh        → te da la función `emit`
#   scripts/emit.sh <kind> <summary> [ok] [task] [dur]   → desde un comando o a mano
#
# POR QUÉ EXISTE: el panel sabía de agentes y tokens — todo eso lo presta Claude
# Code. Pero el harness NO SON SUS AGENTES: son sus decisiones y sus negativas.
# Los gates, las fases, los supuestos y las paradas son NUESTROS, y son la única
# capa que funciona igual con Claude Code, con Codex o con un humano. Sin esto,
# el panel enseña la mitad prestada y se calla la que importa.
#
# LEYES:
#   · FAIL-OPEN, siempre. Sale 0 pase lo que pase. Un bus de telemetría que
#     puede tumbar un ship es un bug, no una feature. Los que bloquean
#     (block-direct-push, guard-canonical) son fail-CLOSED a propósito.
#   · REDACTA ANTES DE ESCRIBIR. El resumen de un gate puede traer un comando
#     con un token. La ley de secretos también aplica al bus.
#   · APPEND-ONLY. Una línea JSON por evento. Cualquier script sabe hacer `>>`,
#     y el bus tiene que funcionar aunque el panel esté muerto.
#
# kinds: phase | gate | decision | assumption | stop | deploy | ship

set -u

_emit_ws() {
  # El workspace es el que tiene .harness/ o CLAUDE.md, subiendo desde aquí.
  local d="${CLAUDE_PROJECT_DIR:-${WS:-$PWD}}"
  printf '%s' "$d"
}

_emit_redact() {
  # OJO: nada de \b — el sed de macOS (BSD) no lo soporta y el patrón entero
  # deja de matchear EN SILENCIO: las llaves sk-/vault/slack/jwt viajaban al
  # bus sin redactar en Mac. Lo cachó tests/test_emit.sh. El borde de palabra
  # portable es (^|[^A-Za-z0-9_-]) conservando el prefijo con \1.
  sed -E \
    -e 's/(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/[REDACTADO:gh]/g' \
    -e 's/(^|[^A-Za-z0-9_-])(hvs|hvb)\.[A-Za-z0-9_-]{20,}/\1[REDACTADO:vault]/g' \
    -e 's/(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}/\1[REDACTADO:key]/g' \
    -e 's/(^|[^A-Za-z0-9_-])xox[baprs]-[A-Za-z0-9-]{10,}/\1[REDACTADO:slack]/g' \
    -e 's/(^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}/\1[REDACTADO:jwt]/g' \
    -e 's/(AKIA|ASIA)[A-Z0-9]{12,}/[REDACTADO:aws]/g' \
    -e 's/lin_api_[A-Za-z0-9]{20,}/[REDACTADO:linear]/g' \
    -e 's/((password|passwd|secret|token|api_?key|authorization)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?)[^"'"'"' ,}]{6,}/\1[REDACTADO]/gI'
}

# emit <kind> <summary> [ok] [task] [dur]
#   ok:  true (pasó) | false (bloqueó) | vacío (no aplica)
#   dur: segundos enteros que tardó lo que se cuenta (opcional).
#
# ── POR QUÉ `dur` Y NO LA RESTA ENTRE TIMESTAMPS ──────────────────────
# La duración de un gate se derivaba restando el `ts` de dos eventos `gate`
# consecutivos. Con dos ships de la MISMA tarea intercalados (ship-wave corre
# los repos en paralelo, y todos escriben en ESTE archivo) los eventos se
# entrelazan: la resta mide el hueco entre dos gates de corridas distintas y
# le atribuye el tiempo al gate equivocado. Un `dur` explícito, medido por
# quien SÍ sabe cuándo empezó su propio gate, no tiene ese modo de fallo.
#
# COMPATIBLE EN LAS DOS DIRECCIONES, a propósito:
#   · un parser VIEJO lee una línea con `dur` y la ignora: es una clave más
#     en un objeto JSON, no un cambio de forma. Los campos que ya leía siguen
#     en su lugar y con el mismo orden.
#   · un emit VIEJO (o cualquier llamador que no pase el 5º argumento) sale
#     EXACTAMENTE como antes, sin la clave. Nadie tiene que actualizarse.
#
# Y `dur` se VALIDA antes de entrar: el bus es fail-open por ley, así que un
# `dur` basura no puede tener el poder de romper la línea JSON entera (un
# --argjson con basura hace fallar a jq, la línea sale vacía y el evento se
# PIERDE). Basura → se descarta el dato, se emite el evento igual.
emit() {
  local kind="${1:-}" summary="${2:-}" ok="${3:-}" task="${4:-${TASK:-}}" dur="${5:-}"
  [ -n "$kind" ] || return 0
  local ws bus
  ws="$(_emit_ws)"; bus="$ws/.harness/events.jsonl"
  mkdir -p "$ws/.harness" 2>/dev/null || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # Entero decimal SIN ceros a la izquierda: "007" es dígitos pero NO es JSON
  # válido, y jq moriría con el evento adentro. Lo que no es número, no viaja.
  case "$dur" in
    ''|*[!0-9]*) dur="" ;;
    0|[1-9]*)    : ;;
    *)           dur="" ;;
  esac

  summary="$(printf '%s' "$summary" | _emit_redact | cut -c1-400)"
  # UN SOLO jq, igual que antes: el filtro y sus --arg se arman con `set --`
  # (nada de arrays, que este archivo se sourcea desde sh/dash/zsh también).
  # Sumar objetos en jq APPENDEA claves, así que el orden de salida es
  # byte a byte el de siempre y `dur` queda al final, detrás de `ok`.
  local filt='{ts:$ts,kind:$k,task:$t,actor:$a,summary:$s}'
  set -- -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg k "$kind" \
    --arg t "$task" --arg s "$summary" --arg a "${ACTOR:-${REPO:-harness}}"
  if [ -n "$ok" ]; then
    set -- "$@" --argjson ok "$ok"; filt="$filt"'+{ok:$ok}'
  fi
  if [ -n "$dur" ]; then
    set -- "$@" --argjson dur "$dur"; filt="$filt"'+{dur:$dur}'
  fi
  local line
  line="$(jq "$@" "$filt" 2>/dev/null)"
  [ -n "$line" ] && printf '%s\n' "$line" >> "$bus" 2>/dev/null
  return 0
}

# Ejecutado directamente (no sourceado) → CLI. Lo usa /smart desde Bash.
# El `"$@"` de acá abajo es el mismo de siempre: la forma CLI acepta el 5º
# argumento (`dur`) sin tocar nada, igual que la forma sourceada.
# El :- importa: BASH_SOURCE no existe si te sourcean desde zsh o sh, y con
# `set -u` eso revienta el script que te sourceó. Y OJO con la sintaxis:
# ${BASH_SOURCE[0]} es un ARRAY — dash (el sh de Debian/Ubuntu) no lo parsea
# ("Bad substitution") y aborta el source entero; el sh de macOS es bash
# disfrazado y lo tolera, así que en Mac esto pasaba de chiripa. Sin
# subíndice, $BASH_SOURCE expande al elemento 0 en bash y a vacío (con :-)
# en dash/zsh — portable de verdad. Un bus de telemetría que tumba a quien
# lo usa es exactamente lo que este archivo promete no ser.
if [ "${BASH_SOURCE:-}" = "${0}" ]; then
  emit "$@"
  exit 0
fi
