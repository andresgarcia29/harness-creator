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

echo
echo "── ISSUES #149/#150: el precheck del ÁRBOL DE UN NODO del DAG"
# Con dag.json schema 2, dos tareas del mismo repo con files[] disjuntos corren
# en paralelo, cada una en worktrees/<task>/<repo>@<Tn>. El precheck componía la
# ruta con el repo PELADO y validaba <repo>@<Tn> contra manifest.yaml, así que:
# el nodo no podía nombrar su árbol, el precheck corría sobre el árbol del
# vecino (medido: 253 archivos de test, 283s, sobre el commit de otro nodo) y
# los hermanos se pisaban el mismo precheck-<repo>.json.
cp -R "$WS/repos/svc" "$WS/worktrees/T1/svc@T2"
( cd "$WS/worktrees/T1/svc@T2"; echo "solo de T2" > t2.txt; git add .
  git commit -qm "feat de T2

Task: T1" )
head_t2="$( cd "$WS/worktrees/T1/svc@T2" && git rev-parse HEAD )"
stub_gitleaks 'exit 0'
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T1 'svc@T2' 2>&1 )"; rc=$?
assert_eq 0 "$rc" "#149: el precheck del nodo corre (antes: 'no está en repos/', exit 2)"
assert_file "$WS/tasks/T1/precheck-svc@T2.json" "#149: sella con SU nombre, no con el del repo pelado"
sello_t2="$(cat "$WS/tasks/T1/precheck-svc@T2.json")"
assert_contains "$sello_t2" "$head_t2" "#149: y ata el commit DEL NODO, no el del árbol de la tarea"
assert_not_contains "$sello_t2" "$head" "#150: no es el commit del vecino (ese era el silencio caro)"
assert_contains "$out" "verde de un NODO" "#149: y dice que este verde no habilita review"
assert_contains "$out" "dag-coalesce.sh T1 svc" "con el paso que falta delante"
# El sello del árbol de la tarea sigue siendo el suyo: el del nodo no lo pisó.
assert_contains "$(cat "$WS/tasks/T1/precheck-svc.json")" "$head" \
  "#149: el sello del árbol de la tarea quedó intacto"

echo
echo "── un nodo verifica, pero NO publica"
# Su rama (task/<id>@<Tn>) no es la que aterriza: publicar desde ahí saltearía
# el coalesce y mandaría a main una tarea a medias.
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh T1 'svc@T2' 2>&1 )"; rc=$?
assert_eq 2 "$rc" "#149: el ship desde un nodo se rechaza"
assert_contains "$out" "desde ahí no se publica" "y dice por qué"
assert_contains "$out" "dag-coalesce.sh T1 svc" "con el comando que falta"

echo
echo "── un sufijo inválido no se convierte en una ruta"
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T1 'svc@../otro' 2>&1 )"; rc=$?
assert_eq 2 "$rc" "un nodo con '..' no pasa"
assert_contains "$out" "nodo inválido" "y lo dice por su nombre"

echo "── precheck rojo"
stub_gitleaks 'echo "leak: token en app.txt"; exit 1'
out="$(run_precheck)"; rc=$?
[ "$rc" -ne 0 ] && pass "gate rojo: exit != 0" || fail "gate rojo: salió 0"
assert_contains "$out" "NO entregues a review" "el mensaje es el prompt del fix"
assert_contains "$out" "NO consume presupuesto de loop" "deja claro que no cuenta como ronda"
sello="$(cat "$WS/tasks/T1/precheck-svc.json")"
assert_contains "$sello" '"ok":false' "sello rojo (el /review no debe lanzar a nadie)"
assert_not_contains "$out" "FALTA DE DISCO" "con disco de sobra no inventa una causa ambiental"

# ── el rojo que NO es del código: disco lleno ────────────────────────
# Caso de campo (COR-567): el disco raíz lleno puso en rojo gates de varios
# workspaces a la vez, ningún mensaje lo dijo, y el agente quemó su presupuesto
# de autofix persiguiendo un bug que no existía. El aviso CONTEXTUALIZA: no
# cambia el exit ni el sello, solo dice que el rojo puede no ser del código.
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/x 100 100 1024 100%% /"\n' > "$WS/bin/df"
chmod +x "$WS/bin/df"
out="$(run_precheck)"; rc=$?
[ "$rc" -ne 0 ] && pass "con el disco al límite el gate sigue rojo (el aviso no lo tapa)" \
  || fail "el aviso de disco cambió el veredicto del gate"
