#!/usr/bin/env bash
# version.sh: la version del plugin, en un solo lugar y derivada de los commits.
#
# POR QUE EXISTE: la version vivia en TRES archivos que se editaban a mano y
# terminaron diciendo cosas distintas: plugin.json en 0.48.0, marketplace.json
# en 0.45.2 y el ultimo tag en v0.47.0. Eso no es cosmetico: marketplace.json
# es lo que Claude Code lee para INSTALAR, y plugin.json es contra lo que
# `make version` compara. Con los tres desalineados, una instancia podia
# reportarse al dia contra un numero que nadie publico, teniendo instalado otro.
#
# La regla: la version NO se escribe, se DERIVA de los commits (conventional
# commits, que este repo ya usa), y los tres lugares se escriben juntos o
# ninguno.
#
#   feat            -> minor      fix/docs/chore/refactor/test/perf -> patch
#   BREAKING CHANGE -> major, salvo en 0.x, donde sube minor: en pre-1.0 el
#                      contrato todavia no se prometio, y saltar a 1.0.0 por un
#                      breaking diria que el proyecto se estabilizo, que es
#                      justo lo contrario de lo que un breaking significa.
#
# Uso:
#   version.sh current            la version declarada hoy
#   version.sh check              los tres lugares coinciden (exit 1 si no)
#   version.sh next               que version tocaria, sin escribir nada
#   version.sh set <x.y.z>        escribe esa version en los tres lugares
#   version.sh bump               calcula y escribe (imprime la nueva)
#
# Portabilidad: bash 3.2 (macOS), BSD userland. Requiere jq y git.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/.claude-plugin/plugin.json"
MARKET="$ROOT/.claude-plugin/marketplace.json"

command -v jq >/dev/null || { echo "❌ jq requerido"; exit 1; }

ver_plugin() { jq -r '.version' "$PLUGIN"; }
ver_market() { jq -r '.plugins[0].version' "$MARKET"; }
ver_tag()    { git -C "$ROOT" tag --list 'v*' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }

cmd_current() { ver_plugin; }

cmd_check() {
  local p m t bad=0
  p="$(ver_plugin)"; m="$(ver_market)"; t="$(ver_tag)"
  printf '  plugin.json      %s\n  marketplace.json %s\n  ultimo tag       %s\n' "$p" "$m" "${t:-ninguno}"
  if [ "$p" != "$m" ]; then
    echo "❌ plugin.json y marketplace.json NO coinciden."
    echo "   marketplace.json es lo que Claude Code lee para INSTALAR y plugin.json"
    echo "   contra lo que 'make version' compara: desalineados, una instancia puede"
    echo "   reportarse al día contra un número que nadie publicó."
    echo "   ↳ remediación: scripts/version.sh set $p"
    bad=1
  fi
  # El tag puede ir por detras legitimamente (commits sin release todavia), pero
  # NUNCA por delante: eso significa que se taggeo algo que los archivos no
  # declaran.
  if [ -n "$t" ] && [ "$t" != "$p" ] && [ "$(printf '%s\n%s\n' "$p" "$t" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$t" ]; then
    echo "❌ hay un tag v$t POR DELANTE de la versión declarada ($p)."
    echo "   ↳ remediación: scripts/version.sh set $t, o borrá el tag si fue un error"
    bad=1
  fi
  [ "$bad" -eq 0 ] && echo "✅ versión coherente en los tres lugares"
  return "$bad"
}

cmd_next() {
  local base range major minor patch bump=patch
  base="$(ver_tag)"
  if [ -n "$base" ]; then range="v$base..HEAD"; else range="HEAD"; fi
  local subjects bodies
  subjects="$(git -C "$ROOT" log --format=%s "$range" 2>/dev/null || true)"
  bodies="$(git -C "$ROOT" log --format=%B "$range" 2>/dev/null || true)"
  # Sin commits nuevos no hay version nueva: forzar un bump vacio produce tags
  # que no significan nada.
  if [ -z "$subjects" ]; then ver_plugin; return 0; fi
  if printf '%s' "$bodies" | grep -q "BREAKING CHANGE" \
     || printf '%s' "$subjects" | grep -qE '^[a-z]+(\(.*\))?!:'; then
    bump=major
  elif printf '%s' "$subjects" | grep -qE '^feat(\(.*\))?:'; then
    bump=minor
  fi
  IFS=. read -r major minor patch <<EOF
$(ver_plugin)
EOF
  case "$bump" in
    major) if [ "$major" -eq 0 ]; then minor=$((minor+1)); patch=0
           else major=$((major+1)); minor=0; patch=0; fi ;;
    minor) minor=$((minor+1)); patch=0 ;;
    patch) patch=$((patch+1)) ;;
  esac
  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

cmd_set() {
  local v="${1:?uso: version.sh set <x.y.z>}"
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) echo "❌ versión inválida: '$v' (se espera x.y.z)"; exit 1 ;;
  esac
  # tmp+mv en los dos: si el proceso muere a medias, la alternativa es un
  # plugin.json escrito y un marketplace.json viejo, o sea el bug que este
  # script existe para no tener.
  local t1 t2
  t1="$(mktemp)"; t2="$(mktemp)"
  jq --arg v "$v" '.version = $v' "$PLUGIN" > "$t1"
  jq --arg v "$v" '.plugins[0].version = $v' "$MARKET" > "$t2"
  mv "$t1" "$PLUGIN"; mv "$t2" "$MARKET"
  echo "$v"
}

cmd_bump() { cmd_set "$(cmd_next)"; }

case "${1:-check}" in
  current) cmd_current ;;
  check)   cmd_check ;;
  next)    cmd_next ;;
  set)     cmd_set "${2:-}" ;;
  bump)    cmd_bump ;;
  *) echo "uso: version.sh [current|check|next|set <x.y.z>|bump]"; exit 1 ;;
esac
