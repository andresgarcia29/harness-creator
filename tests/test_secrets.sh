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
echo "── el mensaje del bootstrap no vende Vault como unica opcion"
bs="$(cat "$ROOT/templates/scripts/bootstrap.sh.tmpl")"
assert_contains "$bs" "secrets.source: {{SECRETS_SOURCE}}" "dice QUE fuente declaro la instancia"
assert_contains "$bs" "gcp-secret-manager" "y nombra las otras que existen"
assert_contains "$bs" "OPCIÓN B · root token" "documenta el root token como opcion real"
assert_contains "$bs" "llave maestra" "con su costo escrito, para que sea decision y no sorpresa"
assert_contains "$bs" "NO tenés que re-autenticarte nunca" "y aclara que el periodic ya evita re-autenticarse"

t_done
