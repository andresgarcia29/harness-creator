#!/usr/bin/env bash
# worktree-task.sh — una tarea = un worktree por repo. Nunca el clon base.
#
# Uso:
#   worktree-task.sh <task-id> <repo> [repo...]   crea worktrees de la tarea
#   worktree-task.sh --rm <task-id>               quita los worktrees (post-ship)
set -euo pipefail
WS="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--rm" ]; then
  TASK="${2:?uso: worktree-task.sh --rm <task-id>}"
  for wt in "$WS/worktrees/$TASK"/*/; do
    [ -d "$wt" ] || continue
    repo="$(basename "$wt")"
    # "No pude mirar" NO es "está limpio". Con 2>/dev/null, un git que falla
    # devolvía cadena vacía y el worktree se borraba igual.
    if ! st="$(git -C "$wt" status --porcelain 2>&1)"; then
      echo "⚠️  no pude inspeccionar $wt, NO lo quito. Motivo: $(printf '%s' "$st" | head -1)"
      continue
    fi
    if [ -n "$st" ]; then
      echo "⚠️  $wt tiene cambios sin commitear — NO lo quito. Shippea o descarta primero."
      continue
    fi
    git -C "$WS/repos/$repo" worktree remove "$wt" && echo "🧹 removido: $wt"
    # UN ÁRBOL LIMPIO NO SIGNIFICA TRABAJO PUBLICADO. Los commits sin shippear
    # también dejan el worktree limpio, y `branch -D` los borraba sin
    # preguntar: solo recuperables por reflog, cosa que ningún agente hace.
    # Caso real: en una tarea multi-repo, el --rm que corre /ship tras shippear
    # el repo A destruía la rama del repo B, que estaba lista y sin publicar.
    #
    # `branch -d` (minúscula) YA implementa exactamente el chequeo que hacía
    # falta: se niega si la rama tiene commits sin mergear. El bug era estar
    # pisándolo con la mayúscula.
    if git -C "$WS/repos/$repo" branch -d "task/$TASK" 2>/dev/null; then
      echo "   🧹 rama task/$TASK borrada (su trabajo ya está publicado)"
    elif git -C "$WS/repos/$repo" show-ref --verify --quiet "refs/heads/task/$TASK"; then
      n="$(git -C "$WS/repos/$repo" rev-list --count "task/$TASK" --not --remotes 2>/dev/null || echo "?")"
      echo "   ⚠️  CONSERVO la rama task/$TASK de $repo: tiene $n commit(s) sin publicar."
      echo "      Si de verdad querés descartar ese trabajo, es tu decisión y es explícita:"
      echo "      git -C repos/$repo branch -D task/$TASK"
    fi
  done
  # Si ya no queda ningún worktree de repo, borra el dir de la tarea. rmdir no basta:
  # gowork.sh/py.sh (go.work, shims) dejan debris fuera de los worktrees y el rmdir
  # no-recursivo falla. Sólo rm -rf si no sobrevive un worktree con trabajo sin shippear.
  # Los reclamos de guard-worktree.sh mueren con su worktree: si no, el
  # siguiente que cree ese mismo par task/repo arranca bloqueado por una
  # sesión que ya no existe (caducarían solos, pero tras una hora de espera
  # que nadie tiene por qué pagar).
  rm -f "$WS/.harness/claims/${TASK}__"*.json 2>/dev/null || true
  if ! ls -d "$WS/worktrees/$TASK"/*/ >/dev/null 2>&1; then
    rm -rf "$WS/worktrees/$TASK"
  else
    echo "→ quedan worktrees en $WS/worktrees/$TASK — no borro el dir de la tarea."
  fi
  exit 0
fi

TASK="${1:?uso: worktree-task.sh <task-id> <repo> [repo...]}"; shift
[ $# -gt 0 ] || { echo "❌ indica al menos un repo"; exit 1; }

for repo in "$@"; do
  base="$WS/repos/$repo"
  wt="$WS/worktrees/$TASK/$repo"
  [ -d "$base/.git" ] || { echo "❌ repo desconocido: $repo (ver manifest.yaml)"; exit 1; }
  [ -d "$wt" ] && { echo "→ ya existe: $wt"; continue; }
  mkdir -p "$(dirname "$wt")"
  git -C "$base" fetch origin
  # Refresca el clon canónico ANTES de crear el worktree: los worktrees nacen frescos de
  # origin/main, pero repos/<repo> queda stale y todo lo que compone contra el canónico
  # (shims de py.sh, fallback de gowork.sh, verifies) se rompe silencioso. Best-effort:
  # offline o dirty NO bloquea — el worktree nace de origin/main igual gracias al fetch.
  cur="$(git -C "$base" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$cur" = "main" ] && [ -z "$(git -C "$base" status --porcelain 2>/dev/null)" ]; then
    git -C "$base" pull --ff-only origin main >/dev/null 2>&1 \
      || echo "⚠️  no pude refrescar repos/$repo (offline o divergió) — sigo; el worktree nace de origin/main."
  else
    echo "⚠️  repos/$repo no está limpio en main${cur:+ (rama: $cur)} — no lo refresco (el worktree nace de origin/main igual)."
  fi
  git -C "$base" worktree add -b "task/$TASK" "$wt" origin/main 2>/dev/null \
    || git -C "$base" worktree add "$wt" "task/$TASK"
  echo "✅ worktree: $wt (rama task/$TASK)"
done

# Loop interno nativo de Go: regenera el go.work de la tarea (worktree ∪ canónico como
# fallback). Best-effort — no-op limpio si no hay módulos Go (Ley 9).
bash "$WS/scripts/gowork.sh" "$TASK" >/dev/null 2>&1 || true

# Prepara los worktrees frontend AL CREARLOS. Un worktree nace de origin/main:
# sin node_modules y sin los tipos de `astro sync`, el gate ts de ship.sh no
# puede correr y antes escupía errores de tipos fantasma que parecían deuda
# vieja (caso real: 8 errores, un landing perdido, cero código que tocar).
# El gate ahora se niega en vez de mentir; esto hace que casi nunca le toque.
#
# NO es best-effort silencioso: si la instalación falla, se dice. Un prepare
# que falla callado reconstruye exactamente la trampa que vino a desarmar.
for repo in "$@"; do
  wt="$WS/worktrees/$TASK/$repo"
  [ -f "$wt/package.json" ] || continue
  echo "→ preparando toolchain frontend de $repo (el gate ts la necesita)"
  if bash "$WS/scripts/fe.sh" 'install' "$repo" "$TASK" >/dev/null 2>&1; then
    if ls "$wt"/astro.config.* >/dev/null 2>&1; then
      (cd "$wt" && npx astro sync >/dev/null 2>&1) \
        && echo "  ✅ deps + astro sync" \
        || echo "  ⚠️  deps instaladas pero 'astro sync' falló, corre: (cd $wt && npx astro sync)"
    else
      echo "  ✅ deps instaladas"
    fi
  else
    echo "  ⚠️  no pude instalar las deps de $repo: el gate ts se negará a correr hasta que lo hagas:"
    echo "     bash scripts/fe.sh 'install' $repo $TASK"
  fi
done

mkdir -p "$WS/tasks/$TASK"
echo "→ artefactos de la tarea (task.md, plan.md, verdict-*.json) en $WS/tasks/$TASK/"
