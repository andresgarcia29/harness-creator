#!/usr/bin/env bash
# test_archived_repos.sh: un repo ARCHIVADO en el forge se ignora SIEMPRE.
#
# Esta muerto por decision explicita de alguien y es de solo lectura. Si entra,
# contamina el grafo con simbolos que nadie mantiene, hace que un explorador
# cite codigo que no se puede tocar, y su brief viaja DENTRO del prompt del
# implementer como si fuera material vivo, que es la forma mas cara de
# contaminar porque no se ve.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

R="$ROOT/templates/scripts"
mkdir -p "$WS/scripts" "$WS/repos/vivo" "$WS/repos/muerto" "$WS/.cache"
cp "$R/archived-repos.sh" "$R/forge.sh" "$R/repo-brief.sh" "$R/graph-refresh.sh" "$WS/scripts/"
chmod +x "$WS/scripts"/*.sh
for r in vivo muerto; do
  ( cd "$WS/repos/$r" && git init -q . && git config user.email t@t && git config user.name t
    echo x > a.txt && git add -A && git commit -qm x ) >/dev/null 2>&1
done

echo "── la consulta se cachea, y el cache manda"
printf 'muerto\n' > "$WS/.cache/archived-repos.txt"
bash "$WS/scripts/archived-repos.sh" is muerto && pass "reconoce el archivado" || fail "no reconoce el archivado"
bash "$WS/scripts/archived-repos.sh" is vivo && fail "marco vivo como archivado" || pass "no marca de mas"

echo "── el brief de un archivado NO se genera (no viaja al prompt)"
out="$(bash "$WS/scripts/repo-brief.sh" muerto 2>&1)"
assert_contains "$out" "ARCHIVADO" "lo dice en vez de callarse"
assert_no_file "$WS/.cache/briefs/muerto.md" "y NO deja brief del archivado"
bash "$WS/scripts/repo-brief.sh" vivo >/dev/null 2>&1
assert_file "$WS/.cache/briefs/vivo.md" "el repo vivo sí tiene brief"

echo "── el grafo lo salta, y lo dice"
# graph-refresh sale 0 en silencio si no encuentra `graphify`. Sin este stub el
# test pasaba solo en máquinas que lo tienen instalado: en CI salía por la
# primera línea sin llegar nunca al bucle que este bloque verifica.
mkdir -p "$WS/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/bin/graphify"
chmod +x "$WS/bin/graphify"
out="$( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/graph-refresh.sh 2>&1 )"
assert_contains "$out" "muerto" "nombra el repo que salta"
assert_contains "$out" "archivado" "y por qué lo salta"

echo "── sin cache no se inventa una lista (ausencia != vacio)"
rm -f "$WS/.cache/archived-repos.txt" "$WS/.cache/briefs/vivo.md"
bash "$WS/scripts/repo-brief.sh" vivo >/dev/null 2>&1
assert_file "$WS/.cache/briefs/vivo.md" "sin cache, todo se trata como vivo"

echo "── 'no pude mirar' NO se cuenta como archivado"
fg="$(cat "$R/forge.sh")"
assert_contains "$fg" "forge_is_archived" "la capa de forge contesta la pregunta"
assert_contains "$fg" "3 = NO pude averiguarlo" "y distingue no-saber de saber"
ar="$(cat "$R/archived-repos.sh")"
assert_contains "$ar" "se tratan como VIVOS" "ante la duda no se esconde nada"

echo "── la ley esta escrita donde el agente la lee"
assert_contains "$(cat "$ROOT/templates/CLAUDE.md.tmpl")" "ARCHIVADO" "CLAUDE.md declara la ley"
assert_contains "$(cat "$ROOT/scripts/doctor.sh")" "archived-repos" "y el doctor la vigila"

t_done
