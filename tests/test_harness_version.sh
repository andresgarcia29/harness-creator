#!/usr/bin/env bash
# test_harness_version.sh: el chequeo de versión y estado de la instancia.
#
# Lo que se protege por encima de todo: **"no pude comparar" no se reporta
# como "al día"**. Es la lección que este harness pagó con doce bugs, y un
# chequeo de versión que la incumple es el peor lugar posible para
# incumplirla: te deja creyendo que tenés los arreglos que no tenés.
set -u
. "$(dirname "$0")/lib.sh"
t_ws
R="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$WS/scripts" "$WS/bin" "$WS/tasks/T1" "$WS/tasks/T2" "$WS/.harness/claims"
cp "$R/templates/scripts/harness-version.sh" "$WS/scripts/"
chmod +x "$WS/scripts/harness-version.sh"

# El stub sirve los DOS endpoints que consulta el script: la versión del
# plugin y el manifiesto de templates. Son preguntas distintas a propósito:
# el número puede coincidir mientras el contenido difiere, que es justo el
# fallo que este script existe para detectar.
#
# Y sirve el listado de TAGS, porque la comparación se ancla al último tag y no
# a la rama por defecto: la rama se mueve con cada commit, así que compararse
# contra ella reporta "hay update" por trabajo sin publicar. El tercer argumento
# existe para el único caso donde tag y rama difieren legítimamente.
# El 4o argumento son los tags del repo del GENERADOR (harness-daemon), que es
# OTRA linea de versiones (#118): el binario del tap no se publica desde
# harness-creator. Sin separarlos, el stub contestaba lo mismo a las dos
# preguntas y el test no podia ver la diferencia que el bug tenia adentro.
stub_gh() {  # stub_gh <version-en-el-tag|""> [digest] [version-en-la-rama] [tag-del-generador]
  if [ -z "$1" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$WS/bin/gh"
  else
    cat > "$WS/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *harness-daemon/tags*) echo "v0.1.0"; echo "v${4:-$1}" ;;
  */tags*)    echo "v0.1.0"; echo "v$1"; echo "no-es-semver" ;;
  *MANIFEST*) [ -n "${2:-}" ] || exit 1
              echo "plugin_version: $1"; echo "digest: ${2:-}" ;;
  *ref=*)     printf '{"version":"$1"}' ;;
  *)          printf '{"version":"${3:-$1}"}' ;;
esac
EOF
  fi
  chmod +x "$WS/bin/gh"
}
# Un plugin instalado en disco: es DE AHÍ que un update copia, así que --verify
# lo mira antes que nada.
stub_plugin() {  # stub_plugin <version> <digest>
  rm -rf "$WS/plugin"; mkdir -p "$WS/plugin/.claude-plugin" "$WS/plugin/templates"
  printf '{"version":"%s"}\n' "$1" > "$WS/plugin/.claude-plugin/plugin.json"
  # Con líneas por archivo ANTES del digest, a propósito: cada una empieza con
  # un sha256, así que un lector que agarre "el primer hash que vea" se lleva el
  # del primer template y compara cosas distintas. Pasó al escribir --verify.
  { echo "1111111111111111111111111111111111111111111111111111111111111111  templates/a"
    echo "digest: $2"; } > "$WS/plugin/templates/MANIFEST.sha256"
}
verify() { ( cd "$WS" && PATH="$WS/bin:$PATH" CLAUDE_PLUGIN_ROOT="$WS/plugin" \
  bash scripts/harness-version.sh --verify ) 2>&1; }
verify_rc() { ( cd "$WS" && PATH="$WS/bin:$PATH" CLAUDE_PLUGIN_ROOT="$WS/plugin" \
  bash scripts/harness-version.sh --verify >/dev/null 2>&1; echo $?); }
SET_A=aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888
SET_B=9999ffff8888eeee7777dddd6666cccc5555bbbb4444aaaa3333999922221111
# HARNESS_GENERATOR_BIN apunta al stub y no a `harness` a secas: este host
# puede tener el binario del tap instalado, y sin esto el test mediria ESE.
export HARNESS_GENERATOR_BIN=harness-stub
run() { ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/harness-version.sh "$@" ) 2>&1; }
rc_of() { ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/harness-version.sh "$@" >/dev/null 2>&1; echo $?); }

echo "── el veredicto de versión, en sus tres formas"

# Los templates se fijan idénticos para que este bloque aísle la VERSIÓN;
# el set de templates tiene su propio bloque más abajo.
echo "$SET_A" > "$WS/.harness-templates"

