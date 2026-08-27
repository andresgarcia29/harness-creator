#!/usr/bin/env bash
# pull-all.sh: TODOS los clones canónicos al último main, EN PARALELO.
#
# "Empezar con lo más nuevo" es preparación determinista: cuesta $0 tokens y
# evita la peor clase de retrabajo (implementar sobre una base vieja). Reglas:
#   · primero MATERIALIZA: lo que manifest.yaml declara y repos/ no tiene, se
#     clona (un workspace recién creado no tenía comando que lo poblara)
#   · paralelo total: el cuello es la red, no el CPU
#   · un clon SUCIO se salta con aviso (el canónico debe estar limpio; los
#     cambios viven en worktrees, y un pull --rebase sobre mugre es peligro)
#   · una rama distinta de main se reporta (no se hace checkout automático)
#   · al final, si algún HEAD se movió, el grafo se refresca en background
# Portabilidad: bash 3.2 (macOS), sin GNU-ismos. Exit 1 si algún pull FALLÓ
# (red/conflicto); los saltados por mugre no son fallo, son aviso.
set -u

WS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/pull-all.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

pull_one() {  # pull_one <dir> <slot>
  local d="$1" slot="$2" name branch note="" before after out untracked
  name="$(basename "$d")"
  [ "$d" = "$WS" ] && name="(workspace)"
  # Solo la mugre VERSIONADA impide el pull: un rebase no toca los untracked.
  # Caso de campo: un artefacto untracked (graphify-out/) dejó un repo 16
  # commits atrás y las auditorías corrieron sobre código que ya no existía.
  if [ -n "$(git -C "$d" status --porcelain -uno 2>/dev/null)" ]; then
    echo "○ $name: cambios VERSIONADOS en el clon canónico; lo salto (el trabajo va en worktrees)" > "$OUT/$slot.txt"
    printf '%s\n' "$name" > "$OUT/$slot.skip"
    echo 2 > "$OUT/$slot.rc"
    return
  fi
  untracked="$(git -C "$d" status --porcelain 2>/dev/null | grep -c '^??' || true)"
  [ "${untracked:-0}" -gt 0 ] && note=" [$untracked untracked: no estorban al rebase]"
  branch="$(git -C "$d" symbolic-ref --short HEAD 2>/dev/null || echo desconocida)"

  # ── UN ÁRBOL QUE NO ES LA TRUNK ES UNA RESPUESTA FALSA SIN SEÑAL ─────
  # El clon canónico es la ruta de lectura RECOMENDADA: el CLAUDE.md generado
  # empuja al agente a consultarlo para orientarse, porque abrir veinte
  # archivos del worktree es el anti-patrón. Con una rama de tarea checkeada,
  # ese camino barato devuelve código viejo y este script decía "ya al día".
  #
  # Caso de campo: design-system en task/workspace-x1n, 149 commits atrás,
  # el único de 31 repos en ese estado y justo el que había que auditar. Se
  # seleccionaron 10 defectos leyendo ese árbol y 4 ya estaban arreglados en
  # main (uno se había arreglado y revertido, y su blocker ya no existía).
  # El pull refrescaba origin/<trunk>, así que la ref avanzaba y el árbol no.
  #
  # La rama ajena NO se toca: puede tener commits sin publicar, y es el mismo
  # invariante que la guarda de refresh_canonical en worktree-task.sh (un pull
  # sobre trabajo versionado de otro es la única forma de que esto destruya
  # algo). Lo que sí se paga es el fetch, para que la distancia sea un número
  # real y origin/<trunk> quede fresco para quien lee refs.
  #
  # Va ANTES del pull a propósito, y eso arregla de paso la otra cara del
  # mismo bug: una rama de tarea SIN upstream (borrada del remoto tras el
  # merge, el caso más común) hacía fallar el pull y salía un "✗" que
  # diagnosticaba "red o conflicto de rebase". Ni red ni conflicto: el árbol
  # simplemente no era la trunk.
  trunk="$(git -C "$d" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  if [ -n "$trunk" ] && [ "$branch" != "$trunk" ]; then
    local behind lbl suf="" fetched=1
    git -C "$d" fetch origin >/dev/null 2>&1 || fetched=0
    git -C "$d" remote set-head origin -a >/dev/null 2>&1 || true
    behind="$(git -C "$d" rev-list --count "HEAD..origin/$trunk" 2>/dev/null || echo '?')"
    [ "$fetched" = 0 ] && suf=" [el fetch falló: la distancia es contra el origin/$trunk local y puede ser mayor]"
    lbl="$branch"; [ "$branch" = "desconocida" ] && lbl="HEAD desacoplado"
    echo "◇ $name: $lbl checkeado; el árbol NO es $trunk ($behind commits atrás)$suf" > "$OUT/$slot.txt"
    printf '%s → %s (%s commits atrás de origin/%s)%s\n' \
      "$name" "$lbl" "$behind" "$trunk" "$suf" > "$OUT/$slot.branch"
    # rc 3: ni fallo (1) ni saltado por mugre (2). Es aviso, no rompe el exit.
    echo 3 > "$OUT/$slot.rc"
    return
  fi
  # La nota de rama queda solo para el caso que este bloque no cubre (sin
  # origin/HEAD resoluble). Antes decía `main|master` cableado, que además
  # daba nota espuria en un repo con trunk `develop`.
  [ -n "$trunk" ] || case "$branch" in
    main|master) ;;
    *) note="$note [rama: $branch]" ;;
  esac
  # Sin upstream, git pull --rebase no sabe contra que rebasar: el clon queda
  # atras con un "✗" criptico que diagnostica "red o conflicto". Caso de campo
  # (COR-642): videocore quedo 40 commits atras y un doc canonico se escribio
  # contra codigo que ya no existia. Si origin tiene la rama homonima, el
  # arreglo es determinista: se configura y se sigue; si no la tiene, el pull
  # fallara abajo y se reporta como siempre (fallo visible, no silencio).
  if [ "$branch" != "desconocida" ] && \
     ! git -C "$d" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$branch" \
      || git -C "$d" fetch origin "$branch" >/dev/null 2>&1 || true
    if git -C "$d" branch --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1; then
      note="$note [upstream reconfigurado a origin/$branch]"
    fi
  fi
  before="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
  if out="$(git -C "$d" pull --rebase 2>&1)"; then
    # Aprovechando que la red ya se pagó: sanar origin/HEAD local, que un
    # remote set-head ajeno puede haber envenenado (issue #32); de él leen
    # base_branch y change-id cuando no pueden pagar la red.
    git -C "$d" remote set-head origin -a >/dev/null 2>&1 || true
    after="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
    if [ "$before" = "$after" ]; then
      echo "✓ $name: ya al día ($after)$note" > "$OUT/$slot.txt"
    else
      echo "✓ $name: $before → $after$note" > "$OUT/$slot.txt"
      echo 1 > "$OUT/$slot.moved"
    fi
    echo 0 > "$OUT/$slot.rc"
  else
    echo "✗ $name: $(printf '%s' "$out" | tail -1)$note" > "$OUT/$slot.txt"
    echo 1 > "$OUT/$slot.rc"
  fi
}

