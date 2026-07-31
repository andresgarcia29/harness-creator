#!/usr/bin/env bash
# adr-new.sh: reserva el PRÓXIMO número de ADR de forma atómica y crea el
# archivo desde la plantilla del repo. Imprime la RUTA creada en stdout.
#
# POR QUÉ EXISTE (caso de campo, issue #46):
# Los repos de producto se aíslan por tarea en `worktrees/<task>/<repo>`, pero
# el repo de la INSTANCIA no tiene ese mecanismo y el pipeline obliga a escribir
# ahí: la Ley 7 manda cada decisión a `docs/adr/`. Hasta hoy el número lo elegía
# un agente mirando el directorio con la vista, y con tareas concurrentes dos
# agentes veían el mismo máximo y elegían el mismo número. Medido el 29/07 con
# tres tareas en vuelo: ADR-0023 y ADR-0024 sin commitear al mismo tiempo, de
# tareas distintas, sobre un solo árbol de trabajo compartido.
#
# "Mirá el directorio y sumá uno" no es una operación atómica: entre el `ls` y
# el `write` hay una ventana, y con N agentes esa ventana se abre N veces.
#
# ── POR QUÉ CUENTA LOS ARCHIVOS SIN COMMITEAR ─────────────────────────
# El máximo sale del FILESYSTEM (glob sobre docs/adr/), nunca del índice de
# git, justamente porque los ADR que colisionan son los que todavía no se
# commitearon: preguntarle a git por `HEAD` devolvería 0022 mientras 0023 y
# 0024 ya existen en disco sin trackear. Ese fue el bug exacto.
#
# ── CINTURÓN Y TIRANTES ───────────────────────────────────────────────
# Dos mecanismos independientes, no uno con respaldo decorativo:
#   1. CINTURÓN: lock por `mkdir` (mismo patrón que el LOCKDIR de ship.sh).
#      `mkdir` es atómico en POSIX: o lo crea uno solo, o falla. Serializa la
#      sección crítica entera (escanear el máximo + crear el archivo).
#   2. TIRANTES: el archivo nace bajo `set -C` (noclobber), donde el `>` usa
#      O_EXCL. Si un día el lock falla (NFS, un lock reclamado de más, alguien
#      que corre el script con el lock parcheado), dos procesos que pasen el
#      cinturón igual NO se pisan: el segundo falla al crear y sale en rojo en
#      vez de sobrescribir el ADR del otro.
# El segundo mecanismo existe porque el modo de falla del primero es silencioso
# y destructivo: perder una decisión ya escrita.
#
# ── FAIL-CLOSED ───────────────────────────────────────────────────────
# Si no puede reservar, NO imprime ruta y NO deja el archivo a medias: el trap
# borra el archivo vacío que haya creado. Un agente que lee una ruta de stdout
# tiene que poder confiar en que esa ruta es SUYA y está completa.
#
# ── NUNCA CUELGA ──────────────────────────────────────────────────────
# La espera del lock tiene tope duro (HARNESS_ADR_LOCK_TIMEOUT, default 30s) y
# falla con mensaje accionable. Este repo ya pagó un bug de cuelgue infinito
# (lock de ship.sh sin pid, irreclamable, 10 min de espera para siempre): no se
# repite la clase. Además reclama el lock si su dueño está SEGURO muerto, con
# el mismo sesgo conservador que ship.sh: "no pude mirar" no es "está muerto".
#
# Uso: adr-new.sh <slug-en-kebab> [titulo]
# Salida: la ruta del archivo creado, en stdout, una línea.
# Exit: 0 ok · 2 uso o entorno inválido · 6 no se pudo reservar el número.
#
# Portabilidad: bash 3.2 (macOS), awk y sed BSD. Sin flock (no existe en macOS).
set -u

WS="$(cd "$(dirname "$0")/.." && pwd)"
ADR_DIR="$WS/docs/adr"
# La plantilla instalada en la instancia (ver el skill harness-init: sale de
# templates/docs/adr-template.md y aterriza como ADR-0000-template.md). No se
# inventa un formato nuevo: si la plantilla cambia, los ADR nuevos la siguen.
TPL="${HARNESS_ADR_TEMPLATE:-$ADR_DIR/ADR-0000-template.md}"
LOCKDIR="$WS/locks/adr-number.lock.d"
LOCK_TIMEOUT="${HARNESS_ADR_LOCK_TIMEOUT:-30}"

