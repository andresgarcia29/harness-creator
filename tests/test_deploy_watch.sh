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
assert_contains "$out" "no despliega por el camino GitOps" "explica por qué no aplica"
assert_contains "$out" "tampoco propongo revertir" "y dice explícitamente que no propone rollback"
assert_contains "$(bus)" '"kind":"assumption"' "declara el tramo no verificado como supuesto"
assert_not_contains "$out" "🔴" "NO reporta rojo"

# El repo de servicio sí entra al camino GitOps (y muere donde toque, no aquí).
: > "$WS/.harness/events.jsonl"
out="$(run_watch atlas)"
assert_not_contains "$out" "no despliega por el camino GitOps" "kind=service sí entra al camino GitOps"

# Instancia vieja sin kind en el manifest: no se asume nada, sigue el flujo.
: > "$WS/.harness/events.jsonl"
printf 'repos:\n  - name: sinkind\n    agent: x\n' > "$WS/manifest.yaml"
out="$(run_watch sinkind)"
assert_not_contains "$out" "no despliega por el camino GitOps" "sin kind declarado: no asume, deja decidir al guard de la app"

t_done
