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
# Cada llamada de red del watcher va por run_bounded, asi que los tramos que se
# extraen del template lo necesitan definido igual que en el script completo.
# Se copia el template REAL: una imitacion en el test probaria la imitacion.
cp "$ROOT/templates/scripts/bounded.sh" "$WS/scripts/"
acota() {  # lo que todo tramo extraido necesita del preambulo del watcher
  . "$WS/scripts/bounded.sh"
  CALL_TIMEOUT=10; CALL_GRACE=2
}

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
    acota
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

# DOS repos en el bloque deploy: el parser tiene que resetear el repo actual
# al ver la clave del siguiente. Con el intervalo ERE {2} (que el awk BSD no
# habilita sin --re-interval) la regla de reset no matcheaba nunca y el
# driver del segundo repo se leía como si fuera del primero.
cat > "$WS/harness-answers.yaml" <<'YAML'
project: demo
deploy:
  atlas:
    memo: sin-driver-declarado
  terraform-core:
    driver: actions
YAML
cat > "$WS/manifest.yaml" <<'YAML'
repos:
  - name: atlas
    kind: service
  - name: terraform-core
    kind: infra-module
YAML
out="$(run_watch atlas)"
assert_contains "$out" "driver de deploy: gitops" \
  "el driver de terraform-core NO se le atribuye a atlas (reset del parser, awk BSD)"
out="$(run_watch terraform-core)"
assert_contains "$out" "driver de deploy: actions" "y terraform-core conserva el suyo"

echo
echo "── un verificador ausente se DICE (el silencio se lee igual que un verde)"
# Caso de campo: "deploy-watch salió 0 con salida vacía", y beads de verde
# falso cuando no autentica. Dos capas: los saltos por CLI ausente ahora
# hablan, y un trap garantiza que el script JAMÁS salga sin una línea.

: > "$WS/.harness/events.jsonl"
printf 'project: demo\ndeploy:\n  atlas:\n    driver: gitops\n' > "$WS/harness-answers.yaml"
printf 'repos:\n  - name: atlas\n    kind: service\n' > "$WS/manifest.yaml"
out="$( ( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" PATH="$WS/bin:$(t_path_without gh)" \
    bash scripts/deploy-watch.sh T1 atlas ) 2>&1 )" || true
assert_contains "$out" "gh no está instalado" "gh ausente: la etapa de Actions lo DICE"
assert_contains "$out" "no sé nada" "y no se disfraza de verde"
assert_contains "$(bus)" "gh no está instalado" "y queda como supuesto en el bus"
mv "$WS/bin/kargo" "$WS/bin/kargo.off"
out="$( ( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" PATH="$WS/bin:$(t_path_without kargo)" \
    bash scripts/deploy-watch.sh T1 atlas ) 2>&1 )" || true
mv "$WS/bin/kargo.off" "$WS/bin/kargo"
assert_contains "$out" "kargo CLI no está" "kargo ausente: también se dice (una línea, sin supuesto)"

# el cinturón estructural: el template garantiza salida no-muda por trap
dwt="$(cat "$ROOT/templates/scripts/deploy-watch.sh.tmpl")"
assert_contains "$dwt" "trap mute_guard EXIT" "existe el guard de salida muda"
assert_contains "$dwt" "SIN haber dicho una palabra" "y su mensaje nombra el bug con el contexto"
assert_contains "$dwt" 'SAID=1' "say alimenta el guard (toda línea cuenta como habla)"
assert_contains "$dwt" 'ETAPA="${1#── }"' "y ademas registra la etapa, para que el watchdog pueda decir donde murio"

echo
echo "── verify declarado por repo: corre para TODOS los drivers, incluido none"
# Caso de campo: un infra-live con driver none se verificó a mano dos veces,
# las dos con errores (grep de un literal generado por template; curl sin
# --compressed que calla). El verify declarado es la señal que faltaba.

cat > "$WS/manifest.yaml" <<'YAML'
repos:
  - name: agora
    kind: infra-live
YAML
mk_answers_verify() {  # mk_answers_verify <verify_cmd> [expect] [timeout]
  { echo "project: demo"
    echo "deploy:"
    echo "  agora:"
    echo "    driver: none"
    echo "    verify_cmd: \"$1\""
    [ -n "${2:-}" ] && echo "    verify_expect: \"$2\""
    [ -n "${3:-}" ] && echo "    verify_timeout: $3"; } > "$WS/harness-answers.yaml"
}
printf '#!/bin/sh\necho "hola data-testid=checkout gzip-ok"\n' > "$WS/bin/fake-verify"
chmod +x "$WS/bin/fake-verify"

# 1. driver none + verify: YA NO sale por "no se verifica con este watcher"
: > "$WS/.harness/events.jsonl"
mk_answers_verify "fake-verify" "data-testid=checkout"
out="$(run_watch agora)"; rc=$?
assert_eq 0 "$rc" "none + verify verde: exit 0"
assert_not_contains "$out" "no se verifica con este watcher" "none con verify SÍ verifica"
assert_contains "$out" "verify verde" "y lo declara"
assert_contains "$out" "verify declarado" "el tramo entra a VERIFIED_PARTS"
assert_contains "$out" "🟢" "el cierre es verde de verdad"

# 2. mismatch del substring esperado: rojo con la causa
: > "$WS/.harness/events.jsonl"
mk_answers_verify "fake-verify" "texto-que-no-esta"
out="$(run_watch agora)"; rc=$?
[ "$rc" -ne 0 ] && pass "verify sin el substring: exit != 0" || fail "mismatch salió verde"
assert_contains "$out" "NO contiene" "nombra la causa exacta"

# 3. timeout: el comando colgado no cuelga al watcher
: > "$WS/.harness/events.jsonl"
printf '#!/bin/sh\nsleep 5\n' > "$WS/bin/fake-verify"
chmod +x "$WS/bin/fake-verify"
mk_answers_verify "fake-verify" "" 1
out="$(run_watch agora)"; rc=$?
[ "$rc" -ne 0 ] && pass "verify que excede el timeout: exit != 0" || fail "el timeout no cortó"
assert_contains "$out" "excedió" "y lo dice"

# 4. none pelado (sin verify ni smoke): el comportamiento honesto de siempre
: > "$WS/.harness/events.jsonl"
printf 'project: demo\ndeploy:\n  agora:\n    driver: none\n' > "$WS/harness-answers.yaml"
out="$(run_watch agora)"; rc=$?
assert_eq 0 "$rc" "none pelado: exit 0 (no aplica, no es fallo)"
assert_contains "$out" "no se verifica con este watcher" "y lo dice como siempre"

