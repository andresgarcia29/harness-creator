#!/usr/bin/env bash
# instance-ship.sh: la puerta a main del REPO DE LA INSTANCIA (el workspace).
#
# POR QUÉ EXISTE (issue #37): el repo de la instancia no tenía camino
# legítimo a main. block-direct-push bloquea el push (Ley 1) y ship.sh solo
# opera sobre repos/ de producto, así que cada /harness-update producía un
# commit que nadie podía pushear por la puerta: el humano terminaba pusheando
# a mano POR FUERA del harness, que es exactamente lo que la Ley 15 llama un
# bug del harness ("que no exista un camino legítimo significa que falta
# uno"). Esto NO es una excepción al hook: es una puerta con los gates que
# SÍ aplican a este repo. El hook no lo bloquea por la misma razón que no
# bloquea a ship.sh: el push vive DENTRO del script sancionado.
#
# Qué contiene el repo de la instancia: specs maestras, ADRs, constitución,
# scripts del harness, harness-answers (REFERENCIAS a secretos, jamás
# valores). No hay suite de producto que correr; los gates que importan son:
#   1. ningún archivo DEL PUSH con ediciones sin commitear (no publicar a
#      medias); el resto de la suciedad es de otras tareas y solo avisa
#   2. rebase sobre origin (la misma disciplina que ship.sh)
#   3. gitleaks sobre el rango a pushear (el riesgo número UNO acá: un
#      token o un .secrets colado a main en el repo que versiona la config)
#   4. doctor en verde (una instancia rota no se publica a sí misma), con el
#      escape declarado de HARNESS_KNOWN_BUG para el rojo que NO es tuyo
#
# Uso: instance-ship.sh
#   -h, --help   imprime el uso y sale sin efectos.
# Portabilidad: bash 3.2, BSD userland.
set -euo pipefail

# ── Argumentos: se parsean ANTES de cualquier gate (issue #63) ──────
# Sin este parser, `instance-ship.sh --help` (o un typo, o un --dry-run que
# no existe) corría el ship COMPLETO con su push irreversible a origin: el
# script ignoraba "$@" y caía directo en los gates. El único argumento válido
# es -h/--help: imprime el uso y sale 0 SIN efectos. Cualquier otra cosa se
# rechaza antes de pisar el repo.
if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  echo "Uso: instance-ship.sh"
  echo "  Publica el repo de la instancia a origin (la puerta a main, con gates)."
  echo "  -h, --help   imprime este uso y sale sin efectos."
  exit 0
fi
if [ "$#" -gt 0 ]; then
  echo "❌ argumento(s) no soportados: $*"
  echo "   ↳ Uso: instance-ship.sh  (sin argumentos; -h/--help imprime la ayuda)"
  exit 2
fi

WS="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WS"

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "❌ el workspace no es un repo git (instance.repo: self sin git init)"
  echo "   ↳ remediación: git init + remote origin, o declara instance.repo en harness-answers.yaml"
  exit 2; }

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "ℹ️  el repo de la instancia no tiene remote origin: no hay dónde pushear."
  echo "   Si la instancia debe versionarse fuera de esta máquina:"
  echo "   git remote add origin <url de instance.repo en harness-answers.yaml>"
  exit 2
fi

# shellcheck source=/dev/null
[ -f "$WS/scripts/instance-repo.sh" ] && . "$WS/scripts/instance-repo.sh" \
  || instance_repo_slug() { :; }

BB="${HARNESS_BASE_BRANCH:-$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')}"
[ -n "$BB" ] || BB=main

