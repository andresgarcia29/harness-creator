#!/usr/bin/env bash
# test_pull_all.sh: make pull contra fixtures git reales. Protege el contrato:
# atrasado se actualiza, al día se reporta, SUCIO se salta sin tocarse (el
# canónico es sagrado), y un origin roto es fallo con exit 1, no silencio.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/repos"
cp "$ROOT/templates/scripts/pull-all.sh" "$WS/scripts/"

git_id() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

mk_pair() {  # mk_pair <nombre> → origin bare + clon canónico en repos/
  # -b main EXPLÍCITO también en el bare: sin él, el HEAD del origin apunta
  # al init.defaultBranch del HOST (master en CI, main en laptops
  # configuradas) y el clone nace sin rama. Testing-policy regla 7.
  local n="$1" work="$WS/seed-$1"
  git init -q --bare -b main "$WS/origins/$n.git"
  git init -q -b main "$work" && git_id "$work" commit -q --allow-empty -m base
  git -C "$work" remote add origin "$WS/origins/$n.git"
  git -C "$work" push -q origin main
  git clone -q "$WS/origins/$n.git" "$WS/repos/$n"
}
mk_pair atrasado; mk_pair aldia; mk_pair sucio; mk_pair roto

# atrasado: el origin avanza un commit
git_id "$WS/seed-atrasado" commit -q --allow-empty -m avance
git -C "$WS/seed-atrasado" push -q origin main
nuevo="$(git -C "$WS/seed-atrasado" rev-parse --short HEAD)"

# sucio: mugre local en el canónico (jamás debe tocarse)
echo mugre > "$WS/repos/sucio/pendiente.txt"

# roto: origin desaparece
rm -rf "$WS/origins/roto.git"

echo "── pull-all: paralelo, seguro con mugre, honesto con fallos"

out="$(bash "$WS/scripts/pull-all.sh" 2>&1)"; rc=$?
assert_eq 1 "$rc" "un origin roto = exit 1 (no silencio)"
assert_contains "$out" "atrasado: " "reporta el repo atrasado"
assert_eq "$nuevo" "$(git -C "$WS/repos/atrasado" rev-parse --short HEAD)" "atrasado quedó en el HEAD nuevo del origin"
assert_contains "$out" "aldia: ya al día" "al día se reporta como tal"
assert_contains "$out" "○ sucio" "sucio se salta con aviso"
assert_file "$WS/repos/sucio/pendiente.txt" "la mugre del sucio quedó intacta"
git -C "$WS/repos/sucio" diff --quiet 2>/dev/null; [ -z "$(git -C "$WS/repos/sucio" log origin/main..HEAD --oneline 2>/dev/null)" ] \
  && pass "sucio: ni rebase ni commits fantasma" || fail "sucio fue tocado"
assert_contains "$out" "✗ roto" "el origin roto se reporta como fallo"

# sin el roto: todo verde y exit 0 (los sucios no son fallo)
rm -rf "$WS/repos/roto"
out="$(bash "$WS/scripts/pull-all.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "sin fallos reales: exit 0 (sucio es aviso, no fallo)"
assert_contains "$out" "todo al día" "resumen final presente"

t_done
