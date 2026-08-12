#!/usr/bin/env bash
# gowork.sh — genera un go.work para el LOOP INTERNO NATIVO de Go (segundos, cache
# incremental), sin depender del contenedor. Universal: descubre módulos en runtime
# desde el filesystem; nada de nombres de repos/módulos hardcodeados.
#
# Uso:
#   bash scripts/gowork.sh             genera go.work en la RAÍZ (cubre los módulos de repos/)
#   bash scripts/gowork.sh <task-id>   genera worktrees/<task-id>/go.work para esa tarea,
#                                       con FALLBACK al canónico: unión por module-path de
#                                       (módulos del worktree) ∪ (módulos de repos/), gana
#                                       el worktree si el module-path está en ambos. Así una
#                                       tarea que sólo tocó un servicio compila contra el
#                                       shared canónico.
#   bash scripts/gowork.sh <task-id> <repo>
#                                      genera worktrees/<task-id>/.review-<repo>/go.work: el
#                                       go.work PROPIO del árbol clavado del reviewer.
#   bash scripts/gowork.sh <task-id> <repo>@<Tn>
#                                      genera worktrees/<task-id>/<repo>@<Tn>/go.work: el
#                                       go.work PROPIO del árbol de ESE nodo del DAG.
#
# ── Por qué el árbol clavado necesita SU archivo (caso de campo) ──
# El pin `.review-<repo>` que clava verdict-scaffold tiene los MISMOS module-paths que el
# worktree vivo, y un go.work no admite el mismo módulo dos veces, así que el go.work de la
# tarea PODA los .review-* (ver discover). Consecuencia: cualquier `go` corrido dentro del pin
# muere con "directory prefix does not contain modules", y la remediación natural (`go work
# use .`, o regenerar el go.work parado ahí) REESCRIBE el archivo que el QA está usando sobre
# el árbol vivo. Medido: el go.work quedó apuntando al pin mientras QA medía sobre el vivo y
# el build salió rojo por una razón que no era el código. No es raro: el pipeline lanza
# reviewer y QA en PARALELO por diseño, así que la carrera es la norma.
# Con un go.work DENTRO del pin, `go` lo encuentra subiendo desde el cwd antes que el de la
# tarea y los dos árboles dejan de compartir archivo. En el pin gana el commit SELLADO; los
# demás repos vivos de la tarea siguen entrando, porque son parte del mismo cambio.
#
# ── Y el árbol de un NODO del DAG es el MISMO problema (#152, familia de #149/#150) ──
# Con `dag.json` schema 2, N tareas del mismo repo corren en paralelo, cada una en
# `worktrees/<task>/<repo>@<Tn>`. Los hermanos y el árbol base comparten module-path por
# definición: son el mismo repo. Este script no los conocía, así que colapsaban a UNA entrada
# por module-path y el ganador lo decidía readdir. Medido en campo: NINGUNO de los dos árboles
# de nodo entró al go.work de la tarea, que nombraba el árbol BASE. Consecuencia: el implementer
# de un nodo corría `go test` contra el código del BASE, o sea el falso verde que #43 y #75
# cerraron para gate_test_muerde, justo en el camino que smart.md recomienda por rápido.
# El arreglo es el mismo que el del pin, porque el defecto es el mismo: cada árbol con
# module-path duplicado necesita SU go.work, y se PODA del go.work ajeno (ver discover).
#
# ── Resultado del experimento de replaces (repos reales de un harness) ──
# Los go.mod de los servicios suelen traer `replace <mod> => ../../pkg` (y proto) pensados
# para un layout monorepo que NO existe en el harness (repos/pkg, repos/proto/gen/go no
# existen; el shared vive en otro repo/subdir). Se probó empíricamente:
#   A) go.work sólo con `use`  → FALLA: "conflicting replacements for <proto>" — en modo
#      workspace Go SÍ aplica los replace de los go.mod miembros y chocan (el replace roto
#      del servicio resuelve a una ruta distinta que el replace válido del shared).
#   B) go.work con `replace <mod> => <dir>` (sin versión) → FALLA: "workspace module <mod>
#      is replaced at all versions ... specify the version".
#   C) go.work con `replace <mod> vX => <dir>` (VERSIONADO, X = la versión con que lo pide
#      el require) → OK, compila nativo. El replace del go.work sobreescribe a los de los
#      miembros y deshace el conflicto.
# Conclusión: `use` NO alcanza; hay que EMITIR replaces versionados en el go.work por cada
# módulo del workspace cuyo replace relativo en algún miembro apunta a una ruta inexistente.
# Todo keyed por module-path leído de los go.mod — nunca por nombre de repo.
#
# Portable: sin arrays asociativos ni mapfile (corre en el bash 3.2 de macOS y en Linux).
# Toolchain: el go.work es agnóstico de qué `go` lo lea (gopls/IDE del humano incluidos).
# Para VERIFICAR usá el `go` del PATH que garantiza scripts/bootstrap.sh. Es derivable y
# por-máquina: va gitignoreado.
set -euo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS_DIR="$WS/repos"
WT_DIR="$WS/worktrees"

