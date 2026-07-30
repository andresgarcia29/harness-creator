#!/usr/bin/env bash
# test_ci_gates.sh: los gates del harness corriendo en infra NEUTRAL.
#
# Hasta aca los gates corrian en la laptop del que pushea. Con un equipo, "los
# sistemas deterministas verifican" es cierto solo hasta la laptop menos
# actualizada: cualquiera puede editar su ship.sh local. El modo --ci mueve la
# verificacion a un runner que nadie controla desde su maquina, corriendo EL
# MISMO codigo: un workflow que reimplemente los gates se desincroniza en la
# primera version y entonces CI y local dicen cosas distintas del mismo commit.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

TMPL="$ROOT/templates/scripts/ship.sh.tmpl"
mkdir -p "$WS/plugin/scripts"
sed -e 's/{{LOOP_BUDGET}}/3/g' -e 's/{{FLOW}}/trunk/g' "$TMPL" > "$WS/plugin/scripts/ship.sh"
chmod +x "$WS/plugin/scripts/ship.sh"

mk_repo() {  # mk_repo <dir>: checkout PELADO, sin layout de workspace
  rm -rf "$1"; mkdir -p "$1"; cd "$1"
  git init -q .; git config user.email t@t; git config user.name t
  printf 'package main\n' > main.go 2>/dev/null
  echo base > app.txt; git add -A; git commit -qm base >/dev/null
  git update-ref refs/remotes/origin/main HEAD
  cd "$WS"
}
run_ci() { ( cd "$1" && bash "$WS/plugin/scripts/ship.sh" --ci demo 2>&1 ); }

echo "── corre sobre un checkout pelado, sin workspace"
mk_repo "$WS/r1"
( cd "$WS/r1"; echo x > f.txt; git add -A; git commit -qm feat >/dev/null )
out="$(run_ci "$WS/r1")"; rc=$?
assert_eq 0 "$rc" "checkout sin tasks/ ni repos/: los gates corren igual"
assert_contains "$out" "modo CI" "lo declara"
assert_contains "$out" "infra neutral" "y dice por que existe"

echo "── NO inventa artefactos del workspace"
assert_no_file "$WS/plugin/tasks" "no crea tasks/ en el checkout del harness"
assert_no_file "$WS/r1/tasks" "ni en el repo"
n="$(find "$WS" -name 'EV-*.json' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$n" "y NO sella evidencia: no hay veredicto que respaldar"

echo "── un gate rojo sigue siendo rojo (no se afloja por estar en CI)"
mk_repo "$WS/r2"
( cd "$WS/r2"; mkdir -p tests
  printf 'def test_a():\n    assert 1 == 1\n    assert 2 == 2\n' > tests/test_x.py
  git add -A; git commit -qm tests >/dev/null; git update-ref refs/remotes/origin/main HEAD
  printf 'def test_a():\n    assert 1 == 1\n' > tests/test_x.py
  git add -A; git commit -qm debilita >/dev/null )
out="$(run_ci "$WS/r2")"; rc=$?
assert_eq 3 "$rc" "test debilitado: bloquea tambien en CI"
assert_contains "$out" "DEBILITA" "nombrando la causa"

echo "── la declaracion puede venir por env (en CI no hay tasks/<id>/)"
printf '## MODIFIED Requirements\n- X-1: se ajusta tests/test_x.py\n' > "$WS/decl.md"
out="$( cd "$WS/r2" && HARNESS_DELTA_SPEC_FILE="$WS/decl.md" bash "$WS/plugin/scripts/ship.sh" --ci demo 2>&1 )"; rc=$?
assert_eq 0 "$rc" "declarado en el cuerpo del PR: pasa"
assert_contains "$out" "DECLARADOS" "y queda en el registro"

echo "── el workflow llama al MISMO codigo, no a una copia"
wf="$(cat "$ROOT/templates/ci/harness-gates.yml.tmpl")"
assert_contains "$wf" "ship.sh --ci" "el workflow invoca ship.sh, no reimplementa gates"
assert_contains "$wf" "merge_group" "y se engancha a la cola de merge"
assert_contains "$wf" "fetch-depth: 0" "con historia completa: un checkout superficial deja el diff vacio"
assert_contains "$wf" "HARNESS_DELTA_SPEC_FILE" "y pasa la declaracion del PR"
upd="$(cat "$ROOT/commands/harness-update.md")"
assert_contains "$upd" "Gates-en-CI" "el updater lo trata como paquete atado con ship.sh"

