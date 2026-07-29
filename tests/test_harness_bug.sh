#!/usr/bin/env bash
# test_harness_bug.sh: el canal de vuelta al plugin contra el código REAL.
# Protege lo que hace que este canal sea señal y no spam: solo artefactos del
# PLUGIN se reportan (los de la instancia no), un archivo parcheado localmente
# no se reporta sin justificación, el repro es obligatorio y no vacío, el
# fingerprint es estable (dedupe), la cuota corta la tormenta, el cuerpo pasa
# por la redacción de secretos, y `off` apaga todo. Nada de red: --dry-run.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/.claude/hooks" "$WS/docs" "$WS/.claude/pipeline" "$WS/.harness"
cp "$ROOT/templates/scripts/harness-bug.sh" "$WS/scripts/"
cp "$ROOT/templates/scripts/emit.sh" "$WS/scripts/"
cp "$ROOT/templates/hooks/block-direct-push.sh" "$WS/.claude/hooks/"
printf '0.99.0\n' > "$WS/.harness-version"
printf 'docs locales\n' > "$WS/docs/quality.md"
printf -- '---\nafter: ship\n---\n' > "$WS/.claude/pipeline/mio.md"
printf 'paso 1: bash -c "scripts/ship.sh --precheck T1 svc"\nsalida: task-id invalido\n' > "$WS/repro.log"

BUG="bash $WS/scripts/harness-bug.sh"
RPT="report --title 'ship.sh --precheck se lee como task-id' --repro repro.log --impact 'toda instancia en macOS'"

echo "── propiedad del artefacto: plugin vs instancia"

out="$(cd "$WS" && $BUG check scripts/emit.sh 2>&1)"; rc=$?
assert_eq 0 "$rc" "un script del plugin es reportable"
assert_contains "$out" "propiedad: plugin" "check nombra la propiedad"

out="$(cd "$WS" && $BUG check docs/quality.md 2>&1)"; rc=$?
assert_eq 3 "$rc" "un doc de la instancia NO es reportable (exit 3)"
out="$(cd "$WS" && $BUG check .claude/pipeline/mio.md 2>&1)"; rc=$?
assert_eq 3 "$rc" "un paso custom es tuyo, no del plugin (exit 3)"
out="$(cd "$WS" && $BUG check .claude/hooks/block-direct-push.sh 2>&1)"; rc=$?
assert_eq 0 "$rc" "un hook del plugin es reportable"

out="$(cd "$WS" && eval "$BUG $RPT --file docs/quality.md --dry-run" 2>&1)"; rc=$?
assert_eq 3 "$rc" "report sobre artefacto de la instancia: exit 3"

echo "── el repro es obligatorio y no vacío"

out="$(cd "$WS" && $BUG report --title x --file scripts/emit.sh --impact y --dry-run 2>&1)"; rc=$?
assert_eq 4 "$rc" "sin --repro: exit 4"
: > "$WS/vacio.log"
out="$(cd "$WS" && $BUG report --title x --file scripts/emit.sh --repro vacio.log --impact y --dry-run 2>&1)"; rc=$?
assert_eq 4 "$rc" "repro vacío: exit 4"
out="$(cd "$WS" && $BUG report --title x --file scripts/emit.sh --repro repro.log --dry-run 2>&1)"; rc=$?
assert_eq 1 "$rc" "sin --impact (a quién más le pasa): exit 1"

echo "── drift local: upstream no reproduce tu parche"

# CLAUDE_PLUGIN_ROOT presente → comparación real contra el template
out="$(cd "$WS" && CLAUDE_PLUGIN_ROOT="$ROOT" eval "$BUG $RPT --file scripts/emit.sh --dry-run" 2>&1)"; rc=$?
assert_eq 0 "$rc" "idéntico al template: procede"
assert_contains "$out" "template: igual" "el cuerpo declara la comparación"
printf '\n# parche local\n' >> "$WS/scripts/emit.sh"
out="$(cd "$WS" && CLAUDE_PLUGIN_ROOT="$ROOT" eval "$BUG $RPT --file scripts/emit.sh --dry-run" 2>&1)"; rc=$?
assert_eq 7 "$rc" "archivo parcheado localmente: exit 7"
out="$(cd "$WS" && CLAUDE_PLUGIN_ROOT="$ROOT" eval "$BUG $RPT --file scripts/emit.sh --dry-run --force" 2>&1)"; rc=$?
assert_eq 7 "$rc" "--force sin --justification sobre drift: sigue bloqueado"
out="$(cd "$WS" && CLAUDE_PLUGIN_ROOT="$ROOT" eval "$BUG $RPT --file scripts/emit.sh --dry-run --force --justification 'el parche es un comentario'" 2>&1)"; rc=$?
assert_eq 0 "$rc" "--force con justificación: procede y la deja en el cuerpo"
assert_contains "$out" "Justificación del drift local" "la justificación viaja en el issue"
cp "$ROOT/templates/scripts/emit.sh" "$WS/scripts/emit.sh"

