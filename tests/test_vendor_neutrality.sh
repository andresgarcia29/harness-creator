#!/usr/bin/env bash
# test_vendor_neutrality.sh: harness-creator es un instalador UNIVERSAL.
#
# El proyecto donde nació es solo el primero que lo usó. Dos formas de
# olvidarlo, y las dos ya pasaron:
#
#   1. Nombrar al cliente. Termina en el producto, y en un repo open source
#      además lo publica. El caso peor no es cosmético: `X-Corvux-Token` es
#      parte del contrato de API con el daemon, o sea que el nombre del
#      cliente quedó dentro del protocolo.
#   2. Cablear un vendor. Peor que lo anterior, porque no se ve. deploy-watch
#      asumía Kubernetes con ArgoCD y Kargo, así que al primer repo de
#      terraform que cruzó el pipeline le aplicó ese modelo y propuso
#      revertir commits CORRECTOS. Un instalador que asume el stack de quien
#      lo escribió no es universal, es su instalador personal con otro
#      nombre.
#
# Reglas 7 y 8 de CONTRIBUTING.md.
set -u
. "$(dirname "$0")/lib.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"

echo "── regla 7: ningún nombre de cliente en el producto"

# Cuando aparezca otro cliente, se agrega acá y su conteo empieza a bajar.
CLIENT_TOKENS="corvux"

# RATCHET, como el del guion largo: el conteo solo puede BAJAR. Se cuenta
# todo lo que se distribuye (templates, scripts, skills, catálogo, comandos),
# incluido el bundle vendorizado del panel: si viaja al usuario, cuenta.
count_client() {
  grep -roIE --exclude-dir=__pycache__ "$(printf '%s' "$CLIENT_TOKENS" | tr ' ' '|')" \
    "$root/templates" "$root/scripts" "$root/skills" \
    "$root/catalog" "$root/commands" 2>/dev/null | wc -l | tr -d ' '
}
CLIENT_MAX=12
now="$(count_client)"
if [ "$now" -le "$CLIENT_MAX" ]; then
  pass "ratchet de nombre de cliente: $now ≤ $CLIENT_MAX (solo baja)"
else
  fail "ratchet de nombre de cliente: $now > $CLIENT_MAX. Usa nombres neutros (acme, example-org)"
fi

# Lo que ya se limpió no puede volver. Estos archivos son la LÓGICA del
# instalador, no el panel vendorizado: aquí el conteo tiene que ser cero.
for f in scripts/discover.sh skills/harness-init/SKILL.md \
         templates/skills/pipeline-step-creator/SKILL.md; do
  if grep -qiE "$(printf '%s' "$CLIENT_TOKENS" | tr ' ' '|')" "$root/$f" 2>/dev/null; then
    fail "$f nombra a un cliente (regla 7): la lógica del instalador va en neutro"
  else
    pass "$f en neutro"
  fi
done

echo
echo "── regla 8: cada eje que varía tiene DRIVERS, no un vendor cableado"

# Un eje sin al menos dos implementaciones es un vendor disfrazado de
# soporte. La tabla es el contrato: agregar un eje aquí obliga a que exista
# su dispatch, y quitarlo exige justificarlo en el PR.
axis() {  # axis <nombre> <archivo> <patrón> <mínimo>
  local name="$1" file="$2" pat="$3" min="$4" n
  n="$(grep -oE "$pat" "$root/$file" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  if [ "$n" -ge "$min" ]; then
    pass "eje '$name': $n implementaciones (mínimo $min)"
  else
    fail "eje '$name': solo $n implementaciones en $file, mínimo $min. Un eje con una sola opción es un vendor cableado (regla 8)"
  fi
}

axis secretos        templates/scripts/secrets.sh.tmpl \
     'pull_[a-z_]+\(\)' 5
axis package-manager templates/scripts/fe.sh \
     'bun\.lock|pnpm-lock\.yaml|yarn\.lock|package-lock\.json' 4
axis lenguajes       templates/scripts/ship.sh.tmpl \
     'go\.mod|package\.json|pyproject\.toml|pubspec\.yaml' 4
axis modelos         templates/models.yaml.tmpl \
     '^models\.[a-z]+:' 3
axis deploy          templates/scripts/deploy-watch.sh.tmpl \
     'DRIVER=(gitops|actions|none)|"\$DRIVER" = "(gitops|actions|none)"' 2

echo
echo "── regla 8: el deploy no puede volver a asumir un solo modelo"

dw="$(cat "$root/templates/scripts/deploy-watch.sh.tmpl")"
assert_contains "$dw" "answers_driver" "el humano puede declarar el driver en answers"
assert_contains "$dw" "repo_kind" "y si no lo declaró, se infiere del kind del manifest"
assert_contains "$dw" '"$DRIVER" = "gitops"' "las etapas de Kubernetes están acotadas a su driver"
assert_contains "$dw" "driver=none" "un repo sin driver lo DICE en vez de inventar un rojo"
# El mensaje final no puede prometer verificaciones que ese driver no hizo.
assert_contains "$dw" "VERIFIED_PARTS" "el mensaje final se arma de los tramos REALMENTE observados"
assert_not_contains "$dw" 'emit deploy "$REPO verificado: actions + argocd + smoke en verde"' \
  "el mensaje final ya no afirma una lista fija de verificaciones"

t_done