die() { printf '%s\n' "$1" >&2; exit "${2:-2}"; }

SLUG="${1:-}"
[ -n "$SLUG" ] || die "uso: adr-new.sh <slug-en-kebab> [titulo]"
# kebab estricto: además de estilo, cierra el paso a `../` y a rutas absolutas
# en un nombre que se concatena a un path.
case "$SLUG" in
  [a-z0-9]*[a-z0-9]|[a-z0-9]) : ;;
  *) die "❌ slug inválido: '$SLUG' (kebab: minúsculas, dígitos y guiones)" ;;
esac
case "$SLUG" in
  *[!a-z0-9-]*) die "❌ slug inválido: '$SLUG' (kebab: minúsculas, dígitos y guiones)" ;;
esac

case "$LOCK_TIMEOUT" in
  ''|*[!0-9]*) die "❌ HARNESS_ADR_LOCK_TIMEOUT no es un entero: '$LOCK_TIMEOUT'" ;;
esac
[ "$LOCK_TIMEOUT" -gt 0 ] || die "❌ HARNESS_ADR_LOCK_TIMEOUT debe ser > 0"

# Título por defecto: el slug con espacios. Un ADR sin título igual arranca
# legible, y el agente lo reescribe cuando llena el cuerpo.
TITLE="${2:-}"
[ -n "$TITLE" ] || TITLE="$(printf '%s' "$SLUG" | tr '-' ' ')"

[ -f "$TPL" ] || die "❌ falta la plantilla de ADR: $TPL"
mkdir -p "$ADR_DIR" "$WS/locks" || die "❌ no pude crear $ADR_DIR"

# ── Limpieza fail-closed ──────────────────────────────────────────────
# FILE se borra salvo que el script haya llegado al final con el contenido
# escrito. Una ruta impresa tiene que ser un ADR completo, no un archivo vacío
# que el próximo escaneo cuente como número tomado sin contenido.
LOCK_HELD=0
FILE=""
DONE=0
cleanup() {
  [ "$DONE" -eq 0 ] && [ -n "$FILE" ] && rm -f "$FILE"
  [ "$LOCK_HELD" -eq 1 ] && rm -rf "$LOCKDIR"
  return 0
}
trap cleanup EXIT

pid_dead() {  # 0 = SEGURO muerto · 1 = vivo, o no se pudo saber
  # El sesgo va siempre a CONSERVAR el lock: esperar de más cuesta segundos,
  # robarle el lock a un proceso vivo cuesta dos ADR con el mismo número, que
  # es exactamente el bug que este script existe para cerrar.
  local err low
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null && return 1
  err="$(kill -0 "$1" 2>&1 || true)"
  low="$(printf '%s' "$err" | tr 'A-Z' 'a-z')"
  case "$low" in
    *"no such process"*|*"no existe"*|*"no such"*) return 0 ;;
    *) return 1 ;;   # EPERM (existe pero es de otro usuario) o mensaje ajeno
  esac
}

# ── CINTURÓN: lock por mkdir, atómico en POSIX ────────────────────────
# Ticks de 0.2s: la sección crítica dura milisegundos, así que 8 agentes
# concurrentes pasan en menos de 2 segundos en vez de 8.
acquire_lock() {
  local ticks=0 nopid=0 max lpid
  max=$((LOCK_TIMEOUT * 5))
  until mkdir "$LOCKDIR" 2>/dev/null; do
    if [ -f "$LOCKDIR/pid" ]; then
      nopid=0
      lpid="$(cat "$LOCKDIR/pid" 2>/dev/null)"
      if pid_dead "$lpid"; then
        printf '⚠️  lock huérfano de pid %s (proceso inexistente); lo reclamo\n' "$lpid" >&2
        rm -rf "$LOCKDIR"; continue
      fi
    else
      # Sin pid: o el dueño está EN la ventana entre el mkdir y el write del
      # pid (milisegundos), o murió dentro de ella y el lock quedó inmortal.
      # 5s de gracia y se reclama: sin esto, un SIGKILL con suerte de milésima
      # deja el ADR bloqueado hasta que un humano haga rm -rf.
      nopid=$((nopid + 1))
      if [ "$nopid" -ge 25 ]; then
        echo "⚠️  lock sin pid tras 5s: huérfano de una muerte en la ventana de adquisición; lo reclamo" >&2
        rm -rf "$LOCKDIR"; nopid=0; continue
      fi
    fi
    ticks=$((ticks + 1))
    if [ "$ticks" -ge "$max" ]; then
      printf '❌ no pude reservar el número de ADR: lock ocupado >%ss (%s)\n' "$LOCK_TIMEOUT" "$LOCKDIR" >&2
      echo "   Hay otro adr-new.sh en curso, o quedó un lock muerto." >&2
      echo "   Si nadie está creando un ADR: rm -rf $LOCKDIR" >&2
      exit 6
    fi
    sleep 0.2
  done
  LOCK_HELD=1               # ANTES del pid: si morimos ahora, el trap limpia
  echo $$ > "$LOCKDIR/pid"
}

