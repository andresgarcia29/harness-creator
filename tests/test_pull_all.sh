#!/usr/bin/env bash
# test_pull_all.sh: make pull contra fixtures git reales. Protege el contrato:
# atrasado se actualiza, al día se reporta, mugre VERSIONADA se salta sin
# tocarse (el canónico es sagrado) Y SE NOMBRA EN EL RESUMEN (caso de campo:
# un repo salteado por un artefacto untracked quedó 16 commits atrás y el
# "todo al día" del final lo tapó; las auditorías corrieron sobre código que
# ya no existía), mugre solo-untracked NO impide el pull (el rebase no la
# toca), y un origin roto es fallo con exit 1, no silencio. Y (#233) que un
# workspace recién creado se MATERIALICE: manifest.yaml declara los repos y
# repos/ ni existe, así que pull-all clona lo que falta antes de pullear.
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

# ── #77: el clon canonico con una RAMA DE TAREA checkeada ────────────
# enrama: la rama existe en el origin (el caso de campo, design-system). El
# pull refrescaba origin/main y cantaba "ya al dia" mientras el arbol que un
# agente lee seguia 3 commits atras.
mk_pair enrama
git_id "$WS/repos/enrama" checkout -q -b task/vieja
git -C "$WS/repos/enrama" push -q -u origin task/vieja
for i in 1 2 3; do git_id "$WS/seed-enrama" commit -q --allow-empty -m "avance$i"; done
git -C "$WS/seed-enrama" push -q origin main
nuevo_enrama="$(git -C "$WS/seed-enrama" rev-parse HEAD)"

# enrama2: rama local que NUNCA se pusheo (el caso post-merge, la mas comun).
# Hoy el set-upstream falla, el pull falla, y sale un "✗" que diagnostica "red
# o conflicto de rebase": mentira, y ademas cuenta como fallo con exit 1.
mk_pair enrama2
git_id "$WS/repos/enrama2" checkout -q -b task/nunca-pusheada
git_id "$WS/seed-enrama2" commit -q --allow-empty -m avance
git -C "$WS/seed-enrama2" push -q origin main

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

# ── #77: la rama de tarea checkeada es su PROPIA categoria, no un verde
assert_contains "$out" "OTRA RAMA checkeada" "el resumen tiene su seccion (el detalle se pierde en el scroll)"
assert_contains "$out" "enrama → task/vieja (3 commits atrás de origin/main)" \
  "nombra el repo, la rama y la DISTANCIA (el dato que convierte el falso en señal)"
assert_not_contains "$out" "✓ enrama: ya al día" "murio el falso verde"
assert_not_contains "$out" "✗ enrama2" "la rama sin upstream ya no se disfraza de fallo de red"
assert_contains "$out" "enrama2 → task/nunca-pusheada" "y tambien se nombra"
# El invariante en sus dos mitades: el arbol ajeno NO se toca, y la ref de la
# trunk queda fresca igual (el fetch se paga).
assert_eq "task/vieja" "$(git -C "$WS/repos/enrama" branch --show-current)" \
  "la rama ajena NO se toca (puede tener commits sin publicar)"
assert_eq "$nuevo_enrama" "$(git -C "$WS/repos/enrama" rev-parse origin/main)" \
  "pero origin/main SI queda fresco: el fetch se pago"

# sin el roto: exit 0, pero el resumen NO puede decir 'todo al día' con saltados
rm -rf "$WS/repos/roto"
out="$(bash "$WS/scripts/pull-all.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "sin fallos reales: exit 0 (saltado y en-rama son aviso, no fallo)"
assert_not_contains "$out" "todo al día" "con repos saltados el resumen NO miente 'todo al día'"
assert_contains "$out" "al día: 4 de 7 repos" "dice cuántos sí quedaron al día (los en-rama tampoco cuentan)"

# limpio el versionado y devuelvo los clones a su trunk: ahora sí, todo al día.
# Es la remediacion exacta que el propio resumen indica.
git -C "$WS/repos/versionado" checkout -q -- f.txt
git -C "$WS/repos/enrama" checkout -q main
git -C "$WS/repos/enrama2" checkout -q main
out="$(bash "$WS/scripts/pull-all.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "todo limpio: exit 0"
assert_contains "$out" "todo al día" "y el resumen de siempre vuelve"

