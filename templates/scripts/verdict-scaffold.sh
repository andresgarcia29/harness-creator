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
WT="$WS/worktrees/$TASK/$REPO"
[ -d "$WS/tasks/$TASK" ] || { echo "❌ no existe tasks/$TASK (¿typo?)"; exit 1; }
HEAD="$(git -C "$WT" rev-parse HEAD 2>/dev/null)" \
  || { echo "❌ no existe el worktree $WT"; echo "   ↳ remediación: scripts/worktree-task.sh $TASK $REPO"; exit 2; }

OUT="$WS/tasks/$TASK/verdict-$REPO.json"

# ── Predicado de elegibilidad de un EV, COMPARTIDO ────────────────────
# Lo usan la selección del scaffold y merge_qa: si divergieran, el merge
# aceptaría evidencia que el scaffold rechaza (o al revés) y volvería el
# tercer SHA. Un EV es elegible si es de este task/repo, salió en verde,
# no movió HEAD, y es del commit pedido O del MISMO cambio (patch_id).
#
# Y NO está marcado por contención. Esa condición no es un capricho: es la
# única forma de que la remediación del ship sea alcanzable. gate_preflight
# rechaza el veredicto que cite un EV con contention.suspect, y manda a
# re-sellar con menos carga; pero si el scaffold vuelve a elegir el
# contaminado, el sello nuevo no sirve de nada: --rebase se niega porque el
# commit no se movió, y --force re-incluye el sucio junto al limpio (y encima
# tira el juicio que el reviewer ya había escrito). Caso de campo: una tarea
# quedó trabada con el veredicto ya en pass, con EV-TEST-01066c3b5ea5 (suspect)
# y EV-TEST-29565073a05f (mismo comando, mismo commit, limpio) conviviendo.
# Un sello que el propio harness declara no probatorio no puede entrar al
# veredicto: si el resultado es cero evidencia, eso es exactamente lo que
# --allow-empty existe para decidir, y lo decide un humano.
#
# El predicado va PARTIDO en dos a propósito. Caso de campo (COR-655): un EV
# del commit CORRECTO pero excluido por contención caía en el mismo saco que
# uno de otro SHA, y el mensaje decía "es de OTRO commit... el implementer
# movió HEAD". Las dos frases eran falsas y mandaban a cazar una causa
# inexistente: el commit era el bueno y nadie había movido nada. Un
# diagnóstico equivocado cuesta más que ninguno, porque se le cree.
ELIGIBLE_JQ='def eligible_salvo_contencion($t; $r; $c; $p):
  type == "object" and .schema == 1 and .task_id == $t and .repo == $r
  and .exit_code == 0 and .commit == .commit_after
  and ((.commit == $c) or (($p != "") and ((.patch_id // "") == $p)));
def eligible($t; $r; $c; $p):
  eligible_salvo_contencion($t; $r; $c; $p)
  and ((.contention.suspect // false) != true);'

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
  local id ev ok_ids=""
  for id in $(jq -r '.evidence[]? // empty' "$q"); do
    ev="$WS/tasks/$TASK/evidence/$id.json"
    [ -f "$ev" ] || { echo "❌ QA cita $id y no existe el manifiesto"; exit 3; }
    if jq -e --arg t "$TASK" --arg r "$REPO" --arg c "$vc" --arg p "$vpid" \
         "$ELIGIBLE_JQ"' eligible($t; $r; $c; $p)' "$ev" >/dev/null; then
      ok_ids="$ok_ids $id"
    elif jq -e --arg t "$TASK" --arg r "$REPO" --arg c "$vc" --arg p "$vpid" \
           "$ELIGIBLE_JQ"' eligible_salvo_contencion($t; $r; $c; $p)' "$ev" >/dev/null; then
      # El commit es el CORRECTO: lo único que lo descalifica es el sello de
      # contención. Decirle "es de OTRO cambio" mandaría a re-correr QA sobre
      # un HEAD que ya es el bueno, y el sello nuevo saldría igual de sucio.
      echo "❌ la evidencia de QA $id está sellada bajo CONTENCIÓN (contention.suspect)"
      echo "   ↳ el commit es el correcto y nadie movió HEAD: la máquina estaba cargada"
      echo "     al sellar. Re-sella con la máquina descargada (o HARNESS_TEST_SLOTS=1)"
      echo "     y volvé a correr --merge-qa."
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
    git -C "$WT" merge-base --is-ancestor "$bcommit" "$vc" 2>/dev/null || {
      echo "❌ el baseline $bid está sellado sobre ${bcommit:0:12}, que NO es ancestro"
      echo "   del commit revisado (${vc:0:12})"
      echo "   ↳ un baseline prueba el PASADO de este cambio; un commit ajeno no prueba nada"
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
  local base_json
  base_json="$(printf '%s\n' $base_ids | jq -Rnc '[inputs | select(length > 0)]')"
  notes="$(jq -r '.notes // ""' "$q")"
  tmp="$(mktemp "$WS/tasks/$TASK/.verdict-$REPO.XXXXXX")"
  jq -S --arg qa "$qa_state" --argjson ids "$ids_json" \
        --argjson bids "$base_json" --arg notes "$notes" '
    .qa = $qa
    | .qa_notes = (if $notes == "" then (.qa_notes // empty) else $notes end)
    | .evidence = ((.evidence + $ids) | unique)
    | (if ($bids | length) > 0
       then .evidence_baseline = (((.evidence_baseline // []) + $bids) | unique)
       else . end)' "$v" > "$tmp" && mv "$tmp" "$v"
  echo "✅ merge-qa: qa=$qa_state fusionado al veredicto ($(printf '%s' "$ids_json" | jq 'length') EVs de QA)"
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
for f in "$WS/tasks/$TASK/evidence"/EV-*.json; do
  [ -e "$f" ] || continue
  line="$(jq -r --arg t "$TASK" --arg r "$REPO" --arg c "$HEAD" --arg p "$PATCH_ID" \
    "$ELIGIBLE_JQ"'
    select(type == "object" and .schema == 1 and .task_id == $t and .repo == $r)
    | if eligible($t; $r; $c; $p)
      then [.id, (.runner // ""), (.kind // "")] | join("|")
      elif eligible_salvo_contencion($t; $r; $c; $p) then "SUSPECT"
      else "STALE" end
  ' "$f" 2>/dev/null || true)"
  case "$line" in
    "") ;;
    SUSPECT) suspect=$((suspect+1)) ;;
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
    # El commit es el CORRECTO: lo único que descalificó a estos EV es el sello
    # de contención. Decir "de OTRO commit" mandaba a cazar un HEAD movido que
    # nadie había movido, y el sello nuevo salía igual de sucio.
    echo "❌ hay $suspect evidencia(s) de $REPO@${HEAD:0:12} selladas bajo CONTENCIÓN"
    echo "   ↳ el commit es el correcto y nadie movió HEAD: la máquina estaba cargada"
    echo "     al sellar. Re-sella con la máquina descargada (o HARNESS_TEST_SLOTS=1):"
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

tmp="$(mktemp "$WS/tasks/$TASK/.verdict-$REPO.XXXXXX")"
printf '%s\n' "$rows" | jq -RnS --arg task "$TASK" --arg repo "$REPO" \
    --arg commit "$HEAD" --arg reviewer "$REVIEWER" \
    --arg patch_id "$PATCH_ID" --arg reviewed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  [inputs | select(length > 0) | split("|")] as $rows
  | { schema: 1, task_id: $task, repo: $repo, commit: $commit,
      patch_id: $patch_id, reviewed_at: $reviewed_at,
      reviewer: $reviewer,
      implementation_agents:
        ($rows | map(.[1])
         | map(select(. != "" and . != $reviewer and . != "qa" and . != "ship"))
         | unique),
      evidence: ($rows | map(.[0])),
      verdict: "PENDING_REVIEWER",
      qa: "pending",
      blocking: [], non_blocking: [],
      docs_updated: false,
      compliance: [],
      requirements_uncovered: -1,
      snapshots_updated_justified: false }' > "$tmp"

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
  # que por el predicado de arriba ya excluye lo marcado por contención.
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
      rebound_at: $fresh[0].reviewed_at }' > "$reb" 2>/dev/null && [ -s "$reb" ] || {
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
            | .evidence_qa_stale = true' "$tmp" > "$tmp.qa" && mv "$tmp.qa" "$tmp"
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

mv "$tmp" "$OUT"
echo "✅ scaffold: tasks/$TASK/verdict-$REPO.json ($(jq '.evidence|length' "$OUT") evidencias, agents=$(jq -c '.implementation_agents' "$OUT"), commit ${HEAD:0:12})"

# El árbol clavado va DESPUÉS del sello: si el scaffold se negó (evidencia
# stale, roles, juicio incorrupto), no queda un pin apuntando a un commit que
# ningún veredicto sella.
REVIEW_DIR="worktrees/$TASK/$REPO"
if pin_review_tree "$HEAD"; then
  REVIEW_DIR="worktrees/$TASK/.review-$REPO"
  echo "📌 árbol clavado al commit sellado: $REVIEW_DIR (${HEAD:0:12}, detached)"
  echo "   el reviewer LEE y difea AHÍ, no en el worktree vivo: el vivo es del"
  echo "   implementer y puede seguir moviéndose mientras se emite el juicio."
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
