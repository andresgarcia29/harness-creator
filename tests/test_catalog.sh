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
    function flush() { if (name != "" && bin != "") printf "%s\t%s\n", bin, inst }
    /^  - name:/      { flush(); name=$3; bin=""; inst="" }
    /^    bin:/       { bin=$2 }
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
while IFS="$(printf '\t')" read -r bin inst; do
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
while IFS="$(printf '\t')" read -r bin inst; do
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

echo "── el bootstrap generado con TODO el catálogo parsea (bash -n)"

# instancia el template exactamente como el generador: una línea por capacidad
lines="$WS/ensure.txt"; : > "$lines"
while IFS="$(printf '\t')" read -r bin inst; do
  [ -n "$bin" ] && [ -n "$inst" ] || continue
  case "$inst" in
    http://*|https://*) printf 'require %s "%s"\n' "$bin" "$inst" >> "$lines" ;;
    *)                  printf 'ensure %s %s\n'   "$bin" "$inst" >> "$lines" ;;
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

t_done
