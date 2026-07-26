#!/usr/bin/env bash
# test_precheck.sh — `ship.sh --precheck`: los gates mecánicos ANTES de gastar
# una ronda de reviewer. Contra el CÓDIGO REAL del template (instanciado con
# sed, como haría el generador). Lo que se verifica es lo que hace de esto una
# ganancia de velocidad y no un gate más:
#   · verde deja sello con el commit revisado (lo lee /review)
#   · rojo deja sello ok:false, sale != 0 y dice que NO se entregue a review
#   · nunca pide veredicto (el reviewer todavía no existe) ni hace push
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/bin" "$WS/tasks/T1" "$WS/repos" "$WS/worktrees/T1"
sed 's/{{LOOP_BUDGET}}/3/g' "$ROOT/templates/scripts/ship.sh.tmpl" > "$WS/scripts/ship.sh"
# El precheck sella su corrida como evidencia, así que necesita a sus vecinos:
# sin evidence.py toma la rama vieja (correr sin sellar) y el test no probaría
# el camino que de verdad usa una instancia.
cp "$ROOT/templates/scripts/evidence.py" "$ROOT/templates/scripts/change-id.sh" "$WS/scripts/"
bash -n "$WS/scripts/ship.sh" && pass "ship.sh instanciado: sintaxis válida" \
  || { fail "ship.sh instanciado: error de sintaxis"; t_done; }

# gitleaks stubeado: el precheck lo corre siempre y en CI no está instalado.
stub_gitleaks() { printf '#!/bin/sh\n%s\n' "$1" > "$WS/bin/gitleaks"; chmod +x "$WS/bin/gitleaks"; }

git init -q "$WS/repos/svc"
( cd "$WS/repos/svc"
  git config user.email t@t; git config user.name t
  echo base > app.txt; git add .; git commit -qm init
  git update-ref refs/remotes/origin/main HEAD )
cp -R "$WS/repos/svc" "$WS/worktrees/T1/svc"
( cd "$WS/worktrees/T1/svc"; echo nuevo > feature.txt; git add .
  git commit -qm "feat

Task: T1" )
head="$( cd "$WS/worktrees/T1/svc" && git rev-parse HEAD )"

run_precheck() { ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T1 svc 2>&1 ); }

echo "── precheck verde"
stub_gitleaks 'exit 0'
out="$(run_precheck)"; rc=$?
assert_eq 0 "$rc" "worktree limpio: exit 0"
assert_contains "$out" "sin veredicto: precheck" "no corre el grupo de veredicto"
assert_not_contains "$out" "veredicto de review" "no exige verdict-<repo>.json"
assert_file "$WS/tasks/T1/precheck-svc.json" "deja el sello que lee /review"
sello="$(cat "$WS/tasks/T1/precheck-svc.json")"
assert_contains "$sello" '"ok":true' "sello verde"
assert_contains "$sello" "$head" "el sello ata al HEAD revisado (un commit nuevo lo invalida)"

echo "── precheck rojo"
stub_gitleaks 'echo "leak: token en app.txt"; exit 1'
out="$(run_precheck)"; rc=$?
[ "$rc" -ne 0 ] && pass "gate rojo: exit != 0" || fail "gate rojo: salió 0"
assert_contains "$out" "NO entregues a review" "el mensaje es el prompt del fix"
assert_contains "$out" "NO consume presupuesto de loop" "deja claro que no cuenta como ronda"
sello="$(cat "$WS/tasks/T1/precheck-svc.json")"
assert_contains "$sello" '"ok":false' "sello rojo (el /review no debe lanzar a nadie)"

echo "── trailer y carril: se cazan ACÁ, donde el arreglo todavía es gratis"
# Antes los dos vivían SOLO en el camino de ship, o sea que un commit sin
# `Task:` o un express que tocó un .proto se descubrían después de pagar review
# y QA. Peor: la remediación del trailer es un amend, que MUEVE HEAD y por lo
# tanto invalida la evidencia y el veredicto ya emitidos. En precheck no hay
# nada que invalidar todavía, así que el mismo arreglo cuesta cero.
stub_gitleaks 'exit 0'
mkdir -p "$WS/worktrees/T2/svc" "$WS/tasks/T2"
cp -R "$WS/repos/svc/." "$WS/worktrees/T2/svc/"
( cd "$WS/worktrees/T2/svc"; echo x > f.txt; git add .; git commit -qm "sin trailer" )
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T2 svc 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && pass "commit sin trailer: el precheck lo caza (antes: recién en ship)" \
  || fail "commit sin trailer pasó el precheck"