# 5. el smoke corre AHORA para driver actions (vivía dentro del if gitops)
: > "$WS/.harness/events.jsonl"
printf 'project: demo\ndeploy:\n  agora:\n    driver: actions\n' > "$WS/harness-answers.yaml"
mkdir -p "$WS/scripts/smoke"
printf '#!/bin/sh\necho smoke-corrio\nexit 0\n' > "$WS/scripts/smoke/agora.sh"
chmod +x "$WS/scripts/smoke/agora.sh"
out="$( ( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" PATH="$WS/bin:$(t_path_without gh)" \
    bash scripts/deploy-watch.sh T1 agora ) 2>&1 )"; rc=$?
assert_contains "$out" "smoke verde" "driver actions: el smoke SÍ corre (antes jamás)"
assert_contains "$out" "smoke del canary" "y entra a VERIFIED_PARTS"
rm -rf "$WS/scripts/smoke"

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
# El caso LITERAL de COR-242, clavado con nombre y apellido: prefijo "corvux"
# + repo "corvux-landing" daba "corvuxcorvux-landing", una app que no existe en
# ningun cluster. El watcher se comio 900s esperandola y propuso revertir un
# deploy que SI habia funcionado. Se fija el literal y no solo el patron
# generico: una regresion que solo rompa este par tiene que morder igual.
assert_eq "corvux-landing" "$(app_of corvux corvux-landing)" \
  "COR-242 literal: corvux + corvux-landing NO da corvuxcorvux-landing"
assert_not_contains "$(app_of corvux corvux-landing)" "corvuxcorvux" \
  "y la concatenacion ciega no vuelve a entrar por ninguna puerta"

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
# rollback_advice consulta revision_contiene_ship (#73): el helper viaja con el
# bloque, igual que en el camino verde.
{ extract_fn revision_contiene_ship; extract_fn rollback_advice; } > "$WS/rb.sh"
mkdir -p "$WS/repos/videocore"
git init -q -b main "$WS/repos/videocore"
( cd "$WS/repos/videocore"; git config user.email t@t; git config user.name t
  echo a > f.txt; git add -A; git commit -qm base
  echo b > f.txt; git add -A; git commit -qm mio
  git update-ref refs/remotes/origin/main HEAD )
MINE="$( cd "$WS/repos/videocore" && git rev-parse HEAD )"
# Una revision AJENA de verdad: existe en el repo y NO desciende de MINE. Antes
# este test usaba un sha inventado (999...9) y afirmaba que el watcher lo
# declaraba "ajeno": eso era el bug del #73, no la conducta deseada. Con el
# objeto ausente no se PUEDE saber si contiene el ship, y decir "otro aterrizo
# despues" era inventar un culpable. El caso indecidible tiene su propio test
# mas abajo, con el mensaje honesto.
AJENA="$( cd "$WS/repos/videocore" \
  && git commit-tree "$(git rev-parse HEAD~1^{tree})" -p "$(git rev-parse HEAD~1)" -m "de otro" )"

run_rb() {  # run_rb <observed-revision> <sha>
  ( set -u; WS="$WS"; REPO=videocore; TASK=T7; BASE_REF=main
    ROLLBACK_MODE=auto; OBSERVED_REVISION="$1"
    LOG="$WS/rb.log"; say() { echo "$1"; }; emit() { :; }
    acota
    . "$WS/rb.sh"; rollback_advice "$2" ) 2>&1
}

out="$(run_rb "$AJENA" "$MINE")"
assert_contains "$out" "NO propongo revertir nada mío" \
  "revisión enferma AJENA: no propone revertir lo propio"
assert_contains "$out" "workspace aterrizó después" "y dice por qué"

# Y el sha que NO existe en el clon: se declina igual (no se toca produccion a
# ciegas) pero el motivo es el verdadero, no un culpable inventado.
out="$(run_rb "9999999999999999999999999999999999999999" "$MINE")"
assert_contains "$out" "NO pude establecer" "revisión que ni existe: dice que no pudo decidir"
assert_not_contains "$out" "workspace aterrizó después" "sin atribuirsela a nadie"

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

echo
echo "── el ensayo del revert va contra el main REAL, no contra el clon stale"
# Encontrado corriendo deploy-watch de verdad: el ensayo se hacia en el clon
# canonico y sobre su HEAD. Ese clon esta atrasado casi siempre (solo se
# refresca con pull-all.sh o al crear un worktree), asi que el commit a revertir
# ni era ancestro suyo y `git revert` fallaba SIEMPRE: el watcher decia
# "conflictua con lo que aterrizo despues" aunque nadie hubiera tocado nada, y
# el camino de rollback quedaba inservible. Medido: clon en eb17f9d, main en
# f2a105e. Ademas limpiaba con `reset --hard` sobre ese clon COMPARTIDO.
mkdir -p "$WS/repos/stale"
git init -q -b main "$WS/repos/stale"
( cd "$WS/repos/stale"; git config user.email t@t; git config user.name t
  echo base > f.txt; git add -A; git commit -qm base
  printf 'linea1\nlinea2\n' > g.txt; git add -A; git commit -qm mio
  git update-ref refs/remotes/origin/main HEAD )
MINE_S="$( cd "$WS/repos/stale" && git rev-parse HEAD )"
# OTRO toca LAS MISMAS lineas y aterriza; el clon se queda atras
( cd "$WS/repos/stale"
  printf 'linea1\nMODIFICADA por otro\n' > g.txt; git add -A; git commit -qm "de otro, misma linea"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q "$MINE_S~1" )
stale_head="$( cd "$WS/repos/stale" && git rev-parse HEAD )"

# Contra el main REAL el revert conflictua (otro reescribio esas lineas), asi
# que hay que PARAR. Contra el clon stale el revert "funciona" y se propondria
# una accion destructiva sobre produccion que en main no aplica: es un FALSO OK,
# peor que un falso conflicto.
out="$( set -u; WS="$WS"; REPO=stale; TASK=T7; BASE_REF=main
        ROLLBACK_MODE=manual; OBSERVED_REVISION=""
        LOG="$WS/rb2.log"; say() { echo "$1"; }; emit() { :; }
        acota
        . "$WS/rb.sh"; rollback_advice "$MINE_S" 2>&1 )"
assert_contains "$out" "PARO" "ensayo contra el main REAL: detecta el conflicto y para"
assert_not_contains "$out" "revert manual sugerido" \
  "y NO propone una accion destructiva que en main no aplica"

