#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"

echo "── contratos de documentación"
root="$(cd "$(dirname "$0")/.." && pwd)"

readme="$(cat "$root/README.md")"
smart="$(cat "$root/templates/commands/smart.md.tmpl")"
index="$(cat "$root/templates/docs/index.md.tmpl")"

assert_not_contains "$readme" "127.0.0.1:7717" "README no conserva el puerto viejo"
assert_not_contains "$readme" "exactamente diez" "README no duplica el número de paradas"
assert_contains "$smart" "Lista cerrada de paradas" "smart declara el contrato cerrado"
assert_contains "$smart" "harness-policy.py pause" "smart registra pausas mediante policy"
assert_contains "$index" "harness/evidence.md" "índice enlaza evidence v1"
assert_contains "$index" "harness/policy.md" "índice enlaza policy v1"

# ── El .gitignore de la instancia es UN archivo, no una lista de memoria.
# Mientras vivió como prosa dentro de la tabla del skill, el generado se
# divergió en los dos sentidos y graphify-out/ (128 MB) entraba a git (#27).
gi="$root/templates/gitignore.tmpl"
[ -f "$gi" ] && pass "el .gitignore de la instancia es un template versionado" \
  || fail "falta templates/gitignore.tmpl: la lista volvió a ser prosa"
for entry in "repos/" "worktrees/" "locks/" ".cache/" ".secrets" ".secrets.d/" \
             "inventory.json" "go.work" "go.work.sum" "graphify-out/" ".harness/" "tasks/"; do
  grep -qxF "$entry" "$gi" 2>/dev/null && pass ".gitignore cubre $entry" \
    || fail ".gitignore SIN $entry (regenerable o local: no va a git)"
done
skill_gi="$(grep '^| `.gitignore`' "$root/skills/harness-init/SKILL.md")"
assert_contains "$skill_gi" "gitignore.tmpl" "la tabla de generación apunta al template, no a una lista inline"

# ── El bloque `env` del settings de la instancia es un CONTRATO, no un adorno.
# Lo que se declara ahí es lo único que llega al entorno de los hooks y al del
# `claude -p` que orchestrator-watch.sh levanta por tarea (verificado end-to-end
# con un hook que volcó su propio entorno). Una perilla que vive solo en el
# template es una perilla que nadie encuentra: el valor se elige por una razón
# medida y esa razón vive en la tabla de generación, o vuelve a ser un string
# mágico que el próximo lector cambia a ciegas.
sj_env="$(python3 -c "import json;print(json.dumps(json.load(open('$root/templates/settings.json.tmpl')).get('env',{})))")"
pony="$(printf '%s' "$sj_env" | python3 -c "import json,sys;print(json.load(sys.stdin).get('PONYTAIL_DEFAULT_MODE',''))")"
case "$pony" in
  off|lite|full|ultra) pass "settings.json.tmpl fija PONYTAIL_DEFAULT_MODE en un modo válido ($pony)" ;;
  "") fail "settings.json.tmpl perdió PONYTAIL_DEFAULT_MODE del bloque env" ;;
  *)  fail "PONYTAIL_DEFAULT_MODE='$pony' no es un modo de ponytail (off|lite|full|ultra)" ;;
esac
skill_sj="$(grep '^| `.claude/settings.json`' "$root/skills/harness-init/SKILL.md")"
assert_contains "$skill_sj" "PONYTAIL_DEFAULT_MODE" \
  "la tabla de generación nombra la perilla, no la deja como string mágico"
assert_contains "$skill_sj" "off" "la tabla dice cuál es el valor que de verdad ahorra tokens"

# ── Ley 15: la recomendada es la duradera, nunca la rápida.
# Caso real: un agente marcó "editar state.json a mano (recomendado)" porque no
# había vuelta atrás por CLI. Era lo rápido, violaba una ley del propio
# CLAUDE.md, y el hueco real (falta un rollback) quedó sin reportar.
# (Este bloque la llamaba "Ley 13": la 13 real es la de repos archivados, y
# citar el número equivocado manda al agente a la ley que no es. El assert de
# abajo ata número Y texto para que no vuelva a derivar.)
claude_md="$root/templates/CLAUDE.md.tmpl"
const="$root/templates/docs/constitution.md.tmpl"
assert_contains "$(cat "$claude_md")" "15. **La recomendada es la que elimina la causa" \
  "la ley 'elimina la causa' es la 15, con número y texto atados"
assert_contains "$(cat "$claude_md")" "NUNCA como" "Ley 15: el atajo nunca va como recomendado"
assert_contains "$(cat "$claude_md")" "Ley 12" "Ley 15: un camino que falta es un bug del harness, no un permiso"
assert_contains "$(cat "$const")" "2b." "la constitución tiene la sección de lo correcto sobre lo rápido"
# La tensión con "código mínimo" tiene que quedar resuelta EN EL TEXTO: sin
# esto, un agente lee la ley nueva como permiso para sobre-construir, que es
# justo lo que §2 y §3 existen para impedir.
assert_contains "$(cat "$claude_md")" "constitución §2" "Ley 15 aclara que no afloja el código mínimo"
assert_contains "$(cat "$const")" "ALCANCE" "la constitución separa alcance (§2) de clase de arreglo (§2b)"
assert_contains "$(cat "$root/templates/commands/smart.md.tmpl")" "elimina la causa" \
  "/smart aplica la Ley 15 al ADR que propone al humano"
assert_contains "$(cat "$root/templates/commands/smart.md.tmpl")" "(Ley 15)" \
  "y la cita por su número real (era 'Ley 13', que es la de repos archivados)"

# ── Enrichment: la única interacción con el humano, al principio.
# Concentrar ahí lo que solo el humano sabe es lo que permite que el resto
# corra sin interrupciones. El modo de fallo de esta fase es la CEREMONIA:
# preguntar por preguntar reintroduce justo el "se para mucho" que vino a
# resolver, así que la barra de calidad se testea igual que la fase.
smart_md="$root/templates/commands/smart.md.tmpl"
assert_contains "$(cat "$smart_md")" "Enrichment" "/smart tiene la fase de enrichment"
assert_contains "$(cat "$smart_md")" "ÚNICA interacción" "el enrichment se declara como la única interacción"
assert_contains "$(cat "$smart_md")" "Entiende el terreno ANTES" "primero el terreno, después la tarea"
assert_contains "$(cat "$smart_md")" "Máximo 5" "la ronda de preguntas tiene techo"
assert_contains "$(cat "$smart_md")" "el default que" "cada pregunta trae su default (el silencio es respuesta válida)"
assert_contains "$(cat "$smart_md")" "Si nada califica" "no preguntar es un resultado válido, no una falla"
assert_contains "$(cat "$smart_md")" "enrichment.md" "la fase deja artefacto auditable"
assert_contains "$(sed 's/{{LOOP_BUDGET}}/3/' "$root/templates/policy.json.tmpl")" \
  "enrichment_questions" "la pausa del enrichment es una parada registrada en policy"
assert_contains "$(cat "$root/templates/docs/intake.md.tmpl")" "enrichment" \
  "intake.md ya no contradice a /smart sobre rebotar con preguntas"