assert_contains "$out" "sin trailer" "nombra la causa exacta"

# carril express que toca contratos: el retroceso más caro del pipeline
# (escalar carril → volver a /rfc → re-planear → re-implementar).
mkdir -p "$WS/worktrees/T3/svc" "$WS/tasks/T3"
cp -R "$WS/repos/svc/." "$WS/worktrees/T3/svc/"
printf '{"lane":"express"}' > "$WS/tasks/T3/state.json"
( cd "$WS/worktrees/T3/svc"; mkdir -p proto; echo 'message X{}' > proto/api.proto
  git add .; git commit -qm "toca proto

Task: T3" )
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T3 svc 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && pass "express que toca proto: el precheck lo caza antes del review" \
  || fail "carril violado pasó el precheck"
assert_contains "$out" "escalate" "da la remediación de escalar carril"

# Sin commits todavía no hay nada que verificar, y eso NO es un rojo: el
# implementer corre el precheck a mitad de trabajo para mirar sus tests.
mkdir -p "$WS/worktrees/T4/svc" "$WS/tasks/T4"
cp -R "$WS/repos/svc/." "$WS/worktrees/T4/svc/"
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T4 svc 2>&1 )"; rc=$?
assert_eq 0 "$rc" "sin commits todavía: no bloquea (se corre a mitad de trabajo)"
assert_contains "$out" "sin trailer ni carril que verificar" "y dice por qué no verificó"

echo "── el precheck no toca main"
( cd "$WS/repos/svc" && git rev-parse origin/main ) > "$WS/before"
stub_gitleaks 'exit 0'; run_precheck >/dev/null 2>&1
( cd "$WS/repos/svc" && git rev-parse origin/main ) > "$WS/after"
assert_eq "$(cat "$WS/before")" "$(cat "$WS/after")" "origin/main intacto: no hay push en precheck"
assert_no_file "$WS/locks/svc.lock.d" "no toma el lock de ship (no serializa a nadie)"

echo
echo "── el sello de evidencia no puede mentir sobre lo que probó"
# Encontrado corriendo ship.sh de punta a punta: el precheck sella su corrida
# de gates como EV-TEST, y esa evidencia es justo la que satisface
# --require-fresh-kind test en el ship. En un repo cuyo stack NO reconoce
# ningún gate, la corrida no compila ni testea nada, así que el sello diría
# "este árbol pasa la suite" sin que ninguna suite haya corrido.

# 1. repo CON stack (python): sella, y el marcador dice que verificó
mkdir -p "$WS/worktrees/T8/svc" "$WS/tasks/T8"
cp -R "$WS/repos/svc/." "$WS/worktrees/T8/svc/"
( cd "$WS/worktrees/T8/svc"
  printf '[project]\nname="svc"\nversion="0.1"\n' > pyproject.toml
  mkdir -p tests && printf 'def test_ok():\n    assert 1 == 1\n' > tests/test_a.py
  git add -A; git commit -qm "con stack

Task: T8" )
if command -v ruff >/dev/null 2>&1 && command -v pytest >/dev/null 2>&1; then
  ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T8 svc >/dev/null 2>&1 ) || true
  n="$(ls "$WS/tasks/T8/evidence/"EV-*.json 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -ge 1 ] && pass "stack reconocido: SÍ sella evidencia" || fail "stack reconocido: no selló"
  assert_eq "1" "$(cat "$WS/tasks/T8/.langseen-svc" 2>/dev/null)" "y el marcador declara que verificó algo"
else
  pass "stack reconocido: saltado (falta ruff/pytest en esta máquina)"
  pass "marcador: saltado por lo mismo"
