#!/usr/bin/env bash
# test_bootstrap_link.sh: link_into_path() del bootstrap, contra el CÓDIGO
# REAL del template. Es la función que decide si ensure() cuenta un binario
# como instalado, y cantaba éxito sin haber enlazado nada (issue #198):
# sin brew el destino colapsaba a "/bin" (el del sistema), el `ln` moría con
# Permission denied y el ok() se imprimía igual. El contrato que se protege
# acá es uno solo: devuelve 0 SOLO si el binario quedó invocable.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

# La función, extraída tal cual del template, con ok() de stub.
sed -n '/^link_into_path()/,/^}/p' "$ROOT/templates/scripts/bootstrap.sh.tmpl" > "$WS/fn.sh"
[ -s "$WS/fn.sh" ] || { echo "no pude extraer link_into_path del template"; exit 1; }

# Corre link_into_path en un subshell hermético: HOME propio, PATH controlado.
# run <PATH> <HOME> <bin> → imprime "<exit>|<salida>"
run() {
  local p="$1" h="$2" b="$3" out rc
  out="$(HOME="$h" PATH="$p" bash -c '
    set -uo pipefail
    ok() { echo "OK:$1"; }
    . "$1"
    link_into_path "$2"
  ' _ "$WS/fn.sh" "$b" 2>&1)"; rc=$?
  printf '%s|%s' "$rc" "$out"
}

# ── caso 1: sin brew y con el binario en ~/go/bin, pero ~/.local/bin fuera
# del PATH. Antes: dest="/bin", ln falla, ok() igual. Ahora: no es éxito.
H1="$WS/h1"; mkdir -p "$H1/go/bin"
printf '#!/bin/sh\necho hola\n' > "$H1/go/bin/faketool"; chmod +x "$H1/go/bin/faketool"
NOBREW="$(t_path_without brew)"
r="$(run "$NOBREW" "$H1" faketool)"
assert_eq "1" "${r%%|*}" "sin brew y con el destino fuera del PATH: devuelve 1"
assert_not_contains "${r#*|}" "OK:" "y no canta 'enlazado' (era el falso verde de #198)"
assert_no_file "/bin/faketool" "no toca el /bin del sistema"

# ── caso 2: mismo caso pero con ~/.local/bin en el PATH: sí es éxito, y el
# enlace existe de verdad.
r="$(run "$H1/.local/bin:$NOBREW" "$H1" faketool)"
assert_eq "0" "${r%%|*}" "sin brew y con ~/.local/bin en el PATH: devuelve 0"
assert_contains "${r#*|}" "OK:faketool enlazado a $H1/.local/bin" "reporta el destino real"
[ -L "$H1/.local/bin/faketool" ] && pass "el symlink existe" || fail "el symlink existe"
assert_eq "hola" "$(PATH="$H1/.local/bin:$NOBREW" faketool)" "y el binario es invocable por nombre"

# ── caso 3: el destino no es escribible → el ln falla → NO es éxito.
# (el falso verde original: exit de ln nunca mirado)
H3="$WS/h3"; mkdir -p "$H3/go/bin" "$H3/.local/bin"
cp "$H1/go/bin/faketool" "$H3/go/bin/"
chmod 555 "$H3/.local/bin"
r="$(run "$H3/.local/bin:$NOBREW" "$H3" faketool)"
chmod 755 "$H3/.local/bin"
if [ "$(id -u)" = "0" ]; then
  pass "destino no escribible: omitido (root escribe igual)"
else
  assert_eq "1" "${r%%|*}" "si el ln falla, devuelve 1"
  assert_not_contains "${r#*|}" "OK:" "si el ln falla, no imprime éxito"
fi

# ── caso 4: el binario YA está en el destino. Enlazarlo a sí mismo es un
# error de `ln`; lo único que decide es si está en el PATH.
H4="$WS/h4"; mkdir -p "$H4/.local/bin"
cp "$H1/go/bin/faketool" "$H4/.local/bin/"
r="$(run "$H4/.local/bin:$NOBREW" "$H4" faketool)"
assert_eq "0" "${r%%|*}" "binario ya en el destino y en el PATH: devuelve 0"
[ -x "$H4/.local/bin/faketool" ] && pass "y el binario sigue ahí" || fail "y el binario sigue ahí"
r="$(run "$NOBREW" "$H4" faketool)"
assert_eq "1" "${r%%|*}" "binario ya en el destino pero fuera del PATH: devuelve 1"

# ── caso 5: con brew, el destino es el prefix de brew, no ~/.local/bin.
H5="$WS/h5"; mkdir -p "$H5/go/bin" "$WS/fakebrew" "$WS/pfx/bin"
cp "$H1/go/bin/faketool" "$H5/go/bin/"
printf '#!/bin/sh\n[ "$1" = --prefix ] && echo %s\n' "$WS/pfx" > "$WS/fakebrew/brew"
chmod +x "$WS/fakebrew/brew"
r="$(run "$WS/pfx/bin:$WS/fakebrew:$NOBREW" "$H5" faketool)"
assert_eq "0" "${r%%|*}" "con brew: devuelve 0"
assert_contains "${r#*|}" "OK:faketool enlazado a $WS/pfx/bin" "con brew: enlaza al prefix de brew"
assert_no_file "$H5/.local/bin/faketool" "con brew: no usa el fallback de usuario"

# ── caso 6: sin `go` instalado, el candidato de GOPATH no debe colapsar a
# "/bin/<bin>" y agarrar un binario del sistema con ese nombre.
rm -f "$NOBREW/go"   # último uso de este PATH: se le saca también go
r="$(run "$NOBREW" "$WS/h6" ls)"
assert_eq "1" "${r%%|*}" "sin go: no adopta /bin/<bin> como candidato"

# el template completo sigue parseando con la función nueva adentro
python3 - "$ROOT/templates/scripts/bootstrap.sh.tmpl" "$WS/boot.sh" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
open(sys.argv[2], 'w').write(re.sub(r'\{\{[A-Z_]+\}\}', '', src))
PY
bash -n "$WS/boot.sh" && pass "bootstrap.sh.tmpl parsea" || fail "bootstrap.sh.tmpl no parsea"

t_done
