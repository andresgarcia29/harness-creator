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
# Placeholders INESCAPABLES para los gates: verdict:"PENDING_REVIEWER",
# qa:"pending", y requirements_uncovered:-1 (JAMÁS null/0: el check hace
# (// 0)==0 y null pasaría).
#
# Uso: verdict-scaffold.sh [--force|--rebase] [--allow-empty] <task-id> <repo> [reviewer]
#   --allow-empty  para el /review paralelo (la evidencia de QA llega después)
#   --force        re-scaffold (imprime commit/verdict previos; el juicio se pierde)
#   --rebase       re-review INCREMENTAL: conserva el juicio que el delta no tocó
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
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --rebase) REBASE=1; shift ;;
    --allow-empty) ALLOW_EMPTY=1; shift ;;
    --*) echo "❌ flag desconocido: $1"; exit 1 ;;
    *) break ;;
  esac
done
[ "$FORCE" -eq 1 ] && [ "$REBASE" -eq 1 ] && {
  echo "❌ --force y --rebase son opuestos: uno borra el juicio previo, el otro lo conserva"
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
    [ "$PREV_COMMIT" != "$HEAD" ] || {
      echo "❌ el veredicto previo ya es de este commit (${HEAD:0:12}): no hay delta que rebasear"
      echo "   ↳ si el implementer aún no commiteó el fix, no hay nada que re-revisar todavía"; exit 3; }
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
rows=""
stale=0
for f in "$WS/tasks/$TASK/evidence"/EV-*.json; do
  [ -e "$f" ] || continue
  line="$(jq -r --arg t "$TASK" --arg r "$REPO" --arg c "$HEAD" '
    select(type == "object" and .schema == 1 and .task_id == $t and .repo == $r)
    | if .commit == $c and .commit_after == $c and .exit_code == 0
      then [.id, (.runner // ""), (.kind // "")] | join("|")
      else "STALE" end
  ' "$f" 2>/dev/null || true)"
  case "$line" in
    "") ;;
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
  if [ "$stale" -gt 0 ]; then
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
PATCH_ID=""
if [ -f "$WS/scripts/change-id.sh" ]; then
  PATCH_ID="$(bash "$WS/scripts/change-id.sh" "$WT" 2>/dev/null || true)"
fi
[ -n "$PATCH_ID" ] || echo "⚠️  sin patch_id (no pude identificar el cambio): si el trunk se mueve antes del ship, este veredicto caduca y habrá re-review"

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
if [ "$REBASE" -eq 1 ]; then
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
      rebased_from: $prevc
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

mv "$tmp" "$OUT"
echo "✅ scaffold: tasks/$TASK/verdict-$REPO.json ($(jq '.evidence|length' "$OUT") evidencias, agents=$(jq -c '.implementation_agents' "$OUT"), commit ${HEAD:0:12})"
[ "$REBASE" -eq 1 ] && echo "→ re-review INCREMENTAL: juzga solo las entradas con .rejudge; el resto trae carried_from."
echo "→ el reviewer reemplaza SOLO el juicio: verdict, blocking, non_blocking,"
echo "  compliance, requirements_uncovered, docs_updated, snapshots_updated_justified."
echo "  El campo qa lo fusiona /review desde qa-$REPO.json."
