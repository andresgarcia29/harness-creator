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

# La suite prueba el codigo REAL del template: cada tramo se extrae y se
# ejecuta de verdad. Un test que reimplementa lo que prueba miente en cuanto el
# template cambia.
extract_fn() { awk "/^$1\(\) \{/{f=1} f{print} f&&/^\}/{exit}" \
  "$ROOT/templates/scripts/deploy-watch.sh.tmpl"; }

# El bloque de kargo del template, con el placeholder resuelto. Se extrae solo
# ese tramo: el resto del watcher habla con GitHub Actions y ArgoCD reales.
sed -e "s|{{KARGO_PROJECT}}|proyecto-demo|g" \
    "$ROOT/templates/scripts/deploy-watch.sh.tmpl" \
  | awk '/^# 2 · Kargo/{f=1} f{print} f&&/^fi$/{exit}' > "$WS/kargo.sh"
grep -q 'kargo_out' "$WS/kargo.sh" || { echo "no pude extraer el bloque de kargo"; exit 1; }

run_kargo() {  # run_kargo: corre el tramo con el stub de kargo que esté en $WS/bin
  ( set -uo pipefail
    export PATH="$WS/bin:$PATH" CLAUDE_PROJECT_DIR="$WS"
    unset KARGO_PROJECT
    cd "$WS"; REPO=videocore; LOG="$WS/deploy.log"
    say() { echo "$1" | tee -a "$LOG"; }
    # El tramo pregunta por el namespace declarado del repo antes de inferirlo:
    # en el watcher completo eso lo contesta harness-answers.yaml.
    answers_repo_key() { printf ''; }
    ciego() { echo "CIEGO: $1"; }
    acota
    . "$WS/scripts/emit.sh"
    . "$WS/kargo.sh" ) 2>&1
}

bus() { cat "$WS/.harness/events.jsonl" 2>/dev/null; }

echo "── kargo falla: el harness lo declara como supuesto, no lo entierra"

# kubectl es el TERCER camino (#112) y por defecto acá tiene que fallar: si no,
# el test se colgaría del cluster real de quien corre la suite y mediría otra
# cosa. Los casos que lo ejercitan lo re-stubean.
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "The connection to the server localhost:8080 was refused" >&2
exit 1
STUB
chmod +x "$WS/bin/kubectl"

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
echo "── #112: el CLI revienta con su propio renderer de texto"
# Medido en cuatro deploys de DOS instancias, cuatro dias aparte: `kargo get
# promotions` sin -o json muere deserializando su propia respuesta
# (*models.PromotionList no implementa TextUnmarshaler), asi que el tramo de
# promocion estaba ciego en TODA tarea. El stub modela exactamente eso: texto
# revienta, json contesta.
cat > "$WS/bin/kargo" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in json) exec cat "$KARGO_JSON" ;; esac; done
echo "Error: list promotions: &{ []  <nil>} (*models.PromotionList) is not supported by the TextConsumer" >&2
exit 1
STUB
chmod +x "$WS/bin/kargo"
cat > "$WS/promos.json" <<'JSON'
{"items":[
 {"metadata":{"name":"promo-vieja","creationTimestamp":"2026-08-01T00:00:00Z"},"spec":{"freight":"f-001"},"status":{"phase":"Succeeded"}},
 {"metadata":{"name":"promo-nueva","creationTimestamp":"2026-08-09T00:00:00Z"},"spec":{"freight":"f-042"},"status":{"phase":"Running"}}
]}
JSON
: > "$WS/.harness/events.jsonl"
out="$(KARGO_JSON="$WS/promos.json" run_kargo)"
assert_contains "$out" "-o json" "#112: cae a -o json cuando el renderer de texto revienta"
assert_contains "$out" "promo-nueva" "#112: y el tramo DEJA de estar ciego"
assert_contains "$out" "f-042" "nombrando el freight, que es lo que distingue 'ArgoCD sano' de 'sano CON MI imagen'"
assert_contains "$out" "Running" "y la fase"
assert_not_contains "$(bus)" "assumption" "#112: sin supuesto: el tramo se verifico de verdad"
# El JSON crudo no se vuelca: cinco lineas de objeto no dicen si promovio.
assert_not_contains "$out" "creationTimestamp" "y no vuelca el objeto entero"

# LA HIPOTESIS DEL -o json QUEDO DESCARTADA CON AUTH: los dos modos fallan
# identico, y `kargo version` (que ni acepta -o, sobre un tipo sin relacion con
# promotions) falla igual. Es el cliente v1.10.9 contra ese servidor, no el
# renderer. El stub modela el reporte tal cual: el CLI revienta por los dos
# caminos.
cat > "$WS/bin/kargo" <<'STUB'
#!/usr/bin/env bash
echo "Error: list promotions: (*models.PromotionList) is not supported by the TextConsumer" >&2
exit 1
STUB
chmod +x "$WS/bin/kargo"
: > "$WS/.harness/events.jsonl"
out="$(run_kargo)"
assert_contains "$out" "ni con -o json, ni en texto, ni por kubectl" \
  "#112: con los tres caminos rotos, el motivo dice por donde se intento"
assert_contains "$(bus)" "Kargo NO verificada" "#112: y la ceguera declarada del diseno sigue intacta"

# Y EL TERCER CAMINO, que es el arreglo: las Promotions son CRDs, asi que
# kubectl las lee contra el API de Kubernetes y la incompatibilidad del CLI de
# kargo no lo toca. Mismo patron que este script ya usa para las Applications de
# ArgoCD. El CLI sigue reventando por los dos lados: el stub de arriba se queda.
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in promotions.kargo.akuity.io) exec cat "$KARGO_JSON" ;; esac; done
echo "error: the server doesn't have a resource type" >&2
exit 1
STUB
chmod +x "$WS/bin/kubectl"
: > "$WS/.harness/events.jsonl"
out="$(KARGO_JSON="$WS/promos.json" run_kargo)"
assert_contains "$out" "kubectl" "#112: con el CLI roto por los dos lados, cae a kubectl"
assert_contains "$out" "promo-nueva" "#112: y el tramo deja de estar ciego por el camino que NO pasa por el CLI"
assert_contains "$out" "f-042" "nombrando el freight igual que por -o json"
assert_not_contains "$(bus)" "assumption" "#112: sin supuesto: se verifico de verdad"
assert_not_contains "$out" "creationTimestamp" "y sigue sin volcar el objeto entero"

# El CR sale del mismo esquema que el -o json del CLI, asi que el jq no cambia;
# el error del CLI igual queda en el LOG para poder decidir si pinnear version.
assert_contains "$(cat "$WS/deploy.log")" "TextConsumer" \
  "#112: el error del CLI se conserva en el log (es el diagnostico util)"

# Vuelve a fallar para los casos de abajo: cada caso stubea lo suyo.
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "The connection to the server localhost:8080 was refused" >&2
exit 1
STUB
chmod +x "$WS/bin/kubectl"

# Un CLI que SI sabe hablar texto no se rompe por este arreglo: sigue el camino
# de siempre, porque el json de un CLI viejo puede no existir.
cat > "$WS/bin/kargo" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in json) echo "unknown flag: -o" >&2; exit 1 ;; esac; done
echo "promotion-1  Succeeded"
STUB
chmod +x "$WS/bin/kargo"
: > "$WS/.harness/events.jsonl"
out="$(run_kargo)"
assert_contains "$out" "promotion-1" "#112: un CLI sin -o json sigue funcionando por texto"
assert_contains "$out" "salida de texto" "y el motivo dice por donde contesto"
assert_not_contains "$(bus)" "assumption" "sin supuesto: contesto igual"

