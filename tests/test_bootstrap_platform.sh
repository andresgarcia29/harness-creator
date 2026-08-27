#!/usr/bin/env bash
# test_bootstrap_platform.sh: bs_install baja el artefacto de ESTA plataforma,
# contra el CÓDIGO REAL del template (issue #236).
#
# El bug: cada receta traía la plataforma escrita a mano en la URL
# (linux/amd64, linux_amd64, -linux-x64), así que en un host macOS el bootstrap
# instalaba ELFs de Linux en $BINDIR. Nada falla ahí: el archivo queda
# ejecutable, `command -v` lo ve y el doctor canta verde. El "exec format error"
# llega mucho después, en medio de una tarea y lejos de la causa.
#
# Lo que se protege acá son dos contratos:
#   1. las URLs (y los pasos post-descarga acoplados al nombre, como el `mv` de
#      node) cambian con el par os/arch, con el naming propio de CADA proveedor;
#   2. donde el proveedor no publica artefacto, la receta GRITA y no descarga
#      nada, en vez de instalar el binario de otra máquina.
# Ninguna aserción toca la red: uname y curl van de palo, y el único fetch de
# verdad se sirve de un árbol local.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

BOOT="$ROOT/templates/scripts/bootstrap.sh.tmpl"
export TMPDIR="$WS"   # los mktemp -d de las recetas mueren con el workspace

# Las recetas, verbatim del template (el mismo rango que usa test_catalog.sh).
awk '/^BINDIR=/,/^# ── ESTE BOOTSTRAP SE GENERO/' "$BOOT" | sed '$d' > "$WS/recetas.sh"
[ -s "$WS/recetas.sh" ] && pass "las recetas se extraen del template" \
                        || { fail "no pude extraer las recetas del bootstrap"; t_done; }
grep -q '^bs_platform()' "$WS/recetas.sh" \
  && pass "bs_platform vive en el template (la resolución es del código real)" \
  || fail "el template no define bs_platform"

# ── el runner: bs_install de verdad, con uname/curl/_bs_fetch de palo ──
# Solo se stubbea lo que sale de la máquina o la ensucia. La lógica que se
# prueba (bs_platform, los alias por proveedor, la interpolación de cada URL)
# es la del template, sin copiar una sola línea.
cat > "$WS/runner.sh" <<'RUNNER'
set -uo pipefail
US="$1"; UM="$2"; BINX="$3"; LOG="$4"
warn() { echo "WARN: $1"; }
ok() { :; }
. "$RECETAS"
uname() { case "${1:-}" in -m) printf '%s\n' "$UM" ;; *) printf '%s\n' "$US" ;; esac; }
curl() { printf 'v9.9.9\n'; }        # el JSON no importa: jq de palo devuelve el tag
jq()   { cat >/dev/null 2>&1; printf 'v9.9.9\n'; }
# el fetch anota QUÉ URL le pidieron (artefacto y sums) y devuelve un archivo
_bs_fetch() {
  printf 'ART %s\n' "$2" >> "$LOG"
  [ -n "${3:-}" ] && printf 'SUMS %s\n' "$3" >> "$LOG"
  : > "$1/${2##*/}"; printf '%s' "$1/${2##*/}"
}
# pasos post-descarga: se anotan los acoplados al nombre del artefacto
mv() { printf 'MV %s\n' "$1" >> "$LOG"; }
install() { :; }; tar() { :; }; unzip() { :; }; gunzip() { :; }
ln() { :; }; chmod() { :; }
bs_install "$BINX"
RUNNER

corre() {  # corre <uname -s> <uname -m> <bin> → imprime "<exit>|<log>|<salida>"
  local out rc log="$WS/log.$$"
  : > "$log"
  out="$(HOME="$WS/home" RECETAS="$WS/recetas.sh" \
         bash "$WS/runner.sh" "$1" "$2" "$3" "$log" 2>&1)"; rc=$?
  printf '%s|%s|%s' "$rc" "$(cat "$log")" "$out"
  rm -f "$log"
}
urls() { printf '%s' "$1" | sed 's/^[0-9]*|//; s/|[^|]*$//'; }

# ── bs_platform: la tabla de mapeo, sobre la función real ─────────────
plat() { HOME="$WS/home" US="$1" UM="$2" bash -c '
  . "$1"
  uname() { case "${1:-}" in -m) printf "%s\n" "$UM" ;; *) printf "%s\n" "$US" ;; esac; }
  bs_platform' _ "$WS/recetas.sh"; }
assert_eq "darwin arm64" "$(plat Darwin arm64)"   "uname Darwin/arm64  → darwin arm64"
assert_eq "darwin amd64" "$(plat Darwin x86_64)"  "uname Darwin/x86_64 → darwin amd64"
assert_eq "linux amd64"  "$(plat Linux x86_64)"   "uname Linux/x86_64  → linux amd64"
assert_eq "linux arm64"  "$(plat Linux aarch64)"  "uname Linux/aarch64 → linux arm64"
assert_eq "freebsd amd64" "$(plat FreeBSD x86_64)" "un OS ajeno no se disfraza de linux"

