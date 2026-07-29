#!/usr/bin/env bash
# harness-bug.sh: el canal de vuelta al plugin. Un bug del HARNESS (no de tu
# código) se verifica aquí y se levanta como issue en el repo de harness-creator.
#
# POR QUÉ EXISTE: el harness corre en la máquina de cada usuario, y sus fallas
# mueren ahí. Un agente que tropieza con un bug del propio harness y solo lo
# rodea con un workaround local condena a los demás a tropezar igual. Pero el
# camino contrario (un agente abriendo issues cada vez que algo le sale rojo)
# es peor: ruido que entierra los reportes reales. Este script es el filtro
# determinista entre las dos cosas. El juicio ("¿vale la pena arreglarlo?") lo
# pone el agente siguiendo .claude/skills/harness-bug-report; los hechos
# verificables los pone este archivo.
#
# Uso:
#   harness-bug.sh check <ruta>            ¿es artefacto del plugin y está sin tocar?
#   harness-bug.sh report --title "..." --file <ruta> --repro <archivo> \
#                         --impact "<a quién más le pasa>" [--dry-run] [--force]
#   harness-bug.sh list                    el ledger local de lo ya reportado
#
# LEYES:
#   · FAIL-CLOSED. Cualquier verificación que no pase, NO abre issue. Un
#     reporte falso cuesta más que un bug no reportado: quema la confianza
#     del canal entero.
#   · REDACTA ANTES DE PUBLICAR. El repro suele ser la salida de un comando,
#     y esa salida trae tokens. La ley de secretos también aplica aquí, y
#     aquí es peor: esto sale a un repo PÚBLICO.
#   · CUOTA Y DEDUPE. Máximo 3 issues automáticos por 24h y jamás dos veces
#     el mismo fingerprint. Tres capas, porque el dedupe es una CARRERA: claim
#     local atómico antes de tocar la red (misma máquina), búsqueda remota
#     antes de crear, y reconciliación contra el forge después de crear (otra
#     máquina que ganó por segundos: el número de issue menor sobrevive).
#   · APAGABLE. HARNESS_UPSTREAM_ISSUES=off o `upstream_issues: off` en
#     harness-answers.yaml y este script no publica nada.
#
# Portabilidad: bash 3.2, BSD userland, jq. Red solo vía gh.
set -u

UPSTREAM_REPO="${HARNESS_UPSTREAM_REPO:-andresgarcia29/harness-creator}"
WS="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER="$WS/.harness/upstream-issues.jsonl"
CLAIMS="$WS/.harness/claims"
QUOTA="${HARNESS_BUG_QUOTA:-3}"
RECON_LIMIT="${HARNESS_BUG_RECONCILE_LIMIT:-30}"

die()  { echo "❌ $1" >&2; exit "${2:-1}"; }
note() { echo "   ↳ $1"; }

sha() {  # sha256 del stdin, portable (shasum en mac, sha256sum en linux)
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else sha256sum | awk '{print $1}'; fi
}

redact() {
  if [ -f "$WS/scripts/emit.sh" ]; then
    # el bus ya tiene los patrones y los tiene TESTEADOS (test_emit.sh); no
    # se duplican aquí: un segundo juego de regex es un segundo juego de bugs
    # shellcheck disable=SC1091
    . "$WS/scripts/emit.sh" 2>/dev/null && command -v _emit_redact >/dev/null 2>&1 \
      && { _emit_redact; return 0; }
  fi
  cat
}

ver_lt() {  # ver_lt <a> <b> → 0 si a < b (semver simple, sin pre-releases)
  awk -v a="$1" -v b="$2" 'BEGIN{
    na=split(a,x,"."); nb=split(b,y,".")
    n = na>nb ? na : nb
    for(i=1;i<=n;i++){ xi=x[i]+0; yi=y[i]+0
      if(xi<yi) exit 0
      if(xi>yi) exit 1 }
    exit 1 }'
}

