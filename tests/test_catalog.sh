#!/usr/bin/env bash
# test_catalog.sh: el catálogo es INSUMO DE UN SCRIPT, no prosa.
# Cada `install:` de una capacidad con `bin:` se interpola en el bootstrap
# generado. Con prosa dentro ("brew install node (o bun)") los paréntesis son
# sintaxis de shell y rompen el PARSEO DEL ARCHIVO COMPLETO: el bootstrap no
# arranca, ni una dependencia se instala, y el doctor culpa a los CLIs
# faltantes sin decir por qué (issue #22). Aquí se genera el bootstrap como lo
# haría el generador y se valida con bash -n: barato y cierra la clase entera.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

CAT="$ROOT/catalog/capabilities.yaml"

# (bin, install) de cada capacidad instalable, en el orden del catálogo
entries() {
  awk '
    function flush() { if (name != "" && bin != "") printf "%s\t%s\t%s\n", bin, inst, kind }
    /^  - name:/      { flush(); name=$3; bin=""; inst=""; kind="" }
    /^    bin:/       { bin=$2 }
    /^    install_kind:/ { kind=$2 }
    /^    install:/   { line=$0; sub(/^[ \t]*install:[ \t]*/, "", line)
                        # valor entrecomillado: hasta la comilla de cierre (el
                        # resto puede ser un comentario YAML, no parte del valor)
                        if (substr(line,1,1) == "\"") {
                          line=substr(line,2); i=index(line,"\""); if (i>0) line=substr(line,1,i-1)
                        } else { sub(/[ \t]+#.*$/, "", line) }
                        inst=line }
    END { flush() }
  ' "$CAT"
}

echo "── catálogo: install es un comando, no prosa"

n=0; bad=0
while IFS="$(printf '\t')" read -r bin inst kind; do
  [ -n "$bin" ] || continue
  n=$((n+1))
  [ -n "$inst" ] || { fail "$bin: sin install:"; bad=$((bad+1)); continue; }
  # metacaracteres de shell: lo que rompe el archivo generado
  case "$inst" in
    *"("*|*")"*|*"|"*|*"&"*|*";"*|*"<"*|*">"*|*'`'*|*'$'*|*'"'*|*"'"*|*"*"*|*"?"*)
      fail "$bin: install con sintaxis de shell dentro: '$inst'"; bad=$((bad+1)) ;;
  esac
done <<EOF
$(entries)
EOF
[ "$bad" -eq 0 ] && pass "$n comandos de install sin metacaracteres de shell"

echo "── catálogo: install es una URL (manual) o un package manager conocido"

unknown=0
while IFS="$(printf '\t')" read -r bin inst kind; do
  [ -n "$bin" ] && [ -n "$inst" ] || continue
  case "$inst" in
    http://*|https://*) ;;   # instalación manual, el bootstrap solo verifica
    brew\ *|npm\ *|npx\ *|pnpm\ *|yarn\ *|pip\ *|pip3\ *|pipx\ *|uv\ *|go\ *|cargo\ *|gem\ *|apt-get\ *|apt\ *|dnf\ *|yum\ *|winget\ *|scoop\ *|gcloud\ *) ;;
    *) fail "$bin: install no es URL ni package manager conocido: '$inst'"; unknown=$((unknown+1)) ;;
  esac
done <<EOF
$(entries)
EOF
[ "$unknown" -eq 0 ] && pass "todo install es URL o package manager reconocible"

echo "── install_kind: el bootstrap instala o verifica por DATO, no por inferencia"