echo "── cadena de suministro: las actions van por SHA, nunca por tag"
# Un tag es un puntero MUTABLE. Quien pueda mover el v4 de una action corre su
# codigo dentro del runner que decide si un PR entra, con el token del repo, sin
# que cambie una linea de estos YAML. Esta es la trinchera mecanica: el dia que
# alguien escriba de nuevo @v4 (o el proximo @v5, que se ve igual de inofensivo)
# el test lo dice antes que el incidente.
USES='^[[:space:]]*(- )?uses:'
for f in .github/workflows/ci.yml .github/workflows/release.yml templates/ci/harness-gates.yml.tmpl; do
  movible="$(grep -n -E "$USES.*@v[0-9]" "$ROOT/$f")"
  assert_eq "" "$movible" "$f: ningun uses: apunta a un tag movible (@vN)"
  sin_sha="$(grep -n -E "$USES" "$ROOT/$f" | grep -v -E '@[0-9a-f]{40}')"
  assert_eq "" "$sin_sha" "$f: todo uses: lleva sha de 40"
  # El sha solo no dice QUE version es: sin el comentario, subirla a mano se
  # vuelve arqueologia y nadie la sube.
  sin_ver="$(grep -n -E "$USES" "$ROOT/$f" | grep -v -E '#[[:space:]]*v[0-9]+\.')"
  assert_eq "" "$sin_ver" "$f: y al lado la version legible (# vX.Y.Z)"
done

echo "── cadena de suministro: uv con version en la URL"
gates="$(cat "$ROOT/templates/ci/harness-gates.yml.tmpl")"
# /uv/install.sh baja el latest DE HOY: el mismo commit se verifica cada semana
# con otra toolchain, y un rojo nuevo no distingue "rompi algo" de "cambio uv".
assert_not_contains "$gates" "astral.sh/uv/install.sh" "la URL sin version no vuelve"
pineada="$(grep -E 'astral\.sh/uv/[0-9]+\.[0-9]+\.[0-9]+/install\.sh' "$ROOT/templates/ci/harness-gates.yml.tmpl")"
assert_contains "$pineada" "astral.sh/uv/" "el instalador de uv trae version explicita en la URL"

echo "── el binario del panel se verifica contra el sha256 del release"
# panel.sh bajaba harnessd y lo ejecutaba sin mirar QUE bajo: toda la cadena de
# suministro confiando en el transporte. El release publica SHA256SUMS, asi que
# se compara de verdad; y cuando no se puede comparar, se DICE (tercer estado),
# porque un "✓ instalado" que no verifico nada es peor que no verificar.
mkdir -p "$WS/ui" "$WS/bin"
cp "$ROOT/templates/ui/panel.sh" "$WS/ui/panel.sh"
# El fallback sin binario exec-ea el panel Python: este server.py de mentira lo
# hace observable sin traerse el real (ni su puerto, ni su red).
printf 'print("PANEL PYTHON")\n' > "$WS/ui/server.py"
# Y el abridor de browser se stubea: un test que abre Chrome no es hermetico.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/bin/xdg-open"
chmod +x "$WS/bin/xdg-open"

# gh de mentira: solo entiende `release download -p <patron> -D <dir>`.
# STUB_SUMS gobierna el unico eje que importa acá: ok | malo | ninguno.
cat > "$WS/bin/gh" <<'STUB'
#!/usr/bin/env bash
dir=""; pat=""
while [ $# -gt 0 ]; do
  case "$1" in
    -D) dir="$2"; shift 2 ;;
    -p) pat="$2"; shift 2 ;;
    *) shift ;;
  esac
done
sha_de() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; return 0; fi
  shasum -a 256 "$1" | awk '{print $1}'
}
if [ "$pat" = "SHA256SUMS" ]; then
  if [ "${STUB_SUMS:-ok}" = "ninguno" ]; then
    echo "gh: el release no publica un asset SHA256SUMS" >&2
    exit 1
  fi
  for f in "$dir"/harnessd-*; do
    s="$(sha_de "$f")"
    if [ "${STUB_SUMS:-ok}" = "malo" ]; then
      s="000000000000000000000000000000000000000000000000000000000000dead"
    fi
    printf '%s  %s\n' "$s" "$(basename "$f")"
  done > "$dir/SHA256SUMS"
  exit 0
