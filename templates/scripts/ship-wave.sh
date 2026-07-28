#!/usr/bin/env bash
# ship-wave.sh: la tarea entera en orden del DAG, con los post-ship declarados.
#
# POR QUÉ EXISTE: el dag: de answers decía literal "ship.sh no lo impone" y
# NADIE ejecutaba el orden. Caso de campo: la cadena real
#   design-system (token) -> publish latest -> consumidor (bump) -> deploy
# se corrió a mano y un eslabón quedó a medias (el testId shippeado y
# publicado, el consumidor sin bump: su spec siguió roja). Esta ola recorre
# `harness-policy.py dag-order`, salta lo ya aterrizado, corre ship.sh por
# repo y, tras cada repo, el hook `deploy.<repo>.post_ship` de answers (bajo
# with-secrets). Un rojo detiene la ola con el estado claro y el comando de
# retome. Reanudación idempotente: ship.log salta ships hechos y
# ship-wave.log salta hooks ya verdes.
#
# flow: prs con landed:false: la ola SIGUE pero DIFIERE el post_ship de ese
# repo (un publish desde un PR sin mergear publicaría algo que no existe);
# queda como assumption en el bus y en el resumen, con el retome exacto.
#
# Uso: ship-wave.sh <task-id> [--from <repo>]
# Portabilidad: bash 3.2, BSD userland, jq.
set -euo pipefail

TASK=""
FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:?--from necesita un repo}"; shift 2 ;;
    --*) echo "❌ flag desconocido: $1"; exit 1 ;;
    *) TASK="$1"; shift ;;
  esac
done
[ -n "$TASK" ] || { echo "uso: ship-wave.sh <task-id> [--from <repo>]"; exit 1; }
case "$TASK" in [A-Za-z0-9]*) : ;; *) echo "❌ task-id inválido: '$TASK'"; exit 1; esac
case "$TASK" in *..*|*/*) echo "❌ task-id inválido: '$TASK'"; exit 1 ;; esac
command -v jq >/dev/null || { echo "❌ jq requerido"; exit 1; }

WS="$(cd "$(dirname "$0")/.." && pwd)"
SHIP_LOG="$WS/tasks/$TASK/ship.log"
WAVE_LOG="$WS/tasks/$TASK/ship-wave.log"

emit() { [ -f "$WS/scripts/emit.sh" ] && bash "$WS/scripts/emit.sh" "$@" >/dev/null 2>&1 || true; }

# el parser de claves planas del bloque deploy:, COPIA de deploy-watch
# (answers_repo_key); el test de paridad de test_ship_wave.sh los compara
answers_repo_key() {  # answers_repo_key <repo> <clave> → valor, o vacío
  [ -f "$WS/harness-answers.yaml" ] || return 0
  awk -v r="$1" -v k="$2" '
    BEGIN { q = sprintf("%c", 39) }
    /^[[:space:]]*#/ { next }
    /^deploy:/ { ind=1; next }
    ind && /^[^[:space:]]/ { ind=0 }
    ind && $0 ~ "^[[:space:]]+" r ":" { cur=1; next }
    ind && cur && $0 ~ "^[[:space:]]+" k ":[[:space:]]*" {
      d=$0; sub(/^[^:]*:[[:space:]]*/,"",d); sub(/[[:space:]]+$/,"",d)
      # SOLO el par envolvente: un verify_cmd con comillas internas se
      # despedazaria con un gsub global de comillas
      if ((substr(d,1,1) == "\"" && substr(d,length(d),1) == "\"") ||
          (substr(d,1,1) == q    && substr(d,length(d),1) == q))
        d = substr(d, 2, length(d)-2)
      print d; exit }
    # [[:space:]][[:space:]] y no {2}: el awk BSD de macOS no habilita
    # intervalos ERE sin --re-interval, y si esta regla no matchea, cur nunca
    # se resetea y el driver de OTRO repo más abajo se leería como el propio.
    ind && cur && /^[[:space:]][[:space:]][a-zA-Z0-9_-]+:/ { cur=0 }
  ' "$WS/harness-answers.yaml" 2>/dev/null
}

