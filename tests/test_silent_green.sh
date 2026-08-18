#!/usr/bin/env bash
# test_silent_green.sh: lo que no se pudo verificar NO puede salir verde.
#
# Grupo P1 de la auditoría: siete lugares donde el harness reportaba éxito
# (o "limpio") sin haber verificado nada. Es la forma más cara del defecto
# porque no deja rastro: nadie va a investigar un verde.
#
# La suite prueba el CÓDIGO REAL de los templates, extraído o renderizado.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

echo "── secrets.sh: GCP era la única fuente que no contaba sus fallos"
# Con gcloud sin autenticar, TODAS las claves fallaban, .secrets quedaba vacío
# y el script salía 0 con "✅ secretos materializados". Vault y AWS ya llamaban
# a finish() tres funciones más arriba; GCP ponía un ✅ fijo.

mkdir -p "$WS/bin"
sed -e "s|{{SECRETS_SOURCE}}|gcp-secret-manager|g" \
    -e "s|{{VAULT_ADDR}}|https://vault.example|g" \
    -e "s|{{VAULT_KV_BASE}}|kv/harness|g" \
    -e "s|{{SOPS_FILE}}|secrets.enc.env|g" \
    -e "s|{{VAULT_KEYS}}|  :|g" \
    -e "s|{{GCP_SM_KEYS}}|  dump_sm GH_TOKEN gh-harness-token|g" \
    -e "s|{{AWS_SM_KEYS}}|  :|g" \
    "$ROOT/templates/scripts/secrets.sh.tmpl" > "$WS/secrets.sh"

# gcloud que siempre falla: el caso de la credencial vencida.
printf '#!/usr/bin/env bash\nexit 1\n' > "$WS/bin/gcloud"; chmod +x "$WS/bin/gcloud"
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash secrets.sh pull 2>&1 )"; rc=$?
assert_eq 1 "$rc" "todas las claves fallaron: sale 1, no 0"
assert_contains "$out" "INCOMPLETA" "y lo dice, en vez de '✅ materializados'"
assert_not_contains "$out" "✅ secretos materializados" "no hay verde con .secrets vacío"

# gcloud que responde: el camino feliz no se rompió.
printf '#!/usr/bin/env bash\necho valor-secreto\n' > "$WS/bin/gcloud"; chmod +x "$WS/bin/gcloud"
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash secrets.sh pull 2>&1 )"; rc=$?
assert_eq 0 "$rc" "con la credencial buena: sale 0"
assert_contains "$out" "✅ secretos materializados" "y sí reporta el verde"

echo
echo "── squawk: la migración manda, no la herramienta"
# Sin squawk instalado, el bloque entero se saltaba en silencio aunque el diff
# agregara migraciones: un ALTER bloqueante llegaba a prod por el mismo
# agujero que squawk existe para cerrar.
sh="$(cat "$ROOT/templates/scripts/ship.sh.tmpl")"
assert_contains "$sh" "agrega migraciones SQL y squawk NO está instalado" \
  "avisa cuando hay migraciones y falta la herramienta"
assert_contains "$sh" "migraciones de \$REPO NO lintadas" "y lo emite como supuesto al ledger"
# El orden importa: primero el diff, después la herramienta.
migs_line="$(printf '%s' "$sh" | grep -n 'migs=' | head -1 | cut -d: -f1)"
sq_line="$(printf '%s' "$sh" | grep -n 'command -v squawk' | head -1 | cut -d: -f1)"
[ "$migs_line" -lt "$sq_line" ] \
  && pass "el diff se mira ANTES que la herramienta (si no, el skip vuelve a ser silencioso)" \
  || fail "se sigue preguntando por squawk antes de mirar si hay migraciones"

# Y la señal que el catálogo pide ahora existe de verdad.
assert_contains "$(cat "$ROOT/scripts/discover.sh")" 'signals+=("migrations")' \
  "el discovery emite la señal de migraciones"
assert_contains "$(cat "$ROOT/catalog/capabilities.yaml")" "signal:migrations" \
  "y squawk filtra por ella, no por prosa inverificable"

echo
echo "── actionlint: un workflow es código, y nadie lo compilaba"
# Dos huecos que se juntaban: un repo de workflows reusables no tiene marcador
# de lenguaje, así que caía al aviso NO bloqueante de "stack no reconocido" y
# aterrizaba en main sin verificar una línea, y es el peor repo donde hacerlo,
# porque su producto rompe el CI de QUIEN LO CONSUME por `uses:`. Y un repo CON
# stack tampoco validaba su YAML, porque `go test` no sabe de workflows.
assert_contains "$sh" "toca workflows de GitHub Actions y actionlint NO está instalado" \
  "avisa cuando el cambio toca workflows y falta la herramienta"
