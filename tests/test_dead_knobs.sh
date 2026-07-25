#!/usr/bin/env bash
# test_dead_knobs.sh: una perilla que se pregunta tiene que hacer algo.
#
# Grupo P2 de la auditoría: cuatro opciones que la entrevista ofrecía, el
# answers registraba, y ningún código consumía. El humano decide, el harness
# archiva su decisión, y hace otra cosa. Es peor que no ofrecerlas: quien
# eligió "PRs" por política de su empresa recibía commits directos a main
# creyendo lo contrario.
set -u
. "$(dirname "$0")/lib.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"

answers="$(cat "$root/templates/harness-answers.yaml.tmpl")"

echo "── flow: quien elige PRs ya no recibe un push a main en silencio"
# ship.sh hacía `git push origin HEAD:main` incondicional y {{FLOW}} no tenía
# UN solo consumidor en todo el repo.
ship="$(cat "$root/templates/scripts/ship.sh.tmpl")"
assert_contains "$ship" 'FLOW="{{FLOW}}"' "ship.sh ahora lee el flujo configurado"
assert_contains "$ship" "solo implementa" "y dice qué implementa de verdad"
assert_contains "$ship" "a espaldas de una política" "y por qué se niega en vez de seguir"

# El guard tiene que dejar pasar trunk y frenar el resto. Se extrae el case.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
check_flow() {  # check_flow <valor> → 0 si deja pasar, 7 si frena
  sed -e "s|{{FLOW}}|$1|g" "$root/templates/scripts/ship.sh.tmpl" \
    | awk '/^FLOW=/{f=1} f{print} f&&/^esac$/{exit}' > "$tmp/flow.sh"
  ( set -u; . "$tmp/flow.sh" ) >/dev/null 2>&1; echo $?
}
assert_eq 0 "$(check_flow trunk)" "flow: trunk pasa (el camino que sí implementa)"
assert_eq 0 "$(check_flow trunk-direct-to-prod)" "su nombre largo también"
assert_eq 0 "$(check_flow "trunk direct-to-prod")" "y la grafía con espacios que usaba la entrevista"
assert_eq 0 "$(check_flow "{{FLOW}}")" "placeholder sin sustituir: se trata como trunk, no frena un ship"
assert_eq 7 "$(check_flow prs)" "flow: prs FRENA en vez de pushear a main"
assert_eq 7 "$(check_flow trunk-staging)" "flow: trunk-staging también frena"

echo
echo "── models.escalation: el placeholder tenía dos usos y ninguna fuente"
# models.yaml lo referencia en roles.escalation y cronjobs.expensive, pero la
# entrevista no lo preguntaba y el answers no lo registraba: quedaba literal y
# stamp-models resolve fallaba en runtime.
assert_contains "$answers" "escalation: {{MODEL_ESCALATION}}" "el answers ya tiene dónde guardarlo"
assert_contains "$(cat "$root/skills/harness-init/SKILL.md")" "alias de ESCALACIÓN" \
  "y la entrevista lo pregunta"
n="$(grep -c "{{MODEL_ESCALATION}}" "$root/templates/models.yaml.tmpl")"
assert_eq 2 "$n" "sigue usándose en sus dos lugares de models.yaml"

echo
echo "── memory.profiles: la respuesta dejaba de existir en el CLAUDE.md generado"
claude="$(cat "$root/templates/CLAUDE.md.tmpl")"
assert_contains "$claude" "{{MEMORY_PROFILES}}" "el CLAUDE.md usa la respuesta del humano"
assert_not_contains "$claude" "Solo perfiles orquestador" "y ya no hardcodea el default"

echo
echo "── tier de un MCP: la única perilla muerta con perfil de seguridad"
# El .mcp.json se genera del campo config del catálogo y nadie lee tier:. El
# humano creía que revocó escritura y el servidor seguía con capacidad plena.
skill="$(cat "$root/skills/harness-init/SKILL.md")"
assert_contains "$skill" "solo es real si la" "la entrevista deja de prometerlo a ciegas"
assert_contains "$skill" "alcance del TOKEN" "y dice cuál es la restricción de verdad"
assert_contains "$skill" "config_read_only" "y nombra el campo que lo haría real"
doc="$(cat "$root/scripts/doctor.sh")"
assert_contains "$doc" "tier read-only en answers" "el doctor nombra los degradados que no se aplican"
assert_contains "$doc" "Registrar la preferencia no revoca nada" "sin ambigüedad sobre qué significa"

echo
echo "── ci-doctor: el último falso verde del grupo P1"
ci="$(cat "$root/templates/cronjobs/jobs/ci-doctor.sh")"
assert_contains "$ci" "forge_ci_failed" "consulta el CI por la capa de forge, no con gh cableado"
assert_contains "$ci" "CI NO consultado en:" "los repos que no pudo consultar se nombran"
assert_contains "$ci" "no pude consultar el CI de NINGÚN repo" "y si no vio nada, no dice limpio"
assert_contains "$ci" "return 3" "devuelve saltado, no verde"

t_done
