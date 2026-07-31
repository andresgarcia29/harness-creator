#!/usr/bin/env bash
# test_adr_new.sh: la carrera de numeración de ADR (issue #46).
#
# El caso que importa es el de CONCURRENCIA, y se corre de verdad en paralelo
# (con `&` y `wait`), no simulado: el bug de campo fue exactamente ese. Tres
# tareas en vuelo sobre el único árbol sin aislar (el repo de la instancia)
# dejaron ADR-0023 y ADR-0024 sin commitear al mismo tiempo, elegidos por dos
# agentes que miraron el directorio y sumaron uno. Un test que llame al script
# ocho veces en serie pasa con el bug adentro y no prueba nada.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

SRC="$ROOT/templates/scripts/adr-new.sh"
TPL="$ROOT/templates/docs/adr-template.md"
[ -f "$SRC" ] || { echo "falta $SRC"; exit 1; }
[ -f "$TPL" ] || { echo "falta $TPL"; exit 1; }

# Una instancia de mentira con la MISMA forma que la real: scripts/ al lado de
# docs/adr/, y la plantilla instalada como ADR-0000-template.md (así la deja el
# skill harness-init). Si la instalación cambia de nombre, este test lo cacha.
mk_inst() {  # mk_inst <dir>
  mkdir -p "$1/scripts" "$1/docs/adr"
  cp "$SRC" "$1/scripts/adr-new.sh"
  cp "$TPL" "$1/docs/adr/ADR-0000-template.md"
}
num_of() {  # num_of <ruta> : el número del nombre de archivo
  printf '%s' "${1##*/}" | sed 's/^ADR-\([0-9][0-9]*\)-.*/\1/'
}

echo "── adr-new.sh: numeración base y plantilla real"
I="$WS/base"; mk_inst "$I"
p1="$(bash "$I/scripts/adr-new.sh" primer-adr 2>"$WS/e1")"
assert_eq "0001" "$(num_of "$p1")" "el primer ADR es 0001 (la plantilla es 0000 y cuenta)"
assert_file "$p1" "crea el archivo que imprime"

body="$(cat "$p1")"
# "Sale de la plantilla real" no es "se le parece": se compara contra el
# contenido de templates/docs/adr-template.md, no contra un formato inventado.
assert_contains "$body" "## Alternativas rechazadas" "el cuerpo trae las secciones de la plantilla"
assert_contains "$body" "nada es oficial fuera de docs/adr/" "el cuerpo trae el cierre de la plantilla"
assert_contains "$body" "# ADR-0001 " "el h1 lleva el número reservado"
assert_not_contains "$(head -1 "$p1")" "ADR-NNNN" "el h1 no deja el placeholder de la plantilla"
assert_contains "$body" "- **Fecha**: $(date +%Y-%m-%d)" "sella la fecha de hoy"
# Y no se le escapan campos: lo que la plantilla deja para el humano sigue ahí.
assert_contains "$body" "- **Estado**: propuesto" "respeta lo que la plantilla deja para el autor"

echo
echo "── adr-new.sh: cuenta los ADR SIN COMMITEAR (el caso del issue #46)"
# El árbol es compartido y los ADR que colisionan son justamente los que aún no
# se commitearon: si el máximo saliera del índice de git, acá daría 0001.
I="$WS/dirty"; mk_inst "$I"
git -C "$I" init -q
git -C "$I" add -A >/dev/null 2>&1
git -C "$I" commit -qm "solo la plantilla" >/dev/null 2>&1
: > "$I/docs/adr/ADR-0023-de-otra-tarea-sin-commitear.md"
untracked="$(git -C "$I" status --porcelain docs/adr | grep -c '^??' | tr -d ' ')"
assert_eq "1" "$untracked" "el ADR-0023 del vecino está sin trackear (premisa del caso)"
p="$(bash "$I/scripts/adr-new.sh" mi-decision)"
assert_eq "0024" "$(num_of "$p")" "con un 0023 sin commitear, el siguiente es 0024 y no 0023"

echo
echo "── adr-new.sh: 8 procesos EN PARALELO reservan 8 números distintos"
I="$WS/race"; mk_inst "$I"; mkdir -p "$WS/out"
i=1
while [ "$i" -le 8 ]; do
  ( bash "$I/scripts/adr-new.sh" "tarea-concurrente-$i" >"$WS/out/$i.path" 2>"$WS/out/$i.err"
    echo $? > "$WS/out/$i.rc" ) &
  i=$((i + 1))
done
wait

oks=0; nums=""
i=1
while [ "$i" -le 8 ]; do
  rc="$(cat "$WS/out/$i.rc" 2>/dev/null || echo 99)"
  [ "$rc" = "0" ] && oks=$((oks + 1))
  path="$(cat "$WS/out/$i.path" 2>/dev/null || true)"
  [ -n "$path" ] && nums="$nums$(num_of "$path")
"
  i=$((i + 1))
