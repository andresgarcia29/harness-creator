#!/usr/bin/env bash
# harness-version.sh: ¿estoy al día, y qué está pasando en este workspace?
#
# Dos preguntas que se hacen juntas y hasta ahora no tenían dónde hacerse:
# la versión vive en `.harness-version`, el estado en `tasks/*/state.json`,
# las sesiones en el bus, y los worktrees tomados en `.harness/claims/`. Para
# saber si conviene actualizar había que leer cuatro lugares a mano.
#
# LEY DE ESTE SCRIPT: OBSERVA, no toca nada. Sale 0 siempre en el modo
# normal, incluso roto: un chequeo de versión que puede frenar tu trabajo es
# un bug, no una feature. La excepción declarada es `--check`, cuyo contrato
# ES el exit code (0 al día, 1 desactualizado, 2 no se pudo comparar).
#
# Y LO MÁS IMPORTANTE, que es la lección que este harness pagó caro:
# "no pude averiguar la versión de upstream" NO se reporta como "estás al
# día". Silencio y verde no son lo mismo.
#
# CONTRA QUÉ SE COMPARA: contra el último TAG de upstream, no contra su rama
# por defecto. La rama se mueve con cada commit, así que comparar contra ella
# reporta "hay update" por trabajo que todavía no se publicó, y peor: el número
# que trae puede no corresponder a ningún set de templates publicado. Un tag es
# inmutable y es lo que el marketplace instala. Si upstream no tiene NINGÚN
# tag se cae a la rama por defecto y se DICE, porque entonces la comparación
# vale menos y quien la lee tiene que saberlo.
#
# Uso:
#   scripts/harness-version.sh            todo: versión + sesión + trabajo
#   scripts/harness-version.sh --check    solo el veredicto, por exit code
#   scripts/harness-version.sh --quiet    solo versión y set de templates
#   scripts/harness-version.sh --verify   DESPUÉS de actualizar: ¿aterrizó?
#   scripts/harness-version.sh --generator  ANTES de generar: ¿el binario del
#                                           tap corresponde a un tag publicado?
set -u

WS="$(cd "$(dirname "$0")/.." && pwd)"
# Mismo patrón que harness-bug.sh: env con default, no un placeholder
# que alguien tenga que acordarse de sustituir.
UPSTREAM_REPO="${HARNESS_UPSTREAM_REPO:-andresgarcia29/harness-creator}"
# El plugin EN DISCO: la fuente real de la que un update copia. Claude Code lo
# exporta como CLAUDE_PLUGIN_ROOT dentro de los comandos.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${HARNESS_PLUGIN_ROOT:-}}"

# ── LA RUTA SE RESUELVE, NO SE ESPERA QUE ALGUIEN LA EXPORTE (#194) ────
# `CLAUDE_PLUGIN_ROOT` lo exporta Claude Code DENTRO de sus comandos. Un humano
# que corre `bash scripts/harness-version.sh --verify` desde su shell no la
# tiene, y eso es exactamente lo que el paso 6 de /harness-update le manda
# hacer. Consecuencia medida: el chequeo archivo por archivo (el ÚNICO que caza
# "el número quedó bien y el CONTENIDO no") estaba apagado justo en la
# invocación que el playbook prescribe.
#
# Lo caro no es el chequeo que no corre: es lo que deja pasar. En una instancia
# real, `.harness-version` decía 0.61.8 y `.harness-templates` traía el digest
# EXACTO de v0.61.8, y sin embargo bootstrap.sh era el template de v0.61.5
# instanciado, deploy-watch.sh el de v0.61.4 y secrets.sh anterior a v0.49.0.
# Los tres son `.tmpl`, o sea los únicos que el fallback manual del update
# INSTANCIA en vez de copiar, así que se saltearon update tras update mientras
# la instancia se reportaba al día por los dos ejes que sí miraba.
#
# Se prueban las rutas conocidas, y cada candidata se valida por su CONTENIDO
# (su `templates/MANIFEST.sha256`), no por llamarse como esperamos: un
# directorio con el nombre correcto y sin templates adentro no es el plugin, y
# creerle sería el mismo silencio con otra cara.
es_plugin() {  # es_plugin <dir> → 0 si ahí vive un plugin del harness
  [ -n "${1:-}" ] && [ -f "$1/templates/MANIFEST.sha256" ] && [ -d "$1/templates" ]
}
if ! es_plugin "$PLUGIN_ROOT"; then
  PLUGIN_ROOT=""
  # El marketplace se llama `harness` (.claude-plugin/marketplace.json) y Claude
  # Code lo deja bajo marketplaces/ y cache/. El clon del workspace va último:
  # es el menos canónico, pero en una instancia que se instaló desde el clon es
  # el único que hay.
  for _c in \
    "$HOME/.claude/plugins/marketplaces/harness" \
    "$HOME/.claude/plugins/cache/harness" \
    "$HOME/.claude/plugins/marketplaces/harness/harness-creator" \
    "$HOME/.claude/plugins/cache/harness/harness-creator" \
    "$WS/harness-creator" \
    "$WS/../harness-creator"; do
    if es_plugin "$_c"; then PLUGIN_ROOT="$(cd "$_c" && pwd)"; break; fi
  done
  unset _c
