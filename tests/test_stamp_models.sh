#!/usr/bin/env bash
# test_stamp_models.sh — la perilla de modelos: models.yaml (aliases por
# proveedor + roles + overrides) → frontmatter de los agentes, vía el
# CÓDIGO REAL del template scripts/stamp-models.sh. Protege el contrato:
# cambiar modelo o proveedor = UNA línea + make models, jamás editar agentes.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/.claude/agents"
cp "$ROOT/templates/scripts/stamp-models.sh" "$WS/scripts/"

cat > "$WS/models.yaml" <<'EOF'
provider: anthropic

models.anthropic:
  fast: haiku
  smart: sonnet
  deep: opus

models.kimi:
  # comentario dentro de sección: no debe romper el parser
  fast: kimi-k2-turbo
  smart: kimi-k2
  deep: kimi-k2-thinking

roles:
  orquestador: deep
  architect: deep
  abogados: deep
  reviewer: smart
  implementer: smart
  qa: fast
  mechanical: fast
  escalation: deep

overrides:
EOF

mk_agent() {  # mk_agent <nombre>
  printf -- '---\nname: %s\nmodel: SIN-ESTAMPAR\n---\ncuerpo del agente\n' "$1" \
    > "$WS/.claude/agents/$1.md"
}
mk_agent architect; mk_agent reviewer; mk_agent qa; mk_agent svc-atlas

echo "── stamp-models: la política se materializa, nadie edita agentes"

bash "$WS/scripts/stamp-models.sh" >/dev/null || fail "stamp falló"
assert_eq opus  "$(awk '/^model:/{print $2}' "$WS/.claude/agents/architect.md")" "architect → roles.architect (deep→opus)"
assert_eq sonnet "$(awk '/^model:/{print $2}' "$WS/.claude/agents/reviewer.md")" "reviewer → roles.reviewer (smart→sonnet)"
assert_eq haiku "$(awk '/^model:/{print $2}' "$WS/.claude/agents/qa.md")" "qa → roles.qa (fast→haiku)"
assert_eq opus  "$(awk '/^model:/{print $2}' "$WS/.claude/agents/svc-atlas.md")" "svc-* cae al rol abogados"
grep -q "cuerpo del agente" "$WS/.claude/agents/architect.md" \
  && pass "el cuerpo del agente queda intacto" || fail "el stamp tocó el cuerpo"

# resolve: alias directo y rol
assert_eq opus "$(bash "$WS/scripts/stamp-models.sh" resolve deep)" "resolve <alias>"
assert_eq sonnet "$(bash "$WS/scripts/stamp-models.sh" resolve reviewer)" "resolve <rol> (rol→alias→id)"

# check: alineado = 0; drift manual = 1 con remediación
bash "$WS/scripts/stamp-models.sh" check >/dev/null \
  && pass "check en verde tras stamp" || fail "check reporta drift sin haberlo"
printf -- '---\nname: qa\nmodel: editado-a-mano\n---\n' > "$WS/.claude/agents/qa.md"
out="$(bash "$WS/scripts/stamp-models.sh" check 2>&1)"; rc=$?
assert_eq 1 "$rc" "check detecta drift (exit 1)"
assert_contains "$out" "make models" "el drift trae su remediación"

# override por agente: una línea gana sobre el rol
printf 'overrides:\n  svc-atlas: fast\n' >> "$WS/models.yaml"
# (la sección overrides original estaba vacía; la nueva al final gana en el parser
#  de primera coincidencia — la duplicamos a propósito para probar robustez)
bash "$WS/scripts/stamp-models.sh" >/dev/null
assert_eq haiku "$(awk '/^model:/{print $2}' "$WS/.claude/agents/svc-atlas.md")" "override svc-atlas: fast gana sobre abogados"

# cambio de proveedor: UNA línea, mismos aliases
sed 's/^provider: anthropic/provider: kimi/' "$WS/models.yaml" > "$WS/m.tmp" && mv "$WS/m.tmp" "$WS/models.yaml"
bash "$WS/scripts/stamp-models.sh" >/dev/null
assert_eq kimi-k2-thinking "$(awk '/^model:/{print $2}' "$WS/.claude/agents/architect.md")" "provider: kimi → mismos roles, IDs de kimi"
assert_eq kimi-k2-turbo "$(bash "$WS/scripts/stamp-models.sh" resolve fast)" "resolve respeta el provider activo"

# alias inexistente en el proveedor → error claro, no silencio
if bash "$WS/scripts/stamp-models.sh" resolve turbo >/dev/null 2>&1; then
  fail "alias inexistente debió fallar"
else
  pass "alias inexistente falla con error (no estampa basura)"
fi

t_done