done
assert_eq "8" "$oks" "los 8 procesos concurrentes salen en verde"
distintos="$(printf '%s' "$nums" | grep -c . )"
unicos="$(printf '%s' "$nums" | sort -u | grep -c . )"
assert_eq "8" "$(printf '%s' "$distintos" | tr -d ' ')" "los 8 imprimen una ruta"
assert_eq "8" "$(printf '%s' "$unicos" | tr -d ' ')" "los 8 números son DISTINTOS (la prueba del bug)"
creados="$(/bin/ls "$I/docs/adr" | grep -c 'tarea-concurrente' | tr -d ' ')"
assert_eq "8" "$creados" "hay 8 archivos en disco, uno por proceso"
# Y cada ruta impresa es de quien la imprimió: si dos se pisaran, el slug del
# archivo no coincidiría con el del proceso que lo reclamó.
mismatch=0
i=1
while [ "$i" -le 8 ]; do
  path="$(cat "$WS/out/$i.path" 2>/dev/null || true)"
  case "${path##*/}" in *"tarea-concurrente-$i.md") : ;; *) mismatch=1 ;; esac
  i=$((i + 1))
done
assert_eq "0" "$mismatch" "cada proceso recibe la ruta de SU propio ADR"

echo
echo "── adr-new.sh: con el lock tomado FALLA, no cuelga"
# Este repo ya pagó un cuelgue infinito (lock de ship.sh sin pid, irreclamable):
# el tope tiene que ser real y el mensaje accionable. El lock se toma con el pid
# del propio test, que está VIVO, así que el reclamo de huérfanos no aplica.
I="$WS/locked"; mk_inst "$I"
mkdir -p "$I/locks/adr-number.lock.d"
echo $$ > "$I/locks/adr-number.lock.d/pid"
t0="$(date +%s)"
set +e
out="$(HARNESS_ADR_LOCK_TIMEOUT=2 bash "$I/scripts/adr-new.sh" no-va 2>&1)"
rc=$?
set -e
t1="$(date +%s)"
assert_eq "6" "$rc" "sale con exit 6 (no pude reservar), no con 0"
assert_contains "$out" "lock ocupado" "dice por qué falló"
assert_contains "$out" "rm -rf" "dice cómo destrabarlo"
[ "$((t1 - t0))" -le 20 ] && pass "respeta el tope de espera ($((t1 - t0))s), no cuelga" \
  || fail "esperó $((t1 - t0))s con un tope de 2s: el tope no muerde"
# Fail-closed: no imprime ruta ni deja nada a medias.
assert_no_file "$I/docs/adr/ADR-0001-no-va.md" "con el lock tomado no crea el archivo"
sobras="$(/bin/ls "$I/docs/adr" | grep -c 'no-va' | tr -d ' ')"
assert_eq "0" "$sobras" "no deja archivos a medias cuando no puede reservar"

echo
echo "── adr-new.sh: los TIRANTES (noclobber) no pisan un nombre ya ocupado"
# El lock serializa, pero el segundo mecanismo es independiente a propósito: el
# día que el lock falle (un reclamo de huérfano de más, un FS raro), el modo de
# falla no puede ser "sobrescribo la decisión del otro" en silencio.
# Se dispara con un nombre que el escaneo NO puede contar (un symlink colgado:
# `[ -f ]` es falso) pero que O_EXCL sí ve ocupado. Sin `set -C`, el `>` seguiría
# el symlink y escribiría FUERA de docs/adr/ devolviendo una ruta mentirosa.
I="$WS/clobber"; mk_inst "$I"
ln -s "$I/afuera.md" "$I/docs/adr/ADR-0001-ocupado.md"
set +e
out="$(bash "$I/scripts/adr-new.sh" ocupado 2>&1)"; rc=$?
set -e
assert_eq "6" "$rc" "no pisa un nombre ocupado: sale en rojo"
assert_contains "$out" "ya existe" "dice que el nombre ya estaba tomado"
assert_no_file "$I/afuera.md" "no escribió a través del symlink (O_EXCL hizo su trabajo)"

echo
echo "── adr-new.sh: entrada inválida, fail-closed"
I="$WS/bad"; mk_inst "$I"
set +e
out="$(bash "$I/scripts/adr-new.sh" "../../escape" 2>&1)"; rc=$?
set -e
assert_eq "2" "$rc" "un slug con ../ es rechazado"
assert_contains "$out" "slug inválido" "explica el rechazo"
antes="$(/bin/ls "$I/docs/adr" | wc -l | tr -d ' ')"
set +e
bash "$I/scripts/adr-new.sh" >/dev/null 2>&1; rc=$?
set -e
assert_eq "2" "$rc" "sin slug es error de uso"
assert_eq "$antes" "$(/bin/ls "$I/docs/adr" | wc -l | tr -d ' ')" "ninguna entrada inválida crea archivos"
# Sin plantilla no inventa un formato: falla.
I="$WS/notpl"; mkdir -p "$I/scripts" "$I/docs/adr"
cp "$SRC" "$I/scripts/adr-new.sh"
set +e
out="$(bash "$I/scripts/adr-new.sh" sin-plantilla 2>&1)"; rc=$?
set -e
assert_eq "2" "$rc" "sin la plantilla instalada, falla"
assert_contains "$out" "falta la plantilla" "dice que falta la plantilla"
assert_no_file "$I/docs/adr/ADR-0001-sin-plantilla.md" "sin plantilla no deja archivo"

t_done
