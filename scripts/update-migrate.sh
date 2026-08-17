#!/usr/bin/env bash
# update-migrate.sh: las migraciones de esquema del update, ejecutables.
#
# Vivían como PROSA dentro de commands/harness-update.md, y una migración en
# prosa la termina ejecutando un LLM con permisos de escritura sobre una
# instancia real. De ese tramo salieron los incidentes caros del update (un
# número de versión que no existía en ningún origen, un AGENTS.md regenerado
# que borró 70 líneas ajenas). Lo que ya está decidido y documentado no
# necesita juicio: se ejecuta, siempre igual, sin tokens.
#
# LEY DE ESTE SCRIPT: solo aplica transformaciones cuyo resultado está
# DOCUMENTADO en el template (un default, no una preferencia). Todo lo que
# exige ELEGIR se detecta, se reporta con lo que encontró y con la decisión que
# falta, y sale por el tercer estado. Un migrador que inventa el mapeo de un id
# crudo de modelo a un alias fast|smart|deep es exactamente el bug que este
# script vino a matar: se vería igual de verde que el resto.
#
# Uso:
#   update-migrate.sh <workspace> [--dry-run]
#
# Exit (tres estados, como doctor.sh):
#   0  nada que migrar, o migrado (con --dry-run: nada que migrar, o migrable)
#   1  fallo real: había que escribir y no se pudo
#   2  no pude determinar: archivo ausente o ilegible, o una transformación que
#      exige juicio humano. NO es éxito y no se reporta como verde.
# Precedencia: 1 tapa a 2, y 2 jamás se degrada a 0. Silencio y verde no son
# lo mismo, y esa confusión es la que dejó instancias 67 commits atrás
# reportándose sanas.
#
# Portabilidad: bash 3.2 (macOS), awk de BSD, sin sed -i.
set -uo pipefail

uso() {
  echo "uso: update-migrate.sh <workspace> [--dry-run]"
}

WS_ARG=""
DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -h|--help) uso; exit 0 ;;
    -*) echo "❌ opción desconocida: $arg"; uso; exit 1 ;;
    *)
      if [ -z "$WS_ARG" ]; then
        WS_ARG="$arg"
      else
        echo "❌ un solo workspace por corrida (sobra: $arg)"; uso; exit 1
      fi
      ;;
  esac
done
[ -n "$WS_ARG" ] || WS_ARG="."

if [ -d "$WS_ARG" ]; then
  WS="$(cd "$WS_ARG" && pwd)"
else
  echo "⚠️  no pude determinar: '$WS_ARG' no es un directorio accesible"
  echo "   ↳ remediación: pasá la ruta del workspace de la instancia"
  echo "     (update-migrate.sh <workspace>); sin poder mirarlo no sé si hay"
  echo "     algo que migrar, y eso no es ni verde ni rojo"
  exit 2
fi

ANSWERS="$WS/harness-answers.yaml"
MODELS="$WS/models.yaml"

APLICADAS=0
SALTADAS=0
SINDET=0
FALLOS=0

aplicada() {  # aplicada <id> <detalle>
  APLICADAS=$((APLICADAS+1))
  if [ "$DRY" -eq 1 ]; then
    echo "✅ $1: SE APLICARÍA: $2"
    echo "   ↳ dry-run: no escribí nada"
  else
    echo "✅ $1: aplicada: $2"
  fi
}
saltada() {   # saltada <id> <motivo>
  SALTADAS=$((SALTADAS+1))
  echo "➖ $1: saltada: $2"
}
sindet() {    # sindet <id> <motivo> <remediación>
  SINDET=$((SINDET+1))
  echo "⚠️  $1: NO PUDE DETERMINAR: $2"
  echo "   ↳ remediación: $3"
}
rota() {      # rota <id> <motivo> <remediación>
  FALLOS=$((FALLOS+1))
  echo "❌ $1: $2"
  echo "   ↳ remediación: $3"
}

