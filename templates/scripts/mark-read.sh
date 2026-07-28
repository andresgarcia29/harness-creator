#!/usr/bin/env bash
# mark-read.sh — registra en tasks/<id>/evidence.log que un artefacto se LEYÓ.
#
# POR QUÉ EXISTE: gate_evidence (ship.sh) intersecta lo CITADO por la
# compliance matrix con lo LEÍDO según evidence.log, y ese log lo alimenta el
# hook track-read.sh, que solo corre dentro de Claude Code. Caso de campo:
# operando el harness desde otro agente (AGENTS.md promete que se puede), el
# log no existía jamás y el gate era impasable; la única salida era editar el
# log a mano, que anula el gate. Este script es el camino legítimo (Ley 15):
# registra la lectura con el MISMO formato del hook, pero solo si el archivo
# existe de verdad bajo el workspace o bajo un worktree de la tarea. No es
# menos honesto que el hook (los dos registran una afirmación de lectura);
# es igual de determinista y deja el mismo rastro auditable.
#
# Uso: mark-read.sh <task-id> <ruta> [ruta...]
#   Las rutas aceptan sufijo ::caso, :NN o #metodo (se registra tal cual;
#   la existencia se comprueba sobre la base, igual que hace gate_evidence).
#   Relativas al workspace o al worktree de la tarea; absolutas bajo el WS.
# Exit: 0 si TODAS se registraron; 3 si alguna no existe (y se nombra).
set -u

WS="$(cd "$(dirname "$0")/.." && pwd)"

TASK="${1:-}"; [ -n "$TASK" ] || { echo "uso: mark-read.sh <task-id> <ruta> [ruta...]"; exit 2; }
shift
[ $# -gt 0 ] || { echo "uso: mark-read.sh <task-id> <ruta> [ruta...]"; exit 2; }
case "$TASK" in *[!A-Za-z0-9._-]*|'') echo "❌ task-id inválido: '$TASK'"; exit 2 ;; esac

LOG_DIR="$WS/tasks/$TASK"
mkdir -p "$LOG_DIR" || exit 2
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sid="cli-$(id -un 2>/dev/null || echo manual)"

rc=0
for art in "$@"; do
  # misma normalización que gate_evidence: el archivo es la base de la cita
  base="$(printf '%s' "$art" | sed -e 's/::.*$//' -e 's/#[A-Za-z_][A-Za-z0-9_]*$//' -e 's/:[0-9][0-9]*\(-[0-9][0-9]*\)*$//')"
  [ -n "$base" ] || base="$art"
  found=""
  case "$base" in
    /*) case "$base" in "$WS"/*) [ -e "$base" ] && found=1 ;; esac ;;
    *)
      [ -e "$WS/$base" ] && found=1
      if [ -z "$found" ]; then
        for wt in "$WS/worktrees/$TASK"/*/; do
          [ -d "$wt" ] || continue
          [ -e "$wt$base" ] && { found=1; break; }
        done
      fi
      ;;
  esac
  if [ -z "$found" ]; then
    echo "✗ NO existe (ni en el workspace ni en worktrees/$TASK/): $art"
    echo "  Este script registra lecturas de archivos REALES; registrar una ruta"
    echo "  inexistente es exactamente lo que gate_evidence existe para impedir."
    rc=3
    continue
  fi
  printf '%s\t%s\t%s\t%s\n' "$ts" "$sid" "read" "$art" >> "$LOG_DIR/evidence.log"
  echo "✓ registrado: $art"
done
exit "$rc"
