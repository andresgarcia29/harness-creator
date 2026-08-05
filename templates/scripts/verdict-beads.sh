#!/usr/bin/env bash
# verdict-beads.sh: non_blocking → beads, como COMANDO y no como disciplina.
#
# POR QUÉ EXISTE: la cadena "los non_blocking se convierten en beads de
# seguimiento" estaba afirmada en cuatro archivos y ejecutada en cero. Caso
# de campo: una decisión de diferimiento vivía en un comentario y en tasks/
# (gitignoreado), o sea que por la Ley 7 no existía; dos reviewers tuvieron
# que abrir beads a mano. Convertir hallazgo en bead debe ser un comando.
#
# Qué hace: por cada entrada de non_blocking[] SIN bead, corre `bd create`
# (título + cuerpo con el origen exacto) y reescribe la entrada como
# {text, bead: <id>} con jq atómico POR entrada: el progreso parcial
# sobrevive a un crash de bd. Idempotente: las entradas con bead se saltan.
# Sin bd en PATH: sale honesto sin tocar NADA (no se exige lo que la
# máquina no puede dar; POLICY-ARCHIVE-002 aplica la misma regla).
#
# Uso: verdict-beads.sh <task-id> <repo>
# Exit: 0 todo con bead (o nada que hacer); 1 algún bd create falló.
# Portabilidad: bash 3.2, BSD userland, jq.
set -euo pipefail

TASK="${1:?uso: verdict-beads.sh <task-id> <repo>}"
REPO="${2:?uso: verdict-beads.sh <task-id> <repo>}"
ok_id() { case "$1" in [A-Za-z0-9][A-Za-z0-9._-]*) return 0 ;; *) return 1 ;; esac; }

# bead_id <salida-de-bd-create> → el id, o vacío. ANCLADO a dónde vive el id
# (la línea de creación, o la línea sola de `--silent`), nunca barriendo la
# salida entera: el barrido se quedaba con el PRIMER token con guion que bd
# imprimiera, y bd imprime avisos antes del id (el nombre de la db, una ruta).
# Caso de campo: el veredicto quedó afirmando el bead "test-beads", que no
# existe, mientras el real era otro. El falso positivo burlaba justo la guarda
# fail-closed de más abajo: siempre había "un id extraíble", solo que el
# equivocado, y afirmar un bead inexistente es peor que no tener bead.
bead_id() {
  local bi_id
  bi_id="$(printf '%s\n' "$1" | grep -i 'created' | head -1 \
    | sed -e 's/.*[Cc]reated//' -e 's/^[[:space:]]*[Ii]ssue//' -e 's/^[^A-Za-z0-9]*//' \
    | grep -oE '^[A-Za-z][A-Za-z0-9._]*-[A-Za-z0-9._]+' | head -1 || true)"
  # `bd create --silent` imprime el id pelado y nada más: sin línea que anclar,
  # se exige que la línea ENTERA sea el id (un aviso suelto no califica).
  [ -n "$bi_id" ] || bi_id="$(printf '%s\n' "$1" \
    | sed -n 's/^[[:space:]]*\([A-Za-z][A-Za-z0-9._]*-[A-Za-z0-9._]*\)[[:space:]]*$/\1/p' \
    | head -1 || true)"
  printf '%s' "$bi_id"
}
ok_id "$TASK" || { echo "❌ task-id inválido: '$TASK'"; exit 1; }
ok_id "$REPO" || { echo "❌ repo inválido: '$REPO'"; exit 1; }
command -v jq >/dev/null || { echo "❌ jq requerido"; exit 1; }

WS="$(cd "$(dirname "$0")/.." && pwd)"
V="$WS/tasks/$TASK/verdict-$REPO.json"
[ -f "$V" ] || { echo "❌ no existe $V"
  echo "   ↳ remediación: /review $TASK $REPO produce el veredicto primero"; exit 1; }

