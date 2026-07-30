#!/usr/bin/env bash
# test_pull_all.sh: make pull contra fixtures git reales. Protege el contrato:
# atrasado se actualiza, al día se reporta, mugre VERSIONADA se salta sin
# tocarse (el canónico es sagrado) Y SE NOMBRA EN EL RESUMEN (caso de campo:
# un repo salteado por un artefacto untracked quedó 16 commits atrás y el
# "todo al día" del final lo tapó; las auditorías corrieron sobre código que
# ya no existía), mugre solo-untracked NO impide el pull (el rebase no la
# toca), y un origin roto es fallo con exit 1, no silencio.
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
mk_pair atrasado; mk_pair aldia; mk_pair sucio; mk_pair roto; mk_pair versionado

# atrasado: el origin avanza un commit
git_id "$WS/seed-atrasado" commit -q --allow-empty -m avance
git -C "$WS/seed-atrasado" push -q origin main
nuevo="$(git -C "$WS/seed-atrasado" rev-parse --short HEAD)"

# sucio: mugre SOLO untracked (el caso de campo: un artefacto de build).
# El rebase no la toca, así que el pull procede con nota.
echo mugre > "$WS/repos/sucio/pendiente.txt"

# versionado: mugre en un archivo TRACKEADO; este sí se salta y se nombra.
echo base > "$WS/repos/versionado/f.txt"
git_id "$WS/repos/versionado" add f.txt
git_id "$WS/repos/versionado" commit -q -m f
git -C "$WS/repos/versionado" push -q origin main
echo cambio-local >> "$WS/repos/versionado/f.txt"

# roto: origin desaparece
rm -rf "$WS/origins/roto.git"

# sinup: rama local SIN upstream (el caso de campo COR-642). El origin avanza;
# sin upstream, pull --rebase no sabe contra que rebasar y el clon se queda
# atras con un "✗" que miente ("red o conflicto"). El arreglo lo reconfigura.
mk_pair sinup
git -C "$WS/repos/sinup" config --unset branch.main.remote
git -C "$WS/repos/sinup" config --unset branch.main.merge
git_id "$WS/seed-sinup" commit -q --allow-empty -m avance2
git -C "$WS/seed-sinup" push -q origin main
nuevo_sinup="$(git -C "$WS/seed-sinup" rev-parse --short HEAD)"

echo "── pull-all: paralelo, seguro con mugre, honesto con fallos"

out="$(bash "$WS/scripts/pull-all.sh" 2>&1)"; rc=$?
assert_eq 1 "$rc" "un origin roto = exit 1 (no silencio)"
assert_contains "$out" "atrasado: " "reporta el repo atrasado"
assert_eq "$nuevo" "$(git -C "$WS/repos/atrasado" rev-parse --short HEAD)" "atrasado quedó en el HEAD nuevo del origin"
assert_contains "$out" "aldia: ya al día" "al día se reporta como tal"
assert_contains "$out" "✓ sucio: ya al día" "mugre SOLO untracked: el pull procede (el rebase no la toca)"
assert_contains "$out" "untracked: no estorban" "y la nota dice que había untracked"
assert_file "$WS/repos/sucio/pendiente.txt" "la mugre untracked quedó intacta"
assert_contains "$out" "○ versionado" "mugre VERSIONADA: se salta con aviso"
assert_file "$WS/repos/versionado/f.txt" "el archivo tocado del versionado queda intacto"
grep -q cambio-local "$WS/repos/versionado/f.txt" \
  && pass "versionado: el cambio local sobrevive (ni rebase ni stash a escondidas)" \
  || fail "versionado fue tocado"
assert_contains "$out" "✗ roto" "el origin roto se reporta como fallo"
assert_contains "$out" "NO ACTUALIZADOS" "el RESUMEN nombra los repos salteados (no se van al scroll)"
assert_contains "$out" "versionado" "y dice cuáles"
assert_contains "$out" "upstream reconfigurado a origin/main" "sin upstream: se configura solo y se dice"
assert_eq "$nuevo_sinup" "$(git -C "$WS/repos/sinup" rev-parse --short HEAD)" "sinup quedo al HEAD nuevo (antes quedaba atras)"
assert_not_contains "$out" "✗ sinup" "sin upstream ya no es un fallo criptico"

# sin el roto: exit 0, pero el resumen NO puede decir 'todo al día' con saltados
rm -rf "$WS/repos/roto"
out="$(bash "$WS/scripts/pull-all.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "sin fallos reales: exit 0 (saltado es aviso, no fallo)"
assert_not_contains "$out" "todo al día" "con repos saltados el resumen NO miente 'todo al día'"
assert_contains "$out" "al día: 4 de 5 repos" "dice cuántos sí quedaron al día"

# limpio el versionado: ahora sí, todo al día
git -C "$WS/repos/versionado" checkout -q -- f.txt
out="$(bash "$WS/scripts/pull-all.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "todo limpio: exit 0"
assert_contains "$out" "todo al día" "y el resumen de siempre vuelve"

t_done
