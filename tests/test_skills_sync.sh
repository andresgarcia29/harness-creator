#!/usr/bin/env bash
# test_skills_sync.sh: la capa compartida de skills contra el código REAL del
# template. Protege el contrato de las tres capas: instala con procedencia
# (.managed), la local SIEMPRE gana en colisión, el prune solo borra lo
# marcado, y --check reporta drift sin tocar nada.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

mkdir -p "$WS/scripts" "$WS/.claude/skills"
cp "$ROOT/templates/scripts/skills-sync.sh" "$WS/scripts/"

git_id() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# repo fuente con dos skills
SRC="$WS/fuentes/corvux-skills"
mkdir -p "$SRC/deploy-x" "$SRC/debug-y"
printf -- '---\nname: deploy-x\ndescription: d\n---\nv1\n' > "$SRC/deploy-x/SKILL.md"
printf -- '---\nname: debug-y\ndescription: d\n---\nv1\n' > "$SRC/debug-y/SKILL.md"
git init -q -b main "$SRC" && git_id "$SRC" add -A && git_id "$SRC" commit -qm v1

cat > "$WS/skills.yaml" <<EOF
sources:
  - $SRC all main
EOF

echo "── skills-sync: tres capas con procedencia"

out="$(bash "$WS/scripts/skills-sync.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" "sync inicial en verde"
assert_file "$WS/.claude/skills/deploy-x/SKILL.md" "instala deploy-x"
assert_file "$WS/.claude/skills/debug-y/.managed" "marca .managed = procedencia"
assert_contains "$(cat "$WS/.claude/skills/deploy-x/.managed")" "$SRC@main#" "la marca trae repo, ref y sha"

out="$(bash "$WS/scripts/skills-sync.sh" 2>&1)"
assert_contains "$out" "deploy-x: al día" "re-sync idempotente"

# la fuente avanza → --check reporta drift SIN tocar, sync actualiza
printf 'v2\n' >> "$SRC/deploy-x/SKILL.md"
git_id "$SRC" add -A && git_id "$SRC" commit -qm v2
out="$(bash "$WS/scripts/skills-sync.sh" --check 2>&1)"; rc=$?
assert_eq 1 "$rc" "--check con drift: exit 1"
grep -q "v2" "$WS/.claude/skills/deploy-x/SKILL.md" && fail "--check tocó la skill" || pass "--check no toca nada"
bash "$WS/scripts/skills-sync.sh" >/dev/null 2>&1
grep -q "v2" "$WS/.claude/skills/deploy-x/SKILL.md" && pass "sync trae la v2" || fail "sync no actualizó"

# skill LOCAL (sin marca): colisión = gana la local, error explícito
mkdir -p "$SRC/mi-local" && printf -- '---\nname: mi-local\n---\nremota\n' > "$SRC/mi-local/SKILL.md"
git_id "$SRC" add -A && git_id "$SRC" commit -qm agrega-mi-local
mkdir -p "$WS/.claude/skills/mi-local" && printf 'MIA\n' > "$WS/.claude/skills/mi-local/SKILL.md"
out="$(bash "$WS/scripts/skills-sync.sh" 2>&1)"; rc=$?
assert_eq 1 "$rc" "colisión con local: exit 1"
assert_contains "$out" "la local gana" "el choque se explica"
assert_contains "$(cat "$WS/.claude/skills/mi-local/SKILL.md")" "MIA" "la local quedó intacta"

# prune: la fuente sale del yaml → solo lo marcado se desinstala
printf 'sources:\n' > "$WS/skills.yaml"
out="$(bash "$WS/scripts/skills-sync.sh" 2>&1)"
assert_no_file "$WS/.claude/skills/deploy-x" "compartida desinstalada al salir del yaml"
assert_file "$WS/.claude/skills/mi-local/SKILL.md" "la local sobrevive al prune"

# sin skills.yaml: no-op amable
rm "$WS/skills.yaml"
bash "$WS/scripts/skills-sync.sh" >/dev/null 2>&1 && pass "sin skills.yaml: exit 0" || fail "sin yaml no debe fallar"

t_done
