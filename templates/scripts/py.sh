#!/usr/bin/env bash
# py.sh — corre un comando de uv en un repo hijo Python con estado LOCAL al workspace:
# CPython gestionado por uv en $WS/.cache/py/cpython (nada global). Espejo de scripts/fe.sh
# y hermano de scripts/gowork.sh para el LOOP INTERNO NATIVO de Python.
#
# EL PROBLEMA (idéntico al de Go): los pyproject.toml de los servicios traen path-deps
# (`[tool.uv.sources]` con `path = "../../..."`) pensados para un layout monorepo que NO
# existe en el harness — apuntan a repos/packages, repos/proto/gen/... que no están. Aquí NO
# se toca ningún repo hijo: los path rotos ESCAPAN del repo hacia territorio del harness
# (repos/ o worktrees/<task>/, gitignoreado, fuera de todo .git hijo) y ahí plantamos
# SYMLINKS (shims) al paquete real. Con los shims, pyproject Y uv.lock resuelven sin editar
# nada. Todo se descubre en runtime, keyed por el NOMBRE del paquete (PEP 621 [project].name)
# — nunca por nombre de repo/cliente.
#
# Uso:
#   make py CMD='sync'                            # repo único autodescubierto, canónico
#   make py CMD='sync' REPO=<repo>               # repo explícito, canónico
#   make py CMD='run pytest' REPO=<repo> TASK=<id>   # en el worktree de la tarea (Ley 4)
#   bash scripts/py.sh '<cmd>' [REPO] [TASK]
#
# Portable: sin arrays asociativos ni mapfile (bash 3.2 de macOS y Linux). set -euo pipefail.
set -euo pipefail
WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; cd "$WS"
REPOS_DIR="$WS/repos"
WT_DIR="$WS/worktrees"

CMD="${1:-}"
REPO="${2:-}"
TASK="${3:-}"

warn() { printf "  \033[33m⚠\033[0m %s\n" "$*" >&2; }

[ -n "$CMD" ] || { echo "❌ falta CMD — uso: make py CMD='sync' [REPO=<repo>] [TASK=<id>]"; exit 2; }

command -v uv >/dev/null 2>&1 || { echo "❌ uv no está instalado — corre 'bash scripts/bootstrap.sh'"; exit 1; }

# ── path abs de $1 relativo a $2 y viceversa (perl/File::Spec: portable, no exige existencia) ──
rel2abs() { perl -MFile::Spec -e 'print File::Spec->rel2abs($ARGV[0],$ARGV[1])' "$1" "$2"; }
abs2rel() { perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0],$ARGV[1])' "$1" "$2"; }

