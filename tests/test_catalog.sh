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

echo "── install_linux es UN comando, igual que install (#199/#200)"
# POR QUE: el generador escribe el valor TAL CUAL detras de `ensure <bin> ...`.
# Una cadena con `&&`/`|`/`$( )` NO llega entera a ensure: el shell parte la
# linea al leer el archivo y solo el primer pedazo queda como argumento; el
# resto corre SUELTO. Medido con el install_linux que tenia kubectl:
#   · con kubectl ya instalado, la cadena se ejecutaba igual y lo reinstalaba;
#   · con --check ("solo reporta que falta, no instala nada"), instalaba;
#   · lo que ensure contaba como la instalacion era `d=$(mktemp -d)`, un no-op.
# Es la misma clase del issue #22, que ya estaba prohibida para `install:` y
# nadie habia prohibido para install_linux. Lo que no cabe en un comando va
# como receta a `bs_install <bin>` dentro del bootstrap.
linux_entries() {
  awk '
    function flush() { if (name != "" && li != "") printf "%s\t%s\n", name, li }
    /^  - name:/ { flush(); name=$3; li="" }
    /^    install_linux:/ { line=$0; sub(/^[ \t]*install_linux:[ \t]*/, "", line)
                            q=substr(line,1,1)
                            if (q == "\"" || q == "'"'"'") { line=substr(line,2); i=index(line,q); if (i>0) line=substr(line,1,i-1) }
                            else { sub(/[ \t]+#.*$/, "", line) }
                            li=line }
    END { flush() }
  ' "$CAT"
}
lbad=0; ln_n=0
while IFS="$(printf '\t')" read -r name li; do
  [ -n "$li" ] || continue
  ln_n=$((ln_n+1))
  case "$li" in
    http://*|https://*) ;;   # manual: una URL que sigue un humano
    *"("*|*")"*|*"|"*|*"&"*|*";"*|*"<"*|*">"*|*'`'*|*'$'*|*'"'*|*"'"*)
      fail "$name: install_linux con sintaxis de shell adentro; no llega entero a ensure: '$li'"
      lbad=$((lbad+1)) ;;
  esac
done <<EOF
$(linux_entries)
EOF
[ "$lbad" -eq 0 ] && pass "$ln_n install_linux sin cadenas de shell (llegan enteros a ensure)"

echo "── cada receta que el catalogo NOMBRA existe en el bootstrap"
# Un `bs_install foo` sin su rama en el case es una capacidad que falla recien
# en la maquina del que corre el bootstrap, y con el mensaje equivocado.
BOOT="$ROOT/templates/scripts/bootstrap.sh.tmpl"
falta=0; recetas=0
while IFS="$(printf '\t')" read -r name li; do
  case "$li" in bs_install\ *) ;; *) continue ;; esac
  r="${li#bs_install }"; recetas=$((recetas+1))
  grep -qE "^    [a-z|]*\b$r\b[a-z|]*\)" "$BOOT" \
    || { fail "$name: el catalogo pide 'bs_install $r' y bootstrap.sh no tiene esa receta"; falta=$((falta+1)); }
done <<EOF
$(linux_entries)
EOF
[ "$falta" -eq 0 ] && pass "las $recetas recetas nombradas por el catalogo existen en el bootstrap"

echo "── ninguna receta escribe donde hace falta root (#199)"
# install_linux existe para el host que NO puede usar brew, y ese host es casi
# siempre uno donde no se es root: si se pudiera ser root, brew tampoco seria un
# problema. Un destino como /usr/local/bin tira a la basura la descarga y su
# verificacion en la ultima linea.
# Se miran las lineas de CODIGO, no los comentarios: uno de ellos explica que
# el instalador de helm apunta a /usr/local/bin con sudo salvo que se le diga,
# y un gate que se dispara con la prosa que lo documenta se apaga solo.
recetas_txt="$(awk '/^bs_install\(\)/,/^}/' "$BOOT" | sed 's/[ \t]*#.*$//')"
case "$recetas_txt" in
  *"/usr/local/bin"*|*"sudo "*) fail "una receta de bs_install escribe con root (/usr/local/bin o sudo)" ;;
  *) pass "las recetas instalan en \$BINDIR, un directorio del usuario" ;;
esac
grep -q '^BINDIR="\$HOME/.local/bin"' "$BOOT" \
  && pass "BINDIR es un directorio del usuario" \
  || fail "BINDIR dejo de ser un directorio del usuario"

