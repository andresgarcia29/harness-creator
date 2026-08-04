#!/usr/bin/env bash
# test_bounded.sh: run_bounded acota DE VERDAD.
#
# Cada aserción de acá corresponde a un modo de falla MEDIDO del idiom que
# `bounded.sh` vino a reemplazar (`perl -e 'alarm N; exec @ARGV'`, que vivía en
# ship.sh como con_limite y en deploy-watch en la etapa verify):
#
#   · el árbol   → timeout de 2s, VEINTE segundos de reloj: el nieto huérfano
#                  sostenía el pipe del $( ) y el acotador ya había reportado
#                  que acotó.
#   · la señal   → un hijo con SIGALRM ignorado devolvía rc=0 tras 9s. Un
#                  cuelgue que pasa por verde.
#   · la escalada→ no existía: nada mandaba SIGKILL.
#
# Los tres se prueban en los DOS caminos (binario nativo y fallback en perl),
# porque si no cada plataforma deja el otro sin ejercitar para siempre: en
# Ubuntu `timeout` existe y el perl no se toca nunca, en macOS al revés.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/bin"
cp "$ROOT/templates/scripts/bounded.sh" "$WS/scripts/"

# El hijo que reproduce el bug del árbol: deja un nieto vivo que HEREDA stdout.
# Es la forma de cualquier verify_cmd real (un script que lanza curl o kubectl)
# y de las sondas de node de ship.sh.
cat > "$WS/bin/deja-nieto.sh" <<'EOF'
#!/bin/sh
sleep 30 &
echo "el padre ya dijo lo suyo"
wait
EOF
chmod +x "$WS/bin/deja-nieto.sh"

# El que ignora SIGTERM: obliga a la escalada a SIGKILL. Tiene que ignorarla el
# proceso QUE ESPERA, no su shell: un `trap '' TERM; sleep 10` en sh no prueba
# nada, porque el sleep es otro proceso y recibe la señal igual.
cat > "$WS/bin/ignora-term.sh" <<'EOF'
#!/usr/bin/env perl
$SIG{TERM} = "IGNORE";
sleep 30;
EOF
chmod +x "$WS/bin/ignora-term.sh"

# corre <forzar-perl> <segundos> <gracia> <cmd...> → imprime "rc elapsed"
# Captura en $( ) A PROPÓSITO: el bug del árbol solo se manifiesta cuando algo
# lee el pipe. Con la salida suelta, el idiom viejo pasaba este test.
corre() {
  local forzar="$1"; shift
  ( set +u
    . "$WS/scripts/bounded.sh"
    [ "$forzar" = perl ] && HARNESS_TIMEOUT_BIN=""
    t0=$(date +%s); rc=0
    out="$(run_bounded "$@" 2>/dev/null)" || rc=$?
    t1=$(date +%s)
    echo "$rc $((t1 - t0))" )
}

for via in nativo perl; do
  if [ "$via" = nativo ] && ! command -v timeout >/dev/null 2>&1 \
                         && ! command -v gtimeout >/dev/null 2>&1; then
    echo; echo "── camino nativo: saltado (no hay timeout/gtimeout en esta máquina)"
    continue
  fi
  echo
  echo "── camino $via"

  # (1) EL ÁRBOL. Con el idiom viejo esto medía 30s con un límite de 2.
  set -- $(corre "$via" 2 1 "$WS/bin/deja-nieto.sh")
  assert_eq 124 "$1" "$via: se agota con 124 (contrato de timeout(1), no 142)"
  [ "$2" -le 8 ] \
    && pass "$via: mata el ÁRBOL: el \$( ) vuelve en ${2}s, no espera al nieto" \
    || fail "$via: el nieto huérfano sostuvo el pipe ${2}s (límite era 2): NO acota"

  # (2) LA ESCALADA. Con el idiom viejo esto devolvía 0.
  set -- $(corre "$via" 2 1 "$WS/bin/ignora-term.sh")
  assert_eq 124 "$1" "$via: el que IGNORA TERM igual sale 124 (nunca 0: un cuelgue no pasa por verde)"
  [ "$2" -le 8 ] \
    && pass "$via: escala a SIGKILL tras la gracia (${2}s)" \
    || fail "$via: sin escalada, el que ignora TERM sobrevivió ${2}s"

  # (3) El camino feliz no se toca: el rc real pasa tal cual.
  set -- $(corre "$via" 5 1 sh -c 'exit 7')
  assert_eq 7 "$1" "$via: pasa el exit code real cuando termina a tiempo"

  set -- $(corre "$via" 5 1 sh -c 'exit 0')
  assert_eq 0 "$1" "$via: exit 0 sigue siendo exit 0"

  # (4) Comando inexistente: 127 en los dos caminos, no un timeout fantasma.
  set -- $(corre "$via" 5 1 "$WS/bin/no-existe-nada")
  assert_eq 127 "$1" "$via: comando inexistente da 127, no se cuelga ni miente"
done

echo
echo "── el contrato está escrito donde se lee"

src="$(cat "$ROOT/templates/scripts/bounded.sh")"
assert_contains "$src" 'kill("TERM", -$pid)' "el fallback señala al GRUPO (el PID negativo es todo el arreglo)"
assert_contains "$src" 'kill("KILL", -$pid)' "el fallback escala a SIGKILL"
assert_contains "$src" 'exec { $ARGV[0] } @ARGV' "usa la forma de bloque: nunca pasa por /bin/sh"
assert_contains "$src" "exit 124" "se agota con 124, igual que timeout(1)"

# ── El idiom viejo NO puede volver a aparecer en ningún script ────────
# Es la regresión que este archivo existe para hacer imposible: se escribe una
# vez, se copia por ahí, y vuelve a haber acotadores que no acotan.
# Se ignoran los COMENTARIOS: bounded.sh cita el idiom textual para explicar por
# qué no sirve, y un guard que no distingue código de prosa prohibiría
# justamente documentar el bug.
echo
echo "── ningún script vuelve al perl alarm"
viejo="$(grep -rn "alarm shift @ARGV" "$ROOT/templates/scripts/" 2>/dev/null \
         | grep -v ':[0-9]*:[[:space:]]*#' || true)"
[ -z "$viejo" ] \
  && pass "ningún template usa 'alarm shift @ARGV' (el acotador que no acotaba)" \
  || fail "volvió el perl alarm: $viejo"

t_done
