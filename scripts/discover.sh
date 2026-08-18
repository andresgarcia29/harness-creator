#!/usr/bin/env bash
# discover.sh — Fase 1 del harness-init. Determinista, cero tokens.
# Escanea <workspace>/repos (o <workspace> si no existe repos/) y produce
# <workspace>/inventory.json: lenguajes, señales, rol inferido y tamaño
# por repo, más un resumen agrupado por rol (insumo del clustering de
# agentes en la entrevista).
#
# Portabilidad: bash 3.2 (macOS), BSD grep/find. Requiere jq.
set -euo pipefail

WS="${1:?uso: discover.sh <workspace>}"
WS="$(cd "$WS" && pwd)"
REPOS_DIR="$WS/repos"
[ -d "$REPOS_DIR" ] || REPOS_DIR="$WS"

command -v jq >/dev/null || { echo "❌ jq requerido. Remediación: brew install jq | apt-get install -y jq"; exit 1; }

tmp="$(mktemp)"
echo "[]" > "$tmp"

# ¿El package.json declara alguna de estas dependencias?
pkg_has() { # pkg_has <dir> <dep>
  [ -f "$1/package.json" ] && grep -q "\"$2\"" "$1/package.json" 2>/dev/null
}

guess_role() { # guess_role <dir> <name> — imprime el rol en stdout
  local dir="$1" name="$2" tf_dir="" first_tf=""

  # contratos: buf o dominancia de .proto
  if [ -f "$dir/buf.yaml" ] || [ -f "$dir/buf.gen.yaml" ]; then echo "contracts"; return; fi

  # App que lleva su propia infra al lado: código de aplicación en la RAÍZ y el
  # terraform confinado a un subdirectorio. Sin este caso, el maxdepth 4 de
  # abajo se los come y una app deployable termina como infra-live → driver
  # `none` → cero verificación post-ship (el bug espejo del que motivó la
  # regla 8: aplicar el modelo equivocado por clasificar por el archivo que
  # aparece primero y no por lo que el repo ES).
  # No basta el marcador en raíz: un módulo terraform puede traer un
  # package.json de tooling. Se exige además evidencia de deployable
  # (Dockerfile o chart), y que NO haya .tf en la raíz.
  if [ -z "$(find "$dir" -maxdepth 1 -name '*.tf' -print -quit 2>/dev/null)" ] \
     && { [ -f "$dir/go.mod" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/package.json" ] || [ -f "$dir/pubspec.yaml" ]; } \
     && { find "$dir" -maxdepth 2 -name "Dockerfile*" -not -path "*/.git/*" -print -quit 2>/dev/null | grep -q . \
          || find "$dir" -maxdepth 3 -name "Chart.yaml" -not -path "*/.git/*" -print -quit 2>/dev/null | grep -q .; }; then
    : # cae a las ramas de lenguaje de abajo, que ya distinguen service/frontend/library
  # infra terraform: module (reutilizable) vs live (raíz aplicable).
  # maxdepth 4: los monorepos de infra viven en envs/prod/… y modules/x/… —
  # a profundidad 2 no se veían y caían a ci-library (bug real de campo).
  elif ls "$dir"/*.tf >/dev/null 2>&1 || find "$dir" -maxdepth 4 -name "*.tf" -not -path "*/.git/*" -print -quit 2>/dev/null | grep -q .; then
    # variables.tf/outputs.tf se buscan en la raíz Y junto al primer .tf: la
    # convención mayoritaria es terraform/ en subdirectorio, y exigirlos en la
    # raíz hacía que módulos reutilizables se declararan infra-live, o sea
    # "aplica infra al mergear", lo contrario de lo que son.
    tf_dir="$dir"
    if [ -z "$(find "$dir" -maxdepth 1 -name '*.tf' -print -quit 2>/dev/null)" ]; then
      first_tf="$(find "$dir" -maxdepth 4 -name "*.tf" -not -path "*/.git/*" -print -quit 2>/dev/null)"
      [ -z "$first_tf" ] || tf_dir="$(dirname "$first_tf")"
    fi
    # Los ejemplos y los tests NO son entornos: la convención mayoritaria de un
    # módulo reutilizable (terraform-aws-modules y las que la copian) es traer
    # `examples/dev` y `test/qa`, y sin excluirlos ese módulo se clasificaba
    # infra-live, o sea "aplica infra al mergear": la etiqueta OPUESTA a lo que
    # es, y la que decide qué modelo de deploy le aplica el harness.
    if [ -n "$(find "$dir" -maxdepth 2 -type d \
                 \( -name gbl -o -name global -o -name prod -o -name prd \
                    -o -name sbx -o -name sandbox -o -name dev -o -name stg \
                    -o -name stage -o -name qa -o -name nonprod \) \
                 -not -path "*/.git/*" \
                 -not -path "*/example/*"  -not -path "*/examples/*" \
                 -not -path "*/test/*"     -not -path "*/tests/*" \
                 -not -path "*/fixtures/*" -not -path "*/testdata/*" \
                 -print -quit 2>/dev/null)" ]; then
      # Un directorio de ENTORNO (terraform/prod, terraform/sbx…) es evidencia
      # directa de stack aplicable: gana sobre variables.tf, porque un stack
      # live perfectamente puede declarar variables y outputs propios.
      echo "infra-live"
    elif [ -f "$tf_dir/variables.tf" ] || [ -f "$tf_dir/outputs.tf" ] || echo "$name" | grep -qi "module"; then
      echo "infra-module"
    else
      echo "infra-live"
    fi
    return
  fi

  # mobile
  if [ -f "$dir/pubspec.yaml" ]; then echo "mobile"; return; fi

  # backend: servicio (deployable) vs librería compartida
  if [ -f "$dir/go.mod" ]; then
    if [ -d "$dir/cmd" ] || find "$dir" -maxdepth 2 -name "Dockerfile*" -print -quit 2>/dev/null | grep -q .; then
      echo "service"
    else
      echo "library"
    fi
    return
  fi
  if [ -f "$dir/pyproject.toml" ]; then
    if find "$dir" -maxdepth 2 -name "Dockerfile*" -print -quit 2>/dev/null | grep -q .; then
      echo "service"
    else
      echo "library"
    fi
    return
  fi

  # frontend TS/JS
  if [ -f "$dir/package.json" ]; then
    if pkg_has "$dir" react || pkg_has "$dir" vue || pkg_has "$dir" svelte || pkg_has "$dir" astro || pkg_has "$dir" vite; then
      echo "frontend"
    elif find "$dir" -maxdepth 2 -name "Dockerfile*" -print -quit 2>/dev/null | grep -q .; then
      echo "service"
    else
      echo "library"
    fi
    return
  fi

  # librería de charts helm (sin código de app: si tuviera go/py/ts ya habría
  # salido arriba) — es familia infra, no ci-library
  if find "$dir" -maxdepth 3 -name "Chart.yaml" -not -path "*/.git/*" -print -quit 2>/dev/null | grep -q .; then
    echo "infra-module"; return
  fi

  # monorepo de librerías (pyproject/package.json/go.mod en subdirs, no raíz)
  if find "$dir" -maxdepth 2 \( -name "pyproject.toml" -o -name "go.mod" -o -name "package.json" \) -not -path "*/.git/*" -print -quit 2>/dev/null | grep -q .; then
    echo "library"; return
  fi

  # librería de CI reusable (solo workflows)
  if [ -d "$dir/.github/workflows" ]; then echo "ci-library"; return; fi

  # docs: mayoría markdown
  local md_count total_count
  md_count=$(find "$dir" -type f -name "*.md" -not -path "*/.git/*" 2>/dev/null | wc -l | tr -d ' ')
  total_count=$(find "$dir" -type f -not -path "*/.git/*" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$total_count" -gt 0 ] && [ $((md_count * 2)) -ge "$total_count" ]; then echo "docs"; return; fi

  echo "unknown"
}

scan_repo() {
  local dir="$1" name langs=() signals=() has_claude_md=false branch="" remote="" role="" files=0
  name="$(basename "$dir")"

  [ -f "$dir/go.mod" ]         && langs+=("go")
  [ -f "$dir/package.json" ]   && langs+=("typescript")
  [ -f "$dir/pyproject.toml" ] && langs+=("python")
  [ -f "$dir/pubspec.yaml" ]   && langs+=("dart")
  { ls "$dir"/*.tf >/dev/null 2>&1 || find "$dir" -maxdepth 4 -name "*.tf" -not -path "*/.git/*" -print -quit 2>/dev/null | grep -q .; } && langs+=("terraform")

  { [ -f "$dir/buf.yaml" ] || [ -f "$dir/buf.gen.yaml" ]; } && signals+=("buf")
  find "$dir" -maxdepth 3 -name "Chart.yaml" -print -quit 2>/dev/null | grep -q . && signals+=("helm")
  [ -d "$dir/.github/workflows" ] && signals+=("gha")
  find "$dir" -maxdepth 2 -name "Dockerfile*" -print -quit 2>/dev/null | grep -q . && signals+=("docker")
  find "$dir" -maxdepth 3 -name "*.proto" -print -quit 2>/dev/null | grep -q . && signals+=("proto")
  find "$dir" -maxdepth 2 -name "docker-compose*.y*ml" -print -quit 2>/dev/null | grep -q . && signals+=("compose")
  # migrations: el catálogo filtra squawk y goose por "repos con migraciones
  # SQL", una señal que nadie emitía, así que esas capacidades jamás se
  # ofrecían aunque la evidencia estuviera en el repo.
  find "$dir" -maxdepth 3 -path "*/migrations/*" -name "*.sql" -print -quit 2>/dev/null | grep -q . && signals+=("migrations")
  grep -rq "argoproj.io" "$dir" --include="*.yaml" 2>/dev/null && signals+=("argocd")
  grep -rq "kargo.akuity.io" "$dir" --include="*.yaml" 2>/dev/null && signals+=("kargo")
  # atlantis: la TERCERA forma de aplicar infra, y la que no dejaba rastro.
  # El gate de deploy del doctor pregunta "¿hay un workflow con deploy/apply en
  # el nombre?", así que un repo que aplica terraform al mergear por un comentario
  # de Atlantis contestaba NO y se saltaba entero: driver → none, deploy-watch
  # "no reviso nada", y el apply rojo se descubre a mano. Medido en un workspace
  # real: 17 repos con atlantis.yaml, 5 de ellos invisibles para ese gate.
  { [ -f "$dir/atlantis.yaml" ] || [ -f "$dir/atlantis.yml" ]; } && signals+=("atlantis")
  grep -rq 'provider "google"' "$dir" --include="*.tf" 2>/dev/null && signals+=("gcp")
  # Gemelas de gcp/gke: el eje "nube" tenía UNA sola implementación detectada,
  # así que un workspace 100% AWS se veía idéntico a uno sin nube (regla 8: un
  # eje que varía se DETECTA, no se asume).
  grep -rq 'provider "aws"' "$dir" --include="*.tf" 2>/dev/null && signals+=("aws")
  grep -rq 'aws_eks_cluster\|aws_eks_node_group' "$dir" --include="*.tf" 2>/dev/null && signals+=("eks")
  grep -rq 'aws_lambda_function' "$dir" --include="*.tf" 2>/dev/null && signals+=("lambda")
  # Señales que el CATÁLOGO ya filtraba por prosa y nadie emitía, así que
  # capacidades correctas nunca se ofrecían aunque la evidencia estuviera en
  # el repo. Cada una tiene su consumidor en catalog/capabilities.yaml.
  grep -rq 'google_container_cluster' "$dir" --include="*.tf" 2>/dev/null && signals+=("gke")
  grep -rqi 'prometheus' "$dir" --include="*.y*ml" --include="*.tf" 2>/dev/null && signals+=("prometheus")
  # Observabilidad más allá de prometheus: mismo eje, otras implementaciones.
  grep -rq 'observeinc\|observe_\|OBSERVE_CUSTOMER' "$dir" --include="*.tf" --include="*.y*ml" 2>/dev/null && signals+=("observe")
  grep -rq 'aws_cloudwatch' "$dir" --include="*.tf" 2>/dev/null && signals+=("cloudwatch")
  # Streaming: el eje que no tenía NI UNA implementación detectada, así que un
  # workspace sobre Kafka se veía igual que uno sin event streaming. Se mira la
  # infra Y el cliente porque los topics casi nunca viven en el mismo repo que
  # los consume: en los 91 repos medidos la única evidencia era una policy IAM
  # con arn:aws:kafka (o sea MSK, consumido pero no creado acá), cero recursos
  # confluent_* y cero clientes, así que buscar solo `provider "confluent"`
  # habría contestado "acá no hay streaming" sobre una plataforma que sí lo usa.
  # Por eso arn:aws:kafka cuenta: es permiso sobre un cluster que existe.
  { grep -rq 'confluent_\|provider "confluent"\|aws_msk\|arn:aws:kafka' "$dir" --include="*.tf" 2>/dev/null \
    || grep -rqi 'confluent-kafka\|kafkajs\|@confluentinc\|segmentio/kafka-go\|Shopify/sarama\|IBM/sarama\|springframework.kafka' \
       "$dir" --include="go.mod" --include="package.json" --include="pyproject.toml" \
       --include="requirements*.txt" --include="pom.xml" --include="build.gradle*" 2>/dev/null; } \
    && signals+=("kafka")
  grep -rqi 'sentry' "$dir" --include="package.json" --include="go.mod" \
    --include="pyproject.toml" --include="requirements*.txt" --include="Gemfile" 2>/dev/null \
    && signals+=("sentry")
  { grep -rq 'service .*{' "$dir" --include="*.proto" 2>/dev/null \
    || grep -rqi 'grpc' "$dir" --include="go.mod" --include="package.json" \
       --include="pyproject.toml" 2>/dev/null; } && signals+=("grpc")
  [ -f "$dir/CLAUDE.md" ] && has_claude_md=true

  branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo unknown)"
  remote="$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")"
  role="$(guess_role "$dir" "$name")"
  files=$(find "$dir" -type f -not -path "*/.git/*" 2>/dev/null | wc -l | tr -d ' ')

  jq --arg name "$name" \
     --arg branch "$branch" \
     --arg remote "$remote" \
     --arg role "$role" \
     --argjson files "$files" \
     --argjson claude "$has_claude_md" \
     --argjson langs "$(printf '%s\n' "${langs[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
     --argjson signals "$(printf '%s\n' "${signals[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
     '. += [{name:$name, current_branch:$branch, remote:$remote, role_guess:$role,
             file_count:$files, languages:$langs, signals:$signals, has_claude_md:$claude}]' \
     "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
}

found=0
for dir in "$REPOS_DIR"/*/; do
  [ -d "$dir/.git" ] || continue
  scan_repo "${dir%/}"
  found=$((found+1))
done

if [ "$found" -eq 0 ]; then
  echo "❌ No se encontraron repos git en $REPOS_DIR"
  echo "   Remediación: clona tus repos en $WS/repos/ y reintenta."
  exit 2
fi

# ── Señales de fuente de secretos (workspace-level, para que la
#    entrevista recomiende con evidencia, no adivine) ─────────────────
secret_hints=()
find "$REPOS_DIR" -maxdepth 3 -name ".sops.yaml" -print -quit 2>/dev/null | grep -q . && secret_hints+=("sops")
find "$REPOS_DIR" -maxdepth 3 \( -name "doppler.yaml" -o -name "doppler.yml" \) -print -quit 2>/dev/null | grep -q . && secret_hints+=("doppler")
find "$REPOS_DIR" -maxdepth 2 -name ".env.example" -print -quit 2>/dev/null | grep -q . && secret_hints+=("env")
grep -rq "VAULT_ADDR\|vault_generic_secret\|hashicorp/vault" "$REPOS_DIR" --include="*.tf" --include="*.yaml" --include="*.md" 2>/dev/null && secret_hints+=("vault")
grep -rq "google_secret_manager_secret" "$REPOS_DIR" --include="*.tf" 2>/dev/null && secret_hints+=("gcp-secret-manager")
grep -rq "aws_secretsmanager" "$REPOS_DIR" --include="*.tf" 2>/dev/null && secret_hints+=("aws-secrets-manager")
grep -rq "op://" "$REPOS_DIR" --include="*.yaml" --include="*.env*" --include="*.tpl" 2>/dev/null && secret_hints+=("1password")
SECRET_HINTS_JSON="$(printf '%s\n' "${secret_hints[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"

jq -n \
  --arg workspace "$WS" \
  --arg scanned_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson repos "$(cat "$tmp")" \
  --argjson secret_hints "$SECRET_HINTS_JSON" \
  '{workspace:$workspace, scanned_at:$scanned_at, repo_count:($repos|length), repos:$repos,
    secret_hints:$secret_hints,
    by_role: ($repos | group_by(.role_guess) | map({key: .[0].role_guess, value: map(.name)}) | from_entries),
    summary:{
      go:[$repos[]|select(.languages|index("go"))|.name],
      typescript:[$repos[]|select(.languages|index("typescript"))|.name],
      python:[$repos[]|select(.languages|index("python"))|.name],
      dart:[$repos[]|select(.languages|index("dart"))|.name],
      terraform:[$repos[]|select(.languages|index("terraform"))|.name],
      proto:[$repos[]|select(.signals|index("proto"))|.name],
      helm:[$repos[]|select(.signals|index("helm"))|.name],
      argocd:[$repos[]|select(.signals|index("argocd"))|.name],
      kargo:[$repos[]|select(.signals|index("kargo"))|.name],
      atlantis:[$repos[]|select(.signals|index("atlantis"))|.name],
      gcp:[$repos[]|select(.signals|index("gcp"))|.name],
      aws:[$repos[]|select(.signals|index("aws"))|.name],
      eks:[$repos[]|select(.signals|index("eks"))|.name],
      lambda:[$repos[]|select(.signals|index("lambda"))|.name],
      observe:[$repos[]|select(.signals|index("observe"))|.name],
      cloudwatch:[$repos[]|select(.signals|index("cloudwatch"))|.name],
      kafka:[$repos[]|select(.signals|index("kafka"))|.name],
      compose:[$repos[]|select(.signals|index("compose"))|.name],
      missing_claude_md:[$repos[]|select(.has_claude_md|not)|.name]
    }}' > "$WS/inventory.json"

echo "✅ inventory.json generado: $found repos escaneados"
echo "── repos por rol (insumo del clustering de agentes) ──"
jq -r '.by_role | to_entries[] | "  \(.key): \(.value | join(", "))"' "$WS/inventory.json"
rm -f "$tmp"

# ── .serena/project.yml: sin esto, Serena no ve UNA LÍNEA del código ──
# (#214) El harness gitignorea `repos/` a propósito, porque los clones son
# regenerables. El default de Serena es `ignore_all_files_in_gitignore: true`.
# Los dos son razonables por separado y juntos dan lo peor posible: Serena
# ignora el 100% del código de la plataforma EN TODA INSTANCIA del harness,
# aunque los language servers arranquen perfecto. En campo:
#   ValueError: Cannot extract symbols from file repos/<repo>/.../x.go.
#   Active language servers: ['typescript', 'go', 'python', 'bash']
# Los servers estaban vivos; el archivo estaba excluido.
#
# Y nadie escribía este archivo, así que Serena lo creaba sola y autodetectaba
# el lenguaje desde la RAÍZ del workspace, que solo tiene `.sh`: `[bash]`. Un
# repo por lenguaje más abajo, y ninguno se veía.
#
# El dato ya lo tiene el harness (`inventory.json`, acá arriba) y los nombres
# de lenguaje mapean 1:1 a IDs de Serena. Por eso se genera acá y no en la
# entrevista: es derivable, determinista y cuesta cero tokens.
#
# LO QUE SE OMITE Y POR QUÉ: un language server que no arranca BLOQUEA la
# inicialización de TODOS, no solo la suya (declarar `python` no sirve de nada
# si `go` está en la lista y falta `gopls`: falla hasta el `.py`). Así que un
# lenguaje cuyo binario no está en el PATH se DECLARA OMITIDO con su línea de
# instalación, en vez de entrar a la lista y llevarse puestos a los demás.
serena_requiere() {  # serena_requiere <lenguaje> → "<binario>|<cómo instalarlo>"
  # Serena descarga sola casi todos los servers; estos necesitan la toolchain
  # del host. Fuente: oraios.github.io/serena → programming-languages.
  case "$1" in
    go)         echo "gopls|go install golang.org/x/tools/gopls@latest" ;;
    terraform)  echo "terraform|brew install terraform (o tfenv/asdf)" ;;
    python)     echo "uvx|curl -LsSf https://astral.sh/uv/install.sh | sh" ;;
    typescript) echo "node|brew install node (o nvm/fnm)" ;;
    dart)       echo "dart|instalá el SDK de Dart/Flutter" ;;
    *)          echo "|" ;;
  esac
}

