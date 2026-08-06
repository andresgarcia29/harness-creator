#!/usr/bin/env bash
# test_finding.sh: la difusión de hallazgos entre repos hermanos.
#
# POR QUÉ ESTA SUITE: el canal no existía y el único difusor era el humano
# relayando a mano. Caso de campo: tres repos escribieron el MISMO guard roto
# en la misma tarea, o sea que se pagó tres veces por descubrir una cosa. Lo
# que estos tests protegen no es que el archivo se escriba, es que el dedupe
# muerda (si no, el canal solo cambia dónde se desperdicia) y que la LECTURA
# esté acotada (si no, el canal hace crecer el contexto de todos los agentes a
# la vez, que es el problema que el harness está tratando de resolver).
set -u
. "$(dirname "$0")/lib.sh"
t_ws

F="$ROOT/templates/scripts/finding.sh"
export CLAUDE_PROJECT_DIR="$WS"
mkdir -p "$WS/tasks/T1"

echo "── finding.sh"

# 1. publicar deja una línea y read la devuelve
bash "$F" publish T1 atlas "el guard de Helm pide charts/ plural" >/dev/null
out="$(bash "$F" read T1)"
assert_contains "$out" "guard de Helm" "read devuelve el hallazgo publicado"
assert_contains "$out" "[atlas]" "y dice de qué repo salió"

# 2. DEDUPE: el mismo hallazgo desde otro repo no se paga dos veces.
#    Insensible a mayúsculas y puntuación a propósito: el orquestador relaya
#    el texto y lo re-puntúa sin querer.
bash "$F" publish T1 hermes "El guard de Helm pide charts/ plural." >/dev/null
assert_eq "1" "$(wc -l < "$WS/tasks/T1/findings.jsonl" | tr -d ' ')" \
  "el duplicado NO se escribió (ese es el punto del canal)"

# 3. un hallazgo distinto sí entra
bash "$F" publish T1 domos "el go.work del worktree no resuelve el replace" >/dev/null
assert_eq "2" "$(wc -l < "$WS/tasks/T1/findings.jsonl" | tr -d ' ')" \
  "un hallazgo nuevo sí se publica"

# 4. REDACCIÓN: los hallazgos citan comandos y salidas de error, que es
#    exactamente por donde viajan los tokens. La ley de secretos también
#    aplica a este canal.
bash "$F" publish T1 atlas "revienta con ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa en el env" >/dev/null
assert_not_contains "$(cat "$WS/tasks/T1/findings.jsonl")" "ghp_aaaaaaaaaaaa" \
  "el token viajó sin redactar al archivo"
assert_contains "$(cat "$WS/tasks/T1/findings.jsonl")" "REDACTADO" \
  "y se marcó que hubo redacción"

# 5. --exclude-repo: un implementer no necesita que le repitan lo suyo
out="$(bash "$F" read T1 --exclude-repo domos)"
assert_not_contains "$out" "go.work" "--exclude-repo no filtró el repo propio"
assert_contains "$out" "guard de Helm" "pero sí trae lo de los hermanos"

# 6. EL TECHO. Esto es lo que separa este canal del bus: lo que devuelve read
#    entra en la VENTANA de un agente y se re-lee en cada tool call suya.
for i in $(seq 1 40); do
  bash "$F" publish T1 atlas "hallazgo numero $i con texto distinto" >/dev/null
done
out="$(bash "$F" read T1 --max 5)"
n="$(printf '%s\n' "$out" | grep -c '·' || true)"
[ "$n" -le 6 ] && pass "read acotado a --max (devolvió $n líneas)" \
  || fail "read devolvió $n líneas con --max 5: el canal no tiene techo"
assert_contains "$out" "omitido" \
  "un contexto acotado debe SABERSE acotado, o el agente cree que vio todo"

# 6b. TECHO POR HALLAZGO. Era el único canal nuevo sin acotar: medido, 15
#     hallazgos de 5000 chars daban 60 KB (~17k tokens) que entran a la ventana
#     de CADA implementer y se releen en cada tool call suyo. Un hallazgo es un
#     puntero, no el informe.
mkdir -p "$WS/tasks/T3"
largo="$(python3 -c 'print("x"*5000)')"
bash "$F" publish T3 atlas "$largo" >/dev/null
n_bytes="$(wc -c < "$WS/tasks/T3/findings.jsonl" | tr -d ' ')"
[ "$n_bytes" -lt 1000 ] && pass "un hallazgo de 5000 chars se acota al publicar ($n_bytes bytes)" \
  || fail "el hallazgo entró casi entero: $n_bytes bytes"
assert_contains "$(bash "$F" read T3)" "[...]" \
  "y se marca que fue recortado: un contexto lossy debe saberse lossy"

# Y el techo total de la lectura, que es lo que entra en la ventana del agente.
for i in $(seq 1 15); do bash "$F" publish T3 atlas "$(python3 -c "print('h$i-' + 'y'*5000)")" >/dev/null; done
out_bytes="$(bash "$F" read T3 | wc -c | tr -d ' ')"
[ "$out_bytes" -lt 8000 ] && pass "16 hallazgos largos dan $out_bytes bytes de contexto" \
  || fail "read devolvió $out_bytes bytes: el canal sigue sin techo"

# 7. FAIL-OPEN: sin hallazgos, silencio y exit 0. Un implementer no se frena
#    porque todavía nadie haya descubierto nada.
mkdir -p "$WS/tasks/T2"
out="$(bash "$F" read T2)"; rc=$?
assert_eq "0" "$rc" "read sin hallazgos sale 0"
assert_eq "" "$out" "y no imprime ruido"

# 8. publicar a una tarea que no existe no explota (fail-open)
bash "$F" publish T-INEXISTENTE atlas "algo" >/dev/null 2>&1
assert_eq "0" "$?" "publish a tarea inexistente es fail-open"

t_done
