#!/usr/bin/env bash
# repo-brief.sh: brief determinista de un repo, $0 tokens.
#
# El arranque frío de un implementer gasta sus primeros minutos (y miles de
# tokens) re-descubriendo lo mismo: estructura, comandos de test, convenciones.
# Este script lo destila UNA vez por HEAD y lo cachea: el orquestador pasa el
# brief en el prompt y el implementer arranca ya orientado, sin explorar.
#
# Uso: repo-brief.sh <repo> [--force]
# Salida: .cache/briefs/<repo>.md (regenera solo si el HEAD del repo cambió)
# Portabilidad: bash 3.2 (macOS), BSD tools. Fail-open: un brief que no se
# pudo generar no bloquea nada: el implementer simplemente explora como antes.
set -u

REPO="${1:?uso: repo-brief.sh <repo> [--force]}"
FORCE="${2:-}"
WS="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$WS/repos/$REPO"
OUT_DIR="$WS/.cache/briefs"
OUT="$OUT_DIR/$REPO.md"

[ -d "$SRC/.git" ] || { echo "⚠️  no existe repos/$REPO; sin brief" >&2; exit 0; }
# Un brief de un repo archivado viaja DENTRO del prompt del implementer como si
# fuera material vivo. Es la forma mas cara de contaminar: no se ve.
if [ -f "$WS/.cache/archived-repos.txt" ] && grep -qxF "$REPO" "$WS/.cache/archived-repos.txt"; then
  echo "⚠️  repos/$REPO está ARCHIVADO en el forge: no genero brief (ver scripts/archived-repos.sh)" >&2
  exit 0
fi
mkdir -p "$OUT_DIR"

head_sha="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$FORCE" != "--force" ] && [ -f "$OUT" ] && head -1 "$OUT" | grep -qF "$head_sha"; then
  echo "$OUT"   # cache vigente
  exit 0
fi

# Sección acotada: nunca más de $2 líneas de la fuente $1 (economía de tokens).
capped() { [ -f "$1" ] && sed -n "1,${2}p" "$1"; }

# run_bounded: el grafo se consulta con reloj. Ver el bloque "## Quién consume".
# shellcheck source=/dev/null
[ -f "$WS/scripts/bounded.sh" ] && . "$WS/scripts/bounded.sh" 2>/dev/null

