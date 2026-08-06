#!/usr/bin/env bash
# finding.sh: que un hallazgo se descubra UNA vez y lo sepan todos los repos.
#
# POR QUÉ EXISTE: el harness no tenía canal de difusión entre agentes hermanos.
# El bus (emit.sh) es telemetría PARA EL PANEL y nadie lo suscribe; `mem_save`
# opera al CERRAR la tarea, así que un hallazgo del reviewer del repo A no llega
# nunca a un implementer del repo B que ya arrancó; y los beads de
# verdict-beads.sh son seguimiento post-review. El único difusor era el humano
# relayando a mano.
#
# Caso de campo que lo motivó: tres repos escribieron el MISMO guard roto de
# forma independiente, en la misma tarea. Se pagó tres veces por descubrir una
# sola cosa, y la tercera vez costó igual que la primera.
#
# LEYES, heredadas del bus y una propia:
#   · APPEND-ONLY, una línea JSON por hallazgo. Cualquier script sabe `>>`.
#   · REDACTA ANTES DE ESCRIBIR: un hallazgo cita comandos y salidas de error,
#     que es exactamente donde viajan los tokens.
#   · ACOTADO AL LEER, que es la ley propia y la razón de que esto no se haya
#     hecho con el bus: lo que devuelve `read` entra en la VENTANA de un agente
#     y se re-lee en cada tool call suya. Un canal de difusión sin techo es un
#     invento para que el contexto crezca en todos los agentes a la vez.
#   · DEDUPE por texto normalizado: publicar dos veces el mismo hallazgo es
#     precisamente el desperdicio que este archivo viene a cortar.
#
# `publish` es fail-OPEN (no puede tumbar un review), `read` es fail-OPEN
# (sin hallazgos, silencio y exit 0: un implementer no se frena por esto).
#
# Uso:
#   scripts/finding.sh publish <task-id> <repo> "<texto>"
#   scripts/finding.sh read <task-id> [--exclude-repo <repo>] [--max N]

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/emit.sh" 2>/dev/null || true

_ws() {
  if command -v _emit_ws >/dev/null 2>&1; then _emit_ws; else printf '%s' "${WS:-$PWD}"; fi
}
_redact() {
  if command -v _emit_redact >/dev/null 2>&1; then _emit_redact; else cat; fi
}

_json_escape() {
  # Sin jq: es una dependencia que el harness no exige en todos lados.
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g' \
    | awk 'BEGIN{ORS=""} {if(NR>1) printf "\\n"; print}'
}

# Clave de dedupe: minúsculas, sin puntuación ni espacios repetidos. Dos
# reviewers describen el mismo defecto con palabras distintas, pero cuando el
# orquestador relaya el hallazgo TAL CUAL (que es el caso que importa) el texto
# coincide y no se duplica.
_key() {
  tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ' | awk '{$1=$1; print}'
}

cmd_publish() {
  local task="${1:-}" repo="${2:-}" text="${3:-}"
  [ -n "$task" ] && [ -n "$repo" ] && [ -n "$text" ] || {
    echo "uso: finding.sh publish <task-id> <repo> \"<texto>\"" >&2; exit 2; }
  local ws dir file
  ws="$(_ws)"; dir="$ws/tasks/$task"
  [ -d "$dir" ] || { echo "finding: no existe $dir (no publico a la nada)" >&2; exit 0; }
  file="$dir/findings.jsonl"

  # TECHO POR HALLAZGO. Sin esto el canal era el unico agujero sin acotar del
  # cambio: medido, 15 hallazgos de 5000 chars daban 60 KB (~17k tokens) que
  # entran a la ventana de CADA implementer y se releen en cada tool call suyo.
  # Un hallazgo es un puntero ("esto ya se descubrio, no lo investigues"), no
  # el informe: si hace falta el detalle, esta en el veredicto del repo que lo
  # encontro.
  local max_chars="${HARNESS_FINDING_MAX_CHARS:-400}"
  local clean key
  clean="$(printf '%s' "$text" | _redact | cut -c1-"$max_chars")"
  [ "${#text}" -gt "$max_chars" ] && clean="$clean [...]"
  key="$(printf '%s' "$clean" | _key)"

  if [ -f "$file" ] && [ -n "$key" ]; then
    # Ya publicado por otro repo: eso NO es un error, es el sistema
    # funcionando. Se dice y se sale en 0.
    if grep -Fq "\"key\":\"$(printf '%s' "$key" | _json_escape)\"" "$file" 2>/dev/null; then
      echo "finding: ya estaba publicado (dedupe), no se paga dos veces"
      exit 0
    fi
  fi

  printf '{"ts":"%s","repo":"%s","key":"%s","text":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$repo" | _json_escape)" \
    "$(printf '%s' "$key" | _json_escape)" \
    "$(printf '%s' "$clean" | _json_escape)" >> "$file" 2>/dev/null || exit 0

  # Al bus también: el humano ve en el panel que hubo difusión, que es
  # justamente lo que antes hacía a mano.
  if command -v emit >/dev/null 2>&1; then
    emit decision "hallazgo difundido desde $repo: $(printf '%s' "$clean" | cut -c1-120)" "" "$task" || true
  fi
  echo "finding: publicado para $task (desde $repo)"
}

cmd_read() {
  local task="${1:-}"; shift || true
  local exclude="" max="${HARNESS_FINDINGS_MAX:-12}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --exclude-repo) exclude="${2:-}"; shift 2 ;;
      --max) max="${2:-12}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$task" ] || { echo "uso: finding.sh read <task-id>" >&2; exit 2; }
  local ws file; ws="$(_ws)"; file="$ws/tasks/$task/findings.jsonl"
  [ -f "$file" ] || exit 0          # sin hallazgos, silencio

  # El techo es la razón de ser del comando: esto entra en la ventana de un
  # agente. Se muestran los más RECIENTES, que son los que todavía no vio.
  local out
  out="$(awk -v ex="$exclude" -v max="$max" '
    {
      repo=""; text="";
      if (match($0, /"repo":"[^"]*"/))  { repo = substr($0, RSTART+8, RLENGTH-9) }
      if (match($0, /"text":"[^"]*"/))  { text = substr($0, RSTART+8, RLENGTH-9) }
      if (ex != "" && repo == ex) next
      if (text == "") next
      lines[++n] = "  · [" repo "] " text
    }
    END {
      start = (n > max) ? n - max + 1 : 1
      if (n == 0) exit 0
      if (n > max) print "  (" (n - max) " hallazgo(s) mas antiguo(s) omitido(s))"
      for (i = start; i <= n; i++) print lines[i]
    }' "$file" 2>/dev/null)"
  [ -n "$out" ] || exit 0
  echo "HALLAZGOS YA DESCUBIERTOS EN ESTA TAREA (no los vuelvas a investigar):"
  printf '%s\n' "$out"
}

case "${1:-}" in
  publish) shift; cmd_publish "$@" ;;
  read)    shift; cmd_read "$@" ;;
  *) echo "uso: finding.sh {publish|read} ..." >&2; exit 2 ;;
esac
