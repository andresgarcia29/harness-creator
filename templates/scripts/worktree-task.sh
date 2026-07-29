#!/usr/bin/env bash
# worktree-task.sh — una tarea = un worktree por repo. Nunca el clon base.
#
# Uso:
#   worktree-task.sh <task-id> <repo> [repo...]   crea worktrees de la tarea
#   worktree-task.sh --rm <task-id>               quita los worktrees (post-ship)
set -euo pipefail
WS="$(cd "$(dirname "$0")/.." && pwd)"

# La rama trunk no siempre se llama "main": se resuelve por repo desde
# origin/HEAD, con override por entorno. Antes, un repo con `master` moría
# en `worktree add ... origin/main` con "invalid reference".
base_branch() {  # base_branch <dir-del-repo> → rama trunk, sin prefijo
  local b
  # `[ ... ] && cmd` bajo set -e mata el script si la condición es falsa.
  if [ -n "${HARNESS_BASE_BRANCH:-}" ]; then printf '%s' "$HARNESS_BASE_BRANCH"; return 0; fi
  # EL REMOTO ES LA AUTORIDAD (issue #32): origin/HEAD local se escribe UNA
  # vez al clonar y un `remote set-head` posterior lo envenena en silencio y
  # para siempre. Se consulta al remoto y se SANA el ref local de paso;
  # offline se cae al ref local (degradar no es inventar).
  b="$(git -C "$1" ls-remote --symref origin HEAD 2>/dev/null \
    | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')"
  if [ -n "$b" ]; then
    git -C "$1" remote set-head origin "$b" >/dev/null 2>&1 || true
  else
    b="$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  fi
  [ -n "$b" ] || b=main
  printf '%s' "$b"
}

