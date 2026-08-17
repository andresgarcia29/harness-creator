#!/usr/bin/env bash
# test_update_migrate.sh: las migraciones del update dejaron de ser prosa.
#
# Mientras vivieron dentro de commands/harness-update.md las ejecutaba un LLM
# con permisos de escritura sobre una instancia real, y ese tramo produjo los
# fallos caros del update. Este test fija las dos mitades del contrato:
#   · lo DOCUMENTADO se aplica solo, idempotente y sin tocar lo ya decidido;
#   · lo que exige JUICIO (mapear un id crudo de modelo a un alias) NO se
#     aplica: se detecta, se nombra y sale por el tercer estado.
# Hermético: crea su workspace temporal, no toca red ni el workspace real.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

MIG="$ROOT/scripts/update-migrate.sh"
UPD="$ROOT/commands/harness-update.md"

mk_ws() {  # mk_ws <nombre> → ruta de una instancia de fixture, vacía
  mkdir -p "$WS/$1"
  printf '%s' "$WS/$1"
}

ans_viejo() {  # answers anterior a upstream_issues y a models.provider
  cat > "$1/harness-answers.yaml" <<'EOF'
harness_version: "0.30.0"
generated_at: "2026-01-01T00:00:00Z"

project:
  name: "acme"
  ticket_prefix: "ACME"

flow: trunk

models:
  architect: deep
  reviewer: smart
  implementer: smart
  mechanical: fast
  escalation: deep

loop_budget: 3

autonomy: checkpoint
EOF
}

ans_ids_crudos() {  # answers de una instancia anterior al esquema de aliases:
                    # los roles de models: traen el ID CRUDO del modelo
  cat > "$1/harness-answers.yaml" <<'EOF'
harness_version: "0.30.0"
generated_at: "2026-01-01T00:00:00Z"

project:
  name: "acme"
  ticket_prefix: "ACME"

flow: trunk

models:
  architect: claude-opus-4-1
  reviewer: claude-sonnet-4-5
  implementer: fast
  mechanical: fast
  escalation: claude-opus-4-1

loop_budget: 3

autonomy: checkpoint
EOF
}

models_nuevo() {  # esquema de aliases (nada que migrar)
  cat > "$1/models.yaml" <<'EOF'
provider: anthropic

models.anthropic:
  fast: sonnet
  smart: opus
  deep: opus

roles:
  architect: deep
  reviewer: smart
  implementer: smart
  mechanical: fast
  escalation: deep

overrides:
EOF
}

models_viejo() {  # esquema viejo: ids crudos, sin provider ni secciones
  cat > "$1/models.yaml" <<'EOF'
# instalación vieja: roles con IDs crudos
roles:
  architect: claude-opus-4-1
  reviewer: claude-sonnet-4-5
  implementer: claude-sonnet-4-5
  mechanical: fast
  # worker: este comentario indentado no es un rol

overrides:
EOF
}

esquema_ok() {  # el esquema del answers es FIJO: doctor.sh lo parsea con
                # grep/awk línea a línea, así que una línea que no sea clave a
                # columna 0, hijo indentado, comentario o vacía lo rompe en
                # silencio. Esto verifica que el migrador no lo ensució.
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^[A-Za-z_][A-Za-z0-9_.]*:/ { next }
    /^  [^[:space:]]/ { next }
    { print "línea fuera del esquema (" NR "): " $0; mal = 1 }
    END { exit mal ? 1 : 0 }
  ' "$1"
}

up_val() {  # valor registrado de upstream_issues
  awk '/^upstream_issues:/ { sub(/^upstream_issues:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); print; exit }' "$1"
}

