#!/usr/bin/env bash
# test_custom_rule.sh: las reglas custom del workspace, o sea /custom-build-rule
# y /custom-edit-rule más el DIENTE que las hace algo distinto de un párrafo.
#
# Lo que se ata acá son dos cosas de naturaleza distinta:
#   · el contrato de las skills (prosa): gatillos, punteros cruzados, registro
#     en la tabla de generación y en el update. Sin esto, una skill que el
#     plugin tiene no llega a ninguna instancia.
#   · el comportamiento REAL del doctor sobre .claude/rules/*.md, que es lo
#     único que impide que una regla apunte a un verificador inexistente y se
#     cite igual en los reviews como si tuviera diente.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

BUILD="$ROOT/templates/skills/custom-build-rule/SKILL.md"
EDIT="$ROOT/templates/skills/custom-edit-rule/SKILL.md"
CONTRATO="$ROOT/templates/docs/rules.md.tmpl"

echo "── /custom-build-rule y /custom-edit-rule: el contrato de las skills"

assert_file "$BUILD" "existe el template de custom-build-rule"
assert_file "$EDIT" "existe el template de custom-edit-rule"
assert_file "$CONTRATO" "existe el contrato docs/harness/rules.md"

for f in "$BUILD" "$EDIT"; do
  d="$(basename "$(dirname "$f")")"
  [ "$(head -1 "$f")" = "---" ] && pass "$d: abre con frontmatter" \
    || fail "$d: no abre con '---' (la skill no carga)"
  grep -qx "name: $d" "$f" && pass "$d: name coincide con el directorio" \
    || fail "$d: el name del frontmatter no es '$d'"
done

build="$(cat "$BUILD")"; edit="$(cat "$EDIT")"; contrato="$(cat "$CONTRATO")"
desc_build="$(grep '^description: ' "$BUILD")"
desc_edit="$(grep '^description: ' "$EDIT")"
assert_contains "$desc_build" "crea una regla" "build dispara con 'crea una regla'"
assert_contains "$desc_build" "de ahora en adelante" "y con el 'de ahora en adelante' que la gente dice de verdad"
assert_contains "$desc_edit" "cambia la regla" "edit dispara con 'cambia la regla'"
assert_contains "$build" "/custom-edit-rule" "build deriva a edit para una regla que ya existe"
assert_contains "$edit" "/custom-build-rule" "edit deriva a build cuando la regla no existe"

# ── El enrichment es lo que se pidió y lo que separa una ley viva de una
# letra muerta: mirar la realidad y CONTAR antes de legislar.
assert_contains "$build" "Enrichment" "build tiene fase de enrichment"
assert_contains "$build" "números" "el enrichment exige números, no adjetivos"
assert_contains "$build" "conflictos" "el enrichment busca choques con la constitución y otras reglas"
assert_contains "$build" "migrar" "el enrichment mide el costo de cumplirla"
assert_contains "$build" "áximo 3" "las preguntas tienen techo (la ceremonia es el modo de fallo)"
assert_contains "$edit" "Enrichment" "edit mide el cumplimiento actual antes de tocar la ley"
assert_contains "$edit" "afloja" "edit clasifica el cambio en afloja/endurece/aclara"
assert_contains "$edit" "DRAFT" "lo que cambia la exigencia vuelve a DRAFT"

# ── La ratificación es humana, y el diente se declara. Las dos leyes del
# harness que esta familia de skills tiene que heredar sí o sí.
assert_contains "$build" "status: DRAFT" "la regla nace DRAFT"
assert_contains "$build" "enforced_by" "la regla declara con qué artefacto se verifica"
assert_contains "$build" "constitution.md" "build deja el puntero que la hace visible a los agentes"
assert_contains "$contrato" "judgment" "el contrato enumera la lista cerrada de dientes"
assert_contains "$contrato" "pipeline-step" "y el diente de paso custom"

# ── Registro: sin esto, ninguna instancia recibe nada de lo anterior.
init="$(cat "$ROOT/skills/harness-init/SKILL.md")"
assert_contains "$init" "skills/custom-build-rule/SKILL.md" "la tabla de generación instala custom-build-rule"
assert_contains "$init" "skills/custom-edit-rule/SKILL.md" "la tabla de generación instala custom-edit-rule"
assert_contains "$init" '`.claude/rules/.gitkeep`' "la tabla crea el dir instance-owned de reglas"
assert_contains "$init" "docs/rules.md.tmpl" "la tabla instala el contrato de reglas"
upd="$(cat "$ROOT/commands/harness-update.md")"
assert_contains "$upd" "Reglas-custom" "el update las declara como paquete atado"
assert_contains "$upd" "custom-edit-rule" "y las enumera entre las skills upstream"
assert_contains "$(cat "$ROOT/templates/docs/constitution.md.tmpl")" "## 7. Reglas custom" \
  "la constitución tiene la sección de punteros (es lo que las hace llegar a los agentes)"
assert_contains "$(cat "$ROOT/templates/docs/index.md.tmpl")" "harness/rules.md" \
  "el índice de docs enlaza el contrato"

echo "── el diente: qué hace el doctor con .claude/rules/*.md"

mkdir -p "$WS/.claude/rules" "$WS/.claude/pipeline" "$WS/semgrep"
doctor() { bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1; }