fi
printf '#!/usr/bin/env bash\ncase "${1:-}" in version) echo 0.46.0 ;; run) echo "HARNESSD RUN" ;; esac\n' > "$dir/$pat"
chmod +x "$dir/$pat"
exit 0
STUB
chmod +x "$WS/bin/gh"

# El harness instalado por brew gana antes de llegar a la descarga: si la maquina
# del que corre el test lo tiene, el test probaria otra cosa. Por eso un PATH sin él.
NOHARNESS="$(t_path_without harness)"
run_panel() {  # run_panel <ok|malo|ninguno> → salida del panel
  rm -f "$WS/ui/harnessd"
  ( cd "$WS/ui" && STUB_SUMS="$1" PATH="$WS/bin:$NOHARNESS" bash "$WS/ui/panel.sh" 7999 2>&1 )
}

out="$(run_panel ok)"
assert_contains "$out" "sha256 verificado" "sha que coincide: lo dice, no lo da por sentado"
assert_contains "$out" "HARNESSD RUN" "y recien ahi ejecuta el binario"

out="$(run_panel malo)"
assert_contains "$out" "NO coincide" "sha distinto al del release: lo nombra"
assert_not_contains "$out" "verificado contra el release" "y NO se declara verificado"
assert_no_file "$WS/ui/harnessd" "el binario que no verifica no queda instalado"
assert_contains "$out" "PANEL PYTHON" "cae al panel Python en vez de ejecutar lo que bajo"

out="$(run_panel ninguno)"
assert_contains "$out" "no publica SHA256SUMS" "release sin checksums: lo avisa, no lo silencia"
assert_contains "$out" "SIN verificar" "y el ✓ de instalado admite que no verifico"
assert_not_contains "$out" "sha256 verificado" "jamas una verificacion fingida"
assert_contains "$out" "HARNESSD RUN" "avisado, sigue: es el tercer estado, no un rojo"

echo
echo "── la pata de macOS existe, pero a pedido: barata sin dejar de ser probable"
# Caso de campo: la matriz corria macOS en CADA push, y los runners de macOS
# gastan 10 veces los minutos. Un dia normal de trabajo (diez pushes) agoto la
# cuota de Actions, y con la cuota agotada NO arranca ningun job: ni el de
# Linux ni el release. La matriz completa no compraba mas portabilidad,
# compraba quedarse sin CI. Ahora macOS corre por workflow_dispatch.
#
# Lo que este bloque protege es que el camino a pedido SIGA EXISTIENDO. Que
# macOS salga de la matriz automatica es una decision de costo; que desaparezca
# del repo entero seria perder la unica forma de probar la promesa de bash 3.2
# y userland BSD, y nadie se enteraria hasta que un usuario de macOS reporte.
ci="$(cat "$ROOT/.github/workflows/ci.yml")"
# El aserto es sobre el RUNNER, no sobre la palabra: el comentario de ci.yml
# explica a proposito por que macOS no esta ahi, y prohibir la palabra
# prohibiria justamente la explicacion.
assert_not_contains "$ci" "macos-latest" \
  "ci.yml es SOLO Linux: un runner macOS ahi vuelve a agotar la cuota y a dejar al repo sin CI"

mac="$ROOT/.github/workflows/ci-macos.yml"
[ -f "$mac" ] && pass "la pata de macOS existe en su propio workflow" \
  || fail "sin ci-macos.yml no hay NINGUNA forma de probar bash 3.2 y BSD"
macyml="$(cat "$mac" 2>/dev/null)"
assert_contains "$macyml" "workflow_dispatch" "y se dispara a mano"
assert_contains "$macyml" "/bin/bash tests/run.sh" \
  "corriendo la suite con el bash 3.2 DE FABRICA (con el de brew probaria otra cosa)"
# Que no corra solo es el punto entero: si alguien le agrega push, pull_request
# o schedule, vuelve el gasto que dejo al repo sin CI un dia entero.
if printf '%s' "$macyml" | grep -qE '^\s*(push|pull_request|schedule):' ; then
  fail "ci-macos.yml gano un disparador automatico: eso es lo que agoto la cuota"
else
  pass "ci-macos.yml NO tiene disparadores automaticos (solo a pedido)"
fi
assert_contains "$macyml" "antes de publicar una versión" \
  "y dice CUANDO dispararlo, o el camino manual no se usa nunca"
assert_contains "$macyml" "actions/checkout@11d5960a326750d5838078e36cf38b85af677262" \
  "con la action pineada por SHA, igual que sus vecinas"

t_done