fi
# El generador del tap. Se nombra por variable y no a pelo porque el propio
# playbook avisa de "otro binario que se llame igual": apuntarlo es la forma de
# comprobar EL que se va a usar, y no el primero que aparezca en el PATH.
GENERATOR_BIN="${HARNESS_GENERATOR_BIN:-harness}"
# ── EL BINARIO NO SE VERSIONA DONDE SE VERSIONAN LOS TEMPLATES (#118) ──
# `--generator` comparaba la versión del BINARIO contra los tags de
# harness-creator, y el binario no se publica desde ahí: la fórmula del tap que
# el propio playbook manda instalar (`brew install andresgarcia29/agm/harness`)
# empaqueta un release de harness-daemon, que lleva SU PROPIA línea de
# versiones. O sea que se comparaban dos ejes independientes.
#
# Efecto medido: un generador legítimo y al día (0.60.0, tag real de
# harness-daemon) se declaraba "esa versión NO EXISTE upstream (último tag:
# 0.59.9) ... Es exactamente el incidente 0.60.0", el paso 2 de /harness-update
# quedaba cerrado, y TODO update caía al fallback 2b: la re-instanciación
# manual por un LLM, que el propio playbook llama el camino más riesgoso. Y el
# mensaje afirmaba con seguridad algo falso, porque el número coincidía por
# casualidad con el del incidente histórico.
#
# La pregunta que el chequeo quiere hacer sigue siendo la misma ("¿este binario
# corresponde a algo PUBLICADO, o alguien escribió un número?"), solo que hay
# que hacérsela al repo donde ese binario se publica.
GENERATOR_REPO="${HARNESS_GENERATOR_REPO:-andresgarcia29/harness-daemon}"
MODE=full
case "${1:-}" in
  --check)     MODE=check ;;
  --quiet)     MODE=quiet ;;
  --verify)    MODE=verify ;;
  --generator) MODE=generator ;;
  "")          MODE=full ;;
  *) echo "uso: harness-version.sh [--check|--quiet|--verify|--generator]"; exit 1 ;;
esac

ver_lt() {  # ver_lt <a> <b> → 0 si a < b (semver simple, sin pre-releases)
  awk -v a="$1" -v b="$2" 'BEGIN{
    na=split(a,x,"."); nb=split(b,y,".")
    n = na>nb ? na : nb
    for(i=1;i<=n;i++){ xi=x[i]+0; yi=y[i]+0
      if(xi<yi) exit 0
      if(xi>yi) exit 1 }
    exit 1}'
}

# ── 0 · ¿contra qué punto de upstream comparo? ────────────────────────
# El último tag semver. Se ordena acá y no se confía en el orden del API:
# /tags devuelve por fecha de creación, y un tag de arreglo publicado tarde
# sobre una versión vieja quedaría primero.
#
# La LISTA entera se guarda, no solo el último: `--generator` no pregunta "¿cuál
# es el más nuevo?" sino "¿esta versión EXISTE?", y son preguntas distintas. Una
# sola llamada al API para las dos.
tags_de() {  # tags_de <owner/repo> → "<version>\t<tag>" por línea, de vieja a nueva
  command -v gh >/dev/null 2>&1 || return 0
  gh api "repos/$1/tags" --paginate --jq '.[].name' 2>/dev/null \
    | awk '{ v=$0; sub(/^v/,"",v); if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) print v"\t"$0 }' \
    | sort -t. -k1,1n -k2,2n -k3,3n
}

UP_TAG=""
UP_TAGS=""
if command -v gh >/dev/null 2>&1; then
  UP_TAGS="$(tags_de "$UPSTREAM_REPO")"
  UP_TAG="$(printf '%s\n' "$UP_TAGS" | tail -1 | cut -f2)"
fi
# El tag SIN la `v`: `UP_TAG` es el ref que consume `gh_raw` (y lleva el prefijo
# tal cual lo publica upstream), pero comparar VERSIONES con él haría que
# `0.59.3` nunca igualara a `v0.59.3`. Dos nombres porque son dos cosas.
UP_TAG_VER="$(printf '%s\n' "$UP_TAGS" | tail -1 | cut -f1)"
UP_WHERE="tag ${UP_TAG:-}"
[ -n "$UP_TAG" ] || UP_WHERE="rama por defecto (upstream no publica tags)"

gh_raw() {  # gh_raw <ruta> → el archivo tal cual, en el ref elegido
  local q=""
  [ -n "$UP_TAG" ] && q="?ref=$UP_TAG"
  gh api "repos/$UPSTREAM_REPO/contents/$1$q" -H "Accept: application/vnd.github.raw" 2>/dev/null
}

# La version en la rama por defecto. Solo se consulta para desempatar el caso
# "la instancia va adelante del ultimo tag", que tiene dos causas opuestas: una
# instancia generada desde un main sin taggear (normal) o un numero escrito de
# memoria (el bug de 0.60.0). Distinguirlas cuesta una llamada, en una rama rara.
gh_head_ver() {
  command -v gh >/dev/null 2>&1 || return 0
  gh api "repos/$UPSTREAM_REPO/contents/.claude-plugin/plugin.json" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true
}