# (1) regla válida con verificador que EXISTE y ya ratificada: verde y sin ruido
printf -- '---\nafter: review\ngate: true\n---\n' > "$WS/.claude/pipeline/tracker-sync.md"
cat > "$WS/.claude/rules/proyecto-por-servicio.md" <<'EOF'
---
id: proyecto-por-servicio
applies_to: workspace
enforcement: pipeline-step
enforced_by: .claude/pipeline/tracker-sync.md
status: RATIFICADA
---
# Cada servicio del manifest tiene UN proyecto en el tracker
EOF
out="$(doctor)"
assert_contains "$out" "regla proyecto-por-servicio (pipeline-step" "regla con verificador presente: verde"
assert_not_contains "$out" "regla proyecto-por-servicio en DRAFT" "una regla RATIFICADA no molesta más"

# (2) el caso que motiva todo el check: el verificador NO existe
cat > "$WS/.claude/rules/bugs-como-beads.md" <<'EOF'
---
id: bugs-como-beads
applies_to: workspace
enforcement: gate
enforced_by: scripts/gate-fantasma.sh
status: DRAFT
---
# Todo bug detectado entra como bead en el proyecto del servicio
EOF
out="$(doctor)"
assert_contains "$out" "regla bugs-como-beads apunta a un verificador AUSENTE" \
  "una regla que promete diente sin tenerlo se caza"
assert_contains "$out" "baja la regla a enforcement: judgment" "y trae su remediación"
assert_contains "$out" "regla bugs-como-beads en DRAFT" "DRAFT avisa hasta que un humano ratifique"

# (3) enforcement automático sin enforced_by
printf -- '---\nid: sin-diente\nenforcement: hook\nstatus: DRAFT\n---\n# x\n' > "$WS/.claude/rules/sin-diente.md"
out="$(doctor)"
assert_contains "$out" "regla sin-diente declara enforcement: hook SIN enforced_by" \
  "declarar diente automático sin artefacto es rojo"

# (4) enforcement fuera de la lista cerrada
printf -- '---\nid: inventado\nenforcement: telepatia\nstatus: DRAFT\n---\n# x\n' > "$WS/.claude/rules/inventado.md"
out="$(doctor)"
assert_contains "$out" "enforcement inválido: telepatia" "la lista de dientes es cerrada"

# (5) el id tiene que ser el nombre del archivo (es lo que citan los agentes)
printf -- '---\nid: otro-nombre\nenforcement: judgment\nstatus: RATIFICADA\n---\n# x\n' > "$WS/.claude/rules/desalineada.md"
out="$(doctor)"
assert_contains "$out" "el id del frontmatter ('otro-nombre') no es el nombre del archivo" \
  "id y archivo no pueden divergir"

# (6) semgrep: el archivo existe pero la regla citada no está adentro
printf 'rules:\n  - id: otra-cosa\n' > "$WS/semgrep/rules.yaml"
cat > "$WS/.claude/rules/sin-semgrep.md" <<'EOF'
---
id: sin-semgrep
enforcement: semgrep
enforced_by: semgrep/rules.yaml:tenant-id-obligatorio
status: RATIFICADA
---
# x
EOF
out="$(doctor)"
assert_contains "$out" "no contiene la regla semgrep 'tenant-id-obligatorio'" \
  "no alcanza con que exista el archivo: la regla citada tiene que estar adentro"

# y con la regla presente, verde
printf 'rules:\n  - id: tenant-id-obligatorio\n' > "$WS/semgrep/rules.yaml"
out="$(doctor)"
assert_contains "$out" "regla sin-semgrep (semgrep" "con el rule-id presente, verde"

# (7) needs_mcp: mismo trato que en los pasos custom
cat > "$WS/.claude/rules/necesita-mcp.md" <<'EOF'
---
id: necesita-mcp
enforcement: judgment
needs_mcp: linear-server
status: RATIFICADA
---
# x
EOF
out="$(doctor)"
assert_contains "$out" "regla necesita-mcp declara needs_mcp 'linear-server' AUSENTE" \
  "una regla que asume un MCP inexistente se caza"
printf '{"mcpServers":{"linear-server":{"command":"x"}}}' > "$WS/.mcp.json"
out="$(doctor)"
assert_contains "$out" "regla necesita-mcp: MCP 'linear-server' presente" "con el MCP instalado, verde"

# (8) sin dir de reglas el doctor no inventa nada (una instancia recién nacida)
rm -rf "$WS/.claude/rules"
out="$(doctor)"
assert_not_contains "$out" "regla " "sin .claude/rules el doctor calla"

echo "── el contrato dice QUIÉN carga la regla, y qué difiere esa carga (#206)"

# Claude Code inyecta el cuerpo entero de cada regla en cada sesión. El contrato
# decía que lo que la hacía llegar era el puntero en la constitución, y de ahí
# salía la idea de que applies_to acotaba algo: no acota nada, y el costo se
# paga igual. `paths:` es el único campo que difiere la carga de verdad.
contrato="$(cat "$CONTRATO")"
assert_contains "$contrato" "paths:" "el contrato declara el campo nativo paths:"
assert_contains "$contrato" "cuerpo entero" "y dice que sin paths: entra el cuerpo entero"
assert_contains "$contrato" "NO difiere" "y desarma la ilusión de que applies_to acota la carga"

build="$(cat "$BUILD")"
assert_contains "$build" "paths:" "custom-build-rule emite paths: cuando el alcance no es el workspace"
assert_contains "$build" 'repos/<repo>/**' "con el mapeo concreto de applies_to a globs"

t_done