echo
echo "── #229: el namespace de la consulta sale de la APP, no de un literal"
# Caso de campo: la consulta fue al proyecto configurado en la instalacion, la
# app vivia en SU propio namespace, la lista vino vacia, y de esa lista vacia el
# tramo dedujo "es la prueba de que el artefacto todavia no llego al warehouse".
# El git log del repo mostraba la promocion de Kargo ya mergeada, con el tag que
# corrian los pods: un namespace equivocado reportado como un hecho del cluster.
{ extract_fn app_k8s_namespace; extract_fn kargo_namespace; } \
  | sed 's|{{KARGO_PROJECT}}|proyecto-demo|g' > "$WS/kns.sh"
grep -q 'app_k8s_namespace' "$WS/kns.sh" || { echo "no pude extraer kargo_namespace"; exit 1; }

cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get application "*) printf '{"spec":{"destination":{"namespace":"svc-demo"}},"status":{"resources":[{"kind":"Service","namespace":"svc-demo","name":"svc-demo"},{"kind":"Deployment","namespace":"svc-demo","name":"svc-demo"}]}}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WS/bin/kubectl"
resuelve_ns() {  # resuelve_ns [lo-que-declaro-el-humano]
  ( set -u; export PATH="$WS/bin:$PATH"
    KARGO_PROJECT="${1:-}"; APP=svc-demo; REPO=svc-demo; KARGO_NS=""
    answers_repo_key() { printf ''; }
    acota; . "$WS/kns.sh"; kargo_namespace )
}
assert_eq "svc-demo" "$(resuelve_ns)" \
  "#229: el namespace sale del namespace REAL de la app, no del proyecto cableado"
assert_eq "prod-ns" "$( DEPLOY_K8S_WORKLOADS="prod-ns/svc-demo" resuelve_ns )" \
  "y los workloads declarados a mano mandan sobre la inferencia"
assert_eq "dicho-por-el-humano" "$(resuelve_ns dicho-por-el-humano)" \
  "y lo declarado por el humano manda sobre todo: lo mas explicito gana"
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$WS/bin/kubectl"
assert_eq "proyecto-demo" "$(resuelve_ns)" \
  "sin cluster que responda, el fallback es el proyecto declarado al instalar"

# Y la lista vacia se reporta como lo que es: un hecho sobre ESTA consulta.
cat > "$WS/bin/kargo" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in json) echo '{"kind":"List","items":null}'; exit 0 ;; esac; done
exit 1
STUB
chmod +x "$WS/bin/kargo"
: > "$WS/.harness/events.jsonl"
out="$(run_kargo)"
assert_contains "$out" "no encontré promociones en el namespace" \
  "#229: la lista vacia habla de la consulta, con su namespace delante"
assert_not_contains "$out" "es la prueba de que" \
  "#229: y ya NO afirma un hecho sobre el warehouse que un git log refuta"
assert_contains "$out" "verificá el namespace" "con la remediacion exacta: mirar el ns primero"
assert_contains "$out" "kargo_project" "y como declararlo si es otro"
assert_contains "$(bus)" "Kargo NO verificada" "sigue siendo ceguera declarada, no un verde"

# ── #229: una pagina de login NO es una respuesta del warehouse ──────────
# Sin credencial (o detras de SSO) lo que vuelve es el HTML del login, y el
# tramo lo volcaba al log y razonaba sobre el como si fuera la lista.
cat > "$WS/bin/kargo" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in json) echo "unknown flag" >&2; exit 1 ;; esac; done
cat <<'HTML'
<!DOCTYPE html>
<html><head><title>Sign in</title></head>
<body><script src="/js-idp.js"></script>addFragmentToURLState()</body></html>
HTML
STUB
chmod +x "$WS/bin/kargo"
: > "$WS/.harness/events.jsonl"
out="$(run_kargo)"
assert_contains "$out" "es HTML, no datos" "#229: el HTML se reporta como lo que es"
assert_contains "$out" "CREDENCIAL" "y se nombra la causa: credencial o direccion"
assert_not_contains "$out" "no encontré promociones" \
  "#229: y NO se convierte en una afirmacion sobre el warehouse"
assert_not_contains "$out" "addFragmentToURLState" "ni se vuelca la pagina de login a la consola"
assert_contains "$(bus)" "la respuesta fue HTML" "el supuesto dice que fue HTML, no 'sin freight'"
assert_contains "$(cat "$WS/deploy.log")" "js-idp" "el payload crudo queda en el log, para diagnosticar"

# Vuelve a fallar por los tres caminos para los casos de abajo.
cat > "$WS/bin/kargo" <<'STUB'
#!/usr/bin/env bash
echo "Error: not authenticated: no token found" >&2
exit 1
STUB
chmod +x "$WS/bin/kargo"
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "The connection to the server localhost:8080 was refused" >&2
exit 1
STUB
chmod +x "$WS/bin/kubectl"

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
# (extract_fn vive arriba: los tramos de kargo tambien lo usan)

# Solo CÓDIGO: el comentario que documenta el bug sí nombra $WT, y debe poder
# hacerlo sin que el test lo confunda con una regresión.
grep -v '^[[:space:]]*#' "$ROOT/templates/scripts/deploy-watch.sh.tmpl" \
  | grep -q 'git -C "$WT"' \
  && fail "sigue usando \$WT en código, y esa variable nunca se define" \
  || pass "ya no depende de \$WT (la variable fantasma que causaba la ceguera)"

# El ledger viaja con la funcion: desde el #232 el sha sale de ship-ledger.jsonl
# (con lectura de compatibilidad de ship.log), y sin los lectores el tramo
# extraido moriria con 127 igual que sin run_bounded.
{ extract_fn ship_ledger_json; extract_fn shipped_sha; } > "$WS/shipped.sh"
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
echo "── issue #96: un skipped CONDICIONAL no puede dar el mismo rojo que el build"
# El arreglo de #66 sobre-matcheaba: declaraba rojo ante CUALQUIER job saltado.
# Caso medido en campo, un run REAL y sano de un infra-live: el unico saltado
# era un docs-dry-run condicional, con build, notify-kargo y deploy-portal en
# success. El artefacto se construyo y se desplego, y el watcher dijo "no se
# construyo artefacto y NO hay nada que desplegar". Un verificador que grita
# lobo es peor que no tenerlo: el dia que el build de verdad se saltee, ese
# rojo tambien se ignora.
CAMPO='{"jobs":[{"name":"test / test","conclusion":"success"},
{"name":"tag / Semver Tag","conclusion":"success"},
{"name":"docs-dry-run","conclusion":"skipped"},
{"name":"build","conclusion":"success"},
{"name":"notify-kargo","conclusion":"success"},
{"name":"publish-api-docs","conclusion":"success"},
{"name":"deploy-portal","conclusion":"success"}]}'
printf 'project: demo\ndeploy:\n  apollo:\n    driver: actions\n' > "$WS/harness-answers.yaml"
: > "$WS/.harness/events.jsonl"
gh_con_jobs "$CAMPO"
out="$(run676)"; rc=$?
assert_eq 0 "$rc" "el run de campo cierra verde: el build corrio y el deploy es sano"
assert_contains "$out" "✅ actions verde" "y actions se declara verde"
assert_not_contains "$out" "🔴" "un docs-dry-run condicional NO es un rojo"
assert_not_contains "$out" "NO hay nada que desplegar" \
  "y no afirma lo contrario de lo que paso"
