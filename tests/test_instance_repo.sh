#!/usr/bin/env bash
# test_instance_repo.sh: quién es el repo de la INSTANCIA, en un solo lugar.
#
# POR QUÉ IMPORTA que esto sea UNA función y no tres lecturas: el repo de la
# instancia es el único del workspace sin `repos/<repo>` ni worktree, y cuatro
# artefactos del pipeline tienen que reconocerlo para no exigirle algo que por
# construcción no puede tener. Con la respuesta repartida, dos de ellos discrepan
# y la tarea queda sin veredicto o clavada en `review` con el cambio ya en main.
set -u
. "$(dirname "$0")/lib.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"
t_ws

mkdir -p "$WS/scripts"
cp "$root/templates/scripts/instance-repo.sh" "$WS/scripts/"

pregunta() {  # pregunta <repo-a-preguntar> → "<slug>|<es-instancia?>"
  ( set -u; WS="$WS"; . "$WS/scripts/instance-repo.sh"
    if es_repo_de_la_instancia "$1"; then printf '%s|si' "$(instance_repo_slug)"
    else printf '%s|no' "$(instance_repo_slug)"; fi )
}

echo "── una url completa: el nombre es el último tramo, sin .git"
cat > "$WS/harness-answers.yaml" <<'YAML'
project: demo
instance:
  repo: git@github.com:acme/workspace.git

flow: trunk
YAML
assert_eq "workspace|si" "$(pregunta workspace)" "reconoce el repo de la instancia por su nombre"
assert_eq "workspace|no" "$(pregunta atlas)"     "y NO confunde a un repo de producto"

echo
echo "── un slug pelado también, con comillas o sin ellas"
printf 'instance:\n  repo: "mi-workspace"\n' > "$WS/harness-answers.yaml"
assert_eq "mi-workspace|si" "$(pregunta mi-workspace)" "entre comillas"
printf 'instance:\n  repo: mi-workspace   # el repo de la config\n' > "$WS/harness-answers.yaml"
assert_eq "mi-workspace|si" "$(pregunta mi-workspace)" "y con comentario al final de la línea"

echo
echo "── NO se lee el repo de otra sección (un parser de YAML de a de veras no hay)"
cat > "$WS/harness-answers.yaml" <<'YAML'
instance:
  repo: workspace
deploy:
  atlas:
    repo: no-soy-la-instancia
YAML
assert_eq "workspace|si" "$(pregunta workspace)" "se queda con el del bloque instance:"
assert_eq "workspace|no" "$(pregunta no-soy-la-instancia)" "y el de deploy: no cuenta"

echo
echo "── lo que NO se puede contestar, no se inventa"
printf 'instance:\n  repo: {{INSTANCE_REPO}}\n' > "$WS/harness-answers.yaml"
assert_eq "|no" "$(pregunta workspace)" "un placeholder sin sustituir no es un nombre"
rm -f "$WS/harness-answers.yaml"
assert_eq "|no" "$(pregunta workspace)" "sin answers no hay respuesta (y no revienta)"
printf 'flow: trunk\n' > "$WS/harness-answers.yaml"
assert_eq "|no" "$(pregunta workspace)" "sin bloque instance: tampoco"
assert_eq "|no" "$(pregunta '')" "y un repo vacío jamás es la instancia"

echo
echo "── los DOS consumidores lo sourcean del mismo archivo"
# Si uno se hiciera su propia copia, esto lo caza: es exactamente la divergencia
# que deja a un gate aceptando lo que el otro rechaza.
for f in verdict-scaffold.sh instance-ship.sh; do
  assert_contains "$(cat "$root/templates/scripts/$f")" 'scripts/instance-repo.sh' \
    "$f sourcea el helper compartido"
done

t_done
