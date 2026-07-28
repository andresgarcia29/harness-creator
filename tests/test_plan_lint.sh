#!/usr/bin/env bash
# test_plan_lint.sh — el plan es ejecutable o no es plan. Este script es la
# única revisión de plan que no cuesta una ronda de review, así que tiene que
# ser exacto en las dos direcciones: no dejar pasar huecos y no inventar
# rojos sobre prosa legítima en español (el caso "todo el diff").
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/tasks/T1"
cp "$ROOT/templates/scripts/plan-lint.sh" "$WS/scripts/"

delta_ok() {
  cat > "$WS/tasks/T1/delta-spec.md" <<'EOF'
## ADDED Requirements
- GW-4: el gateway DEBE limitar a 100 req/min por tenant.
- GW-5: el gateway DEBE exponer X-RateLimit-Remaining.
EOF
}
plan_ok() {
  cat > "$WS/tasks/T1/plan.md" <<'EOF'
# Plan de T1

Todo el diff pasa por el gateway, así que el orden importa poco.

### T1 · atlas · limita por tenant en el gateway
- repo: atlas
- req: GW-4, GW-5
- archivos: internal/ratelimit/limiter.go, internal/http/middleware.go
- criterios: responde 429 tras 100 req/min por tenant
- complexity: low
- deps: ninguna
EOF
}
run() { ( cd "$WS" && bash scripts/plan-lint.sh "$1" 2>&1 ); }

echo "── plan-lint: el camino verde"
delta_ok; plan_ok
out="$(run T1)"; rc=$?
assert_eq 0 "$rc" "plan completo + delta con sus reqs: verde"
assert_contains "$out" "plan ejecutable" "dice por qué pasó"
assert_not_contains "$out" "el plan deja decisiones abiertas" "'Todo el diff' NO es un TODO de código"

echo "── plan-lint: los rojos"
delta_ok
cat > "$WS/tasks/T1/plan.md" <<'EOF'
### T1 · atlas · limita por tenant
- repo: atlas
- req: GW-4
- criterios: que ande rápido
- complexity: low
- deps: ninguna
EOF
out="$(run T1)"; rc=$?
assert_eq 3 "$rc" "tarea sin 'archivos': rojo (exit 3)"
assert_contains "$out" "archivos" "nombra la clave que falta"

plan_ok
printf '\nNota: investigar si el limiter va en el middleware.\n' >> "$WS/tasks/T1/plan.md"
out="$(run T1)"; rc=$?
assert_eq 3 "$rc" "decisión abierta ('investigar si'): rojo"

plan_ok
cat > "$WS/tasks/T1/plan.md" <<'EOF'
### T1 · atlas · limita por tenant
- repo: atlas
- req: GW-4, GW-9
- archivos: a.go
- criterios: responde 429 tras 100 req/min
- complexity: low
- deps: ninguna
EOF
out="$(run T1)"; rc=$?
assert_eq 3 "$rc" "req que el delta-spec no define: rojo"
assert_contains "$out" "GW-9" "nombra el requirement huérfano"

plan_ok
sed 's/complexity: low/complexity: media/' "$WS/tasks/T1/plan.md" > "$WS/p.tmp" && mv "$WS/p.tmp" "$WS/tasks/T1/plan.md"
out="$(run T1)"; rc=$?
assert_eq 3 "$rc" "complexity fuera de low|high: rojo"

plan_ok
rm -f "$WS/tasks/T1/delta-spec.md"
out="$(run T1)"; rc=$?
assert_eq 3 "$rc" "sin delta-spec: rojo (todos los carriles lo producen)"

echo "── plan-lint: artefacto ausente y entradas hostiles"
delta_ok; plan_ok
out="$(run T9)"; rc=$?
assert_eq 2 "$rc" "tarea sin plan.md: exit 2 (falta artefacto, no plan rojo)"
out="$(run ../evil)"; rc=$?
assert_eq 2 "$rc" "task-id con traversal: rechazado"

echo
echo "── el carril se verifica contra los ARCHIVOS del plan, no al final"
# gate_lane (ship.sh) sigue siendo la ley, pero corría después de implementar,
# revisar y hacer QA. Un express rojo por carril obliga a escalar y volver a
# /rfc: el retroceso más caro del pipeline, descubierto en el peor momento.
mk_task() {  # mk_task <id> <lane> <archivos>
  mkdir -p "$WS/tasks/$1"
  printf '{"schema":1,"task_id":"%s","lane":"%s","phase":"rfc"}' "$1" "$2" > "$WS/tasks/$1/state.json"
  cat > "$WS/tasks/$1/plan.md" <<PLAN
### T1 · atlas · algo
- repo: atlas
- req: R-1
- archivos: $3
- criterios: responde 200
- complexity: low
- deps: ninguna
PLAN
  printf '## ADDED Requirements\n- R-1: algo\n' > "$WS/tasks/$1/delta-spec.md"
}

