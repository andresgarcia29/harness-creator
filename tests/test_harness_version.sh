#!/usr/bin/env bash
# test_harness_version.sh: el chequeo de versión y estado de la instancia.
#
# Lo que se protege por encima de todo: **"no pude comparar" no se reporta
# como "al día"**. Es la lección que este harness pagó con doce bugs, y un
# chequeo de versión que la incumple es el peor lugar posible para
# incumplirla: te deja creyendo que tenés los arreglos que no tenés.
set -u
. "$(dirname "$0")/lib.sh"
t_ws
R="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$WS/scripts" "$WS/bin" "$WS/tasks/T1" "$WS/tasks/T2" "$WS/.harness/claims"
cp "$R/templates/scripts/harness-version.sh" "$WS/scripts/"
chmod +x "$WS/scripts/harness-version.sh"

stub_gh() {  # stub_gh <version-upstream|"">  (vacío = gh falla)
  if [ -z "$1" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$WS/bin/gh"
  else
    printf '#!/usr/bin/env bash\nprintf %s "{\\"version\\":\\"%s\\"}"\n' "'%s'" "$1" > "$WS/bin/gh"
  fi
  chmod +x "$WS/bin/gh"
}
run() { ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/harness-version.sh "$@" ) 2>&1; }
rc_of() { ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/harness-version.sh "$@" >/dev/null 2>&1; echo $?); }

echo "── el veredicto de versión, en sus tres formas"

echo "0.40.0" > "$WS/.harness-version"; stub_gh "0.47.0"
out="$(run)"
assert_contains "$out" "HAY UPDATE" "instancia vieja: lo dice"
assert_contains "$out" "0.40.0" "con la versión local"
assert_contains "$out" "0.47.0" "y la de upstream"
assert_contains "$out" "harness-init ." "y el comando exacto para actualizar"
assert_eq 1 "$(rc_of --check)" "--check: exit 1 cuando hay update"

echo "0.47.0" > "$WS/.harness-version"
out="$(run)"
assert_contains "$out" "al día" "instancia al día: lo dice"
assert_not_contains "$out" "HAY UPDATE" "y no confunde"
assert_eq 0 "$(rc_of --check)" "--check: exit 0 al día"

# EL CASO QUE IMPORTA: sin poder consultar upstream, NO se dice "al día".
stub_gh ""
out="$(run)"
assert_contains "$out" "NO pude comparar" "sin respuesta de upstream: lo dice"
assert_not_contains "$out" "al día" "y NO reporta al día (sería la mentira más cara de este script)"
assert_eq 2 "$(rc_of --check)" "--check: exit 2 = no se pudo comparar, distinto de 0 y de 1"

# gh ni siquiera instalado: hay que sacarlo del PATH, no solo borrar el stub
# (el del sistema seguiría respondiendo y el test probaría otra cosa).
rm -f "$WS/bin/gh"
out="$( cd "$WS" && PATH="$WS/bin:/usr/bin:/bin" bash scripts/harness-version.sh 2>&1 )"
assert_contains "$out" "gh no está instalado" "sin gh: dice el motivo concreto"
assert_not_contains "$out" "al día" "y tampoco inventa un veredicto"

echo
echo "── el estado que hay que mirar ANTES de actualizar"
# La fase editada a mano es lo único que un update puede empeorar:
# validate-ship compara la fase contra el último movimiento registrado.
stub_gh "0.47.0"
printf '{"phase":"review","lane":"express","review_rounds":2,"history":[{"to":"review"}]}' > "$WS/tasks/T1/state.json"
printf '{"phase":"review","lane":"full","review_rounds":1,"history":[{"to":"ship"}]}' > "$WS/tasks/T2/state.json"
out="$(run)"
assert_contains "$out" "T2" "lista las tareas con estado"
assert_contains "$out" "EDITADA A MANO" "y marca la que tiene la fase desalineada del historial"
assert_contains "$out" "history dice 'ship'" "diciendo qué esperaba encontrar"
t1_line="$(printf '%s\n' "$out" | grep -E '^  T1 ' || true)"
assert_not_contains "$t1_line" "EDITADA" "la tarea coherente NO se marca"
assert_contains "$out" "fase=review" "con su fase y su carril"

echo
echo "── sesiones, worktrees tomados y supuestos"
printf '{"session":"abc12345def","task":"T1","repo":"atlas","at":1}' > "$WS/.harness/claims/T1__atlas.json"
printf '{"ts":"x","kind":"prompt","session":"s1"}\n{"ts":"y","kind":"stop","session":"s1"}\n' > "$WS/.harness/events.jsonl"
printf -- '- SUPUESTO: el endpoint acepta null\n- SUPUESTO: el umbral es 300ms\n' > "$WS/tasks/T1/assumptions.md"
out="$(run)"
assert_contains "$out" "T1/atlas tomado por la sesión abc12345" "dice qué worktree tiene tomado quién"
assert_contains "$out" "parada(s) registradas" "avisa si alguien te está esperando"
assert_contains "$out" "2 supuesto(s) sin confirmar" "y cuenta los supuestos, que son lo primero a auditar"

echo
echo "── observa, no frena"
# Un chequeo de versión que puede tumbar tu trabajo es un bug: en modo normal
# sale 0 pase lo que pase. El único con contrato de exit code es --check.
rm -rf "$WS/tasks" "$WS/.harness" "$WS/.harness-version"
assert_eq 0 "$(rc_of)" "workspace a medias: sale 0 igual (fail-open)"
out="$(run)"
assert_contains "$out" "no declara versión" "y dice qué le falta"
assert_contains "$out" "(ninguna)" "sin tareas, lo dice en vez de romperse"

t_done