echo "── el cuerpo: redactado, con fingerprint estable"

printf 'export GH_TOKEN=ghp_%s\nfalla aquí\n' "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" > "$WS/repro.log"
out="$(cd "$WS" && eval "$BUG $RPT --file scripts/emit.sh --dry-run" 2>&1)"
assert_not_contains "$out" "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "el token del repro NO viaja al issue"
assert_contains "$out" "REDACTADO" "la redacción se aplicó"
assert_contains "$out" "0.99.0" "el cuerpo declara la versión de la instancia"
fp1="$(echo "$out" | grep -o 'harness-fp: [0-9a-f]*' | awk '{print $2}')"
out2="$(cd "$WS" && eval "$BUG $RPT --file scripts/emit.sh --dry-run" 2>&1)"
fp2="$(echo "$out2" | grep -o 'harness-fp: [0-9a-f]*' | awk '{print $2}')"
assert_eq "$fp1" "$fp2" "fingerprint estable entre corridas (dedupe posible)"
out3="$(cd "$WS" && $BUG report --title "otro bug distinto" --file scripts/emit.sh --repro repro.log --impact z --dry-run 2>&1)"
fp3="$(echo "$out3" | grep -o 'harness-fp: [0-9a-f]*' | awk '{print $2}')"
[ -n "$fp1" ] && [ "$fp1" != "$fp3" ] && pass "otro título, otro fingerprint" || fail "fingerprints colisionan"

echo "── la huella NO depende del locale (si no, macOS y Linux nunca reconcilian)"

# La reconciliación post-create compara huellas literales contra las que escribió
# OTRA máquina. La normalización del título usa `tr`, y ahí GNU trabaja byte a
# byte mientras BSD respeta LC_CTYPE: un título con acentos daba huellas
# distintas en macOS y en Linux, así que la misma falla jamás se reconocía entre
# máquinas. La normalización tiene que ser de bytes en las dos.
fp_loc() {  # fp_loc <locale> <título>
  (cd "$WS" && LC_ALL="$1" LANG="$1" $BUG report --title "$2" --file scripts/emit.sh \
      --repro repro.log --impact z --dry-run 2>&1) | grep -o 'harness-fp: [0-9a-f]*' | awk '{print $2}'
}
acc='la versión del sello no existía'
locale -a > "$WS/locales.txt" 2>"$WS/locales.err"
utf8=""
for cand in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8 es_ES.UTF-8; do
  if grep -qx "$cand" "$WS/locales.txt"; then utf8="$cand"; break; fi
done
if [ -n "$utf8" ]; then
  assert_eq "$(fp_loc C "$acc")" "$(fp_loc "$utf8" "$acc")" \
    "el título acentuado da la MISMA huella bajo C y bajo $utf8"
  # Y la normalización tiene que ser la de BYTES, no la del locale del que
  # reporta: en bytes cada acento es un par no-alfanumérico que colapsa a UN
  # espacio, así que el título acentuado y el mismo título ya "descosido" caen
  # en la misma huella. Fijar solo "las dos coinciden" dejaría pasar un arreglo
  # que forzara UTF-8 en todas partes, y ese vuelve a depender de qué locales
  # tenga instalados cada máquina.
  assert_eq "$(fp_loc "$utf8" "$acc")" "$(fp_loc "$utf8" 'la versi n del sello no exist a')" \
    "los acentos se normalizan por bytes, no por el locale de quien reporta"
else
  # Tercer estado: sin un locale UTF-8 instalado esta máquina no puede ni
  # producir la divergencia. Se dice, no se pinta de verde.
  echo "  ! no pude mirar: esta máquina no ofrece ningún locale UTF-8 conocido; la comparación entre locales queda sin correr"
  head -1 "$WS/locales.err"
fi

echo "── dedupe local y cuota"

