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
assert_contains "$out" "no pude verificar el health" "dice que no pudo verificar"
assert_contains "$out" "CEGUERA, no un deploy rojo" "distingue ceguera de deploy enfermo"
assert_contains "$out" "with-secrets.sh" "da la remediación exacta"
# Ojo con el matcheo ingenuo: el propio mensaje dice "NO propongo revertir
# nada". Lo que no puede aparecer es la PROPUESTA destructiva concreta.
assert_not_contains "$out" "git revert" "NO propone el revert destructivo"
assert_not_contains "$out" "revert manual sugerido" "ni la variante manual"
assert_not_contains "$out" "🔴" "y no marca el deploy como rojo"
assert_contains "$(bus)" "NO verificado" "queda como supuesto en el ledger"

echo
echo "── el sha a revertir es el de ESTE repo, no la última línea del log"
# Bug P0: tail -1 sin filtrar. En tarea multi-repo que shippeó A y luego B,
# el watch de A proponía revertir el sha de B DENTRO de repos/A.
rev_sha() {  # rev_sha <repo>: el sha que el script elegiría para revertir
  ( REPO="$1"; WS="$WS"; TASK=T1
    jq -r --arg r "$REPO" 'select(.repo == $r) | .sha // empty' \
      "$WS/tasks/T1/ship.log" 2>/dev/null | tail -1 )
}
mkdir -p "$WS/tasks/T1"
cat > "$WS/tasks/T1/ship.log" <<'JSONL'
{"repo":"design-system","sha":"aaa1111","shipped_at":"2026-07-25T00:00:00Z"}
{"repo":"videocore","sha":"bbb2222","shipped_at":"2026-07-25T00:01:00Z"}
JSONL
assert_eq "aaa1111" "$(rev_sha design-system)" "el repo shippeado primero recupera SU sha"
assert_eq "bbb2222" "$(rev_sha videocore)" "y el segundo el suyo"
assert_eq "" "$(rev_sha inexistente)" "un repo sin ship no devuelve el sha de otro"

# Sin sha no se propone una acción destructiva a ciegas.
dw="$(cat "$ROOT/templates/scripts/deploy-watch.sh.tmpl")"
assert_contains "$dw" 'NO sé qué revertir' "sin sha: lo dice en vez de sugerir un revert vacío"

echo
echo "── issue #28: el nombre de la app se RESUELVE contra el cluster"
# Medido en un cluster real de 17 apps: el nombre coincide con el del repo en
# 16, y el prefijo configurado no acertaba en NINGUNO. `argocd app wait`
# esperaba 900 s por una app inexistente y de ahí salía la propuesta de
# revertir un deploy sano.
mkdir -p "$WS/bin" "$WS/tasks/T1"
sed -e "s|{{KARGO_PROJECT}}|p|g" -e "s|{{GITHUB_ORG}}|org|g" \
    -e "s|{{ARGO_APP_PREFIX}}|harness-workspace|g" -e "s|{{ROLLBACK_MODE}}|auto|g" \
    "$ROOT/templates/scripts/deploy-watch.sh.tmpl" > "$WS/scripts/dw28.sh"
printf 'repos:\n  - name: corvux-end-to-end\n    kind: service\n' > "$WS/manifest.yaml"

cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get applications"*) printf 'atlas https://github.com/org/atlas.git\ne2e https://github.com/org/corvux-end-to-end.git\n' ;;
  *"get application e2e"*) printf 'Synced Healthy' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WS/bin/kubectl"
: > "$WS/.harness/events.jsonl"
out="$( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" PATH="$WS/bin:$PATH" \
        bash scripts/dw28.sh T1 corvux-end-to-end 2>&1 )"
assert_contains "$out" "verificando e2e" "resuelve el nombre real del cluster, no el prefijo compuesto"
assert_not_contains "$out" "harness-workspace-corvux" "y NO usa la concatenación que no existe en ningún cluster"
assert_contains "$out" "sync=Synced health=Healthy" "reporta el estado observado, con sus valores"
assert_contains "$out" "✅ e2e Healthy" "y lo declara sano"

echo
echo "── issue #28: el fallo del verificador no acusa al deploy"
# El CLI de argocd instalado pero SIN servidor falla en milisegundos con
# "server address unspecified", y el script lo reportaba como "no llegó a
# Healthy+Synced en 900s": falso dos veces, porque ni esperó ni supo nada.
rm -f "$WS/bin/kubectl"
printf '#!/usr/bin/env bash\necho "{\\"level\\":\\"fatal\\",\\"msg\\":\\"Argo CD server address unspecified\\"}" >&2\nexit 1\n' > "$WS/bin/argocd"
chmod +x "$WS/bin/argocd"
: > "$WS/.harness/events.jsonl"
out="$( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" PATH="$WS/bin:/usr/bin:/bin" \
        env -u ARGOCD_AUTH_TOKEN -u ARGOCD_URL bash scripts/dw28.sh T1 corvux-end-to-end 2>&1 )"
assert_contains "$out" "no pude verificar el health" "verificador ciego: lo dice"
assert_contains "$out" "CEGUERA, no un deploy rojo" "y lo distingue de un deploy roto"
assert_not_contains "$out" "🔴" "no marca rojo lo que no observó"
assert_not_contains "$out" "git revert" "y no propone revertir un deploy sano"
assert_contains "$(bus)" "NO verificado" "queda como supuesto en el ledger"

