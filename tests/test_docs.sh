#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"

echo "── contratos de documentación"
root="$(cd "$(dirname "$0")/.." && pwd)"

readme="$(cat "$root/README.md")"
auto="$(cat "$root/templates/commands/auto.md.tmpl")"
index="$(cat "$root/templates/docs/index.md.tmpl")"

assert_not_contains "$readme" "127.0.0.1:7717" "README no conserva el puerto viejo"
assert_not_contains "$readme" "exactamente diez" "README no duplica el número de paradas"
assert_contains "$auto" "Lista cerrada de paradas" "auto declara el contrato cerrado"
assert_contains "$auto" "harness-policy.py pause" "auto registra pausas mediante policy"
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

# ── Ley 13: la recomendada es la duradera, nunca la rápida.
# Caso real: un agente marcó "editar state.json a mano (recomendado)" porque no
# había vuelta atrás por CLI. Era lo rápido, violaba una ley del propio
# CLAUDE.md, y el hueco real (falta un rollback) quedó sin reportar.
claude_md="$root/templates/CLAUDE.md.tmpl"
const="$root/templates/docs/constitution.md.tmpl"
assert_contains "$(cat "$claude_md")" "elimina la causa" "CLAUDE.md tiene la Ley 13"
assert_contains "$(cat "$claude_md")" "NUNCA como" "Ley 13: el atajo nunca va como recomendado"
assert_contains "$(cat "$claude_md")" "Ley 12" "Ley 13: un camino que falta es un bug del harness, no un permiso"
assert_contains "$(cat "$const")" "2b." "la constitución tiene la sección de lo correcto sobre lo rápido"
# La tensión con "código mínimo" tiene que quedar resuelta EN EL TEXTO: sin
# esto, un agente lee la ley nueva como permiso para sobre-construir, que es
# justo lo que §2 y §3 existen para impedir.
assert_contains "$(cat "$claude_md")" "constitución §2" "Ley 13 aclara que no afloja el código mínimo"
assert_contains "$(cat "$const")" "ALCANCE" "la constitución separa alcance (§2) de clase de arreglo (§2b)"
assert_contains "$(cat "$root/templates/commands/auto.md.tmpl")" "elimina la causa" \
  "/auto aplica la Ley 13 al ADR que propone al humano"

# ── Enrichment: la única interacción con el humano, al principio.
# Concentrar ahí lo que solo el humano sabe es lo que permite que el resto
# corra sin interrupciones. El modo de fallo de esta fase es la CEREMONIA:
# preguntar por preguntar reintroduce justo el "se para mucho" que vino a
# resolver, así que la barra de calidad se testea igual que la fase.
auto_md="$root/templates/commands/auto.md.tmpl"
assert_contains "$(cat "$auto_md")" "Enrichment" "/auto tiene la fase de enrichment"
assert_contains "$(cat "$auto_md")" "ÚNICA interacción" "el enrichment se declara como la única interacción"
assert_contains "$(cat "$auto_md")" "Entiende el terreno ANTES" "primero el terreno, después la tarea"
assert_contains "$(cat "$auto_md")" "Máximo 5" "la ronda de preguntas tiene techo"
assert_contains "$(cat "$auto_md")" "el default que" "cada pregunta trae su default (el silencio es respuesta válida)"
assert_contains "$(cat "$auto_md")" "Si nada califica" "no preguntar es un resultado válido, no una falla"
assert_contains "$(cat "$auto_md")" "enrichment.md" "la fase deja artefacto auditable"
assert_contains "$(sed 's/{{LOOP_BUDGET}}/3/' "$root/templates/policy.json.tmpl")" \
  "enrichment_questions" "la pausa del enrichment es una parada registrada en policy"
assert_contains "$(cat "$root/templates/docs/intake.md.tmpl")" "enrichment" \
  "intake.md ya no contradice a /auto sobre rebotar con preguntas"

# ── Ley de estilo (CONTRIBUTING #6): el guion largo "—" delata prosa de IA.
# RATCHET al estilo ratchet-keeper: el conteo del repo SOLO puede bajar.
# Al reescribir prosa vieja, baja el número de abajo al nuevo conteo (nunca
# lo subas: si tu cambio lo sube, reescribe sin el guion largo). Las cajas
# de terminal "──" (U+2500) son otro carácter y no cuentan.
EMDASH_MAX=487
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
au="$(cat "$ROOT/templates/commands/auto.md.tmpl")"
assert_contains "$au" "Una pantalla" "el reporte final de /auto esta acotado"
# La numeracion de las leyes no puede tener huecos ni repetidos: se citan por
# numero desde los prompts ("Ley 6", "Ley 12"), y un salto manda a la ley
# equivocada.
nums="$(grep -oE '^[0-9]+\.' "$ROOT/templates/CLAUDE.md.tmpl" | tr -d '.' | sort -n | uniq)"
dups="$(grep -oE '^[0-9]+\.' "$ROOT/templates/CLAUDE.md.tmpl" | tr -d '.' | sort -n | uniq -d)"
[ -z "$dups" ] && pass "las leyes no tienen numeros repetidos" || fail "leyes duplicadas: $dups"

t_done