# Y lo que no puede pasar nunca: tocar el clon canonico compartido
assert_eq "$stale_head" "$( cd "$WS/repos/stale" && git rev-parse HEAD )" \
  "el ensayo NO movio el HEAD del clon canonico"
assert_eq "" "$( cd "$WS/repos/stale" && git status --porcelain )" \
  "ni lo dejo sucio (antes hacia reset --hard sobre un recurso compartido)"

echo
echo "── SALIR de la ceguera: el contrato de env que los CLIs leen de verdad"
# El tri-estado ya impide el rollback por ceguera (arriba), pero el watcher no
# tenia forma de DEJAR de estar ciego: argocd_cli_ready exigia ARGOCD_URL, una
# variable que el CLI de argocd no lee (lee ARGOCD_SERVER, host SIN esquema) y
# que nada del harness provee. O sea: el respaldo por CLI era codigo muerto, y
# la ceguera era el estado normal, no la excepcion.
extract_fn argocd_server > "$WS/acsrv.sh" 2>/dev/null || true
extract_fn argocd_cli_ready >> "$WS/acsrv.sh"
srv_of() {  # srv_of <valor de ARGOCD_URL o ARGOCD_SERVER>
  ( ARGOCD_URL="$1"; ARGOCD_SERVER="${2:-}"
    . "$WS/acsrv.sh"; argocd_server )
}
assert_eq "argocd.example.org" "$(srv_of 'https://argocd.example.org')" \
  "el esquema https:// se saca: el CLI espera host, no URL"
assert_eq "argocd.example.org" "$(srv_of 'https://argocd.example.org/')" \
  "y la barra final tampoco viaja"
assert_eq "argocd.example.org" "$(srv_of 'http://argocd.example.org/applications')" \
  "ni el path (el 'unknown port' del contexto roto salia de aca)"
assert_eq "argocd.example.org" "$(srv_of '' 'argocd.example.org')" \
  "ARGOCD_SERVER ya canonico se respeta tal cual"
assert_eq "" "$(srv_of '' '')" "sin ninguna de las dos: vacio, y arriba eso es ceguera declarada"

ready_con() {  # ready_con <url> <token>: 0 si el CLI tiene con que hablar
  ( ARGOCD_URL="$1"; ARGOCD_AUTH_TOKEN="$2"; ARGOCD_SERVER=""
    ARGOCD_USERNAME=""; ARGOCD_PASSWORD=""
    . "$WS/acsrv.sh"; argocd_cli_ready ) >/dev/null 2>&1
}
ready_con 'https://argocd.example.org' 'tok' \
  && pass "con direccion y token: el CLI esta listo" \
  || fail "con direccion y token sigue declarandose ciego (el respaldo es codigo muerto)"
ready_con '' 'tok' && fail "sin direccion se declaro listo" \
  || pass "sin direccion: no listo (y arriba eso es ceguera, no rojo)"

echo
echo "── el puente de nombres de Kargo: el CLI pide KARGO_API_*, el harness guarda KARGO_*"
extract_fn kargo_env_bridge > "$WS/kbridge.sh"
grep -q 'KARGO_API_ADDRESS' "$WS/kbridge.sh" \
  || fail "no pude extraer kargo_env_bridge del template"
puente() {  # puente <KARGO_ADDRESS> <KARGO_TOKEN> → 'API_ADDRESS|API_TOKEN'
  ( KARGO_ADDRESS="$1"; KARGO_TOKEN="$2"
    KARGO_API_ADDRESS=""; KARGO_API_TOKEN=""
    . "$WS/kbridge.sh"; kargo_env_bridge
    printf '%s|%s' "$KARGO_API_ADDRESS" "$KARGO_API_TOKEN" )
}
assert_eq "https://kargo.example.org|tok" "$(puente 'https://kargo.example.org' 'tok')" \
  "KARGO_ADDRESS/KARGO_TOKEN llegan al CLI como KARGO_API_*"
inverso() {  # el puente va en los dos sentidos: una instancia puede tener cualquiera
  ( KARGO_ADDRESS=""; KARGO_TOKEN=""
    KARGO_API_ADDRESS="https://kargo.example.org"; KARGO_API_TOKEN="tok"
    . "$WS/kbridge.sh"; kargo_env_bridge
    printf '%s|%s' "$KARGO_ADDRESS" "$KARGO_TOKEN" )
}
assert_eq "https://kargo.example.org|tok" "$(inverso)" "y en el sentido inverso tambien"
assert_eq "|" "$(puente '' '')" "sin nada que puentear: no inventa valores"

echo
echo "── el health por kubectl ESPERA: 'Progressing' no es 'roto'"
# Bug encontrado auditando esta familia: la lectura de kubectl era instantanea,
# sin loop ni uso del timeout. Corriendo segundos despues del push, OutOfSync o
# Progressing es lo NORMAL y transitorio, y ese estado devolvia 1 = rojo = red()
# = propuesta de rollback sobre un deploy que iba bien. Es el mismo falso rojo
# que esta familia de bugs vino a matar, entrando por otra puerta.
# check_argocd_health ahora consulta revision_contiene_ship (#73): sin el helper
# el tramo extraido muere con 127 igual que sin run_bounded.
{ extract_fn revision_contiene_ship; extract_fn check_argocd_health; } > "$WS/health.sh"
mk_kubectl() {  # mk_kubectl <linea1> <linea2...>: respuestas sucesivas
  : > "$WS/kubectl.calls"
  { printf '#!/usr/bin/env bash\n'
    printf 'n=$(( $(cat "%s" 2>/dev/null || echo 0) + 1 )); echo "$n" > "%s"\n' \
      "$WS/kubectl.calls" "$WS/kubectl.calls"
    printf 'case "$n" in\n'
    local i=1
    for r in "$@"; do printf '  %s) echo "%s" ;;\n' "$i" "$r"; i=$((i+1)); done
    printf '  *) echo "%s" ;;\nesac\n' "$1"
  } > "$WS/bin/kubectl"
  chmod +x "$WS/bin/kubectl"
}
corre_health() {  # corre_health <timeout>
  ( export PATH="$WS/bin:$PATH"
    APP=demo; TIMEOUT="$1"; LOG="$WS/h.log"; OBSERVED_REVISION=""
    say() { echo "$1"; }
    PATH="$WS/bin:$PATH"
    acota
    . "$WS/health.sh"
    check_argocd_health; echo "RC=$?" )
}
# Dos lecturas transitorias y despues sano: tiene que salir VERDE, no rojo.
mk_kubectl "Synced Progressing abc123" "OutOfSync Progressing abc123" "Synced Healthy abc123"
out="$(corre_health 60)"
assert_contains "$out" "RC=0" "espera al Progressing en vez de llamarlo roto"
[ "$(cat "$WS/kubectl.calls")" -ge 3 ] \
  && pass "y volvio a mirar (no fue una lectura instantanea)" \
  || fail "leyo una sola vez: el timeout sigue sin usarse en el camino kubectl"

