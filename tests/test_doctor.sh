#!/usr/bin/env bash
# test_doctor.sh — el contrato del doctor: (1) un workspace roto FALLA (exit
# no-cero) y cada fallo trae su remediación; (2) los checks nuevos de esta
# versión existen de verdad (models drift, beads, graphify, AGENTS.md); (3)
# un fallo jamás es silencioso. No prueba cada check — prueba que el doctor
# no miente en las dos direcciones.
set -u
. "$(dirname "$0")/lib.sh"
t_ws

echo "── doctor: un workspace roto falla con remediación"

# workspace casi vacío: faltan los archivos base
mkdir -p "$WS/repos"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "workspace roto: exit no-cero" || fail "workspace roto: salió 0 (doctor mentiroso)"
assert_contains "$out" "remediación" "cada fallo trae remediación"
assert_contains "$out" "CLAUDE.md" "detecta archivos base faltantes"
assert_contains "$out" "resultado:" "imprime el resumen de fallos"

echo "── doctor: el drift de modelos se detecta (stamp-models check)"

# workspace con models.yaml + agente DESALINEADO a propósito
mkdir -p "$WS/scripts" "$WS/.claude/agents"
cp "$ROOT/templates/scripts/stamp-models.sh" "$WS/scripts/"
cat > "$WS/models.yaml" <<'EOF'
provider: anthropic

models.anthropic:
  fast: haiku
  smart: sonnet
  deep: opus

roles:
  orquestador: deep
  architect: deep
  abogados: deep
  reviewer: smart
  implementer: smart
  qa: fast
  mechanical: fast
  escalation: deep

overrides:
EOF
printf -- '---\nname: architect\nmodel: editado-a-mano\n---\n' > "$WS/.claude/agents/architect.md"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "desalineado con models.yaml" "doctor detecta drift de modelos"
assert_contains "$out" "make models" "el drift trae su remediación"

# alineado → el mismo check pasa a verde
bash "$WS/scripts/stamp-models.sh" >/dev/null 2>&1
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "agentes alineados con models.yaml" "alineado: check en verde"

echo "── doctor: hook registrado pero ausente = fail con remediación"

mkdir -p "$WS/.claude/hooks"
cat > "$WS/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/guard-fantasma.sh"}]}]}}
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "guard-fantasma.sh" "detecta el hook fantasma (registrado sin archivo)"
assert_contains "$out" "AUSENTE" "lo reporta como ausente, no como warning genérico"
# presente pero sin +x: también fail, con su chmod
touch "$WS/.claude/hooks/guard-fantasma.sh"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "no ejecutable" "hook sin +x: fail con chmod en la remediación"
chmod +x "$WS/.claude/hooks/guard-fantasma.sh"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
echo "$out" | grep -q "guard-fantasma" && fail "hook OK no debería reportarse" || pass "hook existente y ejecutable: silencio"

echo "── doctor: frescura de clones (la ruta del stat SE EJERCITA)"

# dos clones falsos con FETCH_HEAD viejo: el warn debe salir y el doctor
# NO debe morir por stat (bug real: GNU interpretaba -f %m como filesystem
# y set -u abortaba el doctor a mitad de corrida en Linux)
for rname in alpha beta; do
  mkdir -p "$WS/repos/$rname/.git"
  touch -t 202001010000 "$WS/repos/$rname/.git/FETCH_HEAD"
done
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "resultado:" "el doctor llega al final (no muere en el stat)"
assert_contains "$out" "make pull" "clones sin fetch en 48h: warn con remediación"
echo "$out" | grep -q "unbound" && fail "unbound variable en el doctor" || pass "sin unbound variables"
rm -rf "$WS/repos/alpha" "$WS/repos/beta"

echo "── doctor: un COMENTARIO no es una declaración (issue #26)"

# El ejemplo comentado del propio template hacía que TODO workspace generado
# avisara por una ref que nadie declaró, y el aviso era irresoluble sin leer
# el código del doctor.
cat > "$WS/harness-answers.yaml" <<'EOF'
secrets:
  source: vault
  refs:
    - vault://proyecto/harness/argocd
