#!/usr/bin/env bash
# test_discover.sh — la Fase 1 del instalador contra fixtures reales: la
# inferencia de rol es la ENTRADA del clustering de agentes; si discover
# clasifica mal, la topología entera del harness nace mal. Cubre un repo de
# cada familia + el caso vacío (exit 2 con remediación).
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mk_repo() {  # mk_repo <nombre> — repo git vacío listo para poblar
  mkdir -p "$WS/repos/$1" && git -C "$WS/repos/$1" init -q
}

# contracts: buf.yaml manda
mk_repo proto
touch "$WS/repos/proto/buf.yaml"

# service: go.mod + cmd/
mk_repo atlas
touch "$WS/repos/atlas/go.mod"
mkdir -p "$WS/repos/atlas/cmd"

# library: go.mod sin cmd/ ni Dockerfile
mk_repo shared-go
touch "$WS/repos/shared-go/go.mod"

# frontend: package.json con react
mk_repo webapp
printf '{"dependencies":{"react":"^18"}}' > "$WS/repos/webapp/package.json"

# infra-module: *.tf con variables.tf
mk_repo tf-network
touch "$WS/repos/tf-network/main.tf" "$WS/repos/tf-network/variables.tf"

# docs: puro markdown
mk_repo runbooks
printf '# runbook\n' > "$WS/repos/runbooks/README.md"

echo "── discover: la inferencia de roles que alimenta el clustering"

out="$(bash "$ROOT/scripts/discover.sh" "$WS" 2>&1)"; rc=$?
assert_eq 0 "$rc" "discover sale 0 con repos válidos"
assert_file "$WS/inventory.json" "genera inventory.json"

role() { jq -r ".repos[] | select(.name==\"$1\") | .role_guess" "$WS/inventory.json"; }
assert_eq contracts    "$(role proto)"      "buf.yaml → contracts"
assert_eq service      "$(role atlas)"      "go.mod + cmd/ → service"
assert_eq library      "$(role shared-go)"  "go.mod sin deployable → library"
assert_eq frontend     "$(role webapp)"     "package.json con react → frontend"
assert_eq infra-module "$(role tf-network)" "*.tf + variables.tf → infra-module"
assert_eq docs         "$(role runbooks)"   "puro markdown → docs"

assert_eq 6 "$(jq -r '.repo_count' "$WS/inventory.json")" "repo_count correcto"
assert_eq atlas "$(jq -r '.summary.go | sort | .[0]' "$WS/inventory.json")" "summary agrupa por lenguaje"
jq -e '.by_role.contracts | index("proto")' "$WS/inventory.json" >/dev/null \
  && pass "by_role agrupa (insumo directo del clustering)" || fail "by_role no agrupa"

# un directorio SIN .git se ignora (no es un repo)
mkdir -p "$WS/repos/no-es-repo" && touch "$WS/repos/no-es-repo/go.mod"
bash "$ROOT/scripts/discover.sh" "$WS" >/dev/null 2>&1
assert_eq 6 "$(jq -r '.repo_count' "$WS/inventory.json")" "directorios sin .git se ignoran"

# workspace vacío → exit 2 con remediación, no un inventory mentiroso
EMPTY="$(mktemp -d)"; mkdir -p "$EMPTY/repos"
out="$(bash "$ROOT/scripts/discover.sh" "$EMPTY" 2>&1)"; rc=$?
assert_eq 2 "$rc" "sin repos: exit 2"
assert_contains "$out" "Remediación" "sin repos: trae remediación"
assert_no_file "$EMPTY/inventory.json" "sin repos: NO genera inventory"
rm -rf "$EMPTY"

t_done