# ── EL ROJO QUE NO ES TUYO: HARNESS_KNOWN_BUG='doctor=<url>' ──────────
# Caso de campo (issue #59): doctor.sh contaba como leyes duplicadas una lista
# numerada AJENA que `bd setup codex` inyecta en AGENTS.md. Con el doctor en
# rojo por un bug DEL HARNESS, esta puerta (la ÚNICA legítima a main del repo de
# la instancia: specs maestras, ADRs, constitución) quedaba cerrada para TODA
# tarea, y la única salida era editar AGENTS.md o doctor.sh en medio de una
# tarea, que es exactamente lo que la Ley 12 prohíbe. Bloqueó el archive de una
# tarea más 7 commits ya commiteados de otras. ship.sh ya tenía este escape;
# que la otra puerta no lo tuviera era el bug.
#
# COPIA DELIBERADA de known_bug_cubre() de ship.sh.tmpl, con los MISMOS candados
# y los MISMOS mensajes. No se extrajo a una librería porque ship.sh es un
# template con sustituciones y este script se instala tal cual: hoy no hay un
# lugar compartido donde vivan los dos. DOS COPIAS QUE DIVERGEN EN LA PRIMERA
# EDICIÓN SON UN PROBLEMA CONOCIDO DE ESTE REPO: si tocás los candados acá,
# tocá también templates/scripts/ship.sh.tmpl (y al revés). Los tests de los dos
# lados prueban los mismos cuatro candados justo para que la divergencia grite.
#
# Los candados son el diseño, no un adorno:
#   · EXIGE EL SLOT, no solo la url. Un salto-todo sería una puerta trasera.
#     Acá el único slot declarable es `doctor`.
#   · SLOTS VETADOS, jamás declarables: `security` y `veredicto`. En esta puerta
#     `security` es gitleaks, y un secreto colado a main en el repo que versiona
#     la config del harness es el peor accidente posible acá.
#   · REPORTAR ES LA PRECONDICIÓN: la url tiene que estar YA en
#     .harness/upstream-issues.jsonl, y ahí solo llega por harness-bug.sh.
#   · ISSUE CERRADO = WORKAROUND VENCIDO: si gh dice CLOSED, se rechaza (el fix
#     existe: /harness-update). Sin gh o sin red se acepta, pero declarándolo.
#   · NO PERSISTE (env var por invocación) y NO BORRA EL GATE: se declara, sale
#     un `assumption` al bus y queda dicho en la salida.
KNOWN_BUG="${HARNESS_KNOWN_BUG:-}"