# ── propiedad del artefacto ────────────────────────────────────────────────
# Solo lo que el PLUGIN escribe puede ser un bug del plugin. Lo que escribe tu
# instancia (docs, specs, agentes, pasos custom, answers) es tuyo: si falla,
# el bug es local aunque duela igual. Esta tabla es la misma clasificación de
# propiedad que usa /harness-update para decidir quién gana un diff.
owner_of() {
  case "$1" in
    scripts/smoke/*|scripts/cronjobs/jobs/local-*) echo instance ;;
    # Los cronjobs se extrajeron a su propio repo (harness-cronjobs). Siguen
    # siendo codigo de plugin, pero de OTRO plugin: reportarlos aca abriria el
    # issue en el repo equivocado, contra una ruta que ya no existe.
    scripts/cronjobs/*) echo otro-repo ;;
    scripts/*.sh|scripts/*.py|scripts/ui/*) echo plugin ;;
    .claude/hooks/*.sh) echo plugin ;;
    .claude/commands/*.md) echo plugin ;;
    .claude/skills/skill-creator/*|.claude/skills/pipeline-step-creator/*|.claude/skills/harness-bug-report/*) echo plugin ;;
    harness-policy.json|Makefile|AGENTS.md) echo plugin ;;
    *) echo instance ;;
  esac
}

# Ruta del template que originó el artefacto, si es una COPIA literal. Los
# archivos que el generador instancia con placeholders (secrets.sh, ship.sh,
# commands, CLAUDE.md) no tienen contraparte comparable: ahí el drift local es
# esperado y la comparación no aplica.
tpl_for() {
  local p="$1" base; base="$(basename "$p")"
  case "$p" in
    scripts/ui/*)                    echo "templates/ui/${p#scripts/ui/}" ;;
    scripts/*)                       echo "templates/scripts/$base" ;;
    .claude/hooks/*)                 echo "templates/hooks/$base" ;;
    .claude/skills/*/SKILL.md)       p="${p#.claude/skills/}"; echo "templates/skills/${p%/SKILL.md}/SKILL.md" ;;
    # harness-policy.json ya NO se mapea: dejó de copiarse verbatim y pasó a
    # policy.json.tmpl (max_review_rounds sale de loop_budget). Contra un
    # template, comparar sha no dice nada: la instancia tiene los valores
    # sustituidos y siempre daría "distinto". "no-verificable" es la respuesta
    # honesta, y es la que da el caso por defecto. Mapearlo a un archivo que no
    # existe daba lo mismo por accidente, que no es lo mismo que por diseño.
    *)                               echo "" ;;
  esac
}

# drift_of <ruta> → "igual" | "distinto" | "no-verificable"
drift_of() {
  local p="$1" tpl root
  root="${CLAUDE_PLUGIN_ROOT:-}"
  [ -n "$root" ] && [ -f "$WS/$p" ] || { echo "no-verificable"; return 0; }
  tpl="$(tpl_for "$p")"
  [ -n "$tpl" ] && [ -f "$root/$tpl" ] || { echo "no-verificable"; return 0; }
  if [ "$(sha < "$WS/$p")" = "$(sha < "$root/$tpl")" ]; then echo "igual"; else echo "distinto"; fi
}

enabled() {
  case "${HARNESS_UPSTREAM_ISSUES:-}" in off|false|0) return 1 ;; esac
  if [ -f "$WS/harness-answers.yaml" ]; then
    case "$(grep -E '^upstream_issues:' "$WS/harness-answers.yaml" | head -1 | awk '{print $2}')" in
      off|false) return 1 ;;
    esac
  fi
  return 0
}

# ── claim local sobre la huella ────────────────────────────────────────────
# EL DEDUPE ERA UNA CARRERA. Entre el chequeo del ledger y la escritura del
# ledger hay dos llamadas de red (el gate de versión y la búsqueda remota).
# Diez sesiones tropezando con el MISMO bug del plugin, que es exactamente el
# escenario para el que existe este canal, pasaban las tres verificaciones
# antes de que la primera escribiera: diez issues idénticos en un repo público.
# El claim cierra esa ventana con un mkdir, que es atómico (mismo patrón que
# acquire_create_lock de worktree-task.sh) y va ANTES de la primera llamada de
# red: dos sesiones de esta máquina jamás llegan las dos al forge.
# Lo que NINGÚN lock local puede cerrar es la carrera entre máquinas distintas
# (o entre dos workspaces): eso lo cierra la reconciliación post-create.
CLAIM_DIR=""    # claim en vuelo. El trap lo suelta salvo que hayamos publicado
CLAIM_PATH=""   # ruta del claim disputado, para poder nombrarla en el mensaje
CLAIM_OWNER=""  # pid que lo tomó, cuando el claim es ajeno
CLAIM_URL=""    # url que dejó el dueño anterior, si alcanzó a publicar