{
  echo "<!-- brief @ $head_sha, generado por repo-brief.sh; NO editar -->"
  echo "# $REPO: brief"
  echo

  echo "## Stack y comandos"
  [ -f "$SRC/go.mod" ]        && echo "- Go (\`go build ./...\` · \`go test ./...\` · module: $(head -1 "$SRC/go.mod" | cut -d' ' -f2))"
  [ -f "$SRC/package.json" ]  && echo "- Node$( [ -f "$SRC/tsconfig.json" ] && printf '/TypeScript (`npx tsc --noEmit`)' ) · scripts: $(command -v jq >/dev/null && jq -r '.scripts | keys | join(", ")' "$SRC/package.json" 2>/dev/null || echo "ver package.json")"
  [ -f "$SRC/pyproject.toml" ] && echo "- Python (\`ruff check .\` · \`pytest -q\`)"
  [ -f "$SRC/pubspec.yaml" ]  && echo "- Flutter (\`flutter analyze --no-fatal-infos\` · \`flutter test\`)"
  [ -f "$SRC/buf.yaml" ]      && echo "- ⚠️ CONTRATOS proto (buf): cualquier cambio aquí es carril standard/full, expand/contract obligatorio"
  if [ -f "$SRC/Makefile" ]; then
    targets="$(grep -E '^[a-zA-Z0-9_.-]+:([^=]|$)' "$SRC/Makefile" | cut -d: -f1 | sort -u | head -12 | tr '\n' ' ')"
    [ -n "$targets" ] && echo "- Makefile: $targets"
  fi
  echo

  echo "## Estructura (2 niveles, solo directorios)"
  (cd "$SRC" && find . -maxdepth 2 -type d \
      ! -path './.git*' ! -path './node_modules*' ! -path './vendor*' \
      ! -path './dist*' ! -path './build*' ! -path './.cache*' \
      | sort | head -40 | sed 's|^\./||; s|^|  |')
  echo

  if [ -f "$SRC/CLAUDE.md" ]; then
    echo "## CLAUDE.md del repo (primeras 40 líneas; la fuente manda)"
    capped "$SRC/CLAUDE.md" 40
    echo
  elif [ -f "$SRC/README.md" ]; then
    echo "## README (primeras 20 líneas)"
    capped "$SRC/README.md" 20
    echo
  fi

  echo "## Tests: dónde viven"
  (cd "$SRC" && find . -maxdepth 3 -type d \( -name 'test' -o -name 'tests' -o -name '__tests__' -o -name 'spec' \) \
      ! -path './.git*' ! -path './node_modules*' ! -path './vendor*' \
      | sort | head -10 | sed 's|^\./||; s|^|  |')
  (cd "$SRC" && find . -maxdepth 2 -name '*_test.go' -o -maxdepth 2 -name '*.test.ts' -o -maxdepth 2 -name 'test_*.py' 2>/dev/null | head -5 | sed 's|^\./||; s|^|  |')

  # ── Homónimos: el mismo nombre, en otro repo ───────────────────────────
  # POR QUE ACA Y NO EN EL PROMPT: los prompts llevaban meses diciendo "usá
  # graphify, no grep masivo" y el reporte de campo fue el mismo tres veces: NO
  # se usó. El motivo no es desobediencia, es aritmética: consultar el grafo son
  # 2-3 tool calls a contexto completo, y el grep que el agente ya tiene a mano
  # contesta *algo* en una. Cuando la herramienta correcta cuesta más que la
  # chapucera, gana la chapucera, y ninguna cantidad de prosa da vuelta eso. Así
  # que la respuesta viaja YA RESUELTA en el brief: no se elige, se lee.
  #
  # POR QUE ESTA PREGUNTA Y NO OTRA: hay que ser honesto sobre lo que el grafo
  # de esta instancia sabe. `graph-refresh.sh` usa `graphify update`, que extrae
  # SOLO AST (a propósito: la extracción semántica exigía API key). Eso da
  # aristas `call` DENTRO de cada repo, pero `merge-graphs` no resuelve símbolos
  # entre repos: las aristas cruzadas son CERO, medido. Así que "quién me
  # consume desde otro repo" NO tiene respuesta acá y no se va a fingir una.
  #
  # Lo que sí sale de los nodos, sin necesitar una sola arista, es el homónimo:
  # el mismo identificador definido en más de un repo. Y es justo el dato que el
  # implementer no puede ver, porque su worktree es UN repo, y justo el que
  # convierte un `sed -i` en un incidente. Es la mitad que `gate_rename` (en
  # ship.sh) no alcanza a ver desde el diff: el gate mira lo que sobrevivió
  # DESPUES; esto avisa ANTES.
  _g="$WS/graphify-out/graph.json"
  if [ -s "$_g" ]; then
    _h="$(python3 - "$_g" "$REPO" <<'PYEOF' 2>/dev/null
import collections, json, sys
try:
    g = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
repo = sys.argv[2]
donde = collections.defaultdict(set)
for n in g.get("nodes", []):
    lab, r = n.get("label"), n.get("repo")
    # Solo simbolos, no archivos: "auth.go" repetido en dos repos no es un
    # riesgo de renombre, es el nombre de archivo mas comun del mundo.
    if lab and r and lab.endswith(")"):
        donde[lab].add(r)
filas = sorted((l, sorted(rs - {repo})) for l, rs in donde.items()
               if repo in rs and len(rs) > 1)
for lab, otros in filas[:12]:
    print("  %s  también en: %s" % (lab, ", ".join(otros[:4])))
if len(filas) > 12:
    print("  ...y %d más" % (len(filas) - 12))
PYEOF
)"
    if [ -n "$_h" ]; then
      echo
      echo "## Homónimos en otros repos (cuidado al renombrar)"
      echo "$_h"
      echo "  Un reemplazo de texto sobre estos nombres toca código que no es tuyo."
      echo "  Usá edición simbólica (Serena rename_symbol), no sed."
    fi
  fi

# tmp + mv: cuando un HEAD se mueve, TODAS las sesiones que hacen prefetch
# regeneran a la vez, y minion-probe.sh lo invoca desde workers EN PARALELO y
# después hace cat. Sin esto, un lector recibía un brief truncado o con dos
# escrituras intercaladas, y ese texto viaja DENTRO del prompt del implementer
# como si fuera verdad. El mv es atómico: se lee el viejo entero o el nuevo
# entero.
} > "$OUT.$$.tmp" 2>/dev/null && mv -f "$OUT.$$.tmp" "$OUT" \
  || { rm -f "$OUT.$$.tmp"; echo "⚠️  brief de $REPO falló; fail-open" >&2; exit 0; }

echo "$OUT"
