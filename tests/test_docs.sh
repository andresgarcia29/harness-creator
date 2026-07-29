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
EMDASH_MAX=444
emdash_now=$(grep -ro "—" --include="*.md" --include="*.tmpl" --include="*.yaml" \
  --include="*.sh" --include="*.py" --include="*.json" "$root" 2>/dev/null \
  | grep -v "/\.git/" | grep -v "templates/ui/dist" | wc -l | tr -d ' ')
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
assert_contains "$pipe" "jamás lo elige" "quick es promesa del humano: /smart no lo elige solo"
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

t_done