echo "0.40.0" > "$WS/.harness-version"; stub_gh "0.47.0" "$SET_A"
out="$(run)"
assert_contains "$out" "HAY UPDATE" "instancia vieja: lo dice"
assert_contains "$out" "0.40.0" "con la versión local"
assert_contains "$out" "0.47.0" "y la de upstream"
assert_contains "$out" "harness-init ." "y el comando exacto para actualizar"
assert_eq 1 "$(rc_of --check)" "--check: exit 1 cuando hay update"

echo "0.47.0" > "$WS/.harness-version"
out="$(run)"
assert_contains "$out" "al día" "instancia al día: lo dice"
assert_not_contains "$out" "HAY UPDATE" "y no confunde"
assert_eq 0 "$(rc_of --check)" "--check: exit 0 al día"

# EL CASO QUE IMPORTA: sin poder consultar upstream, NO se dice "al día".
stub_gh ""
out="$(run)"
assert_contains "$out" "NO pude comparar" "sin respuesta de upstream: lo dice"
assert_not_contains "$out" "al día" "y NO reporta al día (sería la mentira más cara de este script)"
assert_eq 2 "$(rc_of --check)" "--check: exit 2 = no se pudo comparar, distinto de 0 y de 1"

echo
echo "── el set de templates: el número puede mentir, el contenido no"
# El fallo real que motivó esto: un generador escribió .harness-version con
# la versión NUEVA habiendo generado desde templates viejos. La versión
# coincidía, el contenido no, y la salida no lo decía en ningún lado.
echo "0.47.0" > "$WS/.harness-version"
echo "$SET_A" > "$WS/.harness-templates"; stub_gh "0.47.0" "$SET_B"
out="$(run)"
assert_contains "$out" "al día" "la VERSIÓN coincide, y eso se reporta tal cual"
assert_contains "$out" "DISTINTOS" "pero el SET de templates difiere y se dice"
assert_contains "$out" "aaaa1111bbbb" "con el digest local"
assert_contains "$out" "9999ffff8888" "y el de upstream"
assert_eq 1 "$(rc_of --check)" "--check: exit 1 aunque la versión coincida (el contenido manda)"

echo "$SET_B" > "$WS/.harness-templates"
out="$(run)"
assert_contains "$out" "idénticos a upstream" "sets iguales: lo dice"
assert_not_contains "$out" "DISTINTOS" "y no confunde"
assert_eq 0 "$(rc_of --check)" "--check: exit 0 solo cuando coinciden versión Y contenido"

# Un generador que no deja rastro de su fuente: la instancia es inauditable.
rm -f "$WS/.harness-templates"
out="$(run)"
assert_contains "$out" "NO declara con qué set" "sin rastro del generador: lo dice"
assert_contains "$out" "no se puede creer" "y avisa que el número de versión no alcanza"
assert_eq 1 "$(rc_of --check)" "--check: exit 1, porque no se puede afirmar que esté al día"

# Sin manifiesto de upstream: no se inventa un veredicto de contenido.
echo "$SET_A" > "$WS/.harness-templates"; stub_gh "0.47.0"
out="$(run)"
assert_contains "$out" "no pude traer el manifiesto" "sin manifiesto remoto: dice el motivo"
assert_not_contains "$out" "idénticos a upstream" "y NO afirma que coincidan"

# gh ni siquiera instalado: hay que sacarlo del PATH, no solo borrar el stub
# (el del sistema seguiría respondiendo y el test probaría otra cosa).
# Y NO alcanza con recortar el PATH a /usr/bin: en un runner de CI `gh` vive
# justo ahí, así que este test pasaba en local y fallaba solo en CI, probando
# el camino equivocado. t_path_without arma un PATH con todo menos gh.
rm -f "$WS/bin/gh"
NOGH="$(t_path_without gh)"
command -v gh >/dev/null 2>&1 && { PATH="$NOGH" command -v gh >/dev/null 2>&1 \
  && fail "el PATH sin gh todavía tiene gh" || pass "el PATH de prueba no tiene gh"; }
out="$( cd "$WS" && PATH="$NOGH" bash scripts/harness-version.sh 2>&1 )"
assert_contains "$out" "gh no está instalado" "sin gh: dice el motivo concreto"
assert_not_contains "$out" "al día" "y tampoco inventa un veredicto"