assert_contains "$out" "FALTA DE DISCO" "y avisa que el rojo puede ser ambiental"
assert_contains "$out" "1 MB libres" "diciendo cuánto queda, no una vaguedad"
assert_contains "$out" "Libera espacio ANTES de tocar nada" "con la remediación en el orden correcto"
sello="$(cat "$WS/tasks/T1/precheck-svc.json")"
assert_contains "$sello" '"ok":false' "y el sello sigue siendo rojo, no un ausente"
# df ilegible: el aviso se calla en vez de tumbar el trap con set -u
printf '#!/bin/sh\necho "no puedo leer nada"\n' > "$WS/bin/df"; chmod +x "$WS/bin/df"
out="$(run_precheck)"; rc=$?
[ "$rc" -ne 0 ] && pass "df ilegible: el precheck sigue funcionando igual" \
  || fail "df ilegible rompió el camino rojo del precheck"
assert_not_contains "$out" "FALTA DE DISCO" "y no inventa un diagnóstico que no puede sostener"
rm -f "$WS/bin/df"

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
  # El test AFIRMA algo que solo es cierto CON este commit (el pyproject que el
  # mismo commit agrega). No es un rodeo: gate_test_muerde corre todo test nuevo
  # contra el árbol base, y un `assert 1 == 1` pasaría también ahí, o sea que
  # este fixture sería el test vacuo que ese gate existe para cazar y el
  # precheck moriría antes de llegar a lo que este caso mide.
  mkdir -p tests
  printf 'import os\n\n\ndef test_ok():\n    assert os.path.exists("pyproject.toml")\n' > tests/test_a.py
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
# ── Y EL SELLO TIENE QUE DECIRLO, no solo el stdout ──────────────────────
# Hasta acá el aviso vivía únicamente en la salida del comando, que ningún
# consumidor parsea: /review leía {commit, ok} y un precheck donde NINGÚN gate
# de lenguaje corrió era, desde el sello, idéntico a un verde con la suite
# pasada. El UNKNOWN se volvía PASS en el único artefacto que sobrevive.
# `ok` NO se endurece a propósito: un repo de docs sin stack no es un rojo, y
# convertirlo en uno fabricaría falsos rojos (la mitad simétrica del defecto).
sello="$(cat "$WS/tasks/T9/precheck-svc.json")"
assert_contains "$sello" '"ok":true' "sin stack: ok:true (no bloquea: un repo sin stack puede ser legítimo)"
assert_contains "$sello" '"verificado":"ninguno"' \
  "pero el sello DECLARA que ningún gate de lenguaje llegó a correr"
# El campo extra no puede romper a quien ya lee el sello: /review lo consume
# con jq, así que el sello tiene que seguir siendo JSON válido y `.ok` tiene
# que seguir contestando lo mismo que antes.
if jq -e '.ok == true and .verificado == "ninguno"' "$WS/tasks/T9/precheck-svc.json" >/dev/null; then
  pass "el sello sigue siendo JSON válido y .ok no cambió de semántica"
else
  fail "el sello no parsea con jq o .ok cambió de semántica"
fi
# Caso de campo: el precheck imprimía EVIDENCE_ID= y dos líneas después
# borraba el sello; cuatro agentes distintos parsearon ese ID fantasma y
# fallaron recién en el ship. El anuncio ahora va después de la decisión.
assert_not_contains "$out" "EVIDENCE_ID=" "y NO anuncia un EVIDENCE_ID que acaba de borrar"

