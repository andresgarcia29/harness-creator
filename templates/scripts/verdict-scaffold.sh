#!/usr/bin/env bash
# verdict-scaffold.sh: esqueleto DETERMINISTA del veredicto. El reviewer no
# puede saber (ni debe adivinar) los campos mecánicos: commit, evidencia e
# implementadores salen de fuentes verificables; él solo pone JUICIO.
#
# Fuentes (espejan a evidence.py verify y harness-policy validate-ship):
#   commit                 = HEAD del worktree de la tarea
#   evidence[]             = ids de tasks/<t>/evidence/EV-*.json con
#                            repo+commit+commit_after correctos y exit_code 0
#   implementation_agents  = runners únicos de esa evidencia, excluyendo al
#                            reviewer y a "qa" (beads no guarda identidad;
#                            el runner del EV es la fuente honesta)
# Al sellar clava además un árbol DESACOPLADO del commit sellado en
# worktrees/<task>/.review-<repo>: el reviewer juzga ESE árbol, nunca el vivo,
# que sigue siendo del implementer (ver "ÁRBOL CLAVADO" más abajo).
#
# Placeholders INESCAPABLES para los gates: verdict:"PENDING_REVIEWER",
# qa:"pending", y requirements_uncovered:-1 (JAMÁS null/0: el check hace
# (// 0)==0 y null pasaría).
#
# Uso: verdict-scaffold.sh [--force|--rebase [--renew]|--merge-qa] [--allow-empty] <task-id> <repo> [reviewer]
#   --allow-empty  para el /review paralelo (la evidencia de QA llega después)
#   --force        re-scaffold (imprime commit/verdict previos; el juicio se pierde)
#   --rebase       re-review INCREMENTAL: conserva el juicio que el delta no tocó
#   --renew        (solo con --rebase) fuerza el re-scaffold aunque el cambio sea
#                  el mismo: para cuando policy rechazó el reuso por ventana
#   --merge-qa     fusiona qa-<repo>.json al veredicto MECANICAMENTE, validando
#                  que hablen del mismo cambio (mata el copy-paste en prosa que
#                  metía EVs de un tercer SHA al veredicto)
#
# POR QUÉ EXISTE --rebase: la evidencia está atada a un commit exacto
# (evidence.py exige commit == commit_after == HEAD), así que CUALQUIER commit
# nuevo la invalida entera, sin importar qué tocó. Hasta aquí está bien: es la
# prueba, y la prueba caduca. Lo que no estaba bien es que el único camino de
# vuelta era --force, que además borra el JUICIO: compliance[], non_blocking y
# los flags del reviewer. Un blocking estrecho ("falta un nil check") tiraba la
# matriz de compliance completa, incluidos los requirements que el fix ni rozó,
# y el reviewer volvía a derivar desde cero un juicio que seguía siendo válido.
#
# --rebase separa las dos cosas, que es la distinción que el harness ya hacía
# en otro lado: `evidence[]` se REGENERA (fail-closed, fresca en el HEAD nuevo)
# y `compliance[]` se ARRASTRA marcada con carried_from. Solo se devuelve a
# pendiente lo que el delta realmente tocó. El reviewer juzga el delta, no la
# tarea entera.
#
# El sesgo del matcheo es a RE-JUZGAR: si no se puede probar que una entrada es
# ajena al delta (rutas que no matchean, o una entrada que no cita artefacto),
# se marca covered:false. Arrastrar de más seria un falso verde; arrastrar de
# menos solo cuesta una re-lectura.
# Portabilidad: bash 3.2, BSD userland, jq.
set -euo pipefail

FORCE=0
ALLOW_EMPTY=0
REBASE=0
RENEW=0
REBIND=0
MERGE_QA=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --rebase) REBASE=1; shift ;;
    --renew) RENEW=1; shift ;;
    --merge-qa) MERGE_QA=1; shift ;;
    --allow-empty) ALLOW_EMPTY=1; shift ;;
    --*) echo "❌ flag desconocido: $1"; exit 1 ;;
    *) break ;;
  esac
done
[ "$FORCE" -eq 1 ] && [ "$REBASE" -eq 1 ] && {
  echo "❌ --force y --rebase son opuestos: uno borra el juicio previo, el otro lo conserva"
  exit 1; }
[ "$RENEW" -eq 1 ] && [ "$REBASE" -ne 1 ] && {
  echo "❌ --renew solo tiene sentido junto a --rebase (fuerza el re-scaffold en un rebase puro)"
  exit 1; }
[ "$MERGE_QA" -eq 1 ] && { [ "$FORCE" -eq 1 ] || [ "$REBASE" -eq 1 ]; } && {
  echo "❌ --merge-qa no se combina con --force/--rebase: fusionar y re-scaffoldear son operaciones distintas"
  exit 1; }
TASK="${1:?uso: verdict-scaffold.sh [--force] [--allow-empty] <task-id> <repo> [reviewer]}"
REPO="${2:?uso: verdict-scaffold.sh [--force] [--allow-empty] <task-id> <repo> [reviewer]}"
REVIEWER="${3:-reviewer}"

ok_id() { case "$1" in [A-Za-z0-9][A-Za-z0-9._-]*) return 0 ;; *) return 1 ;; esac; }
ok_id "$TASK" || { echo "❌ task-id inválido: '$TASK'"; exit 1; }
ok_id "$REPO" || { echo "❌ repo inválido: '$REPO'"; exit 1; }
ok_id "$REVIEWER" || { echo "❌ reviewer inválido: '$REVIEWER'"; exit 1; }
command -v jq >/dev/null || { echo "❌ jq requerido"; exit 1; }

WS="$(cd "$(dirname "$0")/.." && pwd)"

# ── EL REPO DE LA INSTANCIA NO TIENE WORKTREE, Y NUNCA VA A TENERLO (#135) ──
# `docs/`, `specs/`, los ADR y el answers viven en el repo de la INSTANCIA, que
# se publica desde su propio árbol por `instance-ship.sh`: no hay `repos/<repo>`
# ni `worktrees/<task>/<repo>` que crear, y `worktree-task.sh` se niega con
# "repo desconocido". Hasta acá esta línea clavaba la ruta del worktree, así que
# toda tarea que tocara docs o specs llegaba al final con el reviewer habiendo
# emitido juicio completo y SIN NINGÚN LUGAR DONDE SELLARLO, y la remediación
# que este script imprimía tampoco existía.
#
# El nombre se compara contra `instance.repo` del answers y no se infiere de
# "no existe el worktree": un repo mal tipeado tiene que seguir dando error, no
# apuntar en silencio a la raíz del workspace.
# El helper es COMPARTIDO (scripts/instance-repo.sh): instance-ship.sh hace la
# misma pregunta, y dos lecturas del mismo campo divergen justo cuando una tarea
# queda sin veredicto. Fail-open: sin el archivo, este script se comporta como
# antes y el repo de la instancia sigue sin camino (no inventa uno).
# shellcheck source=/dev/null
[ -f "$WS/scripts/instance-repo.sh" ] && . "$WS/scripts/instance-repo.sh" \
  || instance_repo_slug() { :; }

WT="$WS/worktrees/$TASK/$REPO"
ES_INSTANCIA=""
if [ ! -d "$WT" ] && [ -n "$(instance_repo_slug)" ] && [ "$REPO" = "$(instance_repo_slug)" ]; then
  WT="$WS"; ES_INSTANCIA=1
fi
[ -d "$WS/tasks/$TASK" ] || { echo "❌ no existe tasks/$TASK (¿typo?)"; exit 1; }
HEAD="$(git -C "$WT" rev-parse HEAD 2>/dev/null)" \
  || { echo "❌ no existe el worktree $WT"; echo "   ↳ remediación: scripts/worktree-task.sh $TASK $REPO"; exit 2; }
[ -n "$ES_INSTANCIA" ] && echo "ℹ️  $REPO es el repo de la INSTANCIA: sello contra su propio árbol ($WS)," \
  && echo "   que es COMPARTIDO entre tareas. El commit revisado es el que manda, no el árbol."

OUT="$WS/tasks/$TASK/verdict-$REPO.json"