nokind=0; mismatch=0
while IFS="$(printf '\t')" read -r bin inst kind; do
  [ -n "$bin" ] && [ -n "$inst" ] || continue
  case "$kind" in
    auto|manual) ;;
    *) fail "$bin: sin install_kind (auto|manual); el generador tendría que adivinar"; nokind=$((nokind+1)); continue ;;
  esac
  case "$inst" in
    http://*|https://*)
      [ "$kind" = "manual" ] || { fail "$bin: URL marcada como auto (nadie puede ejecutar una URL)"; mismatch=$((mismatch+1)); } ;;
    *)
      # un comando marcado manual es legítimo (dev-dep por repo), pero un
      # comando de package manager marcado auto tiene que serlo de verdad
      if [ "$kind" = "auto" ]; then
        case "$inst" in
          brew\ *|npm\ *|npx\ *|pnpm\ *|yarn\ *|pip\ *|pip3\ *|pipx\ *|uv\ *|go\ *|cargo\ *|gem\ *|apt-get\ *|apt\ *|dnf\ *|yum\ *|winget\ *|scoop\ *|gcloud\ *) ;;
          *) fail "$bin: install_kind auto pero '$inst' no es un package manager"; mismatch=$((mismatch+1)) ;;
        esac
      fi ;;
  esac
done <<EOF
$(entries)
EOF
[ "$nokind" -eq 0 ] && pass "toda capacidad instalable declara install_kind"
[ "$mismatch" -eq 0 ] && pass "install_kind coherente con el comando (issue #23)"

# los package managers que el issue #23 vio degradados a require deben quedar auto
for b in depcruise lint-imports go-arch-lint graphify ccusage gotestsum squawk kubectl; do
  k="$(entries | awk -F"\t" -v b="$b" '$1==b {print $3}')"
  assert_eq "auto" "$k" "$b se instala (era require en el issue #23)"
done

# PEP 668: pip install contra el Python del sistema falla en muchas máquinas
pips="$(entries | awk -F"\t" '$2 ~ /^pip3? install/ {print $1}' | tr '\n' ' ')"
assert_eq "" "$pips" "ningún install usa pip del sistema (uv tool install)"

echo "── el catálogo no manda a instalar cosas que no existen (issue #24)"

grep -q "akuity/tap/kargo-cli" "$CAT" \
  && fail "kargo sigue apuntando a la fórmula inexistente akuity/tap/kargo-cli" \
  || pass "kargo usa la fórmula real (akuity/tap/kargo)"
grep -qE '^\s+install: "brew install terraform"' "$CAT" \
  && fail "terraform con el nombre plano: brew aborta pidiendo confiar el tap (BUSL)" \
  || pass "terraform usa el path completo del tap (auto-tapea, como vault)"

# el override de Linux, si existe, tiene que declarar su propio kind
linux_bad=0
while read -r ln; do
  [ -n "$ln" ] || continue
  linux_bad=$((linux_bad+1))
done <<EOF
$(awk '
  /^  - name:/ { name=$3; li=""; lk="" }
  /^    install_linux:/ { li=$2 }
  /^    install_linux_kind:/ { lk=$2 }
  /^$/ { if (li != "" && lk == "") print name; li=""; lk="" }
' "$CAT")
EOF
assert_eq 0 "$linux_bad" "todo install_linux declara su install_linux_kind"

# ── EL RATCHET: una capacidad que instala con brew DEBE tener camino en Linux ──
# POR QUE EXISTE (#190): el catalogo asumia que "brew corre en Linux, asi que
# las formulas normales sobreviven al cruce". Los #184/#186/#188 derribaron esa
# premisa: en un host Linux acotado brew no esta, y como root NO PUEDE estar (su
# instalador aborta y no admite override). Con la premisa caida, cada
# `install: brew ...` sin `install_linux` es una capacidad que ESA maquina no
# puede instalar, y el catalogo no lo dice.
#
# Medido sobre una instancia real: de las 16 CLIs que hacian falta, 8 no tenian
# NINGUN dato de Linux; las otras 8 salieron bien solo porque su install ya era
# portable (npm/uv/go), no porque el catalogo lo declarara. O sea que cada
# instalacion reconstruia a mano comandos que existen, son estables y publica el
# fabricante.
#
# Sin este ratchet la proxima capacidad que se agregue con brew reabre el hueco,
# y se descubre igual que esta vez: en una maquina, a mano, con el humano
# resolviendo releases uno por uno. Con el ratchet, se descubre acá.
sin_linux="$(awk '
  /^  - name:/ { if (name != "" && brew && !li) print "  · " name; name=$3; brew=0; li=0 }
  /^    install:.*brew/ { brew=1 }
  /^    install_linux:/ { li=1 }
  END { if (name != "" && brew && !li) print "  · " name }
' "$CAT")"
if [ -z "$sin_linux" ]; then
  pass "toda capacidad que instala con brew declara su camino en Linux"
else
  fail "capacidades con 'install: brew' y SIN install_linux (en un host sin brew no hay forma de instalarlas, y el catalogo no lo dice):
$sin_linux"
fi

echo "── el bootstrap generado con TODO el catálogo parsea (bash -n)"

# instancia el template exactamente como el generador: una línea por capacidad
lines="$WS/ensure.txt"; : > "$lines"
while IFS="$(printf '\t')" read -r bin inst kind; do
  [ -n "$bin" ] && [ -n "$inst" ] || continue
  case "$kind" in
    manual) printf 'require %s "%s"\n' "$bin" "$inst" >> "$lines" ;;
    *)      printf 'ensure %s %s\n'   "$bin" "$inst" >> "$lines" ;;
  esac
