#!/usr/bin/env bash
# forge.sh — la capa de forge del harness. Un eje que varía, un dispatch.
#
# POR QUÉ EXISTE: los 13 cronjobs de self-healing tenían GitHub cableado en
# dos lugares distintos, y ninguno era opcional. El prompt inyectado ordena
# "entrega PR o issue vía gh" a TODOS, y `ci-doctor` consultaba el CI con
# `gh run list`. En un workspace de GitLab, Bitbucket o Gitea eso significaba
# que toda la capa de self-healing entregaba a la nada, en silencio: el
# detector encontraba trabajo, el agente despertaba, gastaba tokens, y su PR
# no llegaba a ningún lado.
#
# Un forge tiene que contestar tres preguntas, y son las mismas para todos:
#   · ¿qué corridas de CI fallaron hace poco?     forge_ci_failed
#   · ¿cómo abro un issue?                        forge_issue_create
#   · ¿cómo abro un PR desde esta rama?           forge_pr_create
#
# Implementados: github (gh) y gitlab (glab). Agregar bitbucket o gitea es
# una función más, no un fork (regla 8 de CONTRIBUTING). Un forge sin driver
# NO se finge: se dice, y quien lo lea sabe exactamente qué falta.
#
# Uso:  . scripts/forge.sh   (se sourcea; no hace nada por sí solo)
set -u

# El forge se DETECTA del remote, no se configura por duplicado: el dato ya
# está en git. La respuesta de la entrevista (forge: en answers) gana si
# existe, para el caso de un self-hosted con dominio propio.
forge_kind() {  # forge_kind [dir] → github | gitlab | bitbucket | desconocido
  local d="${1:-.}" cfg="" url=""
  cfg="$(grep -E '^[[:space:]]*forge:' "${FORGE_ANSWERS:-harness-answers.yaml}" 2>/dev/null \
    | head -1 | awk '{print $2}' | tr -d '"')"
  case "$cfg" in github|gitlab|bitbucket) printf '%s' "$cfg"; return 0 ;; esac
  url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
  case "$url" in
    *github.com*)    printf 'github' ;;
    *gitlab*)        printf 'gitlab' ;;
    *bitbucket.org*) printf 'bitbucket' ;;
    *)               printf 'desconocido' ;;
  esac
}

# slug owner/repo desde el remote, para las CLIs que lo piden.
forge_slug() {  # forge_slug [dir]
  git -C "${1:-.}" remote get-url origin 2>/dev/null \
    | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#'
}

_forge_missing() {  # _forge_missing <forge> <verbo>
  echo "⚠️  no puedo $2 en un forge '$1': este harness implementa github y gitlab." >&2
  echo "    NO es que no haya nada que hacer: es que no sé cómo hacerlo acá." >&2
  echo "    ↳ agregá el driver en scripts/forge.sh (una función, no un fork)." >&2
  return 3   # 3 = saltado, la misma convención que los detectores de cronjob
}

# ── ¿qué corridas de CI fallaron? ─────────────────────────────────────
# Imprime una línea por corrida fallida: "<id> [<workflow>] <título>".
# Exit 0 con salida vacía = miré y no hay nada. Exit 3 = NO pude mirar, que
# es lo que distingue un CI sano de un CI invisible.
forge_ci_failed() {  # forge_ci_failed <dir> <desde-iso>
  local d="$1" since="$2" k slug
  k="$(forge_kind "$d")"; slug="$(forge_slug "$d")"
  [ -n "$slug" ] || return 3
  case "$k" in
    github)
      command -v gh >/dev/null || return 3
      gh run list --repo "$slug" --branch "$(forge_base_branch "$d")" --status failure \
        --created ">$since" --json databaseId,displayTitle,workflowName \
        --jq '.[] | "\(.databaseId) [\(.workflowName)] \(.displayTitle)"' 2>/dev/null || return 3 ;;
    gitlab)
      command -v glab >/dev/null || return 3
      glab ci list --repo "$slug" --status failed --per-page 20 2>/dev/null \
        | awk 'NR>1 && NF {print $1" [pipeline] "$0}' || return 3 ;;
    *) _forge_missing "$k" "consultar el CI" ;;
  esac
}

forge_base_branch() {  # la rama trunk del repo, sin suponer que se llama main
  local b
  [ -n "${HARNESS_BASE_BRANCH:-}" ] && { printf '%s' "$HARNESS_BASE_BRANCH"; return 0; }
  b="$(git -C "${1:-.}" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -n "$b" ] || b=main
  printf '%s' "$b"
}

forge_issue_create() {  # forge_issue_create <dir> <título> <cuerpo>
  local d="$1" title="$2" body="$3" k slug
  k="$(forge_kind "$d")"; slug="$(forge_slug "$d")"
  case "$k" in
    github)
      command -v gh >/dev/null || return 3
      gh issue create --repo "$slug" --title "$title" --body "$body" ;;
    gitlab)
      command -v glab >/dev/null || return 3
      glab issue create --repo "$slug" --title "$title" --description "$body" --yes ;;
    *) _forge_missing "$k" "abrir un issue" ;;
  esac
}