# ── #233: workspace RECIÉN CREADO (manifest con repos, repos/ inexistente) ──
# Ningún script del plugin materializaba los clones: pull-all iteraba repos/*/,
# no encontraba nada y salía 0 con "sin repos git". El onboarding no tenía
# comando que resolviera el estado inicial y el único síntoma era un verde.
# Los origins son repos git LOCALES (file://): la suite no toca la red.
mk_origin() {  # mk_origin <nombre> → solo el bare origin, sin clon local
  local n="$1" work="$WS/seedf-$1"
  git init -q --bare -b main "$WS/origins/$n.git"
  git init -q -b main "$work" && git_id "$work" commit -q --allow-empty -m base
  git -C "$work" remote add origin "$WS/origins/$n.git"
  git -C "$work" push -q origin main
}
mk_origin uno; mk_origin dos

FRESH="$WS/fresh"
mkdir -p "$FRESH/scripts"
cp "$ROOT/templates/scripts/pull-all.sh" "$FRESH/scripts/"
cat > "$FRESH/manifest.yaml" <<EOF
project: "acme"
harness_version: "0.0.0-test"

repos:
  - name: uno
    url: file://$WS/origins/uno.git
    branch: main
    kind: service
  - name: dos
    url: "file://$WS/origins/dos.git"
    kind: library
  - name: sin-remoto
    kind: docs
#  - name: comentado
#    url: file://$WS/origins/comentado.git

dag:
  - name: no-soy-un-repo
    url: file://$WS/origins/no-soy-un-repo.git
EOF
assert_no_file "$FRESH/repos" "el workspace nace SIN repos/ (el estado que nadie resolvía)"

echo "── #233: materializar repos/ desde manifest.yaml"
out="$(bash "$FRESH/scripts/pull-all.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "workspace recién creado: exit 0 (clona y pullea)"
assert_contains "$out" "✓ clonado uno" "clona el repo declarado en el manifest"
assert_contains "$out" "✓ clonado dos" "y el segundo también (url entre comillas)"
assert_file "$FRESH/repos/uno/.git/HEAD" "uno quedó clonado de verdad"
assert_file "$FRESH/repos/dos/.git/HEAD" "dos quedó clonado de verdad"
assert_not_contains "$out" "sin repos git" "ya no sale 0 diciendo que no hay nada que hacer"
assert_contains "$out" "sin-remoto" "el repo del manifest SIN url se nombra (no se calla)"
assert_contains "$out" "SIN url" "y se dice exactamente qué le falta"
assert_not_contains "$out" "todo al día" "con un repo declarado sin clonar, el resumen no miente"
assert_no_file "$FRESH/repos/no-soy-un-repo" "la lista dag: no aporta repos falsos"
assert_no_file "$FRESH/repos/comentado" "los ejemplos comentados del template no ensucian"

# segunda corrida: idempotente (no re-clona) y a partir de acá es un pull normal
echo marca > "$FRESH/repos/uno/.marca"
git_id "$WS/seedf-dos" commit -q --allow-empty -m avance
git -C "$WS/seedf-dos" push -q origin main
nuevo_dos="$(git -C "$WS/seedf-dos" rev-parse --short HEAD)"
out="$(bash "$FRESH/scripts/pull-all.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "segunda corrida: exit 0"
assert_not_contains "$out" "clonado uno" "idempotente: lo ya clonado NO se re-clona"
assert_file "$FRESH/repos/uno/.marca" "y el clon existente no se pisa"
assert_contains "$out" "✓ uno: ya al día" "pasa a pullearse como cualquier clon canónico"
assert_eq "$nuevo_dos" "$(git -C "$FRESH/repos/dos" rev-parse --short HEAD)" \
  "dos quedó en el HEAD nuevo del origin (el pull corrió sobre lo recién clonado)"

# un clone que FALLA es fallo visible con exit 1, no un aviso más
rm -rf "$FRESH/repos/dos" "$WS/origins/dos.git"
out="$(bash "$FRESH/scripts/pull-all.sh" 2>&1)"; rc=$?
assert_eq 1 "$rc" "un clone que falla = exit 1 (no silencio)"
assert_contains "$out" "✗ dos: clone falló" "y se reporta al estilo del script"

t_done
