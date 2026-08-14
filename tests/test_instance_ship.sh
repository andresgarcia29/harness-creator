#!/usr/bin/env bash
# test_instance_ship.sh: la puerta a main del repo de la INSTANCIA (issue #37).
# El repo del workspace no tenía camino legítimo: el hook bloqueaba el push y
# ship.sh solo opera sobre repos/, así que cada /harness-update producía un
# commit que el humano terminaba pusheando a mano POR FUERA del harness. Esto
# no es una excepción al hook: es una puerta con los gates que SÍ aplican
# (árbol limpio, rebase, gitleaks, doctor), y el push vive DENTRO del script
# sancionado, igual que en ship.sh.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

# workspace = clon de un origin bare, con la estructura mínima del harness
git init -q --bare -b main "$WS/origin.git"
seed="$WS/seed"
git init -q -b main "$seed"
git -C "$seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$seed" remote add origin "$WS/origin.git"
git -C "$seed" push -q origin main
IWS="$WS/instancia"
git clone -q "$WS/origin.git" "$IWS"
git -C "$IWS" config user.email t@t
git -C "$IWS" config user.name t
mkdir -p "$IWS/scripts" "$WS/bin"
cp "$ROOT/templates/scripts/instance-ship.sh" "$IWS/scripts/"
# stub de doctor conmutable por un archivo UNTRACKED (.doctor-red): reescribir
# el stub entre casos ensuciaba el árbol y el gate de árbol sucio disparaba
# ANTES que el gate que se quería probar
printf '#!/bin/sh\n[ -f .doctor-red ] && exit 1\nexit 0\n' > "$IWS/scripts/doctor.sh"
chmod +x "$IWS/scripts/doctor.sh"
git -C "$IWS" add -A && git -C "$IWS" commit -qm "instala harness"

run_is() { ( cd "$IWS" && PATH="$WS/bin:$(t_path_without gitleaks)" bash scripts/instance-ship.sh "$@" 2>&1 ); }

echo "── los argumentos se parsean ANTES de cualquier gate (issue #63)"

# El bug del issue: el script ignoraba "$@", así que `--help` (o un typo, o
# un --dry-run que no existe) corría el ship COMPLETO, con push irreversible
# a origin/main incluido. Acá hay un commit pendiente sin publicar: si el
# argumento se tragara como antes, origin se movería y el test lo vería.
antes="$(git -C "$WS/origin.git" rev-parse main)"

out="$(run_is --help)"; rc=$?
assert_eq 0 "$rc" "--help: exit 0"
assert_contains "$out" "Uso:" "e imprime el uso"
assert_eq "$antes" "$(git -C "$WS/origin.git" rev-parse main)" \
  "--help: origin NO se movió (nada de gates ni de push)"
assert_no_file "$IWS/locks/instance.lock.d" "--help: ni siquiera tomó el lock"

out="$(run_is -h)"; rc=$?
assert_eq 0 "$rc" "-h: mismo atajo, exit 0"
assert_contains "$out" "Uso:" "e imprime el uso"

out="$(run_is --dry-run)"; rc=$?
assert_eq 2 "$rc" "argumento desconocido: exit != 0"
assert_contains "$out" "no soportados" "y nombra la causa"
assert_contains "$out" "Uso:" "y apunta al uso"
assert_eq "$antes" "$(git -C "$WS/origin.git" rev-parse main)" \
  "argumento desconocido: origin NO se movió (rechazo antes de los gates)"

out="$(run_is main)"; rc=$?
assert_eq 2 "$rc" "un typo de argumento posicional: exit != 0"
assert_eq "$antes" "$(git -C "$WS/origin.git" rev-parse main)" "y tampoco toca nada"

echo "── el camino feliz: gates y push adentro del script (el hook no aplica)"

