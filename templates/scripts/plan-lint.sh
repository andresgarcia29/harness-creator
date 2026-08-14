#!/usr/bin/env bash
# plan-lint.sh: el plan es EJECUTABLE o no es un plan.
#
# POR QUÉ EXISTE: la re-iteración cara del pipeline casi nunca nace en el
# código, nace en el plan. Un plan que no nombra archivos, que deja un
# criterio difuso o que dice "investigar si...", delega la decisión al
# implementer; el implementer elige; el reviewer no está de acuerdo; y ahí
# se va una ronda de 10-20 minutos. Este script comprueba de forma
# determinista (cero tokens, cero juicio) que el plan trae TODO lo que el
# implementer necesita para no adivinar.
#
# Uso: plan-lint.sh <task-id>
#   exit 0 = plan ejecutable · 2 = falta el artefacto · 3 = plan rojo
#
# Qué exige, por tarea del plan (bloque '### T<n> ...'):
#   repo · req · archivos · criterios · complexity (low|high) · deps
# Y sobre el plan completo:
#   · cero vaguedad declarada (TBD, por definir, investigar si, no está claro)
#   · cada ID de `req:` existe de verdad en delta-spec.md (trazabilidad
#     req -> tarea -> test, la misma que el reviewer usa en su matriz)
#
# Portabilidad: bash 3.2 (macOS), awk y grep BSD. Sin dependencias.
set -u

TASK="${1:-}"
[ -n "$TASK" ] || { echo "uso: plan-lint.sh <task-id>"; exit 2; }
case "$TASK" in
  [A-Za-z0-9]*) : ;;
  *) echo "❌ task-id inválido: '$TASK'"; exit 2 ;;
esac
case "$TASK" in *..*|*/*) echo "❌ task-id inválido: '$TASK'"; exit 2 ;; esac

WS="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$WS/tasks/$TASK"
PLAN="$DIR/plan.md"
DELTA="$DIR/delta-spec.md"

red=0
say() { printf '   · %s\n' "$1"; }

[ -f "$PLAN" ] || {
  echo "❌ no existe $PLAN"
  echo "   ↳ remediación: el plan es el artefacto de la fase RFC (o el mini-plan"
  echo "     del carril express). Escríbelo antes de pedir implement."
  exit 2
}

echo "── plan-lint: $TASK"

# ── 1. Bloques de tarea con TODAS sus claves ──────────────────────────
# Formato (lo produce el architect; ver .claude/agents/architect.md):
#   ### T1 · <repo> · <título>
#   - repo: atlas
#   - req: GW-4, GW-5
#   - archivos: internal/ratelimit/limiter.go, internal/http/middleware.go
#   - criterios: 429 tras 100 req/min por tenant (verificable por test)
#   - complexity: low
#   - deps: ninguna
missing="$(awk '
  BEGIN { need = "repo req archivos criterios complexity deps" }
  function flush(   i, n, arr, miss) {
    if (id == "") return
    n = split(need, arr, " ")
    miss = ""
    for (i = 1; i <= n; i++)
      if (index(keys " ", " " arr[i] " ") == 0) miss = miss " " arr[i]
    if (miss != "") printf "%s: faltan claves:%s\n", id, miss
    else if (cx !~ /^(low|high)$/) printf "%s: complexity debe ser low|high (era \"%s\")\n", id, cx
    id = ""; keys = " "; cx = ""
  }
  /^###[ \t]+T[0-9]+/ {
    flush()
    id = $0; sub(/^###[ \t]+/, "", id); sub(/[ \t]*$/, "", id)
    keys = " "; cx = ""
    next
  }
  /^[ \t]*[-*][ \t]+[A-Za-z_]+[ \t]*:/ {
    if (id == "") next
    line = $0
    sub(/^[ \t]*[-*][ \t]+/, "", line)
    k = line; sub(/[ \t]*:.*$/, "", k); k = tolower(k)
    keys = keys k " "
    if (k == "complexity") {
      v = line; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]*$/, "", v); cx = tolower(v)
    }
    next
  }
  END { flush() }
' "$PLAN")"

tasks_n="$(grep -cE '^###[ \t]+T[0-9]+' "$PLAN" || true)"
if [ "${tasks_n:-0}" -eq 0 ]; then
  echo "❌ el plan no declara ni una tarea"
  echo "   ↳ remediación: cada tarea es un bloque '### T<n> · <repo> · <título>'"
  echo "     con sus claves repo/req/archivos/criterios/complexity/deps."
  red=1
elif [ -n "$missing" ]; then
  echo "❌ tareas del plan incompletas (el implementer tendría que adivinar):"
  printf '%s\n' "$missing" | while IFS= read -r l; do [ -n "$l" ] && say "$l"; done
  echo "   ↳ remediación: sin 'archivos' no hay paralelo demostrable, sin 'req' no"
  echo "     hay matriz de compliance, y sin 'criterios' binarios el review es opinión."
  red=1
fi

# ── 2. Vaguedad declarada: lo que el plan no decidió, lo decide el loop ──
# OJO con "todo": en español es una palabra normal ("todo el diff"), así que
# solo cuenta el marcador de código "TODO:" en mayúsculas y con dos puntos.
vague="$( { grep -niE '(^|[^A-Za-z])(tbd|por definir|a definir|pendiente de decidir|investigar si|no est(á|a) claro|ya veremos)([^A-Za-z]|$)' "$PLAN" || true
            grep -nE '(^|[^A-Za-z])(TODO|FIXME|XXX):' "$PLAN" || true; } | sort -n -u)"
if [ -n "$vague" ]; then
  echo "❌ el plan deja decisiones abiertas:"
  printf '%s\n' "$vague" | while IFS= read -r l; do [ -n "$l" ] && say "$l"; done
  echo "   ↳ remediación: resuélvelas AHORA (una probe es más barata que una ronda"
  echo "     de review) o sácalas del scope y déjalas como bead de seguimiento."
  red=1
fi

# ── 2b. Los números de línea envejecen: se ancla por símbolo ──────────
# Caso de campo, cuatro veces en una corrida: el arquitecto escribe
# render.mjs:44, una tarea hermana shippea y mueve el archivo, y el
# implementer sigue coordenadas muertas (hubo que avisarlo a mano en cada
# prompt). Y de regalo, un sufijo :NN rompe los patrones anclados a $ del
# guard de carril: schema.sql:12 no matchea \.sql$ y un express que tocaba
# SQL pasaba de largo (falso negativo del check 4).
lineref_archivos="$(awk '
  /^[ \t]*[-*][ \t]+[Aa]rchivos[ \t]*:/ {
    line = $0; sub(/^[^:]*:[ \t]*/, "", line)
    n = split(line, arr, /[,;]/)
    for (i = 1; i <= n; i++) { f = arr[i]; gsub(/^[ \t]+|[ \t]+$/, "", f)
      if (f ~ /:[0-9]+([-,][0-9]+)*$/) print f }
  }' "$PLAN")"