slot=0
PIDS=""

# ── LEY: UN REPO ARCHIVADO SE IGNORA SIEMPRE ──────────────────────────
# Esta muerto por decision explicita de alguien y es de solo lectura. Meterlo
# aca contamina el resultado con codigo que nadie mantiene y que ningun agente
# puede tocar. La lista la mantiene scripts/archived-repos.sh (cacheada); si no
# existe, no se filtra nada: ausencia de cache no es ausencia de archivados,
# pero tampoco se inventa una lista.
_is_archived() {  # _is_archived <repo>
  [ -f "$WS/.cache/archived-repos.txt" ] || return 1
  grep -qxF "$1" "$WS/.cache/archived-repos.txt"
}

# ── LO QUE EL MANIFEST DECLARA Y repos/ NO TIENE, SE CLONA ────────────
# manifest.yaml es la fuente de verdad de los clones, pero NINGÚN script del
# plugin los materializaba: en un workspace recién generado repos/ ni existe,
# este script no tenía sobre qué iterar y salía 0 con "sin repos git". El
# onboarding no tenía comando que resolviera el estado inicial (sin clones no
# hay loop local, ni grafo, ni worktrees) y el único síntoma era un verde.
#
# Va ACÁ y no en un script aparte a propósito: `make pull` ya es el comando de
# "poné el workspace en su estado más nuevo", y un clon que falta es
# exactamente eso. Es idempotente: lo ya clonado no se re-clona, se pullea
# abajo como siempre.
#
# Se clona el HEAD por defecto del origin, NO el `branch:` del manifest: un -b
# contra una rama que el remoto no tiene revienta el clone entero, y el loop de
# abajo ya reporta (y con distancia) el árbol que no es la trunk.
MANIFEST="$WS/manifest.yaml"
CL="$OUT/clones"
mkdir -p "$CL"

