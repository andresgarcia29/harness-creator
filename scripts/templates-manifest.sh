#!/usr/bin/env bash
# templates-manifest.sh: la huella del set de templates que genera una instancia.
#
# POR QUÉ EXISTE: hay DOS generadores para un solo set de templates, el skill
# /harness-init y el binario `harness generate`. El binario embebe o clona su
# propia copia, así que puede generar desde un set viejo, y hasta hoy lo hacía
# EN SILENCIO: reportaba "24 conflictos, 1 actualizado" sin decir jamás contra
# qué versión estaba generando. El humano resolvía 24 diffs a mano para
# terminar con una instancia que no tenía los arreglos que creía tener.
#
# Es el mismo defecto que este harness persigue en todos lados: una operación
# que no puede decir sobre qué trabajó, reportando éxito.
#
# El manifiesto es la respuesta: versión del plugin más el sha256 de cada
# template, y un hash agregado que identifica el set completo. Con eso:
#   · un generador puede DECLARAR con qué set generó (lo escribe en la
#     instancia como .harness-templates)
#   · la instancia puede comparar el suyo contra upstream y detectar que la
#     generaron con templates viejos, sin depender de que el generador lo diga
#   · el CI verifica que el manifiesto no se quede atrás de los templates
#
# Uso:
#   scripts/templates-manifest.sh generate   reescribe templates/MANIFEST.sha256
#   scripts/templates-manifest.sh verify     falla si está desactualizado
#   scripts/templates-manifest.sh digest     solo el hash agregado del set
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/templates/MANIFEST.sha256"

sha_of() {  # sha_of <archivo> → sha256, portable macOS/Linux
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

# El set: TODO lo que termina dentro de una instancia. Es templates/ más
# `scripts/doctor.sh`, que vive fuera de templates/ pero se COPIA tal cual
# (la instancia es autocontenida). Dejarlo afuera haría que el digest
# afirmara "idénticos a upstream" con un doctor viejo adentro: precisamente
# la mentira que este archivo existe para impedir.
#
# Se excluye el bundle compilado del panel (viaja versionado por su cuenta,
# cambia con cada build de harness-ui) y los artefactos locales de Python.
list_files() {
  {
    find "$ROOT/templates" -type f \
      -not -path "*/ui/dist/*" \
      -not -path "*/__pycache__/*" \
      -not -name "MANIFEST.sha256"
    echo "$ROOT/scripts/doctor.sh"
  } | sed "s|^$ROOT/||" | LC_ALL=C sort
}

build() {
  local ver
  ver="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$ROOT/.claude-plugin/plugin.json" \
    | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  echo "# templates-manifest v1: la huella del set que genera una instancia."
  echo "# Lo escribe scripts/templates-manifest.sh; el CI verifica que esté al día."
  echo "# Un generador DEBE escribir el digest de abajo en .harness-templates de"
  echo "# la instancia: sin eso, nadie puede saber con qué set se generó."
  echo "plugin_version: $ver"
  local f
  while IFS= read -r f; do
    printf '%s  %s\n' "$(sha_of "$ROOT/$f")" "$f"
  done < <(list_files)
}

digest() {  # el hash del set completo: cambia si cambia cualquier template
  build | grep -v '^#' | grep -v '^plugin_version:' \
    | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } \
    | awk '{print $1}'
}

case "${1:-verify}" in
  generate)
    { build; echo "digest: $(digest)"; } > "$OUT"
    echo "✅ $OUT ($(list_files | wc -l | tr -d ' ') templates, digest $(digest | cut -c1-12))"
    ;;
  digest)
    digest
    ;;
  verify)
    [ -f "$OUT" ] || { echo "❌ falta templates/MANIFEST.sha256: corre 'scripts/templates-manifest.sh generate'"; exit 1; }
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    { build; echo "digest: $(digest)"; } > "$tmp"
    if diff -q "$OUT" "$tmp" >/dev/null 2>&1; then
      echo "✅ el manifiesto refleja los templates actuales"
    else
      echo "❌ templates/MANIFEST.sha256 quedó atrás de los templates."
      echo "   Un manifiesto desactualizado es peor que ninguno: hace creer que"
      echo "   una instancia se generó con un set que no es el que se usó."
      echo "   ↳ remediación: scripts/templates-manifest.sh generate"
      diff "$OUT" "$tmp" | head -12
      exit 1
    fi
    ;;
  *) echo "uso: templates-manifest.sh [generate|verify|digest]"; exit 1 ;;
esac
