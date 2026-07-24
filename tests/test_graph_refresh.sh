#!/usr/bin/env bash
# test_graph_refresh.sh — el ciclo de vida del grafo de graphify, contra el
# CÓDIGO REAL del template. Protege el contrato que cierra el hueco de
# "graphify query contra un grafo que nadie construyó": build POR REPO y
# merge, verificación por NODOS (no por exit code ni por existencia del
# archivo), stamp por HEAD que evita trabajo, fallo RUIDOSO cuando no se
# indexa nada, y fail-open total sin el binario instalado (issue #25).
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/bin" "$WS/repos/alpha" "$WS/repos/beta"
cp "$ROOT/templates/scripts/graph-refresh.sh" "$WS/scripts/"

for r in alpha beta; do
  (cd "$WS/repos/$r" && git init -q . && git config user.email t@t && git config user.name t \
     && echo "$r" > f.go && git add . && git commit -qm init)
done

# stub de graphify: se comporta como el real (update escribe
# <path>/graphify-out/graph.json; merge-graphs suma nodos y escribe --out) y
# registra sus llamadas. NODES controla cuántos nodos "encuentra".
cat > "$WS/bin/graphify" <<'EOF'
#!/bin/bash
echo "$@" >> "$CALLS"
n="${NODES:-3}"
case "$1" in
  update)
    mkdir -p "$2/graphify-out"
    if [ "$n" -eq 0 ]; then
      echo "[graphify watch] No code files found - nothing to rebuild."
      printf '{"nodes": [], "links": []}' > "$2/graphify-out/graph.json"
    else
      printf '{"nodes": [' > "$2/graphify-out/graph.json"
      for i in $(seq 1 "$n"); do [ "$i" -gt 1 ] && printf ',' >> "$2/graphify-out/graph.json"; printf '{"id":"%s%s"}' "$2" "$i" >> "$2/graphify-out/graph.json"; done
      printf '], "links": []}' >> "$2/graphify-out/graph.json"
    fi
    exit 0 ;;   # el real sale 0 aunque no indexe nada: por eso contamos nodos
  merge-graphs)
    out="graphify-out/merged.json"; total=0; args=""
    while [ $# -gt 0 ]; do
      case "$1" in --out) out="$2"; shift 2 ;; *) args="$args $1"; shift ;; esac
    done
    for g in $args; do
      [ -f "$g" ] || continue
      c="$(jq '.nodes|length' "$g" 2>/dev/null || echo 0)"; total=$((total+c))
    done
    mkdir -p "$(dirname "$out")"
    printf '{"nodes": [' > "$out"
    for i in $(seq 1 "$total"); do [ "$i" -gt 1 ] && printf ',' >> "$out"; printf '{"id":"m%s"}' "$i" >> "$out"; done
    printf '], "links": []}' >> "$out"
    exit 0 ;;
esac
EOF
chmod +x "$WS/bin/graphify"
export CALLS="$WS/calls.log"; : > "$CALLS"

echo "── graph-refresh: construye por repo y fusiona (issue #25)"

# 1. sin graphify instalado → fail-open, exit 0, silencio
out="$(PATH="/usr/bin:/bin" bash "$WS/scripts/graph-refresh.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "sin binario: exit 0 (capacidad no elegida ≠ error)"
assert_eq "" "$out" "sin binario: silencio total"

# 2. primera corrida → un update POR REPO y un merge, no una pasada sobre repos/
out="$(cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/graph-refresh.sh 2>&1)"
assert_contains "$(cat "$CALLS")" "update repos/alpha/" "indexa repos/alpha por separado"
assert_contains "$(cat "$CALLS")" "update repos/beta/" "indexa repos/beta por separado"
assert_not_contains "$(cat "$CALLS")" "update repos
" "NO apunta graphify al directorio padre (ahí se quedaba en 0 nodos)"
assert_contains "$(cat "$CALLS")" "merge-graphs" "fusiona los grafos por repo en el cross-repo"
assert_file "$WS/graphify-out/graph.json" "el grafo vive en graphify-out/graph.json"
assert_eq 6 "$(jq '.nodes|length' "$WS/graphify-out/graph.json")" "el grafo fusionado tiene los nodos de los dos repos"
assert_contains "$out" "6 nodos de 2/2 repos" "reporta NODOS y repos, no un ✓ a ciegas"
assert_file "$WS/.cache/graph.stamp" "escribe el stamp"