declarados=""; omitidos=""; requeridos=""
# De más repos a menos: el PRIMERO de la lista es el default de Serena y el
# fallback para archivos que ningún otro server reclama.
for lang in $(jq -r '[.repos[].languages[]] | group_by(.) | sort_by(-length) | .[] | .[0]' "$WS/inventory.json"); do
  spec="$(serena_requiere "$lang")"; bin="${spec%%|*}"; how="${spec#*|}"
  if [ -z "$bin" ] || command -v "$bin" >/dev/null 2>&1; then
    declarados="$declarados $lang"
    [ -z "$bin" ] || requeridos="$requeridos $bin"
  else
    omitidos="$omitidos
#   $lang: falta \`$bin\` en el PATH · $how"
  fi
done
# bash al final y siempre: la raíz del workspace son los scripts del harness, y
# su server lo autoprovisiona Serena. Último en la lista = no es el default.
declarados="$declarados bash"

mkdir -p "$WS/.serena"
{
  echo "# .serena/project.yml: GENERADO por harness-creator (scripts/discover.sh)."
  echo "# Se reescribe en cada discovery: lo que edites acá se pierde."
  echo "# Derivado de inventory.json ($found repos)."
  echo "project_name: \"$(basename "$WS")\""
  echo "language_servers: [$(echo "$declarados" | tr -s ' ' | sed 's/^ //; s/ /, /g')]"
  [ -z "$omitidos" ] || { echo "# OMITIDOS (un server que no arranca bloquea a TODOS):$omitidos"; }
  echo "# doctor.sh verifica que estos sigan en el PATH:"
  echo "# harness-requiere:$(echo "$requeridos" | tr -s ' ' | sed 's/ $//')"
  echo
  echo "# repos/ está gitignoreado A PROPÓSITO (los clones son regenerables) y el"
  echo "# default de Serena es ignorar todo lo gitignoreado: con \`true\` acá, Serena"
  echo "# no ve una línea del código de la plataforma (#214)."
  echo "ignore_all_files_in_gitignore: false"
  echo "# Y como el .gitignore deja de aplicar, lo regenerable se nombra a mano:"
  echo "# sin esto entra al índice worktrees/ (una copia de cada repo), los"
  echo "# node_modules y los .venv que el .gitignore de cada repo tapaba."
  echo "ignored_paths:"
  for p in "worktrees/**" "locks/**" ".cache/**" ".harness/**" "tasks/**" \
           "graphify-out/**" ".secrets.d/**" "**/node_modules/**" "**/.venv/**" \
           "**/venv/**" "**/vendor/**" "**/dist/**" "**/build/**" "**/target/**" \
           "**/.terraform/**" "**/__pycache__/**" "**/.dart_tool/**"; do
    echo "  - \"$p\""
  done
} > "$WS/.serena/project.yml"

echo "✅ .serena/project.yml:$declarados (sin esto Serena ignora repos/ entero)"
if [ -n "$omitidos" ]; then
  echo "⚠️  language servers OMITIDOS por falta de binario (uno que no arranca los bloquea a todos):"
  printf '%s\n' "$omitidos" | sed 's/^#  /  /' | grep -v '^$'
  echo "   Instalalos y volvé a correr este script para que entren."
fi