# ── 0b · EL GENERADOR: ¿su versión existe en algún origen? (#102) ─────
# El paso 2 de /harness-update PREFIERE el binario `harness` del tap sobre la
# re-instanciación manual, y con razón: es determinista. Pero el binario trae su
# propia copia de los templates y su propio número, y nada comprobaba que ese
# número correspondiera a algo publicado.
#
# CASO DE CAMPO: el binario del tap reportaba 0.60.0 con el último tag y el
# último release de upstream en 0.59.3, o sea una versión que no existe en
# NINGÚN origen. Generar con él habría escrito templates no publicados, el paso
# 5 habría estampado ese número en `.harness-version`, y el `--verify` posterior
# habría salido rojo contra el último tag SIN explicar por qué. Es el incidente
# 0.60.0 que el propio playbook cita como uno de los tres más caros.
#
# En esa instancia no llegó a pasar porque el binario murió antes, rechazando la
# clave `gcp:` de un answers perfectamente válido (el esquema embebido era otro).
# O sea que el segundo síntoma tapó al primero: los dos salen de lo mismo, un
# generador que no corresponde a la versión publicada, y los dos los ataja esta
# única pregunta hecha ANTES de escribir nada.
#
# Hasta acá la única defensa era que el humano comparara a mano, y el playbook
# tenía que dedicarle tres párrafos a pedirlo. Un chequeo que depende de que
# alguien se acuerde no es un chequeo.
generador_dice() {  # → la versión que reporta el binario, o vacío
  local out=""
  command -v "$GENERATOR_BIN" >/dev/null 2>&1 || return 0
  # Las dos formas: no se adivina cuál habla este binario, se prueban.
  out="$("$GENERATOR_BIN" --version 2>/dev/null || true)"
  [ -n "$out" ] || out="$("$GENERATOR_BIN" version 2>/dev/null || true)"
  # El sufijo entra a propósito (`0.60.0-rc1`): distinguir un pre-release de un
  # tag publicado es justo lo que el reporte pide poder hacer.
  printf '%s' "$out" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -1
}

generador_check() {  # → 0 autorizado · 1 NO generar con él · 2 no pude comprobarlo
  local ver="" gen_tags="" gen_last=""
  if ! command -v "$GENERATOR_BIN" >/dev/null 2>&1; then
    echo "ℹ️  generador: no hay binario \`$GENERATOR_BIN\` en el PATH."
    echo "   No es un error: el camino es la re-instanciación manual (paso 2b),"
    echo "   que se DECLARA como tal para que quien lea el resultado sepa que"
    echo "   lo produjo un LLM y no el generador."
    return 2
  fi
  ver="$(generador_dice)"
  if [ -z "$ver" ]; then
    echo "⚠️  generador: el binario \`$GENERATOR_BIN\` no dice qué versión es."
    echo "   Sin ese número no se puede saber qué vintage de templates embebe,"
    echo "   así que no hay nada que autorizar: andá al paso 2b y declaralo."
    return 2
  fi
  # Los tags del repo donde se PUBLICA EL BINARIO, que no es el de los
  # templates (#118). Se piden acá y no arriba porque solo este modo los usa:
  # una llamada de red más en cada `make version` sería pagar por una pregunta
  # que nadie hizo.
  gen_tags="$(tags_de "$GENERATOR_REPO")"
  gen_last="$(printf '%s\n' "$gen_tags" | tail -1 | cut -f1)"
  if [ -z "$gen_tags" ]; then
    echo "⚠️  generador $ver: no pude traer los tags de $GENERATOR_REPO para comparar."
    echo "   Esto NO es una autorización: es una comprobación que no corrió."
    echo "   (¿gh sin auth, sin red?) Andá al paso 2b y declaralo."
    return 2
  fi
  if ! printf '%s\n' "$gen_tags" | cut -f1 | grep -qxF "$ver"; then
    # Las dos formas de no existir se separan porque la remediación difiere.
    case "$ver" in
      *[!0-9.]*)
        echo "❌ generador $ver: es un PRE-RELEASE, no un tag publicado."
        echo "   Un pre-release puede traer templates que todavía no existen en"
        echo "   ningún origen. Si querés usarlo, es una decisión declarada, no"
        echo "   el camino por defecto de un update." ;;
      *)
        echo "❌ generador $ver: esa versión NO EXISTE en $GENERATOR_REPO (último tag: ${gen_last:-?})."
        echo "   Un binario no puede ir adelante de su origen: ese número no se"
        echo "   leyó de ningún lado. Generar con él escribiría templates NO"
        echo "   publicados y el paso 5 estamparía ese número en .harness-version,"
        echo "   con lo que el --verify posterior saldría rojo sin explicar por qué."
        echo "   Es exactamente el incidente 0.60.0." ;;
    esac
    echo "   ↳ NO generes con este binario: andá al paso 2b (re-instanciación"
    echo "     manual) y declaralo, o actualizá el tap y volvé a correr esto."
    return 1
  fi
  if [ "$ver" != "$gen_last" ]; then
    echo "❌ generador $ver: es un tag publicado de $GENERATOR_REPO, pero NO el último (${gen_last:-?})."
    echo "   Sus templates son más viejos que lo que upstream publica, así que"
    echo "   generar con él produce una instancia vieja... que va a reportar"
    echo "   éxito igual, y estampar un número que dice que está al día."
    echo "   ↳ actualizá el tap (brew upgrade harness) y volvé a correr esto."
    return 1
  fi
  echo "✅ generador $ver: es el último tag publicado de $GENERATOR_REPO, podés generar con él"
  return 0
}

if [ "$MODE" = "generator" ]; then
  generador_check
  exit $?
fi

# ── 1 · versión ───────────────────────────────────────────────────────
local_ver="$(cat "$WS/.harness-version" 2>/dev/null | tr -d ' \n' || true)"
up_ver=""
up_why=""
if command -v gh >/dev/null 2>&1; then
  up_ver="$(gh_raw ".claude-plugin/plugin.json" | jq -r '.version // empty' 2>/dev/null || true)"
  [ -n "$up_ver" ] || up_why="gh no devolvió la versión (¿sin auth, sin red?)"
else
  up_why="gh no está instalado"
fi

verdict=2   # 0 al día · 1 hay update · 2 no se pudo comparar
if [ -z "$local_ver" ]; then
  line="⚠️  esta instancia no declara versión (falta .harness-version)"