printf '{"ts":"x","epoch":%s,"fp":"%s","file":"scripts/emit.sh","url":"https://github.com/x/y/issues/1","status":"creado"}\n' \
  "$(date +%s)" "$fp1" > "$WS/.harness/upstream-issues.jsonl"
out="$(cd "$WS" && eval "$BUG $RPT --file scripts/emit.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "fp ya reportado: no duplica (exit 0)"
assert_contains "$out" "ya reportado" "dice que ya estaba reportado"
assert_contains "$out" "issues/1" "y da la URL del issue previo"

now="$(date +%s)"
for i in 1 2 3; do
  printf '{"ts":"x","epoch":%s,"fp":"deadbeef%s","file":"scripts/x.sh","url":"u","status":"creado"}\n' "$now" "$i" \
    >> "$WS/.harness/upstream-issues.jsonl"
done
out="$(cd "$WS" && $BUG report --title "bug nuevo del dia" --file scripts/emit.sh --repro repro.log --impact z --dry-run 2>&1)"; rc=$?
assert_eq 5 "$rc" "cuota de 24h agotada: exit 5"
# fuera de la ventana de 24h la cuota se libera
sed_tmp="$WS/.harness/l2.jsonl"
awk -v old="$(( now - 200000 ))" '{sub(/"epoch":[0-9]+/, "\"epoch\":" old); print}' \
  "$WS/.harness/upstream-issues.jsonl" > "$sed_tmp" && mv "$sed_tmp" "$WS/.harness/upstream-issues.jsonl"
out="$(cd "$WS" && $BUG report --title "bug nuevo del dia" --file scripts/emit.sh --repro repro.log --impact z --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "reportes de hace >24h no consumen cuota"

echo "── el canal se puede apagar"

out="$(cd "$WS" && HARNESS_UPSTREAM_ISSUES=off eval "$BUG $RPT --file scripts/emit.sh --dry-run" 2>&1)"; rc=$?
assert_eq 8 "$rc" "HARNESS_UPSTREAM_ISSUES=off: exit 8, no publica"
printf 'upstream_issues: off\n' > "$WS/harness-answers.yaml"
out="$(cd "$WS" && eval "$BUG $RPT --file scripts/emit.sh --dry-run" 2>&1)"; rc=$?
assert_eq 8 "$rc" "upstream_issues: off en answers: exit 8"
rm -f "$WS/harness-answers.yaml"

echo "── instancia atrasada y publicación (gh de mentira, cero red)"

mkdir -p "$WS/bin"
cat > "$WS/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Cada invocación queda anotada en $GH_CALLS: sin ese contador, "el claim corta
# antes de la red" solo se podría afirmar leyendo el código, que es justo lo que
# un test existe para no tener que hacer.
if [ -n "${GH_CALLS:-}" ]; then printf '%s\n' "$*" >> "$GH_CALLS"; fi
case "${1:-}" in
  api)  printf '{"version":"%s"}\n' "${GH_FAKE_VERSION:-1.0.0}" ;;
  auth) exit 0 ;;
  issue)
    case "${2:-}" in
      list)
        # Hay DOS listados con formas distintas: el dedupe previo pide --json url
        # y la reconciliación pide --json number,body. Responderles lo mismo haría
        # pasar los tests por el motivo equivocado.
        case "$*" in
          *number,body*)
            if [ "${GH_FAKE_LIST_FAIL:-0}" = 1 ]; then
              echo "gh: no pude listar los issues (stub)" >&2; exit 1
            fi
            printf '%s\n' "${GH_FAKE_RIVALS:-[]}" ;;
          *) printf '%s\n' "${GH_FAKE_DUP:-}" ;;
        esac ;;
      create) printf '%s\n' "${GH_FAKE_NEW:-https://github.com/andresgarcia29/harness-creator/issues/42}" ;;
      close)
        if [ "${GH_FAKE_CLOSE_FAIL:-0}" = 1 ]; then
          echo "gh: no pude cerrar el issue (stub)" >&2; exit 1
        fi
        printf 'cerrado #%s\n' "${3:-?}" ;;
    esac ;;
esac
STUB
chmod +x "$WS/bin/gh"

