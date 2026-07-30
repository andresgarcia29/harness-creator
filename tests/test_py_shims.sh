#!/usr/bin/env bash
# test_py_shims.sh — py.sh RE-APUNTA los shims viejos (COR-333).
#
# El bug: la rama "el destino ya resuelve → recurse, sin shim" se cumplía cuando
# el symlink VIEJO seguía resolviendo (típicamente al clon canónico de repos/) y
# recursaba SIN re-apuntar. Con TASK el índice pone el worktree primero, pero ese
# ganador nunca se aplicaba al shim ya plantado. Caso de campo: el path-dep
# escapaba del worktree a un directorio compartido entre tareas, el repo compiló
# y testeó contra repos/ en silencio, y un símbolo agregado en el worktree "no
# existía". Regla declarada, igual que al plantarlo: ÚLTIMO EN CORRER GANA.
#
# `uv` se stubbea (fakebin) para que py.sh llegue al planteo de shims sin exigir
# el toolchain real: los shims se plantan ANTES del `exec uv`.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

echo "── py.sh: el shim viejo se re-apunta al ganador del índice"

PY="$WS/py"; mkdir -p "$PY/scripts" "$PY/fakebin"
cp "$ROOT/templates/scripts/py.sh" "$PY/scripts/py.sh"
printf '#!/bin/sh\nexit 0\n' > "$PY/fakebin/uv"; chmod +x "$PY/fakebin/uv"

run_py() {  # run_py <repo> [task]
  ( cd "$PY" && PATH="$PY/fakebin:$PATH" bash "$PY/scripts/py.sh" '--version' "$1" "${2:-}" 2>&1 )
}

# ── fixtures: el canónico (repos/) y la copia de la tarea (worktrees/T1/) ──
# repos/libpkg trae .git a propósito: es un clon canónico. Si el veto de "repo
# hijo" se preguntara por $resolved (canonizado A TRAVÉS del symlink) en vez de
# por el directorio que CONTIENE el link, este .git vetaría el re-apuntado
# siempre y el bug seguiría vivo con el gate en verde.
mkdir -p "$PY/repos/libpkg/.git" "$PY/repos/svc/.git"
cat > "$PY/repos/libpkg/pyproject.toml" <<'EOF'
[project]
name = "libpkg"
version = "0.1.0"
EOF
touch "$PY/repos/libpkg/SOLO-EN-EL-CANONICO"
cat > "$PY/repos/svc/pyproject.toml" <<'EOF'
[project]
name = "svc"
version = "0.1.0"

[tool.uv.sources]
libpkg = { path = "../packages/libpkg" }
EOF

mkdir -p "$PY/worktrees/T1/svc" "$PY/worktrees/T1/libpkg"
: > "$PY/worktrees/T1/svc/.git"            # worktree real: .git es un ARCHIVO
cp "$PY/repos/svc/pyproject.toml" "$PY/worktrees/T1/svc/pyproject.toml"
cat > "$PY/worktrees/T1/libpkg/pyproject.toml" <<'EOF'
[project]
name = "libpkg"
version = "0.1.0"
EOF
touch "$PY/worktrees/T1/libpkg/SOLO-EN-EL-WORKTREE"   # el símbolo que "no existía"

# el shim VIEJO, plantado A MANO apuntando al canónico (lo que dejó la corrida
# anterior). Resuelve, así que la rama vieja recursaba y lo dejaba intacto.
mkdir -p "$PY/worktrees/T1/packages"
ln -sfn "../../../repos/libpkg" "$PY/worktrees/T1/packages/libpkg"

out="$(run_py svc T1)"
LINK="$PY/worktrees/T1/packages/libpkg"
assert_eq "../libpkg" "$(readlink "$LINK" 2>/dev/null)" \
  "con TASK: el shim viejo se re-apunta al worktree de la tarea"
[ -f "$LINK/SOLO-EN-EL-WORKTREE" ] \
  && pass "y resuelve a las ediciones VIVAS del worktree (no al clon canónico)" \
  || fail "el shim sigue resolviendo fuera del worktree de la tarea"
assert_contains "$out" "re-apuntado" "y lo declara en la lista de shims"

echo "── contra-mitades"

# sin TASK, el índice sólo ve repos/: el mismo mecanismo devuelve el shim al
# canónico. La regla es simétrica (último en correr gana), no un trinquete.
mkdir -p "$PY/repos/packages"
ln -sfn "../../worktrees/T1/libpkg" "$PY/repos/packages/libpkg"
out="$(run_py svc)"
CLINK="$PY/repos/packages/libpkg"
assert_eq "../libpkg" "$(readlink "$CLINK" 2>/dev/null)" \
  "sin TASK: el shim vuelve a apuntar al canónico"
[ -f "$CLINK/SOLO-EN-EL-CANONICO" ] \
  && pass "y resuelve al clon canónico" \
  || fail "el shim sin TASK no resuelve al canónico"
assert_contains "$out" "re-apuntado" "y también lo declara"

# un symlink DENTRO de un repo hijo NO se toca, aunque el índice elija otro dir:
# escribir en el árbol de un repo hijo está prohibido, re-apuntar incluido.
mkdir -p "$PY/repos/dep" "$PY/worktrees/T1/dep" "$PY/worktrees/T1/app3/vendored"
cat > "$PY/repos/dep/pyproject.toml" <<'EOF'
[project]
name = "dep"
version = "0.1.0"
EOF
cat > "$PY/worktrees/T1/dep/pyproject.toml" <<'EOF'
[project]
name = "dep"
version = "0.1.0"
EOF
: > "$PY/worktrees/T1/app3/.git"
cat > "$PY/worktrees/T1/app3/pyproject.toml" <<'EOF'
[project]
name = "app3"
version = "0.1.0"

[tool.uv.sources]
dep = { path = "./vendored/dep" }
EOF
ln -sfn "../../../../repos/dep" "$PY/worktrees/T1/app3/vendored/dep"
run_py app3 T1 >/dev/null 2>&1
assert_eq "../../../../repos/dep" "$(readlink "$PY/worktrees/T1/app3/vendored/dep" 2>/dev/null)" \
  "un symlink DENTRO de un repo hijo no se re-apunta (ni siquiera con otro ganador en el índice)"

t_done