# Pero NO se calla: un tramo que no corrio tiene que verse en el log.
assert_contains "$out" "docs-dry-run" "el skipped se nombra igual, sin frenar"
assert_contains "$(bus)" '"ok":true' "y el bus lo cuenta como desplegado"

# CONTRA-MITAD, la que justifica que el chequeo siga existiendo (#66): el
# build saltado sigue siendo rojo aunque haya otros skipped al lado.
: > "$WS/.harness/events.jsonl"
gh_con_jobs '{"jobs":[{"name":"docs-dry-run","conclusion":"skipped"},{"name":"build","conclusion":"skipped"},{"name":"tag","conclusion":"success"}]}'
out="$(run676)"; rc=$?
[ "$rc" -ne 0 ] && pass "build skipped sigue en rojo (con otro skipped al lado)" \
  || fail "el arreglo de #96 apago el gate de #66"
assert_contains "$out" "SKIPPED: build" "y nombra al CRITICO, no a la lista entera"
assert_not_contains "$out" "SKIPPED: docs-dry-run, build" \
  "el condicional no se cuela en el rojo: el rojo es del que construye"

echo
echo "── el token, no la subcadena: build-and-push construye, rebuild-cache no"
: > "$WS/.harness/events.jsonl"
gh_con_jobs '{"jobs":[{"name":"build-and-push","conclusion":"skipped"},{"name":"tag","conclusion":"success"}]}'
out="$(run676)"; rc=$?
[ "$rc" -ne 0 ] && pass "build-and-push saltado es rojo: ES el build de ese pipeline" \
  || fail "build-and-push skipped salio 0"
: > "$WS/.harness/events.jsonl"
gh_con_jobs '{"jobs":[{"name":"build","conclusion":"success"},{"name":"rebuild-cache","conclusion":"skipped"}]}'
out="$(run676)"; rc=$?
assert_eq 0 "$rc" "rebuild-cache saltado no frena: no construye el artefacto"
assert_contains "$out" "✅ actions verde" "y el run cierra verde"

echo
echo "── si NO reconozco quien construye, es ceguera declarada (ni verde ni rojo)"
# El default cubre el nombre mayoritario, no todos. Cuando hay skipped y
# NINGUN job del run se llama como un critico, el watcher no puede afirmar que
# el artefacto se construyo: lo DICE y dice como declararlo, en vez de inventar
# un verde (el falso verde de #66) o un rojo (el falso rojo de #96).
: > "$WS/.harness/events.jsonl"
gh_con_jobs '{"jobs":[{"name":"compile","conclusion":"success"},{"name":"docs","conclusion":"skipped"}]}'
out="$(run676)"; rc=$?
assert_not_contains "$out" "✅ actions verde" "sin job critico reconocible no se canta verde"
assert_not_contains "$out" "🔴" "y tampoco es rojo: no se observo nada roto"
assert_contains "$out" "CEGUERA" "se declara ceguera, con todas las letras"
assert_contains "$out" "critical_jobs" "y dice como declararlo para volver a medir"
assert_not_contains "$(bus)" '"ok":true' "el bus no lo da por desplegado"

echo
echo "── y declarar critical_jobs devuelve la medicion (la perilla del eje)"
printf 'project: demo\ndeploy:\n  apollo:\n    driver: actions\n    critical_jobs: "compile, deploy-portal"\n' \
  > "$WS/harness-answers.yaml"
: > "$WS/.harness/events.jsonl"
gh_con_jobs '{"jobs":[{"name":"compile","conclusion":"skipped"},{"name":"docs","conclusion":"skipped"}]}'
out="$(run676)"; rc=$?
[ "$rc" -ne 0 ] && pass "con critical_jobs declarado, compile saltado ES rojo" \
  || fail "critical_jobs declarado no frena: la perilla no llega al chequeo"
assert_contains "$out" "SKIPPED: compile" "y nombra al job que el humano declaro critico"
: > "$WS/.harness/events.jsonl"
gh_con_jobs '{"jobs":[{"name":"compile","conclusion":"success"},{"name":"docs","conclusion":"skipped"}]}'
out="$(run676)"; rc=$?
assert_eq 0 "$rc" "y con el critico en success, el docs saltado no frena"
assert_contains "$out" "✅ actions verde" "cierra verde"
printf 'project: demo\ndeploy:\n  apollo:\n    driver: actions\n' > "$WS/harness-answers.yaml"
: > "$WS/.harness/events.jsonl"
gh_con_jobs '{"jobs":[{"name":"compile","conclusion":"skipped"},{"name":"docs","conclusion":"skipped"}]}'
export DEPLOY_CRITICAL_JOBS="compile"
out="$(run676)"; rc=$?
unset DEPLOY_CRITICAL_JOBS
[ "$rc" -ne 0 ] && pass "DEPLOY_CRITICAL_JOBS pisa la lista por corrida" \
  || fail "la perilla de entorno no llega al chequeo"
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

# ── y el cierre completo: Synced+Healthy con el ROLLOUT A MEDIAS no es verde ──
# Es el caso de campo entero, de punta a punta: ArgoCD dice que el manifiesto
# aterrizo (y es cierto) y el watcher cerraba 🟢 con un pod viejo sirviendo.
mkdir -p "$WS/k8s"
printf '{"status":{"resources":[{"kind":"Deployment","namespace":"prod","name":"apollo"}]}}\n' > "$WS/k8s/app.json"
printf '%s\n' '{"metadata":{"generation":134},"spec":{"replicas":3,"selector":{"matchLabels":{"app":"apollo"}}},"status":{"observedGeneration":134,"updatedReplicas":2,"readyReplicas":3,"availableReplicas":2}}' > "$WS/k8s/deploy.json"
printf '%s\n' '{"items":[]}' > "$WS/k8s/pods.json"
cat > "$WS/bin/kubectl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"get application "*"-o jsonpath"*) printf 'Synced Healthy $SHA40' ;;
  *"get application "*)  cat "$WS/k8s/app.json" ;;
  *"get deployment"*)    cat "$WS/k8s/deploy.json" ;;
  *"get pods"*)          cat "$WS/k8s/pods.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WS/bin/kubectl"
: > "$WS/.harness/events.jsonl"
out="$(DEPLOY_ROLLOUT_TIMEOUT=1 run676)"; rc=$?
assert_contains "$out" "Healthy + Synced" "el manifiesto SI aterrizo, y se dice"
assert_not_contains "$out" "🟢" "pero con el rollout a medias NO hay verde"
assert_contains "$out" "ROLLOUT NO terminó" "y el motivo es el rollout, no una ceguera de credenciales"
assert_contains "$out" "updated=2" "con los contadores medidos delante"
assert_not_contains "$(bus)" '"ok":true' "ni un deploy ok=true en el panel del humano"
assert_not_contains "$out" "🔴" "no es rojo: nada esta enfermo, esta INCOMPLETO"