# La huella la calcula el script, no el test: pedírsela con --dry-run (que no
# toca la red ni toma claim) evita reimplementar el hash acá y que el test siga
# verde el día que la fórmula cambie.
fp_of() {  # fp_of <título>
  (cd "$WS" && $BUG report --title "$1" --file scripts/emit.sh --repro repro.log \
      --impact z --dry-run 2>&1) | grep -o 'harness-fp: [0-9a-f]*' | awk '{print $2}'
}
gh_calls() { wc -l < "$WS/calls.log" | tr -d ' '; }
# Por encima de cualquier pid_max de macOS o Linux: `kill -0` responde "no
# existe" sin riesgo de pegarle a un proceso real reciclado.
DEAD_PID=2147483647
rm -f "$WS/.harness/upstream-issues.jsonl"
printf 'falla reproducible\n' > "$WS/repro.log"

out="$(cd "$WS" && PATH="$WS/bin:$PATH" $BUG report --title "gate de version" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 6 "$rc" "instancia 0.99.0 contra upstream 1.0.0: exit 6, no reporta"
assert_contains "$out" "1.0.0" "dice a qué versión actualizar"
assert_no_file "$WS/.harness/upstream-issues.jsonl" "una instancia atrasada no deja rastro en el ledger"
# El claim se toma ANTES del gate de versión (el gate ya es una llamada de red).
# Si el gate mata el reporte no se publicó nada, así que el claim TIENE que
# quedar suelto: uno pegado dejaría ese bug intocable para siempre.
assert_no_file "$WS/.harness/claims/$(fp_of 'gate de version').lock.d" "un reporte que muere en un gate suelta su claim"

out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_FAKE_VERSION=0.99.0 $BUG report --title "bug de verdad en el bus" --file scripts/emit.sh --repro repro.log --impact "toda instancia" 2>&1)"; rc=$?
assert_eq 0 "$rc" "instancia al día: publica"
assert_contains "$out" "issues/42" "devuelve la URL del issue creado"
assert_file "$WS/.harness/upstream-issues.jsonl" "queda registrado en el ledger local"
assert_eq "creado" "$(jq -r .status "$WS/.harness/upstream-issues.jsonl" | tail -1)" "el ledger registra el estado"

out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_FAKE_VERSION=0.99.0 $BUG report --title "bug de verdad en el bus" --file scripts/emit.sh --repro repro.log --impact "toda instancia" 2>&1)"
assert_contains "$out" "ya reportado" "el mismo bug no se reporta dos veces"

rm -f "$WS/.harness/upstream-issues.jsonl"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_FAKE_VERSION=0.99.0 GH_FAKE_DUP="https://github.com/x/y/issues/7" $BUG report --title "ya reportado por otro" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 0 "$rc" "dedupe remoto: no crea un segundo issue"
assert_contains "$out" "issues/7" "apunta al issue que ya existe upstream"
assert_eq "duplicado" "$(jq -r .status "$WS/.harness/upstream-issues.jsonl" | tail -1)" "el ledger lo marca duplicado"

echo "── claim local: dos sesiones de la MISMA máquina no llegan las dos a la red"

# El escenario del hallazgo: diez sesiones tropiezan con el mismo bug del plugin
# y las diez pasan los tres controles antes de que la primera escriba el ledger.
# Acá se simula la segunda: el claim de la primera está tomado y vivo.
rm -f "$WS/.harness/upstream-issues.jsonl"
rm -rf "$WS/.harness/claims"
fpc="$(fp_of 'carrera local entre sesiones')"
if [ -n "$fpc" ]; then pass "la huella de la carrera local es legible"; else fail "no pude leer la huella del dry-run"; fi
mkdir -p "$WS/.harness/claims/$fpc.lock.d"
printf '%s\n' "$$" > "$WS/.harness/claims/$fpc.lock.d/pid"   # el pid del test: vivo de verdad
: > "$WS/calls.log"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_CALLS="$WS/calls.log" GH_FAKE_VERSION=0.99.0 \
  $BUG report --title "carrera local entre sesiones" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 0 "$rc" "claim ajeno vivo: la segunda sesión no es un error, simplemente no duplica"
assert_contains "$out" "otra sesión de esta máquina" "declara por qué no publicó"
assert_eq 0 "$(gh_calls)" "CERO llamadas a gh: el claim corta antes de la red, no después"
assert_no_file "$WS/.harness/upstream-issues.jsonl" "la sesión que no publicó tampoco escribe el ledger"
assert_file "$WS/.harness/claims/$fpc.lock.d/pid" "y no le roba el claim al dueño vivo"

echo "── claim huérfano: se recupera si guarda url, y si no, tercer estado"

