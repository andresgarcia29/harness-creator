#!/usr/bin/env bash
# dag-coalesce.sh: junta el trabajo de los NODOS del DAG en la rama de la tarea.
#
# POR QUÉ EXISTE: con `files[]` disjuntos declarados (dag.json schema 2), las
# tareas del DAG que comparten repo ya no se serializan: cada nodo trabaja en su
# propio árbol (`worktrees/<task>/<repo>@<Tn>`, rama `task/<id>@<Tn>`). Medido:
# cadenas de 80 min por 6 tareas, 50 por 4, 36 por 6, contra una cota paralela
# (el nodo más lento) de 6 a 15 minutos. Pero review, precheck, QA y ship operan
# sobre UN árbol y UNA rama, así que alguien tiene que juntar lo que se hizo en
# paralelo. Ese alguien es este script, y es DETERMINISTA a propósito: cero
# tokens, cero criterio, el orden lo pone el DAG.
#
# Uso:
#   dag-coalesce.sh <task-id> <repo>            coalesce todos los nodos del repo
#   dag-coalesce.sh <task-id> <repo> --dry-run  qué haría, sin tocar nada
#
# QUÉ HACE, exactamente: por cada nodo del repo en orden topológico del DAG,
# hace cherry-pick de los commits de `task/<id>@<Tn>` que no estén ya en
# `task/<id>`, sobre el árbol base `worktrees/<task>/<repo>`.
#
# ── EL CONFLICTO ES EL ROLLBACK, Y ES POR NODO ────────────────────────
# Si un cherry-pick entra en conflicto, este script ABORTA ese cherry-pick (deja
# el árbol exactamente como estaba antes de tocarlo) y sale 3 nombrando el nodo.
# Eso NO es una falla del harness: es la degradación prevista. Ese nodo vuelve a
# implementarse en serie sobre el árbol ya coalescido, que es la conducta de
# siempre. Lo que no puede pasar es que un conflicto deje un árbol a medias con
# un cherry-pick abierto, porque a partir de ahí ningún gate mide lo que cree
# medir.
set -uo pipefail

TASK="${1:?uso: dag-coalesce.sh <task-id> <repo> [--dry-run]}"
REPO="${2:?uso: dag-coalesce.sh <task-id> <repo> [--dry-run]}"
DRY=""
[ "${3:-}" = "--dry-run" ] && DRY=1

WS="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$WS/scripts/emit.sh" ] && . "$WS/scripts/emit.sh" || emit() { :; }

BASE_WT="$WS/worktrees/$TASK/$REPO"
DAG="$WS/tasks/$TASK/dag.json"

[ -f "$DAG" ] || {
  echo "❌ no existe $DAG: sin DAG no hay nodos que juntar."
  echo "   Los carriles sin DAG (quick, express) no coalescen nada: su trabajo"
  echo "   ya vive en task/$TASK."
  exit 2
}
# `-e` y no `-d`: en un worktree, `.git` es un ARCHIVO que apunta al gitdir
# real. Con `-d` este chequeo rechazaba justamente el caso normal.
[ -e "$BASE_WT/.git" ] || {
  echo "❌ no existe el árbol base worktrees/$TASK/$REPO."
  echo "   Es el destino del coalesce: creálo con"
  echo "     bash scripts/worktree-task.sh $TASK $REPO"
  exit 2
}

# El orden lo pone el DAG, y se lo pedimos al policy engine: reimplementarlo acá
# en awk sería una segunda definición del mismo orden, o sea una oportunidad de
# divergir justo donde el orden decide si hay conflicto.
nodos="$(python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" \
          dag-nodes "$WS/tasks/$TASK" --repo "$REPO" 2>&1)" || {
  echo "❌ no pude leer el orden del DAG:"
  printf '%s\n' "$nodos" | sed 's/^/   /'
  exit 2
}
nodos="$(printf '%s\n' "$nodos" | awk -F'\t' 'NF{print $1}')"
[ -n "$nodos" ] && [ "$nodos" != "" ] || {
  echo "ℹ️  el DAG no declara nodos para $REPO: nada que coalescer"
  exit 0
}

# Un árbol sucio no se coalesce: el cherry-pick se llevaría por delante cambios
# sin commitear, y eso no se recupera de ningún lado.
sucio="$(git -C "$BASE_WT" status --porcelain 2>&1)" || {
  echo "❌ no pude inspeccionar $BASE_WT: $(printf '%s' "$sucio" | head -1)"; exit 2; }