# Y con el rollout COMPLETO vuelve a ser verde, y encima uno mas fuerte.
printf '%s\n' '{"metadata":{"generation":134},"spec":{"replicas":2,"selector":{"matchLabels":{"app":"apollo"}}},"status":{"observedGeneration":134,"updatedReplicas":2,"readyReplicas":2,"availableReplicas":2}}' > "$WS/k8s/deploy.json"
# Los pods nacen DESPUES del commit del fixture (que es de ahora mismo): esa es
# justamente la mitad (b) de la condicion, y una fecha del pasado la falsearia.
printf '%s\n' '{"items":[{"metadata":{},"spec":{"containers":[{"image":"apollo:2"}]},"status":{"phase":"Running","containerStatuses":[{"ready":true}],"startTime":"2099-01-01T00:00:00Z"}},{"metadata":{},"spec":{"containers":[{"image":"apollo:2"}]},"status":{"phase":"Running","containerStatuses":[{"ready":true}],"startTime":"2099-01-01T00:00:01Z"}}]}' > "$WS/k8s/pods.json"
: > "$WS/.harness/events.jsonl"
out="$(DEPLOY_ROLLOUT_TIMEOUT=1 run676)"; rc=$?
assert_contains "$out" "🟢 deploy de apollo verificado" "rollout completo: verde legitimo"
assert_contains "$out" "rollout completo en los pods" "y el verde dice que se miraron los PODS"
assert_contains "$(bus)" '"ok":true' "ahi si, deploy ok=true"
rm -f "$WS/bin/kubectl"

echo
echo "── el manifiesto no es el pod: el rollout se mira en los PODS"
# Caso de campo: 🟢 declarado con gen=134 obsGen=134 replicas=3 updated=2
# ready=3 available=2 y un pod viejo Running con la imagen ANTERIOR, o sea un
# tercio del trafico contra el artefacto viejo con el deploy ya dado por bueno.
# Segundo caso, hecho por el propio autor del vigilante: contadores 2/2/2 en
# verde con los pods corriendo la imagen anterior porque el promotor todavia no
# habia movido el tag. Un contador contesta "el rollout que hubiera termino", no
# "mi cambio esta sirviendo".
{ extract_fn rollout_workloads; extract_fn ship_commit_epoch
  extract_fn pods_sirviendo; extract_fn check_rollout; } > "$WS/rollout.sh"
grep -q 'observedGeneration' "$WS/rollout.sh" || { echo "no pude extraer check_rollout"; exit 1; }

# kubectl de palo: contesta el Deployment y los Pods que le pidan, leyendo los
# JSON que cada caso deja en $WS/k8s/.
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")/../k8s"
for a in "$@"; do
  case "$a" in
    deployment) kind=deploy ;;
    pods)       kind=pods ;;
    application) kind=app ;;
  esac
done
[ -f "$d/$kind.json" ] || exit 1
cat "$d/$kind.json"
STUB
chmod +x "$WS/bin/kubectl"
mkdir -p "$WS/k8s"
printf '{"status":{"resources":[{"kind":"Deployment","namespace":"prod","name":"svc-demo"}]}}\n' > "$WS/k8s/app.json"

corre_rollout() {  # corre_rollout → RC=<n> + lo que dijo
  ( export PATH="$WS/bin:$PATH"
    APP=svc-demo; REPO=svc-demo; WS="$WS"; LANDED_SHA=""; ROLLOUT_TIMEOUT=1
    DEPLOY_POLL_SECS=1; ROLLOUT_INCOMPLETO=""
    say() { echo "$1"; }
    acota
    . "$WS/rollout.sh"
    check_rollout; echo "RC=$?"
    printf '%s' "${ROLLOUT_INCOMPLETO:-}" )
}

# (1) el caso del reporte: contadores a medias. Ningun verde.
printf '%s\n' '{"metadata":{"generation":134},"spec":{"replicas":3,"selector":{"matchLabels":{"app":"svc-demo"}}},"status":{"observedGeneration":134,"updatedReplicas":2,"readyReplicas":3,"availableReplicas":2}}' > "$WS/k8s/deploy.json"
printf '%s\n' '{"items":[]}' > "$WS/k8s/pods.json"
out="$(corre_rollout)"
assert_contains "$out" "RC=1" "rollout a medias: NO es verde (updated=2 de 3)"
assert_contains "$out" "updated=2" "y el diagnostico trae los contadores medidos"

# (2) contadores completos pero DOS imagenes entre los pods: el pod viejo sigue
#     sirviendo, y ningun contador lo dice.
printf '%s\n' '{"metadata":{"generation":10},"spec":{"replicas":2,"selector":{"matchLabels":{"app":"svc-demo"}}},"status":{"observedGeneration":10,"updatedReplicas":2,"readyReplicas":2,"availableReplicas":2}}' > "$WS/k8s/deploy.json"
printf '%s\n' '{"items":[{"metadata":{},"spec":{"containers":[{"image":"svc-demo:2.9.2"}]},"status":{"phase":"Running","containerStatuses":[{"ready":true}],"startTime":"2026-08-13T10:00:00Z"}},{"metadata":{},"spec":{"containers":[{"image":"svc-demo:2.9.3"}]},"status":{"phase":"Running","containerStatuses":[{"ready":true}],"startTime":"2026-08-13T11:00:00Z"}}]}' > "$WS/k8s/pods.json"
out="$(corre_rollout)"
assert_contains "$out" "RC=1" "dos imagenes entre los pods: hay uno viejo sirviendo"
assert_contains "$out" "juegos de imagen distintos" "y lo dice con los dos juegos de imagen"

# (3) todo completo y una sola imagen: verde de verdad.
printf '%s\n' '{"items":[{"metadata":{},"spec":{"containers":[{"image":"svc-demo:2.9.3"}]},"status":{"phase":"Running","containerStatuses":[{"ready":true}],"startTime":"2026-08-13T11:00:00Z"}},{"metadata":{},"spec":{"containers":[{"image":"svc-demo:2.9.3"}]},"status":{"phase":"Running","containerStatuses":[{"ready":true}],"startTime":"2026-08-13T11:00:01Z"}}]}' > "$WS/k8s/pods.json"
out="$(corre_rollout)"
assert_contains "$out" "RC=0" "rollout completo con UNA imagen: verde"

# (3b) sidecar: dos imagenes POR POD, iguales en todos. No es un rollout a
#      medias, y mirar una lista suelta de imagenes lo declararia asi para
#      siempre en cualquier instalacion con service mesh.
printf '%s\n' '{"items":[{"metadata":{},"spec":{"containers":[{"image":"svc-demo:2.9.3"},{"image":"proxy:1.20"}]},"status":{"phase":"Running","containerStatuses":[{"ready":true},{"ready":true}],"startTime":"2026-08-13T11:00:00Z"}},{"metadata":{},"spec":{"containers":[{"image":"proxy:1.20"},{"image":"svc-demo:2.9.3"}]},"status":{"phase":"Running","containerStatuses":[{"ready":true},{"ready":true}],"startTime":"2026-08-13T11:00:01Z"}}]}' > "$WS/k8s/pods.json"
out="$(corre_rollout)"
assert_contains "$out" "RC=0" "sidecar identico en todos los pods: sigue siendo un rollout completo"

# (4) contadores completos, UNA imagen, y aun asi los pods son ANTERIORES a mi
#     commit: es el segundo caso de campo (2/2/2 en verde con el promotor sin
#     mover el tag todavia). El rollout que hubiera termino, pero no es el mio.
cat > "$WS/bin/git" <<'STUB'
#!/usr/bin/env bash
echo 4000000000      # un commit del futuro: ningun pod puede ser posterior
STUB
chmod +x "$WS/bin/git"
out="$( export PATH="$WS/bin:$PATH"
        APP=svc-demo; REPO=svc-demo; WS="$WS"; LANDED_SHA=abc123def456; ROLLOUT_TIMEOUT=1
        DEPLOY_POLL_SECS=1; ROLLOUT_INCOMPLETO=""
        say() { echo "$1"; }
        acota
        . "$WS/rollout.sh"
        check_rollout; echo "RC=$?"
        printf '%s' "${ROLLOUT_INCOMPLETO:-}" )"