# Escritura atómica. El mktemp va en el MISMO directorio que el destino: un mv
# entre filesystems copia y trunca, y ahí un Ctrl-C deja medio answers escrito,
# que es peor que no migrar. El `cp -p` previo NO es por el contenido (awk lo
# pisa entero): es para heredar el MODO del archivo del usuario, porque mktemp
# crea 0600 y un answers que además cambió de permisos hace dudar de qué más
# tocó el migrador.
aplicar_awk() {  # aplicar_awk <archivo> <programa awk> → 0 ok, 1 no se publicó
  local dst="$1" prog="$2" tmp
  if ! tmp="$(mktemp "$dst.XXXXXX")"; then
    return 1
  fi
  if ! cp -p "$dst" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! awk "$prog" "$dst" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$dst"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

echo "── update-migrate: $WS ──"

# ── 1 · answers: la clave upstream_issues ─────────────────────────────
# El paquete Canal-de-vuelta la exige, y su default está DOCUMENTADO en
# templates/harness-answers.yaml.tmpl (`auto`): eso la hace mecánica. Lo que no
# es mecánico es el consentimiento, así que el script lo DECLARA en su salida
# en vez de esconderlo: es la única acción del harness que publica algo hacia
# afuera, y el humano tiene que poder decir que no (`off`).
ID_UP="answers.upstream_issues"
ID_PROV="answers.models.provider"
ID_ALIAS="answers.models.aliases"

answers_legible=0
if [ -f "$ANSWERS" ]; then
  if [ -r "$ANSWERS" ]; then
    answers_legible=1
  else
    sindet "$ID_UP, $ID_PROV y $ID_ALIAS" "harness-answers.yaml existe pero no puedo leerlo" \
      "revisá permisos (ls -l $ANSWERS); sin leerlo no sé qué claves faltan"
  fi
else
  sindet "$ID_UP, $ID_PROV y $ID_ALIAS" "no hay harness-answers.yaml en $WS" \
    "¿es el workspace de una instancia? si lo es, la generación quedó incompleta: corré /harness-init sobre él; si no, pasá la ruta correcta"
fi

if [ "$answers_legible" -eq 1 ]; then
  if grep -qE '^upstream_issues:' "$ANSWERS"; then
    up_val="$(awk '
      /^upstream_issues:/ {
        sub(/^upstream_issues:[[:space:]]*/, "")
        sub(/[[:space:]]*#.*$/, "")
        print
        exit
      }' "$ANSWERS")"
    case "$up_val" in
      "")
        sindet "$ID_UP" "la clave está pero SIN valor" \
          "escribí 'upstream_issues: auto' (reporta bugs del harness al repo público del plugin) o 'off' (nada sale de esta máquina)"
        ;;
      "{{"*)
        # El placeholder literal es un generador que no sustituyó: si lo
        # pisáramos con el default estaríamos tapando ese fallo, y el resto del
        # archivo probablemente traiga los suyos.
        sindet "$ID_UP" "la clave trae el placeholder literal '$up_val', no una decisión" \
          "la instancia se generó a medias: regenerá con /harness-init . y revisá qué otros {{...}} quedaron"
        ;;
      *)
        saltada "$ID_UP" "ya presente con valor '$up_val': la decisión registrada no se toca"
        ;;
    esac
  else
    if grep -qE '^loop_budget:' "$ANSWERS"; then
      donde="tras loop_budget:"
    else
      donde="al final del archivo (no hay loop_budget: donde anclarla)"
    fi
    prog_up='
      function bloque() {
        print ""
        print "# Canal de vuelta al plugin (lo agregó scripts/update-migrate.sh:"
        print "# esta instancia es anterior a la clave). Cuando un agente tropieza"
        print "# con un bug del HARNESS (no de tu código), lo verifica y levanta un"
        print "# issue en el repo público de harness-creator."
        print "#   auto → reporta solo, tras las verificaciones deterministas"
        print "#   off  → nunca sale nada de esta máquina; el hallazgo va al humano"
        print "# Nunca viajan valores de secretos: el cuerpo se redacta antes de"
        print "# publicar, hay dedupe por fingerprint y cuota de 3 issues por 24h."
        print "upstream_issues: auto"
      }
      { print }
      !hecho && /^loop_budget:/ { bloque(); hecho = 1 }
      END { if (!hecho) bloque() }
    '
    if [ "$DRY" -eq 1 ]; then
      aplicada "$ID_UP" "agregar 'upstream_issues: auto' (default documentado) $donde"
    else
      if aplicar_awk "$ANSWERS" "$prog_up"; then
        aplicada "$ID_UP" "'upstream_issues: auto' (default documentado) $donde"
        echo "   ↳ DECLARALO al humano: con 'auto' el harness publica issues de bugs"
        echo "     DEL HARNESS en el repo público del plugin. Si no lo quiere: 'off'."
      else
        rota "$ID_UP" "no pude publicar el harness-answers.yaml migrado" \
          "revisá permisos de escritura en $WS y espacio en disco; el archivo original quedó INTACTO (mktemp+mv)"
      fi
    fi
  fi

  # ── 2 · answers: models.provider ────────────────────────────────────
  # Mismo criterio: el default `anthropic` está documentado en el template, así
  # que agregarlo no es elegir. Lo que sí sería elegir es cambiarle el proveedor
  # a quien ya declaró uno, y por eso lo presente jamás se pisa.
  if grep -qE '^models:' "$ANSWERS"; then
    prov_val="$(awk '
      /^[^ #]/ { insec = ($1 == "models:") }
      insec && $1 == "provider:" {
        sub(/^[[:space:]]*provider:[[:space:]]*/, "")
        sub(/[[:space:]]*#.*$/, "")
        print
        exit
      }' "$ANSWERS")"
    if [ -n "$prov_val" ]; then
      saltada "$ID_PROV" "ya presente con valor '$prov_val': la decisión registrada no se toca"
    else
      prog_prov='
        { print }
        !hecho && /^models:/ {
          print "  provider: anthropic        # lo agregó update-migrate.sh: default documentado"
          hecho = 1
        }
      '
      if [ "$DRY" -eq 1 ]; then
        aplicada "$ID_PROV" "agregar 'provider: anthropic' (default documentado) bajo models:"
      else
        if aplicar_awk "$ANSWERS" "$prog_prov"; then
          aplicada "$ID_PROV" "'provider: anthropic' (default documentado) bajo models:"
        else
          rota "$ID_PROV" "no pude publicar el harness-answers.yaml migrado" \
            "revisá permisos de escritura en $WS y espacio en disco; el archivo original quedó INTACTO (mktemp+mv)"
        fi
      fi
    fi

    # ── 2b · answers: los valores de models.* son ALIASES ─────────────
    # La cabecera de este script promete que lo que exige ELEGIR se detecta y se
    # reporta. Un answers anterior al esquema de aliases trae ids crudos acá
    # (architect: claude-opus-4-1) y salía VERDE: el migrador ni lo migraba ni
    # lo miraba, que es la peor de las dos combinaciones, porque el update
    # seguía como si el answers estuviera al día. No se mapea, se nombra: en
    # anthropic smart y deep resuelven al mismo id, así que el mapeo inverso
    # id → alias no es una función y elegirlo es juicio.
    # La única clave NO-modelo del bloque models: de
    # templates/harness-answers.yaml.tmpl es provider:, y la migra el paso de
    # arriba; el resto (architect, reviewer, implementer, mechanical,
    # escalation) son roles y hablan en fast|smart|deep.
    no_alias="$(awk '
      /^[^ #]/ { insec = ($1 == "models:") }
      insec && /^  [A-Za-z0-9_-]+:/ {
        k = $1; sub(/:$/, "", k)
        if (k == "provider") next
        v = $0
        sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", v)
        sub(/[[:space:]]*#.*$/, "", v)
        sub(/[[:space:]]*$/, "", v)
        if (v == "fast" || v == "smart" || v == "deep") next
        if (v == "") v = "(sin valor)"
        print k "\t" v
      }' "$ANSWERS")"
    if [ -z "$no_alias" ]; then
      saltada "$ID_ALIAS" "los valores de models.* ya son aliases (fast|smart|deep)"
    else
      sindet "$ID_ALIAS" "el bloque models: del answers trae valor(es) fuera de la whitelist de aliases fast|smart|deep" \
        "elegí CON el humano el alias de cada clave nombrada y escribilo en el answers (los roles hablan en fast|smart|deep; el id concreto lo resuelve models.yaml); después corré este migrador de nuevo. No lo mapeo yo: en anthropic smart y deep resuelven al MISMO id, así que el mapeo inverso id → alias no es una función y elegirlo sería inventar. Si el valor es un placeholder literal {{...}}, la instancia se generó a medias: regenerá con /harness-init ."
      echo "   ↳ claves del answers cuyo valor no es un alias:"
      while IFS="$(printf '\t')" read -r clave valor; do
        if [ -n "$clave" ]; then
          echo "     · models.$clave: '$valor'"
        fi
      done <<EOF
$no_alias
EOF
    fi
  else
    sindet "$ID_PROV y $ID_ALIAS" "el answers no tiene bloque 'models:' donde anclar el proveedor ni valores de rol que auditar" \
      "el esquema del answers es fijo (doctor.sh lo parsea con grep/awk): restituí el bloque models: desde templates/harness-answers.yaml.tmpl con las decisiones que ya estén registradas"
  fi
fi

# ── 3 · models.yaml: esquema de aliases ───────────────────────────────
# Aquí el script se planta. Detecta el esquema viejo (roles con ids crudos, sin
# `provider:` ni secciones `models.<provider>:`) y NO lo migra, porque el mapeo
# inverso id → alias no es una función: en anthropic `smart` y `deep` resuelven
# al MISMO id, así que de un id crudo no se deduce el alias. Elegirlo es juicio,
# y un juicio inventado por un migrador se ve idéntico a uno correcto hasta que
# el agente equivocado corre con el modelo equivocado.
ID_MOD="models.yaml.aliases"
if [ -f "$MODELS" ]; then
  if [ -r "$MODELS" ]; then
    prov_yaml="$(awk '
      /^provider:/ {
        sub(/^provider:[[:space:]]*/, "")
        sub(/[[:space:]]*#.*$/, "")
        print
        exit
      }' "$MODELS")"
    secciones="$(awk '/^models\.[A-Za-z0-9_-]+:/ { n++ } END { print n+0 }' "$MODELS")"
    crudos="$(awk '
      /^[^ #]/ { insec = ($1 == "roles:") }
      insec && /^  [A-Za-z0-9_-]+:/ {
        k = $1; sub(/:$/, "", k)
        v = $0
        sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", v)
        sub(/[[:space:]]*#.*$/, "", v)
        if (v == "") next
        if (v == "fast" || v == "smart" || v == "deep") next
        print k "\t" v
      }' "$MODELS")"

    faltantes=""
    if [ -z "$prov_yaml" ]; then
      faltantes="$faltantes sin 'provider:';"
    fi
    if [ "$secciones" -eq 0 ]; then
      faltantes="$faltantes sin secciones 'models.<provider>:';"
    fi
    if [ -n "$crudos" ]; then
      faltantes="$faltantes roles con ids crudos;"
    fi

    if [ -z "$faltantes" ]; then
      saltada "$ID_MOD" "ya está en el esquema de aliases (provider: $prov_yaml, $secciones sección(es) models.<provider>, roles en fast|smart|deep)"
    else
      sindet "$ID_MOD" "models.yaml en esquema viejo:$faltantes la parte mecánica la hice (detectar y nombrar), la que falta es una DECISIÓN" \
        "decidí el alias de cada rol con el humano y escribí el esquema nuevo (provider: + secciones models.<provider>: + roles en aliases) copiando la forma de templates/models.yaml.tmpl del plugin; después verificá con 'bash scripts/stamp-models.sh check'. No lo mapeo yo: en anthropic smart y deep resuelven al mismo id, así que el mapeo inverso no es una función y elegirlo sería inventar"
      if [ -n "$crudos" ]; then
        echo "   ↳ roles que traen un id crudo (no es un alias fast|smart|deep):"
        while IFS="$(printf '\t')" read -r rol valor; do
          if [ -n "$rol" ]; then
            echo "     · roles.$rol: '$valor'"
          fi
        done <<EOF
$crudos
EOF
      else
        echo "   ↳ los roles ya hablan en aliases: falta el encabezado (provider y secciones)"
      fi
    fi
  else
    sindet "$ID_MOD" "models.yaml existe pero no puedo leerlo" \
      "revisá permisos (ls -l $MODELS); sin leerlo no sé si trae el esquema viejo"
  fi
else
  sindet "$ID_MOD" "no hay models.yaml en $WS" \
    "toda instancia lo tiene (es LA perilla de modelos): si falta, la generación quedó incompleta y lo trae /harness-init sobre el workspace"
fi

# ── 4 · .serena/project.yml: la config sin la cual Serena ignora TODO ─
# (#214) Es mecánica de punta a punta: el contenido sale de inventory.json y lo
# escribe discover.sh, sin una sola decisión que consultar. Va acá y no en el
# doctor porque un update que solo AVISA deja la instancia rota igual, y esta
# rota barato: get_symbols_overview falla sobre el 100% del código y cada
# pregunta cae al Read del archivo entero (46.450 tokens medidos en uno).
ID_SER="serena.project_yml"
SERENA_YML="$WS/.serena/project.yml"
DISCOVER="$(cd "$(dirname "$0")" && pwd)/discover.sh"

serena_ciega=0
if [ ! -f "$SERENA_YML" ]; then
  serena_ciega=1
elif grep -qE '^ignore_all_files_in_gitignore: *true' "$SERENA_YML" 2>/dev/null; then
  # El que escribió Serena sola en el primer arranque: autodetectó [bash] desde
  # la raíz del workspace y heredó el .gitignore, donde vive repos/.
  serena_ciega=1
fi

if [ ! -d "$WS/repos" ]; then
  # Sin repos/ no hay lenguajes que declarar NI ceguera que arreglar: el bug es
  # que Serena no ve lo que hay bajo repos/. No es "no pude determinar", que
  # frenaría el update entero por una migración que acá no aplica.
  saltada "$ID_SER" "no hay repos/ en $WS: no hay código bajo el .gitignore que Serena pueda ignorar"
elif [ ! -x "$DISCOVER" ]; then
  sindet "$ID_SER" "no encuentro discover.sh junto a este script ($DISCOVER)" \
    "corré la migración desde el plugin instalado, o generá el archivo con /harness-init ."
elif [ "$serena_ciega" -eq 0 ]; then
  saltada "$ID_SER" "ya hay .serena/project.yml sin heredar el .gitignore"
elif [ "$DRY" -eq 1 ]; then
  aplicada "$ID_SER" "escribiría .serena/project.yml desde el inventario (hoy Serena no ve repos/, que está gitignoreado)"
elif "$DISCOVER" "$WS" >/dev/null 2>&1 && [ -f "$SERENA_YML" ]; then
  aplicada "$ID_SER" "$(sed -n 's/^language_servers: *//p' "$SERENA_YML" | head -1): antes Serena ignoraba repos/ entero"
  grep -q '^# OMITIDOS' "$SERENA_YML" \
    && echo "   ↳ hay language servers omitidos por falta de binario (los lista $SERENA_YML): uno que no arranca bloquea a TODOS, por eso quedan afuera"
else
  rota "$ID_SER" "discover.sh no pudo escribir .serena/project.yml" \
    "corrélo a mano y mirá su salida: $DISCOVER $WS"
fi

echo "── resultado: $APLICADAS aplicada(s), $SALTADAS sin cambios, $SINDET sin determinar, $FALLOS con fallo ──"
if [ "$FALLOS" -gt 0 ]; then
  echo "   el update NO puede seguir como si esto hubiera pasado: arreglá el fallo y volvé a correr"
  exit 1
fi
if [ "$SINDET" -gt 0 ]; then
  echo "   exit 2: hay migraciones sin resolver. NO es éxito: resolvelas con el humano antes de cerrar el update"
  exit 2
fi
exit 0