[ -z "$sucio" ] || {
  echo "❌ el árbol base tiene cambios sin commitear: no coalesco encima."
  printf '%s\n' "$sucio" | sed 's/^/   /'
  exit 2
}
# Y tampoco con un cherry-pick o un merge a medio camino de una corrida anterior.
# Las rutas se le PREGUNTAN a git (`rev-parse --git-path`): en un worktree el
# gitdir no es `<árbol>/.git` sino `.git/worktrees/<nombre>/` del repo canónico,
# así que componer la ruta a mano daba un chequeo que nunca encontraba nada.
# El `cd` importa: --git-path puede contestar una ruta RELATIVA al árbol, así
# que preguntarla desde otro directorio y probarla acá daría siempre "no existe".
git_path_existe() {  # git_path_existe <nombre> → 0 si el archivo de git existe
  ( cd "$BASE_WT" 2>/dev/null || exit 1
    p="$(git rev-parse --git-path "$1" 2>/dev/null)" || exit 1
    [ -e "$p" ] )
}
if git_path_existe CHERRY_PICK_HEAD || git_path_existe rebase-merge; then
  echo "❌ hay una operación de git a medio terminar en $BASE_WT."
  echo "   ↳ resolvela o abortala (git -C $BASE_WT cherry-pick --abort) y re-corré."
  exit 2
fi

aplicados=0; saltados=0
for nodo in $nodos; do
  rama="task/$TASK@$nodo"
  if ! git -C "$BASE_WT" show-ref --verify --quiet "refs/heads/$rama"; then
    echo "→ $nodo: sin rama $rama (ese nodo no usó worktree propio): nada que traer"
    saltados=$((saltados+1))
    continue
  fi
  # Los commits del nodo que TODAVÍA no están en la rama de la tarea, del más
  # viejo al más nuevo. `--cherry-pick --right-only` los compara por PARCHE, no
  # por sha: un nodo que ya se coalesció (o cuyo commit llegó por otro camino)
  # no se aplica dos veces, y esa es la propiedad que hace re-correr este script
  # seguro.
  commits="$(git -C "$BASE_WT" rev-list --reverse --no-merges \
               --cherry-pick --right-only "HEAD...$rama" 2>/dev/null || true)"
  if [ -z "$commits" ]; then
    echo "→ $nodo: ya estaba en task/$TASK: nada que hacer"
    saltados=$((saltados+1))
    touch "$WS/tasks/$TASK/.coalesced-${REPO}@${nodo}" 2>/dev/null || true
    continue
  fi
  n="$(printf '%s\n' "$commits" | grep -c . || true)"
  if [ -n "$DRY" ]; then
    echo "→ $nodo: traería $n commit(s) de $rama"
    aplicados=$((aplicados+1))
    continue
  fi
  echo "→ $nodo: cherry-pick de $n commit(s) desde $rama"
  # Uno por uno y no en rango: con el rango, un conflicto en el tercero deja los
  # dos primeros aplicados y la secuencia abierta, y el abort de git deshace TODO
  # (incluido trabajo de nodos anteriores que ya estaba bien). De a uno, lo que
  # se pierde ante un conflicto es exactamente el commit que conflictúa.
  for c in $commits; do
    if git -C "$BASE_WT" cherry-pick -x "$c" >/dev/null 2>&1; then
      continue
    fi
    git -C "$BASE_WT" cherry-pick --abort >/dev/null 2>&1 || true
    echo
    echo "⚠️  CONFLICTO coalesciendo $nodo (commit ${c:0:12}) en $REPO."
    echo "   El árbol quedó como estaba: el cherry-pick se abortó entero."
    echo "   Esto NO es un rojo del harness, es la degradación prevista: los"
    echo "   archivos declarados eran disjuntos pero el parche no aplicó, así que"
    echo "   ese nodo vuelve a implementarse EN SERIE sobre el árbol coalescido."
    echo "   ↳ 1. los nodos anteriores ya están aplicados: no se re-implementan"
    echo "     2. re-implementá $nodo en worktrees/$TASK/$REPO (árbol base)"
    echo "     3. cuando termine, seguí con precheck y review como siempre"
    emit decision "coalesce de $REPO: el nodo $nodo conflictúa, vuelve a serie" false "$TASK"
    exit 3
  done
  touch "$WS/tasks/$TASK/.coalesced-${REPO}@${nodo}" 2>/dev/null || true
  aplicados=$((aplicados+1))
done

if [ -n "$DRY" ]; then
  echo "── dry-run: $aplicados nodo(s) traerían trabajo, $saltados sin nada que traer"
  exit 0
fi
echo "✅ coalesce de $REPO: $aplicados nodo(s) aplicados, $saltados sin nada que traer"
echo "   El árbol de review/precheck/QA/ship es worktrees/$TASK/$REPO, como siempre."
emit phase "$REPO: junté el trabajo de $aplicados nodo(s) del DAG en task/$TASK" true "$TASK"