assert_contains "$out" "RC=1" "pods anteriores a mi commit: el rollout no es el mio"
assert_contains "$out" "ningún pod nació después de tu commit" "y lo dice sin rodeos"
rm -f "$WS/bin/git"

echo
echo "── issue #229: los pods de CronJob YA TERMINADOS no son replicas viejas"
# Caso de campo: el chart declara CronJobs con las MISMAS labels de Helm que el
# Deployment, asi que el selector los trae. 17 pods terminados (ready=false,
# ownerReferences.kind=Job) con las imagenes de tres versiones anteriores, y 2
# replicas sanas en la imagen nueva. El tramo conto "3 juegos de imagen
# distintos" y espero los 300s enteros sobre un rollout que kubectl declaraba
# "successfully rolled out". La ceguera no es un rojo, pero traba la fase igual.
#
# Primero la funcion real, sola, con JSON fijo: es donde vive la decision.
pods_json='{"items":[
 {"metadata":{"name":"svc-demo-1","ownerReferences":[{"kind":"ReplicaSet"}]},
  "spec":{"containers":[{"image":"svc-demo:3.28.3"}]},
  "status":{"phase":"Running","containerStatuses":[{"ready":true}],"startTime":"2026-08-24T10:00:00Z"}},
 {"metadata":{"name":"svc-demo-2","ownerReferences":[{"kind":"ReplicaSet"}]},
  "spec":{"containers":[{"image":"svc-demo:3.28.3"}]},
  "status":{"phase":"Running","containerStatuses":[{"ready":true}],"startTime":"2026-08-24T10:00:01Z"}},
 {"metadata":{"name":"svc-demo-purge-29793395","ownerReferences":[{"kind":"Job"}]},
  "spec":{"containers":[{"image":"svc-demo:3.28.2"}]},
  "status":{"phase":"Succeeded","containerStatuses":[{"ready":false}],"startTime":"2026-08-24T09:00:00Z"}},
 {"metadata":{"name":"svc-demo-watchdog-29793245","ownerReferences":[{"kind":"Job"}]},
  "spec":{"containers":[{"image":"svc-demo:3.28.1"}]},
  "status":{"phase":"Succeeded","containerStatuses":[{"ready":false}],"startTime":"2026-08-24T08:00:00Z"}},
 {"metadata":{"name":"svc-demo-analytics-29792560"},
  "spec":{"containers":[{"image":"svc-demo:3.28.1"}]},
  "status":{"phase":"Failed","containerStatuses":[{"ready":false}],"startTime":"2026-08-23T08:00:00Z"}}
]}'
vivos="$( PATH="$WS/bin:$PATH"; . "$WS/rollout.sh"; pods_sirviendo "$pods_json" )"
assert_eq "2" "$(printf '%s' "$vivos" | jq '.items | length')" \
  "de 5 pods con las mismas labels, solo 2 SIRVEN (los otros ya terminaron)"
assert_eq "1" "$(printf '%s' "$vivos" | jq -r '[.items[].spec.containers[].image] | unique | length')" \
  "y entre esos 2 hay UN solo juego de imagen: no hay ningun pod viejo sirviendo"
assert_not_contains "$vivos" "3.28.1" "la imagen de un Job terminado no cuenta como tráfico"
assert_not_contains "$vivos" "svc-demo-analytics" "un pod Failed sin dueño Job tampoco sirve"

# Y el tramo entero, que es lo que el humano ve: con esos mismos pods tiene que
# cerrar VERDE, no esperar el timeout diciendo "hay uno viejo sirviendo".
printf '%s\n' '{"status":{"resources":[{"kind":"Deployment","namespace":"prod","name":"svc-demo"}]}}' > "$WS/k8s/app.json"
printf '%s\n' '{"metadata":{"generation":10},"spec":{"replicas":2,"selector":{"matchLabels":{"app":"svc-demo"}}},"status":{"observedGeneration":10,"updatedReplicas":2,"readyReplicas":2,"availableReplicas":2}}' > "$WS/k8s/deploy.json"
printf '%s\n' "$pods_json" > "$WS/k8s/pods.json"
start=$(date +%s)
out="$(corre_rollout)"
elapsed=$(( $(date +%s) - start ))
assert_contains "$out" "RC=0" "#229: con los pods de Job descartados, el rollout esta COMPLETO"
assert_not_contains "$out" "juegos de imagen distintos" \
  "#229: y ya no acusa a los pods terminados de ser replicas viejas"
[ "$elapsed" -lt 10 ] && pass "#229: y no espera el timeout entero (${elapsed}s)" \
  || fail "#229: espero ${elapsed}s: sigue contando los pods de Job"

# CONTRA-MITAD: un pod viejo DE VERDAD (Running, ready, de un ReplicaSet) sigue
# delatando el rollout a medias. Si el filtro se comiera este caso, el arreglo
# habria cambiado una ceguera por un falso verde, que es peor.
printf '%s\n' '{"items":[
 {"metadata":{"ownerReferences":[{"kind":"ReplicaSet"}]},"spec":{"containers":[{"image":"svc-demo:3.28.3"}]},
  "status":{"phase":"Running","containerStatuses":[{"ready":true}],"startTime":"2026-08-24T10:00:00Z"}},
 {"metadata":{"ownerReferences":[{"kind":"ReplicaSet"}]},"spec":{"containers":[{"image":"svc-demo:3.28.2"}]},
  "status":{"phase":"Running","containerStatuses":[{"ready":true}],"startTime":"2026-08-24T09:00:00Z"}}
]}' > "$WS/k8s/pods.json"
out="$(corre_rollout)"
assert_contains "$out" "RC=1" "un pod viejo Running y ready SIGUE siendo un rollout a medias"
assert_contains "$out" "juegos de imagen distintos" "y se dice con los dos juegos de imagen"

# Y si NINGUN pod sirve con los contadores en verde, no estamos midiendo lo que
# creemos: eso es ceguera declarada, no un rollout a medias ni un verde.
printf '%s\n' '{"items":[{"metadata":{"ownerReferences":[{"kind":"Job"}]},"spec":{"containers":[{"image":"svc-demo:3.28.1"}]},"status":{"phase":"Succeeded","containerStatuses":[{"ready":false}]}}]}' > "$WS/k8s/pods.json"
out="$(corre_rollout)"
assert_contains "$out" "RC=2" "sin un solo pod sirviendo: ceguera, no un verde inventado"

# (5) sin poder mirar (la app no lista Deployments) es CEGUERA, no rojo: el
#     verde se degrada al del manifiesto, que es la conducta de siempre.
printf '{"status":{"resources":[]}}\n' > "$WS/k8s/app.json"
out="$(corre_rollout)"
assert_contains "$out" "RC=2" "sin workload que mirar: ceguera, no rojo"
rm -f "$WS/bin/kubectl"