fi

# 2. repo SIN stack reconocido: NO sella, y lo dice
mkdir -p "$WS/worktrees/T9/svc" "$WS/tasks/T9"
cp -R "$WS/repos/svc/." "$WS/worktrees/T9/svc/"
( cd "$WS/worktrees/T9/svc"; echo hola > README.txt; git add -A; git commit -qm "sin stack

Task: T9" )
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T9 svc 2>&1 )"
assert_eq "0" "$(cat "$WS/tasks/T9/.langseen-svc" 2>/dev/null)" "sin stack: el marcador declara que NO verificó nada"
assert_eq "0" "$(ls "$WS/tasks/T9/evidence/"EV-*.json 2>/dev/null | wc -l | tr -d ' ')" \
  "sin stack: NO queda evidencia acuñada"
assert_contains "$out" "NO sello evidencia" "y lo dice explícitamente"
assert_contains "$out" "sin que ninguna suite haya corrido" "explicando por qué sería una mentira"

echo
echo "── un gate rojo NO puede salir verde (el falso verde que encontró el demo)"
# Encontrado pasando una feature REAL por el harness, no en los unitarios: el
# precheck imprimia "✅ precheck verde", sellaba evidencia con exit_code 0 y
# estampaba ok:true, CON LA SUITE DE TESTS ROTA.
#
# La causa: al extraer los gates a `ship.sh --lang-gates` para poder sellarlos
# como evidencia, la invocacion quedo como `run_lang_gates || lrc=$?`. Esa
# construccion DESACTIVA set -e dentro de la funcion, asi que el gate que falla
# no aborta, los siguientes corren igual, y la funcion devuelve el exit del
# ULTIMO comando, que era 0. Es la forma mas cara del defecto: nadie investiga
# un verde.
mkdir -p "$WS/worktrees/T10/svc" "$WS/tasks/T10"
cp -R "$WS/repos/svc/." "$WS/worktrees/T10/svc/"
( cd "$WS/worktrees/T10/svc"; : > Cargo.toml; git add -A; git commit -qm "stack cuyo build falla

Task: T10" )
# cargo de palo que FALLA: hermetico, sin depender de toolchains reales
printf '#!/bin/sh\necho "error[E0433]: build roto"\nexit 1\n' > "$WS/bin/cargo"
chmod +x "$WS/bin/cargo"

out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T10 svc 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && pass "gate de lenguaje rojo: el precheck sale != 0" \
  || fail "GATE ROJO SALIO VERDE: set -e quedo desactivado sobre run_lang_gates"
assert_not_contains "$out" "precheck verde" "no anuncia verde con un gate rojo"
assert_contains "$out" "precheck rojo" "lo declara rojo"
sello="$(cat "$WS/tasks/T10/precheck-svc.json" 2>/dev/null)"
assert_contains "$sello" '"ok":false' "el sello dice ok:false (lo lee /review para no lanzar a nadie)"

# Y lo que hace al falso verde catastrofico: la evidencia. Si se sella con
# exit_code 0, satisface --require-fresh-kind y el ship pasa sobre tests rotos.
ev="$(ls "$WS/tasks/T10/evidence/"EV-*.json 2>/dev/null | head -1)"
if [ -n "$ev" ]; then
  code="$(jq -r '.exit_code' "$ev")"
  [ "$code" != "0" ] && pass "la evidencia del gate rojo lleva exit_code != 0 (inerte para los gates)" \
    || fail "la evidencia dice exit_code 0 con el build roto: certificaria una suite que fallo"
else
  pass "el gate rojo no dejo evidencia utilizable"
fi

# El camino feliz del mismo stack sigue verde: el arreglo no rompio el verde.
printf '#!/bin/sh\nexit 0\n' > "$WS/bin/cargo"; chmod +x "$WS/bin/cargo"
( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T10 svc >/dev/null 2>&1 ) \
  && pass "el mismo stack en verde sigue pasando (no se rompio el camino feliz)" \
  || fail "el camino feliz quedo roto"
rm -f "$WS/bin/cargo"

t_done