out="$(run_is)"; rc=$?
assert_eq 0 "$rc" "commit pendiente + doctor verde: exit 0"
assert_contains "$out" "SIN escanear secretos" "sin gitleaks: lo dice en vez de callarse"
assert_contains "$out" "instancia publicada" "y publica"
assert_eq "$(git -C "$IWS" rev-parse HEAD)" "$(git -C "$WS/origin.git" rev-parse main)" \
  "origin/main quedó EXACTAMENTE en el HEAD de la instancia"
assert_no_file "$IWS/locks/instance.lock.d" "el lock se libera al salir"

out="$(run_is)"; rc=$?
assert_eq 0 "$rc" "sin commits nuevos: exit 0"
assert_contains "$out" "nada que pushear" "y lo dice"

echo "── los gates de la puerta"

# lo INNEGOCIABLE: una edición sin commitear sobre un archivo QUE ESTE PUSH
# PUBLICA. Commiteo una versión (sin pushear) y edito el MISMO archivo otra vez:
# publicar ese commit con el archivo a medias es justo lo que el gate impide.
echo v1 > "$IWS/scripts/nuevo.sh"
git -C "$IWS" add scripts/nuevo.sh
git -C "$IWS" commit -qm "script nuevo"
echo v2 >> "$IWS/scripts/nuevo.sh"
out="$(run_is)"; rc=$?
assert_eq 3 "$rc" "edición sin commitear sobre un archivo DEL push: exit 3"
assert_contains "$out" "SIN COMMITEAR" "nombra la causa"
assert_contains "$out" "scripts/nuevo.sh" "y nombra el archivo que se solapa"
git -C "$IWS" commit -qam "script nuevo v2"

# árbol sucio POR OTRA TAREA (COR-319): el árbol de la instancia es COMPARTIDO
# (Ley 7 manda los ADR a docs/adr, /archive fusiona delta-specs en specs/), así
# que otra tarea en vuelo lo ensucia. Si no se solapa con el push: avisa, NO
# bloquea, y la edición ajena SOBREVIVE (el autostash la aparta y la devuelve).
mkdir -p "$IWS/docs/adr"; echo "adr v1" > "$IWS/docs/adr/ADR-0001.md"
git -C "$IWS" add docs/adr/ADR-0001.md
git -C "$IWS" commit -qm "adr"
run_is >/dev/null   # publico lo pendiente: el ADR queda FUERA del rango a pushear
echo y > "$IWS/scripts/otro.sh"
git -C "$IWS" add scripts/otro.sh
git -C "$IWS" commit -qm "commit propio, otro archivo"
echo "otra tarea, en vuelo" >> "$IWS/docs/adr/ADR-0001.md"
out="$(run_is)"; rc=$?
assert_eq 0 "$rc" "suciedad AJENA al push: no bloquea (exit 0)"
assert_contains "$out" "NO se publican" "avisa que el rebase la aparta y la devuelve"
assert_contains "$out" "ADR-0001" "y nombra el archivo ajeno"
assert_contains "$out" "instancia publicada" "y publica igual: hay camino legítimo"
assert_contains "$(git -C "$IWS" status --porcelain)" "ADR-0001.md" \
  "el trabajo ajeno SOBREVIVE al push (nadie lo barrió)"

# vuelvo a dejar un commit pendiente para los gates que siguen (con el árbol
# sucio de la otra tarea todavía en vuelo: ninguno de ellos debe cambiar)
echo z > "$IWS/scripts/pendiente.sh"
git -C "$IWS" add scripts/pendiente.sh
git -C "$IWS" commit -qm "commit pendiente"

# doctor con FALLOS: una instancia rota no se publica a sí misma
touch "$IWS/.doctor-red"
out="$(run_is)"; rc=$?
assert_eq 3 "$rc" "doctor rojo: exit 3"
assert_contains "$out" "no se publica a sí misma" "con el porqué"
# Y que el rojo diga de QUE clase es: un CLI que le falta a este host no es una
# instancia rota, y confundirlos dejaba sin publicar un commit de documentos por
# 16 CLIs que ese commit no ejecuta (#185).
assert_contains "$out" "FALLOS DE LA INSTANCIA" "nombrando la clase que sí bloquea"
assert_contains "$out" "--instance-only" "y la remediación pide el modo que le compete"
assert_contains "$out" "scripts/doctor.sh" "y manda al detalle con remediaciones"

