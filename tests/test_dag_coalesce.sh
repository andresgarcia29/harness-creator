#!/usr/bin/env bash
# test_dag_coalesce.sh: el paralelo DENTRO de un repo, y su rollback.
#
# La cadena completa: dag.json schema 2 con files[] disjuntos → un worktree por
# nodo → cherry-pick determinista sobre task/<id>. Y las dos negativas, que son
# las que sostienen la promesa: files[] que se pisan NO pasan el validador, y un
# conflicto deja el árbol EXACTAMENTE como estaba (no a medias).
set -u
. "$(dirname "$0")/lib.sh"
root="$(cd "$(dirname "$0")/.." && pwd)"

t_ws
mkdir -p "$WS/scripts" "$WS/tasks/T-1"
cp "$root/templates/scripts/worktree-task.sh" "$root/templates/scripts/dag-coalesce.sh" \
   "$root/templates/scripts/harness-policy.py" "$root/templates/scripts/emit.sh" "$WS/scripts/"
# gowork.sh y fe.sh los llama worktree-task.sh; acá no hay stack que preparar.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/scripts/gowork.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/scripts/fe.sh"
chmod +x "$WS/scripts/gowork.sh" "$WS/scripts/fe.sh"
sed 's/{{LOOP_BUDGET}}/3/' "$root/templates/policy.json.tmpl" > "$WS/harness-policy.json"

# ── un "remoto" y su clon canónico, como en el workspace de verdad ────
origen="$WS/origen.git"
git init -q --bare "$origen"
sem="$WS/semilla"; mkdir -p "$sem"
( cd "$sem" && git init -q -b main && printf 'uno\n' > a.txt && printf 'uno\n' > b.txt \
  && git add -A && git commit -qm base && git remote add origin "$origen" && git push -q origin main )
mkdir -p "$WS/repos"
git clone -q "$origen" "$WS/repos/atlas"
git -C "$WS/repos/atlas" remote set-head origin main >/dev/null 2>&1

wt() { bash "$WS/scripts/worktree-task.sh" "$@" 2>&1; }

echo "── un worktree por NODO: árbol propio, rama propia"
out="$(wt T-1 atlas)"                     # el árbol base, destino del coalesce
out="$out$(wt --node T1 T-1 atlas)"
out="$out$(wt --node T2 T-1 atlas)"
assert_file "$WS/worktrees/T-1/atlas@T1/a.txt" "worktrees/T-1/atlas@T1 existe"
assert_file "$WS/worktrees/T-1/atlas@T2/a.txt" "worktrees/T-1/atlas@T2 también"
assert_eq "task/T-1@T1" "$(git -C "$WS/worktrees/T-1/atlas@T1" symbolic-ref --short HEAD)" \
  "y cada uno en SU rama (con @, no con / : refs/heads/task/T-1 ya existe)"
assert_eq "task/T-1" "$(git -C "$WS/worktrees/T-1/atlas" symbolic-ref --short HEAD)" \
  "el árbol base conserva la rama de la tarea"

echo
echo "── nodos que declaran archivos disjuntos: el DAG los deja en paralelo"
cat > "$WS/tasks/T-1/dag.json" <<'JSON'
{"schema": 2,
 "tasks": [{"id": "T1", "repo": "atlas", "depends_on": [], "files": ["a.txt"]},
           {"id": "T2", "repo": "atlas", "depends_on": [], "files": ["b.txt"]}]}
JSON
out="$(python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" \
        validate-dag "$WS/tasks/T-1/dag.json" 2>&1)"; rc=$?
assert_eq 0 "$rc" "validate-dag pasa con files[] disjuntos"
assert_contains "$out" "DAG válido" "y lo dice"

echo
echo "── los mismos dos nodos SIN files[]: fail-closed, se serializan"
cat > "$WS/tasks/T-1/mal.json" <<'JSON'
{"schema": 2,
 "tasks": [{"id": "T1", "repo": "atlas", "depends_on": []},
           {"id": "T2", "repo": "atlas", "depends_on": []}]}
JSON
out="$(python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" \
        validate-dag "$WS/tasks/T-1/mal.json" 2>&1)"; rc=$?
assert_eq 3 "$rc" "schema:2 sin files[] no pasa"
assert_contains "$out" "POLICY-DAG-011" "con código propio, no con el genérico"

echo
echo "── y con files[] que SE PISAN tampoco (la premisa de DAG-010 sigue viva)"
cat > "$WS/tasks/T-1/pisan.json" <<'JSON'
{"schema": 2,
 "tasks": [{"id": "T1", "repo": "atlas", "depends_on": [], "files": ["a.txt"]},
           {"id": "T2", "repo": "atlas", "depends_on": [], "files": ["a.txt", "b.txt"]}]}
JSON
out="$(python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" \
        validate-dag "$WS/tasks/T-1/pisan.json" 2>&1)"; rc=$?
assert_eq 3 "$rc" "files[] solapados no pasan"
assert_contains "$out" "SE PISAN: a.txt" "y nombra el archivo compartido"