echo
echo "── el sello afirma 'gates sobre ESTE commit': con árbol sucio NO se sella"
# Issue #39: el fix de 0.52.0 degradó la EVIDENCIA con árbol sucio pero el
# sello del precheck seguía grabando HEAD con ok:true, o sea que /review leía
# "los gates pasaron sobre este commit" de un commit que no contiene lo que
# se validó. Los gates corren igual (feedback); la afirmación falsa no.
mkdir -p "$WS/worktrees/T11/svc" "$WS/tasks/T11"
cp -R "$WS/repos/svc/." "$WS/worktrees/T11/svc/"
( cd "$WS/worktrees/T11/svc"; echo base > f.txt; git add -A; git commit -qm "base

Task: T11" )
echo "cambio sin commitear" >> "$WS/worktrees/T11/svc/f.txt"
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T11 svc 2>&1 )"; rc=$?
assert_eq 0 "$rc" "árbol sucio con gates verdes: exit 0 (los gates sí corrieron)"
assert_no_file "$WS/tasks/T11/precheck-svc.json" "pero NO deja sello: sellaría un commit que no contiene lo validado"
assert_contains "$out" "SIN sello" "y lo dice"
assert_contains "$out" "commitea" "con la remediación exacta"

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
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T10 svc 2>&1 )"; rc=$?
assert_eq 0 "$rc" "el mismo stack en verde sigue pasando (no se rompio el camino feliz)"
# La otra mitad del campo: un stack que SÍ compiló y testeó se sella
# "completo". Sin este caso, un sello que dijera "ninguno" siempre pasaría el
# test de arriba y el campo no distinguiría nada.
sello="$(cat "$WS/tasks/T10/precheck-svc.json")"
assert_contains "$sello" '"ok":true' "stack reconocido y verde: ok:true"
assert_contains "$sello" '"verificado":"completo"' \
  "y el sello declara que un gate de lenguaje SÍ compiló y testeó"
assert_not_contains "$out" "verificado: ninguno" "y la última línea no lo desmiente"
rm -f "$WS/bin/cargo"

echo
echo "── 'no pude saberlo' es un TERCER estado, no un verde ni un rojo"
# Sin evidence.py los gates corren igual pero NADIE deja el marcador que dice
# si algún tramo llegó a compilar o testear. Sellar "ninguno" ahí sería inventar
# un rojo (quizá corrió todo) y sellar "completo" sería inventar un verde. El
# sello dice "desconocido" y el reviewer decide: es la misma regla que ya
# gobierna el pid ilegible del lock y la baseline de ruff que no se pudo sacar.
mkdir -p "$WS/worktrees/T12/svc" "$WS/tasks/T12"
cp -R "$WS/repos/svc/." "$WS/worktrees/T12/svc/"
( cd "$WS/worktrees/T12/svc"; echo x > g.txt; git add -A; git commit -qm "sin evidence.py

Task: T12" )
mv "$WS/scripts/evidence.py" "$WS/evidence.py.guardado"
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T12 svc 2>&1 )"; rc=$?
mv "$WS/evidence.py.guardado" "$WS/scripts/evidence.py"
assert_eq 0 "$rc" "sin evidence.py el precheck sigue corriendo (el sello es lo que cambia)"
sello="$(cat "$WS/tasks/T12/precheck-svc.json")"
assert_contains "$sello" '"verificado":"desconocido"' "el sello declara que no se pudo saber"
assert_contains "$out" "verificado: desconocido" "y la última línea que alguien lee también"