# known_bug_cubre <slot> → 0 SOLO si el knob declara ESE slot y pasa los cuatro
# candados. Es un predicado: se llama desde la condición de un `if`, así que
# jamás debe salir != 0 por otra cosa que no sea "no cubre". Cada rechazo
# imprime su motivo CON la remediación: un "no" mudo devolvería al agente al
# bucle de tocar el harness, que es justo lo que este camino existe para evitar.
known_bug_cubre() {  # known_bug_cubre <slot>
  local slot="$1" decl_slot decl_url estado
  [ -n "$KNOWN_BUG" ] || return 1
  case "$KNOWN_BUG" in
    *=*) ;;
    *) echo "❌ HARNESS_KNOWN_BUG='$KNOWN_BUG' no tiene forma '<slot>=<url>'."
       echo "   ↳ hay que NOMBRAR el slot: un salto-todo sería una puerta trasera."
       echo "     El único slot declarable en esta puerta es 'doctor'."
       return 1 ;;
  esac
  decl_slot="${KNOWN_BUG%%=*}"
  decl_url="${KNOWN_BUG#*=}"

  # CANDADO 1 (la defensa principal): hay slots que no se rodean nunca. Acá se
  # chequea ANTES de comparar el slot (en ship.sh va después) porque esta puerta
  # tiene UN solo slot: si no, el intento de declarar 'security' saldría por la
  # rama muda de abajo y el motivo no se imprimiría nunca.
  case "$decl_slot" in
    security|veredicto)
      echo "❌ los slots 'security' y 'veredicto' no se rodean JAMÁS, ni con issue abierto."
      echo "   · security: un secreto filtrado jamás es un bug del harness, y este"
      echo "     es el repo donde un token colado a main duele más."
      echo "   · veredicto: sin veredicto no hubo review, y entonces no hay nada"
      echo "     que shippear todavía."
      echo "   ↳ si el gate de ese slot está roto de verdad: reportalo con"
      echo "     scripts/harness-bug.sh report y ESPERÁ el fix. Ese es el precio."
      return 1 ;;
  esac
  # Silencioso si el knob habla de OTRO slot: el rojo que bloquea ya se imprime
  # con su propio mensaje, y repetirlo acá sería el mismo hallazgo con dos caras.
  [ "$decl_slot" = "$slot" ] || return 1

  # CANDADO 2: forma de issue del forge. Un '<slot>=porque-si' no es una
  # declaración, es un salto sin rastro que nadie puede auditar después.
  case "$decl_url" in
    https://github.com/*/issues/*) ;;
    *) echo "❌ HARNESS_KNOWN_BUG apunta a '$decl_url', que no es la url de un issue."
       echo "   ↳ forma esperada: https://github.com/<org>/<repo>/issues/<n>"
       return 1 ;;
  esac

  # CANDADO 3: el issue tiene que estar YA en el ledger local, y ahí solo lo
  # pone harness-bug.sh (report verifica propiedad del artefacto, drift contra
  # el template, versión y repro; record anota uno abierto a mano). O sea:
  # REPORTAR ES LA PRECONDICIÓN DE DESBLOQUEARSE. Sin esto el knob sería un
  # "confía en mí" y el canal de vuelta al plugin se quedaría vacío.
  if ! grep -qF "\"url\":\"$decl_url\"" "$WS/.harness/upstream-issues.jsonl" 2>/dev/null; then
    echo "❌ $decl_url no está en .harness/upstream-issues.jsonl: ese bug no fue reportado."
    echo "   Reportar es la PRECONDICIÓN de desbloquearse, no un trámite posterior."
    echo "   ↳ remediación:"
    echo "     scripts/harness-bug.sh report --title '...' --file <artefacto-del-plugin> \\"
    echo "       --repro <archivo-con-la-salida> --impact '<a quién más le pasa>'"
    echo "     (si el issue ya existe y lo abriste a mano: harness-bug.sh record --url $decl_url ...)"
    return 1
  fi

  # CANDADO 4: un issue CERRADO significa que el fix ya existe. Seguir
  # declarándolo sería congelar el harness roto en esta máquina para siempre.
  # Sin gh o sin red no se puede saber: se acepta, pero DICIÉNDOLO (un
  # "verificado" que no verificó nada es peor que un desconocido declarado).
  estado=""
  if command -v gh >/dev/null 2>&1; then
    estado="$(gh issue view "$decl_url" --json state --jq .state 2>/dev/null || echo "")"
  fi
  if [ "$estado" = "CLOSED" ]; then
    echo "❌ el issue $decl_url está CERRADO: el workaround venció."
    echo "   El fix del harness ya existe; declararlo otra vez lo dejaría fuera."
    echo "   ↳ remediación: corré /harness-update y re-corré este instance-ship."
    return 1
  fi
  [ -n "$estado" ] || echo "   (estado del issue sin verificar: no hay gh o no hubo red)"
  return 0
}

# ── 1. Árbol limpio POR SOLAPAMIENTO: no se publica un archivo a medias ─
# El árbol de la instancia es COMPARTIDO entre tareas concurrentes: la Ley 7
# manda los ADR a docs/adr y /archive fusiona las delta-specs en specs/, así que
# varias tareas en vuelo lo ensucian a la vez. Caso de campo (COR-319): 55
# archivos sucios de OTRAS tareas y este gate en rojo, sin camino legítimo para
# publicar; la única salida era barrer trabajo ajeno, que es peor que el bug.
# Lo INNEGOCIABLE sigue intacto: un archivo que ESTE push toca no puede tener
# ediciones sin commitear (publicar el commit con el archivo a medias es justo
# lo que este gate impide). La suciedad que NO se solapa avisa y sigue: el
# rebase --autostash la aparta y la devuelve.
dirty="$(git status --porcelain -uno 2>/dev/null || true)"
# el path de cada línea de porcelain: "XY path" (y "old -> new" en los renames)
dirty_paths="$(printf '%s\n' "$dirty" | sed -e 's/^...//' -e 's/^.* -> //')"
outgoing="$(git diff --name-only "origin/$BB..HEAD" 2>/dev/null || true)"