task="${1:-}"
repo="${2:-}"

# ── MODO --base: un go.work para un ÁRBOL ARBITRARIO fuera del workspace ──
# Lo pide gate_test_muerde de ship.sh (#75). Ese gate levanta el árbol BASE en
# un worktree temporal bajo mktemp, o sea fuera del workspace, así que no hay
# go.work alcanzable subiendo desde el cwd y el `replace ... => ../../pkg` del
# layout monorepo no resuelve. El paquete ni compila, y el gate declaraba el
# tramo sin poder mirarlo:
#
#   ⚠️  el ARBOL BASE no compila sin tu cambio: NO puedo verificar este test
#       replacement directory ../../pkg does not exist
#
# Los SEIS servicios Go de la plataforma usan ese layout, o sea que el gate más
# caro del precheck no verificaba nada en ninguno. La pieza ya existía acá; lo
# único que faltaba era poder apuntarla a un directorio cualquiera.
#
# Las deps salen de repos/ canónico, NO del worktree vivo de la tarea: el árbol
# base tiene que ser "todo igual MENOS tu cambio", y colar el worktree por la
# vía del módulo compartido contaminaría justo lo que el gate mide.
base=""
if [ "${1:-}" = "--base" ]; then
  base="${2:-}"; task=""; repo=""
  [ -n "$base" ] || { echo "❌ --base necesita un directorio"; exit 1; }
  case "$base" in /*) ;; *) echo "❌ --base quiere una ruta ABSOLUTA (recibí '$base')"; exit 1 ;; esac
  [ -d "$base" ] || { echo "❌ --base: el directorio no existe ($base)"; exit 1; }
  base="$(cd "$base" && pwd)"
fi

# ── descubrimiento: go.mod bajo un root, podando ruido y (opcional) una ruta extra ──
discover() { # $1=root  [$2=ruta absoluta a podar]
  local root="$1" extra="${2:-}"
  [ -d "$root" ] || return 0
  # `.review-*` es el arbol CLAVADO del reviewer (verdict-scaffold): mismo
  # module-path que el worktree vivo. Sin podarlo, el go.work puede apuntar
  # el loop nativo al commit sellado en vez de a las ediciones vivas, y el
  # ganador lo decide el orden de readdir: no determinista (demostrado).
  # `*@*` es el arbol de un NODO del DAG (worktree-task.sh --node), y es el
  # MISMO caso por la MISMA razon (#152): comparte module-path con el arbol
  # base y con sus hermanos. Podarlos deja el go.work de la TAREA determinista
  # (gana siempre el arbol base) y saca a los hermanos del go.work de cualquier
  # otro arbol. Cada nodo recibe el suyo por el modo `<repo>@<Tn>` de abajo.
  if [ -n "$extra" ]; then
    find "$root" \( -name .git -o -name vendor -o -name node_modules \
                    -o -name .cache -o -name '.review-*' -o -name '*@*' \
                    -o -path "$extra" \) \
                    -prune -o -name go.mod -print
  else
    find "$root" \( -name .git -o -name vendor -o -name node_modules \
                    -o -name .cache -o -name '.review-*' -o -name '*@*' \) \
                    -prune -o -name go.mod -print
  fi
}

# ── el árbol PROPIO (el pin `.review-*` o el nodo `<repo>@<Tn>`): su RAÍZ matchea
#    justo la poda de discover, que lo borraría entero. Acá se poda todo lo demás
#    y el árbol propio sí entra. ──
discover_pin() { # $1=raíz del árbol propio
  local root="$1"
  [ -d "$root" ] || return 0
  find "$root" \( -name .git -o -name vendor -o -name node_modules \
                  -o -name .cache \) -prune -o -name go.mod -print
}

# ── path de $1 relativo a $2, con prefijo ./ (perl/File::Spec: portable, no exige existencia) ──
reldir() {
  local p
  p="$(perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0],$ARGV[1])' "$1" "$2")"
  case "$p" in .|./*|../*) printf '%s' "$p" ;; *) printf './%s' "$p" ;; esac
}

# module-path (1ra línea `module `) y directiva `go` de un go.mod
mod_of() { awk '$1=="module"{print $2; exit}' "$1"; }
gov_of() { awk '$1=="go"{print $2; exit}' "$1"; }

# imprime "OLD<TAB>TARGET" por cada replace (single-line y en bloque) de un go.mod
replaces_of() {
  awk '
    function emit(s,   n,a,i,arrow) {
      n=split(s,a," "); arrow=0
      for(i=1;i<=n;i++) if(a[i]=="=>"){arrow=i; break}
      if(arrow && arrow<n) print a[1]"\t"a[arrow+1]
    }
    { line=$0; sub(/\/\/.*/,"",line) }
    line ~ /^[ \t]*replace[ \t]*\(/ { inblk=1; next }
    inblk && line ~ /^[ \t]*\)/     { inblk=0; next }
    inblk { gsub(/^[ \t]+/,"",line); if(line!="") emit(line); next }
    line ~ /^[ \t]*replace[ \t]+/   { sub(/^[ \t]*replace[ \t]+/,"",line); emit(line) }
  ' "$1"
}