# ── Ley de estilo (CONTRIBUTING #6): el guion largo "—" delata prosa de IA.
# RATCHET al estilo ratchet-keeper: el conteo del repo SOLO puede bajar.
# Al reescribir prosa vieja, baja el número de abajo al nuevo conteo (nunca
# lo subas: si tu cambio lo sube, reescribe sin el guion largo). Las cajas
# de terminal "──" (U+2500) son otro carácter y no cuentan.
# El tope es el conteo REAL del día, sin holgura: dejarlo por encima (487 con
# 447 medidos) regala 40 guiones largos gratis y el ratchet deja de morder.
#
# Y cuenta SOLO ARCHIVOS VERSIONADOS (`git ls-files`), no lo que haya en el
# directorio. El walk del filesystem contaba cualquier cosa que otra herramienta
# dejara al lado (pasó: un `.atl/skill-registry.md` de un runtime local sumó uno
# y puso el gate rojo), y entonces el mensaje "tu cambio AÑADE em dashes" era
# falso: no era un cambio, ni era de este repo. Un gate que mide otra cosa que
# la que dice medir se apaga solo, porque el primero que lo vea mentir deja de
# creerle. En CI daba verde, además, así que discrepaban las dos mitades.
EMDASH_MAX=430
emdash_now=$( (cd "$root" && git ls-files -z -- '*.md' '*.tmpl' '*.yaml' '*.sh' '*.py' '*.json' 2>/dev/null \
    | xargs -0 grep -o "—" 2>/dev/null) \
  | grep -v "templates/ui/dist" | wc -l | tr -d ' ')
if [ "$emdash_now" -le "$EMDASH_MAX" ]; then
  pass "ratchet de guion largo: $emdash_now ≤ $EMDASH_MAX (solo baja)"
else
  fail "ratchet de guion largo: $emdash_now > $EMDASH_MAX; tu cambio AÑADE em dashes. Reescribe con coma/dos puntos/paréntesis (CONTRIBUTING #6)"
fi

# ── El manifiesto de templates refleja los templates.
# Un manifiesto viejo es PEOR que ninguno: hace creer que una instancia se
# generó con un set que no es el que se usó, que es exactamente el fallo
# que el manifiesto existe para detectar. Por eso se verifica en cada corrida
# y no "cuando alguien se acuerde".
if out="$(bash "$root/scripts/templates-manifest.sh" verify 2>&1)"; then
  pass "templates/MANIFEST.sha256 al día con los templates"
else
  fail "$out"
fi

echo
echo "── las cuentas que el README canta las deriva la suite, no la memoria"
# CASO DE CAMPO, y es el que paga este bloque: el README decia "son 37
# archivos" con 63 tests en el arbol, y "cada uno de los 96 archivos" con 109
# en el manifiesto. Ninguna de las dos mentia el dia que se escribio:
# envejecieron PR a PR, calladas, porque una cuenta en prosa no tiene quien la
# mire. Es el mismo defecto que el manifiesto de arriba existe para cazar, solo
# que aplicado a la documentacion, y se arregla igual: lo que se puede DERIVAR
# del arbol se deriva, y la prosa se compara contra eso.
#
# Solo entran cuentas que un script puede reconstruir sin juicio. La duracion
# de la suite, por ejemplo, NO esta aca a proposito: depende de la maquina, y
# un test que la fije seria mas fragil que la prosa que pretende cuidar.
readme_dice() {  # readme_dice <expr sed con UN grupo> → el numero que afirma el README
  sed -n "s/$1/\1/p" "$root/README.md" | head -1
}

# 1. archivos de test. El `ls` es la fuente: si manana entra test_nuevo.sh, esta
#    linea cambia sola y la prosa tiene que seguirla.
t_reales="$(ls "$root"/tests/test_*.sh "$root"/tests/test_*.py 2>/dev/null | grep -c .)"
t_dice="$(readme_dice '.*no los lista todos (son \([0-9][0-9]*\) archivos).*')"
if [ "$t_dice" = "$t_reales" ]; then
  pass "README: dice $t_dice archivos de test y en tests/ hay $t_reales"
else
  fail "README: dice '$t_dice archivos' de test y en tests/ hay $t_reales.
   ↳ remediación: corregí 'son N archivos' en la sección Tests del README.md"
fi

# 2. entradas del manifiesto. Se cuentan las lineas hash+ruta, que es lo que
#    templates-manifest.sh llama "templates": ni las de cabecera, ni
#    plugin_version, ni el digest del final. Incluye scripts/doctor.sh, que se
#    COPIA a la instancia y por eso cuenta como template (lo dice el propio
#    README en "Estructura de este repo").
m_reales="$(grep -c '^[0-9a-f]\{64\}  ' "$root/templates/MANIFEST.sha256")"
m_dice="$(readme_dice '.*de los \([0-9][0-9]*\) archivos que terminan dentro de una instancia.*')"
if [ "$m_dice" = "$m_reales" ]; then
  pass "README: dice $m_dice archivos en el manifiesto y hay $m_reales"
else
  fail "README: dice '$m_dice archivos' en el manifiesto y hay $m_reales.
   ↳ remediación: corregí el número en 'el sha256 de cada uno de los N archivos'
     de la sección 'El número de versión no alcanza' del README.md"
fi

# 3. Y la red de la red: si alguien reescribe esas frases y el sed deja de
#    encontrarlas, los dos casos de arriba compararian "" contra "" y pasarian
#    en verde sin haber mirado nada. Un verificador que no encuentra qué
#    verificar tiene que decirlo, no aprobar.
if [ -n "$t_dice" ] && [ -n "$m_dice" ]; then
  pass "las dos frases con cuenta siguen existiendo en el README (el test no quedó ciego)"
else
  fail "no encontré en el README las frases con las cuentas (tests='$t_dice' manifiesto='$m_dice').
   ↳ remediación: si reescribiste esas líneas, actualizá los sed de tests/test_docs.sh;
     si borraste la cuenta, borrá también su caso: un test que no mide nada es peor que ninguno"
fi

echo
echo "── README.en.md es un ESPEJO del español, no un resumen"
# Hasta hoy era un resumen de 148 lineas contra 1003 del español, y llevaba
# semanas sin tocarse. Un documento que promete "overview" envejece sin que
# nadie lo note, porque nada se rompe cuando queda atras. Ahora es un espejo, y
# un espejo que solo se sostiene con disciplina se raja en el primer PR apurado.
#
# NO se compara el TEXTO (son dos idiomas) sino la FORMA: si el español gana una
# seccion, un diagrama o una fila de tabla, el ingles tiene que ganarla tambien.
# Es la comprobacion mas barata que distingue "traducido" de "quedo a medias", y
# la unica que un script puede hacer sin opinar sobre prosa.
espejo() {  # espejo <patron grep> <qué se cuenta>
  local es en
  es="$(grep -c "$1" "$root/README.md")"
  en="$(grep -c "$1" "$root/README.en.md")"
  if [ "$es" = "$en" ]; then
    pass "README.en.md espeja $2 ($es)"
  else
    fail "README.en.md tiene $en $2 y README.md tiene $es.
   ↳ remediación: los dos README son el mismo documento en dos idiomas
     (CONTRIBUTING lo declara). Si tocaste uno, tocá el otro; si el cambio es
     deliberadamente asimétrico, este caso es el lugar para declararlo"
  fi
}
espejo '^## '        "las secciones de primer nivel"
espejo '^### '       "las subsecciones"
espejo '^```mermaid' "los diagramas mermaid"
espejo '^|'          "las filas de tabla"

