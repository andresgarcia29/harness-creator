#!/usr/bin/env bash
# test_version.sh: la version se DERIVA de los commits y vive en un solo lugar.
#
# Vivia en tres archivos editados a mano y terminaron diciendo cosas distintas:
# plugin.json 0.48.0, marketplace.json 0.45.2, tag v0.47.0. marketplace.json es
# lo que Claude Code lee para INSTALAR, asi que una instancia podia instalar una
# version y reportarse al dia contra otra.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

V="$ROOT/scripts/version.sh"

mk_repo() {  # mk_repo <version-inicial> <tag|"">
  rm -rf "$WS/r"; mkdir -p "$WS/r/.claude-plugin" "$WS/r/scripts"
  cp "$V" "$WS/r/scripts/version.sh"
  printf '{"name":"x","version":"%s"}\n' "$1" > "$WS/r/.claude-plugin/plugin.json"
  printf '{"plugins":[{"name":"x","version":"%s"}]}\n' "$1" > "$WS/r/.claude-plugin/marketplace.json"
  ( cd "$WS/r"; git init -q .; git config user.email t@t; git config user.name t
    git add -A; git commit -qm "chore: init"
    [ -n "${2:-}" ] && git tag "$2" ) >/dev/null 2>&1
}
run() { ( cd "$WS/r" && bash scripts/version.sh "$@" ) 2>&1; }

echo "── el bump se deriva de los commits, no se elige"
mk_repo 0.10.0 v0.10.0
( cd "$WS/r"; git commit -q --allow-empty -m "fix(x): algo" ) >/dev/null
assert_eq "0.10.1" "$(run next)" "solo fix: sube patch"
( cd "$WS/r"; git commit -q --allow-empty -m "feat(x): algo nuevo" ) >/dev/null
assert_eq "0.11.0" "$(run next)" "con un feat: sube minor (aunque haya fixes)"

echo "── en 0.x un BREAKING no salta a 1.0.0"
mk_repo 0.10.0 v0.10.0
( cd "$WS/r"; git commit -q --allow-empty -m "feat(x)!: rompe el contrato" ) >/dev/null
assert_eq "0.11.0" "$(run next)" "pre-1.0: breaking sube minor, no major"
# saltar a 1.0.0 diria que el proyecto se estabilizo, que es lo contrario de lo
# que un breaking significa.

mk_repo 1.2.3 v1.2.3
( cd "$WS/r"; git commit -q --allow-empty -m "feat(x)!: rompe" ) >/dev/null
assert_eq "2.0.0" "$(run next)" "post-1.0: breaking sube major"

echo "── sin commits nuevos no hay version nueva"
mk_repo 0.10.0 v0.10.0
assert_eq "0.10.0" "$(run next)" "sin commits desde el tag: no inventa un bump"

echo "── check caza el desalineado que ya paso"
mk_repo 0.48.0 ""
( cd "$WS/r" && jq '.plugins[0].version="0.45.2"' .claude-plugin/marketplace.json > /tmp/m && mv /tmp/m .claude-plugin/marketplace.json )
out="$(run check)"; rc=$?
assert_eq 1 "$rc" "plugin y marketplace distintos: falla"
assert_contains "$out" "NO coinciden" "lo nombra"
assert_contains "$out" "INSTALAR" "y dice por que importa marketplace.json"

echo "── un tag POR DELANTE de la version declarada tambien es error"
mk_repo 0.10.0 v0.99.0
out="$(run check)"; rc=$?
assert_eq 1 "$rc" "tag adelantado: falla"
assert_contains "$out" "POR DELANTE" "lo nombra"

echo "── el tren del release NO es un tag adelantado (carrera del 2026-07-29)"
# El release taggea y alinea en un chore commit DESPUES del commit que lo
# disparo; el CI corre sobre el commit anterior y desde ahi el tag se ve
# adelantado. Las dos condiciones de la excepcion: HEAD ancestro del tag,
# y el arbol del tag declara su propia version.
mk_repo 0.10.0 ""
( cd "$WS/r"
  jq '.version="0.10.1"' .claude-plugin/plugin.json > p.tmp && mv p.tmp .claude-plugin/plugin.json
  jq '.plugins[0].version="0.10.1"' .claude-plugin/marketplace.json > m.tmp && mv m.tmp .claude-plugin/marketplace.json
  git commit -qam "chore(release): v0.10.1"
  git tag v0.10.1
  git checkout -q 'HEAD~1'
) >/dev/null 2>&1
out="$(run check)"; rc=$?
assert_eq 0 "$rc" "tag adelantado con el tren alineado: pasa"
assert_contains "$out" "tren del release" "y lo nombra como lo que es"

echo "── pero un tag en un descendiente que NO declara la version sigue rojo"
mk_repo 0.10.0 ""
( cd "$WS/r"
  git commit -q --allow-empty -m "x"
  git tag v0.99.0
  git checkout -q 'HEAD~1'
) >/dev/null 2>&1
out="$(run check)"; rc=$?
assert_eq 1 "$rc" "descendiente sin alinear: falla"
assert_contains "$out" "declara 0.10.0, no 0.99.0" "y dice que declara el commit del tag"

echo "── set escribe los DOS lugares o ninguno"
mk_repo 0.10.0 ""
run set 0.20.0 >/dev/null
assert_eq "0.20.0" "$(jq -r .version "$WS/r/.claude-plugin/plugin.json")" "plugin.json escrito"
assert_eq "0.20.0" "$(jq -r '.plugins[0].version' "$WS/r/.claude-plugin/marketplace.json")" "marketplace.json tambien"
run set 9 >/dev/null 2>&1 && fail "acepto una version invalida" || pass "version invalida: rechaza"

echo "── este repo esta coherente"
# La coherencia se exige donde MANDA: en un arbol que contiene el ultimo
# release. En una rama de tarea con commits propios encima, plugin.json declara
# la version vieja y el tag del release que aterrizo DESPUES del branch point no
# es alcanzable desde HEAD: version.sh sale 1 con razon, pero eso no es un
# defecto de este repo, es la rama estando por detras. Caso de campo (COR-660):
# cuatro releases aterrizaron en una tarde y cada uno ponia la suite en rojo por
# esta sola asercion, o sea una corrida completa (~7 min) tirada por vuelta.
#
# Saltarse NO es callarse: se dice cual es el tag que falta. Y no afloja nada,
# porque los dos casos que el gate existe para cazar siguen midiendose: el trunk
# (el tag es ancestro de HEAD) y el tren del release (HEAD es ancestro del tag).
ult="$(git -C "$ROOT" tag --list 'v*' --sort=-v:refname 2>/dev/null | head -1)"
if [ -n "$ult" ] \
   && ! git -C "$ROOT" merge-base --is-ancestor "$ult" HEAD 2>/dev/null \
   && ! git -C "$ROOT" merge-base --is-ancestor HEAD "$ult" 2>/dev/null; then
  pass "harness-creator: $ult no esta en el historial de HEAD (rama por detras del release): la coherencia se mide en el trunk"
else
  bash "$V" check >/dev/null 2>&1 && pass "harness-creator: version coherente" || fail "harness-creator desalineado"
fi

t_done