# Enfermo de verdad hasta el deadline: eso SI es rojo, con el estado observado.
mk_kubectl "OutOfSync Degraded abc123"
start=$(date +%s); out="$(corre_health 3)"; elapsed=$(( $(date +%s) - start ))
assert_contains "$out" "RC=1" "enfermo hasta el deadline: rojo legitimo"
assert_contains "$out" "health=Degraded" "y el mensaje trae el estado observado"
[ "$elapsed" -lt 30 ] && pass "respeta el deadline (${elapsed}s)" \
  || fail "se paso del timeout: ${elapsed}s"

# kubectl que no responde nada NO es enfermedad: es ceguera. No puede quemar el
# timeout esperandole a un cluster que no esta.
mk_kubectl ""
start=$(date +%s); out="$(corre_health 30)"; elapsed=$(( $(date +%s) - start ))
assert_contains "$out" "RC=2" "kubectl mudo: ceguera (no rojo, no verde)"
[ "$elapsed" -lt 10 ] && pass "y no le espera al cluster ausente (${elapsed}s)" \
  || fail "espero ${elapsed}s a un kubectl que no responde"
rm -f "$WS/bin/kubectl"

echo
echo "── el catalogo declara la DIRECCION, no solo el token"
# Sin la direccion en el catalogo, el bootstrap instala el CLI y el doctor lo ve
# presente, pero nadie puede materializar con que servidor habla: la cadena
# completa que exige la regla anti-consejo-vacio quedaba cortada en el ultimo
# eslabon, y el watcher vivia ciego por diseno.
cat_yaml="$(cat "$ROOT/catalog/capabilities.yaml")"
assert_contains "$cat_yaml" "ARGOCD_URL" "el entry de argocd declara su direccion"
assert_contains "$cat_yaml" "KARGO_API_ADDRESS" "y el de kargo la suya"

echo
echo "── COR-676: Actions verde NO es un deploy verificado; el cluster es quien lo dice"
# Caso de campo (repo apollo). `deploy-watch.sh <task> apollo` cerraba con
#   🟢 deploy de apollo verificado por driver=gitops: actions
# y emitia un `deploy ok=true` al bus, con los DOS tramos de cluster ciegos:
# kargo sin login y argocd sin direccion. Lo unico comprobado era que el CI
# construyo. El cambio que lo destapo era una variable de entorno del chart, o
# sea exactamente lo que solo se ve corriendo en el pod. Un falso verde asi es
# peor que un rojo: nadie vuelve a mirar.
mkdir -p "$WS/bin" "$WS/tasks/T9"
# El clon canonico de apollo tiene que EXISTIR y tener los objetos: desde el #73
# la relacion entre la revision desplegada y el ship se decide con git, y sin
# objetos la respuesta honesta es "no pude decidir" (rc=4), no el rojo que
# AFIRMA que el deploy no se hizo. Los shas sinteticos de antes probaban un
# escenario que en produccion no existe: ahi siempre hay clon.
mkdir -p "$WS/repos/apollo"
git init -q -b main "$WS/repos/apollo"
( cd "$WS/repos/apollo"; git config user.email t@t; git config user.name t
  echo v1 > app.txt; git add -A; git commit -qm "anterior"
  echo v2 > app.txt; git add -A; git commit -qm "mi ship"
  git update-ref refs/remotes/origin/main HEAD )
SHA_PREV="$( cd "$WS/repos/apollo" && git rev-parse HEAD~1 )"
SHA40="$( cd "$WS/repos/apollo" && git rev-parse HEAD )"
sed -e "s|{{KARGO_PROJECT}}|p|g" -e "s|{{GITHUB_ORG}}|org|g" \
    -e "s|{{ARGO_APP_PREFIX}}|corvux|g" -e "s|{{ROLLBACK_MODE}}|auto|g" \
    "$ROOT/templates/scripts/deploy-watch.sh.tmpl" > "$WS/scripts/dw676.sh"
printf 'repos:\n  - name: apollo\n    kind: service\n' > "$WS/manifest.yaml"
rm -f "$WS/harness-answers.yaml"; rm -rf "$WS/scripts/smoke"
printf '{"repo":"apollo","sha":"%s"}\n' "$SHA40" > "$WS/tasks/T9/ship.log"

# gh que responde por NUESTRO commit y da el workflow en verde: la etapa de CI
# se verifica de verdad, que es justo lo que hacia falta para reproducir.
cat > "$WS/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"run list"*)  echo 30568698782 ;;
  # el watcher ya no usa `gh run watch` (se cuelga por diseño: su loop no tiene
  # deadline). Ahora poll-ea status+conclusion en UNA llamada.
  *"--json status,conclusion"*) printf 'completed\tsuccess\n' ;;
  *) exit 1 ;;
esac
STUB
kargo_ciego() { cat > "$WS/bin/kargo" <<'STUB'
#!/usr/bin/env bash
echo "Error: get client from config: seems like you are not logged in" >&2
exit 1
STUB
chmod +x "$WS/bin/kargo"; }
kargo_ok() { printf '#!/usr/bin/env bash\necho "promotion-1  Succeeded"\n' > "$WS/bin/kargo"
  chmod +x "$WS/bin/kargo"; }
# argocd instalado pero sin servidor: falla en milisegundos, como en campo
printf '#!/usr/bin/env bash\necho "Argo CD server address unspecified" >&2\nexit 1\n' > "$WS/bin/argocd"
chmod +x "$WS/bin/gh" "$WS/bin/argocd"
SIN_KUBECTL="$(t_path_without kubectl)"

