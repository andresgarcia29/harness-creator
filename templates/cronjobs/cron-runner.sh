#!/usr/bin/env bash
# cron-runner.sh — ejecutor de cronjobs self-healing del harness.
# Arquitectura: el DETECTOR (determinista, cero LLM) produce hallazgos;
# el agente SOLO despierta si hay algo que arreglar, con modelo, esfuerzo
# y presupuesto en USD fijados por models.yaml. Todo aterriza como
# PR/issue (GitHub como base de datos) — NUNCA push directo a main.
#
# Uso: cron-runner.sh <jobs/nombre.sh>
# Contrato del job (se sourcea):
#   JOB_NAME, JOB_TIER (cheap|medium|expensive), JOB_TOOLS (allowlist),
#   JOB_MAX_TURNS (opcional, default 40), detect() → escribe hallazgos
#   en $FINDINGS y retorna: 0=limpio · 10=hallazgos (despertar agente) ·
#   3=skip (falta herramienta) · otro=error del detector.
#   JOB_PROMPT — instrucciones del agente (los hallazgos se anexan).
set -uo pipefail
JOB_FILE="${1:?uso: cron-runner.sh <jobs/nombre.sh>}"
WS="$(cd "$(dirname "$0")/../.." && pwd)"   # scripts/cronjobs/ → workspace
cd "$WS"
MODELS="$WS/models.yaml"
LEDGER_DIR="$WS/.cache/cron"; mkdir -p "$LEDGER_DIR"
LEDGER="$LEDGER_DIR/ledger.jsonl"

# shellcheck disable=SC1090
. "$JOB_FILE"
: "${JOB_NAME:?el job debe definir JOB_NAME}"
: "${JOB_TIER:?el job debe definir JOB_TIER}"
: "${JOB_PROMPT:?el job debe definir JOB_PROMPT}"
JOB_MAX_TURNS="${JOB_MAX_TURNS:-40}"
FAILS_F="$LEDGER_DIR/$JOB_NAME.fails"

log()    { echo "[$JOB_NAME] $1"; }

# ── UN HALLAZGO, UN PR: LOS CRONJOBS NO SE MULTIPLICAN POR WORKSPACE ──
# Estos jobs entregan PRs e issues contra los repos COMPARTIDOS, pero su
# ledger y su circuit breaker son locales. Con varias instalaciones del harness
# (una por persona) el mismo detector encuentra el mismo hallazgo en todas y
# entrega hasta N PRs duplicados del mismo bump de dependencia; y el breaker
# abre en una laptop mientras las otras siguen martillando.
#
# La perilla vive en harness-answers.yaml:
#   cronjobs:
#     run_on: any            → cualquiera (el default, correcto con UN workspace)
#     run_on: <hostname>     → solo esa máquina (el "workspace designado")
#     run_on: k8s            → nadie local; corren en el CronJob de Kubernetes
#                              (templates/cronjobs/k8s-cronjob.yaml.tmpl)
# Se falla hacia NO correr cuando el dueño está declarado y no somos nosotros:
# un job que no corre se nota, uno que corre diez veces contamina un repo
# compartido y se lo come el equipo entero.
cron_owner() {
  [ -f "$WS/harness-answers.yaml" ] || { printf 'any'; return 0; }
  awk '/^cronjobs:/ { insec=1; next }
       insec && /^[^[:space:]]/ { insec=0 }
       insec && /^[[:space:]]+run_on:[[:space:]]*/ {
         v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); gsub(/["\047]/,"",v)
         sub(/[[:space:]]*#.*$/,"",v); sub(/[[:space:]]+$/,"",v); print v; exit }
      ' "$WS/harness-answers.yaml" 2>/dev/null | grep . || printf 'any'
}
OWNER="$(cron_owner)"
ME="$(hostname -s 2>/dev/null || echo desconocido)"
case "$OWNER" in
  # Un placeholder sin sustituir es un problema de generación (le toca al
  # doctor), no un motivo para desactivar en silencio los trece cronjobs.
  any|""|'{{'*) : ;;
  k8s)
    log "⏭️  cronjobs.run_on=k8s: este job corre en el CronJob de Kubernetes, no acá."
    exit 0 ;;
  "$ME") : ;;
  *)
    log "⏭️  cronjobs.run_on=$OWNER y esta máquina es $ME: no corro."
    log "   Con varios workspaces, correr en todos entrega PRs duplicados del"
    log "   mismo hallazgo a un repo compartido."
    exit 0 ;;
