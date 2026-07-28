#!/usr/bin/env bash
# instance-ship.sh: la puerta a main del REPO DE LA INSTANCIA (el workspace).
#
# POR QUÉ EXISTE (issue #37): el repo de la instancia no tenía camino
# legítimo a main. block-direct-push bloquea el push (Ley 1) y ship.sh solo
# opera sobre repos/ de producto, así que cada /harness-update producía un
# commit que nadie podía pushear por la puerta: el humano terminaba pusheando
# a mano POR FUERA del harness, que es exactamente lo que la Ley 15 llama un
# bug del harness ("que no exista un camino legítimo significa que falta
# uno"). Esto NO es una excepción al hook: es una puerta con los gates que
# SÍ aplican a este repo. El hook no lo bloquea por la misma razón que no
# bloquea a ship.sh: el push vive DENTRO del script sancionado.
#
# Qué contiene el repo de la instancia: specs maestras, ADRs, constitución,
# scripts del harness, harness-answers (REFERENCIAS a secretos, jamás
# valores). No hay suite de producto que correr; los gates que importan son:
#   1. árbol limpio (lo mismo que exige la evidencia: no publicar a medias)
#   2. rebase sobre origin (la misma disciplina que ship.sh)
#   3. gitleaks sobre el rango a pushear (el riesgo número UNO acá: un
#      token o un .secrets colado a main en el repo que versiona la config)
#   4. doctor en verde (una instancia rota no se publica a sí misma)
#
# Uso: instance-ship.sh
# Portabilidad: bash 3.2, BSD userland.
set -euo pipefail

WS="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WS"

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "❌ el workspace no es un repo git (instance.repo: self sin git init)"
  echo "   ↳ remediación: git init + remote origin, o declara instance.repo en harness-answers.yaml"
  exit 2; }

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "ℹ️  el repo de la instancia no tiene remote origin: no hay dónde pushear."
  echo "   Si la instancia debe versionarse fuera de esta máquina:"
  echo "   git remote add origin <url de instance.repo en harness-answers.yaml>"
  exit 2
fi

BB="${HARNESS_BASE_BRANCH:-$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')}"
[ -n "$BB" ] || BB=main

# ── 1. Árbol limpio: no se publica a medias ───────────────────────────
dirty="$(git status --porcelain -uno 2>/dev/null || echo "?")"
if [ -n "$dirty" ]; then
  echo "❌ el repo de la instancia tiene cambios SIN COMMITEAR:"
  printf '%s\n' "$dirty" | head -5 | sed 's/^/   /'
  echo "   ↳ remediación: commitea primero (tasks/ y .harness/ van gitignorados;"
  echo "     si aparecen acá, el .gitignore de la instancia perdió sus entradas)"
  exit 3
fi

# ── lock: dos sesiones publicando la instancia no se pisan ────────────
LOCKDIR="$WS/locks/instance.lock.d"
mkdir -p "$WS/locks"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  lpid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; then
    echo "⚠️  lock huérfano (pid $lpid ya no existe); lo reclamo"
    rm -rf "$LOCKDIR"; mkdir "$LOCKDIR"
  else
    echo "❌ otra sesión${lpid:+ (pid $lpid)} está publicando la instancia; espera o revisa."
    echo "   Si estás SEGURO de que no queda ninguna viva: rm -rf $LOCKDIR"
    exit 6
  fi
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

# ── 2. Rebase sobre origin: misma disciplina que ship.sh ──────────────
git fetch origin
if ! rebase_out="$(git rebase "origin/$BB" 2>&1)"; then
  git rebase --abort >/dev/null 2>&1 || true
  echo "❌ no pude rebasear sobre origin/$BB:"
  printf '%s\n' "$rebase_out" | sed 's/^/   /'
  echo "   ↳ resuelve el conflicto en el workspace y re-corre instance-ship.sh"
  exit 4
fi

n="$(git rev-list --count "origin/$BB..HEAD" 2>/dev/null || echo 0)"
if [ "${n:-0}" -eq 0 ]; then
  echo "✅ nada que pushear: la instancia ya está al día con origin/$BB"
  exit 0
fi

# ── 3. gitleaks sobre el rango: EL gate de este repo ──────────────────
if command -v gitleaks >/dev/null; then
  echo "── gitleaks sobre origin/$BB..HEAD ──"
  gitleaks detect --no-banner --log-opts="origin/$BB..HEAD" || {
    echo "❌ gitleaks encontró secretos en lo que ibas a pushear. Este repo"
    echo "   versiona la CONFIG del harness: un token acá es el peor accidente."
    echo "   ↳ remediación: purga el secreto del historial (rebase -i / filtro),"
    echo "     muévelo a la fuente declarada (secrets.refs) y re-corre"
    exit 3; }
else
  echo "⚠️  gitleaks no está instalado: el rango se pushea SIN escanear secretos."
  echo "   Este es el repo donde un token colado duele más; instálalo (catálogo: gitleaks)."
  [ -f "$WS/scripts/emit.sh" ] && bash "$WS/scripts/emit.sh" assumption \
    "push de la instancia SIN escaneo de secretos: gitleaks no está instalado" \
    "" "" >/dev/null 2>&1 || true
fi

# ── 4. doctor en verde: una instancia rota no se publica ──────────────
if [ -x "$WS/scripts/doctor.sh" ]; then
  echo "── doctor (los FAIL bloquean; los warn no) ──"
  bash "$WS/scripts/doctor.sh" . >/dev/null 2>&1 || {
    echo "❌ el doctor reporta FALLOS: una instancia rota no se publica a sí misma."
    echo "   ↳ remediación: bash scripts/doctor.sh .  (el detalle con remediaciones)"
    exit 3; }
  echo "✅ doctor sin fallos"
fi

# ── push (vive DENTRO del script sancionado: el hook no aplica acá) ───
git push origin "HEAD:$BB"
echo "🟢 instancia publicada: $n commit(s) a origin/$BB"
[ -f "$WS/scripts/emit.sh" ] && bash "$WS/scripts/emit.sh" ship \
  "repo de la instancia publicado: $n commit(s) a origin/$BB" "" "" >/dev/null 2>&1 || true
exit 0
