# harness-janitor — el harness no se pudre: worktrees/ramas/locks
# huérfanos (limpieza determinista aquí mismo) + destilación de memoria
# (lo único que requiere agente).
JOB_NAME=harness-janitor
JOB_TIER=cheap
JOB_TOOLS="Read,Grep,Glob,Bash(git *),Write,Edit"

detect() {
  : > "$FINDINGS"
  # limpieza determinista (no requiere agente): la hace el propio detector
  for r in repos/*/; do
    [ -d "$r/.git" ] || continue
    git -C "$r" worktree prune --expire 7.days.ago 2>/dev/null || true
    # ramas task/* mergeadas a main
    git -C "$r" branch --merged main 2>/dev/null | grep -E '^\s+(task|bot)/' | while read -r b; do
      git -C "$r" branch -d "$b" 2>/dev/null && echo "limpiado: rama $b de $(basename "$r")" >> "$FINDINGS.log"
    done
  done
  # locks huérfanos de ship.sh
  for l in locks/*.lock.d; do
    [ -d "$l" ] || continue
    # `kill -0` falla también con pid ilegible y con EPERM (el proceso EXISTE
    # pero es de otro usuario). Leer los tres casos como "muerto" hacía que
    # este job borrara locks VIVOS, y un lock de ship vivo que desaparece son
    # dos ships concurrentes peleando el push al mismo repo. Ante la duda no
    # se toca: un lock de más lo limpia el humano; un lock de menos corrompe
    # main.
    lpid="$(cat "$l/pid" 2>/dev/null)"
    case "$lpid" in
      ''|*[!0-9]*)
        echo "conservado: $l tiene pid ilegible ('$lpid'), no puedo saber si vive" >> "$FINDINGS.log" ;;
      *)
        if kill -0 "$lpid" 2>/dev/null; then
          : # vivo, no se toca
        elif kill -0 "$lpid" 2>&1 | grep -qiE 'permission|permitido|permiso'; then
          echo "conservado: $l lo sostiene el pid $lpid de otro usuario (vivo)" >> "$FINDINGS.log"
        else
          rm -rf "$l" && echo "limpiado: lock huérfano $l (pid $lpid inexistente)" >> "$FINDINGS.log"
        fi ;;
    esac
  done
  # dumps de quiet.sh >7 días
  find .cache/quiet -name "*.log" -mtime +7 -delete 2>/dev/null || true
  # el grafo de graphify no se pudre: refresh incremental si hay HEADs
  # nuevos (fail-open: sin graphify instalado no hace nada)
  [ -x scripts/graph-refresh.sh ] && bash scripts/graph-refresh.sh >> "$FINDINGS.log" 2>&1 || true
  # ¿la memoria episódica necesita destilación? (esto SÍ es del agente)
  local mem_lines=0
  [ -f ".claude/MEMORY.md" ] && mem_lines=$(wc -l < .claude/MEMORY.md | tr -d ' ')
  local stale_tasks; stale_tasks=$(find tasks -maxdepth 1 -type d -mtime +30 2>/dev/null | grep -v archive | wc -l | tr -d ' ')
  if [ "$mem_lines" -gt 150 ] || [ "$stale_tasks" -gt 5 ]; then
    { echo "memoria: MEMORY.md tiene $mem_lines líneas (tope sano ~150)"
      echo "tareas viejas sin archivar: $stale_tasks (corre /archive o ciérralas)"
      cat "$FINDINGS.log" 2>/dev/null; } > "$FINDINGS"
    rm -f "$FINDINGS.log"; return 10
  fi
  rm -f "$FINDINGS.log"; return 0
}

JOB_PROMPT='Eres el harness-janitor. La limpieza mecánica ya la hizo el
detector; tu trabajo es la DESTILACIÓN: (1) si MEMORY.md excede el
presupuesto, condensa entradas viejas en aprendizajes duraderos (mueve
lo maduro a candidatos de /promote, borra lo superado) hasta quedar
bajo 150 líneas; (2) tareas de tasks/ >30 días sin archivar: si su
ticket cerró, córreles el proceso de /archive; si quedaron a medias,
issue "tarea zombie <id>" con el estado. Commitea la memoria destilada
directo (es meta-repo). Nada de tocar repos/ ni specs.'
