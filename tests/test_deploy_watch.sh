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

t_done
