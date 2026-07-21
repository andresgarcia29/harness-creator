#!/usr/bin/env bash
# Reconstruye templates/ui/dist (lo que sirve server.py y viaja a cada workspace)
# desde harness-ui, la fuente de verdad del panel (ADR-0003). El SOURCE del panel
# ya no se mantiene aquí; el installer solo consume su build compilado.
set -euo pipefail
UI_REPO="${HARNESS_UI_REPO:-$HOME/Workspace/harness-ui}"
[ -d "$UI_REPO" ] || { echo "no encuentro harness-ui en $UI_REPO (set HARNESS_UI_REPO)"; exit 1; }
( cd "$UI_REPO" && npm ci --silent && npm run build )
dst="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates/ui/dist"
rm -rf "$dst" && cp -R "$UI_REPO/dist" "$dst"
echo "✓ templates/ui/dist reconstruido desde harness-ui ($UI_REPO)"
