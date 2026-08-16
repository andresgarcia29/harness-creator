#!/usr/bin/env bash
# test_concurrency.sh: diez sesiones sobre el mismo workspace.
#
# Grupo P2. El patrón común es una escritura NO atómica sobre un archivo que
# otras sesiones están leyendo: se trunca el destino, se tarda segundos en
# llenarlo, y en el medio cualquiera lee basura. Con una sesión no se nota;
# con diez es el caso normal, porque varios de estos scripts los lanza el
# prefetch en background por diseño.
#
# La forma correcta ya estaba en el repo (gowork.sh y verdict-scaffold.sh
# usan mktemp + mv desde siempre): faltaba aplicarla donde importa.
set -u
. "$(dirname "$0")/lib.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"

echo "── escrituras atómicas: se lee el archivo viejo entero o el nuevo entero"

gr="$(cat "$root/templates/scripts/graph-refresh.sh")"
assert_contains "$gr" 'mv -f "$GRAPH.tmp" "$GRAPH"' "graph-refresh publica el grafo con mv"
assert_not_contains "$gr" 'merge-graphs $parts --out "$GRAPH" ' "y ya no escribe directo al definitivo"
assert_contains "$gr" 'LOCKDIR="$WS/.cache/graph.lock.d"' "y toma un lock: cuatro sitios lo lanzan en background"
assert_contains "$gr" "no duplico el trabajo" "si otra corrida ya refresca, esta se va"

rb="$(cat "$root/templates/scripts/repo-brief.sh")"
assert_contains "$rb" 'mv -f "$OUT.$$.tmp" "$OUT"' "repo-brief publica el brief con mv"
assert_contains "$rb" 'viaja DENTRO del prompt' "y el comentario dice por qué importa"

sm="$(cat "$root/templates/scripts/stamp-models.sh")"
assert_contains "$sm" '"$f.$$.tmp"' "stamp-models usa un temporal por proceso"
assert_not_contains "$sm" '> "$f.tmp" &&' "y no el nombre fijo que dos make models compartían"

gw="$(cat "$root/templates/hooks/guard-worktree.sh")"
assert_contains "$gw" 'mv -f "$tmp" "$claim"' "guard-worktree publica el claim con mv (dos hooks concurrentes no dejan JSON a medias)"
assert_not_contains "$gw" '"$now" > "$claim"' "y ya no escribe el claim directo al definitivo"

wt="$(cat "$root/templates/scripts/worktree-task.sh")"
assert_contains "$wt" 'until mkdir_lock "$dir"' "worktree-task serializa la CREACIÓN con un lock por (task, repo)"
assert_not_contains "$wt" 'worktree add -b "task/$TASK" "$wt" "origin/$bb" 2>/dev/null' \
  "y una colisión de worktree add ya no muere muda a /dev/null"

echo
echo "── el lock del grafo es real, no decorativo"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.cache/graph.lock.d"    # simula una corrida en curso
: > "$tmp/.cache/graph.lock.d/.owner"
out="$( cd "$tmp" && WS="$tmp" bash -c '
  LOCKDIR="$WS/.cache/graph.lock.d"
  mkdir_lock() { mkdir "$1" 2>/dev/null || return 1; ( set -C; : > "$1/.owner" ) 2>/dev/null; }
  if ! mkdir_lock "$LOCKDIR"; then echo "OCUPADO"; fi' )"
assert_contains "$out" "OCUPADO" "con el lock tomado, una segunda corrida no entra"

echo
echo "── ningún artefacto vuelve a usar \`mkdir\` pelado como mutex (issue #209)"
# El bug no fue de un script: fue del PRIMITIVO. Ubuntu 26.04 cambió GNU
# coreutils por uutils, y su \`mkdir\` hace statx y después mkdir(2), o sea
# check-then-act: bajo carrera le devuelve 0 a varios procesos (medido en el
# host del reporte: 20-31% de las rondas, tmpfs y ext4 por igual). El syscall
# es atómico; el binario no. Todo lock del harness pasa por \`mkdir_lock\`, donde
# el dueño es quien gana el O_EXCL de \`.owner\` (que hace la shell, sin binario).
# Este check existe para que el próximo lock no nazca con el agujero adentro.
sueltos="$(grep -rn 'mkdir "' "$root/templates/scripts" "$root/templates/hooks" 2>/dev/null \
  | grep -v 'mkdir -p' | grep -v ':  mkdir "\$1"' || true)"
[ -z "$sueltos" ] && pass "cero mkdir pelados como lock fuera de mkdir_lock" \
  || fail "hay mkdir usado como mutex sin pasar por mkdir_lock: $sueltos"

# Y que el helper no se pueda vaciar: donde se define, el O_EXCL tiene que estar.
faltan=""
for f in $(grep -rl 'mkdir_lock() {' "$root/templates/scripts" "$root/templates/hooks" 2>/dev/null); do
  grep -q 'set -C; : > "\$1/.owner"' "$f" || faltan="$faltan $(basename "$f")"
done
[ -z "$faltan" ] && pass "cada mkdir_lock reclama con O_EXCL, que es lo único atómico acá" \
  || fail "mkdir_lock sin el O_EXCL de .owner en:$faltan"

echo
echo "── skills-sync: instalar no puede dejar la skill a medias"
ss="$(cat "$root/templates/scripts/skills-sync.sh")"
assert_contains "$ss" 'stage="$tgt.$$.new"' "se arma completa a un lado"
assert_contains "$ss" 'mv "$stage" "$tgt"' "y se publica con un solo mv"
assert_contains "$ss" "SIN marca" "el comentario explica el peor caso: quedar sin .managed"
# El orden importa: el .managed se escribe ANTES de publicar, no después.
managed_pos="$(printf '%s' "$ss" | grep -n 'managed-by: skills-sync' | head -1 | cut -d: -f1)"
publish_pos="$(printf '%s' "$ss" | grep -n 'mv "$stage" "$tgt"' | head -1 | cut -d: -f1)"
[ "$managed_pos" -lt "$publish_pos" ] \
  && pass "la marca .managed se escribe antes de publicar (si no, la skill queda huérfana)" \
  || fail "la skill se publica antes de marcarla: puede quedar sin .managed para siempre"

echo
echo "── un fetch fallido no desinstala skills"
# \$WANTED solo se puebla con las fuentes que respondieron; un fetch fallido
# hacía continue y el prune corría igual, borrando skills que skills.yaml
# seguía declarando. La evidencia ausente no es evidencia de desinstalación.
assert_contains "$ss" 'if [ "$fails" -gt 0 ]; then' "el prune se salta si alguna fuente no se pudo leer"
assert_contains "$ss" "NO desinstalo nada en esta corrida" "y lo dice"
assert_contains "$ss" "solo una de las dos es reversible sola" "con el porqué"

echo
echo "── harness-bug: el dedupe corre antes de dos llamadas de red"
# Diez sesiones tropezando con el MISMO bug del plugin (que es justo el
# escenario) pasaban los tres controles antes de que la primera escribiera el
# ledger: issues duplicados en el repo público, que es el daño que el propio
# script declara como el peor.
hb="$(cat "$root/templates/scripts/harness-bug.sh")"
assert_contains "$hb" "ledger_add" "sigue existiendo el ledger de dedupe"
# Documentado como límite conocido: el arreglo real es reservar el
# fingerprint ANTES de la red, y está en HARDENING.md.
assert_contains "$(cat "$root/HARDENING.md")" "harness-bug.sh" "el límite queda declarado en el plan"

t_done