echo
echo "── marcador ausente al sellar: se BORRA el EV, no se conserva"
# El marcador vive en tasks/<task>/ y lo comparten precheck y ship del mismo
# task+repo, sin lock entre ellos: un precheck concurrente hace `rm -f` y puede
# llevárselo entre que el hijo --lang-gates lo escribe y el padre lo lee para
# decidir si sella. La lectura era `cat ... || echo 1`, o sea que la ausencia
# CONSERVABA el sello: un EV-TEST que satisface --require-fresh-kind test
# salido de una corrida de la que no sabemos si ejecutó una sola suite. Un
# fail-open sobre evidencia es el mismo verde silencioso de siempre.
#
# La carrera se reproduce en el punto exacto donde ocurre: un evidence.py de
# palo que corre los gates de verdad, acuña el EV y BORRA el marcador antes de
# devolver el ID, que es justo lo que hace el `rm -f` del vecino. El resto del
# camino (la decisión de sellar, el mensaje y el sello) es el código real.
mkdir -p "$WS/worktrees/T13/svc" "$WS/tasks/T13"
cp -R "$WS/repos/svc/." "$WS/worktrees/T13/svc/"
( cd "$WS/worktrees/T13/svc"; : > Cargo.toml; git add -A; git commit -qm "stack que sí corre

Task: T13" )
printf '#!/bin/sh\nexit 0\n' > "$WS/bin/cargo"; chmod +x "$WS/bin/cargo"
mv "$WS/scripts/evidence.py" "$WS/evidence.py.guardado"
cat > "$WS/scripts/evidence.py" <<'PY'
import os, subprocess, sys
a = sys.argv[1:]
td = a[a.index('--task-dir') + 1]
repo = a[a.index('--repo') + 1]
cwd = a[a.index('--cwd') + 1]
rc = subprocess.call(a[a.index('--') + 1:], cwd=cwd)
d = os.path.join(td, 'evidence')
os.makedirs(d, exist_ok=True)
open(os.path.join(d, 'EV-CARRERA.json'), 'w').write('{"schema":1,"kind":"test","exit_code":%d}' % rc)
open(os.path.join(d, 'EV-CARRERA.log'), 'w').write('salida\n')
m = os.path.join(td, '.langseen-' + repo)
if os.path.exists(m):
    os.remove(m)          # el precheck del vecino, en la peor ventana posible
print('EVIDENCE_ID=EV-CARRERA')
sys.exit(rc)
PY
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T13 svc 2>&1 )"; rc=$?
mv "$WS/evidence.py.guardado" "$WS/scripts/evidence.py"
rm -f "$WS/bin/cargo"
assert_eq 0 "$rc" "el precheck no se rompe por perder el marcador (los gates sí corrieron)"
assert_no_file "$WS/tasks/T13/evidence/EV-CARRERA.json" \
  "sin marcador NO queda EV-TEST: no sé si probó algo, así que no lo certifico"
assert_no_file "$WS/tasks/T13/evidence/EV-CARRERA.log" "y su log se va con él"
assert_contains "$out" "no hay rastro de si algo corrió" "y dice el motivo exacto, no 'ninguna suite'"
assert_not_contains "$out" "EVIDENCE_ID=" "sin anunciar un ID que acaba de borrar"
sello="$(cat "$WS/tasks/T13/precheck-svc.json")"
assert_contains "$sello" '"verificado":"desconocido"' "y el sello declara el tercer estado, no un verde"

echo
echo "── un ship en vuelo es dueño del marcador: el precheck NO se lo pisa"
# El `rm -f` del arranque existe para no heredar el 'completo' de una corrida
# anterior, pero con un ship vivo del mismo task+repo ese archivo es SUYO: su
# hijo lo escribe y su padre lo lee dos veces. Borrarlo le arranca la evidencia
# y encima en la dirección cara (el ship tira su EV recién acuñado y repite la
# suite). El lock del repo es el único indicio de que hay un ship vivo.
# El commit va SIN trailer a propósito: así el precheck muere en gate_trailer,
# después del bloque del marcador y antes de los gates de lenguaje, que es lo
# único que reescribiría el archivo y taparía la diferencia.
mkdir -p "$WS/worktrees/T14/svc" "$WS/tasks/T14"
cp -R "$WS/repos/svc/." "$WS/worktrees/T14/svc/"
( cd "$WS/worktrees/T14/svc"; echo h > h.txt; git add -A; git commit -qm "sin trailer, muere temprano" )
mkdir -p "$WS/locks/svc.lock.d"
echo 999999 > "$WS/locks/svc.lock.d/pid"
printf '1' > "$WS/tasks/T14/.langseen-svc"
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T14 svc 2>&1 )"
assert_eq "1" "$(cat "$WS/tasks/T14/.langseen-svc" 2>/dev/null)" \
  "con el lock de ship tomado: el marcador del vecino sobrevive intacto"
assert_contains "$out" "NO borro el marcador" "y el precheck avisa que no lo tocó"
assert_contains "$out" "puede venir de esa corrida" "diciendo qué significa eso para su sello"

# Y sin ship en vuelo el borrado sigue ocurriendo: sin esta mitad, el test de
# arriba pasaría igual con un `rm -f` que nunca borra nada.
rm -rf "$WS/locks/svc.lock.d"
printf '1' > "$WS/tasks/T14/.langseen-svc"
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T14 svc 2>&1 )"
assert_no_file "$WS/tasks/T14/.langseen-svc" \
  "sin lock: el marcador viejo SÍ se borra (nadie hereda un 'completo' ajeno)"
