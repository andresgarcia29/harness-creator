# flake-warden — flakiness: mismo commit, pass y fail. Detecta desde los
# JUnit XML que gotestsum/pytest/vitest archivan en .cache/junit/<repo>/.
# Política GitHub-interna: detectar → CUARENTENA → delegar el fix.
JOB_NAME=flake-warden
JOB_TIER=expensive
JOB_MAX_TURNS=60
JOB_TOOLS="Read,Grep,Glob,Bash(git *),Bash(gh *),Bash(go *),Bash(npm *),Bash(uv *),Bash(gotestsum *),Edit,Write"

detect() {
  local dir=".cache/junit"
  [ -d "$dir" ] || { echo "sin $dir — archiva los JUnit XML de cada run de CI ahí" >&2; return 3; }
  # tests que aparecen con failure Y sin failure en los XML de la semana
  find "$dir" -name "*.xml" -mtime -7 2>/dev/null | while read -r f; do
    grep -oE '<testcase[^>]*name="[^"]+"' "$f" | sed 's/.*name="//;s/"$//' | sort -u | sed "s|^|ALL |"
    python3 - "$f" <<'PYEOF' | sort -u | sed "s|^|FAIL |"
import sys, xml.etree.ElementTree as ET
# CON UN PARSER DE XML, NO CON REGEX. El grep -B0 -A2 original capturaba los
# DOS testcases siguientes: en XML de una línea por testcase (gotestsum,
# vitest) los vecinos que PASARON entraban al set de fallos, y el prompt
# ordena cuarentena inmediata del señalado. En XML indentado el nombre está en
# la línea ANTERIOR, que -B0 no miraba, así que el flake real podía no
# detectarse nunca.
#
# El primer intento de arreglo usó regex y reprodujo el bug exacto: `[^>]*`
# se comía la barra de `/>` y el testcase auto-cerrado se fusionaba con el
# siguiente. Un XML se parsea con un parser.
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)          # XML ilegible: no inventamos fallos
for tc in root.iter('testcase'):
    if tc.find('failure') is not None or tc.find('error') is not None:
        name = tc.get('name')
        if name:
            print(name)
PYEOF
  done | sort | uniq -c | awk '
    $2=="FAIL" {fail[$3]=$1}
    $2=="ALL"  {all[$3]=$1}
    END { for (t in fail) if (all[t] > fail[t]) printf "flip-rate %d/%d %s\n", fail[t], all[t], t }
  ' > "$FINDINGS"
  [ -s "$FINDINGS" ] && return 10 || return 0
}

JOB_PROMPT='Eres el flake-warden. Por cada test con flip-rate de los
hallazgos: (1) CUARENTENA INMEDIATA — PR que marca el test como skip
con link a un issue nuevo que documenta el flip-rate y el dueño (el
autor del test según git blame); (2) root-cause en el mismo PR si es
uno de los 3 peores: reproduce corriendo el test 30 veces, identifica
la causa (sleep, orden, red, tiempo) y propone el fix con evidencia de
30 corridas verdes. Un flake escondido con retry infinito es deuda;
la cuarentena visible no.'