# Un claim solo se suelta si NO publicamos. Si el issue salió, el claim deja de
# ser un lock y pasa a ser rastro: sobrevive al proceso junto al ledger.
trap 'if [ -n "$CLAIM_DIR" ]; then rm -rf "$CLAIM_DIR"; fi' EXIT

# Ojo: estos códigos son INTERNOS de la función y no son los exits del script.
# El caller los traduce: 10 (ajeno vivo) sale 0, 11 con url sale 0, 11 sin url
# sale 9, y 12 sale 10.
claim_take() {  # claim_take <fp> → 0 tomado · 10 ajeno vivo · 11 huérfano · 12 no pude
  local fp="$1" dir err rc lpid=""
  dir="$CLAIMS/$fp.lock.d"
  CLAIM_PATH="$dir"; CLAIM_OWNER=""; CLAIM_URL=""
  if ! mkdir -p "$CLAIMS"; then
    return 12   # el motivo lo imprimió mkdir; tragárselo sería inventar un verde
  fi
  err="$(mkdir "$dir" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$$" > "$dir/pid"
    CLAIM_DIR="$dir"
    return 0
  fi
  # mkdir falló: el caso ESPERADO es que otra sesión lo tenga, pero si el
  # directorio no existe el motivo era otro (permisos, disco) y llamarlo
  # "carrera" sería reportar un choque que no hubo.
  if [ ! -d "$dir" ]; then
    printf '   ↳ mkdir del claim: %s\n' "$err" >&2
    return 12
  fi
  if [ -f "$dir/pid" ]; then lpid="$(cat "$dir/pid")"; else lpid=""; fi
  if [ -z "$lpid" ]; then
    # entre el mkdir del dueño y su escritura del pid pasan microsegundos: una
    # relectura cubre esa ventana en vez de inventarle un estado al claim
    sleep 1
    if [ -f "$dir/pid" ]; then lpid="$(cat "$dir/pid")"; else lpid=""; fi
  fi
  CLAIM_OWNER="$lpid"
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
    return 10
  fi
  if [ -f "$dir/url" ]; then CLAIM_URL="$(cat "$dir/url")"; else CLAIM_URL=""; fi
  return 11
}

claim_seal() {  # claim_seal <url>: el claim ya no es lock, es rastro del issue
  if [ -z "$CLAIM_DIR" ]; then return 0; fi
  local tmp; tmp="$CLAIM_DIR/.url.$$"
  printf '%s\n' "$1" > "$tmp"
  mv "$tmp" "$CLAIM_DIR/url"
  # se vacía SIEMPRE, incluso si la escritura falló: publicamos, y un trap que
  # borre el claim de un issue ya creado reabre la puerta al duplicado
  CLAIM_DIR=""
}