echo "── (a) answers viejo: la clave documentada se agrega sola"
A="$(mk_ws caso-a)"; ans_viejo "$A"; models_nuevo "$A"
out="$(bash "$MIG" "$A" 2>&1)"; rc=$?
assert_eq 0 "$rc" "answers viejo + models al día: exit 0"
assert_contains "$out" "answers.upstream_issues" "nombra la migración por su id"
assert_contains "$out" "aplicada" "y dice que la aplicó"
assert_contains "$out" "DECLARALO al humano" "declara lo único que sale de la máquina (no lo esconde)"
assert_eq 1 "$(grep -cE '^upstream_issues:' "$A/harness-answers.yaml")" "queda UNA sola clave upstream_issues"
assert_eq auto "$(up_val "$A/harness-answers.yaml")" "con el default DOCUMENTADO (auto), no uno inventado"
assert_eq anthropic "$(awk '/^[^ #]/ { s = ($1 == "models:") } s && $1 == "provider:" { print $2; exit }' "$A/harness-answers.yaml")" \
  "models.provider migrado con su default documentado"
# Los valores de models.* se AUDITAN contra la whitelist de aliases, y con
# aliases legítimos la auditoría no dispara: si disparara acá sería ruido y el
# update entero saldría 2 por nada.
assert_contains "$out" "answers.models.aliases" "también audita que models.* hable en aliases"
assert_contains "$out" "ya son aliases" "y con aliases legítimos no dispara"
assert_not_contains "$out" "· models." "no nombra ninguna clave como fuera de whitelist"
if esquema_ok "$A/harness-answers.yaml"; then
  pass "el answers migrado sigue en el esquema fijo (lo que doctor.sh parsea)"
else
  fail "el answers migrado rompe el esquema fijo"
fi
# Las decisiones registradas son ley: migrar agrega, jamás reescribe.
assert_contains "$(cat "$A/harness-answers.yaml")" "flow: trunk" "no toca las decisiones registradas (flow)"
assert_contains "$(cat "$A/harness-answers.yaml")" "  architect: deep" "ni los valores del bloque models"
assert_contains "$(cat "$A/harness-answers.yaml")" "autonomy: checkpoint" "ni lo que venía después del punto de inserción"
# Un archivo sin salto final le come la última línea a cualquier `read`.
[ -z "$(tail -c1 "$A/harness-answers.yaml")" ] && pass "el archivo termina con salto de línea" \
  || fail "el archivo migrado no termina con salto de línea"
if grep -q "$(printf '\t')" "$A/harness-answers.yaml"; then
  fail "el migrador metió tabs en un YAML"
else
  pass "sin tabs (un tab en YAML es un archivo inválido)"
fi

echo
echo "── (b) segunda corrida: no-op que lo DICE (idempotencia)"
# "byte a byte" se compara con cmp, no con $(cat): la sustitución de comando
# RECORTA los saltos de línea finales, así que un migrador que se comiera el
# último \n pasaba el test. cmp compara los bytes que hay en el disco.
antes="$WS/caso-a.antes"; cp "$A/harness-answers.yaml" "$antes"
out="$(bash "$MIG" "$A" 2>&1)"; rc=$?
assert_eq 0 "$rc" "answers ya migrado: exit 0"
assert_contains "$out" "saltada" "nombra la migración como saltada"
assert_contains "$out" "ya presente con valor 'auto'" "y dice POR QUÉ la saltó"
assert_contains "$out" "0 aplicada(s)" "no vuelve a aplicar nada (el resumen lo cuenta)"
if cmp -s "$antes" "$A/harness-answers.yaml"; then
  pass "el archivo queda byte a byte igual (cmp, incluidos los saltos finales)"
else
  fail "el archivo cambió en la segunda corrida ($(wc -c < "$antes") bytes antes, $(wc -c < "$A/harness-answers.yaml") después)"
fi

echo
echo "── (b2) una decisión registrada NUNCA se pisa con el default"
G="$(mk_ws caso-off)"; ans_viejo "$G"; models_nuevo "$G"
printf 'upstream_issues: off\n' >> "$G/harness-answers.yaml"
bash "$MIG" "$G" >/dev/null 2>&1
assert_eq off "$(up_val "$G/harness-answers.yaml")" "'off' sobrevive al migrador (el humano ya decidió)"