#    - env://GH_TOKEN
#    - env://<NOMBRE_DE_LA_VARIABLE>
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_not_contains "$out" "GH_TOKEN" "una ref env:// comentada NO produce aviso"

# y una ref REAL sin variable en el entorno sigue avisando (el check sirve)
cat > "$WS/harness-answers.yaml" <<'EOF'
secrets:
  source: env
  refs:
    - env://HARNESS_TEST_VAR_QUE_NADIE_EXPORTA
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "HARNESS_TEST_VAR_QUE_NADIE_EXPORTA" "una ref env:// real sin variable sí avisa"
# el ejemplo del template no puede ser un literal parseable
grep -qE '^#.*env://[A-Za-z_][A-Za-z0-9_]*$' "$ROOT/templates/harness-answers.yaml.tmpl" \
  && fail "el template trae un ejemplo env:// que el parser puede confundir con una ref" \
  || pass "el ejemplo del template no es un literal parseable"
rm -f "$WS/harness-answers.yaml"

echo "── doctor: un repo que deploya con driver=none se marca (eje deploy)"
# Caso de campo: deploy-watch dijo "driver: none, NO reviso nada" en repos
# que sí deployan, y tras cada ship hubo que verificar a mano con gh run
# view. El doctor es quien vigila el eje (CONTRIBUTING regla 1).

mkdir -p "$WS/repos/tf-live/.github/workflows" "$WS/repos/quieto"
printf 'name: apply\non: push\njobs:\n  a:\n    steps:\n      - run: terraform apply\n' \
  > "$WS/repos/tf-live/.github/workflows/deploy.yml"
cat > "$WS/manifest.yaml" <<'EOF'
project: t
repos:
  - name: tf-live
    kind: infra-live
    agent: infra
  - name: quieto
    kind: docs
    agent: docs
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "tf-live tiene workflows de deploy y su driver resuelve a none" \
  "repo con workflow de deploy y driver none: warn"
assert_contains "$out" "deploy.tf-live.driver" "la remediación nombra la clave exacta del answers"
assert_not_contains "$out" "quieto tiene workflows" "un repo sin workflows no genera ruido"

# declarado en answers → el mismo repo pasa a verificable
cat > "$WS/harness-answers.yaml" <<'EOF'
deploy:
  tf-live:
    driver: actions
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "deploy de tf-live verificable (driver: actions)" \
  "con el driver declarado: el check queda en verde"
rm -f "$WS/harness-answers.yaml" "$WS/manifest.yaml"; rm -rf "$WS/repos/tf-live" "$WS/repos/quieto"

echo "── doctor: los dos mapas de leyes hablan de LAS MISMAS leyes"
# CLAUDE.md y AGENTS.md comparten numeracion y los playbooks citan "Ley N" por
# numero. Una instancia vieja que actualiza puede quedarse con las dos
# numeraciones conviviendo (el merge de AGENTS.md lo ejecuta un LLM siguiendo
# prosa), y entonces "Ley 6" resuelve a leyes DISTINTAS segun por que mapa entre
# el agente. El plugin ya lo vigila en tests/test_docs.sh, pero eso corre en el
# repo del plugin: aca se prueba que el diente viaja a la instancia.

mkdir -p "$WS/.claude/commands" "$WS/.claude/agents"

mapa_canon() {  # CLAUDE.md: el canon, igual en todos los casos
  cat > "$WS/CLAUDE.md" <<'EOF'
# workspace

## Leyes globales (no negociables)

1. **Push a main SOLO vía ship.sh**: es la única puerta.
2. **Contratos expand/contract**: buf breaking es gate duro.
6. **Presupuestos**: máx 3 iteraciones por loop; RFC máx 2 rondas.
6b. **Piensa hondo en el plan, no en el loop**: ultrathink, sin decisiones abiertas.
7. **Decisiones fuera del repo NO EXISTEN.** Lo de chat se propone como ADR.
12. **Un bug del HARNESS se verifica y se reporta upstream, siempre.**
13. **Un repo ARCHIVADO en el forge se ignora SIEMPRE.** No entra al grafo.
EOF
}
# Los playbooks citan por numero: 6 y 12 desde un comando, 7 desde un agente.
# La "## Ley 0" del agente es una ley INTERNA del rol, no una cita del mapa.
printf 'Agotado el presupuesto, escala a humano (Ley 6).\nUn bug del harness se reporta upstream (Ley 12).\n' \
  > "$WS/.claude/commands/implement.md"
