#!/usr/bin/env bash
# test_minion_probe.sh: el fan-out MinionS (descomposición + workers paralelos)
# contra el código REAL del template. Protege: cada worker responde SU probe
# sobre SU scope, en paralelo; cita/DESCONOCIDO; fail-open sin worker; scope
# vacío es honesto (SIN CONTEXTO, no inventa); ids sanitizados.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/bin" "$WS/tasks/T1" "$WS/repos/atlas"
cp "$ROOT/templates/scripts/minion-probe.sh" "$WS/scripts/"
printf 'func Login(t string) bool { return check(t) }\n' > "$WS/repos/atlas/auth.go"
printf 'message Rate { int32 limit = 1; }\n' > "$WS/repos/atlas/rate.proto"

# stamp-models stub → tier worker
cat > "$WS/scripts/stamp-models.sh" <<'EOF'
#!/bin/bash
[ "$1" = "resolve" ] && [ "$2" = "worker" ] && echo "modelo-worker"
EOF
chmod +x "$WS/scripts/stamp-models.sh"

# claude stub: registra que corrió y responde citando su material
cat > "$WS/bin/claude" <<'EOF'
#!/bin/bash
echo "WORKER_RAN" >> "$CALLS"
material="$(cat)"
if echo "$material" | grep -q "auth.go"; then
  echo "- Login valida el token (repos/atlas/auth.go:1)"
elif echo "$material" | grep -q "rate.proto"; then
  echo "- Rate tiene campo limit (repos/atlas/rate.proto:1)"
else
  echo "DESCONOCIDO"
fi
EOF
chmod +x "$WS/bin/claude"
export CALLS="$WS/calls.log"; : > "$CALLS"

cat > "$WS/probes.json" <<'EOF'
[
  {"id":"auth","q":"cómo se valida","scope":{"files":["repos/atlas/auth.go"]}},
  {"id":"rate","q":"qué campos tiene Rate","scope":{"files":["repos/atlas/rate.proto"]}},
  {"id":"nada","q":"algo sin scope","scope":{}}
]
EOF

echo "── minion-probe: descomposición + workers en paralelo"

out="$(PATH="$WS/bin:$PATH" bash "$WS/scripts/minion-probe.sh" T1 "$WS/probes.json" 2>&1)"; rc=$?
assert_eq 0 "$rc" "exit 0"
assert_contains "$out" "repos/atlas/auth.go:1" "worker de auth cita su fuente"
assert_contains "$out" "repos/atlas/rate.proto:1" "worker de rate cita su fuente"
assert_file "$WS/tasks/T1/probes/auth.md" "escribe la respuesta por probe"
assert_file "$WS/tasks/T1/probes/rate.md" "una respuesta por probe"
assert_eq 2 "$(grep -c WORKER_RAN "$CALLS")" "un worker por probe CON scope (2), no por el vacío"
assert_contains "$out" "SIN CONTEXTO" "probe sin scope: honesto, no inventa"

# cada worker vio SOLO su scope: el de auth no debe citar rate y viceversa
grep -q "rate.proto" "$WS/tasks/T1/probes/auth.md" && fail "el worker de auth vio contexto ajeno" || pass "aislamiento de scope: cada worker vio solo el suyo"

# fail-open: sin claude → devuelve crudo, no revienta
out="$(PATH="/usr/bin:/bin" bash "$WS/scripts/minion-probe.sh" T1 "$WS/probes.json" 2>/dev/null)"; rc=$?
assert_eq 0 "$rc" "sin worker/claude: exit 0 (fail-open)"
assert_contains "$out" "func Login" "sin worker: devuelve el contexto crudo del scope"

# ids inválidos → exit 1 (sin traversal)
PATH="$WS/bin:$PATH" bash "$WS/scripts/minion-probe.sh" "../evil" "$WS/probes.json" >/dev/null 2>&1 && fail "task traversal pasó" || pass "task-id inválido: exit 1"

# probes.json que no es array → exit 1
echo '{"no":"array"}' > "$WS/bad.json"
PATH="$WS/bin:$PATH" bash "$WS/scripts/minion-probe.sh" T1 "$WS/bad.json" >/dev/null 2>&1 && fail "no-array pasó" || pass "probes.json no-array: exit 1"

t_done