elif [ -z "$up_ver" ]; then
  # NO se dice "al día": no se pudo comparar, y decirlo verde sería mentir.
  line="⚠️  instancia $local_ver · NO pude comparar contra upstream: $up_why"
elif ver_lt "$local_ver" "$up_ver"; then
  verdict=1
  line="⬆️  instancia $local_ver · upstream $up_ver ($UP_WHERE): HAY UPDATE"
elif ver_lt "$up_ver" "$local_ver" && [ "$(gh_head_ver)" = "$local_ver" ]; then
  # Adelantado del ultimo TAG, pero exactamente igual a lo que hay en la rama
  # por defecto: no es un numero inventado, es una instancia generada desde un
  # main que todavia no se taggeo. Se dice, y no se marca update: no hay nada
  # publicado a lo que ir.
  line="✅ instancia $local_ver · último tag $up_ver: al día (generada desde main sin taggear)"
  verdict=0
elif ver_lt "$up_ver" "$local_ver"; then
  # UNA INSTANCIA NO PUEDE IR ADELANTE DE SU ORIGEN. Si dice una version mayor
  # que la de upstream, ese numero no salio de ningun lado: lo escribio alguien
  # (o algun agente) de memoria. Antes esto caia en el `else` de abajo y se
  # reportaba "✅ al día", que es la peor lectura posible.
  #
  # CASO REAL: una instalacion escribio `0.60.0` en .harness-version. Esa
  # version no existe en el plugin (0.45.2 / 0.47.0 / 0.48.0) y por CONTENIDO
  # estaba mas de sesenta commits atras. `make version` decia "al día" mientras
  # los gates de lenguaje ni compilaban. La causa: la tabla del instalador pedia
  # "version del plugin" sin decir de donde leerla.
  verdict=1
  line="❗ instancia $local_ver · upstream $up_ver: la instancia dice una versión MAYOR que su origen"
  extra_ver="   Eso es imposible: nadie publica hacia atrás. Ese número no se leyó de
   ningún lado, se escribió. No te fíes de él para nada, y mirá el digest de
   templates de abajo, que compara CONTENIDO y no se puede inventar.
   ↳ se arregla regenerando con /harness-init . (lee la versión de plugin.json)"
else
  verdict=0
  line="✅ instancia $local_ver · upstream $up_ver: al día"
fi

echo "$line"
[ -n "${extra_ver:-}" ] && echo "$extra_ver"

# ── 1b · el SET de templates que realmente generó esta instancia ──────
# El número de versión NO alcanza, y esto se aprendió caro: un generador
# escribió `.harness-version` con la versión nueva habiendo generado desde
# templates viejos. Los 24 conflictos que produjo no traían ninguno de los
# arreglos que el número prometía, y nada en la salida lo decía.
#
# El digest compara CONTENIDO: es el sha256 del set completo de templates,
# publicado en templates/MANIFEST.sha256 de upstream. Un generador honesto
# escribe el suyo en `.harness-templates` al generar. Si no está, no es un
# detalle cosmético: significa que el generador no puede decir con qué set
# trabajó, y entonces nadie puede saber qué tiene esta instancia.
# ── EL MARCADOR SE NORMALIZA, NO SE SUPONE ────────────────────────────
# `templates/MANIFEST.sha256` termina con la linea `digest: <hash>`, y la tabla
# de generacion pide escribir "el digest: de MANIFEST.sha256". Eso se lee de dos
# formas: el VALOR, o la LINEA entera. Antes solo se aceptaba una (`tr -d ' \n'`
# y comparar contra el hash pelado), asi que una instancia cuyo generador
# escribio `digest: abc...` quedaba en `digest:abc...` y NUNCA igualaba: `make
# version` reportaba drift para siempre sobre una instancia perfectamente al
# dia. Reproducido con dos instancias identicas.
#
# Es el peor sitio posible para un falso rojo: esta comprobacion existe para que
# un update no pueda mentir, y mintiendo ella enseña a ignorar el aviso.
# Se aceptan las dos formas y se exige que lo que quede sea un sha256 de verdad;
# cualquier otra cosa es un marcador ILEGIBLE, que no es lo mismo que drift.
read_digest() {  # read_digest <archivo> → sha256 en minusculas, o vacio
  sed -n 's/^[[:space:]]*\(digest:[[:space:]]*\)\{0,1\}\([0-9a-fA-F]\{64\}\).*$/\2/p' \
    "$1" 2>/dev/null | head -1 | tr 'A-Z' 'a-z'
}
local_tpl="$(read_digest "$WS/.harness-templates")"
tpl_raw="$(cat "$WS/.harness-templates" 2>/dev/null | tr -d ' \n' || true)"
up_tpl=""
if command -v gh >/dev/null 2>&1; then
  up_tpl="$(gh_raw "templates/MANIFEST.sha256" | sed -n 's/^digest: *//p' | head -1 || true)"
fi

if [ -z "$local_tpl" ] && [ -n "$tpl_raw" ]; then
  # El archivo existe pero no trae un sha256. NO es drift: es un marcador roto,
  # y decir "distintos" mandaria a regenerar por la razon equivocada.
  echo "⚠️  .harness-templates existe pero no contiene un digest legible"
  echo "   (leído: '$(printf '%.40s' "$tpl_raw")')."
  echo "   Se esperan 64 caracteres hex, con o sin el prefijo 'digest: '."
  echo "   ↳ se arregla regenerando con /harness-init . , o escribiendo a mano"
  echo "     el digest que publica templates/MANIFEST.sha256 de upstream."
  [ "$verdict" -eq 0 ] && verdict=1