rm -rf "$WS/.harness/claims"
fpo="$(fp_of 'publicado sin ledger')"
mkdir -p "$WS/.harness/claims/$fpo.lock.d"
printf '%s\n' "$DEAD_PID" > "$WS/.harness/claims/$fpo.lock.d/pid"
printf 'https://github.com/andresgarcia29/harness-creator/issues/11\n' > "$WS/.harness/claims/$fpo.lock.d/url"
: > "$WS/calls.log"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_CALLS="$WS/calls.log" GH_FAKE_VERSION=0.99.0 \
  $BUG report --title "publicado sin ledger" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 0 "$rc" "claim huérfano CON url: el issue ya existe, no hay nada que publicar"
assert_contains "$out" "issues/11" "y dice cuál es"
assert_eq 0 "$(gh_calls)" "sin red: la url del claim ya responde la pregunta"
assert_eq "recuperado" "$(jq -r .status "$WS/.harness/upstream-issues.jsonl" | tail -1)" "el ledger se repara con lo que el claim sabía"

rm -f "$WS/.harness/upstream-issues.jsonl"
rm -rf "$WS/.harness/claims"
fpu="$(fp_of 'murio a mitad de camino')"
mkdir -p "$WS/.harness/claims/$fpu.lock.d"
printf '%s\n' "$DEAD_PID" > "$WS/.harness/claims/$fpu.lock.d/pid"
: > "$WS/calls.log"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_CALLS="$WS/calls.log" GH_FAKE_VERSION=0.99.0 \
  $BUG report --title "murio a mitad de camino" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 9 "$rc" "claim huérfano SIN url: no se sabe si publicó, y ante la duda no se publica"
assert_contains "$out" "no publico a ciegas" "lo declara como el tercer estado que es"
assert_contains "$out" "rm -rf" "y dice exactamente cómo destrabarlo"
assert_eq 0 "$(gh_calls)" "tampoco toca la red para adivinar"
assert_no_file "$WS/.harness/upstream-issues.jsonl" "no inventa una entrada de ledger"

echo "── reconciliación post-create: entre máquinas gana el número MENOR"

# Ningún lock local cierra la carrera entre dos máquinas: solo el forge las ve a
# las dos, y ahí el número de issue es el único orden total compartido.
rm -f "$WS/.harness/upstream-issues.jsonl"
rm -rf "$WS/.harness/claims"
fpr="$(fp_of 'carrera entre maquinas')"
rivals="$(printf '[{"number":3,"body":"otro bug <!-- harness-fp: deadbeefcafe -->"},{"number":7,"body":"el mismo bug desde otra maquina <!-- harness-fp: %s -->"},{"number":42,"body":"el mio <!-- harness-fp: %s -->"}]' "$fpr" "$fpr")"
: > "$WS/calls.log"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_CALLS="$WS/calls.log" GH_FAKE_VERSION=0.99.0 GH_FAKE_RIVALS="$rivals" \
  $BUG report --title "carrera entre maquinas" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 0 "$rc" "reconciliar no convierte un reporte bueno en un fallo"
assert_contains "$out" "issues/7" "nombra al superviviente"
closed="$(grep '^issue close' "$WS/calls.log")"
assert_contains "$closed" "issue close 42" "cierra el SUYO (#42), jamás el del rival"
assert_contains "$closed" "issues/7" "el comentario del cierre enlaza al superviviente"
assert_eq "reconciliado" "$(jq -r .status "$WS/.harness/upstream-issues.jsonl" | tail -1)" "el ledger declara la reconciliación"
assert_eq "https://github.com/andresgarcia29/harness-creator/issues/7" \
  "$(jq -r .url "$WS/.harness/upstream-issues.jsonl" | tail -1)" "y registra al superviviente como el issue del bug"
assert_eq "https://github.com/andresgarcia29/harness-creator/issues/42" \
  "$(jq -r '.superseded // ""' "$WS/.harness/upstream-issues.jsonl" | tail -1)" "sin perder cuál cedió"

rm -f "$WS/.harness/upstream-issues.jsonl"
rm -rf "$WS/.harness/claims"
fps="$(fp_of 'sin rival en el forge')"
: > "$WS/calls.log"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_CALLS="$WS/calls.log" GH_FAKE_VERSION=0.99.0 \
  GH_FAKE_RIVALS="$(printf '[{"number":3,"body":"otro bug <!-- harness-fp: deadbeefcafe -->"},{"number":42,"body":"el mio <!-- harness-fp: %s -->"}]' "$fps")" \
  $BUG report --title "sin rival en el forge" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 0 "$rc" "sin rival: el reporte sigue siendo bueno"
