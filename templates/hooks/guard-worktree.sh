#!/usr/bin/env bash
# guard-worktree.sh: un worktree tiene UN dueño a la vez.
#
# PROBLEMA: `worktrees/<task>/<repo>` no tenía ninguna guarda. Con varias
# sesiones de Claude Code abiertas sobre el mismo workspace, dos implementers
# pueden terminar editando el mismo árbol: se pisan archivos, se pisan el
# índice de git, y el síntoma que ve el humano es "cambios que se deshacen
# solos". El lock de ship.sh es por REPO y solo cubre el push; el semáforo de
# build-slot.sh es por MÁQUINA y solo cubre builds. En medio, la edición
# concurrente del árbol no la cubría nadie.
#
# CÓMO: la primera sesión que escribe en un worktree lo RECLAMA. Otra sesión
# que intente escribir ahí se bloquea, con el id de quien lo tiene. El reclamo
# se refresca en cada escritura, así que caduca solo cuando su dueño deja de
# trabajar (TTL abajo) y entonces cualquiera puede tomarlo.
#
# FAIL-OPEN a propósito, y esto lo diferencia de block-direct-push y
# guard-canonical, que son fail-CLOSED: esos impiden acciones prohibidas o
# irreversibles, y ante la duda conviene frenar. Este solo coordina, y una
# colisión es recuperable con git. Bloquear todas las escrituras porque falta
# jq sería un remedio peor que la enfermedad.
set -uo pipefail

TTL_SECONDS="${HARNESS_WORKTREE_TTL:-3600}"   # sin escrituras por 1 h, el reclamo caduca

input="$(cat 2>/dev/null)"
[ -n "$input" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
session="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$path" ] && [ -n "$session" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
case "$path" in
  "$root"/worktrees/*/*) ;;
  *) exit 0 ;;                       # fuera de un worktree, no es asunto de este hook
esac

rel="${path#"$root"/worktrees/}"
task="${rel%%/*}"; rest="${rel#*/}"; repo="${rest%%/*}"
[ -n "$task" ] && [ -n "$repo" ] && [ "$task" != "$rest" ] || exit 0

claims="$root/.harness/claims"
mkdir -p "$claims" 2>/dev/null || exit 0
claim="$claims/${task}__${repo}.json"
now="$(date -u +%s)"

write_claim() {
  # tmp + mv: dos hooks concurrentes escribiendo el mismo claim no pueden
  # dejar un JSON a medias (el mv es atómico dentro del mismo directorio).
  local tmp
  tmp="$(mktemp "$claims/.${task}__${repo}.XXXXXX" 2>/dev/null)" || return 0
  printf '{"session":"%s","task":"%s","repo":"%s","at":%s}\n' \
    "$session" "$task" "$repo" "$now" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$claim" 2>/dev/null || rm -f "$tmp"
}

if [ ! -f "$claim" ]; then
  write_claim; exit 0
fi

owner="$(jq -r '.session // empty' "$claim" 2>/dev/null)"
at="$(jq -r '.at // 0' "$claim" 2>/dev/null)"
case "$at" in ''|*[!0-9]*) at=0 ;; esac

if [ -z "$owner" ] || [ "$owner" = "$session" ]; then
  write_claim; exit 0                # es nuestro: refrescar y seguir
fi

age=$(( now - at ))
if [ "$age" -ge "$TTL_SECONDS" ]; then
  echo "⚠️  worktree $task/$repo estaba reclamado por la sesión ${owner:0:8} pero lleva" >&2
  echo "    $((age / 60)) min sin escrituras: lo tomo yo." >&2
  write_claim; exit 0
fi

cat >&2 <<EOF
⛔ worktree ocupado: $task/$repo lo está usando la sesión ${owner:0:8}
   (última escritura hace $((age / 60)) min).

   Dos sesiones editando el mismo worktree se pisan los archivos y el índice
   de git. El síntoma que verías después es "cambios que se deshacen solos",
   y para entonces ya no se sabe cuál de las dos los perdió.

   Opciones:
   · Trabajá esta tarea desde la sesión que ya la tiene.
   · Usá otro worktree: scripts/worktree-task.sh <otra-task> $repo
   · Si esa sesión ya murió, borrá el reclamo:
     rm .harness/claims/${task}__${repo}.json
   El reclamo caduca solo tras $((TTL_SECONDS / 60)) min sin escrituras.
EOF
exit 2