elif [ -z "$local_tpl" ]; then
  echo "⚠️  esta instancia NO declara con qué set de templates se generó"
  echo "   (falta .harness-templates). Quien la generó no dejó rastro de su"
  echo "   fuente, así que el número de versión de arriba no se puede creer:"
  echo "   puede decir 'al día' y tener templates de hace cinco versiones."
  echo "   ↳ se arregla regenerando con /harness-init . (deja el rastro)"
  [ "$verdict" -eq 0 ] && verdict=1
elif [ -z "$up_tpl" ]; then
  echo "⚠️  templates $(printf '%.12s' "$local_tpl") · no pude traer el manifiesto de upstream para comparar"
elif [ "$local_tpl" = "$up_tpl" ]; then
  echo "✅ templates $(printf '%.12s' "$local_tpl"): idénticos a upstream"
else
  echo "⬆️  templates $(printf '%.12s' "$local_tpl") · upstream $(printf '%.12s' "$up_tpl"): DISTINTOS"
  echo "   El contenido difiere aunque el número de versión coincida. Esto es"
  echo "   exactamente lo que produce un update que reporta éxito sin traer"
  echo "   los arreglos: regenerá antes de confiar en esta instancia."
  verdict=1
fi

[ "$MODE" = "quiet" ] && exit 0
if [ "$MODE" = "check" ]; then exit "$verdict"; fi

# ── 1b2 · el generador instalado, si lo hay ───────────────────────────
# Se dice acá y no solo bajo `--generator` porque el reporte del #102 lo pedía
# sin saberlo: la instancia estaba al día en número y digest, y aun así el
# update iba a correr con un binario 0.60.0. Este script es el lugar donde
# alguien ya viene a preguntar "¿estoy al día?", y el generador es parte de la
# respuesta. Silencio si no hay binario: no todo el mundo lo tiene, y un aviso
# por algo que no está instalado es ruido.
if [ "$MODE" = "full" ] && command -v "$GENERATOR_BIN" >/dev/null 2>&1; then
  generador_check || true
fi

# ── 1c0 · LA COMPARACIÓN ARCHIVO POR ARCHIVO ──────────────────────────
# POR QUÉ HACE FALTA, y es un hueco del propio verificador: el chequeo de
# templates de más abajo compara el string que el UPDATE escribió en
# `.harness-templates` contra el digest del MANIFEST del tag. O sea confirma
# "copié del set correcto", que es lo que el update DECLARA, no "cada archivo
# de la instancia coincide con ese set". Es autoatestación: solo caza al que se
# olvida de mentir consistente, y el modo de falla que el mensaje anuncia
# atrapar ("el número quedó bien y el CONTENIDO no") es justo el que la
# autoatestación no puede atrapar, porque el número ES la declaración.
#
# Medido en campo: `docs/harness/pipeline.md` estuvo SEMANAS congelado en una
# versión vieja con `--verify` en verde, y lo encontró un humano comparando a
# mano. Un verificador que se pierde eso no verifica: acompaña.
#
# CÓMO, sin inventar un mapeo que no existe: qué template aterriza en qué ruta
# de la instancia lo sabe el generador, no este repo. Así que no se deduce, se
# BUSCA por nombre de archivo dentro del workspace (podando repos/, worktrees/
# y demás ruido). Cero candidatos o más de uno = no se puede afirmar nada, y se
# cuenta aparte: "no pude comprobarlo" jamás se disfraza de verde.
#
# Y hay DOS clases de archivo, que no se pueden verificar igual:
#   · copiado tal cual (los que no terminan en .tmpl) → sha256 exacto contra el
#     manifiesto. Una diferencia es una diferencia.
#   · renderizado (.tmpl) → su sha JAMÁS va a coincidir, porque el generador
#     sustituye `{{CLAVE}}` con las respuestas del answers, y una sola clave
#     puede expandirse a muchas líneas (medido: `secrets.sh` diverge 162 líneas
#     por expansión de listas, y es correcto). Hashearlos sería una máquina de
#     falsos rojos, y un verificador que grita con un archivo legítimo es un
#     verificador que alguien apaga: peor que el hueco. Lo que SÍ vale para
#     ellos: toda línea del template que NO tiene placeholder tiene que estar
#     en el archivo de la instancia. Si el template ganó secciones que la
#     instancia no tiene, está atrasada. Es exactamente lo que se encontró a
#     mano con pipeline.md, hecho por máquina.
#
# ROJO solo donde la propiedad es del PLUGIN (scripts, hooks, comandos,
# agentes, settings, policy y las skills upstream): ahí una diferencia es
# siempre drift. En lo compartido (docs, README, los mapas) se AVISA con el
# archivo nombrado y no se pone rojo, porque lo local puede ganar legítimamente
# (/harness-update lo clasifica así). Avisar ya es todo lo que faltaba: nadie
# sabía que pipeline.md estaba congelado.
sha_de() {  # sha_de <archivo> → sha256, portable macOS/Linux
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else sha256sum "$1" 2>/dev/null | awk '{print $1}'; fi
}