echo
echo "── el estado que hay que mirar ANTES de actualizar"
# La fase editada a mano es lo único que un update puede empeorar:
# validate-ship compara la fase contra el último movimiento registrado.
stub_gh "0.47.0"
printf '{"phase":"review","lane":"express","review_rounds":2,"history":[{"to":"review"}]}' > "$WS/tasks/T1/state.json"
printf '{"phase":"review","lane":"full","review_rounds":1,"history":[{"to":"ship"}]}' > "$WS/tasks/T2/state.json"
out="$(run)"
assert_contains "$out" "T2" "lista las tareas con estado"
assert_contains "$out" "EDITADA A MANO" "y marca la que tiene la fase desalineada del historial"
assert_contains "$out" "history dice 'ship'" "diciendo qué esperaba encontrar"
t1_line="$(printf '%s\n' "$out" | grep -E '^  T1 ' || true)"
assert_not_contains "$t1_line" "EDITADA" "la tarea coherente NO se marca"
assert_contains "$out" "fase=review" "con su fase y su carril"

echo
echo "── sesiones, worktrees tomados y supuestos"
printf '{"session":"abc12345def","task":"T1","repo":"atlas","at":1}' > "$WS/.harness/claims/T1__atlas.json"
printf '{"ts":"x","kind":"prompt","session":"s1"}\n{"ts":"y","kind":"stop","session":"s1"}\n' > "$WS/.harness/events.jsonl"
printf -- '- SUPUESTO: el endpoint acepta null\n- SUPUESTO: el umbral es 300ms\n' > "$WS/tasks/T1/assumptions.md"
out="$(run)"
assert_contains "$out" "T1/atlas tomado por la sesión abc12345" "dice qué worktree tiene tomado quién"
assert_contains "$out" "parada(s) registradas" "avisa si alguien te está esperando"
assert_contains "$out" "2 supuesto(s) sin confirmar" "y cuenta los supuestos, que son lo primero a auditar"

# Caso de campo: un assumptions.md que EXISTE y no tiene ni un supuesto (o sea
# el caso BUENO) rompía el script entero. `grep -c` imprime 0 y ADEMÁS sale 1
# cuando no encuentra nada, así que el `|| echo 0` que había agregaba un
# segundo 0: k quedaba "0\n0" y el $(()) moría con "syntax error in
# expression". Se veía al final de la salida, después de imprimir todo, así
# que parecía un fallo del bloque de worktrees y no del conteo de supuestos.
printf 'notas sueltas, ningun supuesto\n' > "$WS/tasks/T2/assumptions.md"
out="$(run 2>&1)"; rc=$?
assert_eq 0 "$rc" "un assumptions.md SIN supuestos no rompe el script"
assert_not_contains "$out" "harness-version.sh: line" "y no escupe un error de bash en la cara"
assert_contains "$out" "2 supuesto(s) sin confirmar" "el conteo sigue siendo el de los supuestos reales"

# y el borde de al lado: TODOS los assumptions.md vacíos de supuestos
printf 'nada\n' > "$WS/tasks/T1/assumptions.md"
out="$(run 2>&1)"; rc=$?
assert_eq 0 "$rc" "todos sin supuestos: sale 0 igual"
assert_not_contains "$out" "supuesto(s) sin confirmar" "y no anuncia una sección vacía"
printf -- '- SUPUESTO: el endpoint acepta null\n- SUPUESTO: el umbral es 300ms\n' > "$WS/tasks/T1/assumptions.md"
rm -f "$WS/tasks/T2/assumptions.md"

# Y la defensa de al lado, con diente: si `grep` devuelve algo que NO es un
# número (otro vendor, un locale raro, un alias del usuario), la aritmética
# tampoco puede tumbar el script. Esto OBSERVA: no tiene permiso para romper.
cat > "$WS/bin/grep" <<'SH'
#!/bin/sh
case "$*" in *SUPUESTO*) echo "no soy un numero"; exit 0 ;; esac
exec /usr/bin/grep "$@"
SH
chmod +x "$WS/bin/grep"
out="$(run 2>&1)"; rc=$?
assert_eq 0 "$rc" "un grep que devuelve basura no tumba el chequeo"
assert_not_contains "$out" "harness-version.sh: line" "y tampoco escupe un error de bash"
rm -f "$WS/bin/grep"