# ── reconciliación post-create (la carrera ENTRE máquinas) ─────────────────
# Dos máquinas no comparten locks; lo único que ven igual es el forge, y ahí el
# número de issue es un orden total compartido (el mismo principio que el claim
# de tickets por comentario: gana quien llegó primero, y "primero" lo dice el
# servidor, no el cliente). Regla: sobrevive el número MENOR. Quien creó el
# mayor cierra el suyo apuntando al superviviente y anota al superviviente como
# el issue del bug.
# La relectura NO usa `--search`: el índice de búsqueda del forge va con
# segundos (a veces minutos) de retraso, que es EXACTAMENTE la ventana de esta
# carrera, así que el rival de hace tres segundos no aparecería. El listado de
# issues es consistente al instante, y traer el cuerpo permite exigir la huella
# literal antes de cerrar nada.
reconcile_after_create() {  # reconcile_after_create <fp> <file> <url-propio>
  local fp="$1" f="$2" mine_url="$3" mine_num list rc surv surv_url msg
  mine_num="${mine_url##*/}"
  case "$mine_num" in
    ''|*[!0-9]*)
      echo "⚠️  no pude leer el número de mi propio issue en '$mine_url': NO reconcilio"
      note "sin número no hay orden que comparar; si hay un duplicado, ciérralo a mano"
      return 0 ;;
  esac
  # El stderr va a un archivo aparte, no a 2>&1: un aviso de gh ("hay una
  # versión nueva") mezclado con el JSON lo volvería imparseable y esta capa
  # declararía "no pude releer" para siempre, sin que nadie sepa por qué.
  local errf; errf="$(mktemp)"
  # --state open a propósito: heredar el hilo de un issue YA CERRADO enterraría
  # un bug vivo detrás de uno que alguien dio por muerto.
  list="$(gh issue list --repo "$UPSTREAM_REPO" --state open \
          --limit "$RECON_LIMIT" --json number,body 2>"$errf")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "⚠️  no pude releer los issues de $UPSTREAM_REPO (gh salió $rc): NO cierro nada"
    note "gh dijo: $(head -3 "$errf" | tr '\n' ' ')"
    note "si otra máquina abrió el mismo bug al mismo tiempo quedan dos issues abiertos, que es el mal MENOR frente a cerrar el equivocado"
    rm -f "$errf"
    return 0
  fi
  surv="$(printf '%s' "$list" | jq -r --arg fp "$fp" --argjson mine "$mine_num" \
     '[ .[] | select(((.body // "") | contains("harness-fp: " + $fp))) | .number | select(. < $mine) ] | min // empty' 2>"$errf")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "⚠️  no pude interpretar la relectura (jq salió $rc): NO cierro nada"
    note "jq dijo: $(head -3 "$errf" | tr '\n' ' ')"
    rm -f "$errf"
    return 0
  fi
  rm -f "$errf"
  if [ -z "$surv" ]; then
    note "reconciliación: ningún issue abierto más viejo con la huella $fp; el mío queda como el issue del bug"
    return 0
  fi
  # Solo se cierra contra un número: cualquier otra cosa que salga de jq es una
  # sorpresa, y una sorpresa no alcanza para cerrar un issue en un repo público.
  case "$surv" in
    ''|*[!0-9]*)
      echo "⚠️  la relectura devolvió algo que no es un número de issue ('$surv'): NO cierro nada"
      return 0 ;;
  esac
  surv_url="https://github.com/$UPSTREAM_REPO/issues/$surv"
  msg="Duplicado de $surv_url: otra instancia del harness abrió el mismo bug (huella \`$fp\`) unos segundos antes."
  msg="$msg Gana el número menor, que es el único orden que las dos máquinas ven igual. Sigo el hilo allá."
  if gh issue close "$mine_num" --repo "$UPSTREAM_REPO" --comment "$msg"; then
    echo "⏭  reconciliado: cierro el mío (#$mine_num) a favor de $surv_url"
    ledger_add "$fp" "$f" "$surv_url" "reconciliado" "$mine_url"
  else
    echo "⚠️  hay un issue más viejo con la misma huella ($surv_url) pero no pude cerrar el mío (#$mine_num): ciérralo a mano"
    ledger_add "$fp" "$f" "$surv_url" "reconciliado-sin-cerrar" "$mine_url"
  fi
}

# ── check ──────────────────────────────────────────────────────────────────
cmd_check() {
  local p="${1:?uso: harness-bug.sh check <ruta-relativa-al-workspace>}"
  p="${p#./}"; p="${p#"$WS"/}"
  [ -e "$WS/$p" ] || die "no existe en el workspace: $p" 1
  local own drift; own="$(owner_of "$p")"; drift="$(drift_of "$p")"
  echo "artefacto: $p"
  echo "propiedad: $own"
  echo "drift:     $drift"
  if [ "$own" = "otro-repo" ]; then
    echo "veredicto: NO reportable ACA: los cronjobs viven en harness-cronjobs"
    note "abri el issue en ese repo. Reportarlo aca lo mandaria al proyecto equivocado, contra una ruta que ya no existe"
    return 3
  fi
  if [ "$own" != "plugin" ]; then
    echo "veredicto: NO reportable upstream (es artefacto de tu instancia)"
    note "arréglalo aquí; si crees que el GENERADOR lo produjo mal, reporta el generador, no el archivo"
    return 3
  fi
  if [ "$drift" = "distinto" ]; then
    echo "veredicto: personalizado localmente: upstream NO lo reproduce tal cual"
    note "reproduce contra el archivo original antes de reportar, o usa --force --justification '<por qué el parche local es irrelevante>'"
    return 7
  fi
  echo "veredicto: reportable (artefacto del plugin$([ "$drift" = igual ] && echo ", idéntico al template"))"
  return 0
}