done <<EOF
$(entries)
EOF

python3 - "$ROOT/templates/scripts/bootstrap.sh.tmpl" "$lines" "$WS/bootstrap.sh" <<'PY'
import sys, re
tpl, lines, out = sys.argv[1:4]
t = open(tpl).read().replace("{{ENSURE_LINES}}", open(lines).read())
t = re.sub(r"\{\{[A-Z_]+\}\}", "vault", t)   # el resto de placeholders, como el generador
open(out, "w").write(t)
PY
bash -n "$WS/bootstrap.sh" 2>"$WS/err.txt" \
  && pass "bootstrap con las $(wc -l < "$lines" | tr -d ' ') capacidades del catálogo: sintaxis válida" \
  || fail "el bootstrap generado NO parsea: $(head -2 "$WS/err.txt")"

echo "── la regresión del issue #22 queda cazada"

# una prosa con paréntesis en el catálogo debe hacer FALLAR este test
printf 'ensure npm brew install node (o bun)\n' > "$WS/evil.txt"
python3 - "$ROOT/templates/scripts/bootstrap.sh.tmpl" "$WS/evil.txt" "$WS/evil.sh" <<'PY'
import sys, re
tpl, lines, out = sys.argv[1:4]
t = open(tpl).read().replace("{{ENSURE_LINES}}", open(lines).read())
t = re.sub(r"\{\{[A-Z_]+\}\}", "vault", t)
open(out, "w").write(t)
PY
bash -n "$WS/evil.sh" 2>/dev/null \
  && fail "el bash -n no detecta los paréntesis: el test no protege nada" \
  || pass "prosa con paréntesis: bash -n la caza (el test tiene dientes)"

echo "── el install_linux de kubectl VERIFICA antes de instalar (#192)"
# Es el UNICO install_linux de tipo `auto` que descarga un BINARIO: los demas
# son de canal (go install, npm, uv, cargo) o `manual`, que es una URL que sigue
# un humano. Y corre en el bootstrap de cada instancia, o sea en el momento de
# menos supervision, escribiendo en un directorio del PATH.
#
# El comando se saca VERBATIM del catalogo y se EJECUTA: lo unico stubbeado son
# las herramientas (curl sirve de un directorio local, install redirige la
# escritura, sha256sum se emula donde no existe). Un grep del texto probaria que
# la palabra "sha256" esta escrita; esto prueba que el binario manipulado NO SE
# INSTALA, que es lo que importa.
KB="$WS/kubectl-verifica"; mkdir -p "$KB/bin" "$KB/srv" "$KB/dest"
cmd="$(python3 -c "
import yaml
d = yaml.safe_load(open('$CAT'))
print([c for c in d['capabilities'] if c['name']=='kubectl'][0]['install_linux'])
")"
[ -n "$cmd" ] && pass "el catalogo declara install_linux para kubectl" \
               || fail "sin install_linux de kubectl no hay nada que ejercitar"
# Primero la estructural, porque es la que NOMBRA el defecto: sin ella, una
# regresion se reporta como "no instalo el binario bueno", que manda a mirar
# el lugar equivocado.
case "$cmd" in
  *.sha256*--check*) pass "el comando descarga el checksum publicado y lo COMPRUEBA" ;;
  *) fail "el install_linux de kubectl no verifica: baja un binario y lo hace ejecutable sin comprobar el .sha256 que el fabricante publica al lado (#192)" ;;
