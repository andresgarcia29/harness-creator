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
  # El formato de salida de bd create varía por versión: parseo tolerante y
  # fail-closed POR entrada (sin id extraíble no se reescribe: inventar un
  # bead sería peor que no tenerlo).
  if out="$(bd create "$title" -d "$body" 2>&1)"; then
    # || true: sin match, grep sale 1 y pipefail mataría el script mudo
    id="$(printf '%s' "$out" | grep -oE '[A-Za-z]+-[A-Za-z0-9]+' | head -1 || true)"
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