# ── EL ROJO QUE NO ES TUYO en la puerta de la instancia (issue #59) ────
# Caso de campo: doctor.sh contaba una lista ajena de AGENTS.md como leyes
# duplicadas. Con el doctor en rojo por un bug DEL HARNESS, esta puerta (la
# única legítima a main del repo de la instancia: specs maestras, ADRs,
# constitución) quedaba cerrada para TODA tarea, y la única salida era editar
# AGENTS.md o doctor.sh en medio de una tarea, que es justo lo que la Ley 12
# prohíbe. Bloqueaba un archive más 7 commits ya commiteados de otras tareas.
# Los candados son los MISMOS que en ship.sh: se testean acá porque una copia
# que diverge silenciosamente es el modo de falla conocido de tener dos.
LEDGER="$IWS/.harness/upstream-issues.jsonl"   # untracked: -uno no lo ve sucio
KB_URL="https://github.com/andresgarcia29/harness-creator/issues/59"
run_kb() {  # run_kb <valor-de-HARNESS_KNOWN_BUG>
  ( cd "$IWS" && PATH="$WS/bin:$(t_path_without gitleaks)" \
      HARNESS_KNOWN_BUG="$1" bash scripts/instance-ship.sh 2>&1 )
}
# gh stub: sin él el estado del issue depende de la red y de que la máquina
# tenga gh logueado, que es exactamente el flake que un test no puede tener.
gh_stub() { printf '#!/bin/sh\necho %s\n' "$1" > "$WS/bin/gh"; chmod +x "$WS/bin/gh"; }
gh_stub OPEN

# el knob SIN forma '<slot>=<url>': hay que NOMBRAR el slot, un salta-todo sería
# una puerta trasera
out="$(run_kb "$KB_URL")"; rc=$?
assert_eq 3 "$rc" "knob sin slot: sigue bloqueando"
assert_contains "$out" "no tiene forma" "y dice que hay que nombrar el slot"

# el knob nombra OTRO slot: el rojo del doctor no está declarado
out="$(run_kb "gitleaks=$KB_URL")"; rc=$?
assert_eq 3 "$rc" "knob de otro slot: el rojo del doctor sigue bloqueando"

# CANDADO: reportar es la PRECONDICIÓN. Sin fila en el ledger no hay rastro
# auditable, y el knob sería un "confía en mí".
rm -f "$LEDGER"
out="$(run_kb "doctor=$KB_URL")"; rc=$?
assert_eq 3 "$rc" "issue NO reportado (sin fila en el ledger): sigue bloqueando"
assert_contains "$out" "upstream-issues.jsonl" "y nombra el ledger que falta"
assert_contains "$out" "harness-bug.sh report" "con la remediación: reportarlo"

mkdir -p "$IWS/.harness"
printf '{"ts":"2026-07-30","status":"creado","file":"scripts/doctor.sh","url":"%s"}\n' \
  "$KB_URL" > "$LEDGER"

# CANDADO: un issue CERRADO significa que el fix ya existe; seguir declarándolo
# congelaría el harness roto en esta máquina para siempre
gh_stub CLOSED
out="$(run_kb "doctor=$KB_URL")"; rc=$?
assert_eq 3 "$rc" "issue CLOSED upstream: el workaround venció, sigue bloqueando"
assert_contains "$out" "CERRADO" "y lo dice"
assert_contains "$out" "harness-update" "mandando a traer el fix"

