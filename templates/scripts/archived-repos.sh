#!/usr/bin/env bash
# archived-repos.sh: la lista de repos ARCHIVADOS en el forge, cacheada.
#
# LEY: un repo archivado se ignora SIEMPRE. No entra al grafo, ni al inventario,
# ni a los briefs, ni se refresca en los pulls. Un archivado es de solo lectura
# y esta muerto por decision explicita de alguien: tomarlo en cuenta contamina
# el grafo con simbolos que nadie mantiene, hace que un explorador cite codigo
# que no se puede tocar, y gasta reloj clonando lo que no se va a modificar.
#
# POR QUE UN CACHE Y NO UNA CONSULTA EN CALIENTE: `graph-refresh`, `pull-all` y
# `repo-brief` corren seguido y sobre TODOS los repos. Con 30 repos, preguntarle
# al forge en cada uno agrega decenas de llamadas de red al camino critico de
# algo que hoy es local y rapido. Se consulta aparte y se cachea.
#
# Uso:
#   archived-repos.sh refresh     consulta el forge y reescribe el cache
#   archived-repos.sh list        imprime los archivados conocidos (cache)
#   archived-repos.sh is <repo>   exit 0 si esta archivado, 1 si no
#
# Cache: .cache/archived-repos.txt (un nombre por linea) + .stamp con la fecha.
# Portabilidad: bash 3.2, BSD userland.
set -u

WS="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="$WS/.cache"
CACHE="$CACHE_DIR/archived-repos.txt"
STAMP="$CACHE_DIR/archived-repos.stamp"
MAX_AGE_DAYS="${HARNESS_ARCHIVED_MAX_AGE_DAYS:-7}"

cmd_refresh() {
  command -v jq >/dev/null 2>&1 || { echo "⚠️  sin jq: no puedo consultar el forge" >&2; return 3; }
  # shellcheck source=/dev/null
  . "$WS/scripts/forge.sh" 2>/dev/null || { echo "⚠️  falta scripts/forge.sh" >&2; return 3; }
  mkdir -p "$CACHE_DIR"
  local tmp arch=0 vivo=0 nose=0 rc
  tmp="$(mktemp "$CACHE_DIR/.archived.XXXXXX")"
  for d in "$WS"/repos/*/; do
    [ -d "$d/.git" ] || continue
    name="$(basename "$d")"
    rc=0; forge_is_archived "$d" || rc=$?
    case "$rc" in
      0) printf '%s\n' "$name" >> "$tmp"; arch=$((arch+1)) ;;
      1) vivo=$((vivo+1)) ;;
      *) nose=$((nose+1)) ;;
    esac
  done
  # tmp+mv: lo leen procesos en paralelo (el prefetch lanza varios a la vez) y
  # un lector no puede ver media lista. Misma leccion que repo-brief.
  sort -u "$tmp" > "$tmp.s" 2>/dev/null && mv -f "$tmp.s" "$CACHE" || mv -f "$tmp" "$CACHE"
  rm -f "$tmp"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP"
  echo "✅ archivados: $arch · vivos: $vivo${nose:+ · no verificados: $nose}"
  # "No pude mirar" se DICE. Si el forge no contesta, esos repos siguen
  # tratandose como vivos, que es el sesgo correcto: no escondemos nada por no
  # haber podido comprobarlo.
  [ "$nose" -gt 0 ] && echo "   ⚠️  $nose repo(s) sin verificar (¿sin CLI del forge, sin auth, sin red?): se tratan como VIVOS"
  return 0
}

cmd_list() { [ -f "$CACHE" ] && cat "$CACHE" || true; }

cmd_is() {
  local repo="${1:?uso: archived-repos.sh is <repo>}"
  [ -f "$CACHE" ] || return 1
  grep -qxF "$repo" "$CACHE"
}

# stale <dias> → 0 si el cache es mas viejo que eso (o no existe)
cmd_stale() {
  [ -f "$STAMP" ] || return 0
  local age
  age="$(find "$STAMP" -mtime "+$MAX_AGE_DAYS" 2>/dev/null | head -1)"
  [ -n "$age" ]
}

case "${1:-list}" in
  refresh) cmd_refresh ;;
  list)    cmd_list ;;
  is)      cmd_is "${2:-}" ;;
  stale)   cmd_stale ;;
  *) echo "uso: archived-repos.sh [refresh|list|is <repo>|stale]"; exit 1 ;;
esac