assert_contains "$out" "ningún issue abierto más viejo" "lo dice en voz alta"
assert_not_contains "$(cat "$WS/calls.log")" "issue close" "no cierra nada: una huella ajena no es un duplicado"
assert_eq "creado" "$(jq -r .status "$WS/.harness/upstream-issues.jsonl" | tail -1)" "el mío queda como el issue del bug"

rm -f "$WS/.harness/upstream-issues.jsonl"
rm -rf "$WS/.harness/claims"
: > "$WS/calls.log"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_CALLS="$WS/calls.log" GH_FAKE_VERSION=0.99.0 GH_FAKE_LIST_FAIL=1 \
  $BUG report --title "la relectura se cae" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 0 "$rc" "relectura caída: el issue ya está creado, eso no se deshace"
assert_contains "$out" "NO cierro nada" "no cierra a ciegas: peor es cerrar el issue equivocado"
assert_contains "$out" "no pude listar los issues (stub)" "y cuenta el motivo que dio gh, sin tragárselo"
assert_not_contains "$(cat "$WS/calls.log")" "issue close" "cero cierres cuando no se pudo mirar"
assert_eq "creado" "$(jq -r .status "$WS/.harness/upstream-issues.jsonl" | tail -1)" "el ledger no inventa un superviviente"

echo "── la cuota cuenta ISSUES ABIERTOS, no filas del ledger"

# Un solo evento deja VARIAS filas: crear y después ceder ante otra máquina son
# dos, y `recuperado` no abrió nada en absoluto. Contando filas, dos reportes
# reales gastaban la cuota de tres y el tercero moría por una tormenta que nunca
# existió (exit 5 con dos issues creados).
rm -f "$WS/.harness/upstream-issues.jsonl"
rm -rf "$WS/.harness/claims"
fpq="$(fp_of 'un evento que se reconcilia')"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_FAKE_VERSION=0.99.0 \
  GH_FAKE_RIVALS="$(printf '[{"number":7,"body":"mismo bug desde otra maquina <!-- harness-fp: %s -->"}]' "$fpq")" \
  $BUG report --title "un evento que se reconcilia" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 0 "$rc" "el reporte que cede ante otra máquina sigue siendo exitoso"
assert_eq 2 "$(wc -l < "$WS/.harness/upstream-issues.jsonl" | tr -d ' ')" "ese ÚNICO evento dejó dos filas (creado + reconciliado)"

rm -rf "$WS/.harness/claims"
fpv="$(fp_of 'recuperado del claim ajeno')"
mkdir -p "$WS/.harness/claims/$fpv.lock.d"
printf '%s\n' "$DEAD_PID" > "$WS/.harness/claims/$fpv.lock.d/pid"
printf 'https://github.com/andresgarcia29/harness-creator/issues/11\n' > "$WS/.harness/claims/$fpv.lock.d/url"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_FAKE_VERSION=0.99.0 \
  $BUG report --title "recuperado del claim ajeno" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"
assert_eq 3 "$(wc -l < "$WS/.harness/upstream-issues.jsonl" | tr -d ' ')" "el recuperado suma una tercera fila sin abrir ningún issue"

out="$(cd "$WS" && $BUG report --title "el tercer bug del dia" --file scripts/emit.sh --repro repro.log --impact z --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "tres filas pero UN issue abierto: la cuota consumida es 1, no 3"

now2="$(date +%s)"
for i in 1 2; do
  printf '{"ts":"x","epoch":%s,"fp":"beefcafe%s","file":"scripts/x.sh","url":"u","status":"creado"}\n' "$now2" "$i" \
    >> "$WS/.harness/upstream-issues.jsonl"
done
out="$(cd "$WS" && $BUG report --title "el cuarto bug del dia" --file scripts/emit.sh --repro repro.log --impact z --dry-run 2>&1)"; rc=$?
assert_eq 5 "$rc" "tres issues ABIERTOS de verdad: ahí sí corta (exit 5)"

echo "── el claim que no se pudo ni intentar es otro problema, con otro exit"