echo
echo "── (c) models.yaml crudo: detecta, nombra y NO inventa el mapeo"
C="$(mk_ws caso-c)"; ans_viejo "$C"; models_viejo "$C"
bash "$MIG" "$C" >/dev/null 2>&1   # deja el answers al día: aísla el caso
antes_models="$WS/caso-c.models.antes"; cp "$C/models.yaml" "$antes_models"
out="$(bash "$MIG" "$C" 2>&1)"; rc=$?
assert_eq 2 "$rc" "esquema viejo de models.yaml: exit 2 (tercer estado)"
assert_contains "$out" "NO PUDE DETERMINAR" "lo declara como no determinado, ni verde ni rojo"
assert_contains "$out" "roles.architect: 'claude-opus-4-1'" "nombra el rol y el id crudo que encontró"
assert_contains "$out" "roles.reviewer: 'claude-sonnet-4-5'" "cada uno, no solo el primero"
assert_not_contains "$out" "roles.mechanical" "un rol que YA habla en aliases no se reporta como crudo"
assert_contains "$out" "remediación" "trae remediación, estilo doctor"
assert_contains "$out" "no es una función" "y el motivo real: el mapeo inverso no es una función"
if cmp -s "$antes_models" "$C/models.yaml"; then
  pass "models.yaml queda INTACTO byte a byte (un mapeo inventado se ve igual de verde)"
else
  fail "el migrador tocó models.yaml ($(wc -c < "$antes_models") bytes antes, $(wc -c < "$C/models.yaml") después)"
fi

echo
echo "── (c2) lo mecánico se aplica aunque lo otro quede pendiente"
F="$(mk_ws caso-mixto)"; ans_viejo "$F"; models_viejo "$F"
out="$(bash "$MIG" "$F" 2>&1)"; rc=$?
assert_eq 2 "$rc" "con un pendiente de juicio, el exit es 2 (2 nunca degrada a 0)"
assert_eq auto "$(up_val "$F/harness-answers.yaml")" "y aun así aplicó la migración mecánica"
assert_contains "$out" "exit 2: hay migraciones sin resolver" "el cierre dice que exit 2 NO es éxito"

echo
echo "── (c2b) .serena/project.yml: el update ARREGLA la ceguera, no la avisa (#214)"
# Una instancia ya instalada nunca vuelve a correr discover.sh, así que sin esta
# migración el arreglo del #214 solo llegaba a workspaces nuevos y toda instancia
# viva se quedaba con Serena ignorando el 100% del código (repos/ gitignoreado +
# ignore_all_files_in_gitignore: true por default).
S="$(mk_ws caso-serena)"; ans_viejo "$S"; models_nuevo "$S"
mkdir -p "$S/repos/svc" && git -C "$S/repos/svc" init -q && touch "$S/repos/svc/go.mod"
mkdir -p "$S/.serena"
printf 'project_name: "caso-serena"\nlanguage_servers:\n- bash\nignore_all_files_in_gitignore: true\n' \
  > "$S/.serena/project.yml"

out="$(bash "$MIG" "$S" --dry-run 2>&1)"
assert_contains "$out" "SE APLICARÍA" "el dry-run dice que hay que arreglarlo"
assert_contains "$(cat "$S/.serena/project.yml")" "ignore_all_files_in_gitignore: true" \
  "y el dry-run NO escribió: el archivo sigue como estaba"

out="$(bash "$MIG" "$S" 2>&1)"; rc=$?
assert_eq 0 "$rc" "la migración es mecánica de punta a punta: no hay nada que consultar"
assert_contains "$out" "serena.project_yml" "la nombra por su id"
yml="$(cat "$S/.serena/project.yml")"
assert_contains "$yml" "ignore_all_files_in_gitignore: false" \
  "#214: deja de heredar el .gitignore, donde vive repos/"
assert_not_contains "$yml" "language_servers:
- bash" "y el [bash] que Serena autodetectó desde la raíz ya no está solo"

out="$(bash "$MIG" "$S" 2>&1)"
assert_contains "$out" "ya hay .serena/project.yml" "segunda corrida: no-op que lo dice (idempotencia)"

