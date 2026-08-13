#!/usr/bin/env bash
# test_deploy_coalesce.sh: un watcher por REPO, no uno por ship.
#
# El número que lo justifica: una familia de 13 lotes sobre el mismo repo pagó
# 13 ciclos de deploy (8-12 min cada uno) cuando ArgoCD despliega HEAD y los
# ancestros van incluidos. Lo que se prueba acá es que el ahorro no compra
# ceguera: el segundo ship queda ANOTADO (no ignorado), el watcher vivo
# re-apunta al sha más nuevo, y el log llega a TODAS las tareas cubiertas.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/.harness" "$WS/tasks/T-A" "$WS/tasks/T-B" "$WS/repos"
cp "$ROOT/templates/scripts/emit.sh" "$ROOT/templates/scripts/bounded.sh" "$WS/scripts/"
sed -e 's|{{GITHUB_ORG}}|org-demo|g' -e 's|{{ARGO_APP_PREFIX}}||g' \
    -e 's|{{ROLLBACK_MODE}}|revert|g' -e 's|{{KARGO_PROJECT}}|p|g' \
    "$ROOT/templates/scripts/deploy-watch.sh.tmpl" > "$WS/scripts/deploy-watch.sh"
# driver none: este test mide la coalescencia, no el cluster. `none` recorta
# las etapas de red sin tocar una línea de la maquinaria que sí se prueba.
cat > "$WS/harness-answers.yaml" <<'YAML'
deploy:
  atlas:
    driver: none
YAML
cat > "$WS/manifest.yaml" <<'YAML'
repos:
  - name: atlas
    kind: tool
YAML

# Un repo de verdad: el re-apunte comprueba ANCESTRÍA con git, así que un
# repo de mentira probaría otra cosa.
git init -q -b main "$WS/repos/atlas"
( cd "$WS/repos/atlas" && printf 'a\n' > f.txt && git add -A && git commit -qm uno )
SHA1="$(git -C "$WS/repos/atlas" rev-parse HEAD)"
( cd "$WS/repos/atlas" && printf 'b\n' >> f.txt && git add -A && git commit -qm dos )
SHA2="$(git -C "$WS/repos/atlas" rev-parse HEAD)"
# Historia SIN relación con la trunk (rama huérfana): verificar ese sha no
# verificaría nada de lo que este watcher está mirando.
( cd "$WS/repos/atlas" && git checkout -q --orphan huerfana && git rm -rqf . \
  && printf 'z\n' > otro.txt && git add -A && git commit -qm huerfana && git checkout -qf main )
SHA_HUERFANO="$(git -C "$WS/repos/atlas" rev-parse huerfana)"

ship() {  # ship <task> <sha>
  printf '{"repo":"atlas","sha":"%s","landed":true}\n' "$2" > "$WS/tasks/$1/ship.log"
}
watch() {  # watch <task> [--coalesce]
  ( cd "$WS" && CLAUDE_PROJECT_DIR="$WS" DEPLOY_HARD_LIMIT=60 \
      bash scripts/deploy-watch.sh "$1" atlas "${2:-}" 2>&1 )
}
reg() { cat "$WS/.harness/deploy-pending/atlas.jsonl" 2>/dev/null; }

echo "── el primer ship elige watcher y anota su sha"
ship T-A "$SHA1"
out="$(watch T-A --coalesce)"
assert_contains "$out" "soy el watcher de atlas" "el primero se queda con el repo"
assert_file "$WS/tasks/T-A/deploy-atlas.log" "deja su log donde /archive lo busca"
assert_no_file "$WS/.harness/deploy-pending/atlas.jsonl" \
  "al terminar suelta el registro (si no, el próximo ship se creería cubierto por un muerto)"
assert_no_file "$WS/.harness/deploy-pending/atlas.lock.d" "y el lock"