echo
echo "── observa, no frena"
# Un chequeo de versión que puede tumbar tu trabajo es un bug: en modo normal
# sale 0 pase lo que pase. El único con contrato de exit code es --check.
rm -rf "$WS/tasks" "$WS/.harness" "$WS/.harness-version"
assert_eq 0 "$(rc_of)" "workspace a medias: sale 0 igual (fail-open)"
out="$(run)"
assert_contains "$out" "no declara versión" "y dice qué le falta"
assert_contains "$out" "(ninguna)" "sin tareas, lo dice en vez de romperse"

echo
echo "── el marcador de templates vale con o sin el prefijo 'digest: '"
# templates/MANIFEST.sha256 termina con la linea `digest: <hash>` y la tabla de
# generacion pedia "el digest: de MANIFEST.sha256": se lee como el VALOR o como
# la LINEA. Solo se aceptaba una, asi que una instancia cuyo generador escribio
# la linea reportaba drift PARA SIEMPRE estando al dia. Es el peor sitio para un
# falso rojo: esta comprobacion existe para que un update no pueda mentir.
stub_gh "0.47.0" "$SET_A"
for form in "$SET_A" "digest: $SET_A" "  digest:   $SET_A  "; do
  printf '%s' "$form" > "$WS/.harness-templates"
  out="$(run)"
  assert_contains "$out" "idénticos a upstream" "forma aceptada: '$(printf '%.24s' "$form")'"
done
# mayusculas: mismo digest, otra grafia
printf '%s' "$(printf '%s' "$SET_A" | tr 'a-f' 'A-F')" > "$WS/.harness-templates"
assert_contains "$(run)" "idénticos a upstream" "hex en mayusculas: mismo set"

# Un marcador ROTO no es drift, y decirlo asi mandaria a regenerar por la razon
# equivocada.
printf 'no-soy-un-digest' > "$WS/.harness-templates"
out="$(run)"
assert_contains "$out" "no contiene un digest legible" "marcador ilegible: se nombra como tal"
assert_not_contains "$out" "DISTINTOS" "y NO se reporta como drift de contenido"

echo
echo "── una instancia NO puede ir adelante de su origen"
# Caso real, encontrado en una VPS: la instalacion escribio 0.60.0 en
# .harness-version, una version que no existe en el plugin y que por CONTENIDO
# estaba mas de sesenta commits atras. Como 0.60.0 > 0.48.0, caia en el `else`
# y `make version` decia "✅ al día" mientras los gates de lenguaje ni
# compilaban. La causa: la tabla del instalador pedia "version del plugin" sin
# decir de donde leerla, asi que el agente escribio un numero plausible.
echo "$SET_A" > "$WS/.harness-templates"
stub_gh "0.48.0" "$SET_A"
echo "0.60.0" > "$WS/.harness-version"
out="$(run)"
assert_not_contains "$out" "al día" "version mayor que upstream: NO se reporta al dia"
assert_contains "$out" "MAYOR que su origen" "se nombra la imposibilidad"
assert_contains "$out" "se escribió" "y se dice que el numero no se leyo de ningun lado"
assert_eq 1 "$(rc_of --check)" "--check: no la trata como sana"

# el instalador ya no puede inventarla
sk="$(cat "$ROOT/skills/harness-init/SKILL.md")"
assert_contains "$sk" "plugin.json" "el instalador lee la version del plugin.json"
assert_contains "$sk" "jamás se escribe de memoria" "y tiene prohibido escribirla de memoria"


echo
echo "── ... salvo que la rama por defecto diga lo mismo"
# La otra cara: con la comparacion anclada al TAG, una instancia generada desde
# un main sin taggear va legitimamente adelante del ultimo tag. Marcarla como
# numero inventado seria un rojo falso en el peor lugar (esta comprobacion
# existe para que un update no pueda mentir; mintiendo ella enseña a ignorarla).
# La rama desempata: si el numero local EXISTE en main, se leyo de algun lado.
stub_gh "0.48.0" "$SET_A" "0.49.0"
echo "0.49.0" > "$WS/.harness-version"
out="$(run)"
assert_contains "$out" "main sin taggear" "adelantado del tag pero igual a main: se explica"
assert_not_contains "$out" "MAYOR que su origen" "y NO se acusa de numero inventado"
assert_eq 0 "$(rc_of --check)" "--check: no hay nada publicado a lo que ir"

echo
echo "── se compara contra el ULTIMO tag, no contra el primero que devuelva el API"
# /tags devuelve por fecha de creacion: un tag de arreglo publicado tarde sobre
# una version vieja quedaria primero. El stub sirve v0.1.0 ANTES que el bueno.
stub_gh "0.48.0" "$SET_A"
echo "0.40.0" > "$WS/.harness-version"
out="$(run)"
assert_contains "$out" "0.48.0" "toma el mayor, no el primero"
assert_not_contains "$out" "upstream 0.1.0" "y no el mas viejo"
assert_contains "$out" "tag v0.48.0" "y dice contra que punto comparo"