run676() {  # run676 [env...]: corre el watcher de apollo con el PATH de $WS/bin
  ( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" PATH="$WS/bin:$SIN_KUBECTL" \
      DEPLOY_TIMEOUT="${DW_TIMEOUT:-3}" DEPLOY_POLL_SECS=1 \
      DEPLOY_ACTIONS_TIMEOUT="${DW_ACTIONS_TIMEOUT:-5}" DEPLOY_ACTIONS_POLL_SECS=1 \
      env -u ARGOCD_AUTH_TOKEN -u ARGOCD_URL -u ARGOCD_SERVER \
      bash scripts/dw676.sh T9 apollo ) 2>&1
}

kargo_ciego
rm -f "$WS/bin/kubectl"
: > "$WS/.harness/events.jsonl"
out="$(run676)"; rc=$?
assert_contains "$out" "✅ actions verde" "el tramo de CI SI se verifico (la reproduccion es fiel)"
assert_not_contains "$out" "verificado por driver=gitops: actions" \
  "COR-676: Actions sola NO cierra verde un deploy gitops"
assert_not_contains "$out" "🟢" "y no hay circulo verde de ningun tipo"
assert_not_contains "$(bus)" '"ok":true' \
  "ni un deploy ok=true en el bus (es lo que el humano ve en el panel)"
assert_contains "$out" "SIN VERIFICAR EN EL CLUSTER" "se declara AUSENTE, con todas las letras"
assert_contains "$out" "pipeline CORRIÓ" "y explica que CI y cluster son preguntas distintas"
assert_contains "$out" "CEGUERA, no un deploy rojo" "es ceguera, no un deploy roto"
assert_contains "$out" "· kargo:" "nombra el tramo de kargo que quedo sin mirar"
assert_contains "$out" "· argocd:" "y el de argocd"
assert_contains "$(bus)" "NO verificado en el cluster" "queda como supuesto en el ledger"
assert_not_contains "$out" "🔴" "no inventa un rojo con lo que no observo"
assert_not_contains "$out" "git revert" "y no manda a revertir (la remediacion son credenciales)"
assert_eq 0 "$rc" "ceguera no es fallo del deploy: exit 0"

echo
echo "── la contra-mitad: un deploy REALMENTE verde sigue verde"
# Si el arreglo convierte todo en "no pude verificar", el gate deja de servir y
# es peor que el bug. Con el cluster respondiendo Healthy+Synced, el cierre
# tiene que ser verde de verdad y con su evento en el bus.
kargo_ok
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get applications"*) exit 1 ;;
  *"get application "*) printf 'Synced Healthy ' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WS/bin/kubectl"
: > "$WS/.harness/events.jsonl"
out="$(run676)"; rc=$?
assert_contains "$out" "🟢 deploy de apollo verificado" "cluster sano: el cierre es verde"
assert_contains "$out" "actions + argocd sincronizado al manifiesto" "y nombra lo que argocd PRUEBA: el manifiesto, no la imagen"
assert_contains "$(bus)" '"ok":true' "con su deploy ok=true en el bus"
assert_not_contains "$out" "SIN VERIFICAR" "no degrada a ceguera lo que si pudo mirar"
assert_eq 0 "$rc" "y sale 0"

echo
echo "── argocd verde SIN interrogar al artefacto: sigue verde, pero lo DICE"
# POR QUE: Synced significa que el cluster coincide con el MANIFIESTO de esa
# revision, y Healthy que los pods viven. Con promocion de tag (Kargo) el bump
# es un commit APARTE, asi que la revision puede descender de tu ship y el
# manifiesto de TU servicio seguir apuntando a la imagen anterior: Synced y
# Healthy verdaderos, pods corriendo lo viejo. La ancestria prueba que el REPO
# avanzo, no que TU CODIGO corre. Caso de campo reportado por un operador.
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get applications"*) exit 1 ;;
  *"get application "*) printf 'Synced Healthy ' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WS/bin/kubectl"
: > "$WS/.harness/events.jsonl"
out="$(run676)"; rc=$?
assert_eq 0 "$rc" "sigue saliendo 0: degradarlo a rojo se llevaria puesto todo repo gitops sin verify_cmd"
assert_contains "$out" "🟢 deploy de apollo verificado" "y sigue siendo verde"
assert_contains "$out" "NADIE interrogó al artefacto"   "pero avisa que nadie miro si el pod corre TU imagen"
assert_contains "$out" "Kargo" "y nombra la causa concreta: la promocion de tag"
assert_contains "$out" "verify_cmd" "con la remediacion exacta"
assert_contains "$(bus)" "sin interrogar al artefacto"   "y viaja al bus: el verde es lo que se recuerda, asi que el asterisco tiene que verse en el panel"

# CONTRA-MITAD 1: con verify_cmd declarado, el aviso NO sale. Si saliera igual
# se volveria ruido permanente y alguien lo apagaria.
printf 'deploy:\n  apollo:\n    driver: gitops\n    verify_cmd: "echo marcador-de-build"\n    verify_expect: "marcador-de-build"\n' >> "$WS/harness-answers.yaml"
: > "$WS/.harness/events.jsonl"
out="$(run676)"
assert_not_contains "$out" "NADIE interrogó al artefacto" \
  "con verify_cmd declarado el aviso se calla"
# Se revierte el answers para no contaminar los casos de abajo.
python3 - "$WS/harness-answers.yaml" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); l = p.read_text().splitlines()
while l and ("verify_" in l[-1] or "driver: gitops" in l[-1] or l[-1].strip() in ("apollo:", "deploy:")):
    l.pop()
p.write_text("\n".join(l) + "\n")
PYEOF
rm -f "$WS/bin/kubectl"

# El smoke tambien es señal de cluster: interroga al artefacto desplegado.
mkdir -p "$WS/scripts/smoke"
printf '#!/bin/sh\nexit 0\n' > "$WS/scripts/smoke/apollo.sh"
chmod +x "$WS/scripts/smoke/apollo.sh"
rm -f "$WS/bin/kubectl"
: > "$WS/.harness/events.jsonl"
out="$(run676)"
assert_contains "$out" "🟢 deploy de apollo verificado" \
  "con argocd ciego pero smoke verde: sigue habiendo prueba de que el artefacto vive"
rm -rf "$WS/scripts/smoke"

echo
echo "── la otra contra-mitad: un deploy REALMENTE roto sigue en rojo"
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get applications"*) exit 1 ;;
  *"get application "*) printf 'OutOfSync Degraded ' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WS/bin/kubectl"
: > "$WS/.harness/events.jsonl"
out="$(run676)"; rc=$?
assert_contains "$out" "🔴" "app observada y enferma: rojo legitimo"
assert_contains "$out" "NO está Healthy+Synced" "con la causa observada"
[ "$rc" -ne 0 ] && pass "y sale != 0 (el rojo sigue mordiendo)" \
  || fail "un deploy enfermo salio 0: el gate dejo de morder"
assert_contains "$(bus)" '"ok":false' "y el bus lo cuenta como deploy fallado"
assert_not_contains "$out" "SIN VERIFICAR EN EL CLUSTER" \
  "un rojo observado NO se disfraza de ceguera"
rm -f "$WS/bin/kubectl"

