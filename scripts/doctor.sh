#!/usr/bin/env bash
# doctor.sh — Fase 4 y chequeo de salud continuo. Determinista, cero tokens.
# Todos los checks se DERIVAN de harness-answers.yaml (esquema fijo):
#   bin: <x>   → command -v <x>
#   mcp: <x>   → clave presente en .mcp.json
#   env://X    → variable presente en el entorno (warn)
# Cada fallo imprime su remediación exacta.
# Portabilidad: bash 3.2 (macOS), BSD grep. Requiere jq.
set -uo pipefail

# ── DOS NATURALEZAS QUE NO SE PUEDEN CONTAR JUNTAS ────────────────────
# `--instance-only` corre los chequeos de salud de la INSTANCIA y baja a aviso
# los de provisión del HOST. Son cosas distintas y solo una debería frenar una
# publicación:
#
#   salud de la INSTANCIA   links de docs rotos, un hook sin cablear, una regla
#                           que apunta a un verificador inexistente, drift de
#                           templates. Publicar eso PROPAGA una instancia rota.
#   provisión del HOST      falta flutter, falta gcloud, falta terraform. Es
#                           ESTA máquina, no lo que se publica.
#
# Caso de campo (#185): un commit de documentos y el bump del harness quedó sin
# publicar porque al host le faltaban 16 CLIs, ninguno de los cuales ese commit
# ejecuta. Los dos SDK más pesados (flutter ~1GB, gcloud ~500MB) son además los
# más caros de instalar, así que el gate empujaba a provisionar media máquina
# para publicar un markdown, o a declarar un HARNESS_KNOWN_BUG que no era un bug
# del harness. El operador terminó haciendo lo segundo por falta de una tercera
# opción, que es la señal de que el gate medía lo que no le competía.
#
# Lo que NO se afloja: `make doctor` sigue corriendo todo y contando todo. Este
# modo solo cambia lo que el gate MIRA, y lo dice en su salida: un CLI ausente
# se sigue viendo, con su remediación, como aviso.
INSTANCE_ONLY=0
args=()
for a in "$@"; do
  case "$a" in
    --instance-only) INSTANCE_ONLY=1 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"

WS="${1:-.}"; WS="$(cd "$WS" && pwd)"
ANSWERS="$WS/harness-answers.yaml"
FAIL=0; WARN=0

ok()   { echo "✅ $1"; }
warn() { echo "⚠️  $1"; WARN=$((WARN+1)); }
fail() { echo "❌ $1"; echo "   ↳ remediación: $2"; FAIL=$((FAIL+1)); }
# Un fallo de PROVISIÓN DEL HOST: cuenta como fallo en el doctor completo y
# como aviso en `--instance-only`. Es una función y no un `if` suelto para que
# el día que aparezca el segundo chequeo de esta clase no haya que acordarse.
fail_host() {
  if [ "$INSTANCE_ONLY" -eq 1 ]; then
    warn "$1 (provisión del HOST: no bloquea la publicación de la instancia)"
    echo "   ↳ $2"
  else
    fail "$1" "$2"
  fi
}

echo "── doctor: $WS ──"

command -v jq >/dev/null || { fail "jq no instalado" "brew install jq | apt-get install -y jq"; echo "── resultado: $FAIL fallos ──"; exit 1; }

# 1 · Archivos núcleo
for f in CLAUDE.md manifest.yaml harness-answers.yaml .harness-version inventory.json; do
  [ -f "$WS/$f" ] && ok "$f presente" || fail "$f faltante" "corre /harness-init de nuevo"
done

# 1a · El rastro del generador. Sin esto la instancia es inauditable: el
# número de `.harness-version` lo escribe quien genera, y ya pasó que lo
# escribiera con la versión nueva habiendo generado desde templates viejos.
# El digest del set es lo único que compara CONTENIDO.
if [ -f "$WS/.harness-templates" ]; then
  # Misma normalizacion que harness-version.sh: el marcador vale con o sin el
  # prefijo `digest: `, y lo que no sea un sha256 es ILEGIBLE, no drift.
  _dg="$(sed -n 's/^[[:space:]]*\(digest:[[:space:]]*\)\{0,1\}\([0-9a-fA-F]\{64\}\).*$/\2/p' "$WS/.harness-templates" 2>/dev/null | head -1)"
  if [ -n "$_dg" ]; then ok ".harness-templates presente (set $(printf '%.12s' "$_dg"))"
  else fail ".harness-templates no contiene un digest legible (se esperan 64 hex, con o sin 'digest: ')" \
            "regenerá con /harness-init . o copiá el digest de templates/MANIFEST.sha256"; fi
else
  fail ".harness-templates faltante: no se puede saber con qué set de templates se generó esta instancia" \
       "regenera con /harness-init . : el generador que la creó no dejó rastro de su fuente, así que .harness-version no es confiable"
fi

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

# 1c · .gitignore: las tres trampas caras. graphify-out/ pesa cientos de MB
# (128 MB medidos con 28 repos) y el propio flujo invita al accidente
# (`git init` del workspace + `make graph` + `git add -A`); go.work lo genera
# gowork.sh con rutas absolutas de ESTA máquina; .secrets son valores. Issue #27.
if [ -f "$WS/.gitignore" ]; then
  grep -qxF ".secrets" "$WS/.gitignore" \
    || fail ".gitignore SIN .secrets" "agrégalo YA: un git add -A commitea valores de secretos"
  for e in "graphify-out/" "go.work"; do
    grep -qxF "$e" "$WS/.gitignore" \
      || warn ".gitignore sin '$e': es regenerable/por-máquina y no debe entrar a git; añádelo (o corre /harness-init . en modo update)"
  done
fi

# 1d · Repos ARCHIVADOS: la ley es ignorarlos siempre. El doctor no los
# descubre (eso cuesta red), pero sí vigila que la lista exista y esté fresca:
# un cache viejo hace que un repo archivado ayer siga entrando al grafo hoy.
if [ -d "$WS/repos" ]; then
  _arch="$WS/.cache/archived-repos.txt"
  if [ -f "$_arch" ]; then
    # Misma trampa que mató a harness-version.sh: `grep -c` imprime 0 y sale 1
    # cuando no encuentra nada, así que `|| echo 0` deja "0\n0". Acá no revienta
    # (el valor solo se interpola en un mensaje) pero el doctor diría "0\n0
    # archivados conocidos", y un observador que imprime basura deja de ser
    # creíble justo cuando hace falta creerle.
    _n="$(grep -c . "$_arch" 2>/dev/null || true)"
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    if [ -f "$WS/.cache/archived-repos.stamp" ] && [ -n "$(find "$WS/.cache/archived-repos.stamp" -mtime +7 2>/dev/null)" ]; then
      warn "la lista de repos archivados tiene más de 7 días ($_n archivados conocidos)"
      echo "   ↳ scripts/archived-repos.sh refresh — si un repo se archivó después, sigue entrando al grafo"
    else
      ok "repos archivados: $_n conocidos y la lista está fresca"
    fi
  else
    warn "sin lista de repos archivados: los archivados están entrando al grafo, a los briefs y a los pulls"
    echo "   ↳ scripts/archived-repos.sh refresh (la consulta al forge se cachea; no corre en caliente)"
  fi
fi

# 2 · Scripts de instancia ejecutables
for s in ship.sh worktree-task.sh quiet.sh with-secrets.sh emit.sh bounded.sh finding.sh          build-slot.sh gowork.sh py.sh fe.sh repo-brief.sh          stamp-models.sh graph-refresh.sh pull-all.sh skills-sync.sh          verdict-scaffold.sh minion-probe.sh pipeline-steps.sh plan-lint.sh          harness-bug.sh; do
  if [ -f "$WS/scripts/$s" ]; then
    [ -x "$WS/scripts/$s" ] && ok "scripts/$s ejecutable" || fail "scripts/$s no ejecutable" "chmod +x scripts/$s"
    bash -n "$WS/scripts/$s" 2>/dev/null && ok "scripts/$s sintaxis válida" || fail "scripts/$s con error de sintaxis" "revisa el archivo (bash -n scripts/$s)"
  else
    fail "scripts/$s faltante" "corre /harness-init de nuevo"
  fi
done

# Los scripts de PYTHON van aparte, y esta separación no es cosmética: la lista
# de arriba valida con `bash -n`, que sobre un .py falla SIEMPRE. Meter un
# script de Python ahí hace que el doctor lo reporte roto estando sano, que es
# la peor clase de observador: el que grita en verde. Se comprueba con el
# compilador de Python, que es el equivalente exacto.
for s in harness-policy.py evidence.py harness-metrics.py harness-cost.py task-note.py harness-sink.py; do
  if [ -f "$WS/scripts/$s" ]; then
    [ -x "$WS/scripts/$s" ] && ok "scripts/$s ejecutable" || fail "scripts/$s no ejecutable" "chmod +x scripts/$s"
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$WS/scripts/$s" 2>/dev/null \
      && ok "scripts/$s sintaxis válida" \
      || fail "scripts/$s con error de sintaxis" "revisa el archivo (python3 -m py_compile scripts/$s)"
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
else
  # Sin else, un .mcp.json ausente saltaba la verificación entera y el doctor
  # podía salir verde: los agentes arrancaban sin ninguno de los MCP elegidos
  # y nadie decía que el archivo faltaba.
  if grep -qE '^[[:space:]]*mcp:' "$ANSWERS" 2>/dev/null; then
    fail ".mcp.json FALTA pero harness-answers.yaml declara MCPs" \
      "re-corre /harness-init . (modo update) para regenerarlo"
  else
    ok "sin .mcp.json y sin MCPs declarados (coherente)"
  fi