# Parseo a mano, el MISMO que hace harness-policy.py (repo_kinds/repo_names):
# se cortan los comentarios primero, así los ejemplos comentados del template no
# ensucian, y una clave top-level cierra el item en curso, de modo que la lista
# `dag:` de más abajo no aporte repos falsos. Sale "<nombre>\t<url>" por repo;
# un repo sin `url:` sale con la url vacía y se REPORTA (no se calla).
_manifest_repos() {
  [ -f "$MANIFEST" ] || return 0
  awk '
    function flush() { if (n != "") printf "%s\t%s\n", n, u; n=""; u="" }
    /^[^ \t#]/ { flush(); inrepos = ($0 ~ /^repos:/); next }
    {
      sub(/#.*/, ""); line = $0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (!inrepos || line == "") next
      if (line ~ /^-[ \t]*name:/) {
        flush(); sub(/^-[ \t]*name:[ \t]*/, "", line)
        gsub(/^["\047]+|["\047]+$/, "", line); n = line
      } else if (n != "" && line ~ /^url:/) {
        sub(/^url:[ \t]*/, "", line)
        gsub(/^["\047]+|["\047]+$/, "", line); u = line
      }
    }
    END { flush() }
  ' "$MANIFEST"
}

clone_one() {  # clone_one <nombre> <url> <slot>
  local name="$1" url="$2" slot="$3"
  # Mismo estilo que skills-sync.sh: silencioso si sale bien, y si falla dice
  # qué mirar. </dev/null es obligatorio: esto corre en background compartiendo
  # el stdin del while de abajo, y un git sobre ssh que pida algo se lo comería.
  if git clone -q "$url" "$WS/repos/$name" </dev/null >/dev/null 2>&1; then
    echo "✓ clonado $name (del manifest: $url)" > "$CL/$slot.txt"
    : > "$CL/$slot.ok"
  else
    echo "✗ $name: clone falló (¿existe? ¿acceso?) url: $url" > "$CL/$slot.txt"
    echo 1 > "$CL/$slot.rc"
  fi
}

declared=0; clone_fails=0; nourl_n=0; cloned_n=0; cslot=0
CPIDS=""
while IFS="$(printf '\t')" read -r name url; do
  [ -n "$name" ] || continue
  # El nombre viene de un archivo de la instancia y se usa para armar una ruta:
  # misma higiene que el resto del harness (bajo repos/ y sin traversal).
  case "$name" in
    */*|.*|*" "*) echo "✗ manifest.yaml: nombre de repo inválido ('$name'); lo ignoro"; continue ;;
  esac
  _is_archived "$name" && continue
  declared=$((declared+1))
  [ -d "$WS/repos/$name/.git" ] && continue
  cslot=$((cslot+1))
  if [ -d "$WS/repos/$name" ]; then
    echo "✗ $name: repos/$name existe y NO es un clon git; no lo piso (borralo y re-corré make pull)" > "$CL/$cslot.txt"
    echo 1 > "$CL/$cslot.rc"
    continue
  fi
  if [ -z "$url" ]; then
    echo "⚠️  $name: declarado en manifest.yaml SIN url; no hay de dónde clonarlo" > "$CL/$cslot.txt"
    printf '%s\n' "$name" > "$CL/$cslot.nourl"
    continue
  fi
  mkdir -p "$WS/repos"
  clone_one "$name" "$url" "$cslot" </dev/null &
  CPIDS="$CPIDS $!"
done <<EOF
$(_manifest_repos)
EOF
for p in $CPIDS; do wait "$p" 2>/dev/null; done
for f in "$CL"/*.rc;    do [ -f "$f" ] && clone_fails=$((clone_fails+1)); done
for f in "$CL"/*.ok;    do [ -f "$f" ] && cloned_n=$((cloned_n+1)); done
for f in "$CL"/*.nourl; do [ -f "$f" ] && nourl_n=$((nourl_n+1)); done
if [ "$cslot" -gt 0 ]; then
  for f in "$CL"/*.txt; do [ -f "$f" ] && cat "$f"; done | sort
  [ "$cloned_n" -gt 0 ] && echo "── $cloned_n repo(s) del manifest clonados; siguen al pull como el resto"
fi

# Un repo declarado sin url no se puede materializar NUNCA: es un aviso con
# remediación exacta, y se dice tanto arriba como en el resumen (si solo se
# dijera arriba se lo come el scroll, que es la ley del resto del script).
_report_nourl() {
  [ "$nourl_n" -gt 0 ] || return 0
  echo "── ⚠️  $nourl_n repo(s) del manifest SIN url: no se pueden clonar"
  for f in "$CL"/*.nourl; do [ -f "$f" ] || continue; printf '     %s\n' "$(cat "$f")"; done
  echo "   Agregale 'url: <remoto-git>' a esa entrada de manifest.yaml y re-corré make pull."
}

for d in "$WS"/repos/*/; do
  if _is_archived "$(basename "$d")"; then continue; fi
  [ -d "$d/.git" ] || continue
  slot=$((slot+1))
  pull_one "${d%/}" "$slot" &
  PIDS="$PIDS $!"
done
if [ -d "$WS/.git" ]; then
  slot=$((slot+1))
  pull_one "$WS" "$slot" &
  PIDS="$PIDS $!"
fi
if [ "$slot" -le 0 ]; then
  if [ "$declared" -gt 0 ]; then
    echo "sin repos git: manifest.yaml declara $declared repo(s) y NINGUNO quedó en repos/ (detalle arriba)"
  else
    echo "sin repos git (ni en repos/ ni el workspace)"
  fi
  _report_nourl
  [ "$clone_fails" -gt 0 ] && exit 1
  exit 0
fi

for p in $PIDS; do wait "$p" 2>/dev/null; done

for f in "$OUT"/*.txt; do cat "$f"; done | sort
fails=0
for f in "$OUT"/*.rc; do [ "$(cat "$f")" = "1" ] && fails=$((fails+1)); done

# HEADs nuevos = grafo viejo: refresh en background, fail-open, sin bloquear
if ls "$OUT"/*.moved >/dev/null 2>&1 && [ -x "$WS/scripts/graph-refresh.sh" ]; then
  (bash "$WS/scripts/graph-refresh.sh" >/dev/null 2>&1 &)
  echo "── grafo: refresh disparado en background (HEADs nuevos)"
fi

# "Todo al día" con repos salteados es la mentira cara: el resumen es lo
# único que se lee (el detalle de arriba se pierde en el scroll), así que los
# NO actualizados se nombran AQUÍ, en rojo, con su remediación.
skipped=""
skip_n=0
for f in "$OUT"/*.skip; do
  [ -f "$f" ] || continue
  skipped="$skipped $(cat "$f")"
  skip_n=$((skip_n+1))
done
if [ "$skip_n" -gt 0 ]; then
  echo "── ⚠️  $skip_n repo(s) NO ACTUALIZADOS (clon canónico con cambios versionados):$skipped"
  echo "   Auditar sobre un clon viejo produce inventarios de código que ya no existe."
  echo "   Limpia el canónico (git -C repos/<repo> stash) y re-corre make pull."
fi
# Misma ley que los saltados: si no se nombra ACÁ, se pierde en el scroll y el
# resumen vuelve a ser la mentira cara.
branch_n=0
for f in "$OUT"/*.branch; do
  [ -f "$f" ] || continue
  branch_n=$((branch_n+1))
done
if [ "$branch_n" -gt 0 ]; then
  echo "── ⚠️  $branch_n repo(s) con OTRA RAMA checkeada (lo que leas ahí NO es la trunk):"
  for f in "$OUT"/*.branch; do [ -f "$f" ] || continue; printf '     %s' "$(cat "$f")"; echo; done
  echo "   Leer ese clon devuelve respuestas viejas sin ninguna señal, y es la ruta"
  echo "   de lectura que el CLAUDE.md recomienda para orientarse."
  echo "   Cuando la rama ya no haga falta: git -C repos/<repo> checkout <trunk> && make pull."
  echo "   (la rama NO se toca sola: puede tener commits sin publicar)"
fi
_report_nourl
if [ "$clone_fails" -gt 0 ]; then
  echo "── $clone_fails clone(s) del manifest FALLARON; detalle arriba"
  echo "   Sin ese clon no hay worktree, ni grafo, ni lectura canónica de ese repo."
fi
if [ "$fails" -gt 0 ]; then
  echo "── $fails pull(s) FALLARON (red o conflicto de rebase); detalle arriba"
fi
if [ "$fails" -gt 0 ] || [ "$clone_fails" -gt 0 ]; then
  exit 1
fi
if [ "$skip_n" -gt 0 ] || [ "$branch_n" -gt 0 ]; then
  echo "── al día: $((slot - skip_n - branch_n)) de $slot repos ($skip_n saltados, $branch_n en otra rama; arriba en rojo)"
elif [ "$nourl_n" -gt 0 ]; then
  # "todo al día" con un repo del manifest que ni siquiera está clonado es la
  # misma mentira cara que con uno salteado.
  echo "── al día: $slot repos ($nourl_n declarado(s) en el manifest sin url, arriba en rojo)"
else
  echo "── todo al día: $slot repos en paralelo"
fi