# versión con que un go.mod pide el module-path $2 (para el replace versionado); default v0.0.0
reqver_of() {
  awk -v m="$2" '{for(i=1;i<NF;i++) if($i==m && $(i+1) ~ /^v[0-9]/){print $(i+1); exit}}' "$1" \
    | { read -r v || true; printf '%s' "${v:-v0.0.0}"; }
}

# ── selección de módulos: registros "modpath<TAB>dir<TAB>gomod"; el ÚLTIMO gana por module-path.
#    Para el fallback del worktree: cargamos repos/ primero y el worktree después (worktree gana). ──
records=""
collect() { # lee paths de go.mod por stdin y agrega registros
  local gomod mp dir
  while IFS= read -r gomod; do
    [ -n "$gomod" ] || continue
    mp="$(mod_of "$gomod")"; [ -n "$mp" ] || continue
    dir="$(cd "$(dirname "$gomod")" && pwd)"
    records="${records}${mp}	${dir}	${gomod}
"
  done
}

donde=""
if [ -n "$base" ]; then
  # Mismo patrón que el modo tarea: canónico primero, el árbol dado GANA por
  # module-path. Así el paquete bajo prueba se resuelve contra la copia base y
  # sus deps del monorepo contra repos/.
  workfile="$base/go.work"; workdir="$base"; donde=" [árbol base del gate muerde]"
  collect < <(discover "$REPOS_DIR")
  collect < <(discover "$base")
elif [ -z "$task" ]; then
  workfile="$WS/go.work"; workdir="$WS"
  collect < <(discover "$WS" "$WT_DIR")               # raíz: poda worktrees
else
  # task-id acotado (mismo criterio que worktree-task.sh) para no cruzar dirs raros
  case "$task" in
    [A-Za-z0-9][A-Za-z0-9._-]*) ;;
    *) echo "❌ task-id inválido '$task'"; exit 1 ;;
  esac
  wtroot="$WT_DIR/$task"
  [ -d "$wtroot" ] || { echo "❌ worktree de la tarea '$task' no existe ($wtroot)"; exit 1; }
  if [ -z "$repo" ]; then
    workfile="$wtroot/go.work"; workdir="$wtroot"
    collect < <(discover "$REPOS_DIR")                # canónico primero
    collect < <(discover "$wtroot")                   # worktree gana por module-path
  else
    # El `@<Tn>` es del ÁRBOL, no del repo: se parte acá igual que en ship.sh
    # (#149/#150), para que `repo` siga siendo la identidad y el sufijo viaje
    # sólo a la ruta del worktree.
    node=""
    case "$repo" in *@*) node="${repo##*@}"; repo="${repo%@*}" ;; esac
    case "$node" in
      *[!A-Za-z0-9_-]*)
        echo "❌ nodo inválido: '$node' (solo letras, números, guion y guion bajo)"
        echo "   La forma es <repo>@<Tn>, igual que el directorio del worktree."
        exit 1 ;;
    esac
    case "$repo" in
      [A-Za-z0-9][A-Za-z0-9._-]*) ;;
      *) echo "❌ repo inválido '$repo'"; exit 1 ;;
    esac
    if [ -n "$node" ]; then
      # ── el árbol de ESE nodo del DAG (#152) ──
      # Misma terna que el pin, por la misma razón: canónico de fondo, los OTROS
      # repos vivos de la tarea (podando el árbol base de ESTE repo, que comparte
      # module-path), y el árbol propio último para que gane. Los hermanos @Tm ya
      # los podó discover.
      nodedir="$wtroot/$repo@$node"
      [ -d "$nodedir" ] || {
        echo "❌ no existe el árbol del nodo ($nodedir)"
        echo "   ↳ lo crea: scripts/worktree-task.sh --node $node $task $repo"
        exit 1; }
      workfile="$nodedir/go.work"; workdir="$nodedir"; donde=" [árbol del nodo $node]"
      collect < <(discover "$REPOS_DIR")
      collect < <(discover "$wtroot" "$wtroot/$repo")
      collect < <(discover_pin "$nodedir")
    else
    pin="$wtroot/.review-$repo"
    [ -d "$pin" ] || {
      echo "❌ no existe el árbol clavado del reviewer ($pin)"
      echo "   ↳ lo clava el sello del veredicto: scripts/verdict-scaffold.sh $task $repo"
      exit 1; }
    workfile="$pin/go.work"; workdir="$pin"; donde=" [árbol clavado del reviewer]"
    collect < <(discover "$REPOS_DIR")                # canónico primero
    collect < <(discover "$wtroot" "$wtroot/$repo")   # los OTROS repos vivos de la tarea
    collect < <(discover_pin "$pin")                  # el commit SELLADO gana
    fi
  fi