# ── report ─────────────────────────────────────────────────────────────────
cmd_report() {
  local title="" file="" repro="" impact="" just="" dry=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="${2:-}"; shift 2 ;;
      --file)  file="${2:-}";  shift 2 ;;
      --repro) repro="${2:-}"; shift 2 ;;
      --impact) impact="${2:-}"; shift 2 ;;
      --justification) just="${2:-}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --force)   force=1; shift ;;
      *) die "flag desconocido: $1" 1 ;;
    esac
  done
  [ -n "$title" ]  || die "falta --title" 1
  [ -n "$file" ]   || die "falta --file (el artefacto del harness que falla)" 1
  [ -n "$repro" ]  || die "falta --repro <archivo con el repro mínimo y su salida>" 4
  [ -n "$impact" ] || die "falta --impact (a quién más le pasa; si no le pasa a nadie más, no es upstream)" 1

  enabled || die "reportes upstream deshabilitados en esta instancia (upstream_issues: off)" 8

  file="${file#./}"; file="${file#"$WS"/}"
  [ -e "$WS/$file" ] || die "no existe en el workspace: $file" 1

  # 1 · propiedad y drift (fail-closed)
  local own drift; own="$(owner_of "$file")"; drift="$(drift_of "$file")"
  [ "$own" = "otro-repo" ] && die "$file pertenece a harness-cronjobs, no a este plugin: abri el issue en ese repo" 3
  [ "$own" = "plugin" ] || die "$file es artefacto de tu instancia, no del plugin: no hay bug upstream que reportar" 3
  if [ "$drift" = "distinto" ] && [ "$force" -ne 1 ]; then
    die "$file está personalizado localmente: upstream no lo reproduce tal cual" 7
  fi
  [ "$drift" = "distinto" ] && [ -z "$just" ] && [ "$force" -eq 1 ] && \
    die "--force sobre un archivo con drift exige --justification" 7

  # 2 · repro con contenido (un reporte sin repro es una queja)
  [ -f "$WS/$repro" ] || [ -f "$repro" ] || die "no existe el archivo de repro: $repro" 4
  local repro_path="$repro"; [ -f "$WS/$repro" ] && repro_path="$WS/$repro"
  [ -s "$repro_path" ] || die "el repro está vacío: $repro" 4

  # 3 · fingerprint y dedupe local
  # LC_ALL=C en los dos tr a propósito: GNU tr trabaja byte a byte y BSD tr
  # respeta el locale, así que un título con acentos normalizaba distinto en
  # macOS que en Linux y la MISMA falla daba dos huellas. La reconciliación
  # entre máquinas compara huellas literales: sin esto, jamás matcheaba.
  # Efecto único de la corrección: un título acentuado ya reportado cambia de
  # huella una sola vez, y el dedupe local lo verá como nuevo esa vez.
  local norm fp
  norm="$(printf '%s' "$title" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cs '[:alnum:]' ' ' | awk '{$1=$1};1')"
  fp="$(printf '%s|%s' "$file" "$norm" | sha | cut -c1-12)"
  if [ -f "$LEDGER" ] && grep -q "\"fp\":\"$fp\"" "$LEDGER" 2>/dev/null; then
    local prev; prev="$(grep "\"fp\":\"$fp\"" "$LEDGER" | tail -1 | jq -r '.url // "(sin url)"' 2>/dev/null)"
    echo "⏭  ya reportado (fp $fp): $prev"
    return 0
  fi

  # 4 · cuota diaria (una tormenta de issues automáticos es spam, no señal)
  # La cuota cuenta ISSUES QUE ABRÍ, no filas del ledger. Un solo evento deja
  # varias filas: el `creado` y, si otra máquina ganó la carrera, el
  # `reconciliado` del mismo bug; `recuperado` y `duplicado` ni siquiera
  # abrieron nada. Contarlas todas cobraba el mismo reporte dos y tres veces y
  # cerraba el canal con la cuota a medio gastar.
  if [ -f "$LEDGER" ]; then
    local recent now; now="$(date +%s)"
    recent="$(jq -r --argjson now "$now" 'select((.epoch // 0) > ($now - 86400)) | select((.status // "") == "creado") | .fp' "$LEDGER" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${recent:-0}" -ge "$QUOTA" ]; then
      die "cuota de reportes automáticos agotada ($recent en 24h, tope $QUOTA): junta los hallazgos en UN issue o repórtalo a mano" 5
    fi
  fi

  # 5 · CLAIM sobre la huella, antes de la PRIMERA llamada de red. El orden
  #     importa: el gate de versión de abajo ya consulta al forge, así que un
  #     claim posterior dejaría a las diez sesiones llegando juntas a la red.
  #     Un --dry-run no publica ni toca la red: tomar el claim ahí solo serviría
  #     para bloquear a un reporte de verdad.
  local crc
  if [ "$dry" -eq 0 ]; then
    claim_take "$fp"; crc=$?
    case "$crc" in
      0) : ;;
      10)
        echo "⏭  otra sesión de esta máquina está reportando este mismo bug ahora (fp $fp, pid $CLAIM_OWNER): no duplico"
        return 0 ;;
      11)
        if [ -n "$CLAIM_URL" ]; then
          echo "⏭  ya lo reportó otra sesión de esta máquina (fp $fp): $CLAIM_URL"
          note "el claim quedó huérfano con la url adentro: el issue existe aunque el ledger no lo hubiera anotado"
          ledger_add "$fp" "$file" "$CLAIM_URL" "recuperado"
          return 0
        fi
        # Tercer estado honesto: no es verde (no reportamos) ni rojo (nadie dijo
        # que el reporte esté mal); es "no puedo saber si aquella sesión llegó a
        # publicar", y ante la duda este canal NO publica.
        echo "❌ claim local huérfano sobre la huella $fp: no publico a ciegas" >&2
        note "el proceso que lo tomó (pid ${CLAIM_OWNER:-desconocido}) ya no existe y el claim no guarda url"
        # La ruta va entre comillas simples porque el mensaje es un comando para
        # copiar y pegar: sin ellas, un workspace con espacios convierte el
        # rm -rf en DOS rutas, y una de las dos no es la que se quería borrar.
        note "mira https://github.com/$UPSTREAM_REPO/issues?q=$fp: si no hay ninguno con esa huella, borra el claim (rm -rf '$CLAIM_PATH') y re-corre"
        exit 9 ;;
      *)
        # Otro exit, porque es otro problema con otra remediación: acá el claim
        # no se pudo ni intentar (permisos, disco, .harness/claims ocupado por un
        # archivo). No hay nada que mirar en el forge ni claim que borrar; lo que
        # se arregla es el directorio.
        echo "❌ no pude tomar el claim local sobre la huella $fp: sin claim no hay dedupe, y sin dedupe no publico" >&2
        note "revisa $CLAIMS: tiene que ser un directorio escribible (el motivo exacto lo imprimió mkdir, arriba)"
        exit 10 ;;
    esac
  fi

  # 6 · versión: reportar un bug ya arreglado upstream es la falla más común
  local local_ver up_ver=""
  local_ver="$(cat "$WS/.harness-version" 2>/dev/null | tr -d ' \n')"
  if command -v gh >/dev/null 2>&1 && [ "$dry" -eq 0 ]; then
    up_ver="$(gh api "repos/$UPSTREAM_REPO/contents/.claude-plugin/plugin.json" \
      -H "Accept: application/vnd.github.raw" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
  fi
  if [ -n "$local_ver" ] && [ -n "$up_ver" ] && ver_lt "$local_ver" "$up_ver" && [ "$force" -ne 1 ]; then
    die "tu instancia está en $local_ver y upstream va en $up_ver: actualiza (/harness-update) y re-verifica antes de reportar" 6
  fi

  # 7 · cuerpo, redactado SIEMPRE
  local body os bashv jqv
  os="$(uname -sr 2>/dev/null)"; bashv="${BASH_VERSION:-?}"; jqv="$(jq --version 2>/dev/null)"
  body="$(cat <<EOF
