#!/usr/bin/env bash
# test_gowork_shims.sh — el loop interno nativo (Ley 9) sobre FIXTURES sintéticos, sin
# toolchains reales instaladas:
#   A) gowork.sh: módulos Go falsos con un `replace` relativo ROTO (layout monorepo
#      inexistente) → el go.work generado trae `use (...)` con ambos módulos Y un
#      `replace <mod> vX => <dir>` VERSIONADO al módulo real. Valida el ARCHIVO (no
#      compila: `go` puede no estar en el runner).
#   B) py.sh: pyproject falsos con una path-dep ROTA → symlink shim al paquete real en
#      territorio del harness, y JAMÁS un shim dentro de un dir con .git (repo hijo).
#      `uv` se stubbea (fakebin) para no depender del toolchain real.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

echo "── loop nativo: gowork.sh + shims de py.sh"

# ══ A. gowork.sh: go.work con use + replace versionado ══════════════════════════
GA="$WS/gowork"; mkdir -p "$GA/scripts" "$GA/repos/shared" "$GA/repos/svc"
cp "$ROOT/templates/scripts/gowork.sh" "$GA/scripts/gowork.sh"

cat > "$GA/repos/shared/go.mod" <<'EOF'
module example.com/shared

go 1.21
EOF
# svc pide shared v1.2.3 pero su replace apunta a ../../pkg/shared (NO existe) — el layout
# monorepo que no está. gowork debe re-apuntarlo al shared canónico, VERSIONADO.
cat > "$GA/repos/svc/go.mod" <<'EOF'
module example.com/svc

go 1.22

require example.com/shared v1.2.3

replace example.com/shared => ../../pkg/shared
EOF

bash "$GA/scripts/gowork.sh" >/dev/null 2>&1 || true
GW="$GA/go.work"
assert_file "$GW" "gowork: genera go.work en la raíz"
content="$(cat "$GW" 2>/dev/null)"
assert_contains "$content" "use ("                 "gowork: emite bloque use ("
assert_contains "$content" "./repos/shared"        "gowork: incluye el módulo shared"
assert_contains "$content" "./repos/svc"           "gowork: incluye el módulo svc"
assert_contains "$content" "replace example.com/shared v1.2.3 => ./repos/shared" \
                                                    "gowork: replace VERSIONADO al canónico (use no alcanza)"
assert_contains "$content" "go 1.22"               "gowork: usa la mayor directiva go (1.22)"

# no-op limpio sin módulos Go
GB="$WS/nogow"; mkdir -p "$GB/scripts" "$GB/repos"
cp "$ROOT/templates/scripts/gowork.sh" "$GB/scripts/gowork.sh"
out2="$(bash "$GB/scripts/gowork.sh" 2>&1)" || true
assert_no_file "$GB/go.work"                        "gowork: sin módulos Go → no escribe go.work"
assert_contains "$out2" "sin módulos Go"            "gowork: no-op limpio anuncia que no aplica"

# ══ B. py.sh: shims de symlink para path-deps rotas ═════════════════════════════
PY="$WS/py"; mkdir -p "$PY/scripts" "$PY/fakebin"
cp "$ROOT/templates/scripts/py.sh" "$PY/scripts/py.sh"
# stub de uv: py.sh planta los shims ANTES de exec uv; el stub sólo cierra en verde.
printf '#!/bin/sh\nexit 0\n' > "$PY/fakebin/uv"; chmod +x "$PY/fakebin/uv"

# app (repo hijo con .git) pide libcore por ../pkg/libcore (ROTO) — escapa fuera de app,
# a repos/pkg/ (territorio del harness, sin .git) → shim permitido al repos/libcore real.
mkdir -p "$PY/repos/app/.git" "$PY/repos/libcore"
cat > "$PY/repos/app/pyproject.toml" <<'EOF'
[project]
name = "app"
version = "0.1.0"

[tool.uv.sources]
libcore = { path = "../pkg/libcore" }
EOF
cat > "$PY/repos/libcore/pyproject.toml" <<'EOF'
[project]
name = "libcore"
version = "0.1.0"
EOF

( cd "$PY" && PATH="$PY/fakebin:$PATH" bash "$PY/scripts/py.sh" '--version' app ) >/dev/null 2>&1 || true
LINK="$PY/repos/pkg/libcore"
if [ -L "$LINK" ]; then
  pass "py.sh: planta un symlink shim para la path-dep rota (repos/pkg/libcore)"
  tgt="$(readlink "$LINK")"
  assert_contains "$tgt" "libcore"                  "py.sh: el shim apunta (relativo) al paquete real"
  [ -f "$LINK/pyproject.toml" ] && pass "py.sh: el shim resuelve a un pyproject real" \
                                || fail "py.sh: el shim no resuelve al paquete"
else
  fail "py.sh: no creó el shim esperado en $LINK"
fi

# app2 (repo hijo con .git) pide dep por ./vendored/dep — CAERÍA DENTRO del .git de app2.
# Aunque 'dep' existe en el índice, el shim debe RECHAZARSE (jamás escribir en un repo hijo).
mkdir -p "$PY/repos/app2/.git" "$PY/repos/dep"
cat > "$PY/repos/app2/pyproject.toml" <<'EOF'
[project]
name = "app2"
version = "0.1.0"

[tool.uv.sources]
dep = { path = "./vendored/dep" }
EOF
cat > "$PY/repos/dep/pyproject.toml" <<'EOF'
[project]
name = "dep"
version = "0.1.0"
EOF

( cd "$PY" && PATH="$PY/fakebin:$PATH" bash "$PY/scripts/py.sh" '--version' app2 ) >/dev/null 2>&1 || true
assert_no_file "$PY/repos/app2/vendored/dep"        "py.sh: NUNCA planta un shim dentro de un dir con .git (repo hijo)"

