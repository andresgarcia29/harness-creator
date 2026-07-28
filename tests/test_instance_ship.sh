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

run_is() { ( cd "$IWS" && PATH="$WS/bin:$(t_path_without gitleaks)" bash scripts/instance-ship.sh 2>&1 ); }

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

# árbol sucio: no se publica a medias
echo x > "$IWS/scripts/nuevo.sh"; git -C "$IWS" add scripts/nuevo.sh
out="$(run_is)"; rc=$?
assert_eq 3 "$rc" "cambios sin commitear: exit 3"
assert_contains "$out" "SIN COMMITEAR" "nombra la causa"
git -C "$IWS" -c user.email=t@t -c user.name=t commit -qm "script nuevo"

# doctor con FALLOS: una instancia rota no se publica a sí misma
touch "$IWS/.doctor-red"
out="$(run_is)"; rc=$?
assert_eq 3 "$rc" "doctor rojo: exit 3"
assert_contains "$out" "no se publica a sí misma" "con el porqué"
assert_contains "$out" "scripts/doctor.sh" "y manda al detalle con remediaciones"
rm -f "$IWS/.doctor-red"

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
