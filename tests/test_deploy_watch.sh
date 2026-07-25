#!/usr/bin/env bash
# test_deploy_watch.sh: el tramo de Kargo del watcher, contra el template real.
# Lo que se protege: un verificador que no puede correr NO se calla. Antes,
# kargo sin token dejaba un warning en el log, el deploy seguía por health de
# ArgoCD y nadie se enteraba de que la promoción nunca se miró. El silencio de
# un verificador ciego se lee igual que un verde.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/bin" "$WS/.harness"
cp "$ROOT/templates/scripts/emit.sh" "$WS/scripts/"

# El bloque de kargo del template, con el placeholder resuelto. Se extrae solo
# ese tramo: el resto del watcher habla con GitHub Actions y ArgoCD reales.
sed -e "s|{{KARGO_PROJECT}}|proyecto-demo|g" \
    "$ROOT/templates/scripts/deploy-watch.sh.tmpl" \
  | awk '/^# 2 · Kargo/{f=1} f{print} f&&/^fi$/{exit}' > "$WS/kargo.sh"
grep -q 'kargo_out' "$WS/kargo.sh" || { echo "no pude extraer el bloque de kargo"; exit 1; }

run_kargo() {  # run_kargo: corre el tramo con el stub de kargo que esté en $WS/bin
  ( set -uo pipefail
    export PATH="$WS/bin:$PATH" CLAUDE_PROJECT_DIR="$WS"
    cd "$WS"; REPO=videocore; LOG="$WS/deploy.log"
    say() { echo "$1" | tee -a "$LOG"; }
    . "$WS/scripts/emit.sh"
    . "$WS/kargo.sh" ) 2>&1
}

bus() { cat "$WS/.harness/events.jsonl" 2>/dev/null; }

echo "── kargo falla: el harness lo declara como supuesto, no lo entierra"

cat > "$WS/bin/kargo" <<'STUB'
#!/usr/bin/env bash
echo "Error: not authenticated: no token found" >&2
exit 1
STUB
chmod +x "$WS/bin/kargo"
: > "$WS/.harness/events.jsonl"

out="$(run_kargo)"
assert_contains "$out" "no token found" "muestra el MOTIVO real (antes se iba a \$LOG y no se veía)"
assert_contains "$out" "NO se verificó" "dice explícitamente que el tramo no se verificó"
assert_contains "$(bus)" '"kind":"assumption"' "emite un supuesto al ledger"
assert_contains "$(bus)" "Kargo NO verificada" "el supuesto nombra lo que quedó sin verificar"
assert_contains "$(bus)" "videocore" "el supuesto dice de qué repo"

echo
echo "── kargo responde: ni supuesto ni ruido"

cat > "$WS/bin/kargo" <<'STUB'
#!/usr/bin/env bash
echo "promotion-1  Succeeded"
STUB
chmod +x "$WS/bin/kargo"
: > "$WS/.harness/events.jsonl"

out="$(run_kargo)"
assert_contains "$out" "promotion-1" "el camino feliz sigue mostrando la promoción"
assert_not_contains "$(bus)" "assumption" "kargo en verde: NO emite supuesto"

echo
echo "── un repo que no despliega por GitOps no puede tener un deploy rojo"
# Bug de campo (P1): el primer repo de infra que cruzó el pipeline. deploy-watch
# construía APP=<prefijo><repo> y esperaba una app de ArgoCD que nunca iba a
# existir; el wait fallaba igual que si estuviera enferma, y de ahí salía una
# propuesta de revertir commits CORRECTOS. El manifest ya declaraba el kind.

sed -e "s|{{KARGO_PROJECT}}|p|g" -e "s|{{GITHUB_ORG}}|org|g" \
    -e "s|{{ARGO_APP_PREFIX}}|cvx-|g" -e "s|{{ROLLBACK_MODE}}|auto|g" \
    "$ROOT/templates/scripts/deploy-watch.sh.tmpl" > "$WS/scripts/deploy-watch.sh"

cat > "$WS/manifest.yaml" <<'YAML'
project: "demo"
repos:
#  - name: comentado
#    kind: service
  - name: terraform-core
    kind: infra-module
    agent: infra
  - name: atlas
    kind: service
    agent: svc-atlas
YAML

