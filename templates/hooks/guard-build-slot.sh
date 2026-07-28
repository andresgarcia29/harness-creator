#!/usr/bin/env bash
# guard-build-slot.sh — PreToolUse (Bash): BLOQUEA `docker build`/`docker run` de
# toolchain sin envolver en el semáforo. Builds pesados paralelos funden la máquina
# compartida entre N sesiones (dato real: load 286 con 6 núcleos). Ley 8: todo build/run
# pesado pasa por scripts/build-slot.sh (serializa en el kernel, sin polling).
#
# Contrato Claude Code: exit 2 + stderr = bloquear la tool call (igual que
# guard-canonical.sh). Sin jq → exit 0 (fail-open, silencioso).
set -uo pipefail
input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0   # sin jq no bloqueamos (fail-open)

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0

# Ya auto-serializado — el wrapper mismo (o algo que lo use por dentro) → no tocar.
case "$cmd" in
  *build-slot.sh*) exit 0 ;;
esac

# El hook juzga COMANDOS, no texto. Caso de campo: un `git commit` cuyo
# mensaje mencionaba "docker run" quedaba bloqueado, porque el grep corría
# sobre el string entero. Antes de mirar, se descartan (a) los cuerpos de
# heredoc (un mensaje de commit por -F- no es un comando) y (b) los tramos
# entrecomillados (un -m "fix docker run flags" tampoco). El orden importa:
# heredoc primero, porque su delimitador suele venir entrecomillado (<<'EOF').
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

# ¿`docker` EN POSICIÓN DE COMANDO (inicio de línea o tras ;, |, & o paréntesis,
# con sudo o asignaciones de entorno delante) seguido, sin cruzar |, ; o &, de la
# palabra `build` o `run`? Cubre `docker build`, `docker buildx build`,
# `docker compose … build`, `docker run`. NO toca ps/logs/images/inspect/exec.
if printf '%s' "$sanitized" | grep -Eq '(^|[;&|(])[[:space:]]*(sudo[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*docker[[:space:]]+([^[:space:]|&;]+[[:space:]]+)*(build|run)([[:space:]]|$)'; then
  echo "🚫 BLOQUEADO (Ley 8): 'docker build/run' pelado funde la máquina compartida entre sesiones (load 286 con 6 núcleos fue real)." >&2
  echo "→ Envuélvelo en el semáforo:  bash scripts/build-slot.sh docker <build|run> …" >&2
  echo "  Serializa cross-sesión con bloqueo de kernel (cero polling); límite max(1, núcleos/4), override HARNESS_BUILD_SLOTS." >&2
  exit 2
fi
exit 0