# En la prosa solo cuenta lo que parece ruta de código (extensión conocida):
# una hora 12:30 o un host:puerto no son referencias a archivos.
lineref_prosa="$(grep -noE '[A-Za-z0-9_./-]+\.(go|py|ts|tsx|js|jsx|mjs|cjs|rs|java|rb|php|tf|sql|sh|bash|kt|cs|swift|vue|svelte|astro|proto|yaml|yml|toml|md):[0-9]+([-,][0-9]+)*' "$PLAN" 2>/dev/null || true)"
linerefs="$( { printf '%s\n' "$lineref_archivos"; printf '%s\n' "$lineref_prosa"; } | grep -v '^$' | sort -u || true)"
if [ -n "$linerefs" ]; then
  echo "❌ el plan ancla por número de línea, y los números mueren con el primer rebase:"
  printf '%s\n' "$linerefs" | while IFS= read -r l; do [ -n "$l" ] && say "$l"; done
  echo "   ↳ remediación: cita el SÍMBOLO (función, clase, sección), no la línea."
  echo "     Una tarea hermana que shippea primero mueve el archivo y el implementer"
  echo "     queda siguiendo coordenadas muertas. Además, un sufijo :NN esquiva los"
  echo "     patrones del guard de carril (schema.sql:12 no matchea \\.sql\$)."
  red=1
fi

# ── 3. Trazabilidad: cada req citado existe en el delta-spec ──────────
if [ -f "$DELTA" ]; then
  if ! grep -qiE '^#+[ \t]*(ADDED|MODIFIED|REMOVED)' "$DELTA"; then
    echo "❌ delta-spec.md sin secciones ADDED/MODIFIED/REMOVED"
    echo "   ↳ remediación: el delta ES la definición formal del blast radius;"
    echo "     gate_tests_untouched y la matriz del reviewer leen esas secciones."
    red=1
  fi
  reqs="$(awk '
    /^[ \t]*[-*][ \t]+[Rr]eq[ \t]*:/ {
      line = $0; sub(/^[^:]*:[ \t]*/, "", line)
      n = split(line, arr, /[,;]/)
      for (i = 1; i <= n; i++) { r = arr[i]; gsub(/^[ \t]+|[ \t]+$/, "", r); if (r != "") print r }
    }
  ' "$PLAN" | sort -u)"
  huerfanos=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    grep -qF -- "$r" "$DELTA" || huerfanos="$huerfanos $r"
  done <<REQEOF
