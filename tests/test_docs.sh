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

# ── El .gitignore de la instancia es UN archivo, no una lista de memoria.
# Mientras vivió como prosa dentro de la tabla del skill, el generado se
# divergió en los dos sentidos y graphify-out/ (128 MB) entraba a git (#27).
gi="$root/templates/gitignore.tmpl"
[ -f "$gi" ] && pass "el .gitignore de la instancia es un template versionado" \
  || fail "falta templates/gitignore.tmpl: la lista volvió a ser prosa"
for entry in "repos/" "worktrees/" "locks/" ".cache/" ".secrets" ".secrets.d/" \
             "inventory.json" "go.work" "go.work.sum" "graphify-out/" ".harness/" "tasks/"; do
  grep -qxF "$entry" "$gi" 2>/dev/null && pass ".gitignore cubre $entry" \
    || fail ".gitignore SIN $entry (regenerable o local: no va a git)"
done
skill_gi="$(grep '^| `.gitignore`' "$root/skills/harness-init/SKILL.md")"
assert_contains "$skill_gi" "gitignore.tmpl" "la tabla de generación apunta al template, no a una lista inline"

# ── Ley 13: la recomendada es la duradera, nunca la rápida.
# Caso real: un agente marcó "editar state.json a mano (recomendado)" porque no
# había vuelta atrás por CLI. Era lo rápido, violaba una ley del propio
# CLAUDE.md, y el hueco real (falta un rollback) quedó sin reportar.
claude_md="$root/templates/CLAUDE.md.tmpl"
const="$root/templates/docs/constitution.md.tmpl"
assert_contains "$(cat "$claude_md")" "elimina la causa" "CLAUDE.md tiene la Ley 13"
assert_contains "$(cat "$claude_md")" "NUNCA como" "Ley 13: el atajo nunca va como recomendado"
assert_contains "$(cat "$claude_md")" "Ley 12" "Ley 13: un camino que falta es un bug del harness, no un permiso"
assert_contains "$(cat "$const")" "2b." "la constitución tiene la sección de lo correcto sobre lo rápido"
# La tensión con "código mínimo" tiene que quedar resuelta EN EL TEXTO: sin
# esto, un agente lee la ley nueva como permiso para sobre-construir, que es
# justo lo que §2 y §3 existen para impedir.
assert_contains "$(cat "$claude_md")" "constitución §2" "Ley 13 aclara que no afloja el código mínimo"
assert_contains "$(cat "$const")" "ALCANCE" "la constitución separa alcance (§2) de clase de arreglo (§2b)"
assert_contains "$(cat "$root/templates/commands/auto.md.tmpl")" "elimina la causa" \
  "/auto aplica la Ley 13 al ADR que propone al humano"

# ── Ley de estilo (CONTRIBUTING #6): el guion largo "—" delata prosa de IA.
# RATCHET al estilo ratchet-keeper: el conteo del repo SOLO puede bajar.
# Al reescribir prosa vieja, baja el número de abajo al nuevo conteo (nunca
# lo subas: si tu cambio lo sube, reescribe sin el guion largo). Las cajas
# de terminal "──" (U+2500) son otro carácter y no cuentan.
EMDASH_MAX=614
emdash_now=$(grep -ro "—" --include="*.md" --include="*.tmpl" --include="*.yaml" \
  --include="*.sh" --include="*.py" --include="*.json" "$root" 2>/dev/null \
  | grep -v "/\.git/" | grep -v "templates/ui/dist" | wc -l | tr -d ' ')
if [ "$emdash_now" -le "$EMDASH_MAX" ]; then
  pass "ratchet de guion largo: $emdash_now ≤ $EMDASH_MAX (solo baja)"
else
  fail "ratchet de guion largo: $emdash_now > $EMDASH_MAX; tu cambio AÑADE em dashes. Reescribe con coma/dos puntos/paréntesis (CONTRIBUTING #6)"
fi

t_done