# intersección sucio ∩ saliente. bash 3.2: sin arrays asociativos ni `comm`
# sobre process substitution; un bucle con `grep -F -x` es lo más simple.
overlap=""
if [ -n "$dirty" ] && [ -n "$outgoing" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if printf '%s\n' "$outgoing" | grep -qFx -- "$f"; then
      overlap="${overlap}${f}
"
    fi
  done <<EOF
$dirty_paths
EOF
fi

if [ -n "$overlap" ]; then
  echo "❌ hay ediciones SIN COMMITEAR sobre archivos que este push publica:"
  printf '%s' "$overlap" | sed -n '1,5s/^/   /p'
  echo "   ↳ remediación: commitea o descarta ESAS ediciones (publicar el commit"
  echo "     con el archivo a medias es justo lo que este gate impide)"
  exit 3
elif [ -n "$dirty" ]; then
  echo "⚠️  árbol con cambios ajenos a este push (trabajo en vuelo de otras tareas):"
  printf '%s\n' "$dirty" | sed -n '1,5s/^/   /p'
  echo "   NO se publican: el rebase los aparta y los devuelve (autostash)."
fi

# ── lock: dos sesiones publicando la instancia no se pisan ────────────
# `mkdir` solo no alcanza como mutex: con uutils coreutils (Ubuntu 26.04) hace
# check-then-act y bajo carrera le dice que sí a varios (issue #209). El dueño
# es quien crea `.owner`, cuyo O_EXCL lo hace la shell y no un binario.
mkdir_lock() {  # mkdir_lock <dir> → 0 solo si el lock es NUESTRO
  mkdir "$1" 2>/dev/null || return 1
  ( set -C; : > "$1/.owner" ) 2>/dev/null
}

LOCKDIR="$WS/locks/instance.lock.d"
mkdir -p "$WS/locks"
if ! mkdir_lock "$LOCKDIR"; then
  lpid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; then
    echo "⚠️  lock huérfano (pid $lpid ya no existe); lo reclamo"
    rm -rf "$LOCKDIR"; mkdir_lock "$LOCKDIR" || {
      echo "❌ otra sesión ganó la carrera al reclamar el lock; re-corre."; exit 6; }
  else
    echo "❌ otra sesión${lpid:+ (pid $lpid)} está publicando la instancia; espera o revisa."
    echo "   Si estás SEGURO de que no queda ninguna viva: rm -rf $LOCKDIR"
    exit 6
  fi
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

# ── 2. Rebase sobre origin: misma disciplina que ship.sh ──────────────
# --autostash porque el gate de arriba ya permite suciedad AJENA al push: sin
# esto el rebase moriría con "cannot rebase: you have unstaged changes" y el
# camino legítimo se cerraría de nuevo. El autostash la aparta y la devuelve.
git fetch origin
if ! rebase_out="$(git rebase --autostash "origin/$BB" 2>&1)"; then
  git rebase --abort >/dev/null 2>&1 || true
  echo "❌ no pude rebasear sobre origin/$BB:"
  printf '%s\n' "$rebase_out" | sed 's/^/   /'
  echo "   ↳ resuelve el conflicto en el workspace y re-corre instance-ship.sh"
  exit 4
fi

n="$(git rev-list --count "origin/$BB..HEAD" 2>/dev/null || echo 0)"
if [ "${n:-0}" -eq 0 ]; then
  echo "✅ nada que pushear: la instancia ya está al día con origin/$BB"
  exit 0
fi

# ── 3. gitleaks sobre el rango: EL gate de este repo ──────────────────
if command -v gitleaks >/dev/null; then
  echo "── gitleaks sobre origin/$BB..HEAD ──"
  gitleaks detect --no-banner --log-opts="origin/$BB..HEAD" || {
    echo "❌ gitleaks encontró secretos en lo que ibas a pushear. Este repo"
    echo "   versiona la CONFIG del harness: un token acá es el peor accidente."
    echo "   ↳ remediación: purga el secreto del historial (rebase -i / filtro),"
    echo "     muévelo a la fuente declarada (secrets.refs) y re-corre"
    exit 3; }
else
  echo "⚠️  gitleaks no está instalado: el rango se pushea SIN escanear secretos."
  echo "   Este es el repo donde un token colado duele más; instálalo (catálogo: gitleaks)."
  [ -f "$WS/scripts/emit.sh" ] && bash "$WS/scripts/emit.sh" assumption \
    "push de la instancia SIN escaneo de secretos: gitleaks no está instalado" \
    "" "" >/dev/null 2>&1 || true
fi

# ── 4. doctor en verde: una instancia rota no se publica ──────────────
if [ -x "$WS/scripts/doctor.sh" ]; then
  # ── ESTE GATE MIRA LA INSTANCIA, NO LA MÁQUINA (#185) ────────────────
  # Corría el doctor COMPLETO, que cuenta con el mismo peso dos cosas de
  # naturaleza distinta: que la instancia esté sana (links, hooks, reglas,
  # drift de templates) y que este host tenga provisionados sus CLIs. Solo la
  # primera dice algo sobre si el commit es seguro para main.
  # Caso de campo: un commit de documentos más el bump del harness quedó sin
  # publicar por 16 `cli faltante`, ninguno de los cuales ese commit ejecuta, y
  # la única salida que quedaba era declarar un HARNESS_KNOWN_BUG que no era un
  # bug del harness. Le pasa a todo host acotado: CI, un contenedor, una VPS
  # sin los SDK de cliente, que es justo donde el repo de la instancia se queda
  # sin camino a main (el hueco que este script existe para cerrar, #37).
  echo "── doctor de la INSTANCIA (los FAIL bloquean; los warn no) ──"
  echo "   (los CLI que falten en este host se cuentan como aviso: son de la"
  echo "    máquina, no de lo que se publica. 'make doctor' los sigue cobrando)"
  if bash "$WS/scripts/doctor.sh" --instance-only . >/dev/null 2>&1; then
    echo "✅ doctor sin fallos"
  elif known_bug_cubre doctor; then
    # NO se borra el gate: el rojo sigue siendo rojo, solo que DECLARADO y con
    # su issue upstream. `if !` sobre un predicado es seguro; envolver así el
    # gate mismo no lo sería (desactivaría errexit adentro).
    echo "⚠️  slot 'doctor' rojo por BUG CONOCIDO del harness: ${KNOWN_BUG#*=}"
    echo "   NO es un verde: es una condición DECLARADA. Queda en el bus y en"
    echo "   esta salida. Quitá el workaround cuando el issue cierre."
    [ -f "$WS/scripts/emit.sh" ] && bash "$WS/scripts/emit.sh" assumption \
      "instancia: slot 'doctor' rojo declarado como bug conocido del harness (${KNOWN_BUG#*=})" \
      "" "" >/dev/null 2>&1 || true
  else
    echo "❌ el doctor reporta FALLOS DE LA INSTANCIA, y una instancia rota no se publica a sí misma."
    echo "   Esto NO son CLIs que le falten a este host: ésos ya se cuentan como"
    echo "   aviso y no llegan hasta acá."
    echo "   ↳ remediación: bash scripts/doctor.sh --instance-only .  (el detalle"
    echo "     con remediaciones; sin el flag ves además lo que falta en la máquina)"
    echo "   ↳ si el rojo NO es tuyo (un bug del harness ya reportado upstream):"
    echo "     HARNESS_KNOWN_BUG='doctor=<url-del-issue>' scripts/instance-ship.sh"
    exit 3
  fi
fi

# ── push (vive DENTRO del script sancionado: el hook no aplica acá) ───
# El rango se captura ANTES del push: después, `origin/$BB..HEAD` está vacío y
# los trailers ya no se pueden leer de ahí.
RANGO_TRAILERS="$(git log --format='%(trailers:key=Task,valueonly)' "origin/$BB..HEAD" 2>/dev/null \
  | tr -d ' ' | grep -v '^$' | sort -u || true)"
git push origin "HEAD:$BB"
echo "🟢 instancia publicada: $n commit(s) a origin/$BB"
[ -f "$WS/scripts/emit.sh" ] && bash "$WS/scripts/emit.sh" ship \
  "repo de la instancia publicado: $n commit(s) a origin/$BB" "" "" >/dev/null 2>&1 || true

# ── LA FASE LA MUEVE EL HECHO, NO QUIEN INVOCA (#135) ─────────────────
# `ship.sh` registra `review → ship` él mismo tras cada push, justamente porque
# era la transición que el orquestador se olvidaba. Este script publicaba igual
# de bien y NO la registraba, así que una tarea cuyo cambio ya estaba en main
# quedaba clavada en `phase=review` para siempre, y de ahí no llegaba ni a
# deploy ni a archive. Las dos salidas que el mensaje de policy ofrece son
# FALSAS para este repo: `ship.sh` sale 2 (no es un repo de repos/) y
# `repos --remove` sería mentir, porque el repo participó y shippeó.
#
# La tarea sale de los trailers `Task:` del rango publicado, que ya son
# obligatorios: no hace falta un argumento nuevo ni que nadie se acuerde. Con
# más de una tarea en el rango no se elige por nosotros: se dicen las dos y se
# deja el registro al humano, porque adivinar cuál avanza sería peor que no
# registrar nada.
registrar_fase() {  # registrar_fase <task-id> <sha>
  local tarea="$1" sha="$2" out rc=0 repo
  [ -f "$WS/tasks/$tarea/state.json" ] || return 0
  # PRIMERO ship.log, DESPUÉS la transición, y ese orden no es cosmético: el
  # gate que decide es `POLICY-SHIP-004`, que cuenta repos con ship registrado.
  # Sin esta línea, la transición se niega con "faltan repos por shippear:
  # <repo>" sobre un repo que acaba de shippear, que es exactamente el mensaje
  # que el reporte trae. El formato es el MISMO que escribe ship.sh: un lector
  # (deploy-watch, la policy, el panel) no tiene por qué saber quién publicó.
  repo="$(instance_repo_slug)"; [ -n "$repo" ] || repo="$(basename "$WS")"
  printf '{"repo":"%s","sha":"%s","short":"%s","shipped_at":"%s"}\n' \
    "$repo" "$sha" "$(git rev-parse --short "$sha" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$WS/tasks/$tarea/ship.log"
  out="$(python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" \
          transition "$WS/tasks/$tarea" ship --actor instance-ship 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "📍 $tarea: fase registrada tras el push (review → ship)"
    return 0
  fi
  case "$out" in
    *POLICY-SHIP-004*)
      echo "   fase: sigue en review, faltan otros repos por shippear (es lo correcto)" ;;
    *POLICY-TRANSITION-001*)
      echo "   fase: ya estaba avanzada, no la muevo" ;;
    *)
      # No es un rojo del push: el cambio YA está en main. El motivo va delante.
      echo "⚠️  publiqué, pero la transición a ship no prosperó. El cambio YA está en origin/$BB."
      printf '%s\n' "$out" | sed 's/^/   /' ;;
  esac
}

if [ -z "$RANGO_TRAILERS" ]; then
  echo "ℹ️  ningún commit del rango trae trailer 'Task:': no hay fase que mover."
elif [ "$(printf '%s\n' "$RANGO_TRAILERS" | grep -c .)" -gt 1 ]; then
  # Con dos tareas en el rango no se elige por nadie: adivinar cuál avanza sería
  # peor que no registrar. Se nombran las dos y se deja el comando servido.
  echo "⚠️  el rango publicado mezcla varias tareas: no registro la fase de ninguna."
  printf '%s\n' "$RANGO_TRAILERS" | sed 's/^/   · /'
  echo "   ↳ registrá la que corresponda a mano (ship.log primero, si falta):"
  echo "     python3 scripts/harness-policy.py transition tasks/<id> ship --actor humano"
else
  registrar_fase "$RANGO_TRAILERS" "$(git rev-parse HEAD)"
fi
exit 0