### Qué falla

$title

### Artefacto del harness

\`$file\` (propiedad del plugin; comparación con el template: $drift)
$([ -n "$just" ] && printf '\nJustificación del drift local: %s\n' "$just")
### Repro mínimo (y su salida)

\`\`\`
$(head -c 12000 "$repro_path" | head -120)
\`\`\`

### A quién más le pasa

$impact

### Entorno

- Instancia: \`.harness-version\` = ${local_ver:-desconocida}${up_ver:+ (upstream: $up_ver)}
- OS: ${os:-?} · bash ${bashv} · ${jqv:-jq ausente}

### Verificación previa (determinista, la hizo \`scripts/harness-bug.sh\`)

- Artefacto es propiedad del plugin, no personalización de la instancia: ✅
- Comparación contra el template del plugin: $drift
- Instancia al día contra upstream: $([ -n "$up_ver" ] && { ver_lt "${local_ver:-0}" "$up_ver" && echo "NO (forzado)" || echo "✅"; } || echo "no verificado (sin red)")
- Repro adjunto y no vacío: ✅
- Redacción de secretos aplicada al reporte: ✅

<!-- harness-fp: $fp -->
Levantado automáticamente por el harness (\`scripts/harness-bug.sh\`) desde una instancia instalada.
EOF
)"
  body="$(printf '%s' "$body" | redact)"

  if [ "$dry" -eq 1 ]; then
    echo "── DRY RUN · fp $fp · repo $UPSTREAM_REPO ──"
    echo "título: [harness] $title"
    echo "$body"
    return 0
  fi

  # 8 · publicar (gh es el único canal; sin él, deja el reporte listo a mano)
  command -v gh >/dev/null 2>&1 || die "gh no instalado: no puedo abrir el issue. Cuerpo listo con --dry-run; súbelo a https://github.com/$UPSTREAM_REPO/issues/new" 2
  gh auth status >/dev/null 2>&1 || die "gh sin autenticar (gh auth login): no puedo abrir el issue" 2

  # dedupe remoto: alguien más (u otra máquina tuya) pudo reportarlo ya
  local dup
  dup="$(gh issue list --repo "$UPSTREAM_REPO" --state all --search "$fp" --limit 3 --json url --jq '.[0].url' 2>/dev/null)"
  if [ -n "$dup" ] && [ "$dup" != "null" ]; then
    echo "⏭  ya existe upstream (fp $fp): $dup"
    ledger_add "$fp" "$file" "$dup" "duplicado"
    return 0
  fi

  local tmp url; tmp="$(mktemp)"; printf '%s\n' "$body" > "$tmp"
  url="$(gh issue create --repo "$UPSTREAM_REPO" --title "[harness] $title" \
        --body-file "$tmp" --label bug 2>/dev/null)" \
    || url="$(gh issue create --repo "$UPSTREAM_REPO" --title "[harness] $title" --body-file "$tmp" 2>/dev/null)"
  rm -f "$tmp"
  [ -n "$url" ] || die "gh no pudo crear el issue (¿permisos? ¿issues deshabilitados?)" 2

  # El issue ya existe: el claim guarda la url ANTES que el ledger, porque si el
  # proceso muere en medio la url dentro del claim es lo único que responde
  # "¿aquella sesión llegó a publicar?" a la sesión siguiente.
  claim_seal "$url"
  ledger_add "$fp" "$file" "$url" "creado"
  echo "✅ issue upstream: $url"
  reconcile_after_create "$fp" "$file" "$url"
  [ -f "$WS/scripts/emit.sh" ] && bash "$WS/scripts/emit.sh" decision \
    "bug del harness reportado upstream: $title ($url)" "" "${HARNESS_TASK:-${TASK:-}}" 2>/dev/null
  return 0
}

ledger_add() {  # fp file url estado [issue-propio-que-cedió]
  mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # `url` es SIEMPRE el issue que vale para ese bug: cuando la reconciliación
  # cede ante uno más viejo, la url es la del superviviente y la del propio (ya
  # cerrado) queda en `superseded`, que es historia, no destino.
  jq -nc --arg fp "$1" --arg f "$2" --arg u "$3" --arg st "$4" --arg sup "${5:-}" \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ep "$(date +%s)" \
     '{ts:$ts,epoch:$ep,fp:$fp,file:$f,url:$u,status:$st}
      + (if $sup == "" then {} else {superseded:$sup} end)' >> "$LEDGER" 2>/dev/null || true
}

cmd_list() {
  [ -f "$LEDGER" ] || { echo "sin reportes upstream registrados"; return 0; }
  jq -r '"\(.ts)  \(.status)  \(.file)  \(.url)"' "$LEDGER" 2>/dev/null
}

case "${1:-}" in
  check)  shift; cmd_check "$@" ;;
  report) shift; cmd_report "$@" ;;
  list)   shift; cmd_list "$@" ;;
  *) echo "uso: harness-bug.sh <check|report|list> …" >&2; exit 1 ;;
esac