assert_not_contains "$out" "NO borro el marcador" "y no avisa de un ship que no existe"

echo
echo "── el campo 'verificado' clasifica contenido raro sin inventar un verde"
# El case estaba ordenado `0) ninguno; no-dígitos) desconocido; *) completo`, y
# ese `*` final se comía todo lo que no fuera exactamente "0": '00', '10' y '2'
# sellaban 'completo' sin que nadie hubiera escrito ese 1. Se prueba la función
# REAL, extraída del script instanciado, con las entradas adversas.
awk '/^precheck_verificado\(\) \{/,/^\}/' "$WS/scripts/ship.sh" > "$WS/pv.sh"
[ -s "$WS/pv.sh" ] && pass "extraje precheck_verificado del script (si sale vacía, el chequeo sería vacuo)" \
  || fail "no pude extraer precheck_verificado: el chequeo no probaría nada"
printf 'set -u\n. "$PV_FN"\nprecheck_verificado\n' > "$WS/pv-run.sh"
clasifica() {  # clasifica <contenido-del-marcador>|--sin-marcador → veredicto
  # Las rutas se resuelven ANTES de la línea que reasigna WS: en un prefijo de
  # asignaciones no está garantizado que una vea a la anterior, y este test no
  # se juega en una sutileza de expansión.
  local probe="$WS/probe" fn="$WS/pv.sh" runner="$WS/pv-run.sh"
  rm -rf "$probe"
  mkdir -p "$probe/tasks/TP"
  if [ "$1" != "--sin-marcador" ]; then printf '%s' "$1" > "$probe/tasks/TP/.langseen-${2:-svc}"; fi
  WS="$probe" TASK=TP REPO=svc ARTEFACTO="${2:-svc}" PV_FN="$fn" bash "$runner"
}
assert_eq "ninguno"     "$(clasifica '00')"  "'00' es solo ceros: ninguno (antes: completo)"
assert_eq "completo"    "$(clasifica '10')"  "'10' trae un dígito 1-9: completo"
assert_eq "ninguno"     "$(clasifica '0 0')" "'0 0' se normaliza y sigue siendo ninguno (antes: completo)"
assert_eq "completo"    "$(clasifica '2')"   "'2' es un conteo, no un cero: completo"
assert_eq "desconocido" "$(clasifica 'x')"   "'x' no es un número: desconocido, no un verde"
assert_eq "desconocido" "$(clasifica '')"    "vacío: desconocido"
assert_eq "desconocido" "$(clasifica '--sin-marcador')" "sin marcador: desconocido"
assert_eq "ninguno"     "$(clasifica '0')"   "el caso de siempre no se movió: '0' es ninguno"
assert_eq "completo"    "$(clasifica '1')"   "ni el otro: '1' es completo"

# ISSUES #149/#150: con nodos paralelos del DAG, el marcador y el sello son del
# ARBOL, no del repo. Con la clave pelada los tres hermanos escribian el mismo
# archivo y ganaba el ultimo: un verde que afirma "verificado: completo" sobre
# un commit que ese nodo nunca produjo.
assert_eq "completo"    "$(clasifica '1' 'svc@T2')" "#149: el marcador del nodo se lee por su propia clave"
assert_eq "desconocido" "$(clasifica '--sin-marcador' 'svc@T3')" \
  "#149: y el hermano sin marcador NO hereda el verde del vecino"

echo
echo "── el sello declara el bug conocido del harness, y solo cuando lo hubo"
# HARNESS_KNOWN_BUG no borra el rojo del gate: lo DECLARA. Si ese hecho no
# queda en el sello, /review lee un ok:true indistinguible de uno limpio y la
# declaracion se evapora justo donde alguien la auditaria. El campo es
# ADITIVO (schema sigue en 1) porque los consumidores leen con jq y toleran
# claves nuevas; agregar un codigo de salida, en cambio, habria roto la tabla
# de exits que este mismo archivo verifica mas abajo.
{ awk '/^known_bug_frag\(\) \{/,/^\}/' "$WS/scripts/ship.sh"
  awk '/^precheck_verificado\(\) \{/,/^\}/' "$WS/scripts/ship.sh"
  awk '/^stamp_precheck\(\) \{/,/^\}/' "$WS/scripts/ship.sh"; } > "$WS/kb.sh"