if [ "${1:-}" = "--rm" ]; then
  TASK="${2:?uso: worktree-task.sh --rm <task-id>}"
  # ── El pin de review (.review-<repo>) TAMBIÉN es un worktree ──────────
  # verdict-scaffold.sh clava ahí un checkout DESACOPLADO del commit que el
  # reviewer juzga. Al no tener rama no puede esconder trabajo sin publicar
  # (que es lo único que este --rm cuida), así que se quita sin ceremonia. Lo
  # que NO puede es quedar huérfano: si el dir se va con el de la tarea y la
  # metadata sobrevive en el repo, el próximo `worktree add` en esa ruta muere
  # con "missing but already registered" y la tarea siguiente nace trabada.
  # Va ANTES del bucle de worktrees vivos porque le pide el repo al que todavía
  # existe. Y recorre los DOS globs porque hay dos formas de quedar huérfano:
  # un pin cuyo worktree vivo ya no está (el vivo se quitó a mano), y un pin
  # cuyo DIR ya no está pero sigue registrado; ese segundo caso no lo ve ningún
  # glob de directorios, y es justo el que deja el repo trabado. Por eso el
  # prune corre siempre: es idempotente y solo toca lo que ya no existe.
  for d in "$WS/worktrees/$TASK"/.review-* "$WS/worktrees/$TASK"/*/; do
    d="${d%/}"
    [ -e "$d" ] || continue                   # glob sin match
    case "$d" in
      */.review-*) repo="${d##*/.review-}" ;;
      *)           repo="${d##*/}" ;;
    esac
    pin="$WS/worktrees/$TASK/.review-$repo"
    gd="$WS/repos/$repo"
    [ -e "$gd/.git" ] || gd="$WS/worktrees/$TASK/$repo"
    [ -e "$gd/.git" ] || gd="$pin"            # último recurso: el pin sabe su repo
    [ -e "$gd/.git" ] || continue             # sin repo desde donde hablarle a git
    if [ -e "$pin" ]; then
      if out="$(git -C "$gd" worktree remove --force "$pin" 2>&1)"; then
        echo "🧹 removido el pin de review: $pin"
      else
        echo "⚠️  git worktree remove no pudo con el pin $pin: $(printf '%s' "$out" | head -1)"
        rm -rf "$pin" || echo "   ⚠️  y tampoco pude borrar el directorio"
        echo "   lo quité a mano; podo la metadata para no dejar el repo trabado"
      fi
    fi
    [ -e "$gd/.git" ] || continue             # era el propio pin y ya no está
    git -C "$gd" worktree prune \
      || echo "⚠️  worktree prune falló en $gd: la metadata del pin puede quedar rota"
  done
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
  # Y los locks de creación huérfanos de esta tarea, por la misma razón.
  rm -rf "$WS/locks/wt-${TASK}__"*.lock.d 2>/dev/null || true
  if ! ls -d "$WS/worktrees/$TASK"/*/ >/dev/null 2>&1; then
    rm -rf "$WS/worktrees/$TASK"
  else
    echo "→ quedan worktrees en $WS/worktrees/$TASK — no borro el dir de la tarea."
  fi
  exit 0
fi

TASK="${1:?uso: worktree-task.sh <task-id> <repo> [repo...]}"; shift
[ $# -gt 0 ] || { echo "❌ indica al menos un repo"; exit 1; }

# ── Lock de CREACIÓN por (task, repo) ─────────────────────────────────
# Caso de campo: /smart lanza este script en paralelo y dos procesos pasaron
# juntos el chequeo "ya existe": el segundo moría a mitad del bucle con un
# error de git silenciado, o peor, dos implementers acababan escribiendo el
# mismo worktree y un `git add` se llevaba el trabajo del otro. El lock de
# ship.sh es por repo y solo cubre el push; el semáforo de build-slot es por
# máquina y solo cubre builds. La CREACIÓN no la cubría nadie.
# mkdir es atómico (mismo patrón que acquire_lock de ship.sh); la vida del
# worktree ya creado la protege el claim de guard-worktree.sh, no esto.
WT_LOCKDIR=""
trap 'if [ -n "$WT_LOCKDIR" ]; then rm -rf "$WT_LOCKDIR"; fi' EXIT

acquire_create_lock() {  # acquire_create_lock <task> <repo> → 0 si es nuestro
  local dir="$WS/locks/wt-${1}__${2}.lock.d" lpid="" tries=0
  local max_wait="${HARNESS_WT_LOCK_WAIT:-10}"   # segundos antes de rendirse
  mkdir -p "$WS/locks"
  until mkdir "$dir" 2>/dev/null; do
    lpid="$(cat "$dir/pid" 2>/dev/null || true)"
    if [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; then
      echo "⚠️  lock de creación huérfano (pid $lpid ya no existe); lo reclamo"
      rm -rf "$dir"
      continue
    fi
    tries=$((tries+1))
    if [ "$tries" -ge "$max_wait" ]; then
      echo "❌ otro proceso${lpid:+ (pid $lpid)} está creando el worktree de $2 para $1."
      echo "   Dos creadores concurrentes del mismo (task, repo) es exactamente el"
      echo "   accidente que este lock existe para impedir: espera a que termine y"
      echo "   re-corre. Si estás SEGURO de que no queda ningún proceso vivo:"
      echo "   rm -rf $dir"
      return 1
    fi
    sleep 1
  done
  echo $$ > "$dir/pid"
  WT_LOCKDIR="$dir"
  return 0
}

release_create_lock() {
  if [ -n "$WT_LOCKDIR" ]; then rm -rf "$WT_LOCKDIR"; WT_LOCKDIR=""; fi
}

for repo in "$@"; do
  base="$WS/repos/$repo"
  wt="$WS/worktrees/$TASK/$repo"
  [ -d "$base/.git" ] || { echo "❌ repo desconocido: $repo (ver manifest.yaml)"; exit 1; }
  # El lock va ANTES del chequeo de existencia: entre este [ -d ] y el
  # worktree add hay un fetch con red de por medio, y esa ventana es la que
  # dejaba pasar a dos procesos a la vez (TOCTOU).
  acquire_create_lock "$TASK" "$repo" || exit 1
  if [ -d "$wt" ]; then
    echo "→ ya existe: $wt"
    release_create_lock
    continue
  fi
  mkdir -p "$(dirname "$wt")"
  git -C "$base" fetch origin
  # Refresca el clon canónico ANTES de crear el worktree: los worktrees nacen frescos de
  # la rama trunk, pero repos/<repo> queda stale y todo lo que compone contra el canónico
  # (shims de py.sh, fallback de gowork.sh, verifies) se rompe silencioso. Best-effort:
  # offline o dirty NO bloquea: el worktree nace de la rama trunk igual gracias al fetch.
  bb="$(base_branch "$base")"
  cur="$(git -C "$base" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$cur" = "$bb" ] && [ -z "$(git -C "$base" status --porcelain 2>/dev/null)" ]; then
    git -C "$base" pull --ff-only origin "$bb" >/dev/null 2>&1 \
      || echo "⚠️  no pude refrescar repos/$repo (offline o divergió) — sigo; el worktree nace de origin/$bb."
  else
    echo "⚠️  repos/$repo no está limpio en $bb${cur:+ (rama: $cur)} — no lo refresco (el worktree nace de origin/$bb igual)."
  fi
  # Sin 2>/dev/null: silenciar el primer intento convertía cualquier colisión
  # (rama ya tomada por otro worktree, index.lock ajeno) en una muerte muda a
  # mitad del bucle multi-repo. El fallback aplica SOLO al caso legítimo: la
  # rama de la tarea ya existe (retoma) y ningún worktree la tiene.
  if git -C "$base" show-ref --verify --quiet "refs/heads/task/$TASK"; then
    git -C "$base" worktree add "$wt" "task/$TASK"
  else
    git -C "$base" worktree add -b "task/$TASK" "$wt" "origin/$bb"
  fi
  echo "✅ worktree: $wt (rama task/$TASK)"
  release_create_lock
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