printf '## Ley 0: piensa hondo, lee poco\n\nLo decidido en chat se propone como ADR (Ley 7).\n' \
  > "$WS/.claude/agents/reviewer.md"

# (1) Instancia coherente: verde, y el recorte legitimo de un titulo NO falla.
mapa_canon
cat > "$WS/AGENTS.md" <<'EOF'
# mapa para agentes

## Las leyes (número y título salen de CLAUDE.md, que es el canon)

1. **Push a main SOLO vía ship.sh**: es la única puerta y hace rebase, tests y gates.
2. **Contratos expand/contract**: un cambio de proto nunca rompe al consumidor.
6. **Presupuestos**: máx 3 iteraciones por loop; RFC máx 2 rondas.
6b. **Piensa hondo en el plan, no en el loop**: ultrathink, sin decisiones abiertas.
7. **Decisiones fuera del repo NO EXISTEN.** Lo de chat se propone como ADR.
12. **Un bug del HARNESS se verifica y se reporta upstream**, con su cuerpo abreviado.
13. **Un repo ARCHIVADO en el forge se ignora SIEMPRE.** No entra al grafo.
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "leyes coherentes en los dos mapas" "instancia coherente: el check sale verde"
assert_not_contains "$out" "❌ Ley" "y no inventa fallos de leyes"
assert_not_contains "$out" "cita huerfana" "las citas de los playbooks resuelven"
assert_not_contains "$out" "no pude verificar leyes" "con los dos mapas presentes, no se declara ciego"
assert_not_contains "$out" "menos del 60%" "un recorte de la cola que conserva el prefijo es legítimo"

# (2) Numeracion VIEJA en AGENTS: su Ley 6 son los contratos proto (en el canon
# es la 2) y su Ley 9 el bug upstream (en el canon es la 12), mientras un
# playbook cita Ley 6 y Ley 12. Es el merge del update mal aplicado.
cat > "$WS/AGENTS.md" <<'EOF'
# mapa para agentes

## Las leyes

1. **Push a main SOLO vía ship.sh**: es la única puerta.
6. **Contratos expand/contract**: un cambio de proto nunca rompe al consumidor.
7. **Decisiones fuera del repo NO EXISTEN.** Lo de chat se propone como ADR.
9. **Un bug del HARNESS se verifica y se reporta upstream, siempre.**
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "❌ Ley 6 con titulo distinto" "numeración vieja: FAIL nombrando el número que resuelve a dos leyes"
assert_contains "$out" "'Presupuestos'" "el mensaje muestra el título del canon"
assert_contains "$out" "'Contratos expand/contract'" "y el que dice el otro mapa"
assert_contains "$out" "❌ cita huerfana: los playbooks citan 'Ley 12'" "la cita del playbook que ya no resuelve: FAIL con el número"
assert_contains "$out" "numeracion vieja que sobrevivio al merge" "una ley que solo existe en AGENTS se nombra como lo que es"
assert_contains "$out" "BLOQUE COMPLETO" "y la remediación del merge dice que las leyes van en bloque"
assert_not_contains "$out" "leyes coherentes en los dos mapas" "con dos numeraciones conviviendo NO hay verde"

# (3) El mismo numero DOS veces en un mapa: la firma exacta del merge fallido.
# Todo lo demas queda coherente, para que el hallazgo sea SOLO el duplicado.
cat > "$WS/AGENTS.md" <<'EOF'
# mapa para agentes

## Las leyes