echo
echo "── un push dispara VARIOS workflows: se elige el que construye, no el que termina antes"
# Caso de campo: un push disparo `e2e` y `Deploy` con el mismo head sha. Se
# tomaba `.[0]` de la lista, o sea el orden que devuelve la API, se eligio el
# `e2e` (que termina antes) y el watcher canto "actions verde" con `Deploy`
# todavia in_progress: el verde salio 7m41s ANTES de que la imagen existiera.
{ extract_fn job_es_critico; extract_fn run_tiene_critico; extract_fn elige_runs; } > "$WS/elige.sh"
grep -q 'job crítico' "$WS/elige.sh" || { echo "no pude extraer elige_runs"; exit 1; }

mk_gh_runs() {  # mk_gh_runs: gh de palo con dos runs, uno con job critico
  cat > "$WS/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"run view"*"111"*) echo "test-e2e" ;;          # el e2e: ningun job construye
  *"run view"*"222"*) printf 'build
deploy-app
' ;;   # el que despliega
  *) exit 1 ;;
esac
STUB
  chmod +x "$WS/bin/gh"
}
mk_gh_runs
corre_elige() {  # corre_elige [DEPLOY_WORKFLOW=...]
  ( export PATH="$WS/bin:$PATH"
    ORG=acme; REPO=svc-demo; CRITICAL_JOBS=build; LOG="$WS/e.log"
    say() { :; }
    answers_repo_key() { printf ''; }
    acota
    . "$WS/elige.sh"
    elige_runs "111 e2e
222 Deploy" )
}
out="$(corre_elige)"
assert_eq "222" "$out" "elige el run con job critico, no el primero de la lista"

# Y si el humano declaro el workflow, manda esa declaracion (mas explicita).
out="$( export PATH="$WS/bin:$PATH"
        ORG=acme; REPO=svc-demo; CRITICAL_JOBS=build; LOG="$WS/e.log"
        say() { :; }; answers_repo_key() { printf ''; }
        acota; . "$WS/elige.sh"
        DEPLOY_WORKFLOW=e2e elige_runs "111 e2e
222 Deploy" )"
assert_eq "111" "$out" "con DEPLOY_WORKFLOW declarado, manda lo que dijo el humano"

# Dos que construyen: se vigilan los DOS. Esperar a uno solo es el mismo azar.
cat > "$WS/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"run view"*) printf 'build
' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WS/bin/gh"
out="$(corre_elige)"
assert_eq "111 222" "$out" "si dos runs construyen, se vigilan los dos"

# Ninguno reconocible: no se elige a ciegas (la salida vacia dispara la ceguera).
cat > "$WS/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"run view"*) printf 'lint
typecheck
' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WS/bin/gh"
out="$(corre_elige)"
assert_eq "" "$out" "sin job critico en ningun run NO se adivina: se declara ceguera"
# Y el diagnostico no puede ensuciar la salida: la funcion corre dentro de un
# $( ), asi que un `say` a stdout se convierte en un id de run (paso de verdad
# escribiendo este arreglo).
out="$( export PATH="$WS/bin:$PATH"
        ORG=acme; REPO=svc-demo; CRITICAL_JOBS=build; LOG="$WS/e.log"
        say() { echo "RUIDO: $1"; }
        answers_repo_key() { printf ''; }
        acota; . "$WS/elige.sh"
        elige_runs "111 e2e" 2>/dev/null )"
assert_not_contains "$out" "RUIDO" "los mensajes van a stderr: stdout son SOLO ids"
rm -f "$WS/bin/gh"

echo
echo "── flow: prs: lo que el watcher RESUELVE tiene que quedar ESCRITO (#217)"
# `landed` lo escribia ship.sh una sola vez, en false, y nadie lo volvia a
# tocar: POLICY-SHIP-005 bloqueaba deploy y archive PARA SIEMPRE aunque el PR
# hubiera mergeado. La remediacion que el gate imprimia ("re-corre
# deploy-watch, que resuelve el commit real") era justo lo que no funcionaba:
# el watcher resolvia el sha en MEMORIA y salia sin persistir, asi que quien la
# seguia entraba en un bucle y /archive quedaba inalcanzable.
# Desde ship_ledger_write() y no desde LANDED_SHA="": los lectores del ledger (#232)
# son parte del tramo, y sin ellos persistir_landed/resolve_landed_sha no
# encuentran una sola entrada. Se corta en BASE_REF=, que es lo primero que ya
# no es funcion del tramo.
awk '/^ship_ledger_write\(\)/{f=1} /^BASE_REF=/{exit} f{print}' \
  "$ROOT/templates/scripts/deploy-watch.sh.tmpl" > "$WS/landed.sh"
grep -q 'persistir_landed' "$WS/landed.sh" || { echo "no pude extraer el tramo de landed"; exit 1; }
grep -q 'resolve_landed_sha' "$WS/landed.sh" || { echo "falta resolve_landed_sha en el tramo"; exit 1; }

