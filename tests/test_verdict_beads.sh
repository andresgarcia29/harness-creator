#!/usr/bin/env bash
# test_verdict_beads.sh: non_blocking → beads como comando, no como disciplina.
# La cadena estaba afirmada en cuatro prompts y ejecutada en cero (caso de
# campo: una decisión de diferimiento vivía solo en tasks/ gitignoreado, o
# sea que por la Ley 7 no existía).
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/tasks/T1" "$WS/bin"
cp "$ROOT/templates/scripts/verdict-beads.sh" "$WS/scripts/"

V="$WS/tasks/T1/verdict-atlas.json"
mk_verdict() {  # mk_verdict <non_blocking-json>
  jq -n --argjson nb "$1" \
    '{schema:1, task_id:"T1", repo:"atlas",
      commit:"aaaa111122223333aaaa111122223333aaaa1111",
      verdict:"pass", qa:"pass", non_blocking:$nb}' > "$V"
}

# stub de bd que loggea y emite un id con el formato real
export BDLOG="$WS/bd-calls.log"; : > "$BDLOG"
cat > "$WS/bin/bd" <<'SH'
#!/bin/sh
echo "bd $*" >> "$BDLOG"
echo "Created hc-00$(wc -l < "$BDLOG" | tr -d ' ')"
SH
chmod +x "$WS/bin/bd"
run_beads() { ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/verdict-beads.sh T1 atlas 2>&1 ); }

echo "── string → objeto {text, bead}, con el origen en el cuerpo"

mk_verdict '["nombre de variable pobre", "falta un indice en la tabla"]'
out="$(run_beads)"; rc=$?
assert_eq 0 "$rc" "dos strings sin bead: exit 0"
assert_eq "2" "$(jq '[.non_blocking[] | select(type == "object" and .bead)] | length' "$V")" \
  "las dos entradas quedaron como objeto con bead"
assert_eq "nombre de variable pobre" "$(jq -r '.non_blocking[0].text' "$V")" \
  "el texto original se conserva"
assert_contains "$(cat "$BDLOG")" "T1 / atlas" "el cuerpo del bead nombra tarea y repo"
assert_contains "$(cat "$BDLOG")" "verdict-atlas.json" "y la ruta del veredicto (el domicilio)"

echo "── idempotencia: la segunda corrida no toca nada"

h1="$(shasum "$V" | cut -d' ' -f1)"
: > "$BDLOG"
out="$(run_beads)"; rc=$?
assert_eq 0 "$rc" "segunda corrida: exit 0"
assert_eq "$h1" "$(shasum "$V" | cut -d' ' -f1)" "el veredicto queda byte-idéntico"
assert_eq "0" "$(grep -c 'bd create' "$BDLOG" || true)" "y bd no se invoca ni una vez"

echo "── sin bd en PATH: honesto y sin tocar nada"

mk_verdict '["hallazgo sin motor"]'
h1="$(shasum "$V" | cut -d' ' -f1)"
out="$( ( cd "$WS" && PATH="$(t_path_without bd)" bash scripts/verdict-beads.sh T1 atlas 2>&1 ) )"; rc=$?
assert_eq 0 "$rc" "sin bd: exit 0 (no se exige lo que la máquina no puede dar)"
assert_contains "$out" "no está en PATH" "lo dice"
assert_eq "$h1" "$(shasum "$V" | cut -d' ' -f1)" "y el veredicto queda byte-idéntico"

echo "── bd que falla o no da id: la entrada NO se reescribe"

printf '#!/bin/sh\necho "error interno" >&2\nexit 1\n' > "$WS/bin/bd"
chmod +x "$WS/bin/bd"
mk_verdict '["entrada que no va a poder"]'
out="$(run_beads)"; rc=$?
assert_eq 1 "$rc" "bd create falla: exit 1"
assert_eq "string" "$(jq -r '.non_blocking[0] | type' "$V")" "la entrada sigue siendo string (sin bead inventado)"

printf '#!/bin/sh\necho "ok pero sin id reconocible ~~~ !!!"\n' > "$WS/bin/bd"
chmod +x "$WS/bin/bd"
out="$(run_beads)"; rc=$?
assert_eq 1 "$rc" "bd sin id extraíble: exit 1"
assert_contains "$out" "no pude extraer el id" "nombra la causa"

echo "── entradas hostiles"

bash "$WS/scripts/verdict-beads.sh" "../evil" atlas >/dev/null 2>&1 && fail "task traversal pasó" || pass "task-id inválido: rechazado"
rm -f "$V"
out="$(run_beads)"; rc=$?
assert_eq 1 "$rc" "sin veredicto: exit 1"
assert_contains "$out" "/review" "con la remediación"

t_done
