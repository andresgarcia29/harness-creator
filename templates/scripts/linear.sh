#!/usr/bin/env bash
# linear.sh: lo que TODO script del carril Linear necesita, en un solo lugar.
# No se ejecuta: se sourcea (`. "$WS/scripts/linear.sh"`).
#
# POR QUÉ EXISTE (#113): "el ticket no existe" y "tu API key es de OTRA
# organización de Linear" son la misma respuesta del API y dos remediaciones
# opuestas, y elegir mal es el peor desvío posible: manda a buscar un ticket
# borrado cuando el ticket está ahí, a la vista, abierto en el navegador.
#
# El caso de campo se midió dos veces. La primera (COR-622) contra
# `ticket-pull.sh`, que se arregló. La segunda contra `ticket-close.sh`, que
# tenía el MISMO bug porque el arreglo se había hecho script por script:
#
#     $ scripts/ticket-close.sh COR-944 --status shipped
#     ❌ ticket COR-944 no existe
#
# El ticket existía y estaba sin archivar. Lo que pasaba es que la
# `LINEAR_API_KEY` entra a la organización `corvux` y el ticket vive en
# `corvux-ai`: DOS organizaciones con un team `COR` y numeración solapada, así
# que `COR-944` es un identifier perfectamente válido que sencillamente no
# existe de este lado.
#
# Por eso el diagnóstico vive acá y no en cada script: una clase de error que
# sobrevive al arreglo de un consumidor y sigue viva en el otro no era un bug de
# ese consumidor, era una pieza faltante. Los que la usan hoy son
# `ticket-pull.sh` y `ticket-close.sh`; cualquier script nuevo del carril
# autenticado por PAT hereda el diagnóstico en vez de reinventarlo a medias.
#
# Portabilidad: bash 3.2, BSD userland, curl, jq.

LINEAR_API="${LINEAR_API:-https://api.linear.app/graphql}"

linear_require_key() {  # → sale 4 si no hay credencial: sin ella no hay nada que preguntar
  [ -n "${LINEAR_API_KEY:-}" ] && return 0
  echo "❌ LINEAR_API_KEY no está en el entorno: usa scripts/with-secrets.sh" >&2
  exit 4
}

linear_gql() {  # linear_gql <query-json> → la respuesta cruda
  curl -sf --retry 3 --retry-delay 2 --retry-all-errors -X POST "$LINEAR_API" \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    --data "$1" \
    || { echo "❌ error de red/auth contra Linear" >&2; exit 4; }
}

# El diagnóstico. Se llama cuando `issue(id:)` devolvió null, y su trabajo es
# decir CUÁL de las dos cosas pasó, con la misma credencial que acaba de fallar.
#
# Sale 6 cuando el prefijo del ticket no es ni siquiera un team alcanzable: ahí
# no hay ambigüedad posible, la key es de otra organización y punto. Sale 2
# cuando el team SÍ existe de este lado, que es el caso engañoso: el identifier
# es válido, el número no está, y la causa puede ser cualquiera de las dos. Ahí
# no se afirma: se pone el `urlKey` de esta credencial delante para que quien
# lee lo compare con la URL del ticket en un segundo.
linear_no_existe() {  # linear_no_existe <ID> <respuesta-del-issue> → 2 · 6
  local id="$1" resp="${2:-}" errcode scope orgkey teamkeys prefix
  errcode="$(printf '%s' "$resp" | jq -r '.errors[0].extensions.code // empty' 2>/dev/null)"
  scope="$(linear_gql '{"query":"query{ organization { urlKey } teams { nodes { key } } }"}')"
  orgkey="$(printf '%s' "$scope" | jq -r '.data.organization.urlKey // "desconocida"' 2>/dev/null)"
  teamkeys="$(printf '%s' "$scope" | jq -r '[.data.teams.nodes[].key] | join(", ")' 2>/dev/null || echo "")"
  prefix="${id%%-*}"
  if [ -n "$errcode" ] && ! printf '%s\n' "$teamkeys" | tr ', ' '\n\n' | grep -qx "$prefix"; then
    echo "❌ $id está fuera del alcance de esta credencial: la key entra a la org '$orgkey' (teams: ${teamkeys:-ninguno}) y ahí no existe el team '$prefix'."
    echo "   ↳ la LINEAR_API_KEY es de otra organización: mintea una de la org dueña de '$prefix' y recargala vía with-secrets."
    return 6
  fi
  echo "❌ ticket $id no existe en la org '$orgkey' (teams alcanzables: ${teamkeys:-ninguno})"
  echo "   ↳ ojo: si otra organización comparte el prefijo '$prefix', esta key no la ve; compará el urlKey de la URL del ticket con '$orgkey'."
  return 2
}