# ── UN JSON NO SE COMPARA POR LÍNEAS ─────────────────────────────────
# Falso positivo medido en campo: `.claude/settings.json` con los 17 hooks
# registrados y CORRIENDO, reportado como 17 líneas ausentes. La causa no es
# drift: es que el archivo pasó por un re-serializador (Claude Code reescribe
# settings.json cuando cambian permisos), y `{ "type": "command", ... }` en una
# línea del template queda en cuatro en la instancia. Byte a byte todo cambió;
# semánticamente no cambió NADA.
#
# Eso no es un detalle cosmético: un verificador que grita con un archivo
# legítimo es un verificador que alguien apaga, que es peor que el hueco. Este
# archivo ya declara ese principio para los .tmpl; los JSON tenían el mismo
# problema por otra vía.
#
# Se compara por HOJAS (`ruta=valor`), no por líneas, y la ruta va SIN los
# índices de array a propósito: agregar un hook local al principio no puede
# correr todo lo demás y convertirlo en drift. La propiedad que se verifica es
# la misma que para los .tmpl, dicha en la estructura en vez de en el texto:
# todo lo que el template declara tiene que estar en la instancia. Lo que la
# instancia agregue de más es suyo, como siempre.
json_hojas() {  # stdin: JSON → "ruta-sin-índices=valor" por línea, ordenado
  jq -r 'paths(scalars) as $p
         | "\([$p[] | select(type == "string")] | join("."))=\(getpath($p) | tostring)"' \
    2>/dev/null | sort -u
}

json_faltan() {  # json_faltan <template> <instancia> → nº de hojas ausentes; 1 si no se puede
  command -v jq >/dev/null 2>&1 || return 1
  jq -e . "$2" >/dev/null 2>&1 || return 1     # instancia ilegible: que hable el chequeo viejo
  local t i
  # Los placeholders se neutralizan ANTES de parsear, en dos pasadas porque hay
  # dos posiciones: `{{X}}` como valor entero (policy.json.tmpl: `"max_review_rounds": {{LOOP_BUDGET}}`,
  # que sin comillas NO es JSON) y `{{X}}` dentro de un string ya citado.
  t="$(sed -E -e 's/([:[,][[:space:]]*)\{\{[^}]*\}\}/\1"HARNESS_PH"/g' \
               -e 's/\{\{[^}]*\}\}/HARNESS_PH/g' "$1" | json_hojas)"
  [ -n "$t" ] || return 1
  i="$(json_hojas < "$2")"
  [ -n "$i" ] || return 1
  # Las hojas que vienen de un placeholder NO se verifican: lo que el generador
  # sustituyó ahí no lo sabe este repo.
  printf '%s\n' "$t" | grep -v HARNESS_PH \
    | grep -F -x -v -f <(printf '%s\n' "$i") 2>/dev/null | grep -c . || true
}

dueno_de() {  # dueno_de <ruta absoluta en la instancia> → plugin|compartido
  case "${1#"$WS"/}" in
    scripts/*|.claude/hooks/*|.claude/commands/*|.claude/agents/*) echo plugin ;;
    .claude/settings.json|harness-policy.json) echo plugin ;;
    .claude/skills/skill-creator/*|.claude/skills/pipeline-step-creator/*) echo plugin ;;
    .claude/skills/harness-bug-report/*|.claude/skills/custom-*/*) echo plugin ;;
    *) echo compartido ;;
  esac
}

verificar_archivos() {  # → 0 todo al día · 1 drift en algo del plugin · 2 no pude
  local mdir="$PLUGIN_ROOT/templates" man="$PLUGIN_ROOT/templates/MANIFEST.sha256"
  if [ ! -f "$man" ] || [ ! -d "$mdir" ]; then
    echo "⚠️  sin templates del plugin en disco: no puedo comparar archivo por archivo"
    return 2
  fi
  local idx tpl rel base render cands n inst esperado real faltan podar njson
  local rojos=0 avisos=0 dudosos=0 vistos=0
  # El PLUGIN se poda del índice: si vive bajo el workspace, cada template
  # aparecería como candidato de sí mismo, habría dos archivos con el mismo
  # nombre y todo quedaría "sin ubicar". Comparar el plugin contra el plugin no
  # dice nada de la instancia.
  podar="${PLUGIN_ROOT:-$WS/.este-path-no-existe}"
  idx="$(find "$WS" \( -name .git -o -name repos -o -name worktrees \
                       -o -name tasks -o -name node_modules -o -name .cache \
                       -o -name .venv -o -path "$podar" \) -prune \
                    -o -type f -print 2>/dev/null)"
  while IFS= read -r tpl; do
    [ -n "$tpl" ] || continue
    rel="${tpl#"$mdir"/}"
    base="${rel##*/}"
    render=0
    case "$base" in *.tmpl) base="${base%.tmpl}"; render=1 ;; esac
    cands="$(printf '%s\n' "$idx" | awk -F/ -v b="$base" '$NF==b')"
    n="$(printf '%s\n' "$cands" | grep -c . || true)"
    if [ "$n" -ne 1 ]; then dudosos=$((dudosos+1)); continue; fi
    inst="$cands"
    vistos=$((vistos+1))
    if [ "$render" -eq 0 ]; then
      esperado="$(awk -v p="templates/$rel" '$2==p{print $1; exit}' "$man")"
      [ -n "$esperado" ] || { dudosos=$((dudosos+1)); continue; }
      real="$(sha_de "$inst")"
      [ "$real" = "$esperado" ] && continue
      faltan="sha distinto"
    else
      # Las líneas del template SIN placeholder tienen que estar todas.
      faltan="$(grep -v '{{' "$tpl" | grep -v '^[[:space:]]*$' \
                | grep -F -x -v -f "$inst" 2>/dev/null | grep -c . || true)"
      [ "${faltan:-0}" -eq 0 ] && continue
      faltan="$faltan línea(s) del template no están"
    fi
    # Los dos chequeos de arriba son TEXTUALES, y para un JSON eso da falsos
    # rojos por re-serialización. Se pregunta de nuevo, por estructura. Va acá y
    # no antes para no pagar jq cuando el archivo ya coincidía byte a byte.
    case "$base" in
      *.json)
        if njson="$(json_faltan "$tpl" "$inst")"; then
          [ "$njson" -eq 0 ] && continue
          faltan="$njson clave(s) del template no están"
        fi ;;
    esac
    if [ "$(dueno_de "$inst")" = plugin ]; then
      echo "   ❌ ${inst#"$WS"/}: $faltan"
      rojos=$((rojos+1))
    else
      echo "   ⚠️  ${inst#"$WS"/}: $faltan (propiedad compartida: puede ser local)"
      avisos=$((avisos+1))
    fi
  done <<EOF