1. **Push a main SOLO vía ship.sh**: es la única puerta.
2. **Contratos expand/contract**: un cambio de proto nunca rompe al consumidor.
6. **Presupuestos**: máx 3 iteraciones por loop; RFC máx 2 rondas.
6b. **Piensa hondo en el plan, no en el loop**: ultrathink, sin decisiones abiertas.
7. **Decisiones fuera del repo NO EXISTEN.** Lo de chat se propone como ADR.
12. **Un bug del HARNESS se verifica y se reporta upstream, siempre.**
13. **Un repo ARCHIVADO en el forge se ignora SIEMPRE.** No entra al grafo.
6. **Presupuestos**: sobreviviente del bloque viejo que el merge no borró.
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "❌ AGENTS.md numera DOS veces la(s) ley(es): 6" "número duplicado en un mapa: FAIL nombrando mapa y número"
assert_contains "$out" "merge del update mal aplicado" "con la remediación del merge, que es su causa"
assert_contains "$out" "re-corre /harness-init . en modo update" "y el comando exacto para reponer el bloque"
assert_not_contains "$out" "leyes coherentes en los dos mapas" "un duplicado no puede salir verde"
assert_not_contains "$out" "titulo distinto en cada mapa" "el duplicado se reporta por lo que es, no como divergencia de título"

# (3b) LISTA NUMERADA AJENA fuera de la seccion de leyes (issues #41 y #59).
# Caso de campo: `bd setup codex` (beads, la herramienta de tracking que el
# propio CLAUDE.md manda usar) inyecta en AGENTS.md un "Session Close Protocol"
# que es una lista 1..5 en negrita. El chequeo escaneaba el archivo ENTERO, asi
# que contaba esos items como leyes y dejaba el doctor en rojo PERMANENTE por un
# AGENTS.md correcto, con una remediacion ("re-corre /harness-init . en modo
# update") que ademas invita a REGENERAR AGENTS.md, que es la accion que
# /harness-update documenta como la que borro 70 lineas de una instancia real.
# El bloque va con su encabezado real y despues de las leyes, tal cual lo instala bd.
cat > "$WS/AGENTS.md" <<'EOF'
# mapa para agentes

## Las leyes

1. **Push a main SOLO vía ship.sh**: es la única puerta.
2. **Contratos expand/contract**: un cambio de proto nunca rompe al consumidor.
6. **Presupuestos**: máx 3 iteraciones por loop; RFC máx 2 rondas.
6b. **Piensa hondo en el plan, no en el loop**: ultrathink, sin decisiones abiertas.
7. **Decisiones fuera del repo NO EXISTEN.** Lo de chat se propone como ADR.
12. **Un bug del HARNESS se verifica y se reporta upstream, siempre.**
13. **Un repo ARCHIVADO en el forge se ignora SIEMPRE.** No entra al grafo.

## Session Close Protocol

When ending a session:

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
5. **Hand off** - Summarize changes, validation, issue status
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_not_contains "$out" "numera DOS veces" "una lista numerada AJENA a la seccion de leyes no son leyes duplicadas"
assert_not_contains "$out" "❌ Ley 3" "ni inventa una 'Ley 3' con el item 3 del protocolo de beads"
assert_contains "$out" "leyes coherentes en los dos mapas" "con las leyes intactas, el check sale verde igual"

# (3b bis) LA CONTRA-MITAD: acotar la ventana no puede APAGAR el chequeo. El
# mismo AGENTS.md, con el bloque ajeno intacto, pero con un 6 duplicado DENTRO
# de la seccion de leyes: eso si es el merge fallido y se sigue reportando.
cat > "$WS/AGENTS.md" <<'EOF'
# mapa para agentes

## Las leyes

1. **Push a main SOLO vía ship.sh**: es la única puerta.
2. **Contratos expand/contract**: un cambio de proto nunca rompe al consumidor.
6. **Presupuestos**: máx 3 iteraciones por loop; RFC máx 2 rondas.
6b. **Piensa hondo en el plan, no en el loop**: ultrathink, sin decisiones abiertas.
7. **Decisiones fuera del repo NO EXISTEN.** Lo de chat se propone como ADR.
12. **Un bug del HARNESS se verifica y se reporta upstream, siempre.**
13. **Un repo ARCHIVADO en el forge se ignora SIEMPRE.** No entra al grafo.
6. **Presupuestos**: sobreviviente del bloque viejo que el merge no borró.

## Session Close Protocol

When ending a session:

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
5. **Hand off** - Summarize changes, validation, issue status
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "❌ AGENTS.md numera DOS veces la(s) ley(es): 6" "un duplicado DENTRO de la seccion de leyes se sigue reportando"
assert_not_contains "$out" "veces la(s) ley(es): 1" "y nombra SOLO el numero duplicado de verdad, no los del bloque ajeno"
assert_not_contains "$out" "leyes coherentes en los dos mapas" "un duplicado real no puede salir verde"