echo
echo "── el coalesce: cada nodo commitea en su árbol y se junta en task/<id>"
( cd "$WS/worktrees/T-1/atlas@T1" && printf 'de T1\n' >> a.txt && git add -A && git commit -qm "T1: a.txt" )
( cd "$WS/worktrees/T-1/atlas@T2" && printf 'de T2\n' >> b.txt && git add -A && git commit -qm "T2: b.txt" )
out="$(bash "$WS/scripts/dag-coalesce.sh" T-1 atlas --dry-run 2>&1)"
assert_contains "$out" "dry-run" "el dry-run no toca nada"
assert_eq 1 "$(git -C "$WS/worktrees/T-1/atlas" rev-list --count HEAD)" "y de verdad no commiteó"
out="$(bash "$WS/scripts/dag-coalesce.sh" T-1 atlas 2>&1)"
assert_contains "$out" "2 nodo(s) aplicados" "trae los dos nodos"
assert_eq 3 "$(git -C "$WS/worktrees/T-1/atlas" rev-list --count HEAD)" "3 commits: base + T1 + T2"
assert_contains "$(cat "$WS/worktrees/T-1/atlas/a.txt")" "de T1" "el trabajo de T1 aterrizó"
assert_contains "$(cat "$WS/worktrees/T-1/atlas/b.txt")" "de T2" "y el de T2 también"

echo
echo "── re-correrlo es seguro: compara por PARCHE, no por sha"
out="$(bash "$WS/scripts/dag-coalesce.sh" T-1 atlas 2>&1)"
assert_contains "$out" "ya estaba" "el segundo coalesce no duplica nada"
assert_eq 3 "$(git -C "$WS/worktrees/T-1/atlas" rev-list --count HEAD)" "siguen siendo 3 commits"

echo
echo "── conflicto: el árbol queda como estaba y el nodo vuelve a serie"
wt --node T3 T-1 atlas >/dev/null
( cd "$WS/worktrees/T-1/atlas@T3" && printf 'otra cosa\n' >> a.txt && git add -A && git commit -qm "T3: a.txt" )
cat > "$WS/tasks/T-1/dag.json" <<'JSON'
{"schema": 2,
 "tasks": [{"id": "T1", "repo": "atlas", "depends_on": [], "files": ["a.txt"]},
           {"id": "T2", "repo": "atlas", "depends_on": [], "files": ["b.txt"]},
           {"id": "T3", "repo": "atlas", "depends_on": ["T1"], "files": ["a.txt"]}]}
JSON
antes="$(git -C "$WS/worktrees/T-1/atlas" rev-parse HEAD)"
out="$(bash "$WS/scripts/dag-coalesce.sh" T-1 atlas 2>&1)"; rc=$?
assert_eq 3 "$rc" "sale 3: hay un nodo que hay que re-implementar"
assert_contains "$out" "CONFLICTO coalesciendo T3" "y dice cuál"
assert_contains "$out" "EN SERIE" "con la degradación prevista escrita"
assert_eq "$antes" "$(git -C "$WS/worktrees/T-1/atlas" rev-parse HEAD)" \
  "el árbol quedó DONDE ESTABA: el cherry-pick se abortó entero"
assert_eq "" "$(git -C "$WS/worktrees/T-1/atlas" status --porcelain)" \
  "y limpio: ningún gate va a medir un árbol a medias"

echo
echo "── un commit POSTERIOR al coalesce no se tira: la marca no alcanza"
# La marca dice "esto se coalescio", no "no quedo nada". Un implementer que
# siguio commiteando en el nodo despues del coalesce tiene trabajo sin publicar,
# y `branch -D` lo destruiria sin preguntar (el cherry-pick cambia el sha, asi
# que git lo ve como "sin mergear" y `-d` no sirve de red). Se le pregunta a git
# si queda algo por PARCHE.
( cd "$WS/worktrees/T-1/atlas@T2" && printf 'tarde\n' >> b.txt \
  && git add -A && git commit -qm "T2: algo despues del coalesce" )

echo
echo "── ISSUE #162: el nodo DEPENDIENTE nace CON sus dependencias adentro"
# worktree-task.sh --node hacía nacer TODA rama de nodo de la trunk. Para el
# nodo independiente es correcto y deliberado (que no se dupliquen los commits
# de los hermanos en el cherry-pick), pero con `depends_on` no vacío significa
# nacer SIN aquello de lo que dependés. El modo de falla no es un rojo: el
# implementer que no encuentra su dependencia la RE-IMPLEMENTA, y eso aparece
# recién como conflicto en el coalesce, con los tokens ya gastados.
mkdir -p "$WS/tasks/T-2"
cat > "$WS/tasks/T-2/dag.json" <<'JSON'
{"schema": 2,
 "tasks": [{"id": "T1", "repo": "atlas", "depends_on": [],     "files": ["a.txt"]},
           {"id": "T2", "repo": "atlas", "depends_on": ["T1"], "files": ["b.txt"]},
           {"id": "T4", "repo": "atlas", "depends_on": [],     "files": ["e.txt"]},
           {"id": "T5", "repo": "atlas", "depends_on": ["T4"], "files": ["f.txt"]},
           {"id": "T9", "repo": "otro",  "depends_on": [],     "files": ["c.txt"]},
           {"id": "T8", "repo": "atlas", "depends_on": ["T9"], "files": ["d.txt"]}]}
