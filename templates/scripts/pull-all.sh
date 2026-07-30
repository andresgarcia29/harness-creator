#!/usr/bin/env bash
# pull-all.sh: TODOS los clones canónicos al último main, EN PARALELO.
#
# "Empezar con lo más nuevo" es preparación determinista: cuesta $0 tokens y
# evita la peor clase de retrabajo (implementar sobre una base vieja). Reglas:
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
  case "$branch" in main|master) ;; *) note="$note [rama: $branch]" ;; esac
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
[ "$slot" -gt 0 ] || { echo "sin repos git (ni en repos/ ni el workspace)"; exit 0; }

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
if [ "$fails" -gt 0 ]; then
  echo "── $fails pull(s) FALLARON (red o conflicto de rebase); detalle arriba"
  exit 1
fi
if [ "$skip_n" -gt 0 ]; then
  echo "── al día: $((slot - skip_n)) de $slot repos ($skip_n saltados, arriba en rojo)"
else
  echo "── todo al día: $slot repos en paralelo"
fi
