#!/usr/bin/env bash
# test_verdict_scaffold.sh: el esqueleto determinista del veredicto contra el
# código REAL del template. Protege: el reviewer solo pone juicio; los campos
# mecánicos salen de fuentes verificables; los fail-closed distinguen sus
# causas (cero evidencia vs evidencia de otro commit vs violación de roles);
# y el scaffold es idempotente a BYTES.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/tasks/T1/evidence" "$WS/worktrees/T1"
cp "$ROOT/templates/scripts/verdict-scaffold.sh" "$WS/scripts/"

# worktree falso con HEAD real
git init -q -b main "$WS/worktrees/T1/atlas"
git -C "$WS/worktrees/T1/atlas" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
HEAD="$(git -C "$WS/worktrees/T1/atlas" rev-parse HEAD)"

mk_ev() {  # mk_ev <id> <runner> <kind> <commit>
  jq -n --arg id "$1" --arg r "$2" --arg k "$3" --arg c "$4" \
    '{schema:1, id:$id, task_id:"T1", repo:"atlas", kind:$k, runner:$r,
      commit:$c, commit_after:$c, exit_code:0, output:("evidence/"+$id+".log"),
      output_sha256:"deadbeef"}' > "$WS/tasks/T1/evidence/$1.json"
}

echo "── verdict-scaffold: el reviewer solo pone juicio"

# 1. cero evidencias → exit 3 con remediación de evidence.py
out="$(bash "$WS/scripts/verdict-scaffold.sh" T1 atlas 2>&1)"; rc=$?
assert_eq 3 "$rc" "sin EVs: exit 3"
assert_contains "$out" "evidence.py run" "sin EVs: remediación exacta"

# 2. evidencia de OTRO commit → exit 3 citando el caso (el más común en campo)
mk_ev EV-TEST-aaaaaaaaaaaa impl-atlas test "0000000000000000000000000000000000000000"
out="$(bash "$WS/scripts/verdict-scaffold.sh" T1 atlas 2>&1)"; rc=$?
assert_eq 3 "$rc" "EVs stale: exit 3"
assert_contains "$out" "OTRO commit" "stale: el mensaje distingue la causa"

# 3. happy path: campos deterministas correctos
mk_ev EV-TEST-bbbbbbbbbbbb impl-atlas test "$HEAD"
mk_ev EV-LINT-cccccccccccc impl-atlas lint "$HEAD"
mk_ev EV-TEST-dddddddddddd qa test "$HEAD"
bash "$WS/scripts/verdict-scaffold.sh" T1 atlas revisor-1 >/dev/null 2>&1 \
  && pass "happy path: exit 0" || fail "happy path falló"
V="$WS/tasks/T1/verdict-atlas.json"
assert_eq "$HEAD" "$(jq -r .commit "$V")" "commit = HEAD del worktree"
assert_eq "PENDING_REVIEWER" "$(jq -r .verdict "$V")" "verdict placeholder inescapable"
assert_eq "-1" "$(jq -r .requirements_uncovered "$V")" "requirements_uncovered=-1 (null pasaría el gate)"
assert_eq "3" "$(jq '.evidence | length' "$V")" "los 3 EVs del commit correcto (el stale fuera; el de qa SÍ es evidencia)"
wait_no=$(jq -r '.implementation_agents | join(",")' "$V")
assert_eq "impl-atlas" "$wait_no" "implementation_agents = runners menos qa/reviewer"

# 4. idempotencia a bytes con --force
h1="$(shasum "$V" | cut -d' ' -f1)"
bash "$WS/scripts/verdict-scaffold.sh" --force T1 atlas revisor-1 >/dev/null 2>&1
h2="$(shasum "$V" | cut -d' ' -f1)"
assert_eq "$h1" "$h2" "re-scaffold con --force: bytes idénticos"

# 5. existente sin --force → exit 3 mostrando el commit previo
out="$(bash "$WS/scripts/verdict-scaffold.sh" T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 3 "$rc" "existente sin --force: exit 3"
assert_contains "$out" "$(printf '%s' "$HEAD" | cut -c1-12)" "muestra el commit del veredicto previo"

# 6. runners solo qa/reviewer → violación de roles detectada temprano
rm -f "$V" "$WS"/tasks/T1/evidence/EV-*bbbb* "$WS"/tasks/T1/evidence/EV-*cccc* "$WS"/tasks/T1/evidence/EV-*aaaa*
out="$(bash "$WS/scripts/verdict-scaffold.sh" T1 atlas revisor-1 2>&1)"; rc=$?
assert_eq 3 "$rc" "solo qa como runner: exit 3"
assert_contains "$out" "roles" "explica la política de roles"

# 7. ids inválidos → exit 1 (sin traversal)
bash "$WS/scripts/verdict-scaffold.sh" "../evil" atlas >/dev/null 2>&1 && fail "task traversal pasó" || pass "task-id inválido: exit 1"
bash "$WS/scripts/verdict-scaffold.sh" T1 "re/po" >/dev/null 2>&1 && fail "repo traversal pasó" || pass "repo inválido: exit 1"

t_done