echo
echo "── y el mensaje final no promete lo que no verificó"
# Bug encontrado probando el arreglo de este issue: con argocd inconcluso y
# sin smoke, el cierre igual decía "verificado: actions + argocd + smoke".
assert_contains "$out" "SIN VERIFICAR: ningún tramo se pudo observar" \
  "sin nada observable, no se declara verde"
assert_not_contains "$out" "actions + argocd + smoke" \
  "el cierre ya no recita una lista fija por driver"


echo
echo "── el sha a vigilar sale de ship.log (antes: \$WT sin definir = ceguera total)"
# Bug de origen: el script usaba `git -C "$WT" rev-parse HEAD` y $WT nunca se
# definía. Con set -u la sustitución moría entera, head_sha quedaba vacío, y
# como las ramas siguientes exigían [ -n "$head_sha" ], la etapa de Actions se
# saltaba sin vigilar NI avisar. Con driver=actions el deploy nunca se verificó.
extract_fn() { awk "/^$1\(\) \{/{f=1} f{print} f&&/^\}/{exit}" \
  "$ROOT/templates/scripts/deploy-watch.sh.tmpl"; }

# Solo CÓDIGO: el comentario que documenta el bug sí nombra $WT, y debe poder
# hacerlo sin que el test lo confunda con una regresión.
grep -v '^[[:space:]]*#' "$ROOT/templates/scripts/deploy-watch.sh.tmpl" \
  | grep -q 'git -C "$WT"' \
  && fail "sigue usando \$WT en código, y esa variable nunca se define" \
  || pass "ya no depende de \$WT (la variable fantasma que causaba la ceguera)"

extract_fn shipped_sha > "$WS/shipped.sh"
mkdir -p "$WS/tasks/T7"
printf '%s\n' \
  '{"repo":"otro","sha":"1111111111111111111111111111111111111111"}' \
  '{"repo":"videocore","sha":"2222222222222222222222222222222222222222"}' \
  > "$WS/tasks/T7/ship.log"
got="$( WS="$WS" TASK=T7 REPO=videocore; . "$WS/shipped.sh"; shipped_sha )"
assert_eq "2222222222222222222222222222222222222222" "$got" \
  "toma el sha de ESTE repo, no la última línea del log"
got="$( WS="$WS" TASK=T7 REPO=inexistente; . "$WS/shipped.sh"; shipped_sha )"
assert_eq "" "$got" "repo sin ship: devuelve vacío (y el watcher lo declara)"

# El sha completo importa: la API del forge devuelve headSha completo, así que
# con el sha corto de antes la comparación no matcheaba nunca.
grep -q 'startswith' "$ROOT/templates/scripts/deploy-watch.sh.tmpl" \
  && pass "compara por prefijo (tolera los ship.log viejos con sha corto)" \
  || fail "comparación exacta: los ship.log con sha corto nunca matchearían"
grep -q 'branch "\$BASE_REF"' "$ROOT/templates/scripts/deploy-watch.sh.tmpl" \
  && pass "la rama del run sale de origin/HEAD, no cableada a main" \
  || fail "sigue cableando --branch main"

echo
echo "── rollback en trunk compartido: no revertir por el rojo de otro"
extract_fn rollback_advice > "$WS/rb.sh"
mkdir -p "$WS/repos/videocore"
git init -q -b main "$WS/repos/videocore"
( cd "$WS/repos/videocore"; git config user.email t@t; git config user.name t
  echo a > f.txt; git add -A; git commit -qm base
  echo b > f.txt; git add -A; git commit -qm mio
  git update-ref refs/remotes/origin/main HEAD )
MINE="$( cd "$WS/repos/videocore" && git rev-parse HEAD )"

run_rb() {  # run_rb <observed-revision> <sha>
  ( set -u; WS="$WS"; REPO=videocore; TASK=T7; BASE_REF=main
    ROLLBACK_MODE=auto; OBSERVED_REVISION="$1"
    LOG="$WS/rb.log"; say() { echo "$1"; }; emit() { :; }
    . "$WS/rb.sh"; rollback_advice "$2" ) 2>&1
}

out="$(run_rb "9999999999999999999999999999999999999999" "$MINE")"
assert_contains "$out" "NO propongo revertir nada mío" \
  "revisión enferma AJENA: no propone revertir lo propio"
assert_contains "$out" "workspace aterrizó después" "y dice por qué"

out="$(run_rb "$MINE" "$MINE")"
assert_contains "$out" "revert en git de $MINE" "revisión enferma PROPIA: sí propone el revert"

out="$(run_rb "" "$MINE")"
assert_contains "$out" "revert en git de $MINE" "sin revisión observable: se comporta como antes"

# alguien construyó ENCIMA: el revert deja de ser puntual
( cd "$WS/repos/videocore"; echo c > f.txt; git add -A; git commit -qm "de otro, encima"
  git update-ref refs/remotes/origin/main HEAD )
out="$(run_rb "" "$MINE")"
assert_contains "$out" "PARO" "revert que conflictúa con lo de encima: para en vez de proponerlo"
assert_contains "$out" "rompería el trabajo de alguien más" "y nombra el riesgo real"
[ -z "$( cd "$WS/repos/videocore" && git status --porcelain )" ] \
  && pass "el ensayo en seco deja el repo limpio" || fail "el ensayo dejó basura en el repo"

t_done
