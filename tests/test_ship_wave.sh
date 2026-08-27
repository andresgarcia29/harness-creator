#!/usr/bin/env bash
# test_ship_wave.sh: el orden del DAG por fin ejecutable. Caso de campo: la
# cadena design-system -> publish -> consumidor -> deploy se corrió a mano y
# un eslabón quedó a medias (testId publicado, consumidor sin bump). La ola
# recorre dag-order, salta lo aterrizado, corre ship.sh por repo y el
# post_ship declarado; un rojo para con el retome exacto.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/tasks/T1" "$WS/.harness"
cp "$ROOT/templates/scripts/ship-wave.sh" "$WS/scripts/"
cp "$ROOT/templates/scripts/harness-policy.py" "$WS/scripts/"
cp "$ROOT/templates/scripts/emit.sh" "$WS/scripts/"
sed 's/{{LOOP_BUDGET}}/3/' "$ROOT/templates/policy.json.tmpl" > "$WS/harness-policy.json"

# stub de ship.sh: loggea la invocación y APPENDEA su línea a ship-ledger.jsonl
# (como el real, que dejó de escribir en ship.log por #232); un marcador de
# fallo por repo permite el caso rojo
export SHIPCALLS="$WS/ship-calls.log"; : > "$SHIPCALLS"
cat > "$WS/scripts/ship.sh" <<'SH'
#!/bin/sh
task="$1"; repo="$2"
echo "ship $repo" >> "$SHIPCALLS"
WS="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$WS/.fail-$repo" ] && { echo "ship de $repo ROJO (fixture)"; exit 3; }
landed=true
[ -f "$WS/.prs-$repo" ] && landed=false
printf '{"repo":"%s","sha":"abc1234","landed":%s}\n' "$repo" "$landed" >> "$WS/tasks/$task/ship-ledger.jsonl"
SH
chmod +x "$WS/scripts/ship.sh"
# with-secrets stub: marca que el hook corre autenticado
cat > "$WS/scripts/with-secrets.sh" <<'SH'
#!/bin/sh
export WS_SECRETS_ON=1
exec "$@"
SH
chmod +x "$WS/scripts/with-secrets.sh"
export HOOKLOG="$WS/hook-calls.log"; : > "$HOOKLOG"
cat > "$WS/bin-hook.sh" <<'SH'
#!/bin/sh
echo "hook ${1:-} secrets=${WS_SECRETS_ON:-0}" >> "$HOOKLOG"
SH
chmod +x "$WS/bin-hook.sh"

jq -n '{schema:1, tasks:[
  {id:"T1", repo:"design-system", depends_on:[]},
  {id:"T2", repo:"agora", depends_on:["T1"]}]}' > "$WS/tasks/T1/dag.json"
cat > "$WS/harness-answers.yaml" <<EOF
project: demo
deploy:
  design-system:
    driver: actions
    post_ship: "$WS/bin-hook.sh design-system"
EOF

run_wave() { ( cd "$WS" && bash scripts/ship-wave.sh "$@" 2>&1 ); }

echo "── la ola respeta el orden y corre el post-ship bajo secretos"

out="$(run_wave T1)"; rc=$?
assert_eq 0 "$rc" "ola completa: exit 0"
assert_eq "ship design-system
ship agora" "$(cat "$SHIPCALLS")" "los repos se shippean en el orden del DAG"
assert_contains "$(cat "$HOOKLOG")" "hook design-system secrets=1" \
  "el post_ship corre tras su repo y bajo with-secrets"
assert_contains "$out" "🟢 ola completa" "y el cierre lo declara"

echo "── reanudación idempotente: nada se repite"

: > "$SHIPCALLS"; : > "$HOOKLOG"
out="$(run_wave T1)"; rc=$?
assert_eq 0 "$rc" "segunda corrida: exit 0"
assert_eq "" "$(cat "$SHIPCALLS")" "ningún ship se re-invoca (el ledger los salta)"
assert_eq "" "$(cat "$HOOKLOG")" "ningún hook verde se repite (ship-wave.log los salta)"

echo "── un rojo detiene la ola con el retome exacto"

