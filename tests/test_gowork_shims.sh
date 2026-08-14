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

# ── modo --base: las rutas del go.work tienen que RESOLVER de verdad ──────────
# Los `use` son relativos al archivo y el kernel resuelve cada `..` sobre la ruta
# REAL. El arbol base del gate muerde nace de `mktemp -d`, o sea bajo /tmp o
# $TMPDIR, y en macOS los dos son symlinks (/tmp → /private/tmp): con la ruta
# LOGICA el calculo se queda un nivel corto y aterriza en /private/<algo> que no
# existe. Sintoma en campo: `go: cannot load module ... listed in go.work file`
# en TODO arbol base, o sea gate_test_muerde ciego en los seis servicios Go de
# una plataforma, en cada corrida. La asercion NO mira el texto: comprueba que
# cada ruta exista desde donde el go.work vive, que es lo que `go` hace.
# El symlink se arma a mano porque es lo que hay que reproducir: una ruta
# LOGICA mas corta que la real (/var → /private/var suma un nivel, /tmp igual).
mkdir -p "$WS/hondo/anidado/real/base/svc"
ln -s "$WS/hondo/anidado/real" "$WS/corto"
BASE="$WS/corto/base"
cp "$GA/repos/svc/go.mod" "$BASE/svc/go.mod"
bash "$GA/scripts/gowork.sh" --base "$BASE" >/dev/null 2>&1 || true
assert_file "$BASE/go.work" "gowork --base: escribe el go.work en el arbol dado"
rutas_rotas=""
for ruta in $(awk '/^use \(/{u=1;next} u&&/^\)/{u=0;next} u{gsub(/[ \t]/,"");print}
                   /^replace /{print $NF}' "$BASE/go.work"); do
  # [ -d ] pregunta al KERNEL, que es quien resuelve los `..` como lo hace `go`.
  # Un `cd` de bash es LOGICO y no reproduce el defecto: por eso la asercion no
  # puede escribirse con cd.
  [ -d "$BASE/$ruta" ] || rutas_rotas="$rutas_rotas $ruta"
done
[ -z "$rutas_rotas" ] \
  && pass "gowork --base: todas las rutas resuelven desde el arbol base" \
  || fail "gowork --base: rutas que no resuelven:$rutas_rotas (go dira 'cannot load module')"
rm -rf "$WS/hondo" "$WS/corto"

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

# ══ E. el ÁRBOL DE UN NODO del DAG: mismo defecto, misma cura (#152) ════════════
# Con `dag.json` schema 2, N tareas del mismo repo corren en paralelo, cada una
# en `worktrees/<task>/<repo>@<Tn>`. Los hermanos y el árbol base comparten
# module-path (son el mismo repo), así que colapsaban a UNA entrada y el ganador
# lo decidía readdir. Medido en campo: NINGUNO de los dos árboles de nodo entró
# al go.work de la tarea, que nombraba el BASE. El implementer del nodo corría
# `go test` contra código ajeno: el falso verde que #43 y #75 ya habían cerrado
# para gate_test_muerde, y justo en el camino que smart.md recomienda por rápido.
echo
echo "── el árbol de un nodo del DAG y el árbol base no comparten go.work (#152)"
mkdir -p "$GD/worktrees/T1/svc@T1" "$GD/worktrees/T1/svc@T2"
printf 'module example.com/svc\n\ngo 1.22\n' > "$GD/worktrees/T1/svc@T1/go.mod"
printf 'module example.com/svc\n\ngo 1.22\n' > "$GD/worktrees/T1/svc@T2/go.mod"

bash "$GD/scripts/gowork.sh" T1 >/dev/null 2>&1 || true
tarea_con_nodos="$(cat "$GWT")"
assert_contains "$tarea_con_nodos" "./svc"          "el go.work de la tarea sigue apuntando al árbol BASE…"
assert_not_contains "$tarea_con_nodos" "svc@T1"     "…y no a un árbol de nodo (module-path duplicado)"
assert_not_contains "$tarea_con_nodos" "svc@T2"     "…ni al otro: el ganador dejó de decidirlo readdir"

out_n1="$(bash "$GD/scripts/gowork.sh" T1 svc@T1 2>&1)" || true
GWN1="$GD/worktrees/T1/svc@T1/go.work"
assert_file "$GWN1" "gowork <task> <repo>@<Tn>: el nodo gana SU PROPIO go.work"
assert_contains "$out_n1" "nodo T1"                 "y la salida dice de qué árbol habla"
n1="$(cat "$GWN1")"
assert_contains "$n1" "	."                          "el nodo se incluye a sí mismo (use .)"
assert_not_contains "$n1" "../svc"$'\n'             "y NO al árbol base: adentro manda el código del nodo"
assert_not_contains "$n1" "svc@T2"                  "ni al árbol del hermano"
assert_contains "$n1" "../otro"                     "los otros repos vivos de la tarea sí entran"
assert_contains "$n1" "repos/shared"                "con el fallback al canónico de siempre"

# Misma regresión que COR-720, ahora entre hermanos: generar uno no toca al otro.
bash "$GD/scripts/gowork.sh" T1 svc@T2 >/dev/null 2>&1 || true
assert_eq "$n1" "$(cat "$GWN1")" "generar el go.work de un nodo no le pisa el 'use' al hermano"
bash "$GD/scripts/gowork.sh" T1 >/dev/null 2>&1 || true
assert_eq "$n1" "$(cat "$GWN1")" "y regenerar el de la tarea tampoco"

out_nn="$(bash "$GD/scripts/gowork.sh" T1 svc@T9 2>&1)"; rc_nn=$?
assert_eq 1 "$rc_nn" "árbol de nodo inexistente: exit 1, no un go.work en un dir inventado"
assert_contains "$out_nn" "worktree-task.sh --node" "con la remediación exacta (quién crea el árbol)"
out_ni="$(bash "$GD/scripts/gowork.sh" T1 'svc@../fuera' 2>&1)"; rc_ni=$?
assert_eq 1 "$rc_ni" "nodo con charset inválido: exit 1 (es un componente de RUTA)"
assert_contains "$out_ni" "nodo inválido"           "y lo dice como lo que es"


echo
echo "── gowork.sh --base: un go.work para un arbol FUERA del workspace (#75)"
# gate_test_muerde levanta el arbol BASE en un worktree temporal bajo mktemp, o
# sea fuera del workspace: no hay go.work alcanzable subiendo desde el cwd, el
# `replace ... => ../../pkg` no resuelve, y el paquete ni compila. El gate
# declaraba el tramo sin poder mirarlo, y los SEIS servicios Go de la plataforma
# usan ese layout, o sea que el gate mas caro del precheck no verificaba nada en
# ninguno.
GB="$WS/gobase"; mkdir -p "$GB/scripts" "$GB/repos/pkg"
cp "$ROOT/templates/scripts/gowork.sh" "$GB/scripts/gowork.sh"
cat > "$GB/repos/pkg/go.mod" <<'EOF'
module example.com/pkg

go 1.21
EOF
# El arbol base vive FUERA del workspace, como el worktree temporal del gate.
BASE="$WS/arbol-base"; mkdir -p "$BASE"
cat > "$BASE/go.mod" <<'EOF'
module example.com/svcbase

go 1.22

require example.com/pkg v0.0.0

replace example.com/pkg => ../../pkg
EOF

out_b="$(bash "$GB/scripts/gowork.sh" --base "$BASE" 2>&1)"; rc_b=$?
assert_eq 0 "$rc_b" "--base: genera sin morir (antes ni parseaba el flag)"
assert_file "$BASE/go.work" "--base: el go.work nace DENTRO del arbol dado, no en el workspace"
gb_content="$(cat "$BASE/go.work" 2>/dev/null || true)"
assert_contains "$gb_content" "example.com/pkg" "y resuelve el replace roto contra repos/ canonico"
assert_contains "$gb_content" "replace example.com/pkg v0.0.0 =>" "con el replace VERSIONADO (el mismo que el loop nativo)"
assert_contains "$gb_content" "use (" "y declara los modulos con use"
assert_no_file "$GB/go.work" "y NO escribe el go.work de la raiz del workspace"

# Las rutas tienen que RESOLVER desde el arbol base: un go.work con un replace
# que apunta a la nada no arregla nada, solo cambia el mensaje de error.
tgt="$(awk '/^replace example.com\/pkg/{print $NF}' "$BASE/go.work")"
resuelto="$(cd "$BASE" && cd "$tgt" 2>/dev/null && pwd || true)"
[ "$resuelto" = "$(cd "$GB/repos/pkg" && pwd)" ] \
  && pass "--base: la ruta del replace resuelve de verdad desde el arbol base" \
  || fail "--base: el replace apunta a '$tgt', que no resuelve a repos/pkg"

# Higiene del flag: una ruta relativa o inexistente se rechaza, no se inventa.
bash "$GB/scripts/gowork.sh" --base "relativo/no" >/dev/null 2>&1; rc_rel=$?
assert_eq 1 "$rc_rel" "--base con ruta relativa: exit 1 (no adivina desde donde)"
bash "$GB/scripts/gowork.sh" --base "$WS/no-existe" >/dev/null 2>&1; rc_ne=$?
assert_eq 1 "$rc_ne" "--base con dir inexistente: exit 1"
bash "$GB/scripts/gowork.sh" --base >/dev/null 2>&1; rc_sd=$?
assert_eq 1 "$rc_sd" "--base sin argumento: exit 1"

t_done