echo
echo "── (c3) answers con IDs crudos bajo models: no puede salir verde"
# El agujero real: la ley de cabecera del script dice que lo que exige elegir se
# detecta y se reporta, y un answers viejo con 'architect: claude-opus-4-1'
# salía rc=0 con todo verde porque el migrador ni lo migraba ni lo miraba.
# El answers es la fuente de la re-instanciación: verde ahí es un update que
# sigue con decisiones que nadie tomó.
H="$(mk_ws caso-ids)"; ans_ids_crudos "$H"; models_nuevo "$H"
out="$(bash "$MIG" "$H" 2>&1)"; rc=$?
assert_eq 2 "$rc" "models.* con ids crudos: exit 2 (tercer estado, ni verde ni rojo)"
assert_contains "$out" "answers.models.aliases" "nombra la migración por su id"
assert_contains "$out" "NO PUDE DETERMINAR" "y la declara como no determinada"
assert_contains "$out" "· models.architect: 'claude-opus-4-1'" "nombra la clave y el valor crudo que encontró"
assert_contains "$out" "· models.escalation: 'claude-opus-4-1'" "cada una, no solo la primera"
assert_not_contains "$out" "· models.implementer" "una clave que YA habla en alias no se reporta"
assert_not_contains "$out" "· models.provider" "provider: no es un rol: queda fuera de la whitelist de aliases a propósito"
assert_contains "$out" "no es una función" "con el motivo: el mapeo inverso id → alias no es una función"
assert_contains "$out" "remediación" "y con remediación, estilo doctor"
# El valor crudo se nombra, JAMÁS se reescribe: un alias adivinado se ve igual
# de verde que uno elegido con el humano.
assert_contains "$(cat "$H/harness-answers.yaml")" "  architect: claude-opus-4-1" "no inventa el alias: deja el valor crudo como está"

echo
echo "── (d) --dry-run no escribe: ni una línea, ni un temporal"
D="$(mk_ws caso-d)"; ans_viejo "$D"; models_nuevo "$D"
copia="$WS/caso-d.antes"; cp "$D/harness-answers.yaml" "$copia"
out="$(bash "$MIG" "$D" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "dry-run con migraciones pendientes: exit 0"
assert_contains "$out" "SE APLICARÍA" "dice qué haría"
assert_contains "$out" "dry-run: no escribí nada" "y que no escribió"
# Se comparan los BYTES y no el mtime a propósito: el mtime tiene resolución de
# segundo en varios filesystems, así que una escritura dentro del mismo segundo
# pasaría el test. Y se compara con cmp y no con $(cat): la sustitución de
# comando recorta los saltos finales, así que una reescritura que solo se comió
# el último \n también pasaba. Los bytes no mienten.
if cmp -s "$copia" "$D/harness-answers.yaml"; then
  pass "el answers queda byte a byte igual (cmp, incluidos los saltos finales)"
else
  fail "el dry-run escribió: $(wc -c < "$copia") bytes antes, $(wc -c < "$D/harness-answers.yaml") después"
fi
sobrantes=0
for f in "$D"/harness-answers.yaml.* "$D"/models.yaml.*; do
  if [ -e "$f" ]; then sobrantes=$((sobrantes+1)); fi
done
assert_eq 0 "$sobrantes" "no deja temporales de mktemp sueltos en el workspace"

echo
echo "── (e) sin answers: tercer estado con remediación, jamás verde"
E="$(mk_ws caso-e)"
out="$(bash "$MIG" "$E" 2>&1)"; rc=$?
assert_eq 2 "$rc" "workspace sin harness-answers.yaml: exit 2"
assert_contains "$out" "no hay harness-answers.yaml" "dice exactamente qué no pudo mirar"
assert_contains "$out" "remediación" "con remediación"
assert_contains "$out" "0 aplicada(s)" "y no reporta nada como aplicado"
out="$(bash "$MIG" "$WS/no-existe-este-dir" 2>&1)"; rc=$?
assert_eq 2 "$rc" "workspace inexistente: exit 2 (no 0 ni 1)"
assert_contains "$out" "no es un directorio accesible" "y lo nombra"

