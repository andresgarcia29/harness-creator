#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"

echo "── contratos de documentación"
root="$(cd "$(dirname "$0")/.." && pwd)"

readme="$(cat "$root/README.md")"
auto="$(cat "$root/templates/commands/auto.md.tmpl")"
index="$(cat "$root/templates/docs/index.md.tmpl")"

assert_not_contains "$readme" "127.0.0.1:7717" "README no conserva el puerto viejo"
assert_not_contains "$readme" "exactamente diez" "README no duplica el número de paradas"
assert_contains "$auto" "Lista cerrada de paradas" "auto declara el contrato cerrado"
assert_contains "$auto" "harness-policy.py pause" "auto registra pausas mediante policy"
assert_contains "$index" "harness/evidence.md" "índice enlaza evidence v1"
assert_contains "$index" "harness/policy.md" "índice enlaza policy v1"

t_done
