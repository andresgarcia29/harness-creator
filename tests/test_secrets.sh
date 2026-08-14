#!/usr/bin/env bash
# test_secrets.sh: el despacho de secrets.sh contra el TEMPLATE real.
# Protege el issue #21 (pull_pull_vault): la fuente se resuelve por VALOR, no
# por un nombre de función interpolado, así que ni el valor del answers ni el
# alias histórico ni un generador despistado pueden producir un
# "command not found" en la primera instalación. Cero red: CLIs de mentira.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/bin"
for c in vault gcloud aws doppler sops op; do
  printf '#!/bin/sh\necho "LLAMADO:%s $*" >> "$CALLS"\nexit 0\n' "$c" > "$WS/bin/$c"
  chmod +x "$WS/bin/$c"
done
export CALLS="$WS/calls.log"

# instancia el template como lo haría el generador, con una clave de ejemplo
# por fuente para que cada rama llegue de verdad a su CLI
gen() {  # gen <valor de SECRETS_SOURCE>
  sed -e "s|{{SECRETS_SOURCE}}|$1|g" \
      -e "s|{{VAULT_ADDR}}|https://vault.example|g" \
      -e "s|{{VAULT_KV_BASE}}|kv/harness|g" \
      -e "s|{{SOPS_FILE}}|secrets.enc.env|g" \
      -e "s|{{VAULT_KEYS}}|  dump_kv GH_TOKEN kv/harness/github pat|g" \
      -e "s|{{GCP_SM_KEYS}}|  dump_sm GH_TOKEN gh-harness-token|g" \
      -e "s|{{AWS_SM_KEYS}}|  dump_asm GH_TOKEN harness/github-token|g" \
      "$ROOT/templates/scripts/secrets.sh.tmpl" > "$WS/scripts/secrets.sh"
  chmod +x "$WS/scripts/secrets.sh"
}

echo "── el placeholder ya no puede producir un comando inexistente"

grep -q "SECRETS_SOURCE_FN" "$ROOT/templates/scripts/secrets.sh.tmpl" \
  && fail "el template sigue interpolando un nombre de función (SECRETS_SOURCE_FN)" \
  || pass "el despacho no interpola nombres de función"

echo "── cada fuente elegida llega a su implementación"

# vault: token presente (fuera del workspace no lo tocamos: usamos HOME falso)
export HOME="$WS/home"; mkdir -p "$HOME/.config/harness"; printf 'tok\n' > "$HOME/.config/harness/vault-token"
for spec in "vault vault" "gcp-secret-manager gcloud" "aws-secrets-manager aws" "doppler doppler"; do
  set -- $spec
  : > "$CALLS"; gen "$1"
  (cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/secrets.sh pull >/dev/null 2>&1)
  assert_contains "$(cat "$CALLS" 2>/dev/null)" "LLAMADO:$2" "fuente '$1' invoca a $2"
done

# sops y 1password piden su archivo de entrada
: > "$CALLS"; gen sops
printf 'x\n' > "$WS/secrets.enc.env"
(cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/secrets.sh pull >/dev/null 2>&1)
assert_contains "$(cat "$CALLS")" "LLAMADO:sops" "fuente 'sops' invoca a sops"
: > "$CALLS"; gen 1password
printf 'K=op://v/i/f\n' > "$WS/.secrets.tpl"
(cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/secrets.sh pull >/dev/null 2>&1)
assert_contains "$(cat "$CALLS")" "LLAMADO:op" "fuente '1password' invoca a op"

# env: no materializa, solo verifica que exista .secrets
rm -f "$WS/.secrets"      # las fuentes anteriores lo dejaron escrito
gen env
out="$(cd "$WS" && bash scripts/secrets.sh pull 2>&1)"; rc=$?
assert_eq 1 "$rc" "fuente 'env' sin .secrets: falla pidiendo el archivo"
printf 'K=V\n' > "$WS/.secrets"
out="$(cd "$WS" && bash scripts/secrets.sh pull 2>&1)"; rc=$?
assert_eq 0 "$rc" "fuente 'env' con .secrets: verde"

