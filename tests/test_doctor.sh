#!/usr/bin/env bash
# test_doctor.sh — el contrato del doctor: (1) un workspace roto FALLA (exit
# no-cero) y cada fallo trae su remediación; (2) los checks nuevos de esta
# versión existen de verdad (models drift, beads, graphify, AGENTS.md); (3)
# un fallo jamás es silencioso. No prueba cada check — prueba que el doctor
# no miente en las dos direcciones.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

echo "── doctor: un workspace roto falla con remediación"

# workspace casi vacío: faltan los archivos base
mkdir -p "$WS/repos"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "workspace roto: exit no-cero" || fail "workspace roto: salió 0 (doctor mentiroso)"
assert_contains "$out" "remediación" "cada fallo trae remediación"
assert_contains "$out" "CLAUDE.md" "detecta archivos base faltantes"
assert_contains "$out" "resultado:" "imprime el resumen de fallos"

echo "── doctor: el drift de modelos se detecta (stamp-models check)"

# workspace con models.yaml + agente DESALINEADO a propósito
mkdir -p "$WS/scripts" "$WS/.claude/agents"
cp "$ROOT/templates/scripts/stamp-models.sh" "$WS/scripts/"
cat > "$WS/models.yaml" <<'EOF'
provider: anthropic

models.anthropic:
  fast: haiku
  smart: sonnet
  deep: opus

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
printf -- '---\nname: architect\nmodel: editado-a-mano\n---\n' > "$WS/.claude/agents/architect.md"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "desalineado con models.yaml" "doctor detecta drift de modelos"
assert_contains "$out" "make models" "el drift trae su remediación"

# alineado → el mismo check pasa a verde
bash "$WS/scripts/stamp-models.sh" >/dev/null 2>&1
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "agentes alineados con models.yaml" "alineado: check en verde"

echo "── doctor: los checks de cadena-completa existen"

# los checks añadidos por la auditoría anti-consejo-vacío deben estar en el
# script — si alguien los borra, este test lo cacha sin depender de tener
# graphify/bd instalados en la máquina del test
for marker in "graphify" "bd ready" "AGENTS.md"; do
  grep -q "$marker" "$ROOT/scripts/doctor.sh" \
    && pass "check presente en doctor: $marker" \
    || fail "check AUSENTE en doctor: $marker"
done

t_done