echo
echo "── --verify: el update aterrizo (numero Y contenido)"
# Un update que termina diciendo "listo" no es evidencia de nada. Lo unico que
# no se puede fingir es coincidir con el tag en los dos ejes.
stub_gh "0.48.0" "$SET_A"
stub_plugin "0.48.0" "$SET_A"
echo "0.48.0" > "$WS/.harness-version"; echo "$SET_A" > "$WS/.harness-templates"
out="$(verify)"
assert_contains "$out" "aterrizó" "todo coincide: lo confirma"
assert_eq 0 "$(verify_rc)" "y sale 0"
# El de arriba tambien prueba que no se agarra el hash del primer archivo del
# MANIFEST del plugin: si lo hiciera, este caso sano saldria rojo.

echo
echo "── --verify: el numero quedo bien y el CONTENIDO no"
# EL fallo caro, y ya paso: '1 actualizado, 24 conflictos' con la version nueva
# escrita sobre templates viejos. Ninguno de esos 24 traia los arreglos que el
# numero prometia, y nada en la salida lo decia.
echo "$SET_B" > "$WS/.harness-templates"
out="$(verify)"
assert_contains "$out" "CONTENIDO" "digest distinto: se nombra el fallo"
assert_not_contains "$out" "aterrizó: instancia" "y NO se declara exito"
assert_eq 1 "$(verify_rc)" "sale 1"

echo
echo "── --verify: mira el plugin EN DISCO, que es de donde el update copia"
# Sin esto, /plugin marketplace update sin correr = regenerar desde templates
# viejos, escribir el numero nuevo, y reportar exito. El bug de 0.60.0 visto un
# paso antes.
echo "$SET_A" > "$WS/.harness-templates"
stub_plugin "0.45.2" "$SET_B"
out="$(verify)"
assert_contains "$out" "PLUGIN EN DISCO" "plugin viejo: se nombra"
assert_contains "$out" "marketplace update" "con el comando que lo arregla"
assert_eq 1 "$(verify_rc)" "y bloquea aunque la instancia coincida con el tag"

echo
echo "── --verify: no poder comprobar NO es exito"
stub_plugin "0.48.0" "$SET_A"
stub_gh ""
out="$(verify)"
assert_contains "$out" "SIN VERIFICAR" "sin upstream: se dice que no se verifico"
assert_not_contains "$out" "aterrizó: instancia" "y no se declara exito"
assert_eq 2 "$(verify_rc)" "exit 2: ni verde ni rojo, no se pudo mirar"

echo
echo "── --generator (#102): el binario del tap se AUTORIZA antes de generar"
# El paso 2 de /harness-update prefiere el binario sobre la re-instanciacion
# manual, y nada comprobaba que su version correspondiera a algo publicado. En
# campo: el binario reportaba 0.60.0 con el ultimo tag en 0.59.3. Generar con el
# habria escrito templates que no existen en ningun origen, el paso 5 habria
# estampado ese numero, y el --verify posterior saldria rojo sin explicar por
# que. La unica defensa eran tres parrafos de prosa pidiendole al humano que
# comparara a mano, y el incidente ocurrio con la prosa ya escrita.
stub_harness() {  # stub_harness <lo-que-dice> [modo]
  if [ -z "$1" ]; then rm -f "$WS/bin/harness-stub"; return; fi
  cat > "$WS/bin/harness-stub" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) [ "${2:-flag}" = "subcomando" ] && exit 1; echo "harness $1" ;;
  version)   echo "harness version : $1" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$WS/bin/harness-stub"
}
gen()    { ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/harness-version.sh --generator ) 2>&1; }
gen_rc() { ( cd "$WS" && PATH="$WS/bin:$PATH" bash scripts/harness-version.sh --generator >/dev/null 2>&1; echo $?); }

stub_gh "0.59.3" "$SET_A"
# (1) EL caso del reporte: una version que no existe como tag ni release.
stub_harness "0.60.0"
out="$(gen)"
assert_contains "$out" "NO EXISTE en andresgarcia29/harness-daemon" \
  "#102: 0.60.0 sin tag en el repo del binario: se dice que no existe"
