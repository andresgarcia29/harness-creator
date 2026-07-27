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
set -u

WS="$(cd "$(dirname "$0")/.." && pwd)"
# Mismo patrón que harness-bug.sh: env con default, no un placeholder
# que alguien tenga que acordarse de sustituir.
UPSTREAM_REPO="${HARNESS_UPSTREAM_REPO:-andresgarcia29/harness-creator}"
# El plugin EN DISCO: la fuente real de la que un update copia. Claude Code lo
# exporta como CLAUDE_PLUGIN_ROOT dentro de los comandos.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${HARNESS_PLUGIN_ROOT:-}}"
MODE=full
case "${1:-}" in
  --check)  MODE=check ;;
  --quiet)  MODE=quiet ;;
  --verify) MODE=verify ;;
  "")       MODE=full ;;
  *) echo "uso: harness-version.sh [--check|--quiet|--verify]"; exit 1 ;;
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
UP_TAG=""
if command -v gh >/dev/null 2>&1; then
  UP_TAG="$(gh api "repos/$UPSTREAM_REPO/tags" --paginate --jq '.[].name' 2>/dev/null \
    | awk '{ v=$0; sub(/^v/,"",v); if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) print v"\t"$0 }' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | cut -f2)"
fi
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
  [ "$vrc" -eq 0 ] && echo "✅ el update aterrizó: instancia == ${UP_TAG:-upstream} en número y contenido"
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
  k="$(grep -c '^- SUPUESTO:' "$a" 2>/dev/null || echo 0)"
  asum=$((asum + k))
done
if [ "$asum" -gt 0 ]; then
  echo
  echo "── $asum supuesto(s) sin confirmar (tasks/*/assumptions.md) ──"
  echo "  Es lo primero que conviene auditar: son las decisiones que se"
  echo "  tomaron por vos cuando la evidencia no alcanzaba."
fi

exit 0