fi

# ── ganadores: último registro por module-path, ordenado por module-path ──
winners="$(printf '%s' "$records" | awk -F'\t' 'NF>=3{last[$1]=$0} END{for(k in last) print last[k]}' | sort)"

# ── no-op limpio para clientes sin Go ──
if [ -z "$winners" ]; then
  echo "(sin módulos Go — go.work no aplica)"
  exit 0
fi

# dir ganador de un module-path
win_dir() { printf '%s\n' "$winners" | awk -F'\t' -v m="$1" '$1==m{print $2; exit}'; }

# ── go X.Y.Z: la mayor directiva `go` entre los módulos ──
maxgo=""
while IFS='	' read -r mp dir gomod; do
  [ -n "$gomod" ] || continue
  gv="$(gov_of "$gomod")"; [ -n "$gv" ] || continue
  if [ -z "$maxgo" ]; then maxgo="$gv"
  else maxgo="$(printf '%s\n%s\n' "$maxgo" "$gv" | sort -V | tail -1)"; fi
done <<EOF
$winners
EOF
[ -n "$maxgo" ] || maxgo="1.21"

# ── replaces rotos: por cada replace relativo de un miembro cuyo target NO existe y cuyo
#    module-path es del workspace → replace versionado hacia el dir ganador. "old<TAB>ver". ──
needs=""
while IFS='	' read -r mp dir gomod; do
  [ -n "$gomod" ] || continue
  while IFS='	' read -r old tgt; do
    [ -n "$old" ] || continue
    case "$tgt" in ./*|../*) ;; *) continue ;; esac          # sólo targets relativos
    resolved="$(perl -MFile::Spec -e 'print File::Spec->rel2abs($ARGV[0],$ARGV[1])' "$tgt" "$dir")"
    [ -e "$resolved" ] && continue                           # replace sano → nada que hacer
    [ -n "$(win_dir "$old")" ] || continue                   # el reemplazado no es del workspace
    case "
$needs" in *"
$old	"*) continue ;; esac                                   # ya registrado (dedupe por module-path)
    needs="${needs}${old}	$(reqver_of "$gomod" "$old")
"
  done < <(replaces_of "$gomod")
done <<EOF
$winners
EOF

# ── composición del go.work ──
nmods="$(printf '%s\n' "$winners" | grep -c . || true)"
nrepl=0
content="go ${maxgo}"$'\n\n'"use ("$'\n'
while IFS='	' read -r mp dir gomod; do
  [ -n "$dir" ] || continue
  content="${content}	$(reldir "$dir" "$workdir")
"
done <<EOF
$winners
EOF
content="${content})"$'\n'
if [ -n "$(printf '%s' "$needs" | tr -d '[:space:]')" ]; then
  content="${content}"$'\n'
  while IFS='	' read -r old ver; do
    [ -n "$old" ] || continue
    content="${content}replace ${old} ${ver} => $(reldir "$(win_dir "$old")" "$workdir")
"
    nrepl=$((nrepl+1))
  done < <(printf '%s' "$needs" | sort)
fi

# ── escritura atómica e idempotente ──
tmp="$(mktemp)"; printf '%s' "$content" > "$tmp"
if [ -f "$workfile" ] && cmp -s "$tmp" "$workfile"; then rm -f "$tmp"; else mv "$tmp" "$workfile"; fi

echo "✓ go.work (${nmods} módulos, ${nrepl} replaces) → ${workfile}${donde}"
