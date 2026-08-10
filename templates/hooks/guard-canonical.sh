#!/usr/bin/env bash
# Hook PreToolUse (Edit|Write|MultiEdit): tres leyes con dientes.
#   LEY 4: nunca editar el clon canónico repos/<x>; el trabajo vive en
#          worktrees/<task>/<repo>.
#   EL PIN ES DE SOLO LECTURA: worktrees/<task>/.review-<repo> es el árbol
#          CLAVADO al commit sellado, y es el que el veredicto juzga. Escribir
#          ahí invalida el juicio en silencio.
#   LEY 0: NINGÚN agente edita el harness mientras hace una tarea. Los gates,
#          los hooks y los denials NO son código de producto: son la ley que
#          juzga al agente que los tocaría. Un agente atascado en el gate 6 al
#          que se le ocurre "arreglar" ship.sh no está pasando el gate: lo
#          está borrando, y con él todos los demás para siempre. Cambiar la ley
#          es trabajo de un humano, en un PR, mirándolo de frente.
# FAIL-CLOSED: sin jq, bloquea por precaución.
#
# ── RESIDUO DECLARADO (lo que este hook NO tapa) ──────────────────────
# Este hook cuelga del matcher Edit|Write|MultiEdit. Un agente decidido a
# reescribir el harness puede hacerlo igual desde Bash: `sed -i`, `cat >`,
# `python - <<EOF`, `git checkout` de otra rama. Ese tramo es de OTRO hook (el
# de matcher Bash, donde ya viven block-direct-push y guard-ws-scripts) y queda
# como follow-up EXPLÍCITO: mientras tanto, la Ley 0 muerde en el camino que el
# agente usa el 95% de las veces, no en todos. Un guard parcial y declarado es
# honesto; uno parcial y silencioso enseña una garantía que no existe.
set -uo pipefail
input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | grep -qE "/repos/|/\.review-|/\.claude/hooks/|ship\.sh|settings\.json|harness-policy\.json"; then
    echo "⛔ jq no disponible: bloqueo por precaución (Ley 4 / Ley 0). Instala jq." >&2
    exit 2
  fi
  exit 0
fi

path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[ -n "$path" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# ── LA VENTANA DE LA LEY 0 ────────────────────────────────────────────
# /harness-update reescribe scripts y hooks A MANO (paso 2b, el fallback sin
# binario `harness`). Sin una ventana explícita, el propio playbook que existe
# para actualizar el harness queda bloqueado por este guard, y quien lo corre
# aprende a desactivar el hook: exactamente lo que la ley intenta evitar.
#
# ES UN ARCHIVO EN DISCO Y NO UNA VARIABLE DE ENTORNO A PROPÓSITO: los hooks de
# Edit/Write corren en un PROCESO APARTE, así que lo que el agente exportó en un
# Bash previo no llega hasta acá. Una perilla por entorno se vería igual de
# verde y no abriría nada.
#
# CADUCA A LA HORA: un marcador olvidado deroga la ley para siempre, y el que
# lo olvida es justo el que ya no se acuerda de que existe.
# Es abusable (el agente puede crear el marcador solo), pero JAMÁS silencioso:
# cada escritura que pasa por acá emite una `assumption` al bus. El mensaje de
# bloqueo, por eso mismo, NO dice cómo se crea el marcador: entregarle la llave
# al agente en bucle es no tener ley.
LEY0_VENTANA="$root/.harness/update-in-progress"
LEY0_TTL=3600

ley0_ventana_abierta() {  # ley0_ventana_abierta <path> → 0 si se permite escribir
  local mt now
  [ -f "$LEY0_VENTANA" ] || return 1
  # BSD primero (macOS es el host mayoritario), GNU de fallback. Sin este par,
  # el guard queda fail-OPEN en un lado o fail-CLOSED perpetuo en el otro.
  mt="$(stat -f %m "$LEY0_VENTANA" 2>/dev/null)" || mt=""
  [ -n "$mt" ] || mt="$(stat -c %Y "$LEY0_VENTANA" 2>/dev/null)" || mt=""
  case "$mt" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ "$((now - mt))" -lt "$LEY0_TTL" ] || return 1
  if [ -f "$root/scripts/emit.sh" ]; then
    bash "$root/scripts/emit.sh" assumption \
      "Ley 0 saltada por la ventana de /harness-update: se escribió $1" \
      >/dev/null 2>&1 || true
  fi
  return 0
}