if ! command -v bd >/dev/null 2>&1; then
  echo "ℹ️  bd no está en PATH: no toco nada."
  echo "   ↳ brew install beads (capability del catálogo), o cierra los"
  echo "     non_blocking a mano; sin motor de beads el gate de archive solo avisa."
  exit 0
fi

sha12="$(jq -r '(.commit // "") | .[0:12]' "$V")"
n="$(jq '.non_blocking | length' "$V")"
created=0; failed=0; i=0
while [ "$i" -lt "$n" ]; do
  if jq -e ".non_blocking[$i] | type == \"object\" and ((.bead // \"\") != \"\")" "$V" >/dev/null; then
    i=$((i+1)); continue                      # ya tiene bead: idempotencia
  fi
  text="$(jq -r ".non_blocking[$i] | if type == \"object\" then (.text // \"\") else . end" "$V")"
  if [ -z "$text" ]; then i=$((i+1)); continue; fi
  title="$(printf '%s' "$text" | cut -c1-80)"
  body="$text

Origen: review de $TASK / $REPO (veredicto tasks/$TASK/verdict-$REPO.json, commit $sha12).
La remediación viene en el texto; NO bloquea el ship: es seguimiento."
  # El id se PIDE, no se adivina: `bd create --silent` es la interfaz de
  # scripting de bd (imprime el id y nada más) y su stderr va aparte, para que
  # ningún aviso pueda colarse como id. Un bd sin esa flag falla al PARSEARLA,
  # o sea antes de crear nada: reintentar sin ella no duplica beads. El formato
  # de la salida en prosa varía por versión, así que ese camino parsea tolerante
  # y fail-closed POR entrada (sin id extraíble no se reescribe).
  err="$(mktemp "$WS/tasks/$TASK/.verdict-beads-err.XXXXXX")"
  id=""; rc=0
  if out="$(bd create "$title" -d "$body" --silent 2>"$err")"; then
    id="$(bead_id "$out")"
    # sin id, el stderr apartado es justo la pista que necesita el humano
    [ -n "$id" ] || out="$out $(cat "$err" 2>/dev/null || true)"
  else
    # el rechazo de la flag se busca en los DOS canales: dónde lo escribe cada
    # versión de bd es exactamente la clase de detalle que no conviene suponer
    diag="$(cat "$err" 2>/dev/null || true)"
    if printf '%s\n%s\n' "$out" "$diag" | grep -qiE 'unknown (flag|shorthand)|not defined'; then
      if out="$(bd create "$title" -d "$body" 2>&1)"; then
        id="$(bead_id "$out")"
      else rc=1; fi
    else
      out="$diag"; rc=1
    fi
  fi
  rm -f "$err"
  if [ "$rc" -eq 0 ]; then
    if [ -n "$id" ]; then
      tmp="$(mktemp "$WS/tasks/$TASK/.verdict-beads.XXXXXX")"
      jq --arg t "$text" --arg id "$id" \
        ".non_blocking[$i] = {text: \$t, bead: \$id}" "$V" > "$tmp" && mv "$tmp" "$V"
      echo "✅ bead $id ← ${title}"
      created=$((created+1))
    else
      echo "❌ no pude extraer el id del bead de la salida de bd: $out"
      failed=$((failed+1))
    fi
  else
    echo "❌ bd create falló: $out"
    failed=$((failed+1))
  fi
  i=$((i+1))
done

if [ -f "$WS/scripts/emit.sh" ] && [ "$created" -gt 0 ]; then
  bash "$WS/scripts/emit.sh" decision \
    "non_blocking → beads: $created creado(s) para $REPO" "" "$TASK" >/dev/null 2>&1 || true
fi
echo "── $created bead(s) creados, $failed fallo(s), $(jq '[.non_blocking[] | select(type == "object" and ((.bead // "") != ""))] | length' "$V") con bead en total"
[ "$failed" -eq 0 ] || exit 1