# (4) Titulo divergente con la MISMA numeracion: edicion local a un solo mapa.
# Dos causas distintas no comparten remediacion: aca NO va la del merge.
cat > "$WS/AGENTS.md" <<'EOF'
# mapa para agentes

## Las leyes

1. **Push a main SOLO vía ship.sh**: es la única puerta.
2. **Contratos expand/contract**: un cambio de proto nunca rompe al consumidor.
6. **Presupuestos**: máx 3 iteraciones por loop; RFC máx 2 rondas.
6b. **Piensa hondo en el plan, no en el loop**: ultrathink, sin decisiones abiertas.
7. **Decisiones fuera del repo NO EXISTEN.** Lo de chat se propone como ADR.
12. **Un bug** del harness, cuando haya tiempo.
13. **Un repo ARCHIVADO en el forge se usa SIEMPRE.** Editado a mano acá.
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "❌ Ley 13 con titulo distinto" "título divergente: FAIL nombrando la ley"
assert_contains "$out" "iguala los dos mapas" "con la remediación de igualar los mapas"
assert_contains "$out" "menos del 60%" "un prefijo que no cubre el 60% del canon tampoco identifica la ley"
assert_not_contains "$out" "BLOQUE COMPLETO" "y NO trae la remediación del merge: son causas distintas"
assert_not_contains "$out" "leyes coherentes en los dos mapas" "un título divergente no puede salir verde"

# (5) La mecanica portada de test_docs.sh: el titulo llega al ULTIMO "**".
# Cortar en el primero dejaba pasar un titulo de sentido INVERTIDO como "mismo
# titulo", porque solo se comparaba el pedazo de adelante.
cat > "$WS/AGENTS.md" <<'EOF'
# mapa para agentes

## Las leyes

1. **Push a main SOLO vía ship.sh**: es la única puerta.
2. **Contratos expand/contract**: un cambio de proto nunca rompe al consumidor.
6. **Presupuestos: máx 3 iteraciones por loop; el cierre quedó en la línea de abajo
   y por eso la mitad del título nunca se compara**.
6b. **Piensa hondo en el plan, no en el loop**: ultrathink, sin decisiones abiertas.
7. **Decisiones fuera del repo NO EXISTEN.** Lo de chat se propone como ADR.
12. **Un bug del HARNESS se verifica y se reporta upstream, siempre.**
13. **Un repo ARCHIVADO **jamas** se ignora: usalo siempre**
EOF
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "❌ Ley 13 en AGENTS.md: titulo <ANIDADO>" "negrita anidada: no es un título, y el sentido invertido no pasa"
assert_contains "$out" "❌ Ley 6 en AGENTS.md: titulo <SIN-CIERRE>" "título partido en dos líneas: tampoco es un título"
assert_not_contains "$out" "cita huerfana: los playbooks citan 'Ley 6'" "un título roto se reporta UNA vez, no dos veces con dos caras"

# (6) Tercer estado: sin uno de los mapas no hay comparacion, y "no pude mirar"
# no es verde. La ausencia YA la reporta el doctor: aca no se repite.
rm -f "$WS/AGENTS.md"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "no pude verificar leyes: falta AGENTS.md" "sin AGENTS.md el check se declara no verificable"
assert_not_contains "$out" "leyes coherentes en los dos mapas" "y jamás verde callado"
n_aus="$(printf '%s\n' "$out" | grep -c 'sin AGENTS.md' | tr -d ' ')"
assert_eq "1" "$n_aus" "la ausencia de AGENTS.md se reporta UNA vez (el check de leyes no la duplica)"

mv "$WS/CLAUDE.md" "$WS/AGENTS.md"
out="$(bash "$ROOT/scripts/doctor.sh" "$WS" 2>&1)"
assert_contains "$out" "no pude verificar leyes: falta CLAUDE.md" "y lo mismo cuando el que falta es el canon"
n_aus="$(printf '%s\n' "$out" | grep -c 'CLAUDE.md faltante' | tr -d ' ')"
assert_eq "1" "$n_aus" "la ausencia de CLAUDE.md tampoco se reporta dos veces"
rm -f "$WS/AGENTS.md" "$WS/.claude/commands/implement.md" "$WS/.claude/agents/reviewer.md"