esac

# curl de palo: traduce la URL a un archivo del directorio servido.
cat > "$KB/bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -fsSLo|-o) out="$2"; shift 2 ;;
    -fsSL|-sSL|-L|-s|-f) shift ;;
    *) url="$1"; shift ;;
  esac
done
p="${url#http://serv}"
src="$SRVDIR$p"
[ -f "$src" ] || exit 22
# Un test JAMAS escribe fuera de su arbol. El comando anterior al #192 bajaba
# directo a /usr/local/bin sin pasar por `install`, asi que sin esta guarda una
# regresion del catalogo convertiria a la suite en algo que toca la maquina.
case "${out:-}" in
  ""|"$SRVDIR"*|/var/*|/tmp/*|/private/*) ;;
  *) echo "curl de palo: me pidieron escribir fuera del test ($out)" >&2; exit 23 ;;
esac
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
CURLEOF
# install de palo: la ruta real es /usr/local/bin y un test no escribe ahi.
cat > "$KB/bin/install" <<'INSEOF'
#!/usr/bin/env bash
args=(); for a in "$@"; do args+=("${a/\/usr\/local\/bin/$DESTDIR}"); done
/usr/bin/install "${args[@]}"
INSEOF
# sha256sum: SIEMPRE se stubbea, y el motivo importa. `--check` es de GNU
# coreutils, que es lo que hay en Linux, o sea el unico sitio donde install_linux
# corre. El host de esta suite es macOS y su `sha256sum` (cuando existe) es el
# BSD, que NO conoce `--check`: sin este stub el test medía la ausencia del flag
# en el host y no la conducta del comando. Se delega a `shasum -a 256`, que sí
# implementa el chequeo con el mismo formato `<hash>  <archivo>`.
cat > "$KB/bin/sha256sum" <<'SHAEOF'
#!/usr/bin/env bash
exec shasum -a 256 "$@"
SHAEOF
chmod +x "$KB/bin/"*

mkdir -p "$KB/srv/release/v1.33.0/bin/linux/amd64"
printf 'yo soy kubectl\n' > "$KB/srv/release/v1.33.0/bin/linux/amd64/kubectl"
printf 'v1.33.0' > "$KB/srv/release/stable.txt"
( cd "$KB/srv/release/v1.33.0/bin/linux/amd64" \
  && { command -v sha256sum >/dev/null 2>&1 && sha256sum kubectl || shasum -a 256 kubectl; } \
     | awk '{print $1}' > kubectl.sha256 )

corre_install() {  # corre el comando del catalogo con las herramientas de palo
  ( export PATH="$KB/bin:$PATH" SRVDIR="$KB/srv" DESTDIR="$KB/dest"
    eval "${cmd//https:\/\/dl.k8s.io/http://serv}" ) >/dev/null 2>&1
}

# (1) binario intacto: instala y sale 0.
rm -f "$KB/dest/kubectl"; corre_install; rc=$?
assert_eq 0 "$rc" "binario intacto: el comando sale 0"
[ -x "$KB/dest/kubectl" ] && pass "y lo instala" || fail "no instalo el binario bueno"

# (2) EL CASO: el binario cambia y el checksum publicado NO. Es lo que produce
#     un mirror comprometido o un MITM. El comando anterior lo instalaba y salia
#     0 (verificado a mano contra un servidor local antes de escribir esto).
printf 'yo soy kubectl MANIPULADO\n' > "$KB/srv/release/v1.33.0/bin/linux/amd64/kubectl"
rm -f "$KB/dest/kubectl"; corre_install; rc=$?
[ "$rc" -ne 0 ] && pass "binario manipulado: el comando CORTA (exit $rc)" \
                || fail "binario manipulado: salio 0, o sea que el checksum no frena nada"
assert_no_file "$KB/dest/kubectl" "y NO lo instala: un binario que no coincide con su checksum no entra al PATH"

t_done