rm -f "$WS/tasks/T1/ship-ledger.jsonl" "$WS/tasks/T1/ship.log" "$WS/tasks/T1/ship-wave.log"; : > "$SHIPCALLS"
touch "$WS/.fail-agora"
out="$(run_wave T1)"; rc=$?
assert_eq 1 "$rc" "ship rojo: exit 1"
assert_contains "$out" "paró en agora" "nombra dónde paró"
assert_contains "$out" "--from agora" "y da el comando de retome exacto"
assert_contains "$out" "design-system" "y dice qué SÍ quedó shippeado"
rm -f "$WS/.fail-agora"

# el retome con --from NO re-shippea lo anterior
: > "$SHIPCALLS"
out="$(run_wave T1 --from agora)"; rc=$?
assert_eq 0 "$rc" "retome: exit 0"
assert_eq "ship agora" "$(cat "$SHIPCALLS")" "--from salta los predecesores"

echo "── flow prs: el post_ship se DIFIERE, la ola sigue"

rm -f "$WS/tasks/T1/ship-ledger.jsonl" "$WS/tasks/T1/ship.log" "$WS/tasks/T1/ship-wave.log"
: > "$SHIPCALLS"; : > "$HOOKLOG"; : > "$WS/.harness/events.jsonl"
touch "$WS/.prs-design-system"
out="$(run_wave T1)"; rc=$?
assert_eq 0 "$rc" "PR sin mergear: la ola sigue (exit 0)"
assert_contains "$out" "DIFERIDO" "el post_ship queda diferido, no fingido"
assert_eq "" "$(cat "$HOOKLOG")" "y el hook NO corrió (publicaría algo que no existe)"
assert_contains "$out" "🟡" "el cierre es amarillo, no verde"
assert_contains "$(cat "$WS/.harness/events.jsonl")" "assumption" "y el diferimiento queda en el bus"
assert_contains "$(cat "$SHIPCALLS")" "ship agora" "los repos siguientes SÍ shippearon"
rm -f "$WS/.prs-design-system"

echo "── el ledger viejo (ship.log) sigue contando: las tareas en vuelo (#232)"
# El ledger pasó a llamarse ship-ledger.jsonl porque `ship.log` invitaba a
# redirigirle el stdout del ship encima. Una tarea que ya estaba a mitad de ola
# cuando se actualizó el harness tiene sus líneas en el nombre VIEJO: si la ola
# dejara de verlas, re-shippearía repos que ya publicaron.
rm -f "$WS/tasks/T1/ship-ledger.jsonl" "$WS/tasks/T1/ship.log" "$WS/tasks/T1/ship-wave.log"
: > "$SHIPCALLS"; : > "$HOOKLOG"
printf '{"repo":"design-system","sha":"abc1234","landed":true}\n' > "$WS/tasks/T1/ship.log"
out="$(run_wave T1)"; rc=$?
assert_eq 0 "$rc" "con el ledger en el nombre viejo: exit 0"
assert_eq "ship agora" "$(cat "$SHIPCALLS")" \
  "design-system NO se re-shippea: su línea estaba en ship.log y la ola la ve igual"
assert_contains "$(cat "$HOOKLOG")" "hook design-system" \
  "y landed=true del archivo viejo destraba su post_ship"

echo "── sin DAG: el mensaje manda al camino correcto"

rm -f "$WS/tasks/T1/dag.json"
out="$(run_wave T1)"; rc=$?
assert_eq 3 "$rc" "sin dag.json: exit 3"
assert_contains "$out" "POLICY-DAG-008" "con el código del policy"

echo "── paridad de parsers: la copia de answers_repo_key no puede divergir"

extract_fn() {  # extract_fn <archivo> <fn>
  awk "/^$2\(\) \{/{f=1} f{print} f&&/^\}/{exit}" "$1"
}
a="$(extract_fn "$ROOT/templates/scripts/deploy-watch.sh.tmpl" answers_repo_key | grep -v '^\s*#' | sed 's/[[:space:]]*$//')"
b="$(extract_fn "$ROOT/templates/scripts/ship-wave.sh" answers_repo_key | grep -v '^\s*#' | sed 's/[[:space:]]*$//')"
awk_a="$(printf '%s' "$a" | sed -n '/awk -v/,/harness-answers/p')"
awk_b="$(printf '%s' "$b" | sed -n '/awk -v/,/harness-answers/p')"
[ -n "$awk_a" ] && [ "$awk_a" = "$awk_b" ] \
  && pass "el awk de answers_repo_key es IDÉNTICO en deploy-watch y ship-wave" \
  || fail "los parsers de answers_repo_key divergieron entre deploy-watch y ship-wave"

t_done
