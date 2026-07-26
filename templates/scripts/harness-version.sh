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
# Uso:
#   scripts/harness-version.sh            todo: versión + sesión + trabajo
#   scripts/harness-version.sh --check    solo el veredicto, por exit code
#   scripts/harness-version.sh --quiet    solo versión y set de templates
set -u

WS="$(cd "$(dirname "$0")/.." && pwd)"
# Mismo patrón que harness-bug.sh: env con default, no un placeholder
# que alguien tenga que acordarse de sustituir.
UPSTREAM_REPO="${HARNESS_UPSTREAM_REPO:-andresgarcia29/harness-creator}"
MODE=full
case "${1:-}" in
  --check) MODE=check ;;
  --quiet) MODE=quiet ;;
  "")      MODE=full ;;
  *) echo "uso: harness-version.sh [--check|--quiet]"; exit 1 ;;
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

# ── 1 · versión ───────────────────────────────────────────────────────
local_ver="$(tr -d ' \n' < "$WS/.harness-version" 2>/dev/null || true)"
up_ver=""
up_why=""
if command -v gh >/dev/null 2>&1; then
  up_ver="$(gh api "repos/$UPSTREAM_REPO/contents/.claude-plugin/plugin.json" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"
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
  line="⬆️  instancia $local_ver · upstream $up_ver: HAY UPDATE"
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
tpl_raw="$(tr -d ' \n' < "$WS/.harness-templates" 2>/dev/null || true)"
up_tpl=""
if command -v gh >/dev/null 2>&1; then
  up_tpl="$(gh api "repos/$UPSTREAM_REPO/contents/templates/MANIFEST.sha256" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null \
    | sed -n 's/^digest: *//p' | head -1 || true)"
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