# [project].name de un pyproject.toml (PEP 621); vacío si no lo tiene
name_of() {
  awk '
    /^[ \t]*\[project\][ \t]*$/ { inproj=1; next }
    /^[ \t]*\[/ { inproj=0 }
    inproj && /^[ \t]*name[ \t]*=/ {
      line=$0; sub(/^[ \t]*name[ \t]*=[ \t]*/,"",line); sub(/[ \t]*#.*/,"",line)
      gsub(/["'\'']/,"",line); gsub(/[ \t]/,"",line); print line; exit
    }
  ' "$1" 2>/dev/null
}

# path-deps de un pyproject: "NAME<TAB>REL" por cada entrada de [tool.uv.sources] con `path = "..."`
sources_of() {
  awk '
    /^[ \t]*\[tool\.uv\.sources\][ \t]*$/ { insrc=1; next }
    /^[ \t]*\[/ { if (insrc && $0 !~ /\[tool\.uv\.sources\]/) insrc=0 }
    insrc {
      line=$0
      if (match(line, /path[ \t]*=[ \t]*"[^"]*"/)) {
        p=substr(line,RSTART,RLENGTH); sub(/path[ \t]*=[ \t]*"/,"",p); sub(/"$/,"",p)
        key=line; sub(/[ \t]*=.*/,"",key); gsub(/[ \t]/,"",key)
        if (key!="" && p!="") print key "\t" p
      }
    }
  ' "$1" 2>/dev/null
}

# ── índice nombre→dir: todos los pyproject.toml del workspace (worktree de la tarea primero,
#    luego repos/); el PRIMERO en aparecer gana (worktree tiene prioridad sobre el canónico) ──
scan_roots=""
[ -n "$TASK" ] && [ -d "$WT_DIR/$TASK" ] && scan_roots="$WT_DIR/$TASK"
scan_roots="$scan_roots $REPOS_DIR"
INDEX=""   # líneas "name<TAB>dir"
for root in $scan_roots; do
  [ -d "$root" ] || continue
  while IFS= read -r pp; do
    [ -n "$pp" ] || continue
    nm="$(name_of "$pp")"; [ -n "$nm" ] || continue
    d="$(cd "$(dirname "$pp")" && pwd -P)"
    INDEX="${INDEX}${nm}	${d}
"
  done < <(find "$root" \( -name .git -o -name node_modules -o -name .venv \
                           -o -name vendor -o -name .cache \
                           -o -name '.review-*' \) -prune -o -name pyproject.toml -print)
  # `.review-*` (arbol clavado del reviewer) trae los MISMOS paquetes que el
  # worktree vivo, y lookup_name devuelve el primer match: sin la poda, un
  # shim podia apuntar al commit sellado en vez de a las ediciones vivas.
done
# dir del paquete llamado $1 (primer match = ganador)
lookup_name() { printf '%s' "$INDEX" | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'; }

# ── territorio del harness: ¿el shim caería DENTRO de un repo hijo (.git en el camino)? ──
# Toma el ancestro EXISTENTE más profundo de $1 (el shim aún no existe), lo canoniza y sube
# hasta WS: si topa un .git antes de WS → repo hijo (no tocar).
inside_child_repo() {
  local p="$1"
  while [ ! -d "$p" ]; do p="$(dirname "$p")"; done
  p="$(cd "$p" && pwd -P)"
  while [ "$p" != "$WS" ] && [ "$p" != "/" ]; do
    [ -e "$p/.git" ] && return 0
    p="$(dirname "$p")"
  done
  return 1
}
# ¿el ancestro existente de $1 está DENTRO DEL WORKSPACE (territorio shimeable)?
#
# ── POR QUÉ EL TERRITORIO ES EL WORKSPACE Y NO SOLO repos//worktrees/ (#133) ──
# La guarda pedía que el shim cayera bajo `repos/` o `worktrees/`, y hay un
# layout entero que no puede cumplirlo: un repo cuyo `pyproject.toml` declara
# `../../packages/<x>` sale DOS niveles desde `repos/<repo>`, o sea a la raíz
# del workspace. Medido en aegis: los dos path-deps caían ahí, no se plantaba
# ningún shim, y el loop interno nativo de Python (Ley 9) simplemente NO EXISTÍA
# para ese repo: ni `sync`, ni `pytest`, ni `ruff`. El workaround era `ruff`
# standalone, que no resuelve dependencias, así que `pytest` no tenía salida.
#
# Lo que la guarda protege de verdad es plantar symlinks FUERA del workspace
# (en $HOME, en un hermano del árbol) y DENTRO de un repo hijo, que es
# escribirle a un clon ajeno. Lo primero se sigue cumpliendo acá; lo segundo lo
# comprueba `inside_child_repo`, que corre antes y no cambió.
#
# Lo que sí cambia y hay que decirlo: un shim en la raíz deja un archivo sin
# trackear en el ÁRBOL DE LA INSTANCIA, que es compartido. Por eso se avisa con
# la línea de .gitignore lista para pegar, en vez de dejar que aparezca como
# suciedad anónima en el próximo `git status` de otra tarea.
in_harness_territory() {
  local p="$1"
  while [ ! -d "$p" ]; do p="$(dirname "$p")"; done
  p="$(cd "$p" && pwd -P)"
  case "$p" in "$WS"|"$WS"/*) return 0 ;; *) return 1 ;; esac
}

# ¿el shim quedó fuera de repos//worktrees/, o sea en el árbol de la instancia?
# La ruta se CANONIZA antes de comparar: la que llega trae los `../..` sin
# resolver (`repos/aegis/../../packages/x`), y esa cadena empieza con
# `$REPOS_DIR/`, así que un `case` sobre el texto crudo contesta al revés.
# Se canoniza el DIRECTORIO QUE CONTIENE al shim, no el shim: para cuando esto
# corre el symlink ya existe, y canonizarlo a él resuelve al DESTINO (que sí
# vive bajo repos/), o sea que la pregunta se contestaría sobre el lugar
# equivocado y el aviso no saldría nunca.
fuera_de_repos_y_worktrees() {
  local p
  p="$(dirname "$1")"
  while [ ! -d "$p" ]; do p="$(dirname "$p")"; done
  p="$(cd "$p" && pwd -P)"
  case "$p" in "$REPOS_DIR"|"$REPOS_DIR"/*|"$WT_DIR"|"$WT_DIR"/*) return 1 ;; *) return 0 ;; esac
}

# ── shims: recorre en fixpoint el árbol de path-deps. Base de resolución = ubicación LÓGICA
#    (el shim recién creado) para que los `../..` anidados caigan de forma consistente en
#    territorio del harness, igual que los ve uv al seguir el symlink. Idempotente. ──
SHIMS=""      # "link -> target" por shim creado (para el reporte)
VISITED=""    # bases ya procesadas (anti-loop)
process_pp() {
  local pp="$1" base="$2" srcs name rel resolved real linkdir tgt cur
  case "
$VISITED" in *"
$base"*) return 0 ;; esac
  VISITED="$VISITED
$base"
  [ -f "$pp" ] || return 0
  srcs="$(sources_of "$pp")"
  [ -n "$srcs" ] || return 0
  while IFS='	' read -r name rel; do
    [ -n "$name" ] || continue
    case "$rel" in /*) continue ;; esac          # sólo paths relativos
    resolved="$(rel2abs "$rel" "$base")"
    if [ -f "$resolved/pyproject.toml" ]; then     # el destino resuelve → no hay que plantar
      # …pero puede resolver porque un shim VIEJO sigue apuntando adonde lo dejó
      # la corrida anterior (típico: el clon canónico de repos/) mientras el
      # índice —que pone el worktree de la tarea PRIMERO— ya elige otro dir. Sin
      # re-apuntar, ese ganador nunca se aplica al shim ya plantado.
      # Caso de campo (COR-333): el path-dep escapaba del worktree a
      # worktrees/packages/ (compartido entre tareas), el repo compiló y testeó
      # contra repos/ en silencio y un símbolo agregado en el worktree "no
      # existía". Misma regla declarada que al plantarlo: ÚLTIMO EN CORRER GANA.
      if [ -L "$resolved" ]; then
        # OJO: el territorio y el repo hijo se preguntan por el directorio que
        # CONTIENE el link, no por $resolved: canonizar a través del symlink
        # lleva al destino (que vive en repos/<repo> y sí tiene .git) y vetaría
        # el re-apuntado siempre.
        linkdir="$(dirname "$resolved")"
        real="$(lookup_name "$name")"
        if [ -n "$real" ] && in_harness_territory "$linkdir" && ! inside_child_repo "$linkdir"; then
          cur="$(cd "$resolved" && pwd -P)"
          if [ "$cur" != "$real" ]; then
            tgt="$(abs2rel "$real" "$linkdir")"
            ln -sfn "$tgt" "$resolved"
            SHIMS="${SHIMS}${resolved} -> ${tgt} (re-apuntado)
"
            process_pp "$real/pyproject.toml" "$resolved"
            continue
          fi
        fi
      fi
      process_pp "$resolved/pyproject.toml" "$resolved"
      continue
    fi
    # destino roto: buscá el paquete real por nombre
    real="$(lookup_name "$name")"
    if [ -z "$real" ]; then warn "path-dep '$name' ($rel) roto y sin match en el workspace — uv reportará el error"; continue; fi
    if inside_child_repo "$resolved"; then warn "el shim de '$name' caería dentro de un repo hijo ($resolved) — no lo toco"; continue; fi
    if ! in_harness_territory "$resolved"; then warn "el shim de '$name' caería FUERA del workspace ($resolved) — no lo toco"; continue; fi
    if [ -e "$resolved" ] && [ ! -L "$resolved" ]; then warn "'$resolved' ya existe y no es symlink — no lo piso"; continue; fi
    linkdir="$(dirname "$resolved")"
    mkdir -p "$linkdir"
    tgt="$(abs2rel "$real" "$linkdir")"           # symlink relativo (portable si se mueve el árbol)
    ln -sfn "$tgt" "$resolved"
    SHIMS="${SHIMS}${resolved} -> ${tgt}
"
    # Un shim en la raíz del workspace es un archivo sin trackear en el árbol
    # COMPARTIDO de la instancia. No se esconde: se nombra, con la línea de
    # .gitignore lista, porque suciedad anónima en ese árbol es exactamente lo
    # que termina colándose en el commit de otra tarea.
    if fuera_de_repos_y_worktrees "$resolved"; then
      warn "el shim de '$name' quedó en el árbol de la instancia (${resolved#"$WS"/}), que es COMPARTIDO"
      warn "  ↳ agregalo al .gitignore del workspace para que no ensucie el status de otras tareas:"
      warn "     echo '${resolved#"$WS"/}' >> .gitignore"
    fi
    process_pp "$real/pyproject.toml" "$resolved" # fixpoint: el paquete real puede traer sus propias path-deps
  done <<EOF
$srcs
EOF
}

# ── resolución del repo objetivo ────────────────────────────────────────────────────────────
if [ -z "$REPO" ]; then
  # autodescubrimiento: dirs de 1er/2do nivel bajo repos/ cuyo ROOT trae pyproject.toml
  cands=""
  for d in "$REPOS_DIR"/*/ "$REPOS_DIR"/*/*/; do
    if [ -L "${d%/}" ]; then continue; fi          # los shims son symlinks — no son proyectos
    [ -f "${d}pyproject.toml" ] || continue
    rel="${d#"$REPOS_DIR"/}"; rel="${rel%/}"
    cands="${cands}${rel}
"
  done
  cands="$(printf '%s' "$cands" | sort -u | grep -v '^$' || true)"
  n="$(printf '%s\n' "$cands" | grep -c . || true)"
  if [ "$n" = 0 ]; then echo "❌ no hay proyectos Python en repos/ (ningún pyproject.toml de 1er/2do nivel)"; exit 2; fi
  if [ "$n" -gt 1 ]; then
    echo "❌ varios proyectos Python — pasá REPO=<uno>:"; printf '%s\n' "$cands" | sed 's/^/   - /'; exit 2
  fi
  REPO="$cands"
  echo "==> REPO autodescubierto: $REPO"
fi

# ── directorio del repo (worktree si hay TASK, si no el canónico) ──
if [ -n "$TASK" ]; then
  DIR="$WT_DIR/$TASK/$REPO"
  [ -d "$DIR" ] || { echo "❌ no existe el worktree $DIR — creá con 'make wt TASK=$TASK REPOS=$REPO'"; exit 1; }
else
  DIR="$REPOS_DIR/$REPO"
  [ -d "$DIR" ] || { echo "❌ no existe $DIR — revisá manifest.yaml y cloná los repos"; exit 1; }
fi
[ -f "$DIR/pyproject.toml" ] || { echo "❌ $DIR/pyproject.toml no existe — este repo no es un proyecto Python/uv"; exit 1; }
DIR="$(cd "$DIR" && pwd -P)"

# ── plantar los shims necesarios (idempotente) ──
process_pp "$DIR/pyproject.toml" "$DIR"
if [ -n "$SHIMS" ]; then
  printf '%s' "$SHIMS" | while IFS= read -r l; do [ -n "$l" ] && printf "  \033[36m↳ shim\033[0m %s\n" "$l"; done
fi

# ── entorno: CPython gestionado LOCAL al workspace. No tocamos el PATH global; uv elige la
#    versión según requires-python del repo, pero SOLO entre las gestionadas (nada del host). ──
export UV_PYTHON_INSTALL_DIR="$WS/.cache/py/cpython"
export UV_PYTHON_PREFERENCE="only-managed"
mkdir -p "$UV_PYTHON_INSTALL_DIR"

echo "==> Python (uv): $REPO${TASK:+  (worktree: $TASK)}"
echo "    dir:  $DIR"
echo "    uv:   $(uv --version 2>/dev/null)  ·  cpython local: $UV_PYTHON_INSTALL_DIR"
echo "    cmd:  uv $CMD"
cd "$DIR"
# shellcheck disable=SC2086  # $CMD es un string de comando del usuario: el word-splitting es intencional
exec uv $CMD