grep -q '^known_bug_frag() {' "$WS/kb.sh" && grep -q '^stamp_precheck() {' "$WS/kb.sh" \
  && pass "extraje known_bug_frag + stamp_precheck del script instanciado" \
  || fail "no pude extraer el sellador: el chequeo no probaria nada"
printf 'set -u\n. "$KB_FN"\nstamp_precheck true\n' > "$WS/kb-run.sh"
sella_kb() {  # sella_kb <valor-de-KNOWN_BUG_USED> → ruta del sello escrito
  # Las rutas se resuelven ANTES del prefijo de asignaciones (mismo motivo que
  # `clasifica` de arriba: que una asignacion vea a la anterior no esta
  # garantizado, y este test no se juega en una sutileza de expansion).
  local probe="$WS/kbprobe" fn="$WS/kb.sh" runner="$WS/kb-run.sh"
  rm -rf "$probe"; mkdir -p "$probe/tasks/TK"
  WS="$probe" TASK=TK REPO=svc ARTEFACTO="${2:-svc}" WT="$probe/sin-worktree" \
    KNOWN_BUG_USED="$1" KB_FN="$fn" bash "$runner"
  printf '%s' "$probe/tasks/TK/precheck-${2:-svc}.json"
}
sello_kb="$(sella_kb "tests=https://github.com/anthropics/harness-creator/issues/77")"
jq -e '.known_bug.url == "https://github.com/anthropics/harness-creator/issues/77"' "$sello_kb" >/dev/null \
  && pass "con el knob usado, el sello trae .known_bug.url" \
  || fail "el sello no declara el issue del bug conocido: $(cat "$sello_kb" 2>/dev/null)"
jq -e '.known_bug.slot == "tests"' "$sello_kb" >/dev/null \
  && pass "y .known_bug.slot dice CUAL gate se declaro (no un salto global)" \
  || fail "el sello no dice que slot se declaro"
jq -e '.schema == 1 and .ok == true and .verificado != null' "$sello_kb" >/dev/null \
  && pass "sin romper el sello de siempre: schema 1, ok y verificado intactos" \
  || fail "el campo nuevo rompio el sello que /review ya leia"
# CONTRA-MITAD: sin knob la clave NO existe. Un `known_bug` siempre presente
# (aunque fuera null) convertiria la declaracion en ruido de fondo.
sello_kb="$(sella_kb "")"
jq -e 'has("known_bug") | not' "$sello_kb" >/dev/null \
  && pass "sin knob, el sello NO trae la clave known_bug" \
  || fail "el sello declara un bug conocido que nadie declaro: $(cat "$sello_kb" 2>/dev/null)"

# #149/#150: el sello de un nodo lleva su sufijo, asi que no pisa al del vecino
# ni al del arbol coalescido (que es el que /review y el ship consumen).
sello_nodo="$(sella_kb "" "svc@T2")"
assert_file "$sello_nodo" "#149: el sello del nodo se llama precheck-<repo>@<Tn>.json"
assert_no_file "$(dirname "$sello_nodo")/precheck-svc.json" \
  "#149: y NO escribe el del arbol de la tarea, que es otro commit"