$reqs
REQEOF
  if [ -n "$huerfanos" ]; then
    echo "❌ el plan cita requirements que el delta-spec no define:$huerfanos"
    echo "   ↳ remediación: o el ID está mal escrito, o ese requirement todavía no"
    echo "     existe. Un req sin entrada en el delta no lo puede cubrir ningún test."
    red=1
  fi
else
  echo "❌ no existe $DELTA"
  echo "   ↳ remediación: TODOS los carriles producen delta-spec (express con 2-6"
  echo "     líneas EARS bajo '## ADDED Requirements'). El carril recorta"
  echo "     deliberación, jamás artefactos."
  red=1
fi

# ── 4. El carril, contra los ARCHIVOS que el plan declara ─────────────
# gate_lane (ship.sh) verifica el carril contra el diff REAL, y es ley. El
# problema era CUÁNDO: al final, después de implementar, revisar y hacer QA.
# Un express rojo por carril no es un fix local, es el retroceso más caro del
# pipeline (escalar carril → volver a /rfc → re-planear → re-implementar), y se
# descubría en el momento de máximo costo hundido.
#
# El plan YA declara `archivos:` por tarea, así que el mismo patrón se puede
# correr acá, gratis y antes de lanzar a nadie. Esto no reemplaza al gate: es
# el mismo criterio, aplicado donde todavía no cuesta nada equivocarse.
LANE=""
[ -f "$DIR/state.json" ] && LANE="$(sed -n 's/.*"lane"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$DIR/state.json" | head -1)"

# Los archivos que el plan declara: los usan DOS comprobaciones (el freno de
# carril corto de abajo y el aviso de carril de más), así que se calcula una
# vez. Se extrae acá y no dentro del `if` porque duplicar el awk fue como
# divergieron antes el patrón de este script y el de gate_lane.
planned_all="$(awk '
  /^[ \t]*[-*][ \t]+[Aa]rchivos[ \t]*:/ {
    line = $0; sub(/^[^:]*:[ \t]*/, "", line)
    n = split(line, arr, /[,;]/)
    for (i = 1; i <= n; i++) { f = arr[i]; gsub(/^[ \t]+|[ \t]+$/, "", f); if (f != "") print f }
  }' "$PLAN")"

# El patron de contrato/migracion/infra: mismo criterio que gate_lane, y hay
# un test que compara las dos lineas literalmente. No lo edites de un lado solo.
pat="${LANE_GUARD_PATTERN:-(\.proto$|(^|/)proto/|(^|/)migrations?/|\.sql$|(^|/)helm/|(^|/)charts?/|(^|/)Chart\.yaml$|(^|/)terraform/|\.tf$|\.tfvars$|(^|/)openapi\.|(^|/)swagger\.)}"
if [ "$LANE" = "express" ]; then
  # `\.tf$|\.tfvars$` van ademas de `(^|/)terraform/`: un infra-module lleva los
  # .tf en la RAIZ, sin directorio terraform/. Se agrego al pasar POLICY-LANE-004
  # de rechazo a aviso (#71), cuando este patron quedo como unico freno.
  # `charts?/` y `Chart.yaml` cubren las tres grafias de un chart de Helm (#83):
  # el `charts/` plural es el directorio de subcharts vendoreados, no el del
  # chart propio, que en la practica se llama `chart/` o vive en la raiz.
  hits="$(printf '%s\n' "$planned_all" | grep -E "$pat" || true)"
  if [ -n "$hits" ]; then
    echo "❌ carril express, pero el plan ya declara archivos de contrato/migración/infra:"
    printf '%s\n' "$hits" | while IFS= read -r l; do [ -n "$l" ] && say "$l"; done
    echo "   ↳ remediación: este cambio necesita deliberación. Escalá AHORA, que"
    echo "     es cuando sale barato (después de implementar cuesta re-planear entero):"
    echo "     python3 scripts/harness-policy.py escalate tasks/$TASK --to standard --actor orchestrator"
    red=1
  fi
fi