# ── El tier degradado de un MCP tiene que ser real o declararse ────────
# answers puede decir tier: read-only, pero el .mcp.json se genera del campo
# `config` del catálogo y NADIE lee tier:. El humano cree que revocó
# escritura y el servidor sigue con capacidad completa. Es la única perilla
# muerta con perfil de seguridad, así que el doctor la nombra.
if [ -f "$ANSWERS" ]; then
  degraded="$(awk '/^capabilities:/{c=1;next} /^[a-z_]+:/{c=0}
    c && /^[[:space:]]*-[[:space:]]*name:/{n=$NF}
    c && /^[[:space:]]*mcp:/{ismcp=1}
    c && /^[[:space:]]*tier:[[:space:]]*read-only/{if(ismcp)print n; ismcp=0}
    c && /^[[:space:]]*-[[:space:]]*name:/{ismcp=0}' "$ANSWERS" 2>/dev/null | tr '\n' ' ')"
  if [ -n "$(printf '%s' "$degraded" | tr -d ' ')" ]; then
    warn "MCPs con tier read-only en answers:$degraded"
    echo "   ↳ el tier NO se aplica solo: .mcp.json se genera del catálogo y nadie"
    echo "     lee tier:. La restricción real es el ALCANCE DEL TOKEN que le pases."
    echo "     Verifica que ese token no tenga permisos de escritura, o quita la"
    echo "     capacidad. Registrar la preferencia no revoca nada."
  fi
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