echo
echo "── con un watcher VIVO, el segundo ship se anota y sale en el acto"
mkdir -p "$WS/.harness/deploy-pending"
# Un dueño vivo de verdad, y sin reloj: el pid de ESTE test.
#
# Antes era `sleep 30 &`, y eso metía un plazo donde no hacía falta ninguno: el
# bloque de arriba corre un ciclo de deploy REAL, así que en una máquina cargada
# tarda más de 30 segundos y el dueño llegaba muerto a esta aserción. El watcher
# entonces hacía lo correcto (no hay dueño vivo: arranco) y el test lo leía como
# rojo. Medido: la corrida entera son ~2 min, y con el sleep en 600 las 15
# aserciones pasan. O sea que medía la carga de la máquina, no la coalescencia.
# El pid del propio test está vivo por definición mientras el test corre, que es
# exactamente la propiedad que la aserción necesita.
VIVO=$$
mkdir -p "$WS/.harness/deploy-pending/atlas.lock.d"
echo "$VIVO" > "$WS/.harness/deploy-pending/atlas.lock.d/pid"
ship T-B "$SHA2"
out="$(watch T-B --coalesce)"
assert_contains "$out" "ya hay un watcher vivo" "no arranca un segundo ciclo de deploy"
assert_contains "$out" "$VIVO" "y dice quién lo está mirando"
assert_contains "$(reg)" "$SHA2" "pero deja anotado su sha: coalescer no es ignorar"
# El dueño se retira borrando su lock, no matando el proceso (que es este test).
rm -rf "$WS/.harness/deploy-pending/atlas.lock.d"

echo
echo "── el watcher vivo RE-APUNTA al sha más nuevo (y solo si desciende)"
# Se extrae la maquinaria real del template: una imitación probaría la imitación.
sed -n '/^# ── COALESCENCIA POR REPO/,/^# La atribución NO es cosmética/p' \
  "$WS/scripts/deploy-watch.sh" > "$WS/coalesce.sh"
grep -q "coalesce_repoint" "$WS/coalesce.sh" || { echo "no pude extraer el bloque de coalesce"; exit 1; }

repoint() {  # repoint <sha-vigilado> <shas-anotados...> → el sha que quedó
  ( set -uo pipefail
    cd "$WS"; WS="$WS"; REPO=atlas; TASK=T-A; LOG="$WS/x.log"
    say() { echo "$1" >> "$LOG"; }
    . "$WS/scripts/bounded.sh"; CALL_TIMEOUT=5; CALL_GRACE=1
    . "$WS/scripts/emit.sh"
    . "$WS/coalesce.sh"
    COALESCE_MINE=1; LANDED_SHA="$1"; shift
    mkdir -p "$COALESCE_DIR"; : > "$COALESCE_REG"
    for s in "$@"; do printf '{"task":"T-Z","repo":"atlas","sha":"%s"}\n' "$s" >> "$COALESCE_REG"; done
    coalesce_repoint || true
    printf '%s' "$LANDED_SHA" )
}
assert_eq "$SHA2" "$(repoint "$SHA1" "$SHA2")" "adopta el sha más nuevo, que contiene al viejo"
assert_eq "$SHA2" "$(repoint "$SHA2" "$SHA1")" \
  "NO retrocede a un sha viejo aunque llegue después: ese no contiene lo que ya vigila"
assert_eq "$SHA1" "$(repoint "$SHA1" "$SHA_HUERFANO")" \
  "ni adopta una historia sin relación: verificarla no verificaría este ship"
assert_eq "$SHA1" "$(repoint "$SHA1" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")" \
  "ni un sha que el repo no tiene: no se afirma sobre lo que no se puede mirar"

echo
echo "── la atribución: el log llega a TODAS las tareas cubiertas"
rm -rf "$WS/.harness/deploy-pending"
ship T-A "$SHA1"
mkdir -p "$WS/.harness/deploy-pending"
printf '{"task":"T-B","repo":"atlas","sha":"%s"}\n' "$SHA2" > "$WS/.harness/deploy-pending/atlas.jsonl"
rm -f "$WS/tasks/T-B/deploy-atlas.log"
out="$(watch T-A --coalesce)"
assert_file "$WS/tasks/T-B/deploy-atlas.log" \
  "la tarea cubierta recibe el log (sin él aparecería 'sin verificar' habiéndolo estado)"
assert_contains "$(cat "$WS/.harness/events.jsonl")" "coalescido" "y el bus lo cuenta"

echo
echo "── sin --coalesce, nada cambia: cada ship su watcher"
rm -rf "$WS/.harness/deploy-pending"
out="$(watch T-A)"
assert_no_file "$WS/.harness/deploy-pending/atlas.jsonl" "no se anota en ningún registro"
assert_not_contains "$out" "coalesce" "ni menciona la coalescencia"

t_done