# ── las URLs cambian con la plataforma, con el naming de cada proveedor ──
echo "── cada receta baja el artefacto del par os/arch detectado"
espera() {  # espera <s> <m> <bin> <aguja> <nombre>
  local r; r="$(corre "$1" "$2" "$3")"
  assert_contains "$(urls "$r")" "$4" "$5"
}
# dl.k8s.io: $os/$arch en la ruta
espera Linux  x86_64 kubectl "/bin/linux/amd64/kubectl"   "kubectl en Linux/x86_64: bin/linux/amd64"
espera Darwin arm64  kubectl "/bin/darwin/arm64/kubectl"  "kubectl en Darwin/arm64: bin/darwin/arm64"
espera Linux  aarch64 kubectl "/bin/linux/arm64/kubectl"  "kubectl en Linux/aarch64: bin/linux/arm64"
# hashicorp: ${os}_${arch} en el zip, y el SHA256SUMS sigue siendo el mismo
espera Darwin arm64  terraform "terraform_v9.9.9_darwin_arm64.zip" "terraform en Darwin/arm64: _darwin_arm64.zip"
espera Linux  x86_64 vault     "vault_v9.9.9_linux_amd64.zip"      "vault en Linux/x86_64: _linux_amd64.zip"
espera Darwin arm64  vault     "SUMS https://releases.hashicorp.com/vault/v9.9.9/vault_v9.9.9_SHA256SUMS" \
                               "y el checksums de hashicorp se sigue pidiendo (verificación viva)"
# argo-cd: argocd-$os-$arch
espera Darwin amd64  argocd "download/argocd-darwin-amd64" "argocd en Darwin/x86_64: argocd-darwin-amd64"
espera Linux  x86_64 argocd "download/argocd-linux-amd64"  "argocd en Linux/x86_64: argocd-linux-amd64"
# beads: ${os}_${arch} en el tarball
espera Darwin arm64  bd "beads_9.9.9_darwin_arm64.tar.gz" "bd en Darwin/arm64: beads_..._darwin_arm64"
espera Linux  x86_64 bd "beads_9.9.9_linux_amd64.tar.gz"  "bd en Linux/x86_64: beads_..._linux_amd64"
# nodejs: x64 donde el resto dice amd64
espera Darwin arm64  npm "node-v9.9.9-darwin-arm64.tar.xz" "node en Darwin/arm64: node-...-darwin-arm64"
espera Darwin x86_64 npm "node-v9.9.9-darwin-x64.tar.xz"   "node en Darwin/x86_64: x64, no amd64"
espera Linux  x86_64 npm "node-v9.9.9-linux-x64.tar.xz"    "node en Linux/x86_64: node-...-linux-x64"
# observeinc/cli: el mismo x64 de node
espera Darwin arm64  observe "observe-darwin-arm64.gz" "observe en Darwin/arm64: observe-darwin-arm64.gz"
espera Linux  x86_64 observe "observe-linux-x64.gz"    "observe en Linux/x86_64: x64, no amd64"
# Google: x86_64 y "arm" a secas
espera Darwin arm64  gcloud "google-cloud-cli-darwin-arm.tar.gz"    "gcloud en Darwin/arm64: darwin-arm (no arm64)"
espera Linux  x86_64 gcloud "google-cloud-cli-linux-x86_64.tar.gz"  "gcloud en Linux/x86_64: linux-x86_64"
# AWS: aarch64 en Linux
espera Linux  aarch64 awscli "awscli-exe-linux-aarch64.zip" "awscli en Linux/aarch64: aarch64"

echo "── el paso post-descarga acoplado al nombre usa la MISMA plataforma"
# El tarball de node se expande a un directorio con la plataforma en el nombre.
# Un `mv node-$v-linux-x64` cableado rompe la instalación aunque la descarga
# haya sido la correcta, y el fallo se lee como "no such file or directory".
r="$(corre Darwin arm64 npm)"
assert_contains "$(urls "$r")" "MV " "el mv de node se ejecuta"
assert_contains "$(urls "$r")" "node-v9.9.9-darwin-arm64" "el mv de node usa darwin-arm64, no linux-x64"
assert_not_contains "$(urls "$r")" "MV $WS/node-v9.9.9-linux-x64" "y no busca el directorio de Linux"

echo "── sin artefacto para la plataforma: RUIDO, y cero descargas"
# awscli publica el zip con `aws/install` SOLO para Linux; en macOS es un .pkg.
r="$(corre Darwin arm64 awscli)"
[ "${r%%|*}" -ne 0 ] && pass "awscli en macOS: la receta sale != 0 (ensure lo reporta)" \
                     || fail "awscli en macOS salió 0: ensure lo contaría como instalado"