# _bin_elsewhere <bin> → ruta donde SÍ está, si existe fuera de este PATH.
# Los sitios donde los gestores de la casa instalan: Homebrew (mac y linux),
# los binarios de usuario de uv/pipx, los de `go install`, y npm global.
_bin_elsewhere() {
  local b="$1" d
  for d in /home/linuxbrew/.linuxbrew/bin /opt/homebrew/bin /usr/local/bin \
           "$HOME/.linuxbrew/bin" "$HOME/.local/bin" "$HOME/go/bin" \
           "$HOME/.cargo/bin" "$HOME/.npm-global/bin" /snap/bin; do
    [ -x "$d/$b" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# 6 · CLIs seleccionadas (bin: del answers). scope: cronjob degrada a
#     warning cuando falta — solo lo usa un detector de cronjob.
if [ -f "$ANSWERS" ]; then
  while read -r bin scope; do
    [ -n "$bin" ] || continue
    if command -v "$bin" >/dev/null; then
      ok "cli: $bin"
    elif found_at="$(_bin_elsewhere "$bin")"; then
      # ── "NO ESTÁ EN MI PATH" NO ES "NO ESTÁ INSTALADO" ────────────────
      # Caso real, y costó un diagnóstico entero: una sesión no interactiva
      # (ssh host 'cmd', cron, un servicio) NO lee ~/.zshrc ni ~/.profile, así
      # que no ve Homebrew ni ~/.local/bin ni ~/go/bin. El doctor reportaba 22
      # CLIs faltantes sobre una máquina que las tenía TODAS instaladas, y de
      # ahí salió la conclusión de que faltaba la toolchain entera.
      #
      # Decir "falta" cuando el binario está a un PATH de distancia manda a
      # reinstalar lo que ya está, y de paso entrena a no creerle al doctor.
      # Es el mismo defecto que perseguimos en los gates, en el diagnóstico.
      warn "cli: $bin NO está en este PATH, pero SÍ está instalado en $found_at"
      echo "   ↳ NO lo reinstales: agregá ese directorio al PATH del entorno que corre"
      echo "     el harness. Si es Homebrew, 'brew shellenv' va en ~/.zshenv (que zsh lee"
      echo "     SIEMPRE), no solo en ~/.zshrc, que las sesiones no interactivas se saltan."
    elif [ "$scope" = "cronjob" ]; then
      warn "cli faltante: $bin (scope: cronjob — solo lo usa harness-cronjobs, repo aparte)"
    else
      fail_host "cli faltante: $bin" "corre scripts/bootstrap.sh (instala todo lo elegido) o ver install en catalog/capabilities.yaml"
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
  # referencias env://: presencia de la variable. Los COMENTARIOS no cuentan:
  # el grep sobre el archivo entero cazaba el ejemplo comentado del propio
  # template y todo workspace generado avisaba por una ref que nadie declaró
  # (issue #26). Se corta desde el # antes de buscar.
  for var in $(sed 's/#.*//' "$ANSWERS" | grep -oE 'env://[A-Za-z_][A-Za-z0-9_]*' | sed 's|env://||' | sort -u); do
    [ -n "${!var:-}" ] && ok "secreto presente: \$$var" || warn "secreto no presente en entorno: \$$var"
  done
  # fuente vault/gcp-sm: bootstrap (token) y materialización (.secrets)
  src="$(grep -E '^[[:space:]]+source:' "$ANSWERS" | head -1 | awk '{print $2}')"
  if [ "$src" = "vault" ]; then
    tokfile="$HOME/.config/harness/vault-token"
    if [ ! -f "$tokfile" ]; then
      warn "sin token de Vault — corre scripts/bootstrap.sh (te lo pide interactivo, fuera del chat)"
    else
      # VIGENCIA, no solo presencia: un token muerto es peor que ninguno
      # El esquema de answers NO tiene vault_addr (solo source y refs), así que
      # este grep salía SIEMPRE vacío y la validación de vigencia jamás corría:
      # el doctor decía "presente (sin validar)" y el token muerto aparecía a
      # mitad de pipeline, que es exactamente lo que promete evitar.
      # La dirección sí existe, renderizada, en el secrets.sh de la instancia.
      vaddr="${VAULT_ADDR:-}"
      [ -n "$vaddr" ] || vaddr="$(grep -E '^[[:space:]]*export VAULT_ADDR=' "$WS/scripts/secrets.sh" 2>/dev/null \
        | head -1 | sed -E 's/.*VAULT_ADDR="?([^"]*)"?.*/\1/')"
      if command -v vault >/dev/null && [ -n "$vaddr" ]; then
        if VAULT_ADDR="$vaddr" VAULT_TOKEN="$(cat "$tokfile")" vault token lookup >/dev/null 2>&1; then
          ok "token de Vault VÁLIDO"
        else
          warn "token de Vault presente pero EXPIRADO/sin permisos (o Vault inaccesible)"
          echo "   ↳ renovación: export VAULT_ADDR=$vaddr && vault login -method=<tu método>"
          echo "     luego: make init (te pide el token nuevo, lo valida y materializa .secrets)"
          echo "     detalle completo: README.md § Secretos"
        fi
      else
        ok "token de Vault presente (sin validar: falta vault CLI o vault_addr en answers)"
      fi
    fi
  fi
  if [ "$src" = "vault" ] || [ "$src" = "gcp-secret-manager" ]; then
    if [ ! -f "$WS/.secrets" ]; then
      warn ".secrets no materializado: corre scripts/secrets.sh pull (los MCPs autenticados y deploy-watch lo necesitan)"
    else
      # ── UN .secrets INCOMPLETO NO ES UN .secrets ─────────────────────
      # Esto miraba solo que el archivo EXISTIERA. Con una credencial vencida,
      # `secrets.sh pull` lo escribe igual, con las claves que SÍ pudo leer, así
      # que un archivo con 3 de las 18 declaradas daba verde. Y lo daba dos
      # líneas debajo del aviso de que el token estaba expirado: la misma
      # salida se contradecía, y el humano se queda con la línea verde.
      # Se cuenta contra lo que secrets.sh DECLARA, que es la única referencia
      # que existe de "completo".
      sec_falta=""; sec_total=0
      for k in $(grep -E '^[[:space:]]*dump_(kv|sm|file) ' "$WS/scripts/secrets.sh" 2>/dev/null | awk '{print $2}' | sort -u); do
        sec_total=$((sec_total+1))
        grep -q "^$k=" "$WS/.secrets" 2>/dev/null || sec_falta="$sec_falta $k"
      done
      if [ "$sec_total" -eq 0 ]; then
        ok ".secrets materializado"
      elif [ -z "$sec_falta" ]; then
        ok ".secrets materializado ($sec_total claves declaradas, todas presentes)"
      else
        sec_n=$(echo "$sec_falta" | wc -w | tr -d ' ')
        # Se nombran las primeras y se dice cuántas quedan, en vez de cortar la
        # lista por caracteres: una clave partida al medio no se puede buscar.
        sec_muestra=$(echo "$sec_falta" | tr ' ' '\n' | grep -v '^$' | head -4 | tr '\n' ' ' | sed 's/ *$//')
        [ "$sec_n" -gt 4 ] && sec_muestra="$sec_muestra y $((sec_n-4)) más"
        fail_host ".secrets INCOMPLETO: faltan $sec_n de $sec_total claves declaradas ($sec_muestra)" \
          "la credencial de la fuente no sirve o el layout cambió: corre 'bash scripts/secrets.sh pull' y mira qué clave falla"
      fi
    fi
  fi
fi

# 8 · Agentes y comandos de pipeline
agents=$(ls "$WS"/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$agents" -gt 0 ] && ok "$agents agentes en .claude/agents/" || fail "sin agentes en .claude/agents/" "corre /harness-init de nuevo"
for c in feature rfc implement review ship; do
  [ -f "$WS/.claude/commands/$c.md" ] && ok "comando /$c presente" || warn "comando /$c faltante — el pipeline documentado en CLAUDE.md no está completo"
done
# El pipeline autónomo se llama /smart: /auto chocaba con el comando homónimo de
# otros agentes (Kimi Code). Una instancia que solo tiene auto.md se quedó en el
# nombre viejo, y decirle "falta el comando" mandaría a reinstalar lo que sí
# está: lo que le falta es el update.
if [ -f "$WS/.claude/commands/smart.md" ]; then
  ok "comando /smart presente (pipeline autónomo: ticket o prompt → prod)"
elif [ -f "$WS/.claude/commands/auto.md" ]; then
  warn "solo está el /auto viejo: el pipeline se renombró a /smart (el nombre chocaba con otros agentes); corre /harness-init . (modo update)"
else
  warn "comando /smart faltante: sin él no hay pipeline sin intervención; corre /harness-init . (modo update)"
fi

# 8a-bis · El bus del harness
if [ -f "$WS/scripts/emit.sh" ]; then
  ok "scripts/emit.sh presente (el bus: gates, fases, supuestos, paradas)"
  grep -q "emit.sh" "$WS/scripts/ship.sh" 2>/dev/null \
    || warn "ship.sh no sourcea emit.sh — los gates no se cuentan y el panel no puede enseñar cuándo el harness frenó a su propio agente"
else
  warn "falta scripts/emit.sh — el panel solo verá agentes y tokens (lo que presta Claude Code), nunca tus decisiones ni tus gates; corre /harness-init . (modo update)"
fi

# 8a-ter · El canal de vuelta al plugin (ley 12): un bug del harness que muere
# en la máquina de un usuario se lo come el siguiente usuario igual. El script
# es el filtro determinista (propiedad, drift, versión, dedupe, cuota,
# redacción); la skill es el juicio. Sin gh, el canal no publica.
upstream_mode="auto"
[ -f "$ANSWERS" ] && upstream_mode="$(grep -E '^upstream_issues:' "$ANSWERS" | head -1 | awk '{print $2}')"
[ -n "$upstream_mode" ] || upstream_mode="auto"
if [ "$upstream_mode" = "off" ]; then
  ok "reportes upstream deshabilitados por decisión de la instancia (upstream_issues: off)"
else
  if [ -f "$WS/.claude/skills/harness-bug-report/SKILL.md" ]; then
    ok "skill harness-bug-report presente (verifica antes de reportar)"
  else
    warn "falta .claude/skills/harness-bug-report/SKILL.md: sin ella los agentes reportan sin verificar (o no reportan); corre /harness-init . (modo update)"
  fi
  command -v gh >/dev/null 2>&1 \
    || warn "gh ausente, harness-bug.sh no puede abrir el issue upstream; el reporte queda solo en --dry-run"
  if [ -f "$WS/.harness/upstream-issues.jsonl" ]; then
    nrep=$(wc -l < "$WS/.harness/upstream-issues.jsonl" | tr -d ' ')
    ok "$nrep reporte(s) upstream desde esta instancia (scripts/harness-bug.sh list)"
  fi
fi

# 8b · Presupuesto de contexto SIEMPRE inyectado.
# CLAUDE.md + constitution.md entran en CADA agente, en CADA turno, para siempre.
# Nadie los borra y cada versión les suma una lección. El límite no es el tamaño
# de la ventana: es el "context rot" — la atención se degrada mucho antes de
# llenarla, y un mapa de 3k líneas se ignora entero. Un techo medido es la
# diferencia entre una ley que se lee y una que se saltan.
ctx_words=0
for f in "$WS/CLAUDE.md" "$WS/docs/constitution.md"; do
  [ -f "$f" ] && ctx_words=$((ctx_words + $(wc -w < "$f" | tr -d ' ')))
done
# ~1.3 tokens por palabra (aprox. honesta; la cuenta exacta la da count_tokens)
ctx_tokens=$((ctx_words * 13 / 10))
if [ "$ctx_tokens" -gt 3000 ]; then
  fail "el mapa siempre-inyectado ≈ ${ctx_tokens} tokens (CLAUDE.md + constitution.md)" \
       "PASA de 3000. Es un MAPA, no un manual: mueve el detalle a docs/ o a una skill y deja punteros. Un CLAUDE.md inflado hace que los agentes ignoren las instrucciones que sí importan."
elif [ "$ctx_tokens" -gt 1500 ]; then
  warn "el mapa siempre-inyectado ≈ ${ctx_tokens} tokens (CLAUDE.md + constitution.md) — vigila el techo (falla a 3000). Prueba: ¿quitar esta línea haría que un agente se equivoque? Si no, fuera."
else
  ok "el mapa siempre-inyectado ≈ ${ctx_tokens} tokens (CLAUDE.md + constitution.md, bajo el techo de 1500)"
fi

# 8b-bis · El mapa NO era lo único siempre inyectado, y este bloque lo decía
# igual (issue #206): una instancia con 3 reglas custom reportaba 2999 tokens
# contra su techo de fallo de 3000, con 4202 tokens más entrando por un camino
# que nadie contaba. Claude Code carga `.claude/rules/*.md` NATIVAMENTE, y el
# cuerpo entero, salvo que la regla declare `paths:` (ver docs/harness/rules.md).
# El mapa tiene techo desde el día uno; las reglas que el propio harness genera
# con /custom-build-rule no tenían ninguno.
rules_words=0; rules_n=0; rules_lazy=0
for rl in "$WS"/.claude/rules/*.md; do
  [ -f "$rl" ] || continue
  [ "$(basename "$rl")" = "README.md" ] && continue
  rules_n=$((rules_n + 1))
  # `paths:` en el frontmatter difiere la carga: cuerpo bajo demanda, solo el
  # frontmatter arriba. Esa regla no pesa en el arranque, así que no se cuenta.
  if head -20 "$rl" | grep -q '^paths:'; then rules_lazy=$((rules_lazy + 1)); continue; fi
  rules_words=$((rules_words + $(wc -w < "$rl" | tr -d ' ')))
done
rules_tokens=$((rules_words * 13 / 10))
rules_det=""
[ "$rules_lazy" -gt 0 ] && rules_det=" · ${rules_lazy}/${rules_n} con paths:, o sea bajo demanda"
if [ "$rules_tokens" -gt 5000 ]; then
  fail "reglas custom siempre-inyectadas ≈ ${rules_tokens} tokens (.claude/rules/${rules_det})" \
       "PASA de 5000. Claude Code inyecta cada regla ENTERA en cada sesión: adelgázala con /custom-edit-rule (la evidencia larga va a docs/), fusiona reglas que se pisan, o dale 'paths:' en el frontmatter para que su cuerpo cargue solo cuando se toca lo que gobierna."
elif [ "$rules_tokens" -gt 2500 ]; then
  warn "reglas custom siempre-inyectadas ≈ ${rules_tokens} tokens, vigila el techo (falla a 5000)${rules_det}. Una regla que aplica a UN repo no tiene por qué pesar en las sesiones de los otros: eso lo resuelve 'paths:'."
elif [ "$rules_n" -gt 0 ]; then
  ok "reglas custom siempre-inyectadas ≈ ${rules_tokens} tokens en ${rules_n} regla(s) (bajo el techo de 2500${rules_det})"
fi

# 8b-ter · El total, y por qué es una COTA INFERIOR y no una medición.
# También entran siempre: las descripciones de agentes, skills y comandos (de
# ellos, eso es lo único que se inyecta; el cuerpo carga bajo demanda) y lo que
# imprimen los hooks SessionStart. Lo que este doctor NO puede contar, porque no
# vive en archivos del workspace: definiciones de tools, esquemas de los MCP y
# el system prompt de la plataforma. Por eso el total AVISA y nunca falla: un
# rojo permanente que nadie puede bajar es un check que se aprende a ignorar.
desc_words=$({ grep -h '^description:' "$WS"/.claude/agents/*.md "$WS"/.claude/commands/*.md \
                 "$WS"/.claude/skills/*/SKILL.md 2>/dev/null || true; } | wc -w | tr -d ' ')
hook_words=0
if [ -f "$WS/.claude/settings.json" ] && [ "${HARNESS_DOCTOR_SKIP_HOOKS:-0}" != "1" ]; then
  # Son idempotentes por diseño (corren en cada arranque de sesión) y fail-open:
  # correrlos una vez más cuesta lo mismo que abrir una sesión. HARNESS_DOCTOR_SKIP_HOOKS=1
  # los saltea si una instancia mete uno lento o con efecto.
  while IFS= read -r hcmd; do
    [ -n "$hcmd" ] || continue
    hpath="$WS/${hcmd#\$CLAUDE_PROJECT_DIR/}"
    case "$hpath" in "$WS"/*) ;; *) continue ;; esac   # nada de fuera del workspace
    [ -x "$hpath" ] || continue
    hook_words=$((hook_words + $(CLAUDE_PROJECT_DIR="$WS" "$hpath" </dev/null 2>/dev/null | wc -w | tr -d ' ')))
  done <<EOF
$(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty' "$WS/.claude/settings.json" 2>/dev/null | awk '{print $1}')
EOF
fi
extra_tokens=$(((desc_words + hook_words) * 13 / 10))
total_tokens=$((ctx_tokens + rules_tokens + extra_tokens))
total_det="mapa ${ctx_tokens} + reglas ${rules_tokens} + descripciones/SessionStart ${extra_tokens}"
if [ "$total_tokens" -gt 12000 ]; then
  warn "contexto total siempre-inyectado ≈ ${total_tokens} tokens (${total_det}), y es una COTA INFERIOR: tools, esquemas MCP y system prompt suman encima y no se pueden contar desde acá. Mídelo de verdad comparando el primer turno dentro y fuera del workspace."
else
  ok "contexto total siempre-inyectado ≈ ${total_tokens} tokens (${total_det}; cota inferior)"
fi

# 8c · La UI (observa local; opera solo creando trabajo — ADR-0010)
if [ -f "$WS/scripts/ui/server.py" ]; then
  ok "panel local presente (make ui)"
  grep -q "ui-emit.sh" "$WS/.claude/settings.json" 2>/dev/null \
    || warn "ui-emit.sh no está registrado en .claude/settings.json — el panel vivirá de tasks/ y transcripts, sin el bus de eventos del harness"
  grep -q "track-read.sh" "$WS/.claude/settings.json" 2>/dev/null \
    || warn "track-read.sh no está registrado — sin él, ship.sh no puede verificar la evidencia de la compliance matrix (gate_evidence queda ciego)"
  command -v claude >/dev/null 2>&1 \
    || warn "el CLI 'claude' no está en PATH — el plano de OPERAR del panel (Nueva tarea, responder a un agente) lanza 'claude -p' headless y sin él esos botones devolverán error (observar sigue funcionando)"
fi

# 8c-bis · La memoria que nadie lee (issue #101). La regla 1 del repo exige la
# cadena COMPLETA para toda herramienta que un prompt cite: quién la instala,
# quién la alimenta, quién la vigila y quién la EJECUTA. engram tenía instalador
# (catálogo) y alimentador (mem_save), y le faltaban los dos últimos: se
# acumulaban observaciones que ningún agente consultaba. El ejecutor es
# mem-recall.sh; el vigilante es esto.
if [ -f "$WS/.mcp.json" ] && grep -q '"engram"' "$WS/.mcp.json" 2>/dev/null; then
  if grep -q "mem-recall.sh" "$WS/.claude/settings.json" 2>/dev/null; then
    ok "engram con su lector cableado (mem-recall.sh en SessionStart)"
  else
    warn "engram está en .mcp.json pero mem-recall.sh NO está registrado en .claude/settings.json: la memoria se escribe y no la lee nadie; re-corré /harness-init . para cablearlo"
  fi
fi

# 8c-ter · Serena con los ojos tapados (issue #214). La misma regla 1, con la
# herramienta que más tokens ahorra: la INSTALA el catálogo, la CITA CLAUDE.md,
# EMPUJA hacia ella guard-symbol-grep... y lo único que se verificaba era que
# estuviera declarada en .mcp.json. Verde mientras `get_symbols_overview`
# fallaba sobre el 100% del código: `repos/` está gitignoreado a propósito y el
# default de Serena es ignorar todo lo gitignoreado.
#
# El agente obediente chocaba contra la pared y volvía al Read del archivo
# entero (46.450 tokens medidos en UNO), que es exactamente el gasto que el
# hook existe para evitar.
if [ -f "$WS/.mcp.json" ] && grep -q '"serena"' "$WS/.mcp.json" 2>/dev/null; then
  sp="$WS/.serena/project.yml"
  if [ ! -f "$sp" ]; then
    warn "serena está en .mcp.json pero NO hay .serena/project.yml: la crea sola y autodetecta el lenguaje desde la raíz del workspace (que solo tiene .sh), y con repos/ gitignoreado no ve una línea del código; regenerá con \${CLAUDE_PLUGIN_ROOT}/scripts/discover.sh $WS"
  elif grep -qE '^ignore_all_files_in_gitignore: *true' "$sp"; then
    warn ".serena/project.yml tiene ignore_all_files_in_gitignore: true: con repos/ en el .gitignore eso deja a serena CIEGA sobre todo el código; ponelo en false o regenerá con \${CLAUDE_PLUGIN_ROOT}/scripts/discover.sh $WS"
  else
    ok "serena ve el código: project.yml con $(sed -n 's/^language_servers: *//p' "$sp" | head -1)"
  fi
  # Los binarios que el propio archivo declara necesitar. No hay tabla acá a
  # propósito: el generador escribe lo que asumió y esto verifica la asunción,
  # así que la lista no se puede divergir en dos lugares.
  if [ -f "$sp" ]; then
    for b in $(sed -n 's/^# harness-requiere: *//p' "$sp" | head -1); do
      command -v "$b" >/dev/null 2>&1 \
        || warn "serena declara un language server que necesita \`$b\` en el PATH y no está: UN server que no arranca BLOQUEA la inicialización de TODOS (falla hasta el .py), así que instalalo o regenerá el project.yml con discover.sh"
    done
    grep -q '^# OMITIDOS' "$sp" \
      && warn "serena tiene language servers OMITIDOS por falta de binario (los lista .serena/project.yml): esos lenguajes no responden a las tools simbólicas y sus archivos caen a Read entero"
  fi
fi

# 8d · Bits de ejecución: un hook sin +x falla EN SILENCIO (Claude Code no
# puede ejecutarlo y nadie te lo dice). La suite del instalador cachó seis
# templates así; aquí vigilamos la instancia instalada.
for f in "$WS"/scripts/*.sh "$WS"/.claude/hooks/*.sh; do
  [ -f "$f" ] || continue
  [ -x "$f" ] || warn "$(basename "$f") no es ejecutable — chmod +x ${f#"$WS"/} (un hook sin +x observa nada y un script sin +x muere en el primer uso)"
done

# 9 · Constituciones DRAFT pendientes de ratificar
drafts=$(grep -l "status: DRAFT" "$WS"/.claude/agents/*.md "$WS"/docs/constitution.md "$WS"/specs/*/spec.md 2>/dev/null | wc -l | tr -d ' ')
[ "$drafts" -gt 0 ] && warn "$drafts documentos en DRAFT (constituciones/constitution/specs) — ratificar antes del primer RFC"

# (La validación de los scripts de Python vive con los demás scripts, en §2.
# Estaba acá y solo cubría harness-policy.py y evidence.py: harness-metrics,
# harness-cost y task-note quedaban sin verificar, y además el chequeo de
# ejecutable estaba en otra lista. Un doctor con dos listas de scripts es un
# doctor que va a olvidarse de una.)

# Frescura de clones: explorar un clon podrido fue el error más caro medido
# en campo (27 commits atrás = inventarios de endpoints inexistentes).
if [ -d "$WS/repos" ]; then
  old_fetch=0; total_r=0
  now_s=$(date +%s)
  for r in "$WS"/repos/*/; do
    [ -d "$r/.git" ] || continue
    total_r=$((total_r+1))
    fh="$r/.git/FETCH_HEAD"
    # stat: GNU (-c %Y) PRIMERO; en BSD falla y cae a -f %m. Al revés NO:
    # en GNU, -f %m "funciona" (imprime el mount point) y rompe la aritmética.
    fetch_s="$(stat -c %Y "$fh" 2>/dev/null || stat -f %m "$fh" 2>/dev/null || echo 0)"
    case "$fetch_s" in *[!0-9]*) fetch_s=0 ;; esac
    if [ ! -f "$fh" ] || [ $(( now_s - fetch_s )) -gt 172800 ]; then
      old_fetch=$((old_fetch+1))
    fi
  done
  if [ "$total_r" -gt 0 ] && [ $((old_fetch * 2)) -gt "$total_r" ]; then
    warn "clones posiblemente podridos: $old_fetch/$total_r sin fetch en 48h — corre make pull antes de explorar"
  fi

  # ── LA OTRA FORMA DEL CLON PODRIDO: NO ES LA TRUNK (#77) ────────────
  # El de arriba mide si el clon se fetcheó; este mide si lo que se LEE es la
  # trunk. Un canónico con una rama de tarea checkeada tiene el fetch fresco y
  # la ref de la trunk al día, así que pasa el chequeo anterior, y el árbol
  # igual devuelve código de hace cientos de commits.
  #
  # Caso de campo: design-system en task/workspace-x1n, 149 commits atrás, el
  # único de 31 repos en ese estado y justo el que había que auditar. Se
  # eligieron 10 defectos leyendo ese árbol; 4 ya estaban arreglados en main.
  # Duele especialmente porque leer repos/<repo> es la ruta que el CLAUDE.md
  # RECOMIENDA para orientarse: el camino barato devolvía una respuesta falsa.
  #
  # Se nombra repo por repo (no agregado como el de FETCH_HEAD) porque serán
  # cero o dos casos y el nombre es la parte útil. Sin red: el doctor es
  # determinista, así que la distancia va contra el origin/<trunk> LOCAL y
  # puede quedar corta; para un warn alcanza, y el número no se promete exacto.
  for r in "$WS"/repos/*/; do
    [ -d "$r/.git" ] || continue
    rn="$(basename "$r")"
    rb="$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null || true)"
    rt="$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    [ -n "$rt" ] || continue          # sin origin/HEAD no hay contra qué comparar
    [ "$rb" = "$rt" ] && continue
    rd="$(git -C "$r" rev-list --count "HEAD..origin/$rt" 2>/dev/null || echo '?')"
    warn "repos/$rn tiene checkeada ${rb:-un HEAD desacoplado}, no $rt ($rd commits atrás de origin/$rt): lo que leas ahí NO es $rt"
    echo "   ↳ cuando la rama ya no haga falta: git -C repos/$rn checkout $rt && make pull"
    echo "     (no se toca sola: esa rama puede tener commits sin publicar)"
  done
fi

# · Port-forwards declarados: el bloque necesita su consumidor y su esquema.
# La sonda de identidad en vivo es asunto de `make forwards-status` (red);
# acá solo lo determinista: que lo declarado tenga con qué correrse.
if [ -f "$ANSWERS" ] && sed 's/#.*//' "$ANSWERS" | awk '/^port_forwards:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/^[[:space:]][[:space:]][a-zA-Z0-9_-]+:/{found=1} END{exit !found}'; then
  if [ -x "$WS/scripts/port-forwards.sh" ]; then
    if out="$(bash "$WS/scripts/port-forwards.sh" doctor 2>&1)"; then
      ok "port-forwards: declaraciones completas"
    else
      warn "port-forwards declarados con huecos: $(printf '%s' "$out" | grep '❌' | head -2 | tr '\n' ' ') (corrige el bloque port_forwards de harness-answers.yaml)"
    fi
  else
    fail "port_forwards declarado pero scripts/port-forwards.sh no existe o no es ejecutable" \
         "corre el update de la instancia (harness update o /harness-init .)"
  fi
fi

# · Eje deploy: un repo que SÍ deploya con driver=none es un hueco silencioso.
# Caso de campo: deploy-watch dijo "driver: none, NO reviso nada" en repos que
# sí deployan, y la única vez que importó (un apply de infra rojo) el watcher
# se declaró incompetente y hubo que verificar a mano con gh run view. La
# precedencia acá es la MISMA que deploy-watch.sh: deploy.<repo>.driver en
# answers > kind del manifest (service/frontend/mobile → gitops; resto → none),
# y `none` con verify_cmd o smoke cuenta como verificado, porque eso es lo que
# deploy-watch hace de verdad. La evidencia de que un repo deploya también es la
# misma: un workflow de deploy, o un atlantis.yaml (que aplica al mergear).
if [ -f "$WS/manifest.yaml" ] && [ -d "$WS/repos" ]; then
  for name in $(grep -E '^[[:space:]]+- name:' "$WS/manifest.yaml" | awk '{print $3}'); do
    has_deploy=""
    # Atlantis aplica al MERGEAR, por un comentario en el PR, sin workflow: si
    # solo se miran .github/workflows, esos repos contestan "no deployo" y el
    # gate se los salta enteros. Es la misma clase de hueco que el gate existe
    # para cerrar, un piso más abajo. Medido en un workspace real: de 17 repos
    # con atlantis.yaml, 5 no tenían NINGÚN workflow que este gate reconociera.
    { [ -f "$WS/repos/$name/atlantis.yaml" ] || [ -f "$WS/repos/$name/atlantis.yml" ]; } && has_deploy=atlantis
    wfdir="$WS/repos/$name/.github/workflows"
    if [ -z "$has_deploy" ]; then
      [ -d "$wfdir" ] || continue
      for wf in "$wfdir"/*.yml "$wfdir"/*.yaml; do
        [ -f "$wf" ] || continue
        case "$(basename "$wf")" in
          *deploy*|*release*|*apply*|*publish*) has_deploy=1; break ;;
        esac
        grep -qiE '(terraform[[:space:]]+apply|kubectl[[:space:]]+apply|helm[[:space:]]+(upgrade|install)|docker[[:space:]]+push|npm[[:space:]]+publish|deploy)' "$wf" 2>/dev/null \
          && { has_deploy=1; break; }
      done
    fi
    [ -n "$has_deploy" ] || continue
    drv="$(awk -v r="$name" '
      /^[[:space:]]*#/ { next }
      /^deploy:/ { ind=1; next }
      ind && /^[^[:space:]]/ { ind=0 }
      ind && $0 ~ "^[[:space:]]+" r ":" { cur=1; next }
      ind && cur && /^[[:space:]]+driver:[[:space:]]*/ {
        d=$0; sub(/^[^:]*:[[:space:]]*/,"",d); gsub(/["\047]/,"",d)
        sub(/[[:space:]]+$/,"",d); print d; exit }
      ind && cur && /^[[:space:]][[:space:]][a-zA-Z0-9_-]+:/ { cur=0 }
    ' "$ANSWERS" 2>/dev/null)"
    if [ -z "$drv" ]; then
      kind="$(awk -v r="$name" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
          n=$0; sub(/^[^:]*:[[:space:]]*/,"",n); gsub(/["\047]/,"",n)
          sub(/[[:space:]]+$/,"",n); cur=(n==r)
        }
        cur && /^[[:space:]]*kind:[[:space:]]*/ {
          k=$0; sub(/^[^:]*:[[:space:]]*/,"",k); gsub(/["\047]/,"",k)
          sub(/[[:space:]]+$/,"",k); print k; exit
        }' "$WS/manifest.yaml" 2>/dev/null)"
      case "${kind:-}" in service|frontend|mobile|"") drv=gitops ;; *) drv=none ;; esac
    fi
    if [ "$drv" = "none" ]; then
      # deploy-watch.sh trata `none` + verify_cmd (o un smoke ejecutable) como
      # VERIFICADO: salta las etapas de CI/gitops pero corre el verify. Es la
      # config correcta para un repo que aplica por Atlantis, donde no hay run
      # de Actions que mirar y la única verdad es interrogar al recurso. Si el
      # doctor solo leyera `driver`, avisaría para siempre sobre una instancia
      # bien configurada, y un aviso que no se puede apagar se aprende a
      # ignorar justo el día que señala algo real.
      vcmd="$(awk -v r="$name" '
        /^[[:space:]]*#/ { next }
        /^deploy:/ { ind=1; next }
        ind && /^[^[:space:]]/ { ind=0 }
        ind && $0 ~ "^[[:space:]]+" r ":" { cur=1; next }
        ind && cur && /^[[:space:]]+verify_cmd:[[:space:]]*/ { print "si"; exit }
        ind && cur && /^[[:space:]][[:space:]][a-zA-Z0-9_-]+:/ { cur=0 }
      ' "$ANSWERS" 2>/dev/null)"
      if [ -n "$vcmd" ] || [ -x "$WS/scripts/smoke/$name.sh" ]; then
        ok "deploy de $name verificable (driver: none + verify)"
        continue
      fi
      case "$has_deploy" in
        atlantis) via="aplica infra con Atlantis (atlantis.yaml)" ;;
        *)        via="tiene workflows de deploy" ;;
      esac
      warn "repos/$name $via y su driver resuelve a none sin verify: deploy-watch NO lo va a verificar tras el ship; declara deploy.$name.driver (gitops|actions) o deploy.$name.verify_cmd en harness-answers.yaml"
    else
      ok "deploy de $name verificable (driver: $drv)"
    fi
  done
fi

# 10 · Capa SDD y modelos
[ -f "$WS/docs/constitution.md" ] && ok "constitution.md presente" || warn "sin docs/constitution.md — los agentes no tienen tie-breaker"
[ -f "$WS/models.yaml" ] && ok "models.yaml presente" || warn "sin models.yaml — sin política de ruteo/escalación de modelos"
if [ -x "$WS/scripts/stamp-models.sh" ] && [ -f "$WS/models.yaml" ]; then
  if bash "$WS/scripts/stamp-models.sh" check >/dev/null 2>&1; then
    ok "agentes alineados con models.yaml (provider + aliases)"
  else
    fail "frontmatter de agentes desalineado con models.yaml" "make models (re-estampa desde la política)"
  fi
fi
if [ -f "$WS/skills.yaml" ] && [ -x "$WS/scripts/skills-sync.sh" ]; then
  if bash "$WS/scripts/skills-sync.sh" --check >/dev/null 2>&1; then
    ok "capa compartida de skills en sync (skills.yaml)"
  else
    warn "skills compartidas con drift o fuente inaccesible; corre: make skills"
  fi
fi
[ -f "$WS/AGENTS.md" ] && ok "AGENTS.md presente (mapa multi-herramienta)" || warn "sin AGENTS.md — Cursor/Kimi/otros agentes no tienen punto de entrada"

# 10a · Los dos mapas de leyes hablan de LAS MISMAS leyes.
# CLAUDE.md y AGENTS.md comparten numeracion, y los playbooks citan "Ley N" por
# numero. Una instancia vieja que actualiza puede quedarse con las dos
# numeraciones conviviendo: entonces "Ley 6" resuelve a leyes DISTINTAS segun
# por que mapa entre el agente, que es la ambiguedad que ya costo horas. Ese
# merge lo ejecuta un LLM leyendo prosa, y la prosa no frena a nadie: el diente
# tiene que estar aca, en la instancia. Misma mecanica que tests/test_docs.sh
# (que solo corre en el repo del plugin): el titulo llega al ULTIMO "**";
# partido en dos lineas o con negrita adentro NO es titulo; los titulos se
# comparan por prefijo y el comun tiene que cubrir al menos LEY_MIN_PCT del
# canon, porque 8 caracteres identifican "Presupues" y en un titulo de 50 no
# identifican nada.
LEY_MIN_PCT=60
# LA VENTANA: SOLO la seccion de leyes, jamas el archivo entero (issues #41,#59).
# Caso de campo: `bd setup codex` (beads, la herramienta de tracking que este
# mismo mapa manda usar) inyecta en AGENTS.md un "Session Close Protocol" que es
# una lista 1..5 en negrita. Escaneando el archivo entero, esos items entraban
# como leyes y el doctor gritaba "numera DOS veces la(s) ley(es): 1 2 3 4 5"
# sobre un AGENTS.md correcto: rojo PERMANENTE (y un rojo cronico deja de
# leerse), con una remediacion que ademas invita a REGENERAR AGENTS.md, que es
# la accion que /harness-update documenta como la que borro 70 lineas de una
# instancia real. Un gate que empuja al incidente que el comando de al lado
# documenta es peor que no tener gate.
#
# EL DELIMITADOR, y por que este:
#  · ABRE en el primer encabezado que menciona "ley" (cualquier nivel, sin
#    importar mayusculas). Tiene que servir para los DOS mapas, y no dicen lo
#    mismo: CLAUDE.md abre con "## Leyes globales (no negociables...)" y
#    AGENTS.md con "## Las leyes (validas para TODA herramienta)". Casar la
#    palabra, no el titulo literal, es lo unico que cubre a los dos y sobrevive
#    a que alguien le cambie el parentesis.
#  · CIERRA en el encabezado SIGUIENTE, sea cual sea. Anclarlo a "## El
#    pipeline" (como hace el repro del issue) ata el chequeo al nombre de una
#    seccion que no es la suya: el dia que alguien la renombra, la ventana se
#    come el resto del archivo y el bug vuelve, callado.
#  · SIN encabezado de leyes se cae al archivo ENTERO, que es el comportamiento
#    de siempre. Un mapa con las leyes bajo otro nombre no puede quedar mudo:
#    devolver vacio ahi convertiria este arreglo en "no miro nada".
_ley_seccion() {  # _ley_seccion <archivo> → SOLO el bloque de leyes
  # el awk sale != 0 cuando NUNCA encontro el encabezado de leyes; ahi, y solo
  # ahi, el fallback imprime el archivo entero (comportamiento historico)
  awk '
    /^#+[ \t]/ {
      if (dentro) exit
      if (tolower($0) ~ /ley/) dentro = 1
      next
    }
    dentro { print }
    END { if (!dentro) exit 9 }
  ' "$1" 2>/dev/null || cat "$1" 2>/dev/null
}
_ley_nums() {   # _ley_nums <archivo> → numeros de ley, en orden de aparicion
  _ley_seccion "$1" | sed -n 's/^\([0-9][0-9]*[a-z]*\)\. \*\*.*/\1/p'
}
_ley_title() {  # _ley_title <archivo> <num> → titulo, marcador de roto, o vacio
  _ley_seccion "$1" | awk -v num="$2" '
    $0 ~ ("^" num "\\. \\*\\*") {
      resto = substr($0, index($0, "**") + 2)
      cierre = 0
      for (i = 1; i < length(resto); i++) { if (substr(resto, i, 2) == "**") cierre = i }
      if (cierre == 0) { print "<SIN-CIERRE>"; exit }
      t = substr(resto, 1, cierre - 1)
      gsub(/`/, "", t)
      sub(/[ \t]+$/, "", t)
      if (index(t, "**") > 0) { print "<ANIDADO>"; exit }
      print t
      exit
    }
  ' 2>/dev/null
}
_ley_rota() { case "$1" in "<SIN-CIERRE>"|"<ANIDADO>") return 0 ;; *) return 1 ;; esac; }

_mapa_cl="$WS/CLAUDE.md"; _mapa_ag="$WS/AGENTS.md"
if [ ! -f "$_mapa_cl" ] || [ ! -f "$_mapa_ag" ]; then
  # Tercer estado. La ausencia del archivo YA la reporta el doctor (CLAUDE.md
  # en el bloque de archivos nucleo, AGENTS.md en la linea de arriba): repetirla
  # seria el mismo hallazgo con dos caras. Lo que falta decir es que la
  # coherencia quedo SIN mirar, que no es lo mismo que verde.
  _ley_falta=""
  [ -f "$_mapa_cl" ] || _ley_falta="CLAUDE.md"
  [ -f "$_mapa_ag" ] || _ley_falta="${_ley_falta:+$_ley_falta y }AGENTS.md"
  warn "no pude verificar leyes: falta $_ley_falta (los dos mapas comparten numeracion y los playbooks citan 'Ley N' contra ambos; con uno solo no hay con que comparar)"
else
  _ley_bad=0
  # (b) El mismo numero DOS veces en un mapa: la firma exacta del merge fallido.
  # El que cita "Ley N" resuelve a la primera que caiga, y la otra queda muda.
  for _ley_map in CLAUDE.md AGENTS.md; do
    _ley_dups="$(_ley_nums "$WS/$_ley_map" | sort | uniq -d | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [ -n "$_ley_dups" ]; then
      fail "$_ley_map numera DOS veces la(s) ley(es): $_ley_dups (dos leyes distintas con el mismo numero: la cita de un playbook resuelve a la que aparezca primero)" \
           "es un merge del update mal aplicado: re-corre /harness-init . en modo update. Las leyes viajan como BLOQUE COMPLETO del template, jamas ley por ley"
      _ley_bad=1
    fi
  done
  # (a) Mismo numero, mismo titulo en los dos mapas.
  _ley_todos="$( { _ley_nums "$_mapa_cl"; _ley_nums "$_mapa_ag"; } | sort -u | sort -n )"
  if [ -z "$_ley_todos" ]; then
    warn "no pude verificar leyes: ni CLAUDE.md ni AGENTS.md tienen leyes numeradas (se esperan lineas 'N. **Titulo**'); si las tienen con otro formato, este check esta ciego y no es verde"
    _ley_bad=1
  fi
  for _ley_n in $_ley_todos; do
    _t_cl="$(_ley_title "$_mapa_cl" "$_ley_n")"
    _t_ag="$(_ley_title "$_mapa_ag" "$_ley_n")"
    if _ley_rota "$_t_cl"; then
      fail "Ley $_ley_n en CLAUDE.md: titulo $_t_cl (no cierra el ** en su linea, o tiene negrita anidada); asi no hay canon con que comparar" \
           "escribi el titulo COMPLETO en la linea que abre la ley, entre ** y **, sin otro ** adentro"
      _ley_bad=1; continue
    fi
    if _ley_rota "$_t_ag"; then
      fail "Ley $_ley_n en AGENTS.md: titulo $_t_ag (no cierra el ** en su linea, o tiene negrita anidada); un titulo partido o anidado puede decir lo CONTRARIO del canon y pasar igual" \
           "escribi el titulo COMPLETO en la linea que abre la ley, entre ** y **, sin otro ** adentro"
      _ley_bad=1; continue
    fi
    if [ -z "$_t_ag" ]; then
      fail "Ley $_ley_n esta en CLAUDE.md y NO en AGENTS.md: quien entra por AGENTS.md (Cursor, Codex, Kimi) no la tiene, y si un playbook la cita la instruccion queda sin resolver" \
           "falta parte del bloque de leyes: re-corre /harness-init . en modo update. Las leyes viajan como BLOQUE COMPLETO del template, jamas ley por ley"
      _ley_bad=1; continue
    fi
    if [ -z "$_t_cl" ]; then
      fail "Ley $_ley_n esta en AGENTS.md y NO en CLAUDE.md: numeracion vieja que sobrevivio al merge (el numero sale del canon, no se inventa en el otro mapa)" \
           "re-corre /harness-init . en modo update: las leyes viajan como BLOQUE COMPLETO del template, jamas ley por ley (renumerar a mano es como se llega aca)"
      _ley_bad=1; continue
    fi
    _ley_pref=no; _ley_largo=0
    case "$_t_cl" in "$_t_ag"*) _ley_pref=si; _ley_largo=${#_t_ag} ;; esac
    case "$_t_ag" in "$_t_cl"*) _ley_pref=si; _ley_largo=${#_t_cl} ;; esac
    if [ "$_ley_pref" = no ]; then
      fail "Ley $_ley_n con titulo distinto en cada mapa: CLAUDE.md dice '$_t_cl' y AGENTS.md dice '$_t_ag' (la misma cita 'Ley $_ley_n' manda a dos leyes distintas segun por donde entre el agente)" \
           "iguala los dos mapas: el canon es CLAUDE.md, copia su titulo a AGENTS.md (o al reves, si el editado a mano fue CLAUDE.md). Si no los editaste vos, re-corre /harness-init . en modo update"
      _ley_bad=1; continue
    fi
    if [ "$((_ley_largo * 100))" -lt "$((${#_t_cl} * LEY_MIN_PCT))" ]; then
      fail "Ley $_ley_n: el titulo de AGENTS.md ('$_t_ag') coincide en $_ley_largo de los ${#_t_cl} caracteres del canon, menos del ${LEY_MIN_PCT}%: no alcanza para identificar la ley" \
           "iguala los dos mapas: copia el titulo entero del canon (CLAUDE.md) a AGENTS.md. Un recorte de la cola se acepta, pero tiene que cubrir al menos el ${LEY_MIN_PCT}% del titulo"
      _ley_bad=1; continue
    fi
  done
  # (c) Toda "Ley N" citada por un playbook existe en LOS DOS mapas. Un playbook
  # es la instruccion que el agente ejecuta sin poder preguntar. Se ignoran las
  # lineas de titulo ('#'): la "## Ley 0" de agents/architect.md es una ley
  # INTERNA de ese rol, no una cita del mapa. Un titulo roto ya lo reporto (a)
  # con su propia remediacion; aca solo importa que el numero EXISTA.
  _ley_citas="$(for _ley_f in "$WS"/.claude/commands/*.md "$WS"/.claude/agents/*.md; do
      [ -f "$_ley_f" ] || continue
      grep -v '^#' "$_ley_f" 2>/dev/null
    done | grep -oE 'Ley [0-9]+[a-z]?' | sed 's/^Ley //' | sort -u | sort -n)"
  for _ley_n in $_ley_citas; do
    _ley_falta=""
    [ -n "$(_ley_title "$_mapa_cl" "$_ley_n")" ] || _ley_falta=" CLAUDE.md"
    [ -n "$(_ley_title "$_mapa_ag" "$_ley_n")" ] || _ley_falta="$_ley_falta AGENTS.md"
    [ -n "$_ley_falta" ] || continue
    fail "cita huerfana: los playbooks citan 'Ley $_ley_n' y ese numero no existe en:$_ley_falta" \
         "el agente ejecuta esa instruccion sin poder preguntar: re-corre /harness-init . en modo update para reponer el bloque. Las leyes viajan como BLOQUE COMPLETO del template, jamas ley por ley"
    _ley_bad=1
  done
  if [ "$_ley_bad" -eq 0 ]; then
    ok "leyes coherentes en los dos mapas ($(printf '%s' "$_ley_todos" | wc -w | tr -d ' ') leyes con igual numero y titulo en CLAUDE.md y AGENTS.md; toda 'Ley N' citada por los playbooks existe en ambos)"
  fi
fi

# Pasos custom del pipeline (.claude/pipeline/*.md): cada playbook debe
# declarar un after válido, y si pide needs_mcp ese MCP debe estar en
# .mcp.json (si no, el paso agéntico alucina o cuelga). Intersección de
# conjuntos, cero opinión. Ver docs/harness/pipeline-steps.md.
if [ -d "$WS/.claude/pipeline" ]; then
  fmval() { awk -v k="$2:" 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} NR>1{l=$0;sub(/[ 	]*#.*$/,"",l);n=index(l,":");if(n>0){key=substr(l,1,n);val=substr(l,n+1);gsub(/[ 	]/,"",key);sub(/^[ 	]+/,"",val);sub(/[ 	]+$/,"",val);if(key==k){print val;exit}}}' "$1" 2>/dev/null; }
  for pb in "$WS"/.claude/pipeline/*.md; do
    [ -f "$pb" ] || continue
    pbn="$(basename "$pb")"
    after="$(fmval "$pb" after)"
    case "$after" in
      intake|rfc|implement|review|ship|deploy) ok "paso custom $pbn (after: $after)" ;;
      "") fail "paso custom $pbn sin 'after:'" "declara after: intake|rfc|implement|review|ship|deploy en el frontmatter" ;;
      *) fail "paso custom $pbn con after inválido: $after" "usa una fase real: intake|rfc|implement|review|ship|deploy" ;;
    esac
    mcp="$(fmval "$pb" needs_mcp)"
    if [ -n "$mcp" ]; then
      if [ -f "$WS/.mcp.json" ] && jq -e --arg m "$mcp" '.mcpServers[$m]' "$WS/.mcp.json" >/dev/null 2>&1; then
        ok "paso $pbn: MCP '$mcp' presente"
      else
        fail "paso custom $pbn declara needs_mcp '$mcp' AUSENTE en .mcp.json" "añade el MCP (elige la capacidad en /harness-init) o corrige needs_mcp en $pbn"
      fi
    fi
    runp="$(fmval "$pb" run)"
    if [ -n "$runp" ]; then
      case "$runp" in scripts/*..*|*/..*|/*) fail "paso $pbn con run inseguro: $runp" "usa una ruta dentro de scripts/ sin .." ;;
      scripts/*) [ -x "$WS/$runp" ] && ok "paso $pbn: run $runp ejecutable" || fail "paso $pbn: run $runp no ejecutable/ausente" "chmod +x $runp o corrige la ruta" ;;
      *) fail "paso $pbn: run debe vivir en scripts/: $runp" "mueve el script a scripts/" ;; esac
    fi
  done
fi
# Reglas custom (.claude/rules/*.md): una regla sin diente es un párrafo, y un
# párrafo no cambia lo que hace un agente apurado. El doctor NO juzga el
# contenido de la regla (eso lo ratifica un humano): verifica lo mecánico, que
# declare CÓMO se verifica y que ese verificador EXISTA. Una regla que apunta a
# un semgrep o a un paso que nadie creó es peor que ninguna: se cita en los
# reviews como si tuviera diente. Ver docs/harness/rules.md.
if [ -d "$WS/.claude/rules" ]; then
  rfm() { awk -v k="$2:" 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} NR>1{l=$0;sub(/[ 	]*#.*$/,"",l);n=index(l,":");if(n>0){key=substr(l,1,n);val=substr(l,n+1);gsub(/[ 	]/,"",key);sub(/^[ 	]+/,"",val);sub(/[ 	]+$/,"",val);if(key==k){print val;exit}}}' "$1" 2>/dev/null; }
  for rl in "$WS"/.claude/rules/*.md; do
    [ -f "$rl" ] || continue
    rn="$(basename "$rl")"; rid="${rn%.md}"
    [ "$rid" = "README" ] && continue
    fid="$(rfm "$rl" id)"
    [ "$fid" = "$rid" ] || fail "regla $rn: el id del frontmatter ('$fid') no es el nombre del archivo" \
      "renombra el archivo a <id>.md o corrige id: en $rn (las citas de los agentes usan el id)"
    enf="$(rfm "$rl" enforcement)"; by="$(rfm "$rl" enforced_by)"
    case "$enf" in
      judgment)
        ok "regla $rid (enforcement: judgment, la citan los agentes)" ;;
      semgrep|hook|gate|pipeline-step|doctor|cronjob)
        if [ -z "$by" ]; then
          fail "regla $rid declara enforcement: $enf SIN enforced_by" \
               "apunta al artefacto que la verifica (ruta relativa) o bájala a enforcement: judgment"
        else
          bypath="${by%%:*}"
          case "$by" in
            /*|*..*) fail "regla $rid: enforced_by sale del workspace: $by" "usa una ruta relativa dentro del workspace" ;;
            *)
              if [ ! -e "$WS/$bypath" ]; then
                fail "regla $rid apunta a un verificador AUSENTE: $by" \
                     "crea $bypath o baja la regla a enforcement: judgment (una regla que promete diente y no lo tiene se cita como si lo tuviera)"
              elif [ "$enf" = "semgrep" ] && [ "$by" != "$bypath" ] && ! grep -q "id: ${by#*:}" "$WS/$bypath" 2>/dev/null; then
                fail "regla $rid: $bypath existe pero no contiene la regla semgrep '${by#*:}'" \
                     "añade esa regla a $bypath o corrige enforced_by en $rn"
              else
                ok "regla $rid ($enf → $by)"
              fi ;;
          esac
        fi ;;
      "") fail "regla $rn sin 'enforcement:'" "declara enforcement: judgment|semgrep|hook|gate|pipeline-step|doctor|cronjob" ;;
      *)  fail "regla $rn con enforcement inválido: $enf" "usa uno de: judgment|semgrep|hook|gate|pipeline-step|doctor|cronjob" ;;
    esac
    case "$(rfm "$rl" status)" in
      RATIFICADA) : ;;
      DRAFT|"") warn "regla $rid en DRAFT: nadie la puede citar como ley hasta que un humano la ratifique (status: RATIFICADA)" ;;
      *) warn "regla $rid con status desconocido: $(rfm "$rl" status) (usa DRAFT|RATIFICADA)" ;;
    esac
    rmcp="$(rfm "$rl" needs_mcp)"
    if [ -n "$rmcp" ]; then
      if [ -f "$WS/.mcp.json" ] && jq -e --arg m "$rmcp" '.mcpServers[$m]' "$WS/.mcp.json" >/dev/null 2>&1; then
        ok "regla $rid: MCP '$rmcp' presente"
      else
        fail "regla $rid declara needs_mcp '$rmcp' AUSENTE en .mcp.json" \
             "añade el MCP (elige la capacidad en /harness-init) o corrige needs_mcp en $rn"
      fi
    fi
  done
fi

# Integridad de hooks: TODO hook referenciado en settings.json debe existir y
# ser ejecutable. Un hook registrado pero ausente spamea "not found" en CADA
# tool call del agente (visto en un VPS real: el generador olvidó un archivo).
# Intersección de conjuntos: cero opinión.
if [ -f "$WS/.claude/settings.json" ]; then
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    hp="$WS/${h#\$CLAUDE_PROJECT_DIR/}"; hp="${hp//\"/}"
    if [ ! -f "$hp" ]; then
      fail "hook registrado en settings.json pero AUSENTE: $h" "re-corre el update de la instancia (harness update o /harness-init .) o copia templates/hooks/$(basename "$h") del plugin"
    elif [ ! -x "$hp" ]; then
      fail "hook registrado pero no ejecutable: $h" "chmod +x $hp"
    fi
  done <<EOF
$(jq -r '.. | .command? // empty' "$WS/.claude/settings.json" 2>/dev/null | grep -o '[^ "]*\.claude/hooks/[^ "]*\.sh' | sed "s|.*\.claude/hooks/|.claude/hooks/|" | sort -u)
EOF
fi

# beads: TODO el pipeline de implement ordena por `bd ready --json` — si el
# workspace no está inicializado, /smart muere en la primera consulta del DAG.
if command -v bd >/dev/null 2>&1; then
  if (cd "$WS" && bd ready --json >/dev/null 2>&1); then
    ok "beads operativo (bd ready responde — el DAG de tareas tiene motor)"
  else
    warn "bd instalado pero 'bd ready --json' falla en el workspace — inicializa beads (bd init) o el pipeline no puede ordenar el DAG"
  fi
fi
# El mensaje prometía "graphify query responde de verdad" y solo comprobaba
# que el ARCHIVO existiera: un graph.json de 176 bytes con 0 nodos pasaba como
# sano mientras los agentes consultaban una fuente vacía (issue #25). Se
# cuentan nodos: si la afirmación es "responde", que lo compruebe.
if command -v graphify >/dev/null 2>&1; then
  gfile=""
  for cand in "$WS/graphify-out/graph.json" "$WS/repos/graphify-out/graph.json"; do
    [ -f "$cand" ] && { gfile="$cand"; break; }
  done
  if [ -z "$gfile" ]; then
    warn "graphify instalado pero SIN grafo — 'graphify query' falla y los agentes caen a grep masivo; corre scripts/graph-refresh.sh (o make graph)"
  else
    gnodes="$(jq '.nodes | length' "$gfile" 2>/dev/null)"
    case "$gnodes" in ''|*[!0-9]*) gnodes=0 ;; esac
    if [ "$gnodes" -gt 0 ]; then
      ok "grafo de graphify con $gnodes nodos (graphify query tiene qué responder)"
    else
      fail "grafo de graphify VACÍO (0 nodos) pero presente en $(basename "$(dirname "$gfile")")/" \
           "los agentes creen tener grafo y no lo tienen. Corre: bash scripts/graph-refresh.sh (construye por repo y fusiona) y revisa .cache/graph.log si vuelve a salir vacío"
    fi
  fi
fi
[ -d "$WS/specs" ] && ok "specs/ presente ($(ls "$WS/specs" 2>/dev/null | wc -l | tr -d ' ') capabilities)" || warn "sin specs/ — los abogados litigan sin documento citable"

# 11 · Cronjobs self-healing
# Los cronjobs viven en su propio repo (andresgarcia29/harness-cronjobs): el
# harness no los instala. Si alguien lo clonó DENTRO del workspace, se revisa
# como integración opcional; si no está, no es un hallazgo.
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

# ── Espacio en disco: el rojo que no es del código ────────────────────
# Caso de campo: 3 de 8 corridas de la misma suite rojas con el disco al 100 por
# ciento (los workers murieron por ENOSPC y ni colectaron el archivo de test);
# 16 de 16 verdes con 29G libres, mismo código. Un rojo por disco se lee igual
# que un defecto y manda a arreglar lo que no está roto.
#
# Acá es OBSERVADOR (el doctor informa), y avisa ANTES del umbral en el que
# ship.sh se niega a correr, para que se limpie sin perder una corrida. El que
# bloquea es el gate; este avisa. No mezclamos las familias.
_libre_kb="$(df -Pk "$WS" 2>/dev/null | awk 'NR==2 {print $4}')"
case "${_libre_kb:-x}" in
  ''|*[!0-9]*) warn "no pude leer el espacio libre de $WS (df ilegible): si una suite se pone roja sin causa clara, mirá el disco a mano" ;;
  *)
    _libre_gb=$((_libre_kb / 1024 / 1024))
    _min_gb="${HARNESS_MIN_FREE_GB:-2}"
    case "$_min_gb" in ''|*[!0-9]*) _min_gb=2 ;; esac
    if [ "$_libre_gb" -lt "$_min_gb" ]; then
      fail "quedan ${_libre_gb}G libres (ship.sh se niega a correr gates bajo ${_min_gb}G): NO ES TU CÓDIGO, ES EL DISCO" \
        "du -sh $WS/.cache $WS/worktrees | sort -h; scripts/worktree-task.sh --rm <task-id> de lo ya shippeado; docker system prune -a"
    elif [ "$_libre_gb" -lt $((_min_gb * 5)) ]; then
      warn "quedan ${_libre_gb}G libres: por encima del mínimo (${_min_gb}G) pero con poco margen. Un disco lleno produce rojos que PARECEN defectos de código (medido: 3 de 8 corridas). Lo que más crece: .cache/, worktrees/, imágenes de docker"
    else
      ok "espacio en disco: ${_libre_gb}G libres"
    fi ;;
esac

# ── Worktrees de tareas ya archivadas ────────────────────────────────────
# POR QUÉ: ningún hook conoce el estado "archivada". Todos derivan la tarea de
# la RUTA, así que un worktree cuya tarea ya se archivó sigue reclamándose,
# sigue bloqueando por el claim, y sigue emitiendo eventos con un task-id que
# ya no existe. Caso de campo: ~15 disparos de un hook de diseño sobre el
# worktree de una tarea archivada, cada uno un turno completo del modelo.
#
# `/archive` ahora los retira, y el job harness-janitor (repo aparte) hace
# `worktree prune`, que solo limpia METADATOS de directorios ya borrados. Este
# chequeo es para el que no corre los cronjobs y archivó antes del arreglo: el
# huérfano no se ve solo, se ve como ruido que nadie asocia a su causa.
if [ -d "$WS/worktrees" ] && [ -d "$WS/tasks/archive" ]; then
  _huerfanos=""
  for _wt in "$WS/worktrees"/*/; do
    [ -d "$_wt" ] || continue
    _tid="$(basename "$_wt")"
    # Viva si tasks/<id> existe; huérfana si además figura bajo tasks/archive/.
    [ -d "$WS/tasks/$_tid" ] && continue
    if ls -d "$WS/tasks/archive/"*"$_tid" >/dev/null 2>&1; then
      _huerfanos="$_huerfanos $_tid"
    fi
  done
  if [ -n "$_huerfanos" ]; then
    warn "worktrees de tareas YA ARCHIVADAS:$_huerfanos. Los hooks derivan la tarea de la ruta, así que siguen reclamando, bloqueando por claim y emitiendo eventos de un task-id muerto. Retiralos con: scripts/worktree-task.sh --rm <task-id> <repo> (se niega si hay trabajo sin publicar, que es lo que querés saber)"
  else
    ok "sin worktrees de tareas archivadas"
  fi
fi

[ "$INSTANCE_ONLY" -eq 1 ] && echo "── modo --instance-only: los CLI faltantes del host se contaron como avisos ──"
echo "── resultado: $FAIL fallos, $WARN advertencias ──"
[ "$FAIL" -eq 0 ]
