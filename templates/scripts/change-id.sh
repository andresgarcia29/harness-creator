#!/usr/bin/env bash
# change-id.sh: la identidad de UN CAMBIO, estable a través de rebases.
#
# POR QUÉ EXISTE: el veredicto del reviewer es un juicio sobre un DIFF, pero
# se sellaba contra un SHA. Con varias personas pusheando al mismo main, el
# rebase de ship.sh reescribe los SHA sin tocar el contenido del cambio, y
# todo el trabajo de review y QA se invalidaba por algo que el reviewer nunca
# miró. Medido: con 10 workspaces contra el mismo trunk, esa invalidación es
# el caso normal, no la excepción.
#
# Esto responde "¿sigue siendo el MISMO cambio?" sin preguntarle al SHA.
#
# ── POR QUÉ --verbatim, Y NO patch-id A SECAS ─────────────────────────
# `git patch-id` por defecto IGNORA el whitespace, incluida la indentación.
# En Python, YAML y Makefiles la indentación ES semántica, así que sin
# --verbatim un implementer podría re-indentar DESPUÉS del review y conservar
# el `pass`. Reproducido antes de escribir esto:
#
#   default : c1382a2abde037bf...  ==  c1382a2abde037bf...   (2 vs 4 espacios)
#   verbatim: 27276f45959e112f...  !=  2de71230fb9d5fb2...
#
# Un harness cuyo diseño entero es anti-manipulación no puede anclar su
# veredicto a un hash ciego al whitespace. --verbatim existe desde git 2.39;
# más abajo hay un fallback que NO es ciego al whitespace tampoco.
#
# ── QUÉ SÍ Y QUÉ NO PROMETE ───────────────────────────────────────────
# SÍ: si el id coincide, el texto del cambio (incluido su whitespace y sus
#     líneas de contexto) es idéntico al que el reviewer juzgó.
# NO: no promete que el RESULTADO DEL MERGE sea equivalente. Un commit ajeno
#     puede renombrar un símbolo que tu diff usa sin tocar tus líneas: el id
#     no cambia y el merge no compila. Por eso el id habilita reusar el
#     JUICIO, jamás la PRUEBA: ship.sh re-corre la suite sobre el árbol
#     integrado y sella evidencia FRESCA (evidence.py --require-fresh-kind).
#     Las dos afirmaciones son distintas y el harness las trata distinto.
#
# Propiedad deseable que sale gratis: el diff lleva ±3 líneas de contexto, así
# que si un commit ajeno toca líneas ADYACENTES a las tuyas, el id cambia solo
# y la tarea cae a re-review. La interferencia textual cercana es fail-closed
# sin código extra.
#
# Uso: change-id.sh <worktree> [base-ref]
#   base-ref default: la rama trunk resuelta por origin/HEAD (nunca "main"
#   cableado; ver la misma técnica en ship.sh y worktree-task.sh).
# Salida: un id hexadecimal en stdout. Exit 0 ok · 2 no se pudo calcular.
#
# Portabilidad: bash 3.2 (macOS), BSD userland.
set -u

WT="${1:?uso: change-id.sh <worktree> [base-ref]}"
[ -d "$WT" ] || { echo "❌ no existe el worktree $WT" >&2; exit 2; }

base_branch() {  # idéntico a ship.sh/worktree-task.sh: la trunk no siempre es main
  local b
  if [ -n "${HARNESS_BASE_BRANCH:-}" ]; then printf '%s' "$HARNESS_BASE_BRANCH"; return 0; fi
  b="$(git -C "$WT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -n "$b" ] || b=main
  printf '%s' "$b"
}
BASE_REF="${2:-$(base_branch)}"

git -C "$WT" rev-parse --verify --quiet "origin/$BASE_REF" >/dev/null 2>&1 || {
  echo "❌ no existe origin/$BASE_REF en $WT: sin base no hay cambio que identificar" >&2
  exit 2; }

# Tres puntos a propósito: es el diff contra el MERGE-BASE, o sea exactamente
# lo que el reviewer mira (`git diff origin/<base>...HEAD`, ver reviewer.md).
# Con dos puntos, el id incluiría los commits ajenos que aterrizaron en la base
# y cambiaría en cada movimiento de main, que es justo lo que esto evita.
# --full-index y -U3 fijos: el id no puede depender de la config del usuario
# (diff.algorithm, diff.context) o dos máquinas calcularían ids distintos para
# el mismo cambio, que es el bug que este archivo existe para no tener.
diff_text="$(git -C "$WT" -c diff.noprefix=false -c diff.algorithm=myers \
  diff --no-color --full-index --no-ext-diff -U3 -M "origin/$BASE_REF...HEAD" 2>/dev/null)"

# Un diff vacío es un hecho legítimo (nada que shippear), pero NO tiene
# identidad de cambio: devolver un id fijo dejaría que dos tareas vacías
# compartan veredicto. Se dice y se falla.
[ -n "$diff_text" ] || { echo "❌ el diff contra origin/$BASE_REF está vacío: no hay cambio que identificar" >&2; exit 2; }

if printf '' | git patch-id --verbatim >/dev/null 2>&1; then
  printf '%s\n' "$diff_text" | git patch-id --verbatim | cut -d' ' -f1
else
  # git < 2.39. NO se cae a `git patch-id` pelado: sería ciego al whitespace,
  # que es justo la propiedad que no podemos perder. Se hashea el diff con los
  # encabezados @@ normalizados, que es lo que --verbatim hace de fondo: tolera
  # corrimientos de línea sin tolerar cambios de contenido.
  sum="$(command -v shasum || command -v sha256sum)" || {
    echo "❌ sin git patch-id --verbatim (git <2.39) y sin shasum/sha256sum" >&2; exit 2; }
  case "$sum" in
    *sha256sum) printf '%s\n' "$diff_text" | sed 's/^@@ .*$/@@/' | sha256sum | cut -d' ' -f1 ;;
    *)          printf '%s\n' "$diff_text" | sed 's/^@@ .*$/@@/' | shasum -a 256 | cut -d' ' -f1 ;;
  esac
fi
