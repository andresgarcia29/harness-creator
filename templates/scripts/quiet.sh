#!/usr/bin/env bash
# quiet.sh — economía de tokens en CLIs ruidosos (kubectl logs, gh run view,
# gcloud, docker). Si el output supera QUIET_MAX_LINES muestra head+tail y
# guarda el dump COMPLETO en .cache/quiet/ (léelo bajo demanda).
# Compone: quiet.sh with-secrets.sh kubectl logs ...
set -uo pipefail
MAX="${QUIET_MAX_LINES:-120}"; NHEAD="${QUIET_HEAD:-40}"; NTAIL="${QUIET_TAIL:-40}"
WS="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$WS/.cache/quiet"; mkdir -p "$CACHE"

[ $# -gt 0 ] || { echo "uso: quiet.sh <comando...>"; exit 1; }
slug="$(printf '%s' "$*" | tr -c 'A-Za-z0-9' '-' | cut -c1-48)"
out="$CACHE/$(date +%Y%m%d-%H%M%S)-$slug.log"

set +e; "$@" > "$out" 2>&1; rc=$?; set -e
lines=$(wc -l < "$out" | tr -d ' ')

if [ "$lines" -le "$MAX" ]; then
  cat "$out"; rm -f "$out"
else
  head -n "$NHEAD" "$out"
  echo "··· [$((lines - NHEAD - NTAIL)) líneas omitidas — dump completo: $out] ···"
  tail -n "$NTAIL" "$out"
fi
exit "$rc"