acquire_lock

# ── Sección crítica: máximo del disco + 1 ─────────────────────────────
max=0
for f in "$ADR_DIR"/ADR-*.md; do
  [ -f "$f" ] || continue          # glob sin match se expande literal
  b="${f##*/}"
  n="${b#ADR-}"; n="${n%%-*}"; n="${n%.md}"
  case "$n" in ''|*[!0-9]*) continue ;; esac
  # 10# fuerza base decimal: sin eso, "0023" se lee como octal y "0009" muere.
  d=$((10#$n))
  [ "$d" -gt "$max" ] && max="$d"
done
NUM="$(printf '%04d' "$((max + 1))")"
FILE="$ADR_DIR/ADR-$NUM-$SLUG.md"

# ── TIRANTES: noclobber, o sea O_EXCL ─────────────────────────────────
# El `set -C` va en una SUBSHELL: así el noclobber no queda pegado al resto del
# script, y el "cannot overwrite existing file" que imprime la shell (no el
# comando, por eso el 2>/dev/null de adentro no lo tapaba) se silencia acá.
# El mensaje que ve el humano es el nuestro, con la ruta y el número.
if ! ( set -C; : > "$FILE" ) 2>/dev/null; then
  ruta="$FILE"; FILE=""        # no es nuestro: el trap no debe borrarlo
  printf '❌ ADR-%s ya existe (%s) y no lo piso\n' "$NUM" "$ruta" >&2
  exit 6
fi

# El cuerpo sale de la plantilla REAL, tal cual, con sustituciones puntuales:
# número, título, fecha y (si el entorno lo trae) la tarea. El separador y el
# resto del formato salen de la plantilla, así que si ella cambia, los ADR
# nuevos la siguen sin tocar este script.
#
# Se usa awk con index/substr y no sed: el título es texto LIBRE del usuario, y
# en el reemplazo de sed (y en el de sub() de awk) `&`, `/` y `\` son
# metacaracteres. Un ADR titulado "A/B testing & co" rompía la sustitución.
# Y el texto del usuario viaja por ENVIRON, no por `-v`: awk interpreta las
# secuencias de escape de un `-v`, o sea que un título con `\n` se partiría.
TODAY="$(date +%Y-%m-%d)"
if ! ADR_TITLE="$TITLE" ADR_TASK="${HARNESS_TASK:-}" \
   awk -v num="$NUM" -v hoy="$TODAY" '
  BEGIN { title = ENVIRON["ADR_TITLE"]; task = ENVIRON["ADR_TASK"] }
  NR == 1 {
    i = index($0, "ADR-NNNN")
    if (i > 0) $0 = substr($0, 1, i - 1) "ADR-" num substr($0, i + 8)
    j = index($0, "<")
    if (j > 0) $0 = substr($0, 1, j - 1) title
    print; next
  }
  /^- \*\*Fecha\*\*:/ { print "- **Fecha**: " hoy; next }
  /^- \*\*Task\*\*:/ && task != "" { print "- **Task**: " task; next }
  { print }
' "$TPL" > "$FILE"; then
  printf '❌ no pude escribir el ADR desde la plantilla %s\n' "$TPL" >&2
  exit 2
fi

DONE=1
printf '%s\n' "$FILE"