echo
echo "── y driver=actions conserva su verde: ahi Actions SI es toda la señal declarada"
# El contrato del driver `actions` es explicito: la conclusion del workflow es
# todo lo que hay, y fingir mas seria inventar. Si el arreglo de COR-676 se
# derramara hasta aca, cada deploy sin Kubernetes quedaria "sin verificar" para
# siempre: eso rompe el gate en vez de arreglarlo.
printf 'project: demo\ndeploy:\n  apollo:\n    driver: actions\n' > "$WS/harness-answers.yaml"
: > "$WS/.harness/events.jsonl"
out="$(run676)"
assert_contains "$out" "🟢 deploy de apollo verificado por driver=actions: actions" \
  "driver=actions con el workflow verde: cierra verde, como siempre"
assert_contains "$(bus)" '"ok":true' "y emite su deploy al bus"
rm -f "$WS/harness-answers.yaml"

echo
echo "── issue #66: un run SUCCESS con build SKIPPED no es verde (skipped != success)"
# Caso real: deploy.yml condiciona el job build a un bump semver por
# conventional commits; un ship sin prefijo dejo tag con bump_type=none y el
# build SKIPPED. La conclusion del RUN es success igual (un job saltado no la
# mancha), y el watcher canto 🟢 sin imagen construida ni deploy. La conclusion
# del run no alcanza: hay que mirar la de CADA job.
gh_con_jobs() {  # gh_con_jobs <json-de-jobs>: gh stub cuyo run view devuelve esos jobs
  cat > "$WS/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"run list"*)  echo 30568698782 ;;
  # el poll va PRIMERO: tambien es un \`run view\`, y sin esta rama caeria en la
  # de abajo y le correria la expresion de status al JSON de jobs.
  *"--json status,conclusion"*) printf 'completed\tsuccess\n' ;;
  *"run view"*)  jq -r "\${@: -1}" <<'JSON'
$1
JSON
  ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$WS/bin/gh"
}

# driver=gitops (el del caso real): el rojo se declara en la etapa de Actions,
# sin esperar 900s a un ArgoCD que jamas va a recibir la revision.
: > "$WS/.harness/events.jsonl"
gh_con_jobs '{"jobs":[{"name":"tag","conclusion":"success"},{"name":"build","conclusion":"skipped"}]}'
out="$(run676)"; rc=$?
assert_not_contains "$out" "✅ actions verde" "build skipped: actions NO se declara verde"
assert_not_contains "$out" "🟢" "y no hay cierre verde de ningun tipo"
[ "$rc" -ne 0 ] && pass "y sale != 0 (el deploy NO paso)" || fail "build skipped salio 0"
assert_contains "$out" "skipped != success" "dice por que: un job saltado no es un job verde"
assert_contains "$out" "SKIPPED: build" "y nombra el job que no corrio"
assert_contains "$out" "NO propongo revertir" "no manda a revertir: no se desplego nada nuevo"
assert_not_contains "$out" "revert en git de" "y no ensaya un revert sobre un deploy que no existio"
assert_contains "$(bus)" '"ok":false' "el bus NO lo da por desplegado"

# contra-mitad: TODOS los jobs en success cierran verde como siempre
printf 'project: demo\ndeploy:\n  apollo:\n    driver: actions\n' > "$WS/harness-answers.yaml"
: > "$WS/.harness/events.jsonl"
gh_con_jobs '{"jobs":[{"name":"tag","conclusion":"success"},{"name":"build","conclusion":"success"}]}'
out="$(run676)"; rc=$?
assert_contains "$out" "✅ actions verde" "todos los jobs success: actions verde, como siempre"
assert_contains "$out" "🟢 deploy de apollo verificado por driver=actions: actions" \
  "y el cierre es verde"
assert_eq 0 "$rc" "y sale 0"
rm -f "$WS/harness-answers.yaml"