# ── Predicado de elegibilidad de un EV, COMPARTIDO ────────────────────
# Lo usan la selección del scaffold y merge_qa: si divergieran, el merge
# aceptaría evidencia que el scaffold rechaza (o al revés) y volvería el
# tercer SHA. Un EV es elegible si es de este task/repo, salió en verde,
# no movió HEAD, y es del commit pedido O del MISMO cambio (patch_id).
#
# LA CONTENCIÓN NO ELIGE: DECLARA. Hasta acá `eligible` exigía además que el
# EV no estuviera marcado con contention.suspect, y esa exclusión salió carísima.
# Caso de campo MEDIDO: una tarea de 5 minutos tardó 3 HORAS y hubo que matarla.
# El agente sellaba evidencia, el scaffold salía exit 3 por contención, y él
# volvía a sellar esperando a que la máquina se calmara. La carga no dependía de
# él, así que el bucle no tenía condición de salida.
#
# Y el gate bloqueaba justo la única clase de resultado que la contención NO
# puede haber falsificado: la elegibilidad exige exit_code 0 ANTES de mirar el
# sello (acá y en evidence.py verify_one/fresh_evidence), o sea que todo EV que
# llega al chequeo de contención YA SALIÓ VERDE. Y la contención produce
# TIMEOUTS, o sea ROJOS, no verdes falsos: el rojo ya lo rechaza exit_code.
#
# Lo que sí queda es un residuo REAL, y por eso el EV entra DECLARADO en
# evidence_under_contention en vez de entrar callado: una suite cuyos guards de
# entorno SALTAN tests cuando un servicio está lento puede salir verde con MENOS
# tests corridos de los que el verde aparenta. Eso es JUICIO del reviewer, y
# para juzgarlo tiene que saberlo. Excluir el EV no lo protegía de ese residuo:
# lo dejaba sin evidencia y sin tarea.
#
# UNA SOLA REGLA DE ELEGIBILIDAD, y los dos diagnósticos de COR-655 conservados
# donde siguen sirviendo. Antes el predicado iba partido en dos (`eligible` y
# `eligible_salvo_contencion`) solo para poder distinguir "suspect" de "otro
# SHA" en el mensaje de error: decirle "es de OTRO commit... el implementer
# movió HEAD" a un EV del commit bueno mandaba a cazar una causa inexistente, y
# a un diagnóstico se le cree. Ese diagnóstico sobrevive, pero se MUEVE al único
# caso en que la contención todavía explica por qué falta un verde: el EV ROJO
# sellado bajo carga (`rojo_bajo_contencion`), donde re-sellar con la máquina
# descargada SÍ puede cambiar el resultado. `bajo_contencion` queda como
# predicado suelto: ya no decide nada, solo se declara.
#
# Y el descarte se CLASIFICA, que era el resto del mismo defecto: un EV podía
# quedar afuera por tres motivos distintos (rojo bajo carga, rojo limpio, otro
# commit) y los tres imprimían "es de OTRO commit... el implementer movió HEAD".
# Al rojo LIMPIO ese mensaje lo mandaba a perseguir un HEAD que nadie movió en
# vez de a leer el log del test que falló. Cada motivo tiene su predicado
# (`rojo_bajo_contencion`, `rojo`, y el resto) y su remediación.
ELIGIBLE_JQ='def de_este_cambio($t; $r; $c; $p):
  type == "object" and .schema == 1 and .task_id == $t and .repo == $r
  and .commit == .commit_after
  and ((.commit == $c) or (($p != "") and ((.patch_id // "") == $p)));
def eligible($t; $r; $c; $p):
  de_este_cambio($t; $r; $c; $p) and .exit_code == 0;
def bajo_contencion: (.contention.suspect // false) == true;
def rojo($t; $r; $c; $p):
  de_este_cambio($t; $r; $c; $p) and .exit_code != 0;
def rojo_bajo_contencion($t; $r; $c; $p):
  rojo($t; $r; $c; $p) and bajo_contencion;'

# ── La contención se DICE, no se esconde en un campo ──────────────────
# Un veredicto que gana un campo que nadie explica se lee como ruido y el
# reviewer lo saltea. El razonamiento va a pantalla completo: por qué el EV
# entra (ya es verde) y qué residuo queda igual (tests SALTADOS por guards de
# entorno). Lo usan el scaffold y merge_qa, para que digan lo mismo.
declara_contencion() {  # declara_contencion <verdict.json>
  local n
  n="$(jq '(.evidence_under_contention // []) | length' "$1" 2>/dev/null || echo 0)"
  [ "${n:-0}" -gt 0 ] || return 0
  echo "⚠️  $n evidencia(s) de este veredicto quedaron selladas bajo CONTENCIÓN:"
  jq -r '(.evidence_under_contention // [])[] | "     - " + .' "$1"
  echo "   NO se excluyen, y el motivo es mecánico: para entrar acá un EV ya pasó"
  echo "   el chequeo de exit_code, o sea que SALIÓ VERDE, y la contención produce"
  echo "   TIMEOUTS (rojos), que ese chequeo ya rechaza. Excluir los verdes dejaba"
  echo "   al agente re-sellando a la espera de una máquina calma, sin condición de"
  echo "   salida: caso de campo, 5 minutos de trabajo que tardaron 3 HORAS."
  echo "   PERO queda un residuo REAL que es JUICIO del reviewer: una suite cuyos"
  echo "   guards de entorno SALTAN tests cuando un servicio está lento sale verde"
  echo "   con MENOS tests corridos de los que el verde aparenta."
  echo "   ↳ el reviewer mira el conteo de tests SALTADOS en el log de esos EV y"
  echo "     dice en su juicio si eso le cambia el veredicto."
}

# ── Un veredicto solo se pisa con algo que SIGUE siendo un veredicto ──
# `jq ... > tmp && mv tmp destino` confía en el exit code de jq, y jq SALE 0
# cuando su programa no produce ninguna salida: el tmp queda en 0 bytes, el mv
# destruye el original y el mensaje de éxito se imprime igual. No es teórico:
# pasó en el camino feliz de /review paso 5.4 y el veredicto (el único artefacto
# que el ship exige) desapareció con exit 0 de punta a punta.
#
# El exit code de jq NO es la post-condición. La post-condición es que lo
# escrito siga siendo un objeto JSON con el commit que sella, y se verifica
# ANTES de pisar nada. Si no lo es, el original queda intacto y esto muere: acá
# fallar es correcto, porque el destino de la alternativa es perder el juicio.
pisa_json() {  # pisa_json <tmp> <destino> <qué se estaba haciendo>
  if [ -s "$1" ] && jq -e 'type == "object" and (.commit // "") != ""' "$1" >/dev/null 2>&1; then
    mv "$1" "$2"
    return 0
  fi
  rm -f "$1"
  echo "❌ $3: el resultado quedó vacío o dejó de ser un veredicto"
  echo "   ↳ el archivo original NO se tocó: $2"
  echo "   ↳ esto es un bug del harness (una transformación que sale 0 y no"
  echo "     produce nada): reportalo con scripts/harness-bug.sh"
  exit 3
}

merge_qa() {
  # Fusión MECANICA de qa-<repo>.json al veredicto. Caso de campo: el paso 3
  # de /review era prosa ("copia qa, evidence y notes si su commit coincide"),
  # nada lo verificaba, y el copy-paste metía al veredicto EVs sellados en un
  # TERCER SHA: el gate de evidencia rebotaba tras pagar lock y suite, 8-9
  # veces en una corrida. La equivalencia NO se declara: se DERIVA de los EV
  # sellados (evidence.py les pone patch_id; un patch_id escrito por el agente
  # QA sería auto-atestación).
  local v="$OUT" q="$WS/tasks/$TASK/qa-$REPO.json"
  [ -f "$v" ] || { echo "❌ no existe $v"
    echo "   ↳ remediación: scripts/verdict-scaffold.sh $TASK $REPO primero"; exit 3; }
  [ -f "$q" ] || { echo "❌ no existe $q: la fase QA no corrió"
    echo "   ↳ remediación: /review paso 1 (agente qa o evidence.py run --runner qa)"; exit 3; }
  jq -e --arg t "$TASK" --arg r "$REPO" '
    ((.task_id // $t) == $t) and ((.repo // $r) == $r)' "$q" >/dev/null \
    || { echo "❌ qa-$REPO.json es de OTRA tarea o repo"; exit 3; }
  local qa_state; qa_state="$(jq -r '.qa // ""' "$q")"
  case "$qa_state" in
    pass|fail) ;;
    *) echo "❌ qa-$REPO.json no declara qa: pass|fail (qa='$qa_state')"
       echo "   ↳ remediación: la fase QA escribe {\"qa\":\"pass|fail\", \"commit\":..., \"evidence\":[...]}"
       exit 3 ;;
  esac

  local vc qc vpid; vc="$(jq -r '.commit // ""' "$v")"; qc="$(jq -r '.commit // ""' "$q")"
  vpid="$(jq -r '.patch_id // ""' "$v")"

  # Cada EV citado por QA pasa el MISMO predicado que la selección del
  # scaffold, contra el commit del veredicto (o su patch_id). Fail-closed:
  # un ID que no pasa NO se descarta en silencio: aborta con la causa.
  local id ev ok_ids="" susp_ids=""
  for id in $(jq -r '.evidence[]? // empty' "$q"); do
    ev="$WS/tasks/$TASK/evidence/$id.json"
    [ -f "$ev" ] || { echo "❌ QA cita $id y no existe el manifiesto"; exit 3; }
    if jq -e --arg t "$TASK" --arg r "$REPO" --arg c "$vc" --arg p "$vpid" \
         "$ELIGIBLE_JQ"' eligible($t; $r; $c; $p)' "$ev" >/dev/null; then
      ok_ids="$ok_ids $id"
      # El sello de contención ya no rechaza: se ARRASTRA al veredicto para que
      # el reviewer lo vea. Rechazarlo mandaba a "re-sella con la máquina
      # descargada", que es una espera sin condición de salida, y protegía de
      # nada: este EV ya pasó exit_code 0, y la contención produce rojos.
      jq -e "$ELIGIBLE_JQ"' bajo_contencion' "$ev" >/dev/null \
        && susp_ids="$susp_ids $id"
    elif jq -e --arg t "$TASK" --arg r "$REPO" --arg c "$vc" --arg p "$vpid" \
           "$ELIGIBLE_JQ"' rojo_bajo_contencion($t; $r; $c; $p)' "$ev" >/dev/null; then
      # Acá la contención SÍ explica el descarte, y es el único lugar donde lo
      # hace: el EV es del commit correcto pero salió ROJO, y un rojo bajo carga
      # puede ser de la máquina (timeouts) y no del cambio. Decirle "es de OTRO
      # cambio" mandaría a re-correr QA sobre un HEAD que ya es el bueno.
      echo "❌ la evidencia de QA $id salió en ROJO y está sellada bajo CONTENCIÓN"
      echo "   ↳ el commit es el correcto y nadie movió HEAD: la máquina estaba cargada"
      echo "     al sellar, y la contención produce TIMEOUTS. Ese rojo puede ser de la"
      echo "     máquina y no de tu cambio: re-sella con la máquina descargada (o"
      echo "     HARNESS_TEST_SLOTS=1) antes de salir a cazar un bug que quizá no existe."
      exit 3
    elif jq -e --arg t "$TASK" --arg r "$REPO" --arg c "$vc" --arg p "$vpid" \
           "$ELIGIBLE_JQ"' rojo($t; $r; $c; $p)' "$ev" >/dev/null; then
      # Mismo descarte mudo que en la selección: el EV es de ESTE cambio y salió
      # rojo sin carga que lo explique. Decirle "es de OTRO cambio" mandaba a
      # re-correr QA sobre el HEAD que ya era el bueno.
      echo "❌ la evidencia de QA $id es de este cambio pero salió en ROJO (exit_code != 0)"
      echo "   ↳ QA no puede fusionar un rojo al veredicto: lee su log, arregla y"
      echo "     re-corre QA (evidence.py run --runner qa ...)"
      exit 3
    else
      echo "❌ la evidencia de QA $id es de OTRO cambio (ni commit ${vc:0:12} ni patch_id del veredicto)"
      echo "   ↳ re-corre QA sobre el HEAD actual (evidence.py run --runner qa ...),"
      echo "     o, si el veredicto es el viejo: scripts/verdict-scaffold.sh --rebase $TASK $REPO"
      echo "   ↳ si es la corrida del ROJO sobre el árbol base (rojo primero), citala en"
      echo "     evidence_baseline[] de qa-$REPO.json: ahí NO se exige igualdad de commit"
      exit 3
    fi
  done

  # ── Evidencia BASELINE: la prueba del rojo primero vive en OTRO commit ──
  # Caso de campo (COR-650): el requirement del rojo primero se demuestra
  # corriendo el test sobre el árbol BASE, y esa corrida se sella por
  # definición en otro SHA y casi siempre en rojo (el rojo ES el punto).
  # Exigirle igualdad de commit y exit 0 la volvía inaceptable siempre, así
  # que el agente QA terminaba inventando campos ad hoc que ningún gate leía.
  # Se acepta si su commit es ANCESTRO del commit revisado: probar el pasado
  # de este cambio es exactamente su trabajo; un commit ajeno no prueba nada.
  local bid bev bcommit base_ids=""
  for bid in $(jq -r '.evidence_baseline[]? // empty' "$q"); do
    bev="$WS/tasks/$TASK/evidence/$bid.json"
    [ -f "$bev" ] || { echo "❌ QA cita $bid como baseline y no existe el manifiesto"; exit 3; }
    jq -e --arg t "$TASK" --arg r "$REPO" --arg id "$bid" '
      type == "object" and .schema == 1 and .task_id == $t and .repo == $r
      and .id == $id and .commit == .commit_after' "$bev" >/dev/null \
      || { echo "❌ el baseline $bid no es un EV sano de esta tarea/repo"; exit 3; }
    bcommit="$(jq -r '.commit // ""' "$bev")"
    # ── EL ANCESTRO ERA UNA REGLA IMPOSIBLE PARA UN TEST NUEVO (#146) ──
    # Las dos reglas del harness se excluían: `evidence.py` se niega a sellar un
    # árbol sucio, así que para MEDIR un test nuevo sobre la base hay que
    # COMMITEARLO sobre la base; y ese commit (`base + test`) nunca es ancestro
    # del revisado (`base + fix`), porque son HERMANOS. O sea que el mecanismo
    # que #53 creó para destrabar el rojo primero no se podía cumplir justo en
    # el caso que #53 quería destrabar.
    #
    # Lo que la regla quiere decir de verdad es "este baseline prueba el PASADO
    # de ESTE cambio", y eso tiene dos formas legítimas, no una:
    #   (a) el baseline ES un punto de la historia del cambio (ancestro), o
    #   (b) el baseline SALE DEL MISMO punto de partida (mismo merge-base con
    #       la trunk) y NO contiene el cambio revisado.
    # Un commit ajeno (otra rama, otro punto de partida, o uno que ya incluye el
    # fix) sigue sin pasar, que es lo único que este chequeo protege.
    baseline_valido() {  # baseline_valido <bcommit> <commit-revisado>
      git -C "$WT" merge-base --is-ancestor "$1" "$2" 2>/dev/null && return 0
      # El baseline no puede CONTENER el cambio revisado: eso ya no es "antes".
      git -C "$WT" merge-base --is-ancestor "$2" "$1" 2>/dev/null && return 1
      local trunk mb_rev mb_base
      trunk="$(git -C "$WT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
      [ -n "$trunk" ] || return 1          # sin trunk no se puede probar (b): fail-closed
      mb_rev="$(git -C "$WT" merge-base "$trunk" "$2" 2>/dev/null)" || return 1
      mb_base="$(git -C "$WT" merge-base "$trunk" "$1" 2>/dev/null)" || return 1
      [ -n "$mb_rev" ] && [ "$mb_rev" = "$mb_base" ]
    }
    baseline_valido "$bcommit" "$vc" || {
      echo "❌ el baseline $bid está sellado sobre ${bcommit:0:12}, que NO es ancestro"
      echo "   del commit revisado (${vc:0:12}) NI sale de su mismo punto de partida"
      echo "   ↳ un baseline prueba el PASADO de este cambio; un commit ajeno no prueba nada"
      echo "   ↳ si es el 'base + el test nuevo' (el rojo primero), commitealo SOBRE el"
      echo "     merge-base de tu rama con la trunk: ahí sí queda como hermano válido"
      exit 3; }
    base_ids="$base_ids $bid"
  done
  if [ "$qc" != "$vc" ] && [ -z "$ok_ids" ]; then
    echo "❌ el QA es del commit ${qc:-?} y el veredicto de ${vc:0:12}: no hay"
    echo "   identidad de contenido sellada que los ligue (QA de agente sin EV)."
    echo "   ↳ re-corre QA sobre el HEAD actual; o --rebase si el veredicto es el viejo."
    exit 3
  fi
  # fusión atómica e idempotente: qa, evidencia elegible (dedup estable), notas.
  # Los campos de JUICIO (verdict, blocking, compliance...) quedan byte a byte.
  local ids_json tmp notes
  ids_json="$(printf '%s\n' $ok_ids | jq -Rnc '[inputs | select(length > 0)]')"
  local base_json susp_json
  base_json="$(printf '%s\n' $base_ids | jq -Rnc '[inputs | select(length > 0)]')"
  susp_json="$(printf '%s\n' $susp_ids | jq -Rnc '[inputs | select(length > 0)]')"
  notes="$(jq -r '.notes // ""' "$q")"
  tmp="$(mktemp "$WS/tasks/$TASK/.verdict-$REPO.XXXXXX")"
  if ! jq -S --arg qa "$qa_state" --argjson ids "$ids_json" \
        --argjson bids "$base_json" --argjson sids "$susp_json" --arg notes "$notes" '
    .qa = $qa
    # SIN notes, el veredicto queda COMO ESTABA, y eso se dice a nivel de
    # pipeline. Acá vivía un data-loss determinista del camino feliz: era
    # `.qa_notes = (if $notes == "" then (.qa_notes // empty) else $notes end)`,
    # y en jq una ASIGNACIÓN con RHS `empty` no borra el campo: mata TODAS las
    # salidas del programa. Con un qa.json sin `notes` (campo opcional que
    # ningún schema exige) y un veredicto sin `.qa_notes` previo (el scaffold no
    # lo crea), el archivo temporal salía en 0 BYTES, jq salía 0, el mv pisaba
    # el veredicto válido y el mensaje de éxito se imprimía igual.
    | (if $notes == "" then . else .qa_notes = $notes end)
    | .evidence = ((.evidence + $ids) | unique)
    | (if ($bids | length) > 0
       then .evidence_baseline = (((.evidence_baseline // []) + $bids) | unique)
       else . end)
    # ADITIVO y con unique: la fusión sigue siendo idempotente a bytes, y el
    # veredicto conserva lo que el scaffold ya había declarado.
    | (if ($sids | length) > 0
       then .evidence_under_contention =
              (((.evidence_under_contention // []) + $sids) | unique)
       else . end)' "$v" > "$tmp"; then
    rm -f "$tmp"
    echo "❌ merge-qa: la fusión falló y el veredicto NO se tocó"
    echo "   ↳ revisá que tasks/$TASK/verdict-$REPO.json sea JSON válido"
    exit 3
  fi
  pisa_json "$tmp" "$v" "merge-qa"
  echo "✅ merge-qa: qa=$qa_state fusionado al veredicto ($(printf '%s' "$ids_json" | jq 'length') EVs de QA)"
  declara_contencion "$v"
}

if [ "$MERGE_QA" -eq 1 ]; then
  merge_qa
  exit 0
fi

# ── La identidad del CAMBIO, no la del commit ─────────────────────────
# El veredicto es un juicio sobre un diff; sellarlo solo contra un SHA hacía
# que cualquier rebase (o sea, cualquier push ajeno al mismo trunk) lo tirara
# entero. `patch_id` deja que harness-policy.py reuse el juicio cuando el
# cambio es el MISMO sobre otra base, y `reviewed_at` acota esa reutilización
# en el tiempo. Fail-open acá a propósito: si no se puede calcular, el
# veredicto sale sin patch_id y el ship exige commit exacto, que es el
# comportamiento viejo. Degradar no puede significar aflojar el gate.
# -f y no -x: el bit de ejecución no sobrevive de forma confiable a un cp, un
# checkout con otro umask ni a un zip, y se invoca con `bash` de todas formas.
# Un guard que depende del modo del archivo degradaría en silencio justo la
# propiedad que evita el re-review.
# Se calcula ANTES de los guards: el chequeo de rebase puro y la selección de
# evidencia (equivalencia por contenido) lo necesitan.
PATCH_ID=""
if [ -f "$WS/scripts/change-id.sh" ]; then
  PATCH_ID="$(bash "$WS/scripts/change-id.sh" "$WT" 2>/dev/null || true)"
fi
[ -n "$PATCH_ID" ] || echo "⚠️  sin patch_id (no pude identificar el cambio): si el trunk se mueve antes del ship, este veredicto caduca y habrá re-review"

PREV_COMMIT=""
if [ -f "$OUT" ]; then
  PREV_COMMIT="$(jq -r '.commit // ""' "$OUT" 2>/dev/null)"
  prev_c="$(printf '%s' "${PREV_COMMIT:-?}" | cut -c1-12)"
  prev_v="$(jq -r '.verdict // "?"' "$OUT" 2>/dev/null)"
  if [ "$REBASE" -eq 1 ]; then
    [ -n "$PREV_COMMIT" ] || {
      echo "❌ el veredicto previo no declara commit: no hay base contra la cual calcular el delta"
      echo "   ↳ remediación: --force (se pierde el juicio, pero es el único camino honesto)"; exit 3; }
    git -C "$WT" cat-file -e "$PREV_COMMIT^{commit}" 2>/dev/null || {
      echo "❌ el commit del veredicto previo ($prev_c) ya no existe en $WT"
      echo "   ↳ se recreó el worktree o se reescribió la historia: sin ese commit no hay"
      echo "     delta que calcular, y arrastrar juicio a ciegas sería un falso verde."
      echo "     Remediación: --force"; exit 3; }
    if [ "$PREV_COMMIT" = "$HEAD" ]; then
      if [ "$RENEW" -ne 1 ]; then
        echo "❌ el veredicto previo ya es de este commit (${HEAD:0:12}): no hay delta que rebasear"
        echo "   ↳ si el implementer aún no commiteó el fix, no hay nada que re-revisar todavía"
        echo "   ↳ si re-sellaste evidencia LIMPIA del mismo commit (la citada quedó suspect),"
        echo "     usa --rebase --renew: re-liga la evidencia y CONSERVA el juicio"
        exit 3
      fi
      # REBIND, no rebase: mismo commit, código byte a byte el que el reviewer
      # ya juzgó. Caso de campo (COR-360): el precheck selló bajo contención,
      # ship rechazó el EV suspect, se re-selló limpio en ventana tranquila...
      # y no había camino de vuelta: --rebase se negaba (sin delta) y --force
      # borraba el juicio. La única salida era pagar un re-review completo de
      # un diff idéntico al ya aprobado. La evidencia caduca por contención
      # igual que caduca por cambio de base; el juicio no.
      REBIND=1
    fi
    # rebase PURO: mismo cambio sobre otra base. El juicio no caduca por esto
    # (validate-ship lo reusa por patch_id); regenerar el scaffold reseteaba
    # verdict a PENDING_REVIEWER y cobraba un reviewer por un movimiento que
    # nadie miró. Se detecta y NO se toca el archivo.
    PREV_PID="$(jq -r '.patch_id // ""' "$OUT" 2>/dev/null)"
    if [ "$RENEW" -ne 1 ] && [ -n "$PATCH_ID" ] && [ "$PATCH_ID" = "$PREV_PID" ]; then
      echo "↻ nada que rebasear: el cambio es el MISMO (patch_id ${PATCH_ID:0:12})."
      echo "  El veredicto de ${PREV_COMMIT:0:12} sigue vigente; ship lo reusa por"
      echo "  patch_id y sella la prueba fresca sobre el HEAD nuevo él solo."
      if [ "$(jq -r '.verdict // ""' "$OUT")" = "pass" ]; then
        echo "  → siguiente: scripts/ship.sh $TASK $REPO (NO corras review ni QA)"
      else
        echo "  → el veredicto previo no es pass y no hay fix commiteado: commitea"
        echo "    el fix primero (eso cambia el patch_id) y re-corre --rebase"
      fi
      echo "  → si policy rechazó el reuso por ventana (24h/200 commits), el"
      echo "    re-review SÍ toca: scripts/verdict-scaffold.sh --rebase --renew $TASK $REPO"
      exit 0
    fi
  elif [ "$FORCE" -ne 1 ]; then
    echo "❌ ya existe $OUT (commit $prev_c, verdict $prev_v)"
    echo "   ↳ --rebase: re-review INCREMENTAL, conserva el juicio que el delta no tocó"
    echo "   ↳ --force:  re-scaffold desde cero (el juicio previo se pierde)"
    exit 3
  else
    echo "⚠️  sobreescribo veredicto previo: commit=$prev_c verdict=$prev_v"
  fi
elif [ "$REBASE" -eq 1 ]; then
  echo "❌ no existe $OUT: no hay veredicto previo que rebasear"
  echo "   ↳ remediación: corre el scaffold normal primero (sin flags)"
  exit 3
fi

# ── Selección de evidencia: mismos criterios estructurales que verify_one ──
# Con el predicado COMPARTIDO: un EV del mismo cambio sobre otro SHA (rebase
# de por medio) es elegible, igual que en evidence.py verify. Eso evita
# re-sellar la suite cuando el EV del implementer sigue probando este diff.
rows=""
stale=0
suspect=0
rojo=0
for f in "$WS/tasks/$TASK/evidence"/EV-*.json; do
  [ -e "$f" ] || continue
  line="$(jq -r --arg t "$TASK" --arg r "$REPO" --arg c "$HEAD" --arg p "$PATCH_ID" \
    "$ELIGIBLE_JQ"'
    select(type == "object" and .schema == 1 and .task_id == $t and .repo == $r)
    | if eligible($t; $r; $c; $p)
      # El cuarto campo viaja para que el veredicto pueda DECLARAR cuáles de
      # los EV que cita se sellaron bajo carga. Vacío cuando no lo estuvieron.
      then [.id, (.runner // ""), (.kind // ""),
            (if bajo_contencion then "suspect" else "" end)] | join("|")
      elif rojo_bajo_contencion($t; $r; $c; $p) then "SUSPECT"
      elif rojo($t; $r; $c; $p) then "ROJO"
      else "STALE" end
  ' "$f" 2>/dev/null || true)"
  case "$line" in
    "") ;;
    SUSPECT) suspect=$((suspect+1)) ;;
    ROJO) rojo=$((rojo+1)) ;;
    STALE) stale=$((stale+1)) ;;
    *)
      id="${line%%|*}"
      [ "$id" = "$(basename "$f" .json)" ] || continue   # id falsificado: fuera
      rows="$rows$line
"
      ;;
  esac
done
rows="$(printf '%s' "$rows" | sort)"   # orden estable ⇒ scaffold idempotente a bytes

if [ -z "$rows" ] && [ "$ALLOW_EMPTY" -ne 1 ]; then
  if [ "$suspect" -gt 0 ]; then
    # El diagnóstico de COR-655, conservado en el ÚNICO caso donde la contención
    # sigue explicando la falta de evidencia: estos EV son del commit CORRECTO
    # pero salieron en ROJO bajo carga. Decir "de OTRO commit" mandaba a cazar un
    # HEAD movido que nadie había movido. Y acá re-sellar SÍ puede cambiar el
    # resultado, al revés que con un verde: la contención produce timeouts.
    echo "❌ hay $suspect evidencia(s) de $REPO@${HEAD:0:12} en ROJO y selladas bajo CONTENCIÓN"
    echo "   ↳ el commit es el correcto y nadie movió HEAD: la máquina estaba cargada"
    echo "     al sellar, y la contención produce TIMEOUTS. Ese rojo puede ser de la"
    echo "     máquina y no de tu cambio: re-sella con la máquina descargada (o"
    echo "     HARNESS_TEST_SLOTS=1) antes de salir a cazar un bug que quizá no existe:"
    [ "$stale" -gt 0 ] && echo "   (además hay $stale de otro commit)"
  elif [ "$rojo" -gt 0 ]; then
    # El tercer descarte, y el que quedaba mudo: EV del commit CORRECTO, sin
    # sello de contención, y en ROJO. Caía en la rama STALE y se lo acusaba de
    # "otro commit", así que el agente salía a cazar un HEAD movido que nadie
    # había movido, en vez de leer el log del test que falló. Acá no hay nada
    # que re-sellar: el veredicto no puede citar un rojo, y el rojo es del
    # cambio. A un diagnóstico se le cree, así que tiene que ser el correcto.
    echo "❌ hay $rojo evidencia(s) de $REPO@${HEAD:0:12} en ROJO (exit_code != 0)"
    echo "   ↳ el commit es el correcto y la máquina no estaba cargada: los tests"
    echo "     FALLARON. No hay HEAD que perseguir ni sello que renovar: lee el log"
    echo "     del EV (tasks/$TASK/evidence/), arregla el cambio y re-sella:"
    [ "$stale" -gt 0 ] && echo "   (además hay $stale de otro commit)"
  elif [ "$stale" -gt 0 ]; then
    echo "❌ hay $stale evidencia(s) de $REPO pero de OTRO commit (HEAD actual: ${HEAD:0:12})"
    echo "   ↳ el implementer movió HEAD después de generarlas: re-corre la evidencia sobre el HEAD actual:"
  else
    echo "❌ cero evidencias de $REPO@${HEAD:0:12} en tasks/$TASK/evidence/"
    echo "   ↳ primero genera evidencia real:"
  fi
  echo "     python3 scripts/evidence.py run --task-dir tasks/$TASK --repo $REPO \\"
  echo "       --runner <implementer> --kind test --cwd worktrees/$TASK/$REPO -- <comando de test>"
  exit 3
fi

# ── LA IDENTIDAD DEL DELTA-SPEC QUE ESTE VEREDICTO MIRA ───────────────
# POLICY-ARCHIVE-001 impide que /archive fusione a las specs maestras un delta
# que ningún reviewer vio, y lo hacía comparando MTIMES. Esa señal la derrota el
# propio flujo: fundir el campo `qa` en el veredicto es un paso PRESCRITO por
# /review, o sea una escritura sobre el veredicto POSTERIOR al juicio, en TODA
# tarea. Caso de campo, 17 segundos de ventana: delta-spec.md editado a las
# 23:20:26, verdict-<repo>.json refundido a las 23:20:43, gate en verde, y el
# reviewer había cerrado antes del texto nuevo.
# Un hash del contenido no lo mueve ninguna escritura mecánica, y además
# sobrevive a un `git checkout`, que también resetea mtimes.
DELTA_SPEC="$WS/tasks/$TASK/delta-spec.md"
DELTA_SHA=""
if [ -f "$DELTA_SPEC" ]; then
  if command -v shasum >/dev/null 2>&1; then
    DELTA_SHA="$(shasum -a 256 "$DELTA_SPEC" 2>/dev/null | awk '{print $1}')"
  else
    DELTA_SHA="$(sha256sum "$DELTA_SPEC" 2>/dev/null | awk '{print $1}')"
  fi
fi

tmp="$(mktemp "$WS/tasks/$TASK/.verdict-$REPO.XXXXXX")"
printf '%s\n' "$rows" | jq -RnS --arg task "$TASK" --arg repo "$REPO" \
    --arg commit "$HEAD" --arg reviewer "$REVIEWER" \
    --arg delta_sha "$DELTA_SHA" \
    --arg patch_id "$PATCH_ID" --arg reviewed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  [inputs | select(length > 0) | split("|")] as $rows
  | { schema: 1, task_id: $task, repo: $repo, commit: $commit,
      patch_id: $patch_id, reviewed_at: $reviewed_at,
      delta_spec_sha256: $delta_sha,
      reviewer: $reviewer,
      implementation_agents:
        ($rows | map(.[1])
         | map(select(. != "" and . != $reviewer and . != "qa" and . != "ship"))
         | unique),
      evidence: ($rows | map(.[0])),
      evidence_under_contention: ($rows | map(select(.[3] == "suspect") | .[0])),
      verdict: "PENDING_REVIEWER",
      qa: "pending",
      blocking: [], non_blocking: [],
      docs_updated: false,
      compliance: [],
      requirements_uncovered: -1,
      snapshots_updated_justified: false }
  # ADITIVO: sin EV bajo contención el campo NO existe, igual que known_bug. Un
  # campo vacío en cada veredicto entrena a saltearlo justo cuando aparezca.
  | (if (.evidence_under_contention | length) == 0
     then del(.evidence_under_contention) else . end)
  # Sin delta-spec no hay identidad que sellar, y un campo vacío haría creer a
  # policy que este veredicto declara un delta (el vacío no matchea nada).
  | (if .delta_spec_sha256 == "" then del(.delta_spec_sha256) else . end)' > "$tmp"

# ── Arrastre del juicio (--rebase) ────────────────────────────────────
# Se conserva compliance[], non_blocking[] y los flags del reviewer. NO se
# conserva verdict ni blocking: el veredicto se re-emite siempre y los blocking
# están justamente siendo corregidos. requirements_uncovered sigue en -1: el
# reviewer lo re-declara.
#
# QA es el caso especial, y hasta acá el mecanismo contradecía al prompt:
# /review promete "QA solo se repite si el fix tocó comportamiento que QA
# ejercita", y este script mandaba qa:"pending" SIEMPRE. Como check_verdict
# bloquea con qa != pass, la promesa era incumplible y cada ronda de rework
# pagaba un ciclo de QA entero, aunque el fix fuera un nil check.
#
# Se mecaniza con una DECLARACIÓN, no con una adivinanza: qa-<repo>.json puede
# traer `surface: ["ruta", ...]` con lo que ejercita. Si el delta no toca nada
# de esa superficie, el pass se arrastra marcado. Sin `surface` no se arrastra
# nada: fail-closed, igual que antes.
if [ "$REBASE" -eq 1 ] && [ "$REBIND" -eq 1 ]; then
  # REBIND: el commit no se movió, así que no hay delta que juzgar. Lo único
  # que cambia es QUÉ evidencia cita el veredicto. Se conserva TODO el juicio
  # (verdict, blocking, compliance, qa, requirements_uncovered, reviewed_at y
  # patch_id) y se reemplaza solo la lista de evidencia por la recién elegida,
  # junto con la declaración de contención que le corresponde.
  # reviewed_at NO se refresca a propósito: la ventana de vigencia que mide
  # policy es la del JUICIO, y el juicio es el mismo de antes.
  # Sin delta POR DEFINICION: el commit no se movió. Se declara igual porque
  # los dos bloques de abajo (el delta que viaja al reviewer y su persistencia)
  # cuelgan de $REBASE, y bajo set -u una variable sin declarar mata el script
  # justo después de haber re-ligado bien el veredicto.
  changed='[]'
  reb="$(mktemp "$WS/tasks/$TASK/.rebind-$REPO.XXXXXX")"
  jq -nS --slurpfile fresh "$tmp" --slurpfile prev "$OUT" '
    $prev[0] + {
      evidence: $fresh[0].evidence,
      implementation_agents:
        ((($prev[0].implementation_agents // []) + ($fresh[0].implementation_agents // []))
         | unique),
      rebound_at: $fresh[0].reviewed_at }
    # La declaración de contención se RECALCULA de la evidencia recién elegida,
    # no se hereda: el rebind cambia justamente QUÉ se cita, así que heredarla
    # dejaría el campo mintiendo en los dos sentidos (declarando un EV que ya no
    # está, o callando uno nuevo). Sería la puerta de atrás por donde la
    # contención vuelve a entrar sin decirlo.
    | (if (($fresh[0].evidence_under_contention // []) | length) > 0
       then .evidence_under_contention = $fresh[0].evidence_under_contention
       else del(.evidence_under_contention) end)' > "$reb" 2>/dev/null && [ -s "$reb" ] || {
      rm -f "$reb" "$tmp"
      echo "❌ no pude re-ligar el veredicto previo (¿archivo corrupto?)"
      echo "   ↳ remediación: --force (el juicio se pierde: toca re-review)"; exit 3; }
  mv "$reb" "$tmp"
  echo "↻ rebind sobre ${HEAD:0:12}: $(jq '.evidence | length' "$tmp") EV re-ligados,"
  echo "  juicio CONSERVADO (verdict=$(jq -r '.verdict' "$tmp"))"
elif [ "$REBASE" -eq 1 ]; then
  changed="$(git -C "$WT" diff --name-only "$PREV_COMMIT" "$HEAD" 2>/dev/null \
    | jq -Rsc 'split("\n") | map(select(length > 0))')"
  [ -n "$changed" ] || changed='[]'
  reb="$(mktemp "$WS/tasks/$TASK/.rebase-$REPO.XXXXXX")"
  # El matcheo de rutas es DELIBERADAMENTE generoso: git diff da rutas
  # relativas al repo, y compliance puede citar rutas relativas al workspace
  # o al worktree (ship.sh busca en los dos). Se compara por sufijo en ambos
  # sentidos y por basename. Un match de más solo pide una re-lectura; uno de
  # menos arrastraría un covered:true que ya no se sostiene.
  jq -nS --slurpfile fresh "$tmp" --slurpfile prev "$OUT" \
     --arg prevc "$PREV_COMMIT" --argjson changed "$changed" '
    def norm: sub("::.*$"; "") | sub("#[A-Za-z_][A-Za-z0-9_]*$"; "")
              | sub(":[0-9]+(-[0-9]+)?$"; "");
    def arts: [ if (.tests? | type) == "array" then .tests[]
                else (.evidence_path // .test // empty) end ]
              | map(norm) | map(select(length > 0));
    def touched($cs): (arts) as $a
      | if ($a | length) == 0 then true
        else ($a | any(. as $x | ($cs | any(. as $c
               | ($x | endswith($c)) or ($c | endswith($x))
               or (($x | split("/") | last) == ($c | split("/") | last))))))
        end;
    $fresh[0] + {
      # QUIEN IMPLEMENTO NO CAMBIA PORQUE SE MOVIO LA BASE. Este campo se deriva
      # de los runners de la evidencia, y tras un intento de ship la unica
      # evidencia en el HEAD nuevo suele ser la de `ship`, que esta excluida a
      # proposito (un verificador no puede figurar como implementador). Sin
      # arrastrarlo, el campo quedaba VACIO y el scaffold se negaba por politica
      # de roles: un callejon sin salida en cada ronda de rework posterior a un
      # ship. Se unen los de antes con los frescos que si sean de implementacion.
      implementation_agents:
        ((($prev[0].implementation_agents // []) + $fresh[0].implementation_agents)
         | unique),
      compliance: (($prev[0].compliance // []) | map(
        . + {carried_from: $prevc}
          + (if touched($changed)
             then {covered: false,
                   rejudge: "el delta tocó el artefacto citado (o la entrada no cita ninguno)"}
             else {} end))),
      non_blocking: ($prev[0].non_blocking // []),
      docs_updated: ($prev[0].docs_updated // false),
      snapshots_updated_justified: ($prev[0].snapshots_updated_justified // false),
      rebased_from: $prevc,
      delta_files: $changed
    }' > "$reb" 2>/dev/null && [ -s "$reb" ] || {
      rm -f "$reb" "$tmp"
      echo "❌ no pude rebasear el juicio previo (¿veredicto corrupto?)"
      echo "   ↳ remediación: --force"; exit 3; }
  mv "$reb" "$tmp"

  # QA: se arrastra el pass SOLO si su superficie declarada quedó fuera del delta.
  QA_FILE="$WS/tasks/$TASK/qa-$REPO.json"
  if [ -f "$QA_FILE" ] && [ "$(jq -r '.qa // ""' "$QA_FILE" 2>/dev/null)" = "pass" ]; then
    qa_prev_commit="$(jq -r '.commit // ""' "$QA_FILE" 2>/dev/null)"
    if [ "$qa_prev_commit" != "$PREV_COMMIT" ]; then
      echo "  qa: NO se arrastra (el qa-$REPO.json es del commit ${qa_prev_commit:0:12}, no del veredicto previo)"
    elif ! jq -e '(.surface | type) == "array" and (.surface | length) > 0' "$QA_FILE" >/dev/null 2>&1; then
      echo "  qa: NO se arrastra (qa-$REPO.json no declara surface[]); QA se re-corre"
      echo "     ↳ para permitir el arrastre, QA declara qué ejercita:"
      echo '       {"qa":"pass", ..., "surface":["internal/http/","web/src/checkout/"]}'
    else
      qa_touched="$(jq -n --slurpfile qa "$QA_FILE" --argjson changed "$changed" '
        ($qa[0].surface // []) as $s
        | [ $changed[] | . as $c
            | select($s | any(. as $x
                | ($c | startswith($x)) or ($c | endswith($x))
                or (($c | split("/") | last) == ($x | split("/") | last)))) ]' )"
      if [ "$(printf '%s' "$qa_touched" | jq 'length')" -eq 0 ]; then
        jq --arg from "$PREV_COMMIT" \
           '.qa = "pass" | .qa_carried_from = $from
            | .evidence_qa_stale = true' "$tmp" > "$tmp.qa"
        pisa_json "$tmp.qa" "$tmp" "arrastre del qa"
        echo "  qa: pass ARRASTRADO desde ${PREV_COMMIT:0:12} (el delta no tocó su surface declarada)"
      else
        echo "  qa: se re-corre — el delta tocó su superficie: $(printf '%s' "$qa_touched" | jq -r 'join(", ")')"
      fi
    fi
  fi

  carried="$(jq '[.compliance[] | select(.rejudge | not)] | length' "$tmp")"
  rejudge="$(jq '[.compliance[] | select(.rejudge)] | length' "$tmp")"
  echo "↻ rebase desde ${PREV_COMMIT:0:12}: $(printf '%s' "$changed" | jq 'length') archivos en el delta"
  echo "  compliance: $carried arrastrada(s), $rejudge a re-juzgar"
fi

# ── El ÁRBOL CLAVADO que el reviewer juzga ────────────────────────────
# Caso de campo (P1): el reviewer leía el worktree VIVO mientras el implementer,
# que es el dueño del claim, seguía editándolo sin commitear. El veredicto sella
# el commit X y el juicio se emitió sobre X MÁS ediciones transitorias: un verde
# que nadie puede reproducir y que ship valida contra otra cosa.
#
# Al sellar se clava un checkout DESACOPLADO del commit sellado en
# worktrees/<task>/.review-<repo>. Detached y sin rama a propósito: no puede
# esconder trabajo sin publicar, así que --rm lo borra sin drama. Y va BAJO
# worktrees/<task>/ también a propósito: track-read.sh deriva la tarea de la
# RUTA (worktrees/<task>/...), así que las lecturas del reviewer ahí adentro se
# atribuyen solas a esta tarea y gate_evidence las ve.
#
# NO ES UN GATE. Si git worktree falla (repo raro, disco, metadata rota que no
# se deja podar), el veredicto sale IGUAL y el scaffold lo DICE, dejando el
# supuesto en el bus. Morir acá sería un falso rojo: el pin es protección extra,
# no la prueba.
PIN="$WS/worktrees/$TASK/.review-$REPO"
PIN_WHY=""
one_line() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-160; }
pin_review_tree() {  # pin_review_tree <commit> → 0 clavado; 1 no, con el motivo en PIN_WHY
  local commit="$1" out=""
  PIN_WHY=""
  # Camino rápido: si el pin de la ronda anterior sigue sano, re-clavarlo es
  # mover su HEAD desacoplado, no volver a copiar el árbol entero.
  if [ -e "$PIN/.git" ]; then
    if out="$(git -C "$PIN" checkout --detach --force "$commit" 2>&1)"; then
      return 0
    fi
    PIN_WHY="re-clavado in situ: $(one_line "$out")"
  fi
  # Pin roto: el dir borrado a mano con la metadata viva (git se niega a
  # re-crearlo: "missing but already registered"), o el dir ocupado por algo que
  # no es un worktree (ahí `worktree remove` dice "is not a working tree" y hace
  # falta el rm). Se desarma entero y se rehace. Ningún motivo se tira: si el
  # rehacer tampoco funciona, todos viajan al mensaje.
  if ! out="$(git -C "$WT" worktree remove --force "$PIN" 2>&1)"; then
    PIN_WHY="$PIN_WHY${PIN_WHY:+; }remove: $(one_line "$out")"
  fi
  if [ -e "$PIN" ] && ! out="$(rm -rf "$PIN" 2>&1)"; then
    PIN_WHY="$PIN_WHY${PIN_WHY:+; }rm -rf: $(one_line "$out")"
  fi
  if ! out="$(git -C "$WT" worktree prune 2>&1)"; then
    PIN_WHY="$PIN_WHY${PIN_WHY:+; }prune: $(one_line "$out")"
  fi
  if out="$(git -C "$WT" worktree add --detach "$PIN" "$commit" 2>&1)"; then
    PIN_WHY=""
    return 0
  fi
  PIN_WHY="$PIN_WHY${PIN_WHY:+; }add: $(one_line "$out")"
  return 1
}

# ── El pin se VERIFICA donde se USA, no se cree su código de retorno ──
# CASO DE CAMPO MEDIDO: dos veredictos sellados sin `.review-<repo>` y sin UNA
# sola señal, ni warning en stdout ni evento assumption en el bus. El reviewer
# de uno entró al pin 43 segundos después, no lo encontró, y se armó un worktree
# descartable en /tmp por su cuenta. Esporádico (2 de ~130 sellos recientes, en
# repos y días distintos) y NO reproducible: el camino feliz de pin_review_tree
# es correcto, corrido dos veces contra repos de juguete.
#
# Por eso el arreglo no persigue la causa: la vuelve irrelevante. `git worktree
# add` saliendo 0 no es la afirmación que importa; la afirmación que importa es
# que EXISTE un árbol usable, en el commit sellado, cuando el reviewer va a
# leerlo. Cualquier cosa que se lleve el pin entremedio (concurrencia sobre el
# mismo repo, un prune ajeno, la limpieza de otro agente) cae en el mismo camino
# que ya existía: warning y supuesto en el bus. Sigue sin ser un gate.
pin_clavado() {  # pin_clavado <commit> → 0 si el pin existe, es worktree y sella
  local head_pin top fisica logica
  [ -d "$PIN" ] || { PIN_WHY="el directorio no quedó después de clavarlo"; return 1; }
  if ! head_pin="$(git -C "$PIN" rev-parse HEAD 2>&1)"; then
    PIN_WHY="el directorio quedó pero git no lo reconoce: $(one_line "$head_pin")"
    return 1
  fi
  # Que `rev-parse` funcione no alcanza: desde un directorio suelto, git sube
  # hasta el repo que lo contenga y contestaría por OTRO árbol. La raíz tiene
  # que ser el pin mismo. Las dos formas de la ruta (física y lógica) valen: en
  # macOS /var es symlink de /private/var y comparar una sola daría un falso
  # negativo que inventaría un supuesto inexistente.
  top="$(git -C "$PIN" rev-parse --show-toplevel 2>/dev/null)"
  fisica="$(cd "$PIN" 2>/dev/null && pwd -P)"
  logica="$(cd "$PIN" 2>/dev/null && pwd)"
  if [ -z "$top" ] || { [ "$top" != "$fisica" ] && [ "$top" != "$logica" ]; }; then
    PIN_WHY="$PIN no es la raíz de un worktree (git resolvió '${top:-nada}')"
    return 1
  fi
  [ "$head_pin" = "$1" ] || {
    PIN_WHY="quedó en ${head_pin:0:12} y el veredicto sella ${1:0:12}"
    return 1; }
  return 0
}

# ── El loop nativo del reviewer no le pisa el del QA ──────────────────
# El go.work de la tarea es UNO SOLO y no puede nombrar el pin: el árbol clavado
# tiene los MISMOS module-paths que el worktree vivo y go.work prohíbe el módulo
# repetido, así que gowork.sh poda los .review-*. Consecuencia medida en campo:
# cualquier `go` corrido dentro del pin muere con "directory prefix does not
# contain modules", y la remediación natural (`go work use .`, o regenerar el
# go.work parado ahí) REESCRIBE el archivo que el QA está usando sobre el árbol
# vivo. El resultado fue un rojo por una razón que no era el código, o sea el
# peor modo de fallo del pipeline: un falso negativo que dispara una ronda de
# review inexistente, o peor, evidencia sellada sobre un árbol que no es el del
# veredicto. Y no es un caso raro: reviewer y QA se lanzan en PARALELO por
# diseño, así que la carrera es la norma en cualquier tarea de un repo Go.
# El pin se lleva su PROPIO go.work: `go` lo encuentra subiendo desde el cwd
# antes que el de la tarea, y los dos árboles dejan de compartir archivo.
# NO ES UN GATE, igual que el pin: sin gowork.sh o sin módulos Go, silencio.
pin_gowork() {
  local out=""
  [ -f "$WS/scripts/gowork.sh" ] || return 0
  if ! out="$(bash "$WS/scripts/gowork.sh" "$TASK" "$REPO" 2>&1)"; then
    echo "⚠️  no pude generar el go.work del árbol clavado: $(one_line "$out")"
    echo "   ↳ si el reviewer corre Go ahí adentro, que lo regenere él:"
    echo "     bash scripts/gowork.sh $TASK $REPO"
    return 0
  fi
  case "$out" in *"sin módulos Go"*) return 0 ;; esac   # repo sin Go: nada que aislar
  echo "📐 el pin tiene su PROPIO go.work: el loop nativo del reviewer y el del QA"
  echo "   dejan de compartir archivo (antes, el segundo en correr le pisaba el"
  echo "   'use' al primero y el build salía rojo por una razón que no era el código)."
  echo "   Queda sin trackear dentro del pin, y el pin es desechable por diseño."
}

# Detección temprana de violación de roles: si TODA la evidencia la corrió
# qa o el propio reviewer, ship morirá en POLICY-ROLE-002/003. Mejor aquí.
if [ "$(jq '.implementation_agents | length' "$tmp")" -eq 0 ] && [ "$ALLOW_EMPTY" -ne 1 ]; then
  runners="$(printf '%s\n' "$rows" | cut -d'|' -f2 | sort -u | tr '\n' ' ')"
  rm -f "$tmp"
  echo "❌ ningún runner de IMPLEMENTACIÓN en la evidencia (runners: ${runners:-ninguno})"
  echo "   ↳ la evidencia del implementer corre con --runner <su identidad>;"
  echo "     el reviewer y qa no pueden ser los implementadores (política de roles)"
  exit 3
fi
jq -e '.evidence | map(select(startswith("EV-TEST-"))) | length > 0' "$tmp" >/dev/null 2>&1 \
  || echo "⚠️  sin evidencia kind=test todavía: evidence.py verify --require-kind test fallará en ship si nadie la aporta"

# ── Una condición DECLARADA no se pierde entre el precheck y el juicio ──
# Si el precheck se selló con un slot rojo declarado como bug conocido del
# harness (HARNESS_KNOWN_BUG), el veredicto tiene que heredarlo. Si no, el
# reviewer juzga un verde que no es verde: hay un tramo del harness que no
# verificó nada y nadie se lo dijo. Aditivo y fail-open: sin el campo, todo
# queda exactamente como estaba.
kb="$(jq -c '.known_bug // empty' "$WS/tasks/$TASK/precheck-$REPO.json" 2>/dev/null || true)"
if [ -n "$kb" ]; then
  if jq --argjson kb "$kb" '.known_bug = $kb' "$tmp" > "$tmp.kb" 2>/dev/null && [ -s "$tmp.kb" ]; then
    mv "$tmp.kb" "$tmp"
    echo "⚠️  este veredicto HEREDA una condición declarada: un slot quedó rojo por"
    echo "   un bug conocido del harness ($(printf '%s' "$kb" | jq -r '.url // "?"'))."
    echo "   El reviewer tiene que NOMBRARLA en su juicio: este verde carga un tramo"
    echo "   que el harness no pudo verificar."
  else
    rm -f "$tmp.kb"
  fi
fi

pisa_json "$tmp" "$OUT" "scaffold"
echo "✅ scaffold: tasks/$TASK/verdict-$REPO.json ($(jq '.evidence|length' "$OUT") evidencias, agents=$(jq -c '.implementation_agents' "$OUT"), commit ${HEAD:0:12})"
declara_contencion "$OUT"

# El árbol clavado va DESPUÉS del sello: si el scaffold se negó (evidencia
# stale, roles, juicio incorrupto), no queda un pin apuntando a un commit que
# ningún veredicto sella.
REVIEW_DIR="worktrees/$TASK/$REPO"
if pin_review_tree "$HEAD" && pin_clavado "$HEAD"; then
  REVIEW_DIR="worktrees/$TASK/.review-$REPO"
  echo "📌 árbol clavado al commit sellado: $REVIEW_DIR (${HEAD:0:12}, detached)"
  echo "   el reviewer LEE y difea AHÍ, no en el worktree vivo: el vivo es del"
  echo "   implementer y puede seguir moviéndose mientras se emite el juicio."
  pin_gowork
else
  echo "⚠️  no pude clavar el árbol de review en worktrees/$TASK/.review-$REPO: $PIN_WHY"
  echo "   el veredicto SALE IGUAL (el pin es protección extra, no un gate:"
  echo "   morir acá sería un falso rojo), pero queda un SUPUESTO abierto: el"
  echo "   reviewer leerá el worktree VIVO, así que su juicio puede incluir"
  echo "   ediciones sin commitear que este veredicto no sella."
  echo "   ↳ remediación: git -C worktrees/$TASK/$REPO worktree prune y re-corre el scaffold"
  if [ -f "$WS/scripts/emit.sh" ]; then
    ( export WS ACTOR="verdict-scaffold"
      bash "$WS/scripts/emit.sh" assumption \
        "sin árbol clavado para el review de $REPO@${HEAD:0:12}: el reviewer lee el worktree vivo ($PIN_WHY)" \
        "" "$TASK" )
  fi
fi

# El delta viaja al reviewer, no se re-deriva (caso de campo: el reviewer
# quemaba su presupuesto reconstruyendo qué cambió cuando este script ya lo
# sabía). Corre en el árbol CLAVADO, que tiene los dos commits y no se mueve
# bajo sus pies. SHAs completos y rutas @sh; queda persistido en .delta_files.
if [ "$REBASE" -eq 1 ]; then
  nfiles="$(printf '%s' "$changed" | jq 'length')"
  if [ "$nfiles" -gt 0 ] && [ "$nfiles" -le 50 ]; then
    echo "→ delta para el reviewer (pégalo VERBATIM en su mensaje):"
    echo "  git -C $REVIEW_DIR diff $PREV_COMMIT..$HEAD -- $(printf '%s' "$changed" | jq -r 'map(@sh) | join(" ")')"
  elif [ "$nfiles" -gt 50 ]; then
    echo "→ delta para el reviewer: git -C $REVIEW_DIR diff $PREV_COMMIT..$HEAD  ($nfiles archivos; lista completa en delta_files)"
  fi
fi
[ "$REBASE" -eq 1 ] && [ "$REBIND" -ne 1 ] \
  && echo "→ re-review INCREMENTAL: juzga solo las entradas con .rejudge; el resto trae carried_from."
echo "→ el reviewer reemplaza SOLO el juicio: verdict, blocking, non_blocking,"
echo "  compliance, requirements_uncovered, docs_updated, snapshots_updated_justified."
echo "  El campo qa lo fusiona /review desde qa-$REPO.json."
