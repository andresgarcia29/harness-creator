#!/usr/bin/env bash
# test_graph_refresh.sh — el ciclo de vida del grafo de graphify, contra el
# CÓDIGO REAL del template. Protege el contrato que cierra el hueco de
# "graphify query contra un grafo que nadie construyó": build inicial sin
# --update, refresh incremental CON --update, stamp que evita trabajo si
# ningún HEAD cambió, y fail-open total sin el binario instalado.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/bin" "$WS/repos/alpha"
cp "$ROOT/templates/scripts/graph-refresh.sh" "$WS/scripts/"

cd "$WS/repos/alpha"
git init -q . && git config user.email t@t && git config user.name t
echo a > f.go && git add . && git commit -qm init

# stub de graphify: registra sus args y produce el graph.json como el real
cat > "$WS/bin/graphify" <<'EOF'
#!/bin/bash
echo "$@" >> calls.log
mkdir -p graphify-out && echo '{}' > graphify-out/graph.json
EOF
chmod +x "$WS/bin/graphify"

echo "── graph-refresh: el grafo se construye, refresca y no se pudre"

# 1. sin graphify instalado → fail-open, exit 0, silencio
out="$(PATH="/usr/bin:/bin" bash "$WS/scripts/graph-refresh.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "sin binario: exit 0 (capacidad no elegida ≠ error)"
assert_eq "" "$out" "sin binario: silencio total"

# 2. primera corrida → build inicial (sin --update), graph.json + stamp
PATH="$WS/bin:$PATH" bash "$WS/scripts/graph-refresh.sh" >/dev/null
assert_file "$WS/graphify-out/graph.json" "build inicial produce graph.json"
assert_file "$WS/.cache/graph.stamp" "build inicial escribe el stamp"
assert_eq "update repos" "$(head -1 "$WS/calls.log")" "primera corrida: build code-only (update repos, sin API key)"

# 3. segunda corrida sin cambios → el stamp la vuelve no-op
PATH="$WS/bin:$PATH" bash "$WS/scripts/graph-refresh.sh" >/dev/null
assert_eq 1 "$(wc -l < "$WS/calls.log" | tr -d ' ')" "HEADs sin cambio: cero llamadas a graphify"

# 4. commit nuevo → refresh incremental con --update
cd "$WS/repos/alpha" && echo b > g.go && git add . && git commit -qm change
PATH="$WS/bin:$PATH" bash "$WS/scripts/graph-refresh.sh" >/dev/null
assert_eq "update repos" "$(tail -1 "$WS/calls.log")" "HEAD nuevo: refresh incremental (update repos)"
assert_eq 2 "$(wc -l < "$WS/calls.log" | tr -d ' ')" "exactamente una llamada por cambio real"

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