echo "── alias históricos y fuente desconocida"

: > "$CALLS"; gen gcp_sm
(cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/secrets.sh pull >/dev/null 2>&1)
assert_contains "$(cat "$CALLS")" "LLAMADO:gcloud" "alias 'gcp_sm' sigue resolviendo"

: > "$CALLS"; gen pull_vault
(cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/secrets.sh pull >/dev/null 2>&1)
assert_contains "$(cat "$CALLS")" "LLAMADO:vault" "un generador que inyecta 'pull_vault' ya no rompe (issue #21)"

gen no-existe
out="$(cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/secrets.sh pull 2>&1)"; rc=$?
assert_eq 1 "$rc" "fuente desconocida: exit 1"
assert_contains "$out" "no-existe" "el error NOMBRA la fuente inválida"
assert_not_contains "$out" "command not found" "no muere como comando inexistente"
assert_contains "$out" "harness-answers.yaml" "el error trae remediación"

echo "── check no depende de la fuente"

gen vault
out="$(cd "$WS" && bash scripts/secrets.sh check 2>&1)"; rc=$?
assert_eq 0 "$rc" "check con .secrets presente: verde"

echo
echo "── el token de Vault: renovar, no necesitar renovacion, y no poder mirar"
# Un token root (o con TTL infinito) NO es renovable: `vault token renew` falla
# SIEMPRE, y el aviso de "¿expiro?" quedaba en cada pull para siempre. Un
# warning permanente que no significa nada enseña a ignorar los warnings, que es
# justo lo que no queremos el dia que uno si importe.
awk '/^pull_vault\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ROOT/templates/scripts/secrets.sh.tmpl" \
  | sed -e 's|{{VAULT_ADDR}}|http://v:8200|g' -e 's|{{VAULT_KEYS}}||g' -e 's|{{VAULT_KV_BASE}}|kv|g' > "$WS/pv.sh"
mkdir -p "$WS/bin" "$WS/fake/.config/harness"
echo tok > "$WS/fake/.config/harness/vault-token"

vault_stub() {  # vault_stub <json-lookup> <exit-renew>
  printf '#!/bin/sh\ncase "$*" in\n  *"token lookup"*) cat <<JEOF\n%s\nJEOF\n ;;\n  *"token renew"*) exit %s ;;\n  *) exit 0 ;;\nesac\n' "$1" "$2" > "$WS/bin/vault"
  chmod +x "$WS/bin/vault"
}
run_pull() {
  ( set -u; PATH="$WS/bin:$PATH"; HOME="$WS/fake"
    OUT="$WS/o"; OUTD="$WS/od"; mkdir -p "$OUTD"; finish() { :; }
    . "$WS/pv.sh"; pull_vault ) 2>&1
}

vault_stub '{"data":{"renewable":true,"ttl":100}}' 0
out="$(run_pull)"
assert_not_contains "$out" "expiró" "token renovable que renueva: sin ruido"
assert_not_contains "$out" "sin caducidad" "y no lo confunde con un root"

vault_stub '{"data":{"renewable":false,"ttl":0}}' 1
out="$(run_pull)"
assert_contains "$out" "no requiere renovación" "root/TTL infinito: lo dice, no lo trata como error"
assert_not_contains "$out" "expiró" "y NO deja el warning permanente que se aprende a ignorar"

vault_stub '{"data":{"renewable":true,"ttl":100}}' 1
out="$(run_pull)"
assert_contains "$out" "renovación falló" "renovable que falla de verdad: sí avisa"

vault_stub "" 1
out="$(run_pull)"
assert_contains "$out" "no pude consultar" "token ilegible: 'no pude mirar', distinto de las otras tres"

echo
echo "── secrets doctor: lo requerido por los repos contra lo provisto"
# Caso de campo: tres secretos existían en la fuente desde siempre y nadie
# los había registrado en secrets.sh; el reporte decía "bloqueado: sin
# acceso" cuando la verdad era "faltan tres líneas dump_kv". Horas de
# diferencia entre esas dos frases.

