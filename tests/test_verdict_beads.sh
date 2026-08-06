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

# stub de bd con el formato real: soporta --silent (la interfaz de scripting) y
# ensucia la salida ANTES del id, como bd en campo (nombre de db, avisos).
export BDLOG="$WS/bd-calls.log"; : > "$BDLOG"
mk_bd() {  # mk_bd  → bd moderno, con --silent
  cat > "$WS/bin/bd" <<'SH'
#!/bin/sh
echo "bd $*" >> "$BDLOG"
n=$(grep -c 'create' "$BDLOG" | tr -d ' ')
echo "aviso: base de datos test-beads sin sincronizar" >&2
case " $* " in
  *" --silent "*) echo "workspace-00$n" ;;
  *) echo "Created issue: workspace-00$n - $2" ;;
esac
SH
  chmod +x "$WS/bin/bd"
}
mk_bd_viejo() {  # mk_bd_viejo → bd sin --silent: cobra falla al parsear la flag
  cat > "$WS/bin/bd" <<'SH'
#!/bin/sh
echo "bd $*" >> "$BDLOG"
case " $* " in
  *" --silent "*) echo "Error: unknown flag: --silent" >&2; exit 1 ;;
esac
n=$(grep -c 'silent' "$BDLOG" | tr -d ' ')
echo "aviso: base de datos test-beads sin sincronizar"
echo "Created issue: workspace-00$n - $2"
SH
  chmod +x "$WS/bin/bd"
}
mk_bd
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
assert_eq "workspace-001" "$(jq -r '.non_blocking[0].bead' "$V")" \
  "el bead escrito es el id que bd devolvió, no el primer token con guion de la salida"
assert_not_contains "$(jq -r '[.non_blocking[].bead] | join(" ")' "$V")" "test-beads" \
  "el aviso ruidoso de bd no se cuela como id (caso de campo: veredicto afirmando un bead inexistente)"

echo "── idempotencia: la segunda corrida no toca nada"

h1="$(shasum "$V" | cut -d' ' -f1)"
: > "$BDLOG"
out="$(run_beads)"; rc=$?
assert_eq 0 "$rc" "segunda corrida: exit 0"
assert_eq "$h1" "$(shasum "$V" | cut -d' ' -f1)" "el veredicto queda byte-idéntico"
assert_eq "0" "$(grep -c 'bd create' "$BDLOG" || true)" "y bd no se invoca ni una vez"

echo "── bd sin --silent: el id sale de la línea de creación, no del ruido"

mk_bd_viejo
: > "$BDLOG"
mk_verdict '["hallazgo con un bd que no tiene la flag"]'
out="$(run_beads)"; rc=$?
assert_eq 0 "$rc" "bd viejo: exit 0 (reintenta sin la flag que rechaza)"
assert_eq "workspace-001" "$(jq -r '.non_blocking[0].bead' "$V")" \
  "el id es el de la línea Created, no el token con guion que bd imprime antes"
assert_eq "2" "$(grep -c 'bd create' "$BDLOG" || true)" \
  "dos invocaciones: la que rebota al parsear la flag (sin crear nada) y la real"

mk_bd
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

# EXISTIR NO ES SER LEGIBLE, y este es el eslabón que volvía SILENCIOSA la
# cascada de un data-loss: con el veredicto en 0 bytes (lo que dejaba
# verdict-scaffold --merge-qa antes del arreglo), `jq length` devolvía vacío, el
# `while [ "$i" -lt "$n" ]` moría con "integer expression expected" (que set -e
# no atrapa en una condición) y este script reportaba "0 bead(s) creados, 0
# fallo(s)" con EXIT 0: el pipeline seguía como si nada sobre el único artefacto
# que el ship exige, ya destruido.
mk_bd
: > "$V"
out="$(run_beads)"; rc=$?
assert_eq 1 "$rc" "veredicto de 0 bytes: exit 1 (antes: '0 bead(s) creados' con exit 0)"
assert_contains "$out" "DATA LOSS" "y lo NOMBRA en vez de reportar 'nada que hacer'"
assert_contains "$out" "verdict-scaffold.sh T1 atlas" "con la remediación exacta"
printf '{"schema":1,"task_id":"T1"}\n' > "$V"     # JSON válido, pero sin commit
out="$(run_beads)"; rc=$?
assert_eq 1 "$rc" "veredicto truncado (sin commit): exit 1"

rm -f "$V"
out="$(run_beads)"; rc=$?
assert_eq 1 "$rc" "sin veredicto: exit 1"
assert_contains "$out" "/review" "con la remediación"

t_done
