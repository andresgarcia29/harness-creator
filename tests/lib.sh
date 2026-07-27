#!/usr/bin/env bash
# lib.sh — aserciones mínimas para los tests de bash. Cada test es un script
# independiente que crea SU workspace temporal y lo borra al salir: un test
# que depende del estado de otro es un test que miente cuando corre solo.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0; CHECKS=0

# ── Identidad de git, para TODOS los tests ────────────────────────────
# Los tests commitean, y hasta acá daban por sentado que la máquina tenía una
# identidad configurada. En una máquina de desarrollo la hay; en un runner
# limpio no, y git muere con "fatal: empty ident name". El fallo no se ve como
# lo que es: el commit falla, la variable que capturaba su sha queda vacía, y la
# aserción de dos pasos más abajo reporta un exit code raro sin decir por qué.
# Diez commits de CI en rojo por esto, verde en local todo el tiempo.
# Se exporta acá y no en cada test: un test hermético no le pregunta nada al host.
export GIT_AUTHOR_NAME="harness tests" GIT_AUTHOR_EMAIL="t@t"
export GIT_COMMITTER_NAME="harness tests" GIT_COMMITTER_EMAIL="t@t"

# ── Un PATH sin cierta herramienta ────────────────────────────────────
# Para probar "no está instalado" no alcanza con recortar el PATH a /usr/bin:
# en un runner `gh` VIVE en /usr/bin, así que el test probaba otra cosa y fallaba
# solo ahí. Esto arma un bin con enlaces a todo lo que hay MENOS lo pedido.
t_path_without() {  # t_path_without <cmd> → imprime un PATH sin ese comando
  local drop="$1" dir="$WS/.nobin-$1" d f
  mkdir -p "$dir"
  printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] && [ ! -d "$f" ] || continue
      [ "$(basename "$f")" = "$drop" ] && continue
      [ -e "$dir/$(basename "$f")" ] || ln -s "$f" "$dir/" 2>/dev/null || true
    done
  done
  printf '%s' "$dir"
}

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
