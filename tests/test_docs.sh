#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"

echo "── contratos de documentación"
root="$(cd "$(dirname "$0")/.." && pwd)"

readme="$(cat "$root/README.md")"
auto="$(cat "$root/templates/commands/auto.md.tmpl")"
index="$(cat "$root/templates/docs/index.md.tmpl")"

assert_not_contains "$readme" "127.0.0.1:7717" "README no conserva el puerto viejo"
assert_not_contains "$readme" "exactamente diez" "README no duplica el número de paradas"
assert_contains "$auto" "Lista cerrada de paradas" "auto declara el contrato cerrado"
assert_contains "$auto" "harness-policy.py pause" "auto registra pausas mediante policy"
assert_contains "$index" "harness/evidence.md" "índice enlaza evidence v1"
assert_contains "$index" "harness/policy.md" "índice enlaza policy v1"

# ── Ley de estilo (CONTRIBUTING #6): el guion largo "—" delata prosa de IA.
# RATCHET al estilo ratchet-keeper: el conteo del repo SOLO puede bajar.
# Al reescribir prosa vieja, baja el número de abajo al nuevo conteo (nunca
# lo subas: si tu cambio lo sube, reescribe sin el guion largo). Las cajas
# de terminal "──" (U+2500) son otro carácter y no cuentan.
EMDASH_MAX=615
emdash_now=$(grep -ro "—" --include="*.md" --include="*.tmpl" --include="*.yaml" \
  --include="*.sh" --include="*.py" --include="*.json" "$root" 2>/dev/null \
  | grep -v "/\.git/" | grep -v "templates/ui/dist" | wc -l | tr -d ' ')
if [ "$emdash_now" -le "$EMDASH_MAX" ]; then
  pass "ratchet de guion largo: $emdash_now ≤ $EMDASH_MAX (solo baja)"
else
  fail "ratchet de guion largo: $emdash_now > $EMDASH_MAX; tu cambio AÑADE em dashes. Reescribe con coma/dos puntos/paréntesis (CONTRIBUTING #6)"
fi

t_done