# Exit 9 es "había un claim y no sé qué pasó con él": se remedia mirando el forge
# y borrando el claim. Esto otro es "no hay dónde poner el claim": se remedia
# arreglando el directorio. Un solo código para las dos manda a la mitad de la
# gente a buscar un claim que no existe.
rm -f "$WS/.harness/upstream-issues.jsonl"
rm -rf "$WS/.harness/claims"
: > "$WS/.harness/claims"    # un archivo donde el script necesita un directorio
: > "$WS/calls.log"
out="$(cd "$WS" && PATH="$WS/bin:$PATH" GH_CALLS="$WS/calls.log" GH_FAKE_VERSION=0.99.0 \
  $BUG report --title "claims ocupado por un archivo" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 10 "$rc" "no pude tomar el claim: exit 10, distinto del huérfano (9)"
assert_contains "$out" "no pude tomar el claim local" "declara que el candado falló, no que hubo carrera"
assert_contains "$out" "directorio escribible" "y manda a arreglar el directorio, no a buscar en el forge"
assert_eq 0 "$(gh_calls)" "sin claim tampoco toca la red"
assert_no_file "$WS/.harness/upstream-issues.jsonl" "ni deja rastro en el ledger"
rm -f "$WS/.harness/claims"

echo "── la remediación del claim huérfano es copiable aunque la ruta tenga espacios"

# El mensaje del exit 9 es un comando para copiar y pegar. Sin comillas, un
# workspace con espacios lo convierte en un `rm -rf` de DOS rutas, y ninguna de
# las dos es la que se quería borrar.
WS2="$WS/ruta con espacios"
mkdir -p "$WS2/scripts" "$WS2/.harness"
cp "$ROOT/templates/scripts/harness-bug.sh" "$WS2/scripts/"
cp "$ROOT/templates/scripts/emit.sh" "$WS2/scripts/"
printf '0.99.0\n' > "$WS2/.harness-version"
printf 'falla reproducible\n' > "$WS2/repro.log"
# La huella es file|título: no depende del workspace, así que se calcula acá.
fpe="$(fp_of 'claim huerfano en ruta con espacios')"
mkdir -p "$WS2/.harness/claims/$fpe.lock.d"
printf '%s\n' "$DEAD_PID" > "$WS2/.harness/claims/$fpe.lock.d/pid"
out="$(cd "$WS2" && PATH="$WS/bin:$PATH" GH_FAKE_VERSION=0.99.0 \
  bash "$WS2/scripts/harness-bug.sh" report --title "claim huerfano en ruta con espacios" \
  --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 9 "$rc" "claim huérfano sin url en ruta con espacios: sigue siendo exit 9"
assert_contains "$out" "rm -rf '$WS2/.harness/claims/$fpe.lock.d'" "el rm -rf sugerido va entrecomillado, con la ruta entera adentro"

echo "── coherencia con el resto del harness"

grep -q "harness-bug.sh" "$ROOT/scripts/doctor.sh" || fail "doctor.sh no vigila harness-bug.sh"
grep -q "harness-bug-report" "$ROOT/scripts/doctor.sh" || fail "doctor.sh no vigila la skill del canal"
grep -q "harness-bug.sh" "$ROOT/templates/CLAUDE.md.tmpl" || fail "la ley 12 no está en CLAUDE.md.tmpl"
grep -q "harness-bug.sh" "$ROOT/templates/AGENTS.md.tmpl" || fail "la ley no está en AGENTS.md.tmpl (multi-herramienta)"
grep -q "harness-bug.sh" "$ROOT/skills/harness-init/SKILL.md" || fail "la tabla de generación no instala harness-bug.sh"
grep -q "harness-bug-report" "$ROOT/skills/harness-init/SKILL.md" || fail "la tabla de generación no instala la skill"
# El contrato de exits vive en la skill: el agente decide qué hacer leyéndolo,
# no leyendo el código. Un exit sin documentar es un agente adivinando.
SK="$ROOT/templates/skills/harness-bug-report/SKILL.md"
grep -q "claim huérfano (9)" "$SK" || fail "la skill no documenta el exit 9 (claim huérfano)"
grep -q "(10)" "$SK" || fail "la skill no documenta el exit 10 (no pude tomar el claim)"
[ -x "$ROOT/templates/scripts/harness-bug.sh" ] && pass "harness-bug.sh ejecutable en el plugin" || fail "harness-bug.sh sin +x (un script sin +x muere en el primer uso)"
bash -n "$ROOT/templates/scripts/harness-bug.sh" && pass "sintaxis válida" || fail "error de sintaxis"

t_done
