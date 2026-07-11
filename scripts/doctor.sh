#!/usr/bin/env bash
# doctor.sh — Fase 4 y chequeo de salud continuo. Determinista, cero tokens.
# Todos los checks se DERIVAN de harness-answers.yaml (esquema fijo):
#   bin: <x>   → command -v <x>
#   mcp: <x>   → clave presente en .mcp.json
#   env://X    → variable presente en el entorno (warn)
# Cada fallo imprime su remediación exacta.
# Portabilidad: bash 3.2 (macOS), BSD grep. Requiere jq.
set -uo pipefail

WS="${1:-.}"; WS="$(cd "$WS" && pwd)"
ANSWERS="$WS/harness-answers.yaml"
FAIL=0; WARN=0

ok()   { echo "✅ $1"; }
warn() { echo "⚠️  $1"; WARN=$((WARN+1)); }
fail() { echo "❌ $1"; echo "   ↳ remediación: $2"; FAIL=$((FAIL+1)); }

echo "── doctor: $WS ──"

command -v jq >/dev/null || { fail "jq no instalado" "brew install jq | apt-get install -y jq"; echo "── resultado: $FAIL fallos ──"; exit 1; }

# 1 · Archivos núcleo
for f in CLAUDE.md manifest.yaml harness-answers.yaml .harness-version inventory.json; do
  [ -f "$WS/$f" ] && ok "$f presente" || fail "$f faltante" "corre /harness-init de nuevo"
done

# 1b · Coherencia manifest ↔ repos/ (fantasmas y faltantes)
if [ -f "$WS/manifest.yaml" ] && [ -d "$WS/repos" ]; then
  for name in $(grep -E '^[[:space:]]+- name:' "$WS/manifest.yaml" | awk '{print $3}'); do
    [ -d "$WS/repos/$name/.git" ] || warn "repo en manifest sin clon: $name — clónalo o quítalo del manifest/DAG"
  done
  for d in "$WS/repos"/*/; do
    [ -d "$d/.git" ] || continue
    name="$(basename "$d")"
    grep -qE "^[[:space:]]+- name: $name\$" "$WS/manifest.yaml" \
      || warn "clon sin registrar en manifest: repos/$name — regístralo o remuévelo (¿repo fantasma?)"
  done
fi

# 2 · Scripts de instancia ejecutables
for s in ship.sh worktree-task.sh; do
  if [ -f "$WS/scripts/$s" ]; then
    [ -x "$WS/scripts/$s" ] && ok "scripts/$s ejecutable" || fail "scripts/$s no ejecutable" "chmod +x scripts/$s"
    bash -n "$WS/scripts/$s" 2>/dev/null && ok "scripts/$s sintaxis válida" || fail "scripts/$s con error de sintaxis" "revisa el archivo (bash -n scripts/$s)"
  else
    fail "scripts/$s faltante" "corre /harness-init de nuevo"
  fi
done

# 3 · .mcp.json válido y coherente con answers
if [ -f "$WS/.mcp.json" ]; then
  if jq empty "$WS/.mcp.json" 2>/dev/null; then
    ok ".mcp.json JSON válido"
    if [ -f "$ANSWERS" ]; then
      for m in $(grep -E '^[[:space:]]+mcp:' "$ANSWERS" | awk '{print $2}' | sort -u); do
        jq -e --arg m "$m" '.mcpServers[$m]' "$WS/.mcp.json" >/dev/null 2>&1 \
          && ok "mcp configurado: $m" \
          || fail "mcp '$m' elegido pero ausente en .mcp.json" "agrega la entrada según catalog/capabilities.yaml o quítalo de harness-answers.yaml"
      done
    fi
  else
    fail ".mcp.json inválido" "revisa la sintaxis JSON"
  fi
fi

# 4 · Hook de protección de main registrado y ejecutable
if [ -f "$WS/.claude/settings.json" ]; then
  grep -q "block-direct-push" "$WS/.claude/settings.json" 2>/dev/null \
    && ok "hook block-direct-push registrado" \
    || warn "hook block-direct-push no registrado en .claude/settings.json — git push directo a main NO está bloqueado"
  if [ -f "$WS/.claude/hooks/block-direct-push.sh" ]; then
    [ -x "$WS/.claude/hooks/block-direct-push.sh" ] && ok "hook block-direct-push ejecutable" || fail "hook block-direct-push no ejecutable" "chmod +x .claude/hooks/block-direct-push.sh"
  fi
else
  warn ".claude/settings.json faltante — sin hooks de protección"
fi

# 5 · Links del CLAUDE.md resuelven
if [ -f "$WS/CLAUDE.md" ]; then
  broken=0
  while read -r p; do
    [ -e "$WS/$p" ] || { warn "link roto en CLAUDE.md: $p"; broken=$((broken+1)); }
  done < <(grep -oE '(docs|scripts|\.claude)/[A-Za-z0-9._/\-]+' "$WS/CLAUDE.md" | sort -u)
  [ "$broken" -eq 0 ] && ok "links del CLAUDE.md resuelven"
fi

# 6 · CLIs seleccionadas (bin: del answers). scope: cronjob degrada a
#     warning cuando falta — solo lo usa un detector de cronjob.
if [ -f "$ANSWERS" ]; then
  while read -r bin scope; do
    [ -n "$bin" ] || continue
    if command -v "$bin" >/dev/null; then
      ok "cli: $bin"
    elif [ "$scope" = "cronjob" ]; then
      warn "cli faltante: $bin (scope: cronjob — instálalo al activar su cronjob)"
    else
      fail "cli faltante: $bin" "corre scripts/bootstrap.sh (instala todo lo elegido) o ver install en catalog/capabilities.yaml"
    fi
  done < <(awk '
    /^  - name:/ { if (bin != "") print bin, scope; bin=""; scope="core" }
    /^    bin:/   { bin=$2 }
    /^    scope:/ { scope=$2 }
    END { if (bin != "") print bin, scope }
  ' "$ANSWERS" | sort -u)
else
  warn "sin harness-answers.yaml — no puedo verificar CLIs ni MCPs elegidos"
fi

# 7 · Secretos: flujo completo, nunca valores
if [ -f "$ANSWERS" ]; then
  # referencias env://: presencia de la variable
  for var in $(grep -oE 'env://[A-Za-z_][A-Za-z0-9_]*' "$ANSWERS" | sed 's|env://||' | sort -u); do
    [ -n "${!var:-}" ] && ok "secreto presente: \$$var" || warn "secreto no presente en entorno: \$$var"
  done
  # fuente vault/gcp-sm: bootstrap (token) y materialización (.secrets)
  src="$(grep -E '^[[:space:]]+source:' "$ANSWERS" | head -1 | awk '{print $2}')"
  if [ "$src" = "vault" ]; then
    [ -f "$HOME/.config/harness/vault-token" ] && ok "token de Vault presente (~/.config/harness/vault-token)" \
      || warn "sin token de Vault — colócalo TÚ (nunca por chat): guarda tu periodic token en ~/.config/harness/vault-token y chmod 600"
  fi
  if [ "$src" = "vault" ] || [ "$src" = "gcp-secret-manager" ]; then
    [ -f "$WS/.secrets" ] && ok ".secrets materializado" \
      || warn ".secrets no materializado — corre: scripts/secrets.sh pull (los MCPs autenticados y deploy-watch lo necesitan)"
  fi
fi

# 8 · Agentes y comandos de pipeline
agents=$(ls "$WS"/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$agents" -gt 0 ] && ok "$agents agentes en .claude/agents/" || fail "sin agentes en .claude/agents/" "corre /harness-init de nuevo"
for c in feature rfc implement review ship; do
  [ -f "$WS/.claude/commands/$c.md" ] && ok "comando /$c presente" || warn "comando /$c faltante — el pipeline documentado en CLAUDE.md no está completo"
done

# 9 · Constituciones DRAFT pendientes de ratificar
drafts=$(grep -l "status: DRAFT" "$WS"/.claude/agents/*.md "$WS"/docs/constitution.md "$WS"/specs/*/spec.md 2>/dev/null | wc -l | tr -d ' ')
[ "$drafts" -gt 0 ] && warn "$drafts documentos en DRAFT (constituciones/constitution/specs) — ratificar antes del primer RFC"