assert_contains "$out" "0.59.3" "y nombra contra que se comparo"
assert_contains "$out" "incidente 0.60.0" "y lo ata al incidente que el playbook ya citaba"
assert_eq 1 "$(gen_rc)" "#102: exit 1, NO generes con este binario"

# (2) el binario al dia: es la unica autorizacion que existe
stub_harness "0.59.3"
out="$(gen)"
assert_contains "$out" "es el último tag publicado" "el binario al dia SI autoriza"
assert_eq 0 "$(gen_rc)" "exit 0"

# (2b) ISSUE #118: el binario y los templates son DOS lineas de versiones.
# El tap empaqueta un release de harness-daemon, asi que un generador legitimo
# y al dia (0.60.0, tag real de harness-daemon) puede ir "adelante" del ultimo
# tag de harness-creator (0.59.9) sin que eso tenga nada de raro. Comparandolo
# contra el repo equivocado, ese generador sano quedaba rechazado con el texto
# del incidente 0.60.0, el paso 2 de /harness-update se cerraba, y TODO update
# caia a la re-instanciacion manual, que el playbook llama el camino mas
# riesgoso.
stub_gh "0.59.9" "$SET_A" "" "0.60.0"
stub_harness "0.60.0"
out="$(gen)"
assert_contains "$out" "podés generar" \
  "#118: el binario al dia en SU repo autoriza, aunque su numero sea mayor que el ultimo tag de los templates"
assert_eq 0 "$(gen_rc)" "#118: exit 0, no el rechazo del incidente que no es"
assert_not_contains "$out" "incidente 0.60.0" "y no lo acusa de un incidente ajeno"
stub_gh "0.59.3" "$SET_A"

# (3) un tag publicado pero VIEJO: generaria una instancia vieja que reporta
#     exito igual, que es el mismo final por otro camino.
stub_harness "0.1.0"
out="$(gen)"
assert_contains "$out" "pero NO el último" "un tag viejo tampoco autoriza"
assert_eq 1 "$(gen_rc)" "exit 1: sus templates son mas viejos que lo publicado"

# (4) un pre-release se distingue del numero inventado: la remediacion difiere
stub_harness "0.60.0-rc1"
out="$(gen)"
assert_contains "$out" "PRE-RELEASE" "#102: un pre-release se nombra como tal"
assert_eq 1 "$(gen_rc)" "y tampoco autoriza por defecto"

# (5) el binario que habla por subcomando, no por --flag
stub_harness "0.59.3" subcomando
assert_eq 0 "$(gen_rc)" "lee la version del binario que solo responde \`harness version\`"

# (6) NO PODER COMPROBAR NO ES AUTORIZAR: la ley de este script, en el lugar
#     donde incumplirla escribe archivos.
stub_harness "0.59.3"
stub_gh ""
out="$(gen)"
assert_contains "$out" "comprobación que no corrió" "sin upstream: se dice que no se comparo"
assert_not_contains "$out" "podés generar" "y NO autoriza"
assert_eq 2 "$(gen_rc)" "exit 2: ni autorizado ni rechazado"

stub_gh "0.59.3" "$SET_A"
stub_harness ""
out="$(gen)"
assert_contains "$out" "no hay binario" "sin binario: no hay generador que autorizar"
assert_eq 2 "$(gen_rc)" "exit 2 (el 2b es el camino, y se declara)"

printf '#!/usr/bin/env bash\necho "harness, el generador"\n' > "$WS/bin/harness-stub"
chmod +x "$WS/bin/harness-stub"
out="$(gen)"
assert_contains "$out" "no dice qué versión es" "un binario mudo no se puede autorizar"
assert_eq 2 "$(gen_rc)" "exit 2, no 0: sin numero no hay vintage de templates que juzgar"

echo
echo "── y el modo normal lo dice sin que nadie se lo pregunte"
# El reporte del #102 venia de una instancia al dia en numero Y digest: nada en
# la salida habitual insinuaba que el update iba a correr con un binario 0.60.0.
echo "0.59.3" > "$WS/.harness-version"
echo "$SET_A" > "$WS/.harness-templates"
stub_harness "0.60.0"
out="$(run)"
assert_contains "$out" "al día" "la instancia sigue reportandose al dia (lo esta)"
assert_contains "$out" "NO EXISTE en andresgarcia29/harness-daemon" "#102: y AUN ASI avisa del generador"
stub_harness ""
out="$(run)"
assert_not_contains "$out" "generador" "sin binario instalado no hay ruido: no todos lo tienen"

t_done