mk_task LANE1 express "internal/http/handler.go"
bash "$WS/scripts/plan-lint.sh" LANE1 >/dev/null 2>&1 \
  && pass "express con archivos normales: verde" || fail "express limpio fue rechazado"

mk_task LANE2 express "proto/api.proto, internal/x.go"
out="$(bash "$WS/scripts/plan-lint.sh" LANE2 2>&1)"; rc=$?
assert_eq 3 "$rc" "express que YA planea tocar un .proto: rojo en el plan"
assert_contains "$out" "carril express" "nombra el carril"
assert_contains "$out" "escalate" "da la remediación de escalar, no de borrar el archivo"
assert_contains "$out" "cuando sale barato" "dice por qué acá y no en el ship"

mk_task LANE3 express "migrations/001_add.sql"
bash "$WS/scripts/plan-lint.sh" LANE3 >/dev/null 2>&1 \
  && fail "migración en express no se cazó" || pass "migración planeada en express: rojo"

mk_task LANE4 full "proto/api.proto"
bash "$WS/scripts/plan-lint.sh" LANE4 >/dev/null 2>&1 \
  && pass "full tocando proto: no es asunto de este check" || fail "full fue rechazado"

# Sin state.json (tarea vieja o flujo manual) no se inventa un carril.
mk_task LANE5 express "proto/api.proto"; rm -f "$WS/tasks/LANE5/state.json"
bash "$WS/scripts/plan-lint.sh" LANE5 >/dev/null 2>&1 \
  && pass "sin state.json: no asume carril (compat)" || fail "sin state.json bloqueó"

echo
echo "── los números de línea envejecen: el plan ancla por símbolo"
# Caso de campo, cuatro veces en una corrida: el arquitecto escribió
# render.mjs:44, una tarea hermana shippeó y movió el archivo, y el
# implementer siguió coordenadas muertas. Y un :NN de regalo esquiva los
# patrones anclados a $ del guard de carril (schema.sql:12 vs \.sql$).

delta_ok; plan_ok
sed 's|internal/ratelimit/limiter.go|internal/ratelimit/limiter.go:42|' \
  "$WS/tasks/T1/plan.md" > "$WS/p.tmp" && mv "$WS/p.tmp" "$WS/tasks/T1/plan.md"
out="$(run T1)"; rc=$?
assert_eq 3 "$rc" "archivos: con sufijo :NN: rojo"
assert_contains "$out" "limiter.go:42" "nombra la referencia envejecible"
assert_contains "$out" "SÍMBOLO" "la remediación pide anclar por símbolo"

delta_ok; plan_ok
printf '\nEl bug está en render.mjs:44 y se propaga.\n' >> "$WS/tasks/T1/plan.md"
out="$(run T1)"; rc=$?
assert_eq 3 "$rc" "referencia archivo:NN en la prosa: rojo"
assert_contains "$out" "render.mjs:44" "la nombra"

delta_ok; plan_ok
printf '\nReunión a las 12:30 en http://localhost:8080 con el equipo.\n' >> "$WS/tasks/T1/plan.md"
out="$(run T1)"; rc=$?
assert_eq 0 "$rc" "una hora (12:30) y un host:puerto NO son referencias a archivos"

# y el agujero del guard de carril queda cerrado: schema.sql:12 en express
mk_task LANE6 express "db/schema.sql:12"
out="$(bash "$WS/scripts/plan-lint.sh" LANE6 2>&1)"; rc=$?
assert_eq 3 "$rc" "express con schema.sql:12: rojo (antes el :12 esquivaba \\.sql\$)"

echo
echo "── LANE_GUARD_PATTERN: un solo criterio en dos archivos"
# El patrón está duplicado literal entre plan-lint.sh (chequeo temprano) y
# gate_lane de ship.sh.tmpl (la ley). Si divergen, el plan aprueba lo que el
# ship rechaza y el retroceso caro vuelve. El del template escapa \$ (la
# generación lo exige); se normaliza antes de comparar.
pat_lint="$(sed -n 's/.*LANE_GUARD_PATTERN:-\(.*\)}"$/\1/p' "$ROOT/templates/scripts/plan-lint.sh")"
pat_ship="$(sed -n 's/.*LANE_GUARD_PATTERN:-\(.*\)}"$/\1/p' "$ROOT/templates/scripts/ship.sh.tmpl" | sed 's/\\\$/$/g')"
[ -n "$pat_lint" ] && [ -n "$pat_ship" ] || fail "no pude extraer los dos patrones"
assert_eq "$pat_ship" "$pat_lint" "el patrón de plan-lint es EL MISMO que el de gate_lane (normalizado el escape del template)"

t_done
