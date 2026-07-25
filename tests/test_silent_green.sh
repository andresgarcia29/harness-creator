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
echo "── vuln-watch: un scan que no corrió no es 'limpio', y no toca la baseline"
# El |o| true se tragaba el fallo de osv-scanner; el archivo del día quedaba
# vacío, el detector devolvía 0 = limpio, Y la baseline se sobreescribía con
# ese vacío. Al día siguiente TODAS las vulns preexistentes volvían como
# nuevas y el agente abría una tanda de PRs duplicados.

mkdir -p "$WS/cron/.cache/cron" "$WS/cron/repos"
cp "$ROOT/templates/cronjobs/jobs/vuln-watch.sh" "$WS/cron/"
printf 'CVE-2020-0001 paquete-viejo\n' > "$WS/cron/.cache/cron/vuln-watch.baseline"
base_before="$(cat "$WS/cron/.cache/cron/vuln-watch.baseline")"

run_vuln() {  # run_vuln: corre solo detect() con el osv-scanner que haya en bin
  ( cd "$WS/cron" && PATH="$WS/bin:$PATH" FINDINGS="$WS/cron/findings.txt" \
      bash -c '. ./vuln-watch.sh; detect' ) 2>&1
}

printf '#!/usr/bin/env bash\nexit 127\n' > "$WS/bin/osv-scanner"; chmod +x "$WS/bin/osv-scanner"
out="$(run_vuln)"; rc=$?
[ "$rc" -ne 0 ] && pass "scan fallido: NO devuelve 0 (limpio)" \
  || fail "un scan que no corrió se sigue leyendo como limpio"
assert_contains "$out" "NO toco la baseline" "dice explícitamente que la protege"
assert_eq "$base_before" "$(cat "$WS/cron/.cache/cron/vuln-watch.baseline")" \
  "la baseline sobrevive intacta al scan fallido"

# Scan que sí corre y no encuentra nada: 0 = limpio de verdad.
printf '#!/usr/bin/env bash\necho "{\\"results\\":[]}"\n' > "$WS/bin/osv-scanner"
chmod +x "$WS/bin/osv-scanner"
run_vuln >/dev/null 2>&1
assert_eq 0 $? "scan que corrió sin hallazgos: 0 (el camino feliz sigue)"

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
echo "── rule-miner: la señal de blocking repetidos estaba muerta"
# El grep entregaba UNA línea de un JSON pretty-printed, que no es un
# documento válido: jq fallaba y el 2>/dev/null lo silenciaba, así que la
# señal producía cero líneas SIEMPRE.
rm_src="$(cat "$ROOT/templates/cronjobs/jobs/rule-miner.sh")"
assert_not_contains "$rm_src" "grep -h '\"blocking\"'" "ya no pasa una línea suelta a jq"
mkdir -p "$WS/archive/T1"
cat > "$WS/archive/T1/verdict-atlas.json" <<'JSON'
{
  "schema": 1,
  "blocking": [
    "falta manejo de nil en el handler",
    "el test no cubre el caso vacío"
  ]
}
JSON
n="$(jq -r '.blocking[]? // empty' "$WS/archive"/*/verdict-*.json 2>/dev/null | wc -l | tr -d ' ')"
assert_eq 2 "$n" "jq sobre los archivos SÍ extrae los blocking (el grep daba 0)"

echo
echo "── mutation-sentinel: 'existe npx' no es 'hay herramienta de mutación'"
ms="$(cat "$ROOT/templates/cronjobs/jobs/mutation-sentinel.sh")"
assert_contains "$ms" "mutated=0" "cuenta lo que realmente se mutó"
assert_contains "$ms" "ningún repo se pudo mutar" "y si fue cero, lo dice"
n="$(printf '%s' "$ms" | grep -c 'mutated=1')"
assert_eq 3 "$n" "las tres ramas de mutación (go, python, ts) marcan que corrieron"

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
