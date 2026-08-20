#!/usr/bin/env bash
# with-secrets.sh — ÚNICO punto de inyección de secretos. Sourcea .secrets
# (materializado por secrets.sh, gitignoreado) y ejecuta el comando.
# Lo usan los MCPs de .mcp.json y los CLIs autenticados (kubectl, kargo…).
# Los valores JAMÁS pasan por el chat ni por argumentos.
set -euo pipefail
WS="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$WS/.secrets" ] || {
  echo "❌ no existe $WS/.secrets" >&2
  echo "   ↳ remediación: scripts/secrets.sh pull" >&2
  exit 1
}
set -a
# shellcheck disable=SC1091
. "$WS/.secrets"
set +a
# Un secreto, dos nombres: npm y bun leen el token del registry privado de
# NODE_AUTH_TOKEN (los .npmrc escriben ${NODE_AUTH_TOKEN}), no de GH_TOKEN.
if [ -n "${GH_TOKEN:-}" ] && [ -z "${NODE_AUTH_TOKEN:-}" ]; then
  export NODE_AUTH_TOKEN="$GH_TOKEN"
fi
exec "$@"