echo
echo "── /harness-update clasifica TODOS los scripts del plugin"
# Un script del plugin que no aparece en harness-update.md no tiene propietario
# declarado, y el update no sabe si pisarlo o respetarlo: en la practica las
# instancias no lo reciben. Paso con change-id.sh (nuevo) y llevaba tiempo
# pasando con deploy-watch.sh y ticket-pull.sh, que SI son del plugin.
# La regla estaba en prosa; esto la pone en un test.
UPD="$ROOT/commands/harness-update.md"
faltan=""
for f in "$ROOT"/templates/scripts/*; do
  b="$(basename "$f")"; n="${b%.tmpl}"; n="${n%.sh}"; n="${n%.py}"
  case "$n" in __pycache__|"") continue ;; esac
  grep -q -- "$n" "$UPD" || faltan="$faltan $n"
done
[ -z "$faltan" ] && pass "todos los scripts del plugin estan clasificados en harness-update.md" \
  || fail "scripts del plugin sin clasificar en harness-update.md:$faltan"

# Y los HOOKS igual, que era el agujero que quedaba: este bloque solo miraba
# templates/scripts/. Un hook nuevo no basta con copiarlo, hay que CABLEARLO en
# .claude/settings.json, asi que si el update no lo nombra la instancia recibe
# el archivo y el hook no corre nunca. Paso con guard-broad-add.sh.
faltan_h=""
for f in "$ROOT"/templates/hooks/*; do
  b="$(basename "$f")"; n="${b%.sh}"
  [ -n "$n" ] || continue
  grep -q -- "$n" "$UPD" || faltan_h="$faltan_h $n"
done
[ -z "$faltan_h" ] && pass "todos los hooks del plugin estan clasificados en harness-update.md" \
  || fail "hooks del plugin sin clasificar en harness-update.md:$faltan_h"
# Y el archivo que los CABLEA tiene que tener dueno declarado, o un hook nuevo
# llega al disco sin que nada lo invoque.
grep -q "settings.json" "$UPD" \
  && pass "harness-update.md declara quien es dueno de .claude/settings.json" \
  || fail ".claude/settings.json sin propietario declarado: un hook nuevo llega pero no se cablea"

echo
echo "── AGENTS.md no se regenera: se mergea"
# Caso real: el update lo trato como propiedad del plugin y lo reescribio
# entero, borrando 70 lineas de una instancia: la ley del design system del
# proyecto y un bloque completo de OTRA herramienta (beads, con su hash).
# AGENTS.md es la puerta multi-herramienta por diseño: Codex, Cursor y lo que
# el proyecto sume dejan lo suyo ahi.
UPD="$ROOT/commands/harness-update.md"
assert_contains "$(cat "$UPD")" "se MERGEA" "el updater dice que AGENTS.md se mergea"
assert_contains "$(cat "$UPD")" "BLOQUES GESTIONADOS" "y nombra la clase entera, no solo AGENTS.md"
assert_contains "$(cat "$UPD")" "BEGIN" "explica como se reconoce un bloque ajeno"
# y ya NO puede figurar en la lista de "upstream gana por default"
own="$(sed -n '/Propiedad del plugin/,/Skills, por capa/p' "$UPD")"
assert_not_contains "$own" "\`AGENTS.md\`, y **el panel**" "AGENTS.md salio de la lista de upstream-gana"

echo
echo "── el doctor distingue 'no esta' de 'no esta en MI PATH'"
# Una sesion no interactiva (ssh host cmd, cron) no lee ~/.zshrc ni ~/.profile,
# asi que no ve Homebrew ni ~/.local/bin. El doctor reportaba 22 CLIs faltantes
# sobre una maquina que las tenia TODAS. Decir "falta" manda a reinstalar lo que
# ya esta, y entrena a no creerle al doctor.
doc="$(cat "$ROOT/scripts/doctor.sh")"
assert_contains "$doc" "_bin_elsewhere" "el doctor busca el binario fuera del PATH"
assert_contains "$doc" "linuxbrew" "en las rutas de Homebrew (tambien Linux)"
assert_contains "$doc" "NO está en este PATH" "y lo dice como lo que es"
assert_contains "$doc" "NO lo reinstales" "sin mandar a reinstalar lo que ya esta"
assert_contains "$doc" "zshenv" "y explica donde va brew shellenv para que persista"

echo
echo "── la ley de reportes: escribir para que se lea"
cl="$(cat "$ROOT/templates/CLAUDE.md.tmpl")"
assert_contains "$cl" "Escribí para que se lea" "CLAUDE.md declara la ley"
assert_contains "$cl" "una pantalla" "con un limite concreto, no 'se breve'"
assert_contains "$cl" "no por el viaje" "y la regla de arrancar por el estado"
assert_contains "$cl" "ejemplo concreto" "lo tecnico se explica con un caso"
ag="$(cat "$ROOT/templates/AGENTS.md.tmpl")"
assert_contains "$ag" "Escribí para que se lea" "y vale para las otras herramientas"
sm="$(cat "$ROOT/templates/commands/smart.md.tmpl")"
assert_contains "$sm" "Una pantalla" "el reporte final de /smart esta acotado"
# La numeracion de las leyes no puede tener huecos ni repetidos: se citan por
# numero desde los prompts ("Ley 6", "Ley 12"), y un salto manda a la ley
# equivocada.
nums="$(grep -oE '^[0-9]+\.' "$ROOT/templates/CLAUDE.md.tmpl" | tr -d '.' | sort -n | uniq)"
dups="$(grep -oE '^[0-9]+\.' "$ROOT/templates/CLAUDE.md.tmpl" | tr -d '.' | sort -n | uniq -d)"
[ -z "$dups" ] && pass "las leyes no tienen numeros repetidos" || fail "leyes duplicadas: $dups"

echo
echo "── CLAUDE.md manda: AGENTS.md usa SU numeracion y SUS titulos"
# AGENTS.md es el entrypoint de Cursor/Codex/Kimi y tenia numeracion propia: su
# "Ley 6" eran los contratos proto (en CLAUDE es la 2) y su "Ley 9" el bug
# upstream (en CLAUDE es la 12); las 13, 14 y 15 no existian ahi. Un playbook
# que dice "escala a humano (Ley 6)" mandaba al agente de otra herramienta a la
# ley que no era: el mismo modo de fallo que b446dc1 dejo anotado (un duplicado
# manda a la ley equivocada), pero entre archivos.
claude_map="$ROOT/templates/CLAUDE.md.tmpl"
agents_map="$ROOT/templates/AGENTS.md.tmpl"

# Mecanica (documentada porque el test la impone): de cada linea que ABRE una
# ley ("7. **Titulo**...") se sacan numero y titulo en negrita, sin backticks.
# El titulo llega hasta el ULTIMO "**" de la linea, nunca hasta el primero:
# cortar en el primero dejaba pasar un titulo con negrita anidada y sentido
# INVERTIDO ("Un repo ARCHIVADO **jamas** se ignora: usalo siempre") como "mismo
# titulo", porque lo unico comparado era el pedazo "Un repo ARCHIVADO".
# Dos formas rotas devuelven MARCADOR en vez de titulo, y el marcador falla:
#   <SIN-CIERRE>  la linea abre "**" y no lo cierra ahi mismo. Es el titulo
#                 partido en dos lineas: el parser va linea a linea y solo ve
#                 la primera, asi que la mitad de abajo nunca se compara.
#   <ANIDADO>     sobrevive un "**" DENTRO del titulo: eso no es un titulo.
# Los titulos se comparan por PREFIJO, no por igualdad: AGENTS puede recortar la
# cola de un titulo largo, pero el prefijo comun tiene que cubrir al menos
# TITULO_MIN_PCT del titulo canon. El umbral es una proporcion y no los 8
# caracteres fijos de antes: 8 caracteres identifican "Presupues", y en un
# titulo de 50 no identifican nada ("Un repo " entra igual).
TITULO_MIN_PCT=60
law_nums() {   # law_nums <archivo> → numeros de ley, en orden de aparicion
  sed -n 's/^\([0-9][0-9]*[a-z]*\)\. \*\*.*/\1/p' "$1"
}
law_title() {  # law_title <archivo> <num> → titulo, marcador de roto, o vacio
  awk -v num="$2" '
    $0 ~ ("^" num "\\. \\*\\*") {
      resto = substr($0, index($0, "**") + 2)
      cierre = 0
      for (i = 1; i < length(resto); i++) {
        if (substr(resto, i, 2) == "**") cierre = i
      }
      if (cierre == 0) { print "<SIN-CIERRE>"; exit }
      t = substr(resto, 1, cierre - 1)
      gsub(/`/, "", t)
      sub(/[ \t]+$/, "", t)
      if (index(t, "**") > 0) { print "<ANIDADO>"; exit }
      print t
      exit
    }
  ' "$1"
}
law_rota() {   # law_rota <titulo> → cierto si es un marcador de titulo roto
  case "$1" in "<SIN-CIERRE>"|"<ANIDADO>") return 0 ;; *) return 1 ;; esac
}

# Leyes de CLAUDE.md que PUEDEN faltar en AGENTS.md. Hoy VACIA a proposito: los
# dos mapas se sincronizaron ley por ley. Si alguna vez una ley no aplica fuera
# de Claude Code, su numero entra aca a mano y con su motivo escrito; por
# silencio, jamas.
OMISIONES_AGENTS=""

leyes_cl="$(law_nums "$claude_map")"
leyes_ag="$(law_nums "$agents_map")"
if [ -z "$leyes_cl" ] || [ -z "$leyes_ag" ]; then
  # Tercer estado explicito: sin leyes que leer no hay comparacion, y "no pude
  # mirar" no se reporta como verde.
  fail "no encontre leyes numeradas en CLAUDE.md.tmpl y/o AGENTS.md.tmpl: sin mapa que comparar, esto no es verde"
else
  # Direccion canon → AGENTS. Es la que atrapa una ley BORRADA de AGENTS:
  # iterando solo las de AGENTS, borrar una ley entera no dejaba rastro (los
  # playbooks solo citan 6, 7, 12, 14 y 15, asi que el resto se iba en silencio).
  for n in $leyes_cl; do
    t_cl="$(law_title "$claude_map" "$n")"
    t_ag="$(law_title "$agents_map" "$n")"
    if law_rota "$t_cl"; then
      fail "Ley $n en CLAUDE.md: titulo $t_cl (no cierra el ** en su linea, o tiene negrita anidada); asi no hay canon con que comparar"
      continue
    fi
    if law_rota "$t_ag"; then
      fail "Ley $n en AGENTS.md: titulo $t_ag (no cierra el ** en su linea, o tiene negrita anidada); un titulo partido o anidado NO es el mismo titulo"
      continue
    fi
    if [ -z "$t_ag" ]; then
      omitida=no
      for o in $OMISIONES_AGENTS; do
        if [ "$o" = "$n" ]; then omitida=si; fi
      done
      if [ "$omitida" = si ]; then
        pass "Ley $n: ausente en AGENTS.md por omision declarada"
      else
        fail "Ley $n esta en CLAUDE.md y NO en AGENTS.md: quien entra por AGENTS no la tiene. Si de verdad no aplica alla, va en OMISIONES_AGENTS con su motivo"
      fi
      continue
    fi
    igual=no
    largo=0
    case "$t_cl" in "$t_ag"*) igual=si; largo=${#t_ag} ;; esac
    case "$t_ag" in "$t_cl"*) igual=si; largo=${#t_cl} ;; esac
    if [ "$igual" = no ]; then
      fail "Ley $n: CLAUDE dice '$t_cl' y AGENTS dice '$t_ag'; el que entra por AGENTS resuelve la cita a otra ley"
      continue
    fi
    if [ "$((largo * 100))" -lt "$((${#t_cl} * TITULO_MIN_PCT))" ]; then
      fail "Ley $n: el titulo de AGENTS ('$t_ag') coincide en $largo de los ${#t_cl} caracteres del canon, menos del $TITULO_MIN_PCT%: no alcanza para identificar la ley"
      continue
    fi
    pass "Ley $n: mismo titulo en los dos mapas ($t_ag)"
  done
  # Direccion AGENTS → canon: un numero que AGENTS inventa manda a una ley que
  # en el canon es otra, o ninguna.
  inventadas=""
  for n in $leyes_ag; do
    if [ -z "$(law_title "$claude_map" "$n")" ]; then inventadas="$inventadas $n"; fi
  done
  if [ -z "$inventadas" ]; then
    pass "AGENTS.md no numera ninguna ley que CLAUDE.md no tenga"
  else
    fail "AGENTS.md numera leyes que CLAUDE.md no tiene:$inventadas; el numero se toma del canon, no se inventa"
  fi
fi

echo
echo "── toda 'Ley N' citada por un playbook resuelve en LOS DOS mapas"
# Un playbook es la instruccion que el agente ejecuta sin poder preguntar: si
# cita un numero que en SU mapa no existe (o peor: existe y es otra ley), la
# instruccion queda ambigua justo donde tiene que ser dura.
# Se ignoran las lineas de titulo (empiezan con '#'): la "## Ley 0" de
# agents/architect.md es una ley INTERNA de ese rol, no una cita del mapa.
citadas="$(grep -hv '^#' "$ROOT"/templates/commands/*.tmpl "$ROOT"/templates/agents/*.tmpl \
  | grep -oE 'Ley [0-9]+[a-z]?' | sed 's/^Ley //' | sort -u)"
if [ -z "$citadas" ]; then
  fail "cero citas 'Ley N' en los playbooks: o se rompio el grep o las citas se perdieron"
else
  for n in $citadas; do
    falta=""
    c_cl="$(law_title "$claude_map" "$n")"
    c_ag="$(law_title "$agents_map" "$n")"
    if [ -z "$c_cl" ]; then falta="$falta CLAUDE.md"; fi
    if law_rota "$c_cl"; then falta="$falta CLAUDE.md(titulo $c_cl)"; fi
    if [ -z "$c_ag" ]; then falta="$falta AGENTS.md"; fi
    if law_rota "$c_ag"; then falta="$falta AGENTS.md(titulo $c_ag)"; fi
    if [ -z "$falta" ]; then
      pass "la cita 'Ley $n' resuelve en los dos mapas"
    else
      fail "los playbooks citan 'Ley $n' y no existe en:$falta"
    fi
  done
fi

echo
echo "── el carril quick se documenta por lo que recorta Y por lo que conserva"
# quick recorta DELIBERACION (enrichment, abogados, RFC, plan) y nada mas. Un
# mapa que lo anuncia como "el carril rapido" sin decir que la verificacion
# sigue entera se lee como "carril sin gates", y el primer agente que lo tome
# se va a saltar el review creyendo que ese era el trato. Sus dos techos son
# dato de policy.json: repetirlos en prosa sin nombrar la fuente los deja
# derivar, y el numero que gobierna termina siendo el que nadie lee.
pipe="$(cat "$root/templates/docs/pipeline.md.tmpl")"
assert_contains "$pipe" "**quick**" "pipeline.md presenta el carril quick"
assert_contains "$pipe" "hasta 8" "y su techo de archivos"
assert_contains "$pipe" "200 líneas cambiadas" "y su techo de lineas cambiadas"
assert_contains "$pipe" "harness-policy.json" "declarando que los techos son dato, no prosa"
assert_contains "$pipe" "QA determinista" "quick conserva la verificacion completa"
assert_contains "$pipe" "escalate --to express" "el diff que excede la promesa tiene escape nombrado"
assert_contains "$pipe" "quick → express → standard → full" "la escalera de carriles esta completa y en orden"
assert_contains "$pipe" "lo clasifica \`/smart\` solo" \
  "quick dejó de ser solo promesa del humano: el router lo clasifica (ver el bloque del router)"
# Las tres puertas de entrada al harness tienen que nombrarlo: un comando que
# solo existe en una de ellas es un comando que la mitad de las herramientas
# no sabe que puede correr.
assert_contains "$(cat "$root/templates/CLAUDE.md.tmpl")" "\`/quick" \
  "CLAUDE.md enumera /quick entre los comandos del flujo"
assert_contains "$(cat "$root/templates/AGENTS.md.tmpl")" "quick.md" \
  "AGENTS.md lo cita como playbook, que es como entra el que no usa Claude Code"
assert_contains "$readme" "cero deliberación, mismos gates" \
  "el README lo ofrece por lo que es, no como un modo sin gates"

echo
echo "── el renombre a /smart: puntero corto y ratchet contra el nombre viejo"
# `/auto` chocaba con el comando homonimo de otros agentes (Kimi Code), asi que
# el playbook inteligente pasa a llamarse `/smart` y el par queda explicito:
# /smart dimensiona el carril por vos, /quick es el que vos ya dimensionaste.
# El archivo viejo NO desaparece de golpe: queda un PUNTERO de deprecacion por
# un ciclo, para que la instancia que ya tiene el comando viejo instalado no se
# quede sin nada. Esa transicion tiene dos modos de fallo opuestos, y los dos
# terminan igual (el agente obedeciendo instrucciones que ya no gobiernan):
#   1. el puntero engorda y vuelve a documentar reglas: dos playbooks vivos que
#      se contradicen, y manda el que el agente leyo primero.
#   2. el nombre viejo se filtra de vuelta a un doc: se le enseña a la instancia
#      una invocacion que el ciclo que viene no existe.
smart_tmpl="$ROOT/templates/commands/smart.md.tmpl"
ptr="$ROOT/templates/commands/auto.md.tmpl"
assert_file "$smart_tmpl" "el playbook inteligente vive en templates/commands/smart.md.tmpl"

ptr_body() {  # ptr_body <archivo> → el cuerpo, sin el frontmatter YAML
  # El frontmatter (description, argument-hint) es protocolo del comando, no
  # contenido: se descuenta para que el tope mida lo unico que puede engordar.
  awk 'NR==1 && $0 ~ /^---[[:space:]]*$/ { fm=1; next }
       fm==1 && $0 ~ /^---[[:space:]]*$/  { fm=2; next }
       fm!=1 { print }' "$1"
}
PTR_MAX_LINES=6
if [ ! -f "$ptr" ]; then
  # Tercer estado: el dia que el ciclo de gracia termine y el puntero se borre
  # A PROPOSITO, este bloque se borra con el. Mientras tanto, que falte es que
  # alguien lo borro antes de tiempo y la instancia vieja se quedo muda.
  fail "falta templates/commands/auto.md.tmpl: quien corra el comando viejo no recibe ni el aviso de que ahora es /smart (si el ciclo de gracia YA termino y lo borraste a proposito, borra tambien este bloque)"
else
  cuerpo="$(ptr_body "$ptr")"
  n_ptr="$(printf '%s\n' "$cuerpo" | grep -c '[^[:space:]]' | tr -d ' ')"
  if [ "$n_ptr" -le "$PTR_MAX_LINES" ]; then
    pass "el puntero /auto → /smart mide $n_ptr líneas de contenido (tope $PTR_MAX_LINES)"
  else
    fail "el puntero auto.md.tmpl paso a $n_ptr líneas de contenido (tope $PTR_MAX_LINES): un puntero que crece es alguien re-duplicando reglas que ya viven en smart.md.tmpl, y dos copias de un playbook se contradicen sin avisar"
  fi
  assert_contains "$cuerpo" "/smart" "y manda a /smart por su nombre, no a 'el comando nuevo'"
  assert_not_contains "$cuerpo" "## " "el puntero no tiene secciones (la primera es el playbook volviendo a nacer)"
fi

# ── El ratchet: fuera del puntero, ningun playbook invoca ya el nombre viejo.
# Lo que se busca es el COMANDO, no la palabra. Los falsos amigos se quedan
# donde estan y el patron los deja pasar por construccion:
#   · lo que SIGUE a "/auto" no puede ser letra, digito, "_" ni "-", asi que
#     /autofix, /auto-detecta y /automatico no entran.
#   · lo que lo PRECEDE no puede ser parte de una ruta, asi que
#     `commands/auto.md` tampoco: mientras el puntero exista, esa ruta apunta a
#     un archivo que existe de verdad (el MANIFEST lo lista por eso mismo).
#   · los task-ids `AUTO-123` quedan fuera por partida doble: van en mayuscula y
#     llevan guion. Ese prefijo se CONSERVA por compatibilidad (lo genera el
#     panel y los ledgers viejos estan llenos de el).
# La unidad de medida es el PARRAFO, no la linea: la prosa que documenta el
# renombre nombra los dos comandos y se parte en varias lineas al envolver, asi
# que exigir el nombre nuevo en la MISMA linea castigaria un salto de linea.
# Un parrafo que nombra /smart esta EXPLICANDO el renombre y puede citar el
# nombre viejo; uno que solo nombra /auto le esta enseñando a la instancia una
# invocacion que el ciclo que viene no existe, y ese es el que muere.
# Exclusiones de archivo: el puntero (es su tema) y templates/ui/ entero (bundle
# vendorizado que se rebuildea en su propio ciclo; su hint a /auto sigue
# funcionando gracias al puntero). HARDENING.md y las entradas viejas del
# CHANGELOG son historia congelada: no se reescriben, y ademas viven fuera de
# los directorios que esto escanea.
renombre_scan() {  # renombre_scan <archivo> → "linea:texto" por cada /auto suelto
  # El texto se compara con un espacio pegado a cada lado para que el patron no
  # necesite anclas: asi el mismo ERE vale al principio y al final de la linea.
  awk -v VIEJO='[^A-Za-z0-9_./-]/auto[^A-Za-z0-9_-]' \
      -v NUEVO='[^A-Za-z0-9_./-]/smart[^A-Za-z0-9_-]' '
    { texto[NR] = $0
      if ($0 ~ /^[[:space:]]*$/) { par++; next }
      parr[NR] = par
      t = " " $0 " "
      if (t ~ VIEJO) viejo[NR] = 1
      if (t ~ NUEVO) explica[par] = 1 }
    END { for (n = 1; n <= NR; n++)
            if (viejo[n] && !explica[parr[n]]) printf "%d:%s\n", n, texto[n] }
  ' "$1"
}

# Autoverificacion del escaner: un test que no puede fallar no protege nada, y
# este es justo el que tiene que seguir mordiendo dentro de un año. Las dos
# mutaciones se corren SIEMPRE, sobre archivos de juguete, antes de creerle al
# resultado sobre el repo.
tmp_ren="$(mktemp -d)"; trap 'rm -rf "$tmp_ren"' EXIT
cat > "$tmp_ren/suelto.md" <<'MUT'
Corre `/auto PROJ-1` y esperá el reporte final.

Este párrafo sí explica el renombre: `/auto` ahora se llama `/smart`.
MUT
# Los falsos amigos van SIN /smart en todo el archivo, a proposito: si
# estuviera, la exencion de parrafo taparia un patron mal escrito.
cat > "$tmp_ren/amigos.md" <<'MUT'
El panel AUTO-DETECTA la tarea y genera ids como `AUTO-123`.
Corré `scripts/autofix.sh` cuando la autonomía del carril lo permita.
El puntero de deprecación vive en commands/auto.md por un ciclo más.
MUT
mut_suelto="$(renombre_scan "$tmp_ren/suelto.md")"
mut_amigos="$(renombre_scan "$tmp_ren/amigos.md")"
case "$mut_suelto" in
  1:*) pass "el escaner caza un /auto suelto y NO el del parrafo que explica el renombre" ;;
  "")  fail "el escaner no vio un /auto suelto en un archivo que lo tiene: el ratchet de abajo seria decorativo" ;;
  *)   fail "el escaner reporto '$mut_suelto': esperaba la linea 1 y solo la linea 1 (la 3 nombra /smart, o sea explica el renombre)" ;;
esac
[ -z "$mut_amigos" ] && pass "y no confunde AUTO-detecta, autofix, autonomia ni commands/auto.md con el comando" \
  || fail "el escaner marco un falso amigo: $mut_amigos"

set --
for d in templates commands skills docs; do
  [ -d "$ROOT/$d" ] && set -- "$@" "$ROOT/$d"
done
if [ "$#" -eq 0 ]; then
  fail "no encontre ni uno de los directorios de playbooks (templates/, commands/, skills/, docs/): sin nada que escanear esto NO es verde"
else
  # Prefiltro barato: solo los archivos de texto que traen la cadena. El escaner
  # fino corre despues, archivo por archivo.
  candidatos="$(grep -rIlF -- '/auto' "$@" 2>/dev/null \
    | grep -v "^$ROOT/templates/ui/" \
    | grep -v "^$ROOT/templates/commands/auto\.md\.tmpl$")"
  colados=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hits="$(renombre_scan "$f")"
    [ -n "$hits" ] || continue
    rel="${f#"$ROOT"/}"
    colados="$colados$(printf '%s\n' "$hits" | sed "s|^|$rel:|")
"
  done <<CANDIDATOS
$candidatos
CANDIDATOS
  # Control positivo: si el escaneo no ve NI UNA mencion del nombre nuevo, el
  # verde de abajo no significa "esta limpio" sino "no mire nada".
  vistos="$(grep -rIlF -- '/smart' "$@" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$vistos" -gt 0 ]; then
    pass "el escaneo alcanza los playbooks ($vistos archivos nombran /smart)"
  else
    fail "el escaneo no encontro NI UNA mencion de /smart: o no esta mirando donde cree, o el renombre no aterrizo; en los dos casos lo de abajo no prueba nada"
  fi
  if [ -z "$(printf '%s' "$colados" | tr -d '[:space:]')" ]; then
    pass "ningun playbook fuera del puntero invoca /auto"
  else
    fail "el nombre viejo se colo de vuelta: estas lineas invocan /auto y tienen que decir /smart (el puntero es el unico archivo donde el nombre viejo manda, y un parrafo que explica el renombre puede citarlo nombrando /smart)"
    printf '%s' "$colados" | sed 's/^/      /'
  fi
fi

echo
echo "── /smart-pr y /smart-main son WRAPPERS FINOS: la conducta vive en un archivo"
# Las tres entradas (/smart, /smart-pr, /smart-main) son el MISMO playbook y se
# diferencian en un dato: la entrega que declaran. Para que eso siga siendo
# cierto dentro de un año, los wrappers no pueden engordar. Un wrapper que
# vuelve a documentar reglas es un segundo playbook vivo, y cuando los dos se
# contradicen manda el que el agente leyó primero: la misma lección que dejó el
# puntero /auto, medida con la misma regla (ptr_body descuenta el frontmatter,
# que es protocolo del comando y no contenido).
WRAP_MAX_LINES=12
for w in smart-pr smart-main; do
  wf="$ROOT/templates/commands/$w.md.tmpl"
  if [ ! -f "$wf" ]; then
    fail "falta templates/commands/$w.md.tmpl: la entrada que declara esa entrega no existe, y sin ella el humano vuelve a pedirla por chat"
    continue
  fi
  wbody="$(ptr_body "$wf")"
  n_w="$(printf '%s\n' "$wbody" | grep -c '[^[:space:]]' | tr -d ' ')"
  if [ "$n_w" -le "$WRAP_MAX_LINES" ]; then
    pass "el wrapper /$w mide $n_w líneas de contenido (tope $WRAP_MAX_LINES)"
  else
    fail "el wrapper /$w pasó a $n_w líneas de contenido (tope $WRAP_MAX_LINES): dejó de ser un wrapper y empezó a ser un segundo playbook. La regla que agregaste va en smart.md.tmpl, que es el único que manda"
  fi
  assert_contains "$wbody" "commands/smart.md" "/$w delega en el archivo con su ruta, no en 'el comando de siempre'"
done

echo
echo "── pedir permiso para publicar dejó de ser una parada: está prohibido POR ESCRITO"
# El dolor que abrió esto: el agente terminaba de implementar y preguntaba en el
# chat "no commiteé ni shippeé, ¿lo llevo por /review + ship?". La invocación ya
# había contestado eso. La prohibición vive DENTRO de la lista cerrada de
# paradas y no en un párrafo suelto: la lista es lo que el agente lee cuando
# duda si parar, y una regla que no está ahí no gobierna esa duda.
lista="$(printf '%s\n' "$smart" | awk '/^## Dónde SÍ paras/{f=1;next} f&&/^## /{exit} f{print}')"
if [ -z "$lista" ]; then
  fail "no encontré la sección 'Dónde SÍ paras' en smart.md.tmpl: sin la lista cerrada no puedo verificar que la prohibición esté DENTRO, y esto NO es verde"
else
  assert_contains "$lista" "PARA COMMITEAR, SHIPPEAR O PUBLICAR NO ES UNA PARADA" \
    "la lista cerrada declara prohibida la pregunta por la entrega"
  assert_contains "$lista" "re-litigar una" \
    "y la nombra por lo que es: re-litigar una decisión ya tomada"
  assert_contains "$lista" "delivery" \
    "citando el campo de state.json donde la decisión quedó registrada"
fi

echo
echo "── ratchet de prosa normativa: los mapas no engordan"
# Politica de la casa: un incidente nuevo entra como test o gate, no como
# parrafo. Un mapa que crece deja de leerse entero, y una ley que nadie lee no
# gobierna nada. Los topes son el wc -l real del dia que se fijaron: se BAJAN
# cuando alguien reescribe mas corto, jamas se suben para que entre un parrafo.
CLAUDE_MAX_LINES=155
AGENTS_MAX_LINES=146
for par in "CLAUDE.md.tmpl:$CLAUDE_MAX_LINES" "AGENTS.md.tmpl:$AGENTS_MAX_LINES"; do
  arch="${par%:*}"
  tope="${par##*:}"
  if [ ! -f "$ROOT/templates/$arch" ]; then
    fail "ratchet de prosa: no pude medir templates/$arch porque no existe"
    continue
  fi
  hoy="$(wc -l < "$ROOT/templates/$arch" | tr -d ' ')"
  if [ "$hoy" -le "$tope" ]; then
    pass "ratchet de prosa: templates/$arch $hoy ≤ $tope lineas (solo baja)"
  else
    fail "ratchet de prosa: templates/$arch paso a $hoy lineas (tope $tope). Un incidente nuevo entra como test o gate, no como parrafo; si esta ley nueva es imprescindible, otra linea tiene que salir"
  fi
done

# El numero que el mapa se autoadjudica tiene que ser el del ratchet, no una
# aspiracion: decia "Presupuesto: ~110 lineas" con el archivo clavado en 155, o
# sea que se leia violado desde el dia uno. La meta de fondo puede seguir siendo
# ~110, pero el tope declarado es el que rige HOY y se verifica.
cl_tmpl="$ROOT/templates/CLAUDE.md.tmpl"
assert_not_contains "$(cat "$cl_tmpl")" "Presupuesto: ~110 líneas" \
  "CLAUDE.md.tmpl no declara como presupuesto un numero que incumple"
dicho="$(sed -n 's/.*(hoy \([0-9][0-9]*\) líneas).*/\1/p' "$cl_tmpl" | head -1)"
if [ -z "$dicho" ]; then
  fail "CLAUDE.md.tmpl no declara su tope real con la forma '(hoy N líneas)': sin numero verificable el presupuesto vuelve a ser prosa"
elif [ "$dicho" = "$CLAUDE_MAX_LINES" ]; then
  pass "el tope que declara CLAUDE.md.tmpl ($dicho) es el del ratchet ($CLAUDE_MAX_LINES)"
else
  fail "CLAUDE.md.tmpl dice '(hoy $dicho líneas)' y el ratchet es $CLAUDE_MAX_LINES: el mapa miente sobre su propio tope"
fi

echo
echo "── el plan no cita runtime: lo ejecuta"
# Caso real (una instancia, tres rondas): el plan del architect marco DOS
# decisiones como "verificado en codigo" sobre el comportamiento en runtime de
# una libreria de routing, leyendo su fuente. Las dos eran falsas y costaron dos
# de las tres rondas. Leer el fuente de una dependencia dice lo que escribio su
# autor, no lo que hace TU version con TU config en TU runtime: para runtime, la
# unica evidencia que cuenta es una EJECUCION con su salida. Se testea frase por
# frase porque cada una carga una pieza distinta de la regla (el disparador, la
# evidencia admisible, la que NO lo es, el caso, y el destino de lo no
# ejecutado): si sobrevive solo el titulo, la regla no gobierna ninguna
# decision.
arch_tmpl="$ROOT/templates/agents/architect.md.tmpl"
rfc_tmpl="$ROOT/templates/commands/rfc.md.tmpl"
# Se compara sobre el texto APLANADO (saltos de linea y sangria a un espacio):
# la regla es prosa envuelta a 72 columnas y una frase parte en dos lineas donde
# caiga el corte. Buscar sobre el crudo ataria el test al ancho del parrafo, y
# reacomodar una coma lo pondria rojo sin que la regla hubiera cambiado.
flat_tmpl() { tr '\n' ' ' < "$1" | tr -s ' '; }
if [ ! -f "$arch_tmpl" ] || [ ! -f "$rfc_tmpl" ]; then
  # Tercer estado: sin los dos archivos no hay nada que comparar. Un
  # assert_not_contains sobre texto vacio pasa siempre, asi que callarlo aqui
  # dejaria el bloque en verde por no haber mirado nada.
  fail "no puedo verificar la regla de runtime: falta templates/agents/architect.md.tmpl o templates/commands/rfc.md.tmpl, y sin ellos este bloque NO es verde"
else
  arch="$(flat_tmpl "$arch_tmpl")"
  assert_contains "$arch" "Runtime no se cita: se ejecuta" \
    "architect.md declara la regla de runtime"
  assert_contains "$arch" "comportamiento en runtime" \
    "y nombra el disparador: la decision depende del runtime de una dependencia externa"
  assert_contains "$arch" "**EJECUCIÓN**" \
    "la evidencia admisible es una ejecucion, no una lectura"
  assert_contains "$arch" "junto al comando que la produjo" \
    "y la salida viaja con el comando que la produjo (sin comando no es reproducible)"
  assert_contains "$arch" "no lo que hace TU versión" \
    "dice por que el fuente no sirve: es el codigo del autor, no tu runtime"
  assert_contains "$arch" "dos de tres rondas" \
    "el caso que fija la regla viene con su costo medido"
  assert_contains "$arch" "no verifica nada" \
    "'lo lei en su fuente' se declara explicitamente como no verificacion"
  assert_contains "$arch" "**SUPUESTO**" \
    "lo no ejecutado baja a SUPUESTO del ledger, no sube a verificado"
  # El puntero de /rfc: UNA linea que manda al architect. Duplicar el cuerpo ahi
  # es garantizar que las dos copias diverjan y que mande la que el agente leyo
  # primero (el mismo modo de fallo del puntero /auto, mas arriba).
  rfc="$(flat_tmpl "$rfc_tmpl")"
  assert_contains "$rfc" "se responde EJECUTANDO" \
    "/rfc aplica la regla a la sonda sobre runtime"
  # La ruta se exige DENTRO de la frase del puntero: /rfc ya nombra
  # `.claude/agents/architect.md` en el paso 6 (por el formato de bloques
  # `### T<n>`), asi que buscar la ruta suelta daba verde aunque el puntero no
  # existiera (medido: al borrar el puntero, esa asercion seguia en verde).
  assert_contains "$rfc" "regla y caso en \`.claude/agents/architect.md\`" \
    "y apunta al architect por su ruta, en vez de copiar la regla"
  assert_not_contains "$rfc" "dos de tres rondas" \
    "/rfc no duplica el cuerpo de la regla (un duplicado diverge)"
fi

echo
echo "── QA: identidad del servidor antes de medir, y asserts que pueden fallar"
# Dos errores de UNA corrida de campo, los dos en QA y ninguno visible para un
# gate mecanico:
#   1. se midio contra el puerto 4321 sin verificar QUE estaba sirviendo ahi:
#      era un dev server viejo, o sea la medicion de OTRO arbol. El antidoto ya
#      existia un paso mas tarde en el pipeline (verify_cmd post-deploy: curl +
#      grep de un marcador); esto lo corre antes de medir.
#   2. un assert de Playwright evaluaba antes de que el dato llegara, asi que no
#      podia fallar: el verde vacuo costo la ronda 3 entera.
# El gate de suite del precheck alcanza a los tests de suite; al QA exploratorio
# (navegador) no lo alcanza ninguno, asi que su disciplina vive en el prompt y
# se testea frase por frase: si sobrevive solo el titulo, la regla no gobierna
# la decision. Se compara sobre el texto APLANADO (flat_tmpl) porque la prosa va
# envuelta a ~70 columnas y reacomodar una coma no puede poner esto en rojo.
qa_tmpl="$ROOT/templates/agents/qa.md.tmpl"
rev_tmpl="$ROOT/templates/commands/review.md.tmpl"
if [ ! -f "$qa_tmpl" ] || [ ! -f "$rev_tmpl" ]; then
  # Tercer estado: sin los archivos no hay nada que comparar, y "no pude mirar"
  # no se reporta como verde.
  fail "no puedo verificar las reglas de QA: falta templates/agents/qa.md.tmpl o templates/commands/review.md.tmpl, y sin ellos este bloque NO es verde"
else
  qa_flat="$(flat_tmpl "$qa_tmpl")"
  rev_flat="$(flat_tmpl "$rev_tmpl")"

  # Regla 1, en el agente que mide.
  assert_contains "$qa_flat" "Identidad del servidor ANTES de medir" \
    "qa.md declara la regla de identidad del servidor"
  assert_contains "$qa_flat" "QUÉ está sirviendo ahí" \
    "y dice que lo primero es saber QUE contesta en ese puerto"
  assert_contains "$qa_flat" "marcador de build" \
    "con la sonda admisible: marcador de build, versión o contenido propio del árbol"
  assert_contains "$qa_flat" "REGISTRA" \
    "la identidad no se mira y se olvida: se registra con la evidencia"
  assert_contains "$qa_flat" "\`verify_cmd\` usa post-deploy" \
    "y se ata al patrón que ya existe post-deploy, un paso antes"
  assert_contains "$qa_flat" "puerto 4321" \
    "el caso real viene con su puerto, no como principio abstracto"
  assert_contains "$qa_flat" "dev server viejo de OTRO árbol" \
    "y con lo que de verdad contestaba: otro árbol"
  assert_contains "$qa_flat" "sin identidad del servidor no respalda" \
    "una medición sin identidad no sostiene el pass"

  # Regla 2, la que ningun gate puede cubrir.
  assert_contains "$qa_flat" "Un assert verde solo cuenta si PUDO fallar" \
    "qa.md declara la regla del assert que puede fallar"
  assert_contains "$qa_flat" "demostrá UNA vez que el assert muerde" \
    "y pide la demostración, no la intención"
  assert_contains "$qa_flat" "nunca un \`sleep\` ni una lectura temprana" \
    "esperar la condición de verdad excluye el sleep y la lectura temprana"
  assert_contains "$qa_flat" "un selector ausente" \
    "con los estados contra los que el assert tiene que fallar"
  assert_contains "$qa_flat" "el árbol base sin el cambio" \
    "incluido el árbol base, que es el control negativo más barato"
  assert_contains "$qa_flat" "se llevó la ronda 3" \
    "el costo del verde vacuo está medido en rondas"
  assert_contains "$qa_flat" "gate mecánico de la suite no puede ver esto" \
    "y se dice por qué la regla es del prompt: ningún gate la alcanza"

  # Regla 1 tambien en el punto donde el orquestador LANZA QA: si solo vive en
  # el agente, el QA determinista (que no lee qa.md) mide sin identidad igual.
  assert_contains "$rev_flat" "Identidad del servidor antes de medir" \
    "review.md exige la identidad del servidor al lanzar QA"
  assert_contains "$rev_flat" "verifica QUÉ está sirviendo ahí" \
    "y la pide como primer comando de QA, agente o determinista"
  assert_contains "$rev_flat" "\`verify_cmd\` (curl + grep del marcador) un paso antes" \
    "nombrando el patrón post-deploy del que es un paso previo"
  assert_contains "$rev_flat" "puerto 4321" \
    "con el caso de campo y su puerto"
  assert_contains "$rev_flat" "dev server viejo de OTRO árbol" \
    "y el árbol equivocado que respondía"
fi

echo
echo "── el doc del MOTOR enseña el camino de vuelta y quién mueve la fase"
# Tres casos de campo distintos terminaron en la misma pregunta: "avancé la fase
# antes de tiempo, cómo vuelvo". El mecanismo existe (harness-policy.py rollback,
# y la transición review→ship la registra ship.sh solo), pero el doc que se
# INSTALA con el motor no lo mencionaba: quien leía docs/harness/policy.md para
# saber cómo se mueve una fase encontraba solo `transition`, que apunta hacia
# adelante, y concluía que no había vuelta. De ahí sale "editá state.json a
# mano", que es justo lo que la constitución prohíbe.
pol="$(cat "$root/templates/docs/policy.md")"
assert_contains "$pol" "harness-policy.py rollback" \
  "policy.md nombra el comando que deshace un avance equivocado"
assert_contains "$pol" "POLICY-ROLLBACK-003" \
  "y su restricción: el rollback solo va hacia atrás"
assert_contains "$pol" "POLICY-SHIP-004" \
  "policy.md explica por qué la fase no avanza con repos sin shippear"
assert_contains "$pol" "ship.sh" \
  "y quién es el dueño de la transición review a ship"

echo
echo "── el router de carril: quick ya lo clasifica /smart, y con qué límite"
# La decisión ANTERIOR (quick es promesa del humano, /smart no lo elige) estaba
# escrita con fundamento en tres lugares. Revertirla sin actualizarlos dejaba el
# template contradiciéndose solo, así que el contrato es que los tres digan lo
# mismo.
assert_contains "$smart" "| **quick** |" "la tabla de carriles del paso 0.1 incluye quick"
assert_contains "$smart" "evidencia positiva" \
  "y exige evidencia positiva de ownership para clasificarlo"
assert_not_contains "$smart" "/smart NO lo elige por su cuenta" \
  "el fundamento viejo no sobrevive al cambio"
assert_not_contains "$smart" "no lo eliges tú" \
  "ni su eco en el reporte final"
assert_contains "$smart" "init tasks/<id> --lane quick" \
  "el MECANISMO es explícito: init con el carril y el flujo de /quick inline"
pipe_doc="$(cat "$root/templates/docs/pipeline.md.tmpl")"
assert_not_contains "$pipe_doc" "quick es promesa del humano, no clasificación" \
  "el doc del pipeline no queda contradiciendo al comando"
assert_contains "$pipe_doc" "POLICY-LANE-004" \
  "y nombra el piso que sostiene la clasificación automática"
# El límite honesto: gate_lane NO frena cruces de ownership dentro de un repo.
assert_contains "$smart" "cruce de OWNERSHIP dentro de un mismo repo" \
  "el backstop se declara PARCIAL, que es lo que hace segura la regla"

echo
echo "── continuar agentes en vez de re-spawnearlos: la herramienta se NOMBRA"
# La regla existía en prosa ("el reviewer es PERSISTENTE") y no se cumplía: 16
# reviewers en una tarea de un repo con dos rondas. Ningún prompt nombraba nunca
# la herramienta, así que el único camino ejecutable escrito era el escape.
rev_cmd="$(cat "$root/templates/commands/review.md.tmpl")"
assert_contains "$smart" "SendMessage" "smart nombra la herramienta que continúa un agente"
assert_contains "$rev_cmd" "SendMessage" "y review también, que es donde vive el loop de rondas"
assert_contains "$smart" "agents.json" "con el registro de ids que la vuelve ejecutable"
assert_contains "$rev_cmd" "agents.json" "en los dos lados"
assert_contains "$rev_cmd" "EXCEPCIÓN DECLARADA" \
  "y relanzar queda como excepción declarada, no como default silencioso"

echo
echo "── general-purpose prohibido, con la alternativa al lado"
assert_contains "$smart" "general-purpose" "smart nombra al agente prohibido"
assert_contains "$smart" "PROHIBIDO" "y lo prohíbe explícitamente"
for herramienta in "graphify query" "semble search" "Serena" "Explore"; do
  assert_contains "$smart" "$herramienta" "y ofrece la alternativa: $herramienta"
done

echo
echo "── una fase, una sesión: el relevo tiene dueño escrito"
# Lo que no puede quedar ambiguo es QUIÉN ejecuta el corte: un prompt no puede
# terminarse a sí mismo ni relanzarse. Sin dueño, esto es prosa aspiracional.
assert_contains "$smart" "handoff.json" "smart nombra el marcador del relevo"
assert_contains "$smart" "orchestrator-watch.sh" "y quién ejecuta el corte"
assert_contains "$pol" "handoff.json" "policy.md documenta el relevo"
assert_contains "$pol" "session_id" "y el campo que lo hace auditable"

t_done
