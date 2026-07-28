#!/usr/bin/env bash
# guard-ws-scripts.sh — PreToolUse (Bash): `scripts/<x>.sh` relativo desde un
# worktree NO existe (los scripts del harness viven en la raíz del workspace).
#
# Caso de campo: la sesión quedó con cwd DENTRO de un worktree por un cd
# previo, y 6-8 comandos murieron con "bash: scripts/x.sh: No such file or
# directory", un round-trip perdido por cada uno. Ninguna variante de $0 en
# los scripts arregla esto: el fallo ocurre ANTES de que bash abra el archivo.
#
# BLOQUEA SOLO CUANDO SABE EL FIX: (a) el cwd efectivo cae dentro de un
# worktree, (b) el comando invoca scripts/<x>.(sh|py) relativo en posición de
# comando, (c) el worktree NO tiene ese script propio, y (d) el workspace SÍ
# lo tiene (doble existencia, no lista de nombres: un repo de usuario con su
# propio scripts/x.sh pasa, y un script que el harness no tiene también).
# Contrato Claude Code: exit 2 + stderr = bloquear. Sin jq → exit 0 (fail-open).
set -uo pipefail
input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
WS="${CLAUDE_PROJECT_DIR:-$PWD}"

# 1. sanitizar: mismo filtro que guard-build-slot (heredocs y comillas fuera)
sanitized="$(printf '%s\n' "$cmd" | awk '
  BEGIN { q = sprintf("%c", 39); skip = 0 }
  skip == 1 {
    t = $0; gsub(/^[[:space:]]+/, "", t)
    if (t == delim) skip = 0
    next
  }
  {
    line = $0
    if (match(line, "<<-?[[:space:]]*[\"" q "]?[A-Za-z_][A-Za-z0-9_]+")) {
      delim = substr(line, RSTART, RLENGTH)
      sub("^<<-?[[:space:]]*", "", delim)
      gsub("[\"" q "]", "", delim)
      skip = 1
      line = substr(line, 1, RSTART - 1)
    }
    gsub("\"[^\"]*\"", "", line)
    gsub(q "[^" q "]*" q, "", line)
    print line
  }
' 2>/dev/null)" || sanitized="$cmd"

# 2. cwd EFECTIVO: el del payload es el de la SESIÓN (documentado en
#    track-read.sh); un `cd <...>worktrees<...>` en el mismo comando manda.
eff="$cwd"
tgt="$(printf '%s\n' "$sanitized" \
  | sed -nE 's/.*(^|[;&|(])[[:space:]]*cd[[:space:]]+([^;&|[:space:]]*worktrees[^;&|[:space:]]*).*/\2/p' \
  | head -1)"
if [ -n "$tgt" ]; then
  case "$tgt" in /*) eff="$tgt" ;; *) eff="${cwd:-$WS}/$tgt" ;; esac
fi
case "$eff" in */worktrees/*) : ;; *) exit 0 ;; esac

# 3. ¿scripts/<x>.(sh|py) relativo en posición de comando?
m="$(printf '%s' "$sanitized" | grep -oE \
  '(^|[;&|(])[[:space:]]*((sudo|bash|sh|python3|python)[[:space:]]+)*(\./)?scripts/[A-Za-z0-9_.-]+\.(sh|py)' \
  | head -1 | grep -oE 'scripts/[A-Za-z0-9_.-]+\.(sh|py)' || true)"
[ -z "$m" ] && exit 0

# 4. doble existencia: propio del repo → legítimo; sin sustitución → no opino
[ -f "$eff/$m" ] && exit 0
[ -f "$WS/$m" ] || exit 0

echo "🚫 BLOQUEADO: '$m' no existe desde $eff (estás dentro de un worktree; los scripts del harness viven en la raíz del workspace)." >&2
echo "→ Usa la ruta absoluta del workspace, que funciona desde cualquier cwd:" >&2
echo "   bash \"\$CLAUDE_PROJECT_DIR/$m\" ...   (= bash $WS/$m ...)" >&2
exit 2