# El forge de mentira: la interfaz real que consume el watcher (forge.sh se
# sourcea en un bash hijo, asi que tiene que ser un archivo de verdad).
mk_forge() {  # mk_forge <sha-mergeado|"">: vacio = el PR sigue abierto
  cat > "$WS/scripts/forge.sh" <<FORGE
forge_pr_merged() { [ -n "$1" ] || return 1; printf '%s' "$1"; }
FORGE
}
mk_shiplog() {  # una tarea de dos repos con flow: prs, los dos sin aterrizar
  mkdir -p "$WS/tasks/T-217"
  rm -f "$WS/tasks/T-217/ship-ledger.jsonl"
  cat > "$WS/tasks/T-217/ship.log" <<'LOG'
{"repo":"docs","sha":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111","short":"aaaa1111aaaa","branch":"task/T-217","pr":"https://x/1","landed":false,"shipped_at":"2026-08-18T00:00:00Z"}
{"repo":"terraform-core","sha":"bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222","short":"bbbb2222bbbb","branch":"task/T-217","pr":"https://x/2","landed":false,"shipped_at":"2026-08-18T00:01:00Z"}
LOG
}
corre_landed() {  # corre_landed <repo> → LANDED_SHA en stdout, diagnosticos aparte
  ( set -uo pipefail
    cd "$WS"; WS="$WS"; TASK=T-217; REPO="$1"
    say() { echo "$1" >&2; }
    emit() { :; }
    acota
    . "$WS/landed.sh"
    resolve_landed_sha; printf '%s' "$LANDED_SHA" ) 2>/dev/null
}
# La lectura del ledger UNE los dos archivos (#232): el viejo primero, el nuevo
# despues, y el ULTIMO registro de un repo es su estado. La escritura, en
# cambio, va SIEMPRE al nuevo, asi que estas dos vistas no son la misma.
ledger() { cat "$WS/tasks/T-217/ship.log" "$WS/tasks/T-217/ship-ledger.jsonl" 2>/dev/null; }
entrada() { ledger | jq -c --arg r "$1" 'select(.repo==$r)' | tail -1; }

mk_shiplog; mk_forge "cccc3333cccc3333cccc3333cccc3333cccc3333"
out="$(corre_landed terraform-core)"
assert_eq "cccc3333cccc3333cccc3333cccc3333cccc3333" "$out" "resuelve el sha que aterrizo (lo que ya hacia)"
assert_eq "true" "$(entrada terraform-core | jq -r '.landed')" \
  "#217: y AHORA lo escribe: landed queda en true"
assert_eq "cccc3333cccc3333cccc3333cccc3333cccc3333" "$(entrada terraform-core | jq -r '.landed_sha')" \
  "con el sha aterrizado"
assert_eq "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222" "$(entrada terraform-core | jq -r '.ship_sha')" \
  "y el que verifico ship.sh conservado: no se pierde la procedencia del gate de evidencia"
assert_eq "landed" "$(entrada terraform-core | jq -r '.event')" "marcada como lo que es, no como un ship"
# Se AGREGA una linea, no se reescribe el archivo: ship.log lo escriben varios
# productores con >> a la vez, y un read-modify-write se come la linea que otro
# agrego en el medio. La entrada original queda intacta como historia.
assert_eq "false" "$(ledger | jq -c 'select(.repo=="terraform-core")' | head -1 | jq -r '.landed')" \
  "la entrada del ship original no se toca"
assert_eq 2 "$(grep -c . "$WS/tasks/T-217/ship.log")" \
  "#232: y el ship.log viejo no crece: la escritura va al ledger nuevo"
assert_eq "false" "$(entrada docs | jq -r '.landed')" \
  "y la del OTRO repo, que no mergeo, tampoco"
assert_eq 3 "$(ledger | grep -c .)" "las dos lineas de antes siguen ahi, mas la nueva"

# Idempotente: una segunda corrida no vuelve a escribir, porque la entrada ya
# dice landed. Un log que crece una linea por corrida seria ruido eterno.
corre_landed terraform-core >/dev/null
assert_eq 3 "$(ledger | grep -c .)" "correrlo de nuevo NO agrega otra linea"

# Segunda corrida: ya no hay nada que preguntarle al forge, y el sha que se
# vigila es el ATERRIZADO, no el de la rama (que es el que quedo en .sha).
mk_forge ""
out="$(corre_landed terraform-core)"
assert_eq "cccc3333cccc3333cccc3333cccc3333cccc3333" "$out" \
  "una entrada ya resuelta vigila el sha aterrizado, no el de la rama"

# El PR que NO mergeo no se marca: el campo dice la verdad en los dos sentidos.
out="$(corre_landed docs)"
assert_eq "" "$out" "sin merge no hay sha que vigilar"
assert_eq "false" "$(entrada docs | jq -r '.landed')" "y landed sigue en false: no se inventa un aterrizaje"

# Varios ships del mismo repo: se marca el ULTIMO, que es el estado de hoy
# (la misma regla que usa repos_not_landed del lado de la policy).
mk_shiplog; mk_forge "dddd4444dddd4444dddd4444dddd4444dddd4444"
cat >> "$WS/tasks/T-217/ship.log" <<'LOG'
{"repo":"docs","sha":"eeee5555eeee5555eeee5555eeee5555eeee5555","short":"eeee5555eeee","branch":"task/T-217b","pr":"https://x/3","landed":false,"shipped_at":"2026-08-18T02:00:00Z"}
LOG
corre_landed docs >/dev/null
assert_eq "false" "$(ledger | jq -c 'select(.repo=="docs")' | head -1 | jq -r '.landed')" \
  "el ship viejo del repo queda como estaba: es historia"
assert_eq "true" "$(entrada docs | jq -r '.landed')" "y el ULTIMO registro del repo es el que manda"
assert_eq "eeee5555eeee5555eeee5555eeee5555eeee5555" "$(entrada docs | jq -r '.ship_sha')" \
  "el aterrizaje se ata al ULTIMO ship, no al primero"

# Y EL REPO SIN DRIVER TAMBIEN REGISTRA. Que este watcher no tenga nada que
# VERIFICAR no significa que no tenga nada que SABER: un repo de docs con
# driver none salia por el early exit ANTES de preguntar por el merge, se
# quedaba en landed:false para siempre, y POLICY-SHIP-005 mira TODOS los repos,
# asi que uno solo dejaba la tarea entera sin deploy ni archive.
echo
echo "── #232: el ledger de ships se lee UNIENDO ship-ledger.jsonl y ship.log"
# ship.log NO era un log: era un ledger JSONL, y su nombre invitaba a la
# redireccion que lo trunca (`ship.sh ... > tasks/<id>/ship.log`). El ship
# aterrizaba, el ledger quedaba en prosa y este watcher se quedaba sin sha que
# vigilar. La contabilidad se mudo a ship-ledger.jsonl. La lectura UNE los dos
# (viejo primero, nuevo despues) y del viejo toma SOLO lo que parsea como JSON;
# la escritura va siempre al nuevo.
mkdir -p "$WS/tasks/T-232"
lee_sha() {  # lee_sha <repo> → lo que el watcher elegiria vigilar
  ( WS="$WS"; TASK=T-232; REPO="$1"; . "$WS/shipped.sh"; shipped_sha )
}

# (1) solo el nombre viejo, limpio: sigue funcionando igual que siempre.
rm -f "$WS/tasks/T-232/ship-ledger.jsonl"
printf '%s\n' \
  '{"repo":"svc-demo","sha":"1111111111111111111111111111111111111111"}' \
  > "$WS/tasks/T-232/ship.log"
assert_eq "1111111111111111111111111111111111111111" "$(lee_sha svc-demo)" \
  "#232: con solo ship.log, el sha sale de ahi (compatibilidad hacia atras)"

# (2) el nombre viejo PISADO por la redireccion: prosa por todos lados y una
#     linea de ledger que sobrevivio. Lo que parsea se usa; lo que no, se tira.
{ echo "── ship de svc-demo ──"
  echo "To https://forge.example/org/svc-demo.git"
  echo "   026c971..b7fd67f  b7fd67f -> main"
  printf '%s\n' '{"repo":"svc-demo","sha":"2222222222222222222222222222222222222222"}'
  echo "✅ shipped svc-demo @ b7fd67f"
  echo '{ esto no es json }'
  echo '"una cadena JSON no es una entrada de ledger"'
} > "$WS/tasks/T-232/ship.log"
assert_eq "2222222222222222222222222222222222222222" "$(lee_sha svc-demo)" \
  "#232: un ship.log con prosa mezclada no ciega al watcher: filtra por linea"

# (3) LA TAREA EN VUELO durante el update, que es el caso que obliga a UNIR y no
#     a elegir: el repo A shippeo ANTES (quedo en el viejo) y el B DESPUES (en el
#     nuevo). Preferir el nuevo dejaria al watcher sin el sha de A, sobre un ship
#     que si ocurrio.
printf '%s\n' \
  '{"repo":"repo-a","sha":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"}' \
  > "$WS/tasks/T-232/ship.log"
printf '%s\n' \
  '{"repo":"repo-b","sha":"bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"}' \
  > "$WS/tasks/T-232/ship-ledger.jsonl"
assert_eq "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111" "$(lee_sha repo-a)" \
  "#232: el ship que quedo en el archivo VIEJO se sigue resolviendo"
assert_eq "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222" "$(lee_sha repo-b)" \
  "#232: y el que fue al nuevo tambien: la lectura une, no elige"
assert_eq "" "$(lee_sha otro-repo)" "y un repo sin ship sigue sin devolver el sha de otro"

# (4) el mismo repo en los DOS archivos: manda el ULTIMO, y el orden de la union
#     es el del update (viejo primero), que es el contrato que ya usa la policy.
printf '%s\n' \
  '{"repo":"repo-a","sha":"cccc3333cccc3333cccc3333cccc3333cccc3333"}' \
  >> "$WS/tasks/T-232/ship-ledger.jsonl"
assert_eq "cccc3333cccc3333cccc3333cccc3333cccc3333" "$(lee_sha repo-a)" \
  "#232: con entradas en los dos, gana la mas nueva (la del ledger nuevo)"

# (5) y lo que el watcher ESCRIBE (#217) va SIEMPRE al archivo nuevo, aunque la
#     entrada que actualiza viva en el viejo: escribir en el viejo seria volver a
#     poner contabilidad donde la redireccion la trunca. La union hace el resto.
mk_forge "ffff6666ffff6666ffff6666ffff6666ffff6666"
printf '%s\n' \
  '{"repo":"svc-demo","sha":"3333333333333333333333333333333333333333","branch":"task/T-232","pr":"https://x/9","landed":false}' \
  > "$WS/tasks/T-232/ship.log"
rm -f "$WS/tasks/T-232/ship-ledger.jsonl"
corre_232() {
  ( set -uo pipefail; cd "$WS"; WS="$WS"; TASK=T-232; REPO=svc-demo
    say() { :; }; emit() { :; }; acota; . "$WS/landed.sh"
    resolve_landed_sha; printf '%s' "$LANDED_SHA" ) 2>/dev/null
}
out="$(corre_232)"
assert_eq "ffff6666ffff6666ffff6666ffff6666ffff6666" "$out" "resuelve el merge del PR"
assert_eq "true" "$(jq -c 'select(.repo=="svc-demo")' "$WS/tasks/T-232/ship-ledger.jsonl" | tail -1 | jq -r '.landed')" \
  "#232: el aterrizaje se registra en ship-ledger.jsonl, aunque el ship viviera en el viejo"
assert_not_contains "$(cat "$WS/tasks/T-232/ship.log")" "landed_sha" \
  "y NO se escribe en el ship.log viejo, que ya no es contabilidad"
assert_eq "3333333333333333333333333333333333333333" \
  "$(jq -c 'select(.repo=="svc-demo")' "$WS/tasks/T-232/ship-ledger.jsonl" | tail -1 | jq -r '.ship_sha')" \
  "conservando la procedencia del ship que estaba en el archivo viejo"
# Y la lectura unida ve el estado nuevo, no el viejo: si no, el watcher volveria
# a preguntarle al forge para siempre.
mk_forge ""
assert_eq "ffff6666ffff6666ffff6666ffff6666ffff6666" "$(corre_232)" \
  "#232: la union toma la entrada mas reciente del repo, que es la que aterrizo"

echo "── #229: sin KUBECONFIG kubectl no habla con ningun cluster, y eso se DICE"
# Caso de campo: cuatro corridas perdidas porque nadie exportaba KUBECONFIG. El
# secreto ya estaba materializado en .secrets.d/kubeconfig; ningun script del
# camino lo exportaba, y los tramos de cluster salian por timeout, que se lee
# igual que un rollout lento.
awk '/^if \[ -z "\$\{KUBECONFIG:-\}" \]/{f=1} f{print} f&&/^fi$/{exit}' \
  "$ROOT/templates/scripts/deploy-watch.sh.tmpl" > "$WS/kubeconf.sh"
grep -q 'export KUBECONFIG' "$WS/kubeconf.sh" \
  || { echo "no pude extraer el bloque de KUBECONFIG"; exit 1; }

mkdir -p "$WS/kcws/.secrets.d"; printf 'apiVersion: v1\n' > "$WS/kcws/.secrets.d/kubeconfig"
# La ruta del tramo extraido se guarda ANTES: el bloque redefine WS a proposito,
# y buscarlo despues lo buscaria dentro del workspace de mentira.
kc_sh="$WS/kubeconf.sh"
got="$( WS="$WS/kcws"; unset KUBECONFIG; . "$kc_sh"; printf '%s' "${KUBECONFIG:-}" )"
assert_eq "$WS/kcws/.secrets.d/kubeconfig" "$got" \
  "#229: sin KUBECONFIG en el entorno, se toma el del workspace"
got="$( WS="$WS/kcws"; KUBECONFIG=/mio/config; . "$kc_sh"; printf '%s' "$KUBECONFIG" )"
assert_eq "/mio/config" "$got" "el que ya viene del entorno NO se pisa"
mkdir -p "$WS/vacio"
got="$( WS="$WS/vacio"; unset KUBECONFIG; . "$kc_sh"; printf '%s' "${KUBECONFIG:-VACIO}" )"
assert_eq "VACIO" "$got" \
  "y sin archivo NO se inventa una ruta (taparia el ~/.kube/config de quien lo tiene)"

# Y si aun asi kubectl no alcanza el cluster, el watcher lo DICE antes de los
# tramos, en vez de dejar que mueran por timeout.
{ extract_fn kubectl_alcanza_cluster; extract_fn kubectl_gate; } > "$WS/kgate.sh"
corre_gate() {
  ( export PATH="$WS/bin:$PATH"
    REPO=svc-demo; KUBE_PROBE=""; CEGUERAS=""
    say() { echo "$1"; }; emit() { echo "BUS: $*"; }
    ciego() { echo "CIEGO: $1"; }
    acota
    . "$WS/kgate.sh"
    kubectl_gate; echo "RC=$?" )
}
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "E0824 memcache.go:265 couldn't get current server API group list" >&2
exit 1
STUB
chmod +x "$WS/bin/kubectl"
out="$(KUBECONFIG="" corre_gate)"
assert_contains "$out" "RC=1" "cluster inalcanzable: el gate lo reporta"
assert_contains "$out" "kubectl no alcanza el cluster" "y lo dice con todas las letras"
assert_contains "$out" "KUBECONFIG" "nombrando la variable que falta"
assert_contains "$out" "with-secrets.sh" "con la remediacion exacta"
assert_contains "$out" "NO es un deploy rojo" "sin convertir la ceguera en un rojo"
assert_contains "$out" "CIEGO:" "y viaja al resumen de cegueras"
assert_contains "$out" "BUS: assumption" "y al ledger de supuestos"

# Un cluster que SI contesta no se lleva ningun aviso: un aviso que muerde de
# mas es un aviso que alguien apaga.
cat > "$WS/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in *--raw*) echo ok ;; *) exit 1 ;; esac
STUB
chmod +x "$WS/bin/kubectl"
out="$(corre_gate)"
assert_contains "$out" "RC=0" "cluster alcanzable: el gate calla"
assert_not_contains "$out" "no alcanza el cluster" "y no inventa una ceguera que no hay"
rm -f "$WS/bin/kubectl"

# Sin kubectl instalado tampoco: ese caso ya tiene su propio mensaje aguas abajo.
out="$( export PATH="$(t_path_without kubectl)"
        REPO=svc-demo; KUBE_PROBE=""; CEGUERAS=""
        say() { echo "$1"; }; emit() { :; }; ciego() { :; }
        acota; . "$WS/kgate.sh"; kubectl_gate; echo "RC=$?" )"
assert_contains "$out" "RC=0" "sin kubectl instalado el gate no habla (no duplica el aviso)"

tmpl="$ROOT/templates/scripts/deploy-watch.sh.tmpl"
salida_l="$(grep -n 'no se verifica con este watcher' "$tmpl" | head -1 | cut -d: -f1)"
resolve_l="$(awk -v n="$salida_l" 'NR<n && /^  resolve_landed_sha \|\| true$/{l=NR} END{print l+0}' "$tmpl")"
[ "${resolve_l:-0}" -gt 0 ] \
  && pass "el repo sin driver resuelve (y registra) el merge ANTES de salir" \
  || fail "el early exit de driver=none sale sin registrar: ese repo no sale nunca de landed:false"

t_done