ley0_juzga() {  # ley0_juzga <path>: pasa si la ventana está abierta, si no corta
  ley0_ventana_abierta "$1" && return 0
  printf '⛔ Ley 0: el harness NO se edita durante una tarea: %s\n' "$1" >&2
  cat >&2 <<'LEY0'
   Ese archivo es parte del juez, no del producto. Si te dio un falso
   rojo o está roto, NO lo arregles NI lo pruebes. El camino es:
   1. reportalo: scripts/harness-bug.sh report --title ... --file ... \
      --repro <log> --impact '...'
   2. desbloqueá TU ship declarándolo:
      HARNESS_KNOWN_BUG='<slot>=<url-del-issue>' scripts/ship.sh ...
   3. seguí con TU tarea: el fix del harness es de sus mantenedores.
   (¿Estás corriendo /harness-update? Ese playbook abre su propia
   ventana en su paso 0c; seguilo, no improvises acá.)
LEY0
  exit 2
}

# ── QUÉ SCRIPTS SON DEL PLUGIN (issue #104) ──────────────────────────
# La lista viaja como DATO y no como cuarenta ramas de `case` por dos razones.
# La primera es que un `case` multilínea mete los espacios de la indentación
# DENTRO del patrón y deja de matchear, que es un pie de bala silencioso. La
# segunda importa más: así el test la lee sin parsear bash y la compara contra
# templates/scripts/, o sea que una lista cableada no puede envejecer sin que
# la suite lo cace. Es la misma regla que se aplicó a las cuentas del README.
#
# Son los scripts que el generador instala bajo scripts/ (la tabla de
# generación de skills/harness-init/SKILL.md), más doctor.sh, que se COPIA
# desde el repo del plugin. El panel (scripts/ui/*) va por su propia rama.
PLUGIN_SCRIPTS='
adr-new.sh archived-repos.sh bootstrap.sh bounded.sh build-slot.sh
change-id.sh dag-coalesce.sh deploy-watch.sh doctor.sh emit.sh evidence.py fe.sh finding.sh
forge.sh gowork.sh graph-refresh.sh harness-bug.sh harness-cost.py
harness-metrics.py harness-policy.py harness-sink.py harness-version.sh
instance-repo.sh instance-ship.sh linear.sh mark-read.sh minion-probe.sh orchestrator-watch.sh
pipeline-steps.sh plan-lint.sh
port-forwards.sh pull-all.sh py.sh quiet.sh repo-brief.sh secrets.sh
ship-wave.sh ship.sh skills-sync.sh stamp-models.sh task-note.py ticket-close.sh
ticket-pull.sh verdict-beads.sh verdict-scaffold.sh with-secrets.sh
worktree-task.sh
'

