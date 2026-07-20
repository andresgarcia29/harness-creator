#!/usr/bin/env bash
# Resincroniza el contrato de tipos daemon→UI (ADR-0003). El daemon es la fuente
# de verdad: regenera su .ts desde los structs Go y lo copia aquí. Hasta que
# harness-ui sea su propio repo (v53.2), el daemon se localiza por env o sibling.
set -euo pipefail
DAEMON="${HARNESS_DAEMON_REPO:-$HOME/Workspace/harness-daemon}"
[ -d "$DAEMON" ] || { echo "no encuentro harness-daemon en $DAEMON (set HARNESS_DAEMON_REPO)"; exit 1; }
( cd "$DAEMON" && go generate ./... )
dst="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src/lib/contract.gen.ts"
{
  echo "// VENDORIZADO desde harness-daemon/contract/harness.gen.ts (ADR-0003)."
  echo "// NO editar a mano. Resync: scripts/sync-contract.sh. Fuente de verdad:"
  echo "// los structs Go de internal/api del daemon."
  cat "$DAEMON/contract/harness.gen.ts"
} > "$dst"
echo "✓ contrato sincronizado → $dst"
