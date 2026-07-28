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
assert_contains "$ship" "ship.sh implementa dos" "y dice qué implementa de verdad"
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
# `prs` dejo de frenar porque dejo de ser una perilla muerta: ahora publica la
# rama y abre el PR. Lo que NO puede pasar nunca es que empuje a la trunk.
assert_eq 0 "$(check_flow prs)" "flow: prs ya no frena: esta implementado"
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
echo "── flow: prs dejo de ser una perilla que solo sabe negarse"
sh="$(cat "$root/templates/scripts/ship.sh.tmpl")"
assert_contains "$sh" "FLOW_MODE=prs" "ship.sh reconoce el flujo de PRs"
assert_contains "$sh" "refs/heads/\$branch" "publica la RAMA, no la trunk"
assert_contains "$sh" "force-with-lease" "y si el rebase la movio, no pisa trabajo ajeno"
assert_contains "$sh" '"landed":false' "ship.log declara que el cambio NO aterrizo"
assert_not_contains "$sh" 'flow a .trunk. si eso es lo que quer' "ya no manda a cambiar la perilla"
fg="$(cat "$root/templates/scripts/forge.sh")"
assert_contains "$fg" "forge_pr_url" "la capa de forge sabe si ya hay PR (el rework re-usa la rama)"
assert_contains "$fg" "forge_pr_merged" "y si mergeo, para resolver el commit real"

echo
echo "── la fase la registra el push, no el prompt"
assert_contains "$sh" "request_ship_phase" "ship.sh pide la transicion el mismo"
assert_contains "$sh" "el push YA ocurrio" "y es fail-open: la contabilidad no puede tumbar un push hecho"
sm="$(cat "$root/templates/commands/ship.md.tmpl")"
assert_contains "$sm" "ya la registró" "el prompt deja de pedirla (era la que se olvidaba)"
pol="$(cat "$root/templates/scripts/harness-policy.py")"
assert_contains "$pol" "emit_bus" "y cada movimiento de fase se ve en el panel"

echo
echo "── las perillas nuevas de answers tienen consumidor (no nacen muertas)"
pf="$(cat "$root/templates/scripts/port-forwards.sh")"
assert_contains "$pf" "port_forwards:" "port-forwards.sh consume el bloque port_forwards"
mk="$(cat "$root/templates/Makefile.tmpl")"
assert_contains "$mk" "port-forwards.sh ensure" "y make forwards lo invoca"
assert_contains "$(cat "$root/scripts/doctor.sh")" "port_forwards" "y el doctor lo vigila"
dwv="$(cat "$root/templates/scripts/deploy-watch.sh.tmpl")"
assert_contains "$dwv" "verify_cmd" "deploy-watch consume verify_cmd del bloque deploy"
assert_contains "$dwv" "verify_expect" "y verify_expect"
assert_contains "$(cat "$root/templates/scripts/ship-wave.sh")" "post_ship" "ship-wave consume post_ship"
answ="$(cat "$root/templates/harness-answers.yaml.tmpl")"
assert_contains "$answ" "post_ship" "y las tres claves están documentadas en el answers"
assert_contains "$answ" "port_forwards:" "incluido el bloque de forwards"

echo
echo "── con PRs, archive no puede correr antes del merge"
am="$(cat "$root/templates/commands/archive.md.tmpl")"
assert_contains "$am" "landed" "archive exige que el cambio haya aterrizado"
assert_contains "$am" "spec rot" "y explica el costo de saltarselo"
dw="$(cat "$root/templates/scripts/deploy-watch.sh.tmpl")"
assert_contains "$dw" "if .landed == false" "deploy-watch no cae en el // de jq (false NO es ausente)"
assert_contains "$dw" "LANDED_SHA" "y el sha viaja por global: say() escribe a stdout"

t_done