# ── 6. Un supuesto de ENTORNO sin medición es una apuesta, no un supuesto ──
#
# POR QUÉ EXISTE: el ciclo más caro del pipeline no es una ronda de review, es
# un plan entero construido sobre una creencia falsa sobre cómo se comporta
# algo que no controlamos. Caso de campo: la pregunta que decidió una tarea de
# $367 fue "¿un <img> degrada limpio en un cliente de correo con imágenes
# bloqueadas?". Se contestaba midiendo, en diez minutos. En vez de eso corrió
# architect → 4 implementers → 4 reviewers, y recién ahí QA descubrió que el
# diseño no servía. Ese ciclo completo, tirado.
#
# La regla YA existía en prosa (architect.md, "Runtime no se cita: se
# ejecuta") y nada la hacía obligatoria: un plan construido sobre "asumo que
# degrada limpio" pasaba este lint en verde. Ahora no.
#
# El marcador es EXPLÍCITO y lo pone quien escribe el ledger: `SUPUESTO-ENTORNO:`
# en vez de `SUPUESTO:`. Se eligió así en vez de adivinar cuáles supuestos son
# de entorno porque adivinar produce falsos positivos sobre el artefacto que el
# humano audita primero, y un lint que grita de más termina apagado. Lo que el
# gate garantiza es que quien SÍ lo declaró de entorno haya medido.
#
# La evidencia admisible es un ID de `evidence.py run`, o sea una EJECUCIÓN.
# Citar un doc no vale: el doc puede estar desactualizado y el entorno no.
ASSUMP="$DIR/assumptions.md"
if [ -f "$ASSUMP" ]; then
  unproven="$(awk '
    /^[ \t]*[-*][ \t]*SUPUESTO-ENTORNO[ \t]*:/ {
      if ($0 !~ /EV-[A-Za-z0-9-]+/) {
        line = $0; sub(/^[ \t]*[-*][ \t]*/, "", line); print line
      }
    }' "$ASSUMP")"
  if [ -n "$unproven" ]; then
    echo "❌ supuesto(s) de ENTORNO sin medición:"
    printf '%s\n' "$unproven" | while IFS= read -r l; do
      [ -n "$l" ] && say "$(printf '%s' "$l" | cut -c1-140)"
    done
    echo "   ↳ remediación: medí AHORA, que es cuando cuesta diez minutos. Después"
    echo "     de lanzar implementers cuesta el pipeline entero:"
    echo "     python3 scripts/evidence.py run --task-dir tasks/$TASK --repo <repo> \\"
    echo "       --runner architect --kind test --cwd <donde> -- <el comando que MIDE>"
    echo "     y pegá el EVIDENCE_ID en la entrada del ledger. Si de verdad no se"
    echo "     puede medir, no es un supuesto de entorno con evidencia: bajalo a"
    echo "     'SUPUESTO:' normal y declará el costo de que sea falso, que es lo"
    echo "     que el humano audita al volver."
    red=1
  fi
fi

# ── 7. El carril de más: se AVISA, no se bloquea ──────────────────────
#
# POR QUÉ EXISTE: `gate_lane` solo verifica hacia ARRIBA (que un carril corto no
# toque contratos). Nada detectaba lo contrario, que es el caso caro y silencioso:
# una tarea clasificada standard cuyo plan resultó trivial paga architect + RFC +
# reviewer + QA por repo para mover veinte líneas. Medido en campo, eso fue el
# segundo componente de costo de una tarea de $367.
#
# AVISO y no rojo, por dos razones: el carril no se BAJA (POLICY-LANE-002: solo
# se escala hacia arriba, porque bajar saltearía deliberación ya registrada), y
# un plan trivial en standard no es incorrecto, es caro. Bloquear algo correcto
# es como se apagan los linters.
#
# La señal es la que el plan YA declara: todas las tareas `complexity: low`, sin
# archivos de contrato/migración/infra, y pocos archivos por tarea.
if [ "$LANE" = "standard" ] || [ "$LANE" = "full" ]; then
  # `head -1` por tarea no sirve: hace falta saber si TODAS son low.
  high_n="$(grep -cE '^[ \t]*[-*][ \t]+complexity[ \t]*:[ \t]*high' "$PLAN" || true)"
  files_n="$(awk '
    /^[ \t]*[-*][ \t]+[Aa]rchivos[ \t]*:/ {
      line = $0; sub(/^[^:]*:[ \t]*/, "", line)
      n = split(line, arr, /[,;]/)
      for (i = 1; i <= n; i++) { f = arr[i]; gsub(/^[ \t]+|[ \t]+$/, "", f); if (f != "") c++ }
    } END { print c + 0 }' "$PLAN")"
  contract_n="$(printf '%s\n' "$planned_all" | grep -cE "$pat" 2>/dev/null || true)"
  if [ "${high_n:-0}" -eq 0 ] && [ "${contract_n:-0}" -eq 0 ] && [ "${files_n:-99}" -le 8 ]; then
    echo "ℹ️  carril $LANE con un plan que parece trivial: $tasks_n tarea(s), todas"
    echo "   complexity low, $files_n archivo(s), cero contratos/migraciones/infra."
    echo "   El carril no se BAJA (POLICY-LANE-002: solo se escala hacia arriba), así"
    echo "   que esto es información, no un rojo. Vale la pena mirarlo porque un plan"
    echo "   así en standard paga architect + RFC + reviewer + QA por repo para un"
    echo "   cambio mecánico. Si todavía no lanzaste a nadie, cancelar y re-entrar"
    echo "   como express es más barato que seguir; si ya gastaste el RFC, seguí."
  fi
