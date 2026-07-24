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

t_done
