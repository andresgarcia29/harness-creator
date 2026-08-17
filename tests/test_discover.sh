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

echo
echo "── .serena/project.yml: el archivo sin el cual Serena ignora TODO el código (#214)"
# En campo: get_symbols_overview fallaba sobre el 100% de la plataforma con los
# language servers VIVOS. repos/ está gitignoreado a propósito y el default de
# Serena es ignorar todo lo gitignoreado, así que nunca veía un solo archivo; y
# como nadie escribía este archivo, Serena lo creaba sola autodetectando desde
# la raíz del workspace: `[bash]`.
sy="$WS/.serena/project.yml"
assert_file "$sy" "discover escribe la config de Serena (antes la escribía Serena, mal)"
grep -qE '^ignore_all_files_in_gitignore: *false' "$sy" \
  && pass "#214: NO hereda el .gitignore del workspace (ahí vive repos/)" \
  || fail "#214: ignore_all_files_in_gitignore no quedó en false: Serena vuelve a quedar ciega sobre todo el código"
declarados="$(sed -n 's/^language_servers: *\[//p' "$sy" | tr -d ' ]')"
printf ',%s,' "$declarados" | grep -q ',bash,' \
  && pass "bash declarado (la raíz del workspace son los scripts del harness)" \
  || fail "bash no quedó declarado"

# Cada lenguaje del inventario: o se declara, o se dice POR QUÉ se omitió. Se
# afirma así y no con una lista fija porque depende de qué binarios hay en el
# host, y un test que exija gopls en CI prueba el PATH del runner, no el script.
for l in $(jq -r '[.repos[].languages[]] | unique | .[]' "$WS/inventory.json"); do
  if printf ',%s,' "$declarados" | grep -q ",$l,"; then
    pass "$l: declarado como language server (sale del inventario, no de la raíz)"
  elif grep -q "^#   $l: falta" "$sy"; then
    pass "$l: omitido con su motivo y su línea de instalación"
  else
    fail "$l está en el inventario y no aparece ni declarado ni omitido en project.yml"
  fi
done

# LO QUE SE OMITE ES DELIBERADO: un language server que no arranca bloquea la
# inicialización de TODOS (declarar python no sirve si go está en la lista y
# falta gopls: falla hasta el .py). Así que nada declarado puede faltar.
for b in $(sed -n 's/^# harness-requiere: *//p' "$sy"); do
  command -v "$b" >/dev/null 2>&1 \
    && pass "declara requerir \`$b\` y está en el PATH" \
    || fail "declara requerir \`$b\` y NO está: ese server bloquea la inicialización de todos los demás"
done

# El caso que ningún host da solo: el binario que falta. Se fuerza sacando gopls
# del PATH, porque el default (todo instalado) nunca ejercita la omisión y es
# justo donde vive el fallo caro: `go` en la lista sin `gopls` no rompe Go, rompe
# la inicialización ENTERA y falla hasta el `.py`.
if command -v gopls >/dev/null 2>&1; then
  SINGOPLS="$(t_path_without gopls)"
  ( PATH="$SINGOPLS" bash "$ROOT/scripts/discover.sh" "$WS" >/dev/null 2>&1 )
  d2="$(sed -n 's/^language_servers: *\[//p' "$sy" | tr -d ' ]')"
  printf ',%s,' "$d2" | grep -q ',go,' \
    && fail "sin gopls declaró go igual: ese server bloquea la inicialización de TODOS los demás" \
    || pass "sin gopls, go NO se declara (un server que no arranca los bloquea a todos)"
  grep -q '^#   go: falta `gopls`' "$sy" \
    && pass "y queda escrito por qué se omitió, con la línea de instalación" \
    || fail "se omitió go en silencio: nadie va a saber que le falta gopls"
  printf ',%s,' "$d2" | grep -q ',bash,' \
    && pass "y los demás siguen declarados: se omite uno, no la lista" \
    || fail "la falta de un binario se llevó puesta la lista entera"
  bash "$ROOT/scripts/discover.sh" "$WS" >/dev/null 2>&1   # se restaura para lo que sigue
fi

grep -q '"worktrees/\*\*"' "$sy" \
  && pass "worktrees/ fuera del índice (es una copia de cada repo)" \
  || fail "sin el .gitignore aplicando, worktrees/ entra al índice duplicando cada repo"
grep -q '"\*\*/node_modules/\*\*"' "$sy" \
  && pass "node_modules fuera del índice (el .gitignore de cada repo ya no aplica)" \
  || fail "node_modules entra al índice: el .gitignore de cada repo dejó de aplicar y nadie lo reemplazó"

# workspace vacío → exit 2 con remediación, no un inventory mentiroso
EMPTY="$(mktemp -d)"; mkdir -p "$EMPTY/repos"
out="$(bash "$ROOT/scripts/discover.sh" "$EMPTY" 2>&1)"; rc=$?
assert_eq 2 "$rc" "sin repos: exit 2"
assert_contains "$out" "Remediación" "sin repos: trae remediación"
assert_no_file "$EMPTY/inventory.json" "sin repos: NO genera inventory"
rm -rf "$EMPTY"

t_done
