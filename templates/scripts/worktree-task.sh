#!/usr/bin/env bash
# worktree-task.sh — una tarea = un worktree por repo. Nunca el clon base.
#
# Uso:
#   worktree-task.sh <task-id> <repo> [repo...]        crea worktrees de la tarea
#   worktree-task.sh --node <Tn> <task-id> <repo>      worktree de UN NODO del DAG
#   worktree-task.sh --rm <task-id>                    quita los worktrees (post-ship)
#
# ── POR QUÉ EXISTE --node ─────────────────────────────────────────────
# Un worktree por (tarea, repo) obliga a serializar todas las tareas del DAG
# que comparten repo (POLICY-DAG-010), y eso es lo que hace que un lote de 6
# tarde 80 minutos cuando la cota paralela (el nodo más lento) son 15. Con
# `files[]` disjuntos declarados en el DAG (schema 2), cada nodo puede tener SU
# árbol y SU rama, y `dag-coalesce.sh` los junta después en `task/<id>`.
#
# El nombre de la rama NO es `task/<id>/<Tn>`, y no es un capricho: git guarda
# las refs como archivos, así que `refs/heads/task/ID` (la rama de la tarea, que
# es el destino del coalesce) y `refs/heads/task/ID/T1` no pueden coexistir:
# el segundo `worktree add` muere con "cannot lock ref". Por eso el separador es
# `@`, igual que en el directorio: `task/<id>@<Tn>` y `worktrees/<id>/<repo>@<Tn>`.
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

# ── REFRESCAR UN CLON CANÓNICO SIN PISAR TRABAJO AJENO ────────────────
# Refresca el clon canónico ANTES de crear el worktree: los worktrees nacen
# frescos de la rama trunk, pero repos/<repo> queda stale y todo lo que compone
# contra el canónico (shims de py.sh, fallback de gowork.sh, verifies) se rompe
# silencioso.
#
# La GUARDA es el invariante, no un detalle: solo se hace `pull --ff-only` si el
# clon está en su trunk y limpio. Es la misma decisión que toma pull-all.sh, y
# por el mismo motivo: el clon canónico es COMPARTIDO y un pull sobre trabajo
# versionado de otro es la única forma de que este script destruya algo.
# Best-effort: offline o dirty NO bloquea, el worktree nace de la trunk igual
# gracias al fetch.
#
# Vive en una función porque ahora tiene DOS llamadores (el repo pedido y las
# dependencias del go.work, issue #76) y dos copias divergirían justo en la
# guarda, que es lo que no puede fallar.
# El trunk se PASA, no se recalcula: el llamador del bucle ya lo necesita para
# el `worktree add`, y tenerlo local acá dejaba esa variable sin definir mas
# abajo (lo caza el test de re-entrada: "bb: unbound variable").
refresh_canonical() {  # refresh_canonical <nombre-repo> <dir-del-repo> <trunk> [motivo]
  local repo="$1" base="$2" bb="$3" motivo="${4:-}" cur
  cur="$(git -C "$base" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$cur" = "$bb" ] && [ -z "$(git -C "$base" status --porcelain 2>/dev/null)" ]; then
    git -C "$base" pull --ff-only origin "$bb" >/dev/null 2>&1 \
      || echo "⚠️  no pude refrescar repos/$repo (offline o divergió) — sigo; el worktree nace de origin/$bb."
  else
    echo "⚠️  repos/$repo no está limpio en $bb${cur:+ (rama: $cur)} — no lo refresco${motivo}"
  fi
}