# 3. segunda corrida sin cambios → no-op
: > "$CALLS"
(cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/graph-refresh.sh >/dev/null 2>&1)
assert_eq "0" "$(wc -l < "$CALLS" | tr -d ' ')" "HEADs sin cambio y grafo con nodos: cero llamadas"

# 4. commit en UN repo → solo ese se re-extrae (incremental de verdad)
: > "$CALLS"
(cd "$WS/repos/alpha" && echo b > g.go && git add . && git commit -qm change)
(cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/graph-refresh.sh >/dev/null 2>&1)
assert_contains "$(cat "$CALLS")" "update repos/alpha/" "el repo que cambió se re-extrae"
assert_not_contains "$(cat "$CALLS")" "update repos/beta/" "el repo intacto NO se re-extrae"

echo "── un grafo vacío NO es un grafo sano"

: > "$CALLS"; rm -rf "$WS/graphify-out" "$WS/.cache"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" NODES=0 bash scripts/graph-refresh.sh 2>&1)"; rc=$?
assert_eq 0 "$rc" "cero nodos: sigue siendo fail-open (no tumba al que lo llamó)"
assert_contains "$out" "no indexó NADA" "cero nodos se reporta RUIDOSAMENTE, no como ✓"
assert_not_contains "$out" "al día" "no dice 'grafo al día' con el grafo vacío"
assert_no_file "$WS/.cache/graph.stamp" "sin stamp: el próximo refresh lo reintenta"
assert_contains "$(cat "$WS/.cache/graph.log" 2>/dev/null)" "No code files found" \
  "la salida de graphify queda en el log, no en /dev/null"

# y un grafo vacío preexistente tampoco cuenta como fresco
mkdir -p "$WS/graphify-out"; printf '{"nodes": [], "links": []}' > "$WS/graphify-out/graph.json"
printf 'x' > "$WS/.cache/graph.stamp"
: > "$CALLS"
(cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/graph-refresh.sh >/dev/null 2>&1)
assert_contains "$(cat "$CALLS")" "update" "grafo vacío con stamp: se reconstruye igual"

echo "── el doctor cuenta nodos, no archivos (issue #25)"

cp "$ROOT/scripts/doctor.sh" "$WS/scripts/doctor.sh"
printf '{"nodes": [], "links": []}' > "$WS/graphify-out/graph.json"
out="$(PATH="$WS/bin:$PATH" bash "$WS/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "VACÍO" "grafo de 0 nodos: el doctor lo marca como fallo"
assert_not_contains "$out" "responde de verdad" "ya no afirma lo que no comprueba"
printf '{"nodes": [{"id":"a"},{"id":"b"}], "links": []}' > "$WS/graphify-out/graph.json"
out="$(PATH="$WS/bin:$PATH" bash "$WS/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "2 nodos" "grafo con contenido: el doctor dice cuántos nodos"

echo "── el grafo se construye en el ONBOARDING, no en la primera tarea"

# El build inicial tarda minutos: si se deja para la primera query, el agente
# cae a grep masivo justo en medio de una tarea. El bootstrap lo construye
# ANTES del doctor (que lo verifica) y antes de que nadie lo use.
boot="$ROOT/templates/scripts/bootstrap.sh.tmpl"
grep -q "graph-refresh.sh" "$boot" || fail "bootstrap no construye el grafo"
g_line="$(grep -n "scripts/graph-refresh.sh" "$boot" | head -1 | cut -d: -f1)"
d_line="$(grep -n "scripts/doctor.sh" "$boot" | head -1 | cut -d: -f1)"
[ -n "$g_line" ] && [ -n "$d_line" ] && [ "$g_line" -lt "$d_line" ] \
  && pass "el grafo se construye ANTES del doctor que lo verifica" \
  || fail "el bootstrap corre el doctor antes de construir el grafo"
bash -n "$boot" && pass "bootstrap con sintaxis válida" || fail "bootstrap con error de sintaxis"

t_done
