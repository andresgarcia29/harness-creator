#!/usr/bin/env bash
# test_build_slot.sh — el semáforo de builds pesados (scripts/build-slot.sh, Ley 8), las
# tres propiedades que lo hacen seguro en una máquina compartida, SIN docker (rápido):
#   1. concurrencia acotada: HARNESS_BUILD_SLOTS=2 + 4 jobs → nunca más de 2 a la vez,
#      todos exit 0 (y al menos 2 corren en paralelo, no serializados).
#   2. sin locks huérfanos: kill -9 al holder → el siguiente adquiere en <2s (el kernel
#      libera el flock al morir el proceso).
#   3. re-entrancia: N=1 anidado NO deadlockea (HARNESS_BUILD_SLOT_HELD hace exec directo).
# Ejecuta el TEMPLATE tal cual se instala — si alguien lo rompe, esto lo cacha.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

SLOT="$ROOT/templates/scripts/build-slot.sh"
[ -f "$SLOT" ] || { echo "no encuentro $SLOT"; exit 1; }

echo "── semáforo de builds (build-slot.sh)"

# ── 1. concurrencia acotada a 2 ────────────────────────────────────────────────
# cada worker (dentro de su slot) marca su presencia, cuenta cuántos hay activos en ese
# instante, lo registra, y se va. Con 2 slots el conteo jamás debe pasar de 2.
WORKER="$WS/worker.sh"
cat > "$WORKER" <<'EOF'
#!/usr/bin/env bash
d="$1"; me="$$"
mkdir -p "$d/active"
: > "$d/active/$me"
n=$(ls "$d/active" 2>/dev/null | wc -l | tr -d ' ')
echo "$n" >> "$d/counts"
sleep 0.5
rm -f "$d/active/$me"
EOF

D="$WS/conc"; mkdir -p "$D"; : > "$D/counts"
pids=""
for _ in 1 2 3 4; do
  HARNESS_BUILD_SLOTS=2 bash "$SLOT" bash "$WORKER" "$D" &
  pids="$pids $!"
done
allok=1
for p in $pids; do wait "$p" || allok=0; done
[ "$allok" -eq 1 ] && pass "4 jobs, 2 slots: todos exit 0" || fail "algún job no salió 0"

maxn="$(sort -n "$D/counts" 2>/dev/null | tail -1)"; maxn="${maxn:-0}"
[ "$maxn" -le 2 ] && pass "concurrencia acotada: máximo simultáneo = $maxn (≤2)" \
                  || fail "concurrencia se pasó de 2: fue $maxn"
[ "$maxn" -ge 2 ] && pass "hubo paralelismo real: 2 corrieron a la vez" \
                  || fail "todo se serializó (max=$maxn) — los slots no dejan pasar 2"

# ── 2. sin locks huérfanos (kill -9 al holder → el siguiente entra en <2s) ──────
H="$WS/holder"; mkdir -p "$H"
HARNESS_BUILD_SLOTS=1 bash "$SLOT" sleep 30 &
holder=$!
# esperar a que el holder tome el único slot
sleep 0.5
HARNESS_BUILD_SLOTS=1 bash "$SLOT" touch "$H/done" &
waiter=$!
sleep 0.5
if [ -e "$H/done" ]; then
  fail "el waiter NO se bloqueó con el slot ocupado (semáforo roto)"
else
  pass "waiter bloqueado mientras el holder tiene el slot"
fi
kill -9 "$holder" 2>/dev/null
# poll <2s a que el kernel libere el lock huérfano y el waiter entre
got=0
for _ in $(seq 1 20); do
  [ -e "$H/done" ] && { got=1; break; }
  sleep 0.1
done
wait "$waiter" 2>/dev/null || true
[ "$got" -eq 1 ] && pass "lock huérfano liberado por el kernel: el waiter entró en <2s" \
                 || fail "el waiter siguió bloqueado tras kill -9 (lock huérfano inmortal)"

# ── 3. re-entrancia: N=1 anidado no deadlockea ─────────────────────────────────
run_nested() {
  bash -c "HARNESS_BUILD_SLOTS=1 bash '$SLOT' bash '$SLOT' true" &
  local pid=$! rc
  ( sleep 5; kill -9 "$pid" 2>/dev/null ) & local watcher=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return "$rc"
}
run_nested && pass "re-entrancia: N=1 anidado hace exec directo (sin deadlock)" \
           || fail "re-entrancia: N=1 anidado se colgó/deadlockeó"

t_done
