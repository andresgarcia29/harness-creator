#!/usr/bin/env bash
# guard-gcloud.sh: PreToolUse (Bash): BLOQUEA `gcloud`/`gsutil` pelados cuando
# la instancia tiene el wrapper keyless `scripts/gcloud.sh` al lado.
#
# POR QUÉ: el binario pelado depende de la sesión humana, que caduca en horas.
# Cuando caduca, gcloud imprime "Reauthentication failed … run gcloud auth
# login", y eso no es un error cualquiera: es una INSTRUCCIÓN que el agente
# obedece. Frena la tarea y pide un humano frente a un navegador, teniendo el
# camino verde a un carácter de distancia. El wrapper existe y funciona; lo que
# faltaba era el diente. Mismo patrón que guard-build-slot.sh para la Ley 8.
#
# AUTO-APAGADO: sin `scripts/gcloud.sh` en la instancia no hay camino
# alternativo que ofrecer, así que el hook es inerte (mismo trato que
# mem-recall.sh sin engram: instalarlo donde no aplica no cuesta un token).
#
# Contrato Claude Code: exit 2 + stderr = bloquear la tool call. Sin jq → exit 0
# (fail-open, silencioso).
set -uo pipefail
input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0   # sin jq no bloqueamos (fail-open)

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0

# Sin wrapper no hay remediación que ofrecer: el hook no existe para esta instancia.
[ -x "${CLAUDE_PROJECT_DIR:-.}/scripts/gcloud.sh" ] || exit 0

# Ya usa el camino verde, o es una operación que DEBE quedar atribuida a una
# persona en los audit logs (el wrapper actúa como service account, así que un
# cambio de IAM de la org o de billing no debe ir por ahí).
case "$cmd" in
  *scripts/gcloud.sh*|*scripts/gcp-token.sh*|*HARNESS_GCLOUD_HUMANO=1*) exit 0 ;;
esac

# El hook juzga COMANDOS, no texto: un `git commit -m "arreglé gcloud.sh"` no es
# una invocación de gcloud. Antes de mirar se descartan (a) los cuerpos de
# heredoc y (b) los tramos entrecomillados. El orden importa: heredoc primero,
# porque su delimitador suele venir entrecomillado (<<'EOF').
sanitized="$(printf '%s\n' "$cmd" | awk '
  BEGIN { q = sprintf("%c", 39); skip = 0 }
  skip == 1 {
    t = $0; gsub(/^[[:space:]]+/, "", t)
    if (t == delim) skip = 0
    next
  }
  {
    line = $0
    if (match(line, "<<-?[[:space:]]*[\"" q "]?[A-Za-z_][A-Za-z0-9_]+")) {
      delim = substr(line, RSTART, RLENGTH)
      sub("^<<-?[[:space:]]*", "", delim)
      gsub("[\"" q "]", "", delim)
      skip = 1
      line = substr(line, 1, RSTART - 1)
    }
    gsub("\"[^\"]*\"", "", line)
    gsub(q "[^" q "]*" q, "", line)
    print line
  }
' 2>/dev/null)" || sanitized="$cmd"

# ¿`gcloud`/`gsutil` EN POSICIÓN DE COMANDO (inicio de línea o tras ;, |, & o
# paréntesis, con sudo o asignaciones de entorno delante)? `scripts/gcloud.sh`
# no matchea: el token empieza por `scripts/`.
if printf '%s' "$sanitized" | grep -Eq '(^|[;&|(])[[:space:]]*(sudo[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(gcloud|gsutil)([[:space:]]|$)'; then
  echo "🚫 BLOQUEADO: 'gcloud/gsutil' pelado depende de la sesión humana, que caduca en horas." >&2
  echo "→ Usa el wrapper keyless:  scripts/gcloud.sh <args>   (mismos argumentos)" >&2
  echo "  Si viste 'Reauthentication failed … run gcloud auth login', ESO NO significa re-loguear:" >&2
  echo "  significa que usaste el binario equivocado. El wrapper anda sin credencial humana en disco." >&2
  echo "  Excepción: operaciones que deben quedar atribuidas a una PERSONA en los audit logs (IAM de" >&2
  echo "  la org, billing) van con  HARNESS_GCLOUD_HUMANO=1 gcloud …  y el hook las deja pasar." >&2
  exit 2
fi
exit 0