echo
echo "── (f) el placeholder literal no se tapa con el default"
P="$(mk_ws caso-ph)"; ans_viejo "$P"; models_nuevo "$P"
printf 'upstream_issues: {{UPSTREAM_ISSUES}}\n' >> "$P/harness-answers.yaml"
out="$(bash "$MIG" "$P" 2>&1)"; rc=$?
assert_eq 2 "$rc" "answers con placeholder sin sustituir: exit 2"
assert_contains "$out" "placeholder literal" "lo nombra como lo que es (generación a medias)"
assert_contains "$(cat "$P/harness-answers.yaml")" "{{UPSTREAM_ISSUES}}" "no lo pisa: taparlo escondería el fallo del generador"

echo
echo "── (g) el update ya no re-instancia de memoria como primera opción"
upd="$(cat "$UPD")"
assert_contains "$upd" "update-migrate.sh" "harness-update.md invoca el migrador donde estaba la prosa"
assert_contains "$upd" "command -v harness" "y el paso de re-instanciación arranca por el binario"
assert_contains "$upd" "harness generate" "con el generador determinista"
assert_contains "$upd" "Fallback" "la re-instanciación mental queda como fallback"
assert_contains "$upd" "re-instanciación manual" "que además se DECLARA en el reporte"
assert_not_contains "$upd" "2. RE-INSTANCIA mentalmente" "ya no es el paso 2 por default"
# Lo que no puede perderse en la reescritura: el cierre verificado y los
# paquetes atados son de donde salieron los otros dos incidentes.
assert_contains "$upd" "harness-version.sh --verify" "el cierre obligatorio sigue ahí"
assert_contains "$upd" "PAQUETES ATADOS" "y los paquetes atados también"

echo
echo "── (g2) el doc mira antes de escribir, y cita leyes que existen"
# El paso 4 dice "NUNCA apliques sin confirmación explícita por archivo" y el
# paso 1b corría el migrador en modo escritura: el doc se contradecía a sí
# mismo, y quien lo ejecuta es un LLM con permisos de escritura.
assert_contains "$upd" "update-migrate.sh <workspace> --dry-run" "el paso 1b arranca por el dry-run"
assert_contains "$upd" "DOS TIEMPOS" "y lo dice como regla, no como sugerencia"
assert_contains "$upd" "esperá el ok del humano" "presenta lo que se aplicaría y espera el ok"
# La renumeración de leyes dejó la cita apuntando a otra ley.
assert_not_contains "$upd" "(ley 12 / ley 9)" "ya no cita la numeración vieja como si fuera la de hoy"
assert_contains "$upd" "ley 12 en los dos mapas" "la cita nombra la ley vigente en CLAUDE.md y AGENTS.md"
assert_contains "$upd" "previas a la renumeración" "y explica de dónde venía el 9 de las instancias viejas"
# Merge de AGENTS.md contra una instancia con la numeración VIEJA: ley por ley
# deja DOS numeraciones conviviendo.
assert_contains "$upd" "BLOQUE COMPLETO" "las leyes se actualizan como bloque entero"
assert_contains "$upd" "RE-ANCLA" "el contenido ajeno de esa sección se re-ancla, no se pierde"
assert_contains "$upd" "DOS numeraciones" "y nombra el modo de fallo que evita"
assert_contains "$upd" "verificá las citas" "tras el merge se verifican las citas Ley <n>"
# Conversión del answers a JSON: mecanismo nombrado, paridad verificada, y
# fallback explícito en vez de improvisación.
assert_contains "$upd" "yq -o=json" "nombra el mecanismo concreto de conversión"
assert_contains "$upd" "Check de paridad" "y exige verificar que el JSON diga lo mismo que el YAML"
assert_contains "$upd" "andá al fallback 2b" "sin conversor confiable, manda al fallback en vez de improvisar"

t_done
