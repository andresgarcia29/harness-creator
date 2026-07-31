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
assert_contains "$ship" "ship.sh implementa tres" "y dice qué implementa de verdad"
assert_contains "$ship" "trunk-merge-commit" "incluido el modo que aterriza con merge commit (#58)"
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

# {{MEMORY_TOOL}} era la peor version de esta misma perilla: vivia SOLO en el
# CLAUDE.md, la entrevista jamas lo preguntaba y nada lo sustituia, asi que
# toda instancia nacia con el placeholder literal y el agente leia "llama a
# {{MEMORY_TOOL}}", una instruccion sobre una herramienta sin nombre. El
# proveedor ya se pregunta y ya se estampa: no hace falta una segunda perilla.
assert_not_contains "$claude" "{{MEMORY_TOOL}}" \
  "el CLAUDE.md no nombra un placeholder que nadie alimenta"
assert_eq "0" "$(grep -rl "{{MEMORY_TOOL}}" "$root/templates" "$root/skills" "$root/commands" 2>/dev/null | grep -cv '^$')" \
  "y no quedo vivo en ningun otro template"
assert_contains "$claude" "{{MEMORY_PROVIDER}}" \
  "la memoria se nombra por el proveedor que el humano eligio"
skillmem="$(cat "$root/skills/harness-init/SKILL.md")"
assert_contains "$skillmem" "MEMORY_PROVIDER" \
  "y la entrevista sabe que esa respuesta viaja al CLAUDE.md"
assert_contains "$skillmem" "provider: none" \
  "con none, la entrevista manda BORRAR el bloque en vez de dejar una tool fantasma"

echo
echo "── metricas: recolectar sin que nadie lea es otra perilla muerta"
# collect corria en /archive y ahi moria: el jsonl crecia y ningun proceso lo
# miraba nunca. Una metrica que nadie lee no es telemetria, es basura con
# formato JSON. El ritual semanal es quien la lee, y quien escala upstream lo
# que resulta ser del harness y no de este workspace.
promote="$(cat "$root/templates/commands/promote.md.tmpl")"
assert_contains "$promote" "make metrics" "el ritual semanal LEE el informe"
assert_contains "$promote" "metrics-escalate" "y escala la friccion del harness upstream"
archive="$(cat "$root/templates/commands/archive.md.tmpl")"
assert_contains "$archive" "harness-metrics.py collect" "y /archive es quien la recolecta"
mk="$(cat "$root/templates/Makefile.tmpl")"
assert_contains "$mk" "metrics:" "con su target en el Makefile"
assert_contains "$mk" "metrics-escalate:" "y el de escalacion"

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
echo "── los techos del carril quick: si el policy los declara, alguien los mide"
# La perilla nueva del carril quick nace como DATO en policy.json (max_files,
# max_lines). Es la clase de perilla con más cara de garantía de todas: el
# humano lee "hasta 8 archivos" y cree que hay un tope, y /quick lo PROMETE en
# prosa. Un techo declarado que ningún gate compara es peor que no tener techo,
# porque el que confía en él manda a revisar menos.
pol_src="$(sed 's/{{LOOP_BUDGET}}/3/' "$root/templates/policy.json.tmpl")"
case "$pol_src" in
  *max_files*|*max_lines*)
    assert_contains "$(cat "$root/templates/scripts/harness-policy.py")" "lane-limits" \
      "el motor expone el lector de los techos (harness-policy.py es LA autoridad sobre el policy)"
    assert_contains "$(cat "$root/templates/scripts/ship.sh.tmpl")" "lane-limits" \
      "y gate_lane lo consume: el techo se mide contra el diff, no se archiva"
    assert_contains "$(cat "$root/templates/commands/quick.md.tmpl")" "lane-limits quick" \
      "y el playbook que hace la promesa manda a leerlos de ahí, no de una copia"
    assert_contains "$(cat "$root/templates/commands/quick.md.tmpl")" "escalate tasks/<id> --to express" \
      "con la remediación del techo excedido, que es lo que convierte el rojo en camino"
    ;;
  *)
    echo "  ! no pude mirar: policy.json.tmpl todavía no declara techos de carril"
    echo "    (max_files/max_lines); la aserción de que tienen lector queda SIN correr,"
    echo "    y esto NO es un verde: es que la perilla que verifica aún no existe."
    ;;
esac

echo
echo "── con PRs, archive no puede correr antes del merge"
am="$(cat "$root/templates/commands/archive.md.tmpl")"
assert_contains "$am" "landed" "archive exige que el cambio haya aterrizado"
assert_contains "$am" "spec rot" "y explica el costo de saltarselo"
dw="$(cat "$root/templates/scripts/deploy-watch.sh.tmpl")"
assert_contains "$dw" "if .landed == false" "deploy-watch no cae en el // de jq (false NO es ausente)"
assert_contains "$dw" "LANDED_SHA" "y el sha viaja por global: say() escribe a stdout"

t_done
