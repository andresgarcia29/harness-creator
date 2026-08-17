#!/usr/bin/env bash
# jira.sh: lo que TODO script del carril Jira necesita, en un solo lugar.
# No se ejecuta: se sourcea (`. "$WS/scripts/jira.sh"`).
#
# Hermano de linear.sh, y existe por la misma razón (#113): la clase de error
# que confunde no se arregla script por script, se pone en la pieza compartida
# y todos los consumidores la heredan. Los que la usan son `ticket-pull.sh` y
# `ticket-close.sh`.
#
# EL DIAGNÓSTICO QUE JIRA HACE FALTA. Jira Cloud responde 404 a un issue que
# no existe Y a uno que existe pero tu cuenta no puede ver, que son dos
# remediaciones opuestas: "el ticket está mal" vs "pedile acceso al proyecto".
# Peor: el 404 también sale cuando el SITE está bien pero el issue vive en otro
# site (una org con jira-a.atlassian.net y jira-b.atlassian.net y el mismo
# prefijo de proyecto en las dos). Igual que en Linear, acá no se afirma: se
# pregunta con la MISMA credencial qué proyectos alcanza y se pone el site
# delante para que quien lee lo compare con la URL de su ticket en un segundo.
#
# AUTH: Jira Cloud usa Basic con `email:api_token` en base64, NO un bearer
# token. Un PAT de Jira Server/DC sí es bearer, y mezclarlos da un 401 sin
# explicación. Acá se soporta Cloud (el caso mayoritario) y se dice cuál falta.
#
# Portabilidad: bash 3.2, BSD userland, curl, jq.

JIRA_URL="${JIRA_URL:-}"
JIRA_API="${JIRA_URL:+$JIRA_URL/rest/api/3}"

jira_require_key() {  # → sale 4 si falta credencial: sin ella no hay nada que preguntar
  local falta=""
  [ -n "${JIRA_URL:-}" ]       || falta="$falta JIRA_URL"
  [ -n "${JIRA_EMAIL:-}" ]     || falta="$falta JIRA_EMAIL"
  [ -n "${JIRA_API_TOKEN:-}" ] || falta="$falta JIRA_API_TOKEN"
  [ -z "$falta" ] && { JIRA_API="$JIRA_URL/rest/api/3"; return 0; }
  echo "❌ falta en el entorno:$falta (usa scripts/with-secrets.sh)" >&2
  echo "   JIRA_URL      → https://<tu-org>.atlassian.net (sin barra final)" >&2
  echo "   JIRA_EMAIL    → el email de la cuenta dueña del token" >&2
  echo "   JIRA_API_TOKEN→ https://id.atlassian.com/manage-profile/security/api-tokens" >&2
  echo "   (Jira Cloud autentica con Basic email:token, no con bearer.)" >&2
  exit 4
}

# curl contra la REST v3 de Jira. Devuelve el cuerpo crudo; corta con 4 si la
# red o la auth fallaron, que es un problema del operador y no del ticket.
jira_api() {  # jira_api <método> <path-relativo> [data-json]
  local method="$1" path="$2" data="${3:-}" out code
  if [ -n "$data" ]; then
    out="$(curl -s --retry 3 --retry-delay 2 --retry-all-errors \
      -w '\n%{http_code}' -X "$method" "$JIRA_API$path" \
      -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
      -H "Content-Type: application/json" -H "Accept: application/json" \
      --data "$data" 2>/dev/null)" || { echo "❌ error de red contra Jira ($JIRA_URL)" >&2; exit 4; }
  else
    out="$(curl -s --retry 3 --retry-delay 2 --retry-all-errors \
      -w '\n%{http_code}' -X "$method" "$JIRA_API$path" \
      -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
      -H "Accept: application/json" 2>/dev/null)" || { echo "❌ error de red contra Jira ($JIRA_URL)" >&2; exit 4; }
  fi
  code="$(printf '%s' "$out" | tail -n1)"
  case "$code" in
    2*) printf '%s' "$out" | sed '$d' ;;
    401|403)
      echo "❌ Jira rechazó la credencial (HTTP $code) para $JIRA_EMAIL en $JIRA_URL" >&2
      echo "   Jira Cloud usa Basic con email:api_token. Si tu instancia es" >&2
      echo "   Server/Data Center la auth es bearer y este carril no la cubre." >&2
      exit 4 ;;
    404) printf '%s' "$out" | sed '$d' ;;  # el consumidor decide: jira_no_existe diagnostica
    *)  echo "❌ Jira devolvió HTTP $code en $method $path" >&2; exit 4 ;;
  esac
}