assert_contains "$sh" "workflows de \$REPO NO validados" "y lo emite como supuesto al ledger"

# Mismo orden que squawk: primero el diff, después la herramienta. Al revés, sin
# actionlint el bloque entero se salta en silencio.
wfs_line="$(printf '%s' "$sh" | grep -n 'wfs=' | head -1 | cut -d: -f1)"
al_line="$(printf '%s' "$sh" | grep -n 'command -v actionlint' | head -1 | cut -d: -f1)"
[ "$wfs_line" -lt "$al_line" ] \
  && pass "el diff se mira ANTES que la herramienta" \
  || fail "se pregunta por actionlint antes de mirar si el cambio toca workflows"

# El ratchet: solo lo que el cambio TOCÓ. Lintear todo main haría que un ship
# ajeno quede secuestrado por deuda que no introdujo (criterio de buf y squawk).
assert_contains "$sh" 'wfs="$(git diff "origin/$BASE_REF...HEAD" --name-only --diff-filter=ACMR' \
  "solo los workflows del diff, no todo el repo"

# NO enciende LANG_SEEN: lintear YAML de CI no es construir el repo. Si lo
# encendiera, apagaría el aviso de stack no reconocido y cambiaría un silencio
# por otro más difícil de ver. Se mide sobre el bloque extraído, no sobre el
# archivo entero, porque LANG_SEEN=1 aparece legítimamente en otras 15 ramas.
blk="$(awk '/^  local wfs$/{f=1} f{print} f&&/^  fi$/{exit}' "$ROOT/templates/scripts/ship.sh.tmpl")"
assert_contains "$blk" "command -v actionlint" "el bloque del gate se extrae"
assert_not_contains "$blk" "LANG_SEEN=1" \
  "el gate de workflows NO se hace pasar por stack reconocido (el aviso de abajo sigue vivo)"

# Y el gate CORRE de verdad: con actionlint en el PATH y un workflow en el
# diff, se invoca con los archivos del diff; sin él, avisa y NO falla.
run_wf_gate() {  # run_wf_gate <archivos-del-diff> <actionlint-si|no|rojo> → salida
  local diff_out="$1" tool="$2" bin="$WS/wfbin" rc_tool=0
  [ "$tool" = "rojo" ] && rc_tool=1
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/actionlint.args"\necho "build.yml:7:9: property \\"foo\\" is not defined"\nexit %s\n' \
    "$WS" "$rc_tool" > "$bin/actionlint"; chmod +x "$bin/actionlint"
  [ "$tool" = "no" ] && rm -f "$bin/actionlint"
  rm -f "$WS/actionlint.args" "$WS/assumptions.log"
  # git y emit stubeados: lo que se mide es el DIENTE del gate, no el productor
  # del diff. set -euo pipefail porque es el shell real de ship.sh.
  ( set -euo pipefail
    PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin"
    REPO=ci-library; BASE_REF=main
    git() { printf '%s' "$diff_out"; }
    gate() { echo "GATE: $1"; }
    emit() { echo "$*" >> "$WS/assumptions.log"; }
    # shellcheck disable=SC1090
    . "$WS/wfgate.sh" ) 2>&1
}
{ echo 'run_wf_gate_body() {'; printf '%s\n' "$blk"; echo '}'
  echo 'run_wf_gate_body'; } > "$WS/wfgate.sh"

out="$(run_wf_gate '.github/workflows/build.yml
.github/workflows/release.yaml
README.md' si)"; rc=$?
assert_eq 0 "$rc" "con actionlint instalado: el gate corre y sale 0"
assert_contains "$out" "GATE: actionlint (workflows)" "y se anuncia como gate, no como aviso"
args="$(cat "$WS/actionlint.args" 2>/dev/null || echo VACIO)"
assert_contains "$args" ".github/workflows/build.yml" "recibe el .yml del diff"
assert_contains "$args" ".github/workflows/release.yaml" "y también el .yaml (las dos extensiones)"
assert_not_contains "$args" "README.md" "y NADA que no sea un workflow"

out="$(run_wf_gate '.github/workflows/build.yml' no)"; rc=$?
assert_eq 0 "$rc" "sin actionlint: avisa y NO bloquea (no inventa un veredicto)"
assert_contains "$out" "actionlint NO está instalado" "el aviso es explícito"
assert_contains "$(cat "$WS/assumptions.log" 2>/dev/null || true)" \
  "assumption workflows de ci-library NO validados" "y el supuesto nombra al repo"