assert_not_contains "$(urls "$r")" "ART " "y no baja NADA (nada de ELFs de Linux en el PATH)"
assert_contains "${r##*|}" "no hay binario de 'awscli' para darwin/arm64" "y dice el par que no tiene binario"
assert_contains "${r##*|}" "linux/amd64 linux/arm64" "y lista las plataformas que el proveedor sí publica"
assert_contains "${r##*|}" "brew install awscli" "con la remediación de macOS (regla 5)"

# Una plataforma que nadie publica (32 bits, un BSD) tampoco se aproxima.
r="$(corre Linux i686 kubectl)"
[ "${r%%|*}" -ne 0 ] && pass "kubectl en linux/i686: sale != 0" || fail "kubectl en linux/i686 salió 0"
assert_not_contains "$(urls "$r")" "ART " "y no descarga un binario de otra arquitectura"
assert_contains "${r##*|}" "no hay binario de 'kubectl' para linux/i686" "nombrando el par real"
r="$(corre FreeBSD x86_64 bd)"
assert_contains "${r##*|}" "no hay binario de 'bd' para freebsd/amd64" "un OS ajeno se nombra, no se traduce"
assert_not_contains "$(urls "$r")" "ART " "y tampoco descarga"

echo "── ratchet: ninguna receta vuelve a cablear una plataforma"
# Se miran las líneas de CÓDIGO (los comentarios explican el bug y nombran esos
# strings; un gate que se dispara con la prosa que lo documenta se apaga solo).
cuerpo="$(awk '/^bs_install\(\)/,/^}/' "$BOOT" | sed 's/[ \t]*#.*$//')"
cableada=0
for p in "linux/amd64/" "linux_amd64" "-linux-x64" "linux-x86_64" "-linux-amd64" "linux-aarch64"; do
  case "$cuerpo" in
    *"$p"*) fail "una receta de bs_install cablea '$p' en vez de usar \$os/\$arch"; cableada=1 ;;
  esac
done
[ "$cableada" -eq 0 ] && pass "las recetas interpolan la plataforma, no la escriben"

echo "── el checksum sigue verificando con el nombre parametrizado (#192 + #236)"
# El sums publicado indexa por NOMBRE de artefacto. Si la URL cambia de
# plataforma y la búsqueda de la línea no, la verificación se vuelve un "no
# encuentro su linea" y la receta corta SIEMPRE. Acá se corre el _bs_fetch de
# verdad contra un árbol local: binario bueno instala, binario manipulado no.
KB="$WS/e2e"; mkdir -p "$KB/bin" "$KB/srv/release/v9.9.9/bin/darwin/arm64" "$KB/home"
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
case "${out:-}" in
  ""|"$SRVDIR"*|/var/*|/tmp/*|/private/*) ;;
  *) echo "curl de palo: me pidieron escribir fuera del test ($out)" >&2; exit 23 ;;
esac
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
CURLEOF
chmod +x "$KB/bin/curl"
printf 'yo soy kubectl de darwin/arm64\n' > "$KB/srv/release/v9.9.9/bin/darwin/arm64/kubectl"
printf 'v9.9.9' > "$KB/srv/release/stable.txt"
( cd "$KB/srv/release/v9.9.9/bin/darwin/arm64" \
  && { command -v sha256sum >/dev/null 2>&1 && sha256sum kubectl || shasum -a 256 kubectl; } \
     | awk '{print $1}' > kubectl.sha256 )

corre_real() {  # bs_install con curl de palo, uname de palo y HOME propio
  ( export PATH="$KB/bin:$PATH" SRVDIR="$KB/srv" HOME="$KB/home"
    warn() { echo "WARN: $1"; }
    . "$WS/recetas.sh"
    uname() { case "${1:-}" in -m) echo arm64 ;; *) echo Darwin ;; esac; }
    bs_install kubectl ) >/dev/null 2>&1
}
DEST="$KB/home/.local/bin/kubectl"
rm -f "$DEST"; corre_real; rc=$?
assert_eq 0 "$rc" "en Darwin/arm64 la receta baja del árbol darwin/arm64 y sale 0"
[ -x "$DEST" ] && pass "y lo instala en el bin del usuario" || fail "no instaló el binario bueno"
printf 'yo soy kubectl MANIPULADO\n' > "$KB/srv/release/v9.9.9/bin/darwin/arm64/kubectl"
rm -f "$DEST"; corre_real; rc=$?
[ "$rc" -ne 0 ] && pass "binario manipulado: corta igual que antes (el sha256 sigue vivo)" \
                || fail "el checksum dejó de frenar con el artefacto parametrizado"
assert_no_file "$DEST" "y NO lo instala"

# el template completo sigue parseando con la resolución nueva adentro
python3 - "$BOOT" "$WS/boot.sh" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
open(sys.argv[2], 'w').write(re.sub(r'\{\{[A-Z_]+\}\}', '', src))
PY
bash -n "$WS/boot.sh" && pass "bootstrap.sh.tmpl parsea" || fail "bootstrap.sh.tmpl no parsea"

t_done
