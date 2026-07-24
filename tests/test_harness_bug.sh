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
case "${1:-}" in
  api)  printf '{"version":"%s"}\n' "${GH_FAKE_VERSION:-1.0.0}" ;;
  auth) exit 0 ;;
  issue)
    case "${2:-}" in
      list)   printf '%s\n' "${GH_FAKE_DUP:-}" ;;
      create) printf 'https://github.com/andresgarcia29/harness-creator/issues/42\n' ;;
    esac ;;
esac
STUB
chmod +x "$WS/bin/gh"
rm -f "$WS/.harness/upstream-issues.jsonl"
printf 'falla reproducible\n' > "$WS/repro.log"

out="$(cd "$WS" && PATH="$WS/bin:$PATH" $BUG report --title "gate de version" --file scripts/emit.sh --repro repro.log --impact z 2>&1)"; rc=$?
assert_eq 6 "$rc" "instancia 0.99.0 contra upstream 1.0.0: exit 6, no reporta"
assert_contains "$out" "1.0.0" "dice a qué versión actualizar"
assert_no_file "$WS/.harness/upstream-issues.jsonl" "una instancia atrasada no deja rastro en el ledger"

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

echo "── coherencia con el resto del harness"

grep -q "harness-bug.sh" "$ROOT/scripts/doctor.sh" || fail "doctor.sh no vigila harness-bug.sh"
grep -q "harness-bug-report" "$ROOT/scripts/doctor.sh" || fail "doctor.sh no vigila la skill del canal"
grep -q "harness-bug.sh" "$ROOT/templates/CLAUDE.md.tmpl" || fail "la ley 12 no está en CLAUDE.md.tmpl"
grep -q "harness-bug.sh" "$ROOT/templates/AGENTS.md.tmpl" || fail "la ley no está en AGENTS.md.tmpl (multi-herramienta)"
grep -q "harness-bug.sh" "$ROOT/skills/harness-init/SKILL.md" || fail "la tabla de generación no instala harness-bug.sh"
grep -q "harness-bug-report" "$ROOT/skills/harness-init/SKILL.md" || fail "la tabla de generación no instala la skill"
[ -x "$ROOT/templates/scripts/harness-bug.sh" ] && pass "harness-bug.sh ejecutable en el plugin" || fail "harness-bug.sh sin +x (un script sin +x muere en el primer uso)"
bash -n "$ROOT/templates/scripts/harness-bug.sh" && pass "sintaxis válida" || fail "error de sintaxis"

t_done