fi

# ── 8. UN CRITERIO QUE NOMBRA UN GATE LO HACE CORRER DOS VECES ────────
#
# POR QUÉ EXISTE: `implementer.md` §5 prohíbe re-correr la suite ("No corras la
# suite otra vez: antes se corría cuatro veces por tarea"), y el formato de plan
# que este mismo script bendice empuja a lo contrario, porque la forma natural
# de escribir un criterio binario y ejercitable es nombrar los comandos de gate
# del repo. Las dos reglas son del mismo harness y se contradicen; la que gana
# es la que el implementer tiene delante, que es el plan.
#
# Medido en una tarea de dos rondas del carril express (1 repo, 2 archivos de
# producción y 2 de test): 18,9 min de reloj de herramientas, de los cuales
# ~10 son el precheck y ~7,9 son los MISMOS gates corridos a mano antes. O sea
# unos 8 minutos por tarea de ejecución duplicada, en el carril más barato que
# tiene el harness, y en un repo cuya suite paga 90 s de arranque por corrida.
#
# AVISA, no bloquea, y es deliberado: un criterio así no es incorrecto, es caro,
# y un lint que bloquea algo correcto es un lint que alguien apaga (misma
# decisión que el aviso de carril de más, arriba).
#
# La lista es de FORMAS conocidas y no del set de gates del repo: los gates por
# lenguaje viven en `run_lang_gates` de ship.sh, que no se puede consultar desde
# acá sin duplicar su despacho. Para un AVISO alcanza con reconocer las que
# aparecen en los planes; una que se escape solo cuesta el aviso que no salió.
gates_en_criterios="$(awk '
  /^[ \t]*[-*][ \t]+[Cc]riterios[ \t]*:/ {
    linea = tolower($0)
    if (linea ~ /(npm|pnpm|yarn|bun)[ \t]+(run[ \t]+)?(test|lint|typecheck|check)/ ||
        linea ~ /go[ \t]+(test|vet|build)/ ||
        linea ~ /(pytest|ruff|mypy|cargo[ \t]+test|tsc|terraform[ \t]+(validate|fmt))/ ||
        linea ~ /gradlew?[ \t]+(test|build)|mvn[ \t]+(test|verify)/) {
      sub(/^[ \t]*[-*][ \t]+/, "", $0); print substr($0, 1, 120)
    }
  }' "$PLAN")"
if [ -n "$gates_en_criterios" ]; then
  echo "ℹ️  criterio(s) que nombran comandos de gate:"
  printf '%s\n' "$gates_en_criterios" | while IFS= read -r l; do [ -n "$l" ] && say "$l"; done
  echo "   Los corre \`ship.sh --precheck\`, que el implementer YA está obligado a"
  echo "   correr antes de entregar: nombrarlos acá los hace correr dos veces por"
  echo "   ronda. Medido: ~8 min por tarea de dos rondas en el carril express."
  echo "   ↳ el criterio correcto es la CONDUCTA que el cambio agrega (el 429, el"
  echo "     campo nuevo, el error que ahora se rechaza). El precheck verde ya está"
  echo "     en el contrato del implementer y no hace falta escribirlo."
fi

if [ "$red" -eq 0 ]; then
  echo "✅ plan ejecutable: $tasks_n tarea(s), claves completas, sin decisiones abiertas"
  exit 0
fi
echo ""
echo "⛔ plan rojo. Arréglalo ANTES de lanzar implementers: cada hueco de aquí"
echo "   se paga después en rondas de review, que es el minuto más caro."
exit 3
