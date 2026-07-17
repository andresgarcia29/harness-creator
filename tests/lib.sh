#!/usr/bin/env bash
# lib.sh — aserciones mínimas para los tests de bash. Cada test es un script
# independiente que crea SU workspace temporal y lo borra al salir: un test
# que depende del estado de otro es un test que miente cuando corre solo.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0; CHECKS=0

t_ws() {  # workspace temporal auto-limpiado
  WS="$(mktemp -d)"
  trap 'rm -rf "$WS"' EXIT
}

pass() { CHECKS=$((CHECKS+1)); printf '  ✓ %s\n' "$1"; }
fail() { CHECKS=$((CHECKS+1)); FAILS=$((FAILS+1)); printf '  ✕ %s\n' "$1"; }

assert_eq() {         # assert_eq <esperado> <real> <nombre>
  [ "$1" = "$2" ] && pass "$3" || fail "$3 — esperaba '$1', fue '$2'"
}
assert_contains() {   # assert_contains <texto> <aguja> <nombre>
  case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 — no contiene '$2'" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "$3 — contiene '$2' y no debería" ;; *) pass "$3" ;; esac
}
assert_file() { [ -f "$1" ] && pass "$2" || fail "$2 — no existe $1"; }
assert_no_file() { [ ! -e "$1" ] && pass "$2" || fail "$2 — existe $1 y no debería"; }

t_done() {
  echo
  if [ "$FAILS" -eq 0 ]; then echo "OK — $CHECKS aserciones"; exit 0
  else echo "FALLARON $FAILS de $CHECKS aserciones"; exit 1; fi
}
