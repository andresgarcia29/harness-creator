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

t_done