mkdir -p "$WS/repos/app/config" "$WS/repos/svc/chart"
printf 'API_KEY=\nDB_URL=\n' > "$WS/repos/app/.env.example"
printf 'const dsn = process.env.SENTRY_DSN;\n' > "$WS/repos/app/config/index.js"
cat > "$WS/repos/svc/chart/values.yaml" <<'YAML'
env:
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: svc-secrets
        key: REDIS_PASSWORD
YAML
printf 'secrets:\n  refs:\n    - env://GH_TOKEN\n' > "$WS/harness-answers.yaml"
gen vault    # VAULT_KEYS ya inyecta dump_kv GH_TOKEN kv/harness/github pat
printf 'DB_URL=x\nAPI_KEY=y\n' > "$WS/.secrets"

# sin CLI de vault utilizable (sin token): degrada honesto y nombra faltantes
out="$( ( cd "$WS" && PATH="$(t_path_without vault)" bash scripts/secrets.sh doctor 2>&1 ) )"; rc=$?
assert_eq 1 "$rc" "hay faltantes: exit 1"
assert_contains "$out" "SENTRY_DSN" "caza el process.env de config/"
assert_contains "$out" "repos/app/config/index.js" "y nombra QUIÉN la requiere"
assert_contains "$out" "REDIS_PASSWORD" "caza el secretKeyRef del chart"
assert_contains "$out" "values.yaml" "con su origen"
assert_not_contains "$out" "FALTA API_KEY" "lo provisto por .secrets no es faltante"
assert_not_contains "$out" "FALTA DB_URL" "ídem"
assert_not_contains "$out" "FALTA GH_TOKEN" "lo provisto por dump_kv tampoco"
assert_contains "$out" "dump_kv SENTRY_DSN" "la remediación da la línea exacta a agregar"
assert_contains "$out" "no pude buscar candidatos" "sin CLI/token: degrada honesto"

# con vault stub + token: sugiere el candidato por nombre de campo
cat > "$WS/bin/vault" <<'SH'
#!/bin/sh
if [ "$1" = "kv" ] && [ "$2" = "get" ]; then
  echo '{"data":{"data":{"pat":"x","sentry_dsn":"y","redis_password":"z"}}}'
  exit 0
fi
exit 0
SH
chmod +x "$WS/bin/vault"
printf 'tok\n' > "$WS/.vault-token"
out="$( ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/secrets.sh doctor 2>&1 ) )"; rc=$?
assert_eq 1 "$rc" "sigue habiendo faltantes: exit 1"
assert_contains "$out" "dump_kv SENTRY_DSN kv/harness/github sentry_dsn" \
  "el candidato viene con path y campo exactos (búsqueda case-insensitive)"

# todo provisto → verde
printf 'DB_URL=x\nAPI_KEY=y\nSENTRY_DSN=s\nREDIS_PASSWORD=r\n' > "$WS/.secrets"
out="$( ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/secrets.sh doctor 2>&1 ) )"; rc=$?
assert_eq 0 "$rc" "todo provisto: exit 0"
assert_contains "$out" "está provisto" "y lo dice"
rm -f "$WS/.vault-token" "$WS/harness-answers.yaml"

echo
echo "── el mensaje del bootstrap no vende Vault como unica opcion"
bs="$(cat "$ROOT/templates/scripts/bootstrap.sh.tmpl")"
assert_contains "$bs" "secrets.source: {{SECRETS_SOURCE}}" "dice QUE fuente declaro la instancia"
assert_contains "$bs" "gcp-secret-manager" "y nombra las otras que existen"
assert_contains "$bs" "OPCIÓN B · root token" "documenta el root token como opcion real"
assert_contains "$bs" "llave maestra" "con su costo escrito, para que sea decision y no sorpresa"
assert_contains "$bs" "NO tenés que re-autenticarte nunca" "y aclara que el periodic ya evita re-autenticarse"