echo
echo "── un run que NUNCA termina no cuelga al watcher (y no es rojo)"
# ESTE es el tramo que no tenia cobertura de cuelgue, y es el que colgaba en
# campo. `gh run watch` se cuelga POR DISENO: su loop es `for run.Status !=
# Completed` sin deadline ni context cancelable, y sus unicas flags son
# --compact, --exit-status e --interval. No existe --timeout. El techo real de
# un run son 35 DIAS. Se reemplazo por un poll con deadline propio.
gh_pegado() {  # gh_pegado <status>: el run se queda en ese estado para siempre
  cat > "$WS/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"run list"*)                  echo 30568698782 ;;
  *"--json status,conclusion"*)  printf '$1\t\n' ;;
  *"pending_deployments"*)       echo "environment prod: espera aprobación de ana, beto" ;;
  *"/jobs"*)                     echo "job build: runner SIN ASIGNAR, labels [self-hosted, linux]" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$WS/bin/gh"
}
run_pegado() {  # run_pegado: como run676 pero con el presupuesto de Actions en 2s
  ( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" PATH="$WS/bin:$SIN_KUBECTL" \
      DEPLOY_TIMEOUT=2 DEPLOY_POLL_SECS=1 \
      DEPLOY_ACTIONS_TIMEOUT=2 DEPLOY_ACTIONS_POLL_SECS=1 \
      env -u ARGOCD_AUTH_TOKEN -u ARGOCD_URL -u ARGOCD_SERVER \
      bash scripts/dw676.sh T9 apollo ) 2>&1
}

printf 'project: demo\ndeploy:\n  apollo:\n    driver: actions\n' > "$WS/harness-answers.yaml"
: > "$WS/.harness/events.jsonl"
gh_pegado queued
inicio=$(date +%s); out="$(run_pegado)"; rc=$?; elapsed=$(( $(date +%s) - inicio ))

# (1) LO PRIMERO: que TERMINE. Con `gh run watch` esto no volvia nunca.
[ "$elapsed" -lt 60 ] \
  && pass "el watcher TERMINA con un run pegado en queued (${elapsed}s, no infinito)" \
  || fail "sigue colgado: ${elapsed}s"

# (2) Y que el $( ) vuelva enseguida. El watchdog corre en background y, si
#     hereda stdout, sostiene el pipe aunque el script ya haya salido: 40
#     minutos de cuelgue DESPUES de terminar. Lo cazo este mismo test cuando
#     el watchdog se escribio sin el >/dev/null.
[ "$elapsed" -lt 60 ] \
  && pass "y el \$( ) que lo captura vuelve con el (el watchdog no sostiene stdout)" \
  || fail "el watchdog dejo el pipe abierto"

# (3) AGOTARSE NO ES ROJO. Un run en queued no desplego nada: el cluster corre
#     la version anterior, que esta sana. Proponer un revert aca mandaria a
#     revertir un commit que nunca llego a ningun lado.
assert_not_contains "$out" "🔴 Actions" "agotarse NO se declara rojo"
assert_not_contains "$out" "git revert" "y NO propone revertir nada"
assert_not_contains "$out" "🟢" "tampoco lo da por verde"
assert_contains "$out" "no terminó en 2s" "dice cuanto espero"
assert_contains "$out" "sigue en 'queued'" "y en que estado quedo"
assert_contains "$(bus)" '"kind":"assumption"' "queda como SUPUESTO, que es la categoria de 'no pude ver'"
assert_not_contains "$(bus)" '"ok":true' "y el bus no lo da por desplegado"

# (4) LA CAUSA SE NOMBRA. "Se agoto el tiempo" no le dice al humano que hacer;
#     "el job sigue encolado sin runner" si. runner_id vacio es la senal.
assert_contains "$out" "sin runner asignado" "nombra la causa: ningun runner tomo el job"
assert_contains "$out" "job build" "y nombra el job concreto"
assert_contains "$out" "self-hosted" "con las labels que nadie matchea"

# (5) LATIDO: el estado se dice a la consola. Antes todo iba a \$LOG y la
#     consola quedaba muda toda la etapa, asi que no se podia distinguir
#     "esperando bien" de "colgado", y por eso el humano lo mataba.
assert_contains "$out" "run 30568698782: queued" "hay latido a consola con el estado"

# (6) waiting es OTRA causa y se dice distinto: no es infraestructura, es que
#     alguien tiene que apretar un boton. Puede durar 30 dias.
: > "$WS/.harness/events.jsonl"
gh_pegado waiting
out="$(run_pegado)"
assert_contains "$out" "APROBACIÓN HUMANA" "waiting: dice que espera a una persona, no a un runner"
assert_contains "$out" "environment prod" "y nombra el environment"
assert_contains "$out" "ana, beto" "y a quienes tienen que aprobar"
assert_not_contains "$out" "git revert" "tampoco propone revertir por una aprobacion pendiente"

# (7) pending es la tercera: bloqueado por un concurrency group.
: > "$WS/.harness/events.jsonl"
gh_pegado pending
out="$(run_pegado)"
assert_contains "$out" "CONCURRENCY GROUP" "pending: nombra el concurrency group"
rm -f "$WS/harness-answers.yaml"
# EL STUB SE RESTAURA. Dejarlo pegado en 'pending' hace que el test SIGUIENTE
# poll-ee con el presupuesto por defecto (1800s) y cuelgue la suite entera: pasó
# al escribir este bloque, y la ironia de que el test del cuelgue colgara la
# suite es exactamente el punto. run676 ademas acota su presupuesto de Actions
# por si alguien vuelve a olvidarse.
gh_con_jobs '{"jobs":[{"name":"tag","conclusion":"success"},{"name":"build","conclusion":"success"}]}'

echo
echo "── issue #64: Healthy+Synced en la revisión VIEJA no es verde"
# Caso real: ship de corvux-landing @ 744e0a8; el watcher observo
# revision=1b46ab06f42d (el commit ANTERIOR), Healthy+Synced, y canto verde
# con el cambio sin desplegar. El verde exige la revision shippeada, con la
# MISMA comparacion que el camino rojo (prefijo en cualquiera de los dos
# sentidos: ship.log guardo shas cortos y la API devuelve completos).
mkdir -p "$WS/repos/promo"
git init -q -b main "$WS/repos/promo"
( cd "$WS/repos/promo"; git config user.email t@t; git config user.name t
  echo base > f.txt; git add -A; git commit -qm base
  echo mio > f.txt;  git add -A; git commit -qm "feat: mi ship (merge)"
  echo bump > chart.yaml; git add -A; git commit -qm "chore: Update image tag"
  git update-ref refs/remotes/origin/main HEAD )
C_BASE="$( cd "$WS/repos/promo" && git rev-parse HEAD~2 )"
C_SHIP="$( cd "$WS/repos/promo" && git rev-parse HEAD~1 )"
C_BUMP="$( cd "$WS/repos/promo" && git rev-parse HEAD )"

corre_health_sha() {  # corre_health_sha <timeout> <sha-shippeado>
  ( export PATH="$WS/bin:$PATH" DEPLOY_POLL_SECS=1
    WS="$WS"; REPO=promo; BASE_REF=main
    APP=demo; TIMEOUT="$1"; LOG="$WS/h.log"; OBSERVED_REVISION=""
    LANDED_SHA="$2"
    say() { echo "$1"; }
    acota
    . "$WS/health.sh"
    check_argocd_health; echo "RC=$?" )
}

mk_kubectl "Synced Healthy $C_BASE"
start=$(date +%s)
out="$(corre_health_sha 3 "$C_SHIP")"
elapsed=$(( $(date +%s) - start ))
assert_not_contains "$out" "RC=0" "sano en la revision ANTERIOR: NUNCA verde"
assert_contains "$out" "RC=3" "espera hasta el deadline y lo reporta aparte (rc=3)"
assert_contains "$out" "aún no llega" "y lo dice mientras espera"
[ "$elapsed" -lt 30 ] && pass "respetando el deadline (${elapsed}s)" \
  || fail "se paso del deadline: ${elapsed}s"

# contra-mitad 1: sano en la revision shippeada SI cierra verde
mk_kubectl "Synced Progressing $C_SHIP" "Synced Healthy $C_SHIP"
out="$(corre_health_sha 30 "$C_SHIP")"
assert_contains "$out" "RC=0" "sano en la revision shippeada: verde legitimo"

# contra-mitad 2: sha corto en el log contra sha completo del cluster
mk_kubectl "Synced Healthy $C_SHIP"
out="$(corre_health_sha 30 "${C_SHIP:0:7}")"
assert_contains "$out" "RC=0" "sha corto vs completo: matchea por prefijo (como el camino rojo)"

# contra-mitad 3: sin revision observada no se inventa la comparacion
mk_kubectl "Synced Healthy "
out="$(corre_health_sha 30 "$C_SHIP")"
assert_contains "$out" "RC=0" "cluster sin revision: verde degradado al de siempre"
rm -f "$WS/bin/kubectl"

echo
echo "── issue #73: la revision desplegada DESCIENDE del ship (el promotor commitea encima)"
# El #64 dejo la comparacion por PREFIJO en los dos sentidos. No cubre el layout
# de infra-live donde un promotor de imagen commitea el bump del tag ENCIMA del
# merge, en el mismo repo que ArgoCD sigue: ahi la revision desplegada nunca es
# igual ni prefijo del sha shippeado, y TODO ship terminaba en rojo falso
# diciendo "el deploy NO se hizo" sobre un commit que CONTIENE el cambio.
corre_health_repo() {  # corre_health_repo <timeout> <sha-shippeado> <repo>
  ( export PATH="$WS/bin:$PATH" DEPLOY_POLL_SECS=1
    WS="$WS"; REPO="$3"; BASE_REF=main
    APP=demo; TIMEOUT="$1"; LOG="$WS/h.log"; OBSERVED_REVISION=""
    LANDED_SHA="$2"
    say() { echo "$1"; }
    acota
    . "$WS/health.sh"
    check_argocd_health; echo "RC=$?" )
}

# RED-FIRST: hoy esto da RC=3 tras quemar el timeout entero.
mk_kubectl "Synced Healthy $C_BUMP"
start=$(date +%s)
out="$(corre_health_repo 20 "$C_SHIP" promo)"
elapsed=$(( $(date +%s) - start ))
assert_contains "$out" "RC=0" "sano en un DESCENDIENTE del ship: verde (el commit desplegado lo contiene)"
assert_contains "$out" "desciende de mi ship" "y lo dice, en vez de callar por que dio verde"
[ "$elapsed" -lt 15 ] \
  && pass "y no quema el timeout entero antes de decidir (${elapsed}s)" \
  || fail "espero ${elapsed}s: sigue tratando el descendiente como transitorio"

# EL #64 NO SE DESHACE: la revision ANTERIOR al ship sigue sin ser verde, porque
# la pregunta es dirigida (mi sha ancestro de lo desplegado, no al reves).
mk_kubectl "Synced Healthy $C_BASE"
out="$(corre_health_repo 3 "$C_SHIP" promo)"
assert_contains "$out" "RC=3" "revision ANTERIOR al ship: sigue en rojo (#64 intacto)"
assert_not_contains "$out" "RC=0" "y no se cuela por la rama de ancestria"

# CEGUERA: la revision observada no existe en el clon y el fetch no la trae.
# No puede terminar en el rojo que AFIRMA que el deploy no se hizo.
mk_kubectl "Synced Healthy cafe1234cafe1234cafe1234cafe1234cafe1234"
out="$(corre_health_repo 3 "$C_SHIP" promo)"
assert_contains "$out" "RC=4" "revision indecidible: cuarto estado, ni verde ni el rojo que afirma"
assert_not_contains "$out" "RC=3" "NO se declara 'el deploy no se hizo' sin poder comprobarlo"

# Sin repo local no hay con que comparar: tambien es ceguera, no rojo.
mk_kubectl "Synced Healthy $C_BUMP"
out="$(corre_health_repo 3 "$C_SHIP" no-existe)"
assert_contains "$out" "RC=4" "sin clon local: ceguera declarada, no un rojo inventado"
rm -f "$WS/bin/kubectl"

echo
echo "── issue #73 en el camino ROJO: el mismo agujero estaba en rollback_advice"
# Una revision ENFERMA que desciende de mi ship SI lo contiene: mi commit es
# sospechoso legitimo y el revert corresponde. La comparacion por prefijo la
# declaraba "ajena" y declinaba con un motivo inventado.
run_rb_repo() {  # run_rb_repo <observed-revision> <sha> <repo>
  ( set -u; WS="$WS"; REPO="$3"; TASK=T7; BASE_REF=main
    ROLLBACK_MODE=manual; OBSERVED_REVISION="$1"
    LOG="$WS/rb3.log"; say() { echo "$1"; }; emit() { :; }
    acota
    . "$WS/rb.sh"; rollback_advice "$2" ) 2>&1
}

out="$(run_rb_repo "$C_BUMP" "$C_SHIP" promo)"
assert_contains "$out" "desciende de mi ship" "revision enferma DESCENDIENTE: reconoce que contiene mi cambio"
assert_not_contains "$out" "Otro workspace aterrizó después" \
  "y NO la declara ajena (era el motivo inventado)"

# Contra-mitad: una revision de verdad ajena sigue declinando como siempre.
out="$(run_rb_repo "$C_BASE" "$C_SHIP" promo)"
assert_contains "$out" "NO propongo revertir nada mío" "revision que NO contiene mi ship: sigue declinando"
assert_contains "$out" "Otro workspace aterrizó después" "con el motivo de siempre"

# Indecidible: se declina igual (no se toca produccion a ciegas) pero el motivo
# es el verdadero, no "otro aterrizo despues", que seria inventar.
out="$(run_rb_repo "cafe1234cafe1234cafe1234cafe1234cafe1234" "$C_SHIP" promo)"
assert_contains "$out" "NO pude establecer" "revision indecidible: dice que no pudo, y declina"
assert_not_contains "$out" "Otro workspace aterrizó después" "sin inventar un culpable"

echo
echo "── issue #64 (extremo a extremo): sano en revision vieja cierra en rojo SIN rollback"
kubectl_rev() {  # kubectl_rev <revision>: stub de kubectl que declara sano en esa revision
  cat > "$WS/bin/kubectl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"get applications"*) exit 1 ;;
  *"get application "*) printf 'Synced Healthy $1' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$WS/bin/kubectl"
}