# ══ C. el árbol clavado del reviewer (.review-*) es INVISIBLE para los escáneres ══
# verdict-scaffold clava worktrees/<task>/.review-<repo> al commit sellado: mismos
# module-paths y paquetes que el árbol vivo. Sin la poda, gowork podía apuntar el
# loop nativo al commit sellado (ganador por orden de readdir: no determinista,
# demostrado en campo) y un shim de py.sh podía resolver al pin. Los decoys son
# deterministas a propósito: el módulo/paquete existe SOLO en el pin, así que con
# la poda desaparece del resultado y sin ella aparece siempre.
mkdir -p "$GA/repos/.review-decoy"
cat > "$GA/repos/.review-decoy/go.mod" <<'EOF'
module example.com/pinned-decoy

go 1.22
EOF
bash "$GA/scripts/gowork.sh" >/dev/null 2>&1 || true
content="$(cat "$GW" 2>/dev/null)"
assert_not_contains "$content" ".review-decoy"      "gowork: el árbol clavado del reviewer NO entra al go.work"
assert_contains "$content" "./repos/svc"            "gowork: y los módulos vivos siguen adentro"

mkdir -p "$PY/repos/.review-pin" "$PY/repos/app3/.git"
cat > "$PY/repos/.review-pin/pyproject.toml" <<'EOF'
[project]
name = "pinned"
version = "0.1.0"
EOF
cat > "$PY/repos/app3/pyproject.toml" <<'EOF'
[project]
name = "app3"
version = "0.1.0"

[tool.uv.sources]
pinned = { path = "../pkg/pinned" }
EOF
( cd "$PY" && PATH="$PY/fakebin:$PATH" bash "$PY/scripts/py.sh" '--version' app3 ) >/dev/null 2>&1 || true
assert_no_file "$PY/repos/pkg/pinned"               "py.sh: un paquete que solo vive en el pin del reviewer no gana shim"

# ══ D. …y por eso el pin se lleva su PROPIO go.work ═════════════════════════════
# La poda de C es correcta y deja un hueco: dentro del pin, `go` no encuentra
# ningún módulo del go.work de la tarea y muere con "directory prefix does not
# contain modules". La remediación natural (`go work use .`) reescribe el archivo
# que el QA usa sobre el árbol VIVO, y el segundo en correr le pisa el `use` al
# primero. Reviewer y QA corren en PARALELO por diseño, así que la carrera es la
# norma: medido en campo como un build rojo por una razón que no era el código.
echo
echo "── el árbol clavado del reviewer y el worktree vivo no comparten go.work"
GD="$WS/goworkpin"
mkdir -p "$GD/scripts" "$GD/repos/shared" \
         "$GD/worktrees/T1/svc" "$GD/worktrees/T1/otro" "$GD/worktrees/T1/.review-svc"
cp "$ROOT/templates/scripts/gowork.sh" "$GD/scripts/gowork.sh"
printf 'module example.com/shared\n\ngo 1.21\n' > "$GD/repos/shared/go.mod"
printf 'module example.com/svc\n\ngo 1.22\n'    > "$GD/worktrees/T1/svc/go.mod"
printf 'module example.com/otro\n\ngo 1.22\n'   > "$GD/worktrees/T1/otro/go.mod"
# el pin: MISMO module-path que el vivo (es el mismo repo, clavado a un commit)
printf 'module example.com/svc\n\ngo 1.22\n'    > "$GD/worktrees/T1/.review-svc/go.mod"

bash "$GD/scripts/gowork.sh" T1 >/dev/null 2>&1 || true
GWT="$GD/worktrees/T1/go.work"
assert_file "$GWT" "gowork <task>: genera el go.work de la tarea"
vivo_antes="$(cat "$GWT")"
assert_contains "$vivo_antes" "./svc"              "el go.work de la tarea apunta al worktree VIVO"
assert_not_contains "$vivo_antes" ".review-svc"    "y nunca al pin (module-path duplicado: go.work lo prohíbe)"

out_pin="$(bash "$GD/scripts/gowork.sh" T1 svc 2>&1)" || true
GWP="$GD/worktrees/T1/.review-svc/go.work"
assert_file "$GWP" "gowork <task> <repo>: el pin gana SU PROPIO go.work"
assert_contains "$out_pin" "árbol clavado"         "y la salida dice de cuál de los dos habla"
pin_content="$(cat "$GWP")"
assert_contains "$pin_content" "	."                "el pin se incluye a sí mismo (use .)"
assert_not_contains "$pin_content" "../svc"        "y NO al árbol vivo: adentro manda el commit sellado"
assert_contains "$pin_content" "../otro"           "los otros repos vivos de la tarea sí entran (son el mismo cambio)"
assert_contains "$pin_content" "repos/shared"      "con el fallback al canónico de siempre"

# LA regresión de COR-720: generar uno NO toca al otro, en ningún orden.
assert_eq "$vivo_antes" "$(cat "$GWT")" "generar el del pin no le pisa el 'use' al del QA"
bash "$GD/scripts/gowork.sh" T1 >/dev/null 2>&1 || true
assert_eq "$pin_content" "$(cat "$GWP")" "y regenerar el de la tarea no le pisa el 'use' al del reviewer"

out_np="$(bash "$GD/scripts/gowork.sh" T1 nopin 2>&1)"; rc_np=$?
assert_eq 1 "$rc_np" "pin inexistente: exit 1, no un go.work en un dir inventado"
assert_contains "$out_np" "verdict-scaffold.sh" "con la remediación exacta (quién clava el pin)"

t_done