$(find "$mdir" -type f 2>/dev/null | sort)
EOF
  echo "   ── $vistos archivo(s) comparados · $rojos del plugin con drift · ${avisos} aviso(s) · $dudosos sin ubicar"
  [ "$dudosos" -gt 0 ] && echo "   (sin ubicar = 0 o >1 archivos con ese nombre en la instancia: no afirmo nada)"
  [ "$rojos" -gt 0 ] && return 1
  return 0
}

# ── 1c · --verify: DESPUÉS de actualizar, ¿aterrizó donde dijo? ───────
# Un update que termina diciendo "listo" no es evidencia de nada: el modo de
# fallo que este harness ya pagó es un generador que escribió la versión nueva
# habiendo copiado templates viejos, y reportó éxito. Este modo comprueba lo
# único que no se puede fingir: que la instancia coincide con el ÚLTIMO TAG en
# los DOS ejes, número y contenido.
#
# Y comprueba antes lo que casi nadie mira: el plugin EN DISCO, que es de donde
# el update copia. Si `/plugin marketplace update` no corrió, regenerar desde
# ahí produce una instancia vieja... que va a reportar éxito igual.
#   exit 0 = aterrizó · 1 = no · 2 = no pude comprobarlo
if [ "$MODE" = "verify" ]; then
  echo
  echo "── ¿el update aterrizó? ──"
  if [ -z "$up_ver" ] || [ -z "$up_tpl" ]; then
    echo "⚠️  no pude traer el último tag de upstream: NO puedo confirmar el update."
    echo "   Esto no es un update fallido, es un update SIN VERIFICAR."
    exit 2
  fi
  [ -n "$UP_TAG" ] || echo "⚠️  upstream no publica tags: comparo contra su rama por defecto, que se mueve."

  vrc=0
  # El plugin en disco, la fuente del copiado.
  if [ -n "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
    disk_ver="$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
    # OJO: acá NO sirve read_digest. MANIFEST.sha256 trae una línea por archivo
    # que EMPIEZA con un sha256, así que read_digest devolvería el hash del
    # primer template en vez del digest del set, y el chequeo compararía cosas
    # distintas dando rojo siempre. El digest es su última línea, con prefijo.
    disk_tpl="$(sed -n 's/^digest: *//p' "$PLUGIN_ROOT/templates/MANIFEST.sha256" 2>/dev/null | head -1)"
    if [ "$disk_ver" != "$up_ver" ] || { [ -n "$disk_tpl" ] && [ "$disk_tpl" != "$up_tpl" ]; }; then
      echo "❌ el PLUGIN EN DISCO ($disk_ver) no es el último tag ($up_ver)."
      echo "   El update copia DESDE acá, así que regenerar produce una instancia"
      echo "   vieja igual, y el número que escriba va a decir que está al día."
      echo "   ↳ /plugin marketplace update harness   y volvé a correr el update"
      vrc=1
    else
      echo "✅ plugin en disco $disk_ver: es el último tag"
    fi
  else
    echo "⚠️  no sé qué plugin está instalado (sin CLAUDE_PLUGIN_ROOT): no puedo"
    echo "   confirmar que el update copió desde la versión publicada."
    [ "$vrc" -eq 0 ] && vrc=2
  fi

  if [ "$local_ver" = "$up_ver" ]; then
    echo "✅ versión de la instancia $local_ver: coincide con el tag"
  else
    echo "❌ la instancia dice $local_ver y el último tag es $up_ver: el update NO aterrizó."
    vrc=1
  fi

  if [ -z "$local_tpl" ]; then
    echo "❌ la instancia no declara set de templates: el update no dejó rastro,"
    echo "   así que el número de arriba no es evidencia de nada."
    vrc=1
  elif [ "$local_tpl" = "$up_tpl" ]; then
    echo "✅ templates $(printf '%.12s' "$local_tpl"): idénticos al tag"
  else
    echo "❌ templates $(printf '%.12s' "$local_tpl") ≠ tag $(printf '%.12s' "$up_tpl")."
    echo "   Este es EL fallo que importa: el número quedó bien y el CONTENIDO"
    echo "   no. Faltan archivos por aplicar, o alguno se rechazó."
    echo "   ↳ volvé a correr /harness-update y aplicá los diffs que queden."
    vrc=1
  fi
  # ── Y AHORA LOS ARCHIVOS, que es lo que los tres chequeos de arriba NO
  # miran: los tres comparan NÚMEROS que el update declaró. Esto compara
  # contenido. Solo corre si el plugin en disco es el tag, porque es la
  # referencia: contra un plugin viejo, comparar archivo por archivo diría
  # que la instancia está mal cuando la desactualizada es la referencia.
  echo
  echo "── ¿y cada archivo? ──"
  # ── DOS CAUSAS DISTINTAS NO PUEDEN COMPARTIR UN MENSAJE (#194) ──────
  # Este bloque decía "sin un plugin en disco al día" para las DOS: no saber
  # DÓNDE está el plugin, y que el plugin esté VIEJO. Solo la segunda habla de
  # frescura, así que a quien le faltaba la ruta se le decía que actualizara un
  # plugin que ya estaba al día, y el chequeo quedaba apagado en silencio.
  # Cada causa con su mensaje y su remediación, que es la regla 5 de este repo.
  if [ -z "$PLUGIN_ROOT" ]; then
    echo "⚠️  no sé DÓNDE está el plugin en disco, así que no puedo comparar los"
    echo "   archivos. Esto NO dice nada de su versión: probé las rutas conocidas"
    echo "   (~/.claude/plugins/{marketplaces,cache}/harness y el clon del"
    echo "   workspace) y en ninguna encontré un templates/MANIFEST.sha256."
    echo "   ↳ remediación: pasale la ruta y vuelve a correr:"
    echo "     CLAUDE_PLUGIN_ROOT=<ruta-del-plugin> bash scripts/harness-version.sh --verify"
    [ "$vrc" -eq 0 ] && vrc=2
  elif [ "${disk_ver:-}" != "$up_ver" ]; then
    echo "⚠️  el plugin en disco está en ${disk_ver:-?} y upstream en ${up_ver:-?}:"
    echo "   comparar los archivos contra un plugin viejo diría que tu instancia"
    echo "   tiene drift cuando lo que está atrasado es la fuente."
    echo "   ↳ remediación: /plugin marketplace update harness  y volvé a correr"
    [ "$vrc" -eq 0 ] && vrc=2
  else
    verificar_archivos || { [ "$?" -eq 1 ] && vrc=1; }
  fi
  [ "$vrc" -eq 0 ] && echo "✅ el update aterrizó: instancia == ${UP_TAG:-upstream} en número, contenido y archivo por archivo"
  exit "$vrc"
fi

if [ "$verdict" -eq 1 ]; then
  echo "   ↳ para actualizar:  /plugin marketplace update harness"
  echo "                       /harness-init .        (modo update, no re-pregunta)"
  echo "   ANTES de actualizar, revisá que ninguna tarea tenga el estado editado"
  echo "   a mano: validate-ship compara la fase contra el último movimiento"
  echo "   registrado, y una que no coincida muere en POLICY-STATE-003."
fi

# ── 2 · tareas en curso ───────────────────────────────────────────────
echo
echo "── tareas con estado ──"
found=0
for st in "$WS"/tasks/*/state.json; do
  [ -f "$st" ] || continue
  found=1
  id="$(basename "$(dirname "$st")")"
  phase="$(jq -r '.phase // "?"' "$st" 2>/dev/null)"
  lane="$(jq -r '.lane // "?"' "$st" 2>/dev/null)"
  rounds="$(jq -r '.review_rounds // 0' "$st" 2>/dev/null)"
  last="$(jq -r '.history[-1].to // ""' "$st" 2>/dev/null)"
  # El mismo invariante que valida el ship, mostrado antes de que muerda.
  flag=""
  if [ -n "$last" ] && [ "$last" != "$phase" ]; then
    flag="  ⚠️ fase EDITADA A MANO (history dice '$last'): el ship va a fallar"
  fi
  printf '  %-34s fase=%-10s carril=%-8s rondas=%s%s\n' "$id" "$phase" "$lane" "$rounds" "$flag"
done
[ "$found" -eq 1 ] || echo "  (ninguna)"

# ── 3 · sesión y trabajo tomado ───────────────────────────────────────
echo
echo "── sesiones y worktrees ──"
bus="$WS/.harness/events.jsonl"
if [ -s "$bus" ] && command -v jq >/dev/null 2>&1; then
  n="$(jq -rs '[.[] | .session // empty] | unique | length' "$bus" 2>/dev/null || echo "?")"
  echo "  sesiones vistas en el bus: $n"
  paradas="$(jq -rs '[.[] | select(.kind == "stop")] | length' "$bus" 2>/dev/null || echo 0)"
  [ "${paradas:-0}" -gt 0 ] && echo "  ⚠️  $paradas parada(s) registradas: alguien te está esperando"
else
  echo "  (sin bus de eventos todavía)"
fi
claims=0
for c in "$WS"/.harness/claims/*.json; do
  [ -f "$c" ] || continue
  claims=$((claims+1))
  jq -r '"  worktree \(.task)/\(.repo) tomado por la sesión \(.session[0:8])"' "$c" 2>/dev/null
done
[ "$claims" -eq 0 ] && echo "  ningún worktree reclamado"

# ── 4 · lo que hay que auditar ────────────────────────────────────────
asum=0
for a in "$WS"/tasks/*/assumptions.md; do
  [ -f "$a" ] || continue
  # `grep -c` IMPRIME 0 y ADEMÁS sale 1 cuando no encontró nada, así que un
  # `|| echo 0` agrega un SEGUNDO 0 y k queda "0\n0": el $(()) de abajo muere
  # con "syntax error in expression". Solo se disparaba con un assumptions.md
  # que existe y no tiene ni un supuesto, o sea en el caso BUENO, y el error
  # salía al final de todo, así que parecía un fallo del bloque anterior.
  # El `|| true` protege el pipeline; el case protege la aritmética de
  # cualquier salida que no sea un número (un grep de otro vendor, un locale
  # raro): esta función observa, y un observador no puede tumbar nada.
  k="$(grep -c '^- SUPUESTO:' "$a" 2>/dev/null || true)"
  case "$k" in ''|*[!0-9]*) k=0 ;; esac
  asum=$((asum + k))
done
if [ "$asum" -gt 0 ]; then
  echo
  echo "── $asum supuesto(s) sin confirmar (tasks/*/assumptions.md) ──"
  echo "  Es lo primero que conviene auditar: son las decisiones que se"
  echo "  tomaron por vos cuando la evidencia no alcanzaba."
fi

exit 0