echo "── doctor: los checks de cadena-completa existen"

# los checks añadidos por la auditoría anti-consejo-vacío deben estar en el
# script — si alguien los borra, este test lo cacha sin depender de tener
# graphify/bd instalados en la máquina del test
for marker in "graphify" "bd ready" "AGENTS.md"; do
  grep -q "$marker" "$ROOT/scripts/doctor.sh" \
    && pass "check presente en doctor: $marker" \
    || fail "check AUSENTE en doctor: $marker"
done


echo "── doctor: un canonico con rama de tarea checkeada NO es un clon sano (#77)"
# El clon canonico es la ruta de lectura recomendada (el CLAUDE.md empuja ahi
# para orientarse). Con una rama de tarea checkeada devuelve codigo viejo sin
# ninguna señal: caso de campo, design-system 149 commits atras, y 4 de 10
# defectos seleccionados leyendo ese arbol ya estaban arreglados en main.
# pull-all lo avisa cuando alguien corre `make pull`; el doctor es el chequeo
# continuo, y "clon podrido" ya es una categoria suya.
DW="$WS/d77"; mkdir -p "$DW/repos" "$DW/origins"
mk77() {  # mk77 <nombre>: origin bare + clon canonico
  local n="$1" work="$DW/seed-$1"
  git init -q --bare -b main "$DW/origins/$n.git"
  git init -q -b main "$work"
  git -C "$work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$work" remote add origin "$DW/origins/$n.git"
  git -C "$work" push -q origin main
  git clone -q "$DW/origins/$n.git" "$DW/repos/$n"
}
mk77 enrama; mk77 sano
git -C "$DW/repos/enrama" checkout -q -b task/x
for i in 1 2; do git -C "$DW/seed-enrama" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "a$i"; done
git -C "$DW/seed-enrama" push -q origin main
# el doctor NO paga red: la distancia se mide contra el origin/main local, asi
# que el fetch lo hace el fixture (como lo haria un make pull previo).
git -C "$DW/repos/enrama" fetch -q origin

out="$(bash "$ROOT/scripts/doctor.sh" "$DW" 2>&1)"
assert_contains "$out" "repos/enrama" "el doctor nombra el repo en otra rama"
assert_contains "$out" "task/x" "y la rama que tiene checkeada"
assert_contains "$out" "2 commits atrás" "y la distancia (el dato que lo vuelve accionable)"
assert_contains "$out" "checkout main" "con la remediacion exacta"
# Y el caso negativo: un warn barato que suena siempre se aprende a ignorar.
assert_not_contains "$out" "repos/sano" "un clon en su trunk NO dispara el aviso"

echo "── doctor --instance-only: el CLI que le falta al HOST no es una instancia rota (#185)"
# El gate del doctor de instance-ship.sh corria el doctor COMPLETO, que cuenta
# con el mismo peso dos cosas de naturaleza distinta: que la instancia este sana
# (links, hooks, reglas, drift) y que ESTA maquina tenga sus CLIs. Solo la
# primera dice algo sobre si el commit es seguro para main. Caso de campo: un
# commit de documentos mas el bump del harness quedo sin publicar por 16
# `cli faltante`, ninguno de los cuales ese commit ejecuta, y la unica salida
# que quedaba era declarar un HARNESS_KNOWN_BUG que no era un bug del harness.
IW="$WS/inst"; mkdir -p "$IW/repos"
cat > "$IW/harness-answers.yaml" <<'YEOF'
capabilities:
  - name: un-cli-que-no-existe
    bin: zzz-cli-inexistente-para-el-test
YEOF
completo="$(bash "$ROOT/scripts/doctor.sh" "$IW" 2>&1)"
assert_contains "$completo" "❌ cli faltante: zzz-cli-inexistente-para-el-test"   "el doctor COMPLETO sigue cobrando el CLI ausente como FALLO"