echo
echo "── un test nuevo que pasa SIN el cambio: el precheck lo caza, de punta a punta"
# Caso de campo que costó una ronda entera: un implementer escribió un assert que
# NO PODÍA FALLAR (evaluaba antes de que llegara el dato). La suite pasó, el
# precheck pasó, y la ronda 3 completa (commit, precheck, dos sellos de
# evidencia, dos agentes) se pagó por un test que no probaba nada. Los bloques de
# arriba miden el gate aislado; esto mide que esté CABLEADO al precheck, que es
# el único camino por el que un implementer lo va a encontrar.
mkdir -p "$WS/worktrees/T15/svc" "$WS/tasks/T15"
cp -R "$WS/repos/svc/." "$WS/worktrees/T15/svc/"
( cd "$WS/worktrees/T15/svc"; mkdir -p tests
  printf 'def test_vacuo():\n    assert True\n' > tests/test_vacuo.py
  git add -A; git commit -qm "un test que no puede fallar

Task: T15" )
# pytest de palo: este caso no mide a pytest, mide que el gate corra el test
# nuevo contra el árbol base y lea su exit. Un `assert True` pasa en los dos.
printf '#!/bin/sh\necho "1 passed"\nexit 0\n' > "$WS/bin/pytest"; chmod +x "$WS/bin/pytest"
stub_gitleaks 'exit 0'
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/ship.sh --precheck T15 svc 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && pass "test nuevo que pasa también sobre la base: el precheck sale != 0" \
  || fail "un test que no puede fallar pasó el precheck (la ronda se paga igual)"
assert_contains "$out" "PASAN también SIN tu cambio" "y nombra exactamente el defecto"
assert_contains "$out" "tests/test_vacuo.py" "con el archivo"
assert_contains "$out" "pasa sin tu fix" "y la remediación"
assert_contains "$out" "NO entregues a review" "encuadrado como precheck rojo, o sea ronda AHORRADA"
sello="$(cat "$WS/tasks/T15/precheck-svc.json")"
assert_contains "$sello" '"ok":false' "el sello dice ok:false (lo lee /review para no lanzar a nadie)"
assert_eq "1" "$( cd "$WS/worktrees/T15/svc" && git worktree list | grep -c . )" \
  "y el worktree temporal del árbol base se limpió, incluso con el gate rojo"
rm -f "$WS/bin/pytest"

echo
echo "── el precheck avisa si la evidencia del repo NO apunta al HEAD que sella"
# Caso de campo, dos veces en la misma sesion: el precheck sello ok:true sobre
# el hijo mientras las UNICAS evidencias del repo apuntaban al padre. El
# desalineamiento lo cazaba recien verdict-scaffold.sh, o sea despues de lanzar
# la ronda de review: la ronda ya estaba pagada.
#
# Es un OBSERVADOR, no un gate: avisa y sigue verde. Convertirlo en rojo seria
# la mitad simetrica del defecto que este mismo archivo ya rechazo (un repo sin
# stack no puede sellar en HEAD y es legitimo), y ademas tras un rebase puro la
# evidencia vieja SIGUE siendo valida por patch_id.
stub_gitleaks 'exit 0'
mkdir -p "$WS/tasks/T1/evidence"
VIEJO="$( cd "$WS/worktrees/T1/svc" && git rev-parse HEAD )"
mk_ev_precheck() {  # mk_ev_precheck <id> <commit> <patch_id>
  printf 'salida\n' > "$WS/tasks/T1/evidence/$1.log"
  local h; h="$(shasum -a 256 "$WS/tasks/T1/evidence/$1.log" | cut -d' ' -f1)"
  jq -n --arg id "$1" --arg c "$2" --arg p "$3" --arg h "$h" \
    '{schema:1, id:$id, task_id:"T1", repo:"svc", kind:"test", runner:"impl-svc",
      commit:$c, commit_after:$c, exit_code:0, patch_id:$p,
      output:("evidence/"+$id+".log"), output_sha256:$h}' \
    > "$WS/tasks/T1/evidence/$1.json"
}
mk_ev_precheck EV-TEST-viejo0000001 "$VIEJO" "PID-VIEJO"
# HEAD se mueve: la evidencia de arriba queda apuntando al padre
( cd "$WS/worktrees/T1/svc"; echo mas > otro.txt; git add .
  git commit -qm "feat 2

Task: T1" )
out="$(run_precheck)"; rc=$?
assert_eq 0 "$rc" "es un aviso, no un rojo: el precheck sigue en verde"
assert_contains "$(cat "$WS/tasks/T1/precheck-svc.json")" '"ok":true' "y el sello sigue verde"
assert_contains "$out" "NO apuntan al HEAD" "pero DICE que la evidencia quedo atras"
assert_contains "$out" "evidence.py run" "con la misma remediacion que da el scaffold"

# CONTRA-MITAD 1: con una evidencia en el HEAD sellado, el aviso NO aparece.
# Sin esto, un aviso que se imprime siempre pasaria el bloque de arriba.
NUEVO="$( cd "$WS/worktrees/T1/svc" && git rev-parse HEAD )"
mk_ev_precheck EV-TEST-nuevo0000001 "$NUEVO" "PID-NUEVO"
out="$(run_precheck)"
assert_not_contains "$out" "NO apuntan al HEAD" "con evidencia en el HEAD: sin aviso"

# CONTRA-MITAD 2: el rebase puro no es desalineamiento. Si el patch_id de la
# evidencia es el del cambio actual, es la MISMA evidencia sobre otra base y
# avisar seria una falsa alarma. Espeja la equivalencia de verdict-scaffold.sh.
rm -f "$WS/tasks/T1/evidence/EV-TEST-nuevo0000001.json"
PID_ACTUAL="$(bash "$WS/scripts/change-id.sh" "$WS/worktrees/T1/svc" main 2>/dev/null || echo '')"
[ -n "$PID_ACTUAL" ] && pass "change-id.sh resuelve el patch_id del worktree (si no, el caso seria vacuo)" \
  || fail "no pude calcular el patch_id: la contra-mitad del rebase no probaria nada"
mk_ev_precheck EV-TEST-rebase000001 "0000000000000000000000000000000000000000" "$PID_ACTUAL"
out="$(run_precheck)"
assert_not_contains "$out" "NO apuntan al HEAD" "rebase puro (mismo patch_id): sin falsa alarma"
rm -f "$WS/tasks/T1"/evidence/EV-*.json "$WS/tasks/T1"/evidence/EV-*.log

echo
echo "── el reviewer no fabrica el veredicto que no existe"
# Lanzado a mano sin verdict-scaffold.sh, el reviewer no tiene camino para
# crear el archivo (su frontmatter no trae Write), así que el modo de fallo es
# un atasco mudo o una redirección por Bash que se salta el esqueleto: el
# veredicto nace sin patch_id, sin evidence[] ni implementation_agents, que son
# los únicos campos verificables. La regla vive en el prompt, y esta aserción
# está acá porque este carril es dueño de reviewer.md.tmpl.
revd="$(cat "$ROOT/templates/agents/reviewer.md.tmpl")"
assert_contains "$revd" "NO lo crees por ningún medio" "el prompt prohíbe fabricar el veredicto ausente"
assert_contains "$revd" "verdict-scaffold.sh" "y nombra el comando que sí lo crea"

echo
echo "── el header declara los códigos de salida REALES, ni uno más ni uno menos"
# Quien automatiza alrededor de ship.sh (CI, wrappers, /smart) decide por lo que
# dice esa tabla. Un código inventado hace que alguien trate como "lock ocupado"
# lo que fue otra cosa; uno omitido lo deja sin caso. Las dos direcciones se
# comprueban mecánicamente contra el código, que es la única fuente que no
# envejece. Las lecciones de los comentarios citan exits AJENOS (el 128 de
# `git rebase --abort`, el 127 de una toolchain ausente) que este script no
# devuelve: por eso se descartan las líneas de comentario antes de contar.
ship="$WS/scripts/ship.sh"
reales="$(grep -vE '^[[:space:]]*#' "$ship" \
  | grep -oE '(^|[^[:alnum:]_-])exit [0-9]+' | grep -oE '[0-9]+' | sort -u)"
tabla="$(grep -oE '^# exit [0-9]+' "$ship" | grep -oE '[0-9]+' | sort -u)"
[ -n "$reales" ] && pass "la extracción encontró códigos (si sale vacía, el test no probaría nada)" \
  || fail "no extraje ningún 'exit N' del script: el chequeo sería vacuo"
[ -n "$tabla" ] && pass "el header trae la tabla de códigos" \
  || fail "el header NO trae tabla de códigos de salida"
faltan="$(comm -23 <(printf '%s\n' "$reales") <(printf '%s\n' "$tabla") | tr '\n' ' ' | sed 's/ *$//')"
sobran="$(comm -13 <(printf '%s\n' "$reales") <(printf '%s\n' "$tabla") | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "" "$faltan" "cada 'exit N' del código está documentado en la tabla"
assert_eq "" "$sobran" "y la tabla no inventa códigos que el script nunca devuelve"

t_done