# ── LAS DEPENDENCIAS DEL go.work TAMBIÉN TIENEN QUE ESTAR AL DÍA (#76) ─
# Un repo Go del monorepo depende de otros por `replace` relativo, y el go.work
# de la tarea los resuelve contra repos/ canónico. Si uno de esos clones quedó
# atrás, `go build` falla en CUALQUIER tarea del repo, INCLUIDA LA BASE SIN
# CAMBIOS, y el error no habla de staleness sino de un símbolo que no existe:
#
#   req.GetTokenDirect undefined (type *hermespb.EmbeddedSignupRequest
#   has no field or method GetTokenDirect)
#
# El precheck sale rojo por una causa que no es del cambio, y el diagnóstico
# costó media hora la primera vez.
#
# pull-all.sh no alcanza: SALTA los clones con cambios versionados (correcto, no
# se pisa trabajo ajeno) y deja la dependencia vieja igual. Acá se refresca lo
# que ESTA tarea va a compilar, con la misma guarda, y cuando no se puede el
# aviso nombra la CONSECUENCIA en vez de dejarla para que la descubra un rojo.
refresh_gowork_deps() {  # refresh_gowork_deps <task-id> <repos-ya-refrescados...>
  local task="$1"; shift
  local work="$WS/worktrees/$task/go.work" dep name repos_real
  [ -f "$work" ] || return 0
  # Los DOS lados se canonizan igual. En macOS /var es un symlink a /private/var,
  # asi que abs_path devuelve /private/var/... y el prefijo $WS/repos/ no
  # matcheaba: la funcion entera se volvia un no-op mudo justo en la plataforma
  # donde mas se corre.
  repos_real="$(perl -MCwd -e 'print(Cwd::abs_path($ARGV[0]) // $ARGV[0])' "$WS/repos" 2>/dev/null)"
  [ -n "$repos_real" ] || repos_real="$WS/repos"
  # Las rutas del go.work son relativas al dir que lo contiene. Se resuelven, se
  # quedan solo las que caen bajo repos/, y se mapea al nombre del repo (primer
  # componente). perl y no realpath: BSD no lo trae (mismo criterio que el resto
  # del harness), y perl ya es dependencia.
  awk '/^[[:space:]]*use[[:space:]]*\(/{u=1;next} u&&/^[[:space:]]*\)/{u=0;next}
       u{gsub(/^[[:space:]]+|[[:space:]]+$/,"");if($0!="")print}
       /^replace[[:space:]]/{for(i=1;i<=NF;i++) if($i=="=>"&&i<NF) print $(i+1)}' "$work" \
  | while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      # abs_path y no solo rel2abs: rel2abs CONCATENA y deja los `..` adentro
      # ($WS/worktrees/T/../../repos/pkg), asi que el filtro de prefijo de mas
      # abajo no matcheaba NUNCA y la funcion entera era un no-op silencioso.
      perl -MFile::Spec -MCwd -e '
        my $p = File::Spec->rel2abs($ARGV[0], $ARGV[1]);
        my $r = Cwd::abs_path($p);
        print(($r // $p), "\n");' "$dep" "$WS/worktrees/$task" 2>/dev/null || true
    done \
  | sed -n "s|^$repos_real/\([^/]*\).*|\1|p" \
  | sort -u \
  | while IFS= read -r name; do
      [ -n "$name" ] || continue
      # Los repos que esta invocación ya refrescó no se vuelven a tocar.
      case " $* " in *" $name "*) continue ;; esac
      [ -d "$WS/repos/$name/.git" ] || continue
      git -C "$WS/repos/$name" fetch origin --quiet >/dev/null 2>&1 || true
      refresh_canonical "$name" "$WS/repos/$name" "$(base_branch "$WS/repos/$name")" \
        ". Y es DEPENDENCIA del go.work de esta tarea: puede estar atrás, y entonces go build falla con símbolos que no existen, en cualquier tarea de este repo."
    done
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
    # Un worktree de NODO se llama `<repo>@<Tn>`: el repo de git es lo de la
    # izquierda del `@`. Sin esto, el --rm iría a buscar `repos/atlas@T1`, no lo
    # encontraría, y dejaría worktrees registrados para siempre (el próximo
    # `worktree add` en esa ruta muere con "already registered").
    repo="${repo%@*}"
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
    dirname_wt="$(basename "$wt")"
    # `<repo>@<Tn>` → repo de git a la izquierda, nodo del DAG a la derecha. La
    # rama del nodo es `task/<id>@<Tn>` (ver la cabecera: `task/<id>/<Tn>` no
    # puede existir junto a `task/<id>`).
    repo="${dirname_wt%@*}"
    if [ "$dirname_wt" != "$repo" ]; then
      branch="task/$TASK@${dirname_wt#*@}"
    else
      branch="task/$TASK"
    fi
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
    # La rama de un NODO se juzga con la misma vara, y no alcanza con `-d`: sus
    # commits ya viven en `task/<id>` por cherry-pick, o sea con OTRO sha, así
    # que git los ve como "sin mergear" y la rama del nodo nunca se limpiaría.
    # `dag-coalesce.sh` deja la marca de lo que ya coalesció; sin marca, se
    # conserva (misma ley: un árbol limpio no significa trabajo publicado).
    # `-D` y no `-d` porque el cherry-pick cambia el sha: git ve esos commits
    # como "sin mergear" aunque su PARCHE ya viva en `task/<id>`. Por eso la
    # condición no es la marca sola: se le pregunta a git si queda algo del nodo
    # que NO esté ya adentro (comparando por parche). Un implementer que siguió
    # commiteando en el nodo DESPUÉS del coalesce tiene trabajo sin publicar, y
    # ese es exactamente el caso que `-D` destruiría sin preguntar.
    if [ "$branch" != "task/$TASK" ] \
       && [ -f "$WS/tasks/$TASK/.coalesced-${dirname_wt}" ] \
       && [ -z "$(git -C "$WS/repos/$repo" rev-list --cherry-pick --right-only \
                    "task/$TASK...$branch" 2>/dev/null)" ]; then
      git -C "$WS/repos/$repo" branch -D "$branch" >/dev/null 2>&1 \
        && echo "   🧹 rama $branch borrada (coalescida entera en task/$TASK)"
    elif git -C "$WS/repos/$repo" branch -d "$branch" 2>/dev/null; then
      echo "   🧹 rama $branch borrada (su trabajo ya está publicado)"
    elif git -C "$WS/repos/$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      n="$(git -C "$WS/repos/$repo" rev-list --count "$branch" --not --remotes 2>/dev/null || echo "?")"
      echo "   ⚠️  CONSERVO la rama $branch de $repo: tiene $n commit(s) sin publicar."
      echo "      Si de verdad querés descartar ese trabajo, es tu decisión y es explícita:"
      echo "      git -C repos/$repo branch -D $branch"
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

# ── EL NODO DEL DAG, SI LO HAY ───────────────────────────────────────
# Se valida como lo que es: un componente de RUTA y un trozo de REF de git a la
# vez. Un `..` o una barra acá no serían un nombre raro, serían un worktree
# fuera de worktrees/ y una rama fuera de refs/heads/task/.
NODE=""
if [ "${1:-}" = "--node" ]; then
  NODE="${2:?uso: worktree-task.sh --node <Tn> <task-id> <repo>}"
  case "$NODE" in
    *[!A-Za-z0-9_-]*|"")
      echo "❌ nodo inválido: '$NODE' (solo letras, números, guion y guion bajo)"; exit 1 ;;
  esac
  shift 2
fi

TASK="${1:?uso: worktree-task.sh [--node <Tn>] <task-id> <repo> [repo...]}"; shift
[ $# -gt 0 ] || { echo "❌ indica al menos un repo"; exit 1; }

# El árbol y la rama de ESTE llamado: con --node, uno por nodo; sin él, el de
# siempre. Una sola función porque abajo hay tres bucles que necesitan la misma
# respuesta (crear, go.work, toolchain frontend) y tres copias divergirían.
wt_dir()    { printf '%s' "$WS/worktrees/$TASK/$1${NODE:+@$NODE}"; }
wt_branch() { printf '%s' "task/$TASK${NODE:+@$NODE}"; }

# ── LAS DEPENDENCIAS DEL NODO, SEGÚN EL DAG (#162) ────────────────────
# El orden y las aristas se le PREGUNTAN al policy engine, que ya valida el DAG
# (ciclos, ids inexistentes) y ya es el único lector de dag.json. Un awk acá
# sería un segundo lector del mismo artefacto.
#
# Best-effort a propósito: sin dag.json (carriles quick/express) o sin poder
# leerlo, DAG_ROWS queda vacío y todo se comporta como antes. Un árbol que no se
# crea es peor que un árbol que nace de la trunk, que es lo que pasaba siempre.
DAG_ROWS=""
if [ -n "$NODE" ] && [ -f "$WS/tasks/$TASK/dag.json" ]; then
  DAG_ROWS="$(python3 "$WS/scripts/harness-policy.py" --policy "$WS/harness-policy.json" \
                dag-nodes "$WS/tasks/$TASK" 2>/dev/null || true)"
fi

# deps_en_repo <repo> → las dependencias de $NODE que viven EN ESE repo.
# Filtrar por repo no es un detalle: un nodo de `proto` que depende de uno de
# `atlas` no tiene nada que heredar en el árbol de proto, y anunciar que sí
# heredó algo sería la misma clase de mentira que este arreglo viene a cerrar.
deps_en_repo() {
  # El índice numérico y no `for (i in d)`: el orden de un for-in de awk no está
  # definido, y una lista de deps que cambia de orden entre corridas es un
  # mensaje que no se puede leer dos veces igual.
  printf '%s\n' "$DAG_ROWS" | awk -F'\t' -v n="$NODE" -v r="$1" '
    { repo[$1] = $2; if ($1 == n) k = split($3, d, ",") }
    END { for (i = 1; i <= k; i++) if (d[i] != "" && repo[d[i]] == r) printf "%s ", d[i] }'
}

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

# `mkdir` solo no alcanza como mutex: con uutils coreutils (Ubuntu 26.04) hace
# check-then-act y bajo carrera le dice que sí a varios (issue #209). El dueño
# es quien crea `.owner`, cuyo O_EXCL lo hace la shell y no un binario.
mkdir_lock() {  # mkdir_lock <dir> → 0 solo si el lock es NUESTRO
  mkdir "$1" 2>/dev/null || return 1
  ( set -C; : > "$1/.owner" ) 2>/dev/null
}

acquire_create_lock() {  # acquire_create_lock <task> <repo> → 0 si es nuestro
  local dir="$WS/locks/wt-${1}__${2}.lock.d" lpid="" tries=0
  local max_wait="${HARNESS_WT_LOCK_WAIT:-10}"   # segundos antes de rendirse
  mkdir -p "$WS/locks"
  until mkdir_lock "$dir"; do
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
  wt="$(wt_dir "$repo")"
  branch="$(wt_branch)"
  [ -d "$base/.git" ] || { echo "❌ repo desconocido: $repo (ver manifest.yaml)"; exit 1; }
  # El lock va ANTES del chequeo de existencia: entre este [ -d ] y el
  # worktree add hay un fetch con red de por medio, y esa ventana es la que
  # dejaba pasar a dos procesos a la vez (TOCTOU).
  acquire_create_lock "$TASK" "$repo${NODE:+@$NODE}" || exit 1
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
  refresh_canonical "$repo" "$base" "$bb"
  # ── DE DÓNDE NACE LA RAMA DE UN NODO ────────────────────────────────
  # Por defecto de la trunk, NO de `task/<id>`: el coalesce hace cherry-pick de
  # cada nodo sobre `task/<id>`, y si el nodo ya llevara adentro los commits de
  # sus HERMANOS, ese cherry-pick los aplicaría dos veces.
  #
  # Eso es correcto para el nodo INDEPENDIENTE y era el único caso contemplado
  # (#162): con `depends_on` no vacío, nacer de la trunk significa nacer SIN
  # aquello de lo que dependés. Y el modo de falla no es un rojo: un implementer
  # que no encuentra lo que necesita lo RE-IMPLEMENTA, y eso recién aparece como
  # conflicto en el coalesce, con los tokens del nodo ya gastados. Medido: cuatro
  # nodos que habrían re-abierto por su cuenta las 176 claves de i18n que su
  # dependencia acababa de abrir.
  #
  # Nacer de `task/<id>` NO reintroduce la duplicación que el párrafo de arriba
  # evita: dag-coalesce.sh selecciona con `rev-list --cherry-pick --right-only`,
  # que compara por PARCHE, así que lo que ya es ancestro no se vuelve a aplicar.
  start="origin/$bb"
  if [ -n "$NODE" ]; then
    deps="$(deps_en_repo "$repo")"
    if [ -n "$deps" ]; then
      if git -C "$base" show-ref --verify --quiet "refs/heads/task/$TASK"; then
        start="task/$TASK"
        echo "→ $NODE depende de ${deps% } en $repo: su rama nace de task/$TASK, no de la trunk"
        # Que la rama exista no prueba que las dependencias estén DENTRO. El
        # marcador lo deja dag-coalesce.sh por nodo aplicado, así que es el
        # único dato que distingue "ya lo trae" de "todavía no".
        faltan=""
        for d in $deps; do
          [ -f "$WS/tasks/$TASK/.coalesced-${repo}@${d}" ] || faltan="$faltan$d "
        done
        if [ -n "$faltan" ]; then
          echo "  ⚠️  pero ${faltan% } todavía no se coalesció en $repo: este árbol NO trae su trabajo."
          echo "     ↳ bash scripts/dag-coalesce.sh $TASK $repo y re-creá este árbol,"
          echo "       o el implementer va a re-implementar lo que su dependencia ya hizo."
        fi
      else
        # No se inventa la rama: se dice. Un árbol que nace de la trunk cuando
        # debía heredar es exactamente el silencio que este bloque cierra.
        echo "⚠️  $NODE depende de ${deps% } en $repo, pero no existe la rama task/$TASK:"
        echo "   este árbol nace de la trunk, SIN el trabajo del que depende."
        echo "   ↳ creá el árbol base y coalescé las dependencias primero:"
        echo "     bash scripts/worktree-task.sh $TASK $repo"
        echo "     bash scripts/dag-coalesce.sh $TASK $repo"
      fi
    fi
  fi
  # Sin 2>/dev/null: silenciar el primer intento convertía cualquier colisión
  # (rama ya tomada por otro worktree, index.lock ajeno) en una muerte muda a
  # mitad del bucle multi-repo. El fallback aplica SOLO al caso legítimo: la
  # rama de la tarea ya existe (retoma) y ningún worktree la tiene.
  if git -C "$base" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$base" worktree add "$wt" "$branch"
  else
    git -C "$base" worktree add -b "$branch" "$wt" "$start"
  fi
  echo "✅ worktree: $wt (rama $branch)"
  release_create_lock
done

# Loop interno nativo de Go: regenera el go.work de la tarea (worktree ∪ canónico como
# fallback). Best-effort — no-op limpio si no hay módulos Go (Ley 9).
bash "$WS/scripts/gowork.sh" "$TASK" >/dev/null 2>&1 || true

# Y el árbol de un NODO necesita el SUYO (#152): comparte module-path con el árbol
# base y con sus hermanos, y un go.work no admite el mismo módulo dos veces, así que
# el de la tarea no puede nombrarlo. Sin este archivo el implementer del nodo corre
# `go test` contra el código del árbol BASE y el verde no dice nada de su cambio.
if [ -n "$NODE" ]; then
  for repo in "$@"; do
    bash "$WS/scripts/gowork.sh" "$TASK" "$repo@$NODE" >/dev/null 2>&1 || true
  done
fi

# Y con el go.work ya escrito se sabe QUÉ clones va a compilar esta tarea: se
# refrescan ahora, no cuando el compilador se queje de un símbolo (#76).
refresh_gowork_deps "$TASK" "$@"

# Prepara los worktrees frontend AL CREARLOS. Un worktree nace de origin/main:
# sin node_modules y sin los tipos de `astro sync`, el gate ts de ship.sh no
# puede correr y antes escupía errores de tipos fantasma que parecían deuda
# vieja (caso real: 8 errores, un landing perdido, cero código que tocar).
# El gate ahora se niega en vez de mentir; esto hace que casi nunca le toque.
#
# NO es best-effort silencioso: si la instalación falla, se dice. Un prepare
# que falla callado reconstruye exactamente la trampa que vino a desarmar.
for repo in "$@"; do
  wt="$(wt_dir "$repo")"
  [ -f "$wt/package.json" ] || continue
  echo "→ preparando toolchain frontend de $repo (el gate ts la necesita)"
  # fe.sh compone `worktrees/<task>/<lo-que-le-pases>`, así que en un worktree
  # de nodo lo que hay que pasarle es `<repo>@<Tn>`: pasarle el repo pelado lo
  # mandaría al árbol base (que puede no existir) y el prepare no prepararía
  # el árbol donde el implementer va a trabajar.
  if bash "$WS/scripts/fe.sh" 'install' "$repo${NODE:+@$NODE}" "$TASK" >/dev/null 2>&1; then
    if ls "$wt"/astro.config.* >/dev/null 2>&1; then
      (cd "$wt" && npx astro sync >/dev/null 2>&1) \
        && echo "  ✅ deps + astro sync" \
        || echo "  ⚠️  deps instaladas pero 'astro sync' falló, corre: (cd $wt && npx astro sync)"
    else
      echo "  ✅ deps instaladas"
    fi
  else
    echo "  ⚠️  no pude instalar las deps de $repo: el gate ts se negará a correr hasta que lo hagas:"
    echo "     bash scripts/fe.sh 'install' $repo${NODE:+@$NODE} $TASK"
  fi
done

mkdir -p "$WS/tasks/$TASK"
echo "→ artefactos de la tarea (task.md, plan.md, verdict-*.json) en $WS/tasks/$TASK/"