esac
ledger() { # ledger <status> <cost>
  printf '{"job":"%s","ts":"%s","status":"%s","cost_usd":%s}\n' \
    "$JOB_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-0}" >> "$LEDGER"
}

# ── Circuit breaker: 3 fallos consecutivos → no correr, avisar ────────
fails=$(cat "$FAILS_F" 2>/dev/null || echo 0)
if [ "$fails" -ge 3 ]; then
  log "⛔ circuit breaker abierto ($fails fallos consecutivos) — revisar a mano y borrar $FAILS_F"
  ledger circuit-open 0
  exit 78   # EX_CONFIG: visible en el estado del CronJob
fi

# ── Política de modelos desde models.yaml (aliases fast|smart|deep) ──
# Los tiers hablan en aliases; stamp-models.sh los traduce al ID real del
# proveedor activo. Si la resolución falla, el valor crudo pasa tal cual
# (compat con models.yaml antiguos que traían IDs directos).
ysec() {  # ysec <sección> — valor de $JOB_TIER dentro de esa sección
  awk -v s="$1:" -v k="$JOB_TIER:" '
    /^[^ #]/ { insec = ($1 == s) }
    insec && $1 == k && /^  / { print $2; exit }
  ' "$MODELS"
}
TIER_ALIAS="$(ysec cronjobs)"
EFFORT="$(ysec cronjob_effort)"; EFFORT="${EFFORT:-medium}"
BUDGET="$(ysec budgets)"
[ -n "$TIER_ALIAS" ] || { log "❌ tier '$JOB_TIER' no está en models.yaml (sección cronjobs)"; ledger config-error 0; exit 78; }
MODEL="$(bash "$WS/scripts/stamp-models.sh" resolve "$TIER_ALIAS" 2>/dev/null || echo "$TIER_ALIAS")"

# ── Detector (determinista) ──────────────────────────────────────────
FINDINGS="$(mktemp)"; export FINDINGS
set +e; detect; rc=$?; set -e
case "$rc" in
  0)  log "✅ detector limpio — el agente no despierta (camino verde = cero tokens)"
      echo 0 > "$FAILS_F"; ledger clean 0; rm -f "$FINDINGS"; exit 0 ;;
  3)  log "⚠️ detector saltado (herramienta faltante) — instala lo que indica el job"
      ledger skipped 0; rm -f "$FINDINGS"; exit 0 ;;
  10) log "🔎 hallazgos ($(wc -l < "$FINDINGS" | tr -d ' ') líneas) — despertando agente [$MODEL/$EFFORT, tope \$$BUDGET]" ;;
  *)  log "❌ detector falló (exit $rc)"
      echo $((fails+1)) > "$FAILS_F"; ledger detector-error 0; exit "$rc" ;;
esac

# ── Agente headless con presupuesto ──────────────────────────────────
PROMPT="$JOB_PROMPT

## Hallazgos del detector (determinista)
\`\`\`
$(head -c 40000 "$FINDINGS")
\`\`\`

Reglas duras: trabaja en una rama nueva \`bot/$JOB_NAME-$(date +%Y%m%d)\`;
entrega PR o issue vía scripts/forge.sh (forge_pr_create / forge_issue_create); JAMÁS pushees a main; respeta la constitución
(docs/constitution.md); si el hallazgo es falso positivo, actualiza la
whitelist del detector en vez de forzar un arreglo."

set +e
OUT="$(claude -p "$PROMPT" \
  --model "$MODEL" --effort "$EFFORT" \
  --max-turns "$JOB_MAX_TURNS" --max-budget-usd "$BUDGET" \
  --permission-mode dontAsk \
  ${JOB_TOOLS:+--allowedTools "$JOB_TOOLS"} \
  --output-format json 2>&1)"
arc=$?
set -e
rm -f "$FINDINGS"

COST="$(echo "$OUT" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)"
if [ "$arc" -eq 0 ]; then
  echo 0 > "$FAILS_F"; ledger done "$COST"
  log "🟢 agente terminó (costo \$$COST)"
  echo "$OUT" | jq -r '.result // empty' 2>/dev/null | tail -20
else
  echo $((fails+1)) > "$FAILS_F"; ledger agent-error "$COST"
  log "🔴 agente falló (exit $arc, costo \$$COST) — fallo $((fails+1))/3 del circuit breaker"
  exit "$arc"
fi