del_plugin() {  # del_plugin <ruta relativa a scripts/> → 0 si la instala el plugin
  case "$1" in ui/*) return 0 ;; esac
  local s
  # shellcheck disable=SC2086
  for s in $PLUGIN_SCRIPTS; do [ "$s" = "$1" ] && return 0; done
  return 1
}

case "$path" in
  "$root"/repos/*)
    echo "⛔ edición del clon canónico bloqueada (Ley 4): $path" >&2
    echo "   Crea tu worktree: scripts/worktree-task.sh <task-id> <repo> y edita ahí." >&2
    exit 2
    ;;
  # ── EL ÁRBOL CLAVADO NO SE MUTA ──────────────────────────────────────
  # Caso de campo: el reviewer hizo verificación por mutación (editar src/
  # para comprobar que un test se pone rojo) sobre el árbol que QA estaba
  # midiendo EN PARALELO. El build de QA absorbió el archivo mutado y un test
  # sin trackear; la medición quedó corrupta y solo se salvó porque QA
  # sospechó. Nada se lo avisó. Un falso rojo cuesta una ronda; un falso verde
  # shippea el bug.
  #
  # El pin además es el árbol que el veredicto SELLA: mutarlo es juzgar un
  # código distinto del que se declara juzgado.
  #
  # No hace falta mutar a mano: `gate_test_muerde` ya corre cada test nuevo
  # contra el árbol base en un worktree TEMPORAL, aislado, en cada precheck.
  "$root"/worktrees/*/.review-*)
    echo "⛔ el árbol clavado es de SOLO LECTURA: $path" >&2
    echo "   worktrees/<task>/.review-<repo> es el árbol sellado que tu veredicto" >&2
    echo "   juzga. Mutarlo invalida el juicio, y en el árbol vivo de al lado hay" >&2
    echo "   un QA midiendo: una mutación ahí le corrompe la medición en silencio." >&2
    echo "   ↳ para probar que un test MUERDE no hace falta mutar: el precheck ya" >&2
    echo "     lo hace aislado (gate_test_muerde, contra el árbol base)." >&2
    echo "   ↳ si necesitás una sonda manual, que sea descartable:" >&2
    echo "     git -C worktrees/<task>/<repo> worktree add --detach /tmp/sonda HEAD" >&2
    echo "     (mutá ahí y borrala con: git worktree remove --force /tmp/sonda)" >&2
    exit 2
    ;;
  # ── LEY 0: EL JUEZ NO SE EDITA MIENTRAS TE JUZGA ──────────────────────
  # Caso de campo: un agente con una tarea de PRODUCTO tropieza con un gate que
  # le da un falso rojo, se pone a arreglar el harness en el medio y entra en
  # bucle: cada intento de "probar" el fix vuelve a correr el gate, y la tarea
  # que lo trajo queda sin terminar. La ley ya estaba escrita en el encabezado
  # de este archivo desde el primer día; lo que faltaba era el `case`.
  #
  # OJO CON EL ORDEN: en un `case` de bash el `*` matchea `/` también, así que
  # los carve-outs de smoke y cronjobs van ANTES de la rama general de scripts
  # o esta se los come.
  #
  # smoke/ y cronjobs/ son DE LA INSTANCIA (misma tabla de propiedad que
  # `owner_of` en harness-bug.sh): son los tests de humo y los jobs que escribe
  # el workspace, no el plugin. Bloquearlos sería frenar trabajo propio.
  "$root"/scripts/smoke/*|"$root"/scripts/cronjobs/*)
    ;;
  # Un hook o una política NUEVOS también son ley: acá el criterio no es si el
  # archivo existe, porque CREAR un hook es escribir una regla que va a juzgar a
  # todos los que vengan después. settings.json entra porque es quien los cablea:
  # sin él, un hook en disco no lo invoca nadie (y al revés, editarlo desactiva
  # hooks sin tocar una línea de sus scripts).
  "$root"/.claude/hooks/*|"$root"/.claude/settings.json|"$root"/harness-policy.json)
    ley0_juzga "$path"
    ;;
  # ── BAJO scripts/ LA PREGUNTA ES DE QUIÉN ES, NO SI EXISTE (issue #104) ──
  # El criterio era `[ -e "$path" ]`, o sea: existir equivalía a ser del plugin.
  # Medido en campo, las dos mitades se contradecían dentro de la MISMA tarea:
  # un Write creaba scripts/check-nats-events.py y pasaba (todavía no existía),
  # y el Edit siguiente sobre ESE MISMO archivo se bloqueaba (ya existía) con un
  # mensaje de Ley 0 que le decía al agente que no tocara el harness cuando no
  # estaba tocando el harness. Si crear ahí estuviera prohibido, el Write
  # tampoco debía pasar; si está permitido, corregir lo recién creado también.
  #
  # Y el daño no era la molestia: el archivo quedaba CONGELADO en su primera
  # versión, en esa tarea y en todas las futuras. Varias reglas del workspace
  # mandan versionar herramientas propias justo bajo scripts/, así que la ley
  # castigaba exactamente lo que otra ley ordena hacer. Peor, el límite se
  # descubría DESPUÉS de escribir, no antes.
  #
  # La procedencia no se adivina: es la lista de lo que el generador instala.
  # tests/test_guard_canonical.sh la DERIVA de templates/scripts/ y falla si
  # esta se queda atrás, que es la única forma de que una lista cableada no
  # envejezca. Lo que no está acá lo escribió la instancia, y la instancia
  # puede corregir lo suyo.
  #
  # NO entra acá el trabajo legítimo sobre el repo del plugin dentro de un
  # worktree: estos patrones están anclados a "$root"/scripts/, y
  # worktrees/<task>/harness-creator/templates/scripts/... no matchea.
  "$root"/scripts/*)
    del_plugin "${path#"$root"/scripts/}" && ley0_juzga "$path"
    ;;
esac
exit 0