# el camino legítimo: issue abierto y reportado. Publica, y NO se calla el rojo.
gh_stub OPEN
out="$(run_kb "doctor=$KB_URL")"; rc=$?
assert_eq 0 "$rc" "doctor rojo + knob válido con el issue en el ledger: publica"
assert_contains "$out" "BUG CONOCIDO del harness" "y lo DECLARA en la salida"
assert_contains "$out" "$KB_URL" "nombrando el issue"
assert_contains "$out" "NO es un verde" "sin venderlo como verde"
assert_contains "$out" "instancia publicada" "y la puerta se abre"
assert_not_contains "$out" "doctor sin fallos" "el gate NO se borra: no dice que el doctor está limpio"

rm -f "$WS/bin/gh" "$LEDGER" "$IWS/.doctor-red"
rmdir "$IWS/.harness" 2>/dev/null || true
# el knob no persiste: es env var por invocación. Dejo un commit pendiente para
# los gates que siguen (el de arriba se publicó).
echo w > "$IWS/scripts/pendiente2.sh"
git -C "$IWS" add scripts/pendiente2.sh
git -C "$IWS" commit -qm "commit pendiente 2"

# gitleaks rojo: el gate que más importa en ESTE repo
printf '#!/bin/sh\necho "leak encontrado" >&2\nexit 1\n' > "$WS/bin/gitleaks"
chmod +x "$WS/bin/gitleaks"
out="$( ( cd "$IWS" && PATH="$WS/bin:$PATH" bash scripts/instance-ship.sh 2>&1 ) )"; rc=$?
assert_eq 3 "$rc" "gitleaks rojo: exit 3"
assert_contains "$out" "purga el secreto" "con la remediación (purgar, no pushear)"
rm -f "$WS/bin/gitleaks"

# lock tomado por un proceso vivo: dos sesiones no se pisan
mkdir -p "$IWS/locks/instance.lock.d"; echo $$ > "$IWS/locks/instance.lock.d/pid"
out="$(run_is)"; rc=$?
assert_eq 6 "$rc" "lock vivo: exit 6"
assert_contains "$out" "otra sesión" "nombra la causa"
rm -rf "$IWS/locks/instance.lock.d"

# limpio el commit pendiente para no dejar la puerta a medias
out="$(run_is)"; rc=$?
assert_eq 0 "$rc" "resuelto todo: el commit pendiente sale"

echo "── sin remote: honesto, no un push a la nada"

git -C "$IWS" remote remove origin
out="$(run_is)"; rc=$?
assert_eq 2 "$rc" "sin origin: exit 2"
assert_contains "$out" "no hay dónde pushear" "y lo dice con la remediación"
git -C "$IWS" remote add origin "$WS/origin.git"

echo "── las DOS puertas están nombradas donde el agente choca"

hook_out="$(jq -nc --arg c 'git push origin main' '{tool_input:{command:$c}}' \
  | bash "$ROOT/templates/hooks/block-direct-push.sh" 2>&1 >/dev/null)" || true
assert_contains "$hook_out" "instance-ship.sh" "el hook nombra la puerta de la instancia"
assert_contains "$hook_out" "ship.sh" "y la de los repos de producto"

# ship.sh con un repo que no está en repos/: manda a la puerta correcta
SWS="$WS/shipws"; mkdir -p "$SWS/scripts" "$SWS/tasks/T1" "$SWS/repos"
sed -e 's/{{FLOW}}/trunk/' -e 's/{{LOOP_BUDGET}}/3/' \
  "$ROOT/templates/scripts/ship.sh.tmpl" > "$SWS/scripts/ship.sh"
out="$( ( cd "$SWS" && bash scripts/ship.sh T1 instancia ) 2>&1 )"; rc=$?
assert_eq 2 "$rc" "ship.sh con repo fuera de repos/: exit 2"
assert_contains "$out" "instance-ship.sh" "y manda a la puerta de la instancia, no a un callejón"
assert_not_contains "$out" "worktree-task.sh instancia" "el callejón viejo (crear worktree de la instancia) ya no se sugiere"

t_done