# LO QUE JUSTIFICA EL GATE: un workflow inválido tiene que CORTAR el ship. Sin
# este caso el test sólo probaría que la herramienta se invoca, que es lo que ya
# hacía el gate roto de al lado: invocar y comerse el rojo.
out="$(run_wf_gate '.github/workflows/build.yml' rojo)"; rc=$?
assert_eq 1 "$rc" "workflow inválido: el gate CORTA (rc != 0), no lo deja pasar"
assert_contains "$out" 'property "foo" is not defined' "y el diagnóstico de actionlint llega al humano"

out="$(run_wf_gate 'main.go
docs/README.md' si)"; rc=$?
assert_eq 0 "$rc" "un cambio que no toca workflows: el gate no dice nada"
assert_not_contains "$out" "actionlint" "ni corre la herramienta ni avisa"
assert_no_file "$WS/actionlint.args" "y no se invocó actionlint"

# Y LOS DOS AVISOS NO PUEDEN CONTRADECIRSE EN LA MISMA CORRIDA. El de abajo (el
# de stack no reconocido) agregaba "Sus workflows SÍ pasaron por actionlint"
# mirando solo si el diff tocaba workflows, así que lo afirmaba también cuando
# actionlint faltaba y el bloque de arriba acababa de avisar lo contrario y de
# emitir el supuesto. Un falso verde textual, en el repo exacto que el gate
# existe para cubrir: el de workflows reusables, que no tiene stack.
blk2="$(awk '/^  if \[ "\$LANG_SEEN" -eq 0 \]; then$/{f=1} f{print} f&&/^  fi$/{exit}' \
  "$ROOT/templates/scripts/ship.sh.tmpl")"
assert_contains "$blk2" "no reconozco el stack" "el bloque del aviso de stack se extrae"
run_ambos() {  # run_ambos <actionlint-si|no> → gate de workflows + aviso de stack, juntos
  { echo 'run_ambos_body() {'; echo '  local LANG_SEEN=0'; printf '%s\n' "$blk"
    printf '%s\n' "$blk2"; echo '}'; echo 'run_ambos_body'; } > "$WS/wfambos.sh"
  run_wf_gate '.github/workflows/build.yml' "$1" >/dev/null 2>&1 || true
  local bin="$WS/wfbin"
  [ "$1" = "no" ] && rm -f "$bin/actionlint"
  ( set -euo pipefail
    PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin"
    REPO=ci-library; BASE_REF=main
    git() { printf '%s' '.github/workflows/build.yml'; }
    gate() { echo "GATE: $1"; }
    emit() { echo "$*" >> "$WS/assumptions.log"; }
    # shellcheck disable=SC1090
    . "$WS/wfambos.sh" ) 2>&1
}
out="$(run_ambos no)"
assert_contains "$out" "actionlint NO está instalado" "sin actionlint: el gate avisa que no validó"
assert_not_contains "$out" "SÍ pasaron por actionlint" \
  "y el aviso de stack NO afirma lo contrario en la misma corrida (era un falso verde de texto)"
out="$(run_ambos si)"
assert_contains "$out" "SÍ pasaron por actionlint" \
  "y con actionlint presente sí lo dice: la aclaración no se perdió, se condicionó"

# La capacidad está en el catálogo y filtra por una señal que discover.sh emite
# de verdad (mismo criterio que squawk: no por prosa inverificable).
assert_contains "$(cat "$ROOT/catalog/capabilities.yaml")" "bin: actionlint" \
  "actionlint está en el catálogo (si no, nadie lo instala y el gate es un aviso perpetuo)"
assert_contains "$(cat "$ROOT/catalog/capabilities.yaml")" "signal:gha" \
  "y filtra por la señal gha"
assert_contains "$(cat "$ROOT/scripts/discover.sh")" 'signals+=("gha")' \
  "que el discovery emite de verdad"

echo
echo "── doctor: la validación del token de Vault ya puede ejecutarse"
# Buscaba vault_addr: en un esquema de answers que NO tiene ese campo, así que
# la validación de vigencia jamás corría: decía "presente (sin validar)" y el
# token muerto aparecía a mitad de pipeline.
doc="$(cat "$ROOT/scripts/doctor.sh")"
assert_not_contains "$doc" "grep -E '^[[:space:]]+vault_addr:'" "ya no lee un campo inexistente"
assert_contains "$doc" 'vaddr="${VAULT_ADDR:-}"' "usa el entorno"
assert_contains "$doc" "export VAULT_ADDR=" "y como respaldo el secrets.sh renderizado de la instancia"
assert_contains "$doc" ".mcp.json FALTA pero" "y avisa si falta .mcp.json con MCPs declarados"

t_done
