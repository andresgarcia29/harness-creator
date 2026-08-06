#!/usr/bin/env bash
# test_repo_brief.sh: el brief es lo unico que el implementer lee ANTES de
# explorar, asi que su contenido viaja dentro de cada prompt de implementer.
# Eso le pone dos obligaciones que se testean aca:
#
#   1. Lo que dice tiene que ser CIERTO. Una seccion inventada no se detecta:
#      se ejecuta con confianza.
#   2. Lo que NO aporta no puede aparecer. Una seccion de relleno en cada brief
#      es contexto pagado en cada tool call de cada implementer, para siempre.
#      Ese es exactamente el gasto que esta ronda vino a cortar.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/scripts" "$WS/graphify-out"
cp "$ROOT/templates/scripts/repo-brief.sh" "$WS/scripts/"
for r in atlas hermes; do
  mkdir -p "$WS/repos/$r"
  printf 'package %s\n' "$r" > "$WS/repos/$r/x.go"
  ( cd "$WS/repos/$r" && git init -q -b main && git config user.email t@t \
      && git config user.name t && git add . && git commit -qm base ) >/dev/null 2>&1
done

# El grafo se ESCRIBE a mano: el test valida el consumo, no a graphify. Asi
# corre en cualquier maquina, con o sin la herramienta instalada.
grafo() { cat > "$WS/graphify-out/graph.json"; }
brief() { rm -f "$WS/.cache/briefs/$1.md"; bash "$WS/scripts/repo-brief.sh" "$1" >/dev/null 2>&1
          cat "$WS/.cache/briefs/$1.md" 2>/dev/null; }

echo "── homonimos: el dato que el implementer NO puede ver desde su worktree"
grafo <<'JSON'
{"nodes":[{"label":"ValidateToken()","repo":"atlas"},
          {"label":"ValidateToken()","repo":"hermes"},
          {"label":"SoloDeAtlas()","repo":"atlas"}],"links":[]}
JSON
out="$(brief atlas)"
assert_contains "$out" "ValidateToken()" "publica el identificador repetido"
assert_contains "$out" "hermes" "y dice en QUE otro repo vive"
assert_contains "$out" "rename_symbol" "y nombra la herramienta que lo hace bien"
assert_not_contains "$out" "SoloDeAtlas" "no lista lo que solo vive en un repo"

echo "── y lo que NO tiene que aparecer nunca"
grafo <<'JSON'
{"nodes":[{"label":"SoloDeAtlas()","repo":"atlas"},
          {"label":"OtroDeHermes()","repo":"hermes"}],"links":[]}
JSON
assert_not_contains "$(brief atlas)" "Homónimos" "sin homonimos NO hay seccion: cada linea se paga en cada prompt"

# Los ARCHIVOS repetidos son la norma, no un riesgo: main.go vive en todos
# lados. Si entraran, la seccion seria ruido garantizado en cada brief.
grafo <<'JSON'
{"nodes":[{"label":"main.go","repo":"atlas"},{"label":"main.go","repo":"hermes"}],
 "links":[]}
JSON
assert_not_contains "$(brief atlas)" "main.go  también" "un nombre de ARCHIVO repetido no es un homonimo peligroso"

echo "── fail-open: el brief nunca puede morir por culpa del grafo"
printf 'esto no es json {{{' > "$WS/graphify-out/graph.json"
out="$(brief atlas)"
assert_contains "$out" "Stack y comandos" "grafo corrupto: el brief sale igual"
assert_not_contains "$out" "Homónimos" "y no inventa una seccion"
rm -f "$WS/graphify-out/graph.json"
assert_contains "$(brief atlas)" "Stack y comandos" "sin grafo: el brief sale igual"

echo "── el tope existe: un grafo grande no puede inflar el prompt"
python3 - "$WS/graphify-out/graph.json" <<'PYEOF'
import json, sys
n = [{"label": f"Repetido{i}()", "repo": r} for i in range(200) for r in ("atlas", "hermes")]
json.dump({"nodes": n, "links": []}, open(sys.argv[1], "w"))
PYEOF
out="$(brief atlas)"
lineas="$(printf '%s' "$out" | sed -n '/## Homónimos/,/^  Un reemplazo/p' | wc -l | tr -d ' ')"
[ "$lineas" -lt 20 ] && pass "200 homónimos entran acotados ($lineas líneas)" \
                     || fail "sección sin tope: $lineas líneas"
assert_contains "$out" "y 188 más" "y DICE cuántos dejó afuera: un recorte callado se lee como cobertura total"

t_done