shipped() {  # ¿hay ALGUNA línea de ship para el repo?
  [ -f "$SHIP_LOG" ] || return 1
  jq -e --arg r "$1" 'select(.repo == $r)' "$SHIP_LOG" >/dev/null 2>&1
}

landed() {  # el ÚLTIMO registro del repo, y preguntando igualdad, no presencia
  [ -f "$SHIP_LOG" ] || return 1
  [ "$(jq -c --arg r "$1" 'select(.repo == $r)' "$SHIP_LOG" 2>/dev/null \
    | tail -1 | jq -r 'if .landed == false then "false" else "true" end')" = "true" ]
}

hook_done() {
  [ -f "$WAVE_LOG" ] || return 1
  jq -e --arg r "$1" 'select(.repo == $r and .step == "post_ship" and .ok == true)' \
    "$WAVE_LOG" >/dev/null 2>&1
}

log_wave() {  # log_wave <repo> <step> <ok>
  printf '{"repo":"%s","step":"%s","ok":%s,"at":"%s"}\n' \
    "$1" "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$WAVE_LOG"
}

wave_stop() {  # wave_stop <repo> <motivo>
  echo ""
  echo "⛔ la ola de $TASK paró en $1: $2"
  echo "   Shippeado hasta ahora: $( [ -f "$SHIP_LOG" ] && jq -r '.repo' "$SHIP_LOG" 2>/dev/null | sort -u | tr '\n' ' ' || echo '(nada)')"
  echo "   ↳ arregla lo de arriba y retoma EXACTAMENTE donde quedó:"
  echo "     bash scripts/ship-wave.sh $TASK --from $1"
  emit stop "la ola de ship de $TASK paró en $1: $2" "" "$TASK"
  exit 1
}

order="$(python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" \
  dag-order "$WS/tasks/$TASK" 2>&1)" || {
  echo "❌ no pude derivar el orden del DAG:"
  printf '%s\n' "$order" | sed 's/^/   /'
  case "$order" in
    *"invalid choice"*)
      echo "   ↳ tu harness-policy.py es viejo (no conoce dag-order): corré el update de la instancia" ;;
  esac
  exit 3; }

echo "══ ship-wave $TASK: $(printf '%s\n' "$order" | grep -c .) repo(s) en orden del DAG ══"
skipping=""
[ -n "$FROM" ] && skipping=1
deferred=""
for repo in $order; do
  if [ -n "$skipping" ]; then
    if [ "$repo" = "$FROM" ]; then skipping=""; else
      echo "· salto $repo (--from $FROM)"; continue
    fi
  fi
  if shipped "$repo"; then
    echo "✓ $repo ya está en ship.log: no lo re-shippeo"
  else
    echo "── ola: ship $repo ──"
    bash "$WS/scripts/ship.sh" "$TASK" "$repo" || wave_stop "$repo" "ship.sh salió rojo"
  fi
  hook="$(answers_repo_key "$repo" post_ship)"
  if [ -n "$hook" ] && ! hook_done "$repo"; then
    if landed "$repo"; then
      echo "── post-ship de $repo: $hook ──"
      if bash "$WS/scripts/with-secrets.sh" bash -c "$hook"; then
        log_wave "$repo" post_ship true
        echo "✅ post-ship de $repo verde"
      else
        log_wave "$repo" post_ship false
        wave_stop "$repo" "el post_ship declarado salió rojo"
      fi
    else
      echo "⏸  post-ship de $repo DIFERIDO: el PR no mergeó (flow: prs)."
      echo "   Un publish desde un PR sin mergear publicaría algo que no existe."
      emit assumption "post-ship de $repo diferido: PR sin mergear; retomá con ship-wave --from $repo" "" "$TASK"
      deferred="$deferred $repo"
    fi
  fi
done

echo ""
if [ -n "$deferred" ]; then
  echo "🟡 ola completa con post-ship DIFERIDOS:$deferred"
  echo "   Tras el merge de cada PR: bash scripts/ship-wave.sh $TASK --from <repo>"
else
  echo "🟢 ola completa: todos los repos del DAG shippeados y sus post-ship verdes"
fi
