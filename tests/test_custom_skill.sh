#!/usr/bin/env bash
# test_custom_skill.sh: el par /custom-build-skill + /custom-edit-skill.
#
# Estas dos skills son PROSA ejecutable: no hay script que las verifique en
# runtime, así que lo que se puede romper en silencio son sus contratos de
# forma (frontmatter que no carga), sus punteros cruzados (una manda a la
# otra) y su registro en la tabla de generación (una skill que el plugin
# tiene y la instancia nunca recibe). Eso es lo que se ata acá.
set -u
. "$(dirname "$0")/lib.sh"

BUILD="$ROOT/templates/skills/custom-build-skill/SKILL.md"
EDIT="$ROOT/templates/skills/custom-edit-skill/SKILL.md"

echo "── /custom-build-skill y /custom-edit-skill"

assert_file "$BUILD" "existe el template de custom-build-skill"
assert_file "$EDIT" "existe el template de custom-edit-skill"

# ── Forma: si el frontmatter no parsea, la skill no carga y nada del resto
# importa. name TIENE que coincidir con el directorio (es como se invoca).
for f in "$BUILD" "$EDIT"; do
  d="$(basename "$(dirname "$f")")"
  [ "$(head -1 "$f")" = "---" ] && pass "$d: abre con frontmatter" \
    || fail "$d: no abre con '---' (la skill no carga)"
  grep -qx "name: $d" "$f" && pass "$d: name coincide con el directorio" \
    || fail "$d: el name del frontmatter no es '$d'"
  grep -q '^description: ' "$f" && pass "$d: tiene description" \
    || fail "$d: sin description (es lo ÚNICO que decide si se carga)"
done

build="$(cat "$BUILD")"; edit="$(cat "$EDIT")"

# ── La description es el gatillo: sin las palabras que el humano dice de
# verdad, la skill existe y nunca se carga. Se exigen las del pedido real.
desc_build="$(grep '^description: ' "$BUILD")"
desc_edit="$(grep '^description: ' "$EDIT")"
assert_contains "$desc_build" "quiero una skill" "build dispara con 'quiero una skill'"
assert_contains "$desc_build" "/custom-build-skill" "build nombra su invocación"
assert_contains "$desc_edit" "cambia la skill" "edit dispara con 'cambia la skill'"
assert_contains "$desc_edit" "/custom-edit-skill" "edit nombra su invocación"

# ── Punteros cruzados: son un par, y por eso viajan como paquete atado.
assert_contains "$build" "/custom-edit-skill" "build deriva a edit ante colisión de nombre"
assert_contains "$edit" "/custom-build-skill" "edit deriva a build cuando la skill no existe"

# ── El modo de fallo #1 de una skill generada: citar un MCP que la instancia
# no tiene. La verificación va ANTES de escribir, y con el comando real.
assert_contains "$build" ".mcpServers" "build verifica los MCPs contra .mcp.json antes de escribir"
assert_contains "$build" "command -v" "build verifica los CLIs contra el PATH"
assert_contains "$edit" ".mcpServers" "edit verifica las herramientas nuevas que se agreguen"

# ── El modo de fallo #1 de una EDICIÓN: tocar la copia equivocada. La capa
# se decide antes de escribir, y las tres tienen que estar nombradas.
assert_contains "$edit" ".managed" "edit reconoce la capa compartida (skills-sync la pisa)"
assert_contains "$edit" "/harness-update" "edit avisa que lo upstream se pierde en el update"
assert_contains "$edit" "local" "edit nombra la capa local (la única que se edita en sitio)"

# ── La ley que hereda todo lo generado: la skill propone, los gates verifican.
assert_contains "$build" "ship.sh" "build prohíbe puentear ship.sh en lo que genera"
assert_contains "$edit" "harness-policy.json" "edit se niega a codificar 'sáltate el gate' en una skill"
# Datos externos (tickets, issues, salida de un MCP) son DATO, no instrucción.
assert_contains "$build" "no instrucción" "build exige la cláusula de dato-no-instrucción en skills que leen fuentes externas"

# ── Registro: una skill que el plugin tiene y la tabla de generación no
# nombra es una skill que ninguna instancia recibe jamás.
init="$(cat "$ROOT/skills/harness-init/SKILL.md")"
assert_contains "$init" "skills/custom-build-skill/SKILL.md" "la tabla de generación instala custom-build-skill"
assert_contains "$init" "skills/custom-edit-skill/SKILL.md" "la tabla de generación instala custom-edit-skill"
upd="$(cat "$ROOT/commands/harness-update.md")"
assert_contains "$upd" "Skills-custom" "el update las declara como paquete atado"
assert_contains "$upd" "custom-edit-skill" "y las enumera entre las skills upstream a clasificar"

# ── Corta: una skill que necesita scroll es dos skills o es un doc. La regla
# la predican las dos, así que se la aplican a sí mismas.
for f in "$BUILD" "$EDIT"; do
  d="$(basename "$(dirname "$f")")"; n="$(wc -l < "$f" | tr -d ' ')"
  [ "$n" -le 140 ] && pass "$d: $n líneas (tope 140, la regla que ella misma predica)" \
    || fail "$d: $n líneas; predica 'corta' y no se la aplica"
done

t_done