JSON
wt T-2 atlas >/dev/null                       # el árbol base, destino del coalesce

# CONTRA-MITAD, y no es decorativa: sin ella este bloque pasaría igual con un
# arreglo que mandara TODO nodo a nacer de task/<id>, que es justo la duplicación
# que el diseño original evita.
out="$(wt --node T1 T-2 atlas)"
assert_not_contains "$out" "nace de task/T-2" \
  "#162: sin depends_on, la rama sigue naciendo de la trunk"

# T1 hace su trabajo y se coalesce: recién ahí task/T-2 lo tiene adentro.
( cd "$WS/worktrees/T-2/atlas@T1" || exit 1
  printf 'clave nueva\n' >> a.txt && git add -A && git commit -qm "T1: a.txt" )
bash "$WS/scripts/dag-coalesce.sh" T-2 atlas >/dev/null 2>&1

out="$(wt --node T2 T-2 atlas)"
assert_contains "$out" "T2 depende de T1 en atlas" "#162: nombra la dependencia que hereda"
assert_contains "$out" "nace de task/T-2" "#162: y de dónde nace la rama"
assert_contains "$(cat "$WS/worktrees/T-2/atlas@T2/a.txt")" "clave nueva" \
  "#162: el árbol del nodo dependiente TRAE el trabajo del que depende"

# Y heredar NO reintroduce la duplicación: el coalesce compara por parche, así
# que lo que ya es ancestro no se vuelve a aplicar.
( cd "$WS/worktrees/T-2/atlas@T2" || exit 1
  printf 'de T2\n' >> b.txt && git add -A && git commit -qm "T2: b.txt" )
bash "$WS/scripts/dag-coalesce.sh" T-2 atlas >/dev/null 2>&1
assert_eq 3 "$(git -C "$WS/worktrees/T-2/atlas" rev-list --count HEAD)" \
  "#162: base + T1 + T2 y nada más: heredar no duplicó el commit de T1"

# Una dependencia en OTRO repo no se hereda acá: el árbol de atlas no tiene nada
# que traer de un nodo de otro repo, y anunciar que sí sería la misma mentira.
out="$(wt --node T8 T-2 atlas)"
assert_not_contains "$out" "nace de task/T-2" \
  "#162: una dependencia en otro repo no cambia de dónde nace este árbol"

# Declarada pero SIN coalescer: que la rama exista no prueba que la dependencia
# esté adentro. Se dice, que es lo único que evita el trabajo duplicado.
out="$(wt --node T5 T-2 atlas)"
assert_contains "$out" "T4 todavía no se coalesció" \
  "#162: avisa que la dependencia declarada no está en la rama todavía"
assert_contains "$out" "dag-coalesce.sh T-2 atlas" "con el comando que falta"

# Y sin árbol base no se inventa la rama: se avisa que nace sin sus dependencias.
mkdir -p "$WS/tasks/T-3"
sed 's/T-2/T-3/' "$WS/tasks/T-2/dag.json" > "$WS/tasks/T-3/dag.json"
out="$(wt --node T2 T-3 atlas)"
assert_contains "$out" "no existe la rama task/T-3" "#162: sin árbol base lo dice"
assert_contains "$out" "SIN el trabajo del que depende" "y qué significa eso"
assert_contains "$out" "worktree-task.sh T-3 atlas" "con la remediación en orden"

echo
echo "── --rm entiende los worktrees de nodo (si no, el repo queda trabado)"
out="$(wt --rm T-1)"
assert_contains "$(git -C "$WS/repos/atlas" branch --list 'task/T-1@T2')" "task/T-1@T2" \
  "la rama del nodo con trabajo NUEVO se CONSERVA, aunque tenga marca de coalescida"
assert_no_file "$WS/worktrees/T-1/atlas@T1" "el worktree del nodo se fue"
assert_contains "$out" "removido" "lo dice"
# La rama de T1 se coalesció: sus commits viven en task/T-1 con OTRO sha, así
# que `branch -d` los vería como "sin mergear" y la conservaría para siempre.
assert_not_contains "$(git -C "$WS/repos/atlas" branch --list 'task/T-1@T1')" "task/T-1@T1" \
  "y su rama también (dag-coalesce dejó la marca de que ya está adentro)"
assert_contains "$(git -C "$WS/repos/atlas" branch --list 'task/T-1@T3')" "task/T-1@T3" \
  "pero la del nodo que NO coalesció se CONSERVA: tiene trabajo sin publicar"

t_done