solo="$(bash "$ROOT/scripts/doctor.sh" --instance-only "$IW" 2>&1)"
assert_not_contains "$solo" "❌ cli faltante" "en --instance-only NO es un fallo"
assert_contains "$solo" "⚠️" "pero se sigue VIENDO: baja a aviso, no desaparece"
assert_contains "$solo" "provisión del HOST" "y dice por que no bloquea"
assert_contains "$solo" "bootstrap.sh" "conservando la remediacion"
assert_contains "$solo" "modo --instance-only" "y el modo se declara en el resumen"

# La contra-mitad, que es la que impide que esto sea un apagador del gate: un
# fallo de SALUD DE LA INSTANCIA sigue siendo fallo en los dos modos. Si no,
# `--instance-only` seria "doctor que no falla nunca" con otro nombre.
f_completo="$(printf '%s' "$completo" | grep -c '^❌' || true)"
f_solo="$(printf '%s' "$solo" | grep -c '^❌' || true)"
[ "$f_solo" -gt 0 ] \
  && pass "--instance-only sigue reportando los fallos de la INSTANCIA ($f_solo)" \
  || fail "--instance-only no reporto ni un fallo: es un gate apagado con otro nombre"
[ "$f_solo" -lt "$f_completo" ] \
  && pass "y son MENOS que los del doctor completo ($f_solo < $f_completo)" \
  || fail "no bajo ningun fallo: el flag no hizo nada"

# El gate de instance-ship tiene que PEDIR ese modo, o el arreglo no llega.
ish="$(cat "$ROOT/templates/scripts/instance-ship.sh")"
assert_contains "$ish" "doctor.sh --instance-only" \
  "instance-ship llama al doctor en el modo que le compete"

echo "── un .secrets INCOMPLETO no es un .secrets materializado"
# El chequeo miraba solo que el archivo EXISTIERA. Con la credencial vencida,
# `secrets.sh pull` lo escribe igual con lo que pudo leer, asi que un archivo
# con 3 de 18 claves daba verde, y lo daba DOS LINEAS debajo del aviso de que
# el token estaba expirado: la misma salida se contradecia.
SW="$WS/sec"; mkdir -p "$SW/scripts" "$SW/fakehome/.config/harness"
printf 'secrets:\n  source: vault\n' > "$SW/harness-answers.yaml"
cat > "$SW/scripts/secrets.sh" <<'SEOF'
#!/usr/bin/env bash
  export VAULT_ADDR="https://vault.example"
  dump_kv ALFA   ejemplo/uno   campo
  dump_kv BETA   ejemplo/uno   otro
  dump_kv GAMMA  ejemplo/dos   campo
#  dump_kv COMENTADA ejemplo/tres campo
SEOF

# a) incompleto: una de las tres declaradas
printf 'ALFA=x\n' > "$SW/.secrets"
out="$( HOME="$SW/fakehome" bash "$ROOT/scripts/doctor.sh" "$SW" 2>&1 )"
assert_contains "$out" ".secrets INCOMPLETO" "con 1 de 3 claves NO dice materializado"
assert_contains "$out" "faltan 2 de 3" "y dice cuantas faltan de cuantas"
assert_contains "$out" "BETA" "nombrando alguna, para poder buscarla"
assert_not_contains "$out" "COMENTADA" "una linea comentada no cuenta como declarada"

# b) completo: las tres
printf 'ALFA=x\nBETA=y\nGAMMA=z\n' > "$SW/.secrets"
out="$( HOME="$SW/fakehome" bash "$ROOT/scripts/doctor.sh" "$SW" 2>&1 )"
assert_contains "$out" ".secrets materializado" "con las tres presentes vuelve a verde"
assert_not_contains "$out" "INCOMPLETO" "y no queda ruido del caso anterior"

# c) es provision del HOST, no instancia rota: no puede bloquear el ship.
printf 'ALFA=x\n' > "$SW/.secrets"
solo="$( HOME="$SW/fakehome" bash "$ROOT/scripts/doctor.sh" --instance-only "$SW" 2>&1 )"
assert_contains "$solo" ".secrets INCOMPLETO" "en --instance-only se sigue VIENDO"
assert_not_contains "$solo" "❌ .secrets INCOMPLETO" "pero baja a aviso: una credencial vencida no es una instancia rota"

t_done