echo
echo "── el onboarding es de TU fuente, no de Vault (7 fuentes, no 1)"
# El bloque preguntaba SIEMPRE por un token de Vault y cableaba `vault-token`
# como archivo, sin mirar que fuente declaro la instancia: 6 de las 7 fuentes
# que secrets.sh implementa no recibian NINGUN paso de credencial y el
# bootstrap saltaba directo a `secrets.sh pull`, que falla sin decir como
# autenticarse.
for f in gcp-secret-manager aws-secrets-manager doppler sops 1password env; do
  assert_contains "$bs" "    $f)" "el bootstrap despacha la fuente $f"
done
assert_contains "$bs" "gcloud auth application-default login" "y nombra el login exacto de GCP"
assert_contains "$bs" "aws sso login" "el de AWS"
assert_contains "$bs" "doppler login" "el de Doppler"
assert_contains "$bs" "op signin" "el de 1Password"
assert_contains "$bs" "SOPS_AGE_KEY_FILE" "y la llave de sops, que no tiene login"

# El caso del #174: token en disco + CLI ausente = no se pudo VALIDAR, y eso
# tiene que decirse en TODA corrida. Antes las dos ramas quedaban sin tomar,
# NEED_TOKEN se quedaba en 0 y el bootstrap daba por bueno un token que nunca
# verifico contra ningun servidor.
assert_contains "$bs" "pero el CLI vault NO está" "sin CLI, el token no se da por bueno en silencio"
assert_contains "$bs" "no tiene cómo saberlo" "y dice que es ceguera, no un verde"

# El tramo se extrae y se EJERCITA, que es lo unico que prueba que la rama se
# toma de verdad: sin CLI de vault y con token en disco, tiene que hablar.
tmpb="$WS/bootstrap-secretos.sh"
{ printf 'warn() { echo "WARN: $1"; }\nok() { echo "OK: $1"; }\nSKIP_SECRETS=0\nCHECK=0\nWS="%s"\n' "$WS"
  sed 's/{{SECRETS_SOURCE}}/vault/g; s/{{VAULT_ADDR}}/https:\/\/vault.example/g' \
      "$ROOT/templates/scripts/bootstrap.sh.tmpl" \
    | awk '/^onboard_cli\(\) \{/{f=1} f{print} /^  esac$/{if(f) exit}'
  printf 'fi\n'   # el `if` del bloque cierra mas abajo, fuera del tramo extraido
} > "$tmpb"
mkdir -p "$WS/fakehome/.config/harness"
printf 'un-token-viejo\n' > "$WS/fakehome/.config/harness/vault-token"
out="$( HOME="$WS/fakehome" PATH="$(t_path_without vault)" bash "$tmpb" 2>&1 )"
assert_contains "$out" "WARN: hay un token" "con token en disco y sin CLI: avisa (antes: silencio)"
assert_contains "$out" "vault token lookup" "y da el comando para validarlo a mano"

# Y una fuente que NO es vault no pide token de vault ni nombra su archivo.
{ printf 'warn() { echo "WARN: $1"; }\nok() { echo "OK: $1"; }\nSKIP_SECRETS=0\nCHECK=0\nWS="%s"\n' "$WS"
  sed 's/{{SECRETS_SOURCE}}/doppler/g; s/{{VAULT_ADDR}}/https:\/\/vault.example/g' \
      "$ROOT/templates/scripts/bootstrap.sh.tmpl" \
    | awk '/^onboard_cli\(\) \{/{f=1} f{print} /^  esac$/{if(f) exit}'
  printf 'fi\n'   # el `if` del bloque cierra mas abajo, fuera del tramo extraido
} > "$tmpb"
out="$( HOME="$WS/fakehome" PATH="$(t_path_without doppler)" bash "$tmpb" 2>&1 )"
assert_contains "$out" "doppler" "fuente doppler: habla de doppler"
assert_not_contains "$out" "token de Vault" "y NO pide un token de Vault"
assert_contains "$out" "no puedo comprobar" "sin su CLI declara ceguera, no un verde"

t_done