# El diagnóstico. Se llama cuando el GET del issue devolvió 404, y su trabajo es
# decir CUÁL de las tres cosas pasó, con la misma credencial que acaba de fallar.
#
# Sale 6 cuando el prefijo del ticket no es ni un proyecto alcanzable: la
# credencial mira otro site (o no tiene el proyecto) y no hay ambigüedad. Sale
# 2 cuando el proyecto SÍ existe de este lado, que es el caso engañoso: la key
# es válida, el número no está, y puede ser inexistente o sin permiso de
# lectura. Ahí no se afirma.
jira_no_existe() {  # jira_no_existe <ID> → 2 · 6
  local id="$1" prefix keys
  prefix="${id%%-*}"
  keys="$(jira_api GET "/project/search?maxResults=100" 2>/dev/null \
    | jq -r '[.values[]?.key] | join(" ")' 2>/dev/null || echo "")"
  if [ -n "$keys" ] && ! printf ' %s ' "$keys" | grep -q " $prefix "; then
    echo "❌ el proyecto '$prefix' no existe con esta credencial." >&2
    echo "   Esta JIRA_API_TOKEN entra a: $JIRA_URL" >&2
    echo "   y alcanza los proyectos: $keys" >&2
    echo "   Compará el site con la URL de tu ticket: si no coinciden, el token" >&2
    echo "   es de otra instancia de Jira (mismo prefijo, otra org)." >&2
    return 6
  fi
  echo "❌ $id no aparece con esta credencial." >&2
  echo "   El proyecto '$prefix' SÍ existe en $JIRA_URL, así que son dos causas" >&2
  echo "   posibles y Jira devuelve 404 para las dos:" >&2
  echo "     · el issue no existe (¿número equivocado?)" >&2
  echo "     · existe y tu cuenta no tiene permiso de verlo → pedí acceso al proyecto" >&2
  echo "   Abrí $JIRA_URL/browse/$id: si carga en el navegador y acá no, es permiso." >&2
  return 2
}

# ADF → texto. La v3 del API devuelve la descripción como Atlassian Document
# Format (JSON con nodos anidados), no como string: un `.description` directo
# imprime "[object Object]" o null y la tarea nace sin requisitos. Se extrae el
# texto recursivamente y los saltos de línea se preservan por bloque.
jira_adf_text() {  # jira_adf_text <adf-json> → texto plano
  printf '%s' "${1:-}" | jq -r '
    def walk_adf:
      if type == "object" then
        if .type == "text" then (.text // "")
        elif .type == "hardBreak" then "\n"
        elif (.type // "") | test("^(paragraph|heading|listItem|blockquote|codeBlock|panel|tableRow)$")
          then ((.content // []) | map(walk_adf) | join("")) + "\n"
        else ((.content // []) | map(walk_adf) | join(""))
        end
      elif type == "array" then (map(walk_adf) | join(""))
      else "" end;
    if . == null or . == "" then "(sin descripción)"
    elif type == "string" then .
    else (walk_adf | if (. | gsub("\\s";"") ) == "" then "(sin descripción)" else . end)
    end' 2>/dev/null || printf '(sin descripción)'
}

# texto → ADF. Los comentarios de la v3 se POSTean como ADF, no como string:
# mandar `{"body":"texto"}` da 400. jq -Rs construye el sobre mínimo válido.
jira_adf_doc() {  # jira_adf_doc <texto> → JSON ADF de un párrafo
  printf '%s' "${1:-}" | jq -Rs '{type:"doc", version:1,
    content:[{type:"paragraph", content:[{type:"text", text:.}]}]}'
}
