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
stub_gh() {  # stub_gh <version-en-el-tag|""> [digest] [version-en-la-rama]
  if [ -z "$1" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$WS/bin/gh"
  else
    cat > "$WS/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
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
rm -f "$WS/bin/gh"
out="$( cd "$WS" && PATH="$WS/bin:/usr/bin:/bin" bash scripts/harness-version.sh 2>&1 )"
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

t_done