# 10 · Capa SDD y modelos
[ -f "$WS/docs/constitution.md" ] && ok "constitution.md presente" || warn "sin docs/constitution.md — los agentes no tienen tie-breaker"
[ -f "$WS/models.yaml" ] && ok "models.yaml presente" || warn "sin models.yaml — sin política de ruteo/escalación de modelos"
[ -d "$WS/specs" ] && ok "specs/ presente ($(ls "$WS/specs" 2>/dev/null | wc -l | tr -d ' ') capabilities)" || warn "sin specs/ — los abogados litigan sin documento citable"

# 11 · Cronjobs self-healing
if [ -d "$WS/scripts/cronjobs" ]; then
  [ -x "$WS/scripts/cronjobs/cron-runner.sh" ] && ok "cron-runner.sh ejecutable" || fail "cron-runner.sh no ejecutable" "chmod +x scripts/cronjobs/cron-runner.sh"
  njobs=$(ls "$WS/scripts/cronjobs/jobs/"*.sh 2>/dev/null | wc -l | tr -d ' ')
  [ "$njobs" -gt 0 ] && ok "$njobs cronjobs instalados" || warn "scripts/cronjobs sin jobs"
  # circuit breakers abiertos
  for f in "$WS"/.cache/cron/*.fails; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" -ge 3 ] && warn "circuit breaker ABIERTO: $(basename "$f" .fails) — revisar y borrar $f"
  done
fi

echo "── resultado: $FAIL fallos, $WARN advertencias ──"
[ "$FAIL" -eq 0 ]