# El ship de apollo en T9 es $SHA40; el cluster declara sano el commit ANTERIOR.
kubectl_rev "$SHA_PREV"
: > "$WS/.harness/events.jsonl"
out="$(run676)"; rc=$?
assert_not_contains "$out" "🟢" "sano en la revision ANTERIOR al ship: no hay verde"
[ "$rc" -ne 0 ] && pass "y sale != 0 (el deploy NO aterrizo)" \
  || fail "revision vieja salio 0"
assert_contains "$out" "nunca llegó al cluster" "dice que el cambio no aterrizo"
assert_contains "$out" "NO propongo revertir" "rojo SIN rollback: el cluster esta sano en la version anterior"
assert_not_contains "$out" "revert en git de" "y no ensaya revert alguno"
assert_contains "$(bus)" '"ok":false' "el bus NO lo da por desplegado"

# y sano en la revision shippeada: el verde de verdad sigue verde
kubectl_rev "$SHA40"
: > "$WS/.harness/events.jsonl"
out="$(run676)"; rc=$?
assert_contains "$out" "🟢 deploy de apollo verificado" "sano en la revision shippeada: verde legitimo"
assert_contains "$out" "actions + argocd sincronizado al manifiesto" "con los dos tramos observados"
assert_contains "$(bus)" '"ok":true' "y su deploy ok=true en el bus"
assert_eq 0 "$rc" "y sale 0"
rm -f "$WS/bin/kubectl"

t_done