run_watch() {  # run_watch <repo>
  ( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" PATH="$WS/bin:$PATH" \
      bash scripts/deploy-watch.sh T1 "$1" ) 2>&1
}
: > "$WS/.harness/events.jsonl"
mkdir -p "$WS/tasks/T1"

out="$(run_watch terraform-core)"; rc=$?
assert_eq 0 "$rc" "repo de infra: sale 0 (no es un fallo, es que no aplica)"
assert_contains "$out" "kind=infra-module" "nombra el kind que leyó del manifest"
assert_contains "$out" "driver de deploy: none" "resuelve el driver y lo declara"
assert_contains "$out" "no se verifica con este watcher" "explica por qué no aplica"
assert_contains "$out" "driver: actions" "y dice cómo declararlo si SÍ despliega"
assert_contains "$out" "tampoco propongo revertir" "y dice explícitamente que no propone rollback"
assert_contains "$(bus)" '"kind":"assumption"' "declara el tramo no verificado como supuesto"
assert_not_contains "$out" "🔴" "NO reporta rojo"

# El repo de servicio sí entra al camino GitOps (y muere donde toque, no aquí).
: > "$WS/.harness/events.jsonl"
out="$(run_watch atlas)"
assert_contains "$out" "driver de deploy: gitops" "kind=service resuelve a gitops"

# Instancia vieja sin kind en el manifest: no se asume nada, sigue el flujo.
: > "$WS/.harness/events.jsonl"
printf 'repos:\n  - name: sinkind\n    agent: x\n' > "$WS/manifest.yaml"
out="$(run_watch sinkind)"
assert_contains "$out" "driver de deploy: gitops" "sin kind declarado: cae a gitops (compat), no a none"

echo
echo "── lo que el humano declara le gana a lo que el harness infiere"
cat > "$WS/harness-answers.yaml" <<'YAML'
project: demo
deploy:
  terraform-core:
    driver: actions
YAML
cat > "$WS/manifest.yaml" <<'YAML'
repos:
  - name: terraform-core
    kind: infra-module
YAML
out="$(run_watch terraform-core)"
assert_contains "$out" "driver de deploy: actions" "answers gana sobre el kind inferido"
assert_not_contains "$out" "no se verifica con este watcher" "y por lo tanto SÍ se verifica"

echo
echo "── el prefijo es un prefijo, no una concatenación ciega"
# Bug de campo P1: prefijo "acme" + repo "acme-landing" daba "acmeacme-landing",
# una app que no existe en ningún cluster. El watcher esperó 900 s por ella y
# propuso revertir un deploy que estaba SANO.
app_of() {  # app_of <prefijo> <repo> → el APP que construye el script
  sed -e "s|{{ARGO_APP_PREFIX}}|$1|g" "$ROOT/templates/scripts/deploy-watch.sh.tmpl" \
    | awk '/^app_name\(\)/{f=1} f{print} f&&/^\}/{exit}' > "$WS/app.sh"
  ( . "$WS/app.sh"; app_name "$2" )
}
assert_eq "acme-landing"  "$(app_of acme acme-landing)"  "repo que YA trae el prefijo: no se duplica"
assert_eq "acme-landing"  "$(app_of acme- acme-landing)" "prefijo con guion y repo que lo trae: tampoco"
assert_eq "acme-landing"  "$(app_of acme landing)"       "prefijo sin guion: lo agrega"
assert_eq "acme-landing"  "$(app_of acme- landing)"      "prefijo con guion: no lo duplica"
assert_eq "landing"       "$(app_of '' landing)"         "sin prefijo: el nombre del repo tal cual"

echo
echo "── sin credenciales de ArgoCD no se espera 900s ni se propone revertir"
: > "$WS/.harness/events.jsonl"
rm -f "$WS/harness-answers.yaml"
printf 'repos:\n  - name: atlas\n    kind: service\n' > "$WS/manifest.yaml"
cat > "$WS/bin/argocd" <<'STUB'
#!/usr/bin/env bash
sleep 900   # si el script llega hasta aquí, el bug sigue vivo
STUB
chmod +x "$WS/bin/argocd"
start=$(date +%s)
out="$( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" PATH="$WS/bin:$PATH" \
        HOME="$WS/nohome" ARGOCD_AUTH_TOKEN="" ARGOCD_URL="" \
        bash scripts/deploy-watch.sh T1 atlas 2>&1 )"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 30 ] && pass "no se cuelga esperando (tardó ${elapsed}s, no 900)" \
  || fail "esperó ${elapsed}s: sigue consultando sin credenciales"
assert_contains "$out" "sin credenciales" "dice que el problema son las credenciales"
assert_contains "$out" "ceguera, no un deploy rojo" "distingue ceguera de deploy enfermo"
assert_contains "$out" "with-secrets.sh" "da la remediación exacta"
# Ojo con el matcheo ingenuo: el propio mensaje dice "NO propongo revertir
# nada". Lo que no puede aparecer es la PROPUESTA destructiva concreta.
assert_not_contains "$out" "git revert" "NO propone el revert destructivo"
assert_not_contains "$out" "revert manual sugerido" "ni la variante manual"
assert_not_contains "$out" "🔴" "y no marca el deploy como rojo"
assert_contains "$(bus)" "ArgoCD sin credenciales" "queda como supuesto en el ledger"

t_done