echo "── bs_install kubectl VERIFICA antes de instalar (#192)"
# Es la unica receta que baja un BINARIO suelto de un endpoint sin firma, y
# corre en el bootstrap de cada instancia, o sea en el momento de menos
# supervision, escribiendo en un directorio del PATH.
#
# La funcion se saca VERBATIM del template y se EJECUTA: lo unico stubbeado es
# curl (sirve de un directorio local). El destino es un $HOME temporal, asi que
# no hace falta stubbear `install` ni tocar la maquina. Un grep del texto
# probaria que la palabra sha256 esta escrita; esto prueba que el binario
# manipulado NO SE INSTALA, que es lo que importa.
KB="$WS/kubectl-verifica"; mkdir -p "$KB/bin" "$KB/srv" "$KB/home"
awk '/^BINDIR=/,/^# ── ESTE BOOTSTRAP SE GENERO/' "$BOOT" | sed '$d' > "$KB/recetas.sh"
[ -s "$KB/recetas.sh" ] && pass "las recetas se extraen del template" \
                        || fail "no pude extraer las recetas del bootstrap"

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
src="$SRVDIR${url#https://dl.k8s.io}"
[ -f "$src" ] || exit 22
# Un test JAMAS escribe fuera de su arbol.
case "${out:-}" in
  ""|"$SRVDIR"*|/var/*|/tmp/*|/private/*) ;;
  *) echo "curl de palo: me pidieron escribir fuera del test ($out)" >&2; exit 23 ;;
esac
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
CURLEOF
chmod +x "$KB/bin/"*

mkdir -p "$KB/srv/release/v1.33.0/bin/linux/amd64"
printf 'yo soy kubectl\n' > "$KB/srv/release/v1.33.0/bin/linux/amd64/kubectl"
printf 'v1.33.0' > "$KB/srv/release/stable.txt"
( cd "$KB/srv/release/v1.33.0/bin/linux/amd64" \
  && { command -v sha256sum >/dev/null 2>&1 && sha256sum kubectl || shasum -a 256 kubectl; } \
     | awk '{print $1}' > kubectl.sha256 )

corre_receta() {  # corre bs_install <bin> con el curl de palo y un HOME propio
  ( export PATH="$KB/bin:$PATH" SRVDIR="$KB/srv" HOME="$KB/home"
    warn() { echo "WARN: $1"; }
    . "$KB/recetas.sh"
    bs_install "$1" ) >/dev/null 2>&1
}
DEST="$KB/home/.local/bin/kubectl"

# (1) binario intacto: instala y sale 0.
rm -f "$DEST"; corre_receta kubectl; rc=$?
assert_eq 0 "$rc" "binario intacto: la receta sale 0"
[ -x "$DEST" ] && pass "y lo instala en el bin del usuario" || fail "no instalo el binario bueno"

# (2) EL CASO: el binario cambia y el checksum publicado NO. Es lo que produce
#     un mirror comprometido o un MITM.
printf 'yo soy kubectl MANIPULADO\n' > "$KB/srv/release/v1.33.0/bin/linux/amd64/kubectl"
rm -f "$DEST"; corre_receta kubectl; rc=$?
[ "$rc" -ne 0 ] && pass "binario manipulado: la receta CORTA (exit $rc)" \
                || fail "binario manipulado: salio 0, o sea que el checksum no frena nada"
assert_no_file "$DEST" "y NO lo instala: un binario que no coincide con su checksum no entra al PATH"

# (3) una receta que no existe se DICE, no se ignora en silencio
corre_receta capacidad-inventada; rc=$?
[ "$rc" -ne 0 ] && pass "un bin sin receta devuelve != 0 (ensure lo reporta como fallo)" \
                || fail "un bin sin receta salio 0: ensure lo contaria como instalado"

echo "── cada detect: signal:<x> nombra una señal que discover.sh EMITE"
# POR QUE: `detect:` es lo que hace que la entrevista OFREZCA la capacidad. En
# forma `signal:<x>` es verificable, y ahí está el valor; el problema es que
# nadie verificaba que la <x> exista. Una señal mal escrita (o renombrada en
# discover.sh) no falla: la capacidad simplemente no se ofrece NUNCA, y eso se
# ve igual que "el workspace no la necesita". Es la misma clase de silencio que
# el ratchet de brew/Linux: el catálogo declara una cadena que no se cumple, y
# lo dice nadie. Pasó con observe-cli y aws-cloudwatch, que nacieron con la
# señal en PROSA ("repos con observeinc en *.tf") cuando discover.sh ya emitía
# la señal de verdad: inverificable por construcción.
emitidas="$(grep -o 'signals+=("[a-z0-9_-]*")' "$ROOT/scripts/discover.sh" \
  | sed 's/.*("//; s/")//' | sort -u)"
huerfanas=""
while read -r s; do
  [ -n "$s" ] || continue
  printf '%s\n' "$emitidas" | grep -qx "$s" || huerfanas="$huerfanas $s"
done <<EOF
$(grep -o 'detect: "signal:[a-z0-9_-]*"' "$CAT" | sed 's/.*signal://; s/"//' | sort -u)
EOF
[ -z "$huerfanas" ] \
  && pass "las $(printf '%s\n' "$emitidas" | grep -c .) señales de discover.sh cubren todo detect: signal: del catálogo" \
  || fail "el catálogo filtra por señales que discover.sh NO emite (la capacidad no se ofrece nunca):$huerfanas"

echo "── y al revés: cada señal que discover.sh emite la LEE alguien"
# POR QUE: el ratchet de arriba cierra UN extremo de la cadena y el hueco
# espejo quedaba abierto. Una señal emitida que nadie consume cuesta lo mismo
# que una señal inexistente: el discovery la mide, la escribe en el inventory,
# y la entrevista sigue sin ofrecer nada. Se ve igual que "el workspace no lo
# usa", que es justo la confusión que la regla 8 existe para impedir (un eje
# que varía se DETECTA **y se DESPACHA**; detectar sin despachar es media
# regla). Paso con `eks`: 11 clusters medidos en un workspace real, la señal
# emitida desde el primer dia, y CERO lectores, asi que una plataforma entera
# sobre EKS se veia identica a una sin Kubernetes gestionado.
# Consumir vale de tres formas, porque las tres hacen que la señal ACTUE:
# `detect: signal:<x>` en el catálogo (ofrece una capacidad), nombrarla en la
# entrevista/plantillas (recomienda una respuesta), o leerla en un gate.
sin_lector=""
while read -r s; do
  [ -n "$s" ] || continue
  grep -q "detect: \"signal:$s\"" "$CAT" && continue
  # `summary.<s>`, `index("<s>")` o `signal:<s>`: una REFERENCIA A LA SEÑAL.
  # Con `\b$s\b` a secas el gate se apagaba solo, y no en teoría: `aws` quedaba
  # "leído" por `aws-secrets-manager` y por los patrones de redacción
  # `[REDACTADO:aws]`, y `gcp` por `gcp-secret-manager`, así que las DOS señales
  # de la nube estaban huérfanas con el ratchet en verde. Se probó borrando el
  # lector de verdad: seguía pasando. Un gate que la prosa vecina satisface mide
  # la prosa, no la cadena.
  grep -rqE "summary\.$s\b|index\(\"$s\"\)|signal:$s\b" \
    "$ROOT/skills" "$ROOT/commands" "$ROOT/templates" \
    "$ROOT/scripts/doctor.sh" 2>/dev/null && continue
  # Tercera forma, la que usan las señales viejas: nombrarla en una frase que
  # habla del INVENTARIO o de las SEÑALES ("si hay CD (gha/argocd/kargo en
  # inventory)", "Detecté buf.yaml en proto → gate buf-breaking"). Eso despacha
  # de verdad, así que vale; lo que no vale es la palabra suelta en cualquier
  # contexto, que es lo que dejaba pasar a aws y gcp.
  grep -rqE "(inventor|señal|signal|detect|gate|by_role|role_guess).*\b$s\b|\b$s\b.*(inventor|señal|signal|detect|gate|by_role|role_guess)" \
    "$ROOT/skills" "$ROOT/commands" "$ROOT/scripts/doctor.sh" 2>/dev/null && continue
  sin_lector="$sin_lector $s"
done <<EOF
$emitidas
EOF
[ -z "$sin_lector" ] \
  && pass "ninguna señal emitida muere en el inventory (todas tienen catálogo, entrevista o gate)" \
  || fail "discover.sh emite señales que NADIE lee: se miden y no despachan nada, igual que no detectarlas:$sin_lector"

t_done