# ── ¿este repo esta ARCHIVADO en el forge? ────────────────────────────
# Un repo archivado es de solo lectura y esta muerto por decision explicita de
# alguien. Tomarlo en cuenta cuesta de tres formas: contamina el grafo y el
# inventario con simbolos que ya nadie mantiene, hace que un explorador cite
# codigo que no se puede tocar, y gasta reloj clonando y refrescando lo que no
# se va a modificar nunca.
#
#   exit 0 = archivado · 1 = vivo · 3 = NO pude averiguarlo
# La tercera no se colapsa con las otras dos a proposito: ante duda el repo se
# trata como VIVO (no se esconde nada por no haber podido mirar), pero quien
# llama puede decir que no verifico.
forge_is_archived() {  # forge_is_archived <dir>
  local d="$1" k slug out
  k="$(forge_kind "$d")"; slug="$(forge_slug "$d")"
  [ -n "$slug" ] || return 3
  case "$k" in
    github)
      command -v gh >/dev/null || return 3
      out="$(gh repo view "$slug" --json isArchived --jq '.isArchived' 2>/dev/null)" || return 3
      [ "$out" = "true" ] && return 0 || return 1 ;;
    gitlab)
      command -v glab >/dev/null || return 3
      out="$(glab api "projects/${slug//\//%2F}" 2>/dev/null | jq -r '.archived // empty' 2>/dev/null)" || return 3
      [ "$out" = "true" ] && return 0 || return 1 ;;
    *) return 3 ;;
  esac
}

# ── ¿ya hay un PR abierto para esta rama? ─────────────────────────────
# Lo necesita `flow: prs`: una ronda de rework re-corre ship.sh sobre la MISMA
# rama, y crear el PR otra vez falla. Preguntar primero convierte ese fallo en
# un caso normal. Exit 0 con salida vacía = miré y no hay PR. Exit 3 = no pude
# mirar, que no es lo mismo y quien llama tiene que poder distinguirlo.
forge_pr_url() {  # forge_pr_url <dir> <rama>
  local d="$1" branch="$2" k slug
  k="$(forge_kind "$d")"; slug="$(forge_slug "$d")"
  case "$k" in
    github)
      command -v gh >/dev/null || return 3
      gh pr list --repo "$slug" --head "$branch" --state open \
        --json url --jq '.[0].url // empty' 2>/dev/null || return 3 ;;
    gitlab)
      command -v glab >/dev/null || return 3
      glab mr list --repo "$slug" --source-branch "$branch" 2>/dev/null \
        | awk 'NR==1{print $1}' || return 3 ;;
    *) return 3 ;;
  esac
}

# ── ¿el PR de esta rama ya se mergeó, y en qué commit? ────────────────
# La respuesta que `flow: prs` le debe a deploy-watch: con PRs, el sha que
# ship.sh verificó NO es el que aterriza (la cola de merge rebasea o hace
# squash). Vigilar el deploy del sha equivocado es peor que no vigilar.
#   stdout = sha del merge · exit 0 mergeado · 1 abierto/cerrado · 3 no pude ver
forge_pr_merged() {  # forge_pr_merged <dir> <rama>
  local d="$1" branch="$2" k slug out state sha
  k="$(forge_kind "$d")"; slug="$(forge_slug "$d")"
  case "$k" in
    github)
      command -v gh >/dev/null || return 3
      out="$(gh pr list --repo "$slug" --head "$branch" --state all \
        --json state,mergeCommit --jq '.[0] | "\(.state) \(.mergeCommit.oid // "")"' 2>/dev/null)" || return 3
      [ -n "$out" ] || return 3
      state="${out%% *}"; sha="${out##* }"
      [ "$state" = "MERGED" ] || return 1
      [ -n "$sha" ] || return 3
      printf '%s' "$sha" ;;
    gitlab)
      command -v glab >/dev/null || return 3
      out="$(glab mr view "$branch" --repo "$slug" 2>/dev/null)" || return 3
      printf '%s' "$out" | grep -qi 'merged' || return 1
      printf '%s' "$out" | sed -n 's/.*[Mm]erge commit:[[:space:]]*\([0-9a-f]\{7,\}\).*/\1/p' | head -1 ;;
    *) return 3 ;;
  esac
}

forge_pr_create() {  # forge_pr_create <dir> <rama> <título> <cuerpo>
  local d="$1" branch="$2" title="$3" body="$4" k slug base
  k="$(forge_kind "$d")"; slug="$(forge_slug "$d")"; base="$(forge_base_branch "$d")"
  case "$k" in
    github)
      command -v gh >/dev/null || return 3
      gh pr create --repo "$slug" --head "$branch" --base "$base" \
        --title "$title" --body "$body" ;;
    gitlab)
      command -v glab >/dev/null || return 3
      glab mr create --repo "$slug" --source-branch "$branch" --target-branch "$base" \
        --title "$title" --description "$body" --yes ;;
    *) _forge_missing "$k" "abrir un PR" ;;
  esac
}
