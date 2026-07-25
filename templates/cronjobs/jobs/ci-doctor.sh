# ci-doctor — triage de builds rojos. Ideal como trigger de workflow_run
# on failure; como cron (cada 30min) barre los runs fallidos recientes.
JOB_NAME=ci-doctor
JOB_TIER=medium
JOB_TOOLS="Read,Grep,Glob,Bash(gh *),Bash(git *),Edit,Write"

# "NO PUDE CONSULTAR" NO ES "CI LIMPIO". Este job solo sabe leer GitHub
# Actions, y el 2>/dev/null se tragaba todo: con un remote de GitLab,
# Bitbucket o Gitea (o con gh sin auth), el comando fallaba, la salida
# quedaba vacía, found seguía en 0 y el detector devolvía 0 = limpio.
# Resultado: CI rojo invisible, todas las noches, sin una sola pista.
#
# El soporte real de otros forges es otra cosa y está pendiente (regla 8 de
# CONTRIBUTING: un eje que varía se detecta y se despacha). Lo que se
# arregla acá es la mentira: lo que no se pudo mirar se dice.
detect() {
  command -v gh >/dev/null || return 3
  command -v jq >/dev/null || return 3
  local found=0 queried=0 blind=""
  while read -r repo; do
    [ -d "repos/$repo/.git" ] || continue
    local url; url="$(git -C "repos/$repo" remote get-url origin 2>/dev/null)"
    [ -n "$url" ] || { blind="$blind $repo(sin-remote)"; continue; }
    case "$url" in
      *github.com*) : ;;
      *) blind="$blind $repo(forge-no-github)"; continue ;;
    esac
    local slug; slug="$(printf '%s' "$url" | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
    [ -n "$slug" ] || { blind="$blind $repo(slug-ilegible)"; continue; }
    local out
    if ! out="$(gh run list --repo "$slug" --branch main --status failure \
      --created "$(date -u -v-2H +%Y-%m-%dT%H:%M 2>/dev/null || date -u -d '2 hours ago' +%Y-%m-%dT%H:%M)" \
      --json databaseId,displayTitle,workflowName --jq \
      '.[] | "'"$repo"' run=\(.databaseId) [\(.workflowName)] \(.displayTitle)"' 2>&1)"; then
      blind="$blind $repo(gh:$(printf '%s' "$out" | head -1 | cut -c1-30))"
      continue
    fi
    queried=$((queried+1))
    if [ -n "$out" ]; then printf '%s\n' "$out" >> "$FINDINGS"; found=1; fi
  done < <(ls repos/ 2>/dev/null)

  # Los ciegos se nombran SIEMPRE: así un "limpio" nunca se lee como "todo
  # limpio" cuando en realidad cubría solo una parte del workspace.
  [ -n "$blind" ] && log "⚠️ CI NO consultado en:$blind (este job solo lee GitHub Actions)"
  if [ "$queried" -eq 0 ]; then
    log "   no pude consultar el CI de NINGÚN repo: esto no es un verde"
    return 3
  fi
  [ "$found" -eq 1 ] && return 10 || return 0
}

JOB_PROMPT='Eres el ci-doctor del harness. Por cada run fallido de los
hallazgos: (1) lee el log de fallo con `gh run view <id> --repo <slug>
--log-failed` (vía scripts/quiet.sh si es largo) y EXTRAE TODAS las
causas de una vez (grep de FAIL/❌/error sobre el log completo): un run
rojo casi nunca tiene una sola, y arreglar de a una quema un ciclo de
CI por causa; (1b) OJO con el entorno: el runner es ubuntu (sh=dash,
/tmp plano, sin homebrew): un fix que solo probaste en tu entorno no
está probado; (2) clasifica: flaky
(re-lanza el run UNA vez y anota al flake-warden) · infra (OOM/timeout:
issue con diagnóstico) · rotura real (fix quirúrgico mínimo en rama
bot/, PR; si el fix no es obvio en 2 intentos, PR de REVERT del commit
culpable con el diagnóstico). Nunca desactives tests para poner el
build en verde.'
