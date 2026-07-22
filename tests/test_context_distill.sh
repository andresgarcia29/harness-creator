#!/usr/bin/env bash
# test_context_distill.sh: el patrón MinionS como script, contra el código
# REAL del template. Protege: el pack cita fuentes y se cachea por hash; el
# fail-open devuelve crudo sin reader/claude; ids sanitizados; el stamp
# ahorra la segunda llamada.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/bin" "$WS/tasks/T1"
cp "$ROOT/templates/scripts/context-distill.sh" "$WS/scripts/"
printf 'func Login(t string) bool { return check(t) }\n' > "$WS/tasks/T1/auth.go"
printf 'type Booking struct { ID string }\n' > "$WS/tasks/T1/model.go"

echo "── context-distill: MinionS como script"

# 1. sin reader/claude en PATH → fail-open: devuelve el crudo, exit 0
out="$(PATH="/usr/bin:/bin" bash "$WS/scripts/context-distill.sh" T1 auth "cómo se valida" "$WS/tasks/T1/auth.go" 2>/dev/null)"; rc=$?
assert_eq 0 "$rc" "sin reader: exit 0 (fail-open)"
assert_contains "$out" "func Login" "sin reader: devuelve el contenido crudo"

# 2. con reader stub + stamp-models: destila y cita
cat > "$WS/scripts/stamp-models.sh" <<'EOF'
#!/bin/bash
[ "$1" = "resolve" ] && [ "$2" = "reader" ] && echo "modelo-barato"
EOF
chmod +x "$WS/scripts/stamp-models.sh"
cat > "$WS/bin/claude" <<'EOF'
#!/bin/bash
echo "USO_CLAUDE" >> "$CALLS"
cat >/dev/null
echo "- Login valida el token (auth.go:1)"
echo "INCERTIDUMBRE: no se ve la implementación de check()"
EOF
chmod +x "$WS/bin/claude"
export CALLS="$WS/calls.log"; : > "$CALLS"

out="$(PATH="$WS/bin:$PATH" bash "$WS/scripts/context-distill.sh" T1 auth "cómo se valida" "$WS/tasks/T1/auth.go" 2>/dev/null)"
assert_contains "$out" "Login valida el token" "destila con el reader"
assert_contains "$out" "auth.go:1" "el pack cita file:línea"
assert_contains "$out" "Fuentes crudas" "el pack enlaza las fuentes crudas (red de seguridad)"
assert_file "$WS/tasks/T1/context/auth.md" "escribe el pack en context/"
assert_eq 1 "$(grep -c USO_CLAUDE "$CALLS")" "una llamada al reader"

# 3. segunda corrida sin cambios → stamp: cero llamadas nuevas
PATH="$WS/bin:$PATH" bash "$WS/scripts/context-distill.sh" T1 auth "cómo se valida" "$WS/tasks/T1/auth.go" >/dev/null 2>&1
assert_eq 1 "$(grep -c USO_CLAUDE "$CALLS")" "pack fresco: no vuelve a llamar al reader"

# 4. cambia el archivo → invalida el stamp y re-destila
sleep 1; printf '\n// tocado\n' >> "$WS/tasks/T1/auth.go"
PATH="$WS/bin:$PATH" bash "$WS/scripts/context-distill.sh" T1 auth "cómo se valida" "$WS/tasks/T1/auth.go" >/dev/null 2>&1
assert_eq 2 "$(grep -c USO_CLAUDE "$CALLS")" "archivo cambiado: re-destila"

# 5. destilación vacía → fail-open al crudo
cat > "$WS/bin/claude" <<'EOF'
#!/bin/bash
cat >/dev/null
EOF
chmod +x "$WS/bin/claude"
rm -f "$WS/tasks/T1/context/model.md.stamp"
out="$(PATH="$WS/bin:$PATH" bash "$WS/scripts/context-distill.sh" T1 model "qué es Booking" "$WS/tasks/T1/model.go" 2>/dev/null)"
assert_contains "$out" "type Booking" "reader vacío: fail-open al crudo"

# 6. ids inválidos → exit 1 (sin traversal)
PATH="$WS/bin:$PATH" bash "$WS/scripts/context-distill.sh" "../evil" s "q" "$WS/tasks/T1/auth.go" >/dev/null 2>&1 && fail "task traversal pasó" || pass "task-id inválido: exit 1"

t_done
