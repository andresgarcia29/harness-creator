---
description: Sincroniza mejoras del plugin a la instancia instalada (diff template ↔ instancia)
argument-hint: [ruta-al-workspace]
---

Actualización de la instancia en $ARGUMENTS (o el directorio actual).

0. `/harness-init` en un workspace ya instalado hace EXACTAMENTE esto
   (modo update) — son el mismo flujo; este comando es el atajo.
1. Lee `.harness-version` y `harness-answers.yaml` del workspace. Si la
   versión coincide con la del plugin, dilo y termina.
1a. **ANTES de copiar nada, comprueba que el plugin EN DISCO es el último
   tag publicado.** El update copia desde `${CLAUDE_PLUGIN_ROOT}/templates/`,
   así que un plugin sin actualizar produce una instancia vieja **que va a
   reportar éxito igual**: se escribe el número nuevo sobre templates viejos.
   Es el fallo de 2026-07 (`0.60.0`) visto desde un paso antes.
   Compara contra el **tag**, no contra la rama por defecto: la rama se mueve
   con cada commit y trae versiones que nadie publicó.
   ```
   gh api repos/andresgarcia29/harness-creator/tags --jq '.[].name'   # el mayor
   jq -r .version ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json    # lo instalado
   ```
   Si el disco está atrás: **para acá**, di el número exacto de los dos lados y
   pide `/plugin marketplace update harness`. No sigas "por si acaso".
1b. **Migra el esquema del answers con el migrador determinista**, no a mano, y
   en DOS TIEMPOS: la regla del paso 4 (nunca aplicar sin confirmación) manda
   también acá, así que primero se mira y recién después se escribe.
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-migrate.sh <workspace> --dry-run
   ```
   El dry-run no escribe una línea: imprime cada `SE APLICARÍA: ...`.
   PRESENTÁ esa lista tal como salió (qué clave, con qué valor y por qué ese
   valor es un default documentado) y esperá el ok del humano. Con el ok, la
   corrida real:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-migrate.sh <workspace>
   ```
   Aplica solo lo que falta y solo lo que ya está DOCUMENTADO (idempotente,
   escritura atómica), y NOMBRA cada migración aplicada o saltada con su
   motivo: `upstream_issues:` con su default, `models.provider` con el suyo
   (`anthropic`). Además AUDITA que los valores de `models.*` del answers sean
   ALIASES fast|smart|deep: un id crudo de modelo (`architect:
   claude-opus-4-1`, típico de instancias viejas) NO lo mapea el script, lo
   nombra clave por clave y sale por el tercer estado, porque el mapeo inverso
   id → alias no es una función. Tres estados en el exit: **0** nada que
   migrar o migrado,
   **1** fallo real, **2** no pude determinar (archivo ausente o ilegible, o
   una transformación que exige juicio). **Exit 2 no es éxito**: lo que declare
   pendiente lo resolvés vos con el humano, nunca el script inventando el
   valor (el caso de models.yaml está en el paso 5).
   Lo que el script no puede hacer sigue siendo tuyo: los campos que esta
   versión agregó y que solo la entrevista responde (ej. `scope:` por
   capacidad según el campo `cronjob:` del catálogo, `instance.repo`) se
   preguntan, y SOLO esos. Las decisiones registradas no se tocan.
2. **Re-instancia por el camino DETERMINISTA.** Si `command -v harness`
   responde (el generador de brew: `brew install andresgarcia29/agm/harness`;
   confirmá con `harness --version` que es ESE binario y no otro que se llame
   igual), no redactes vos los archivos:
   ```
   harness generate --workspace <workspace> --answers <el answers YA registrado>
   ```
   Embebe estos mismos templates, es idempotente por sha256 y lo personalizado
   va a `.new` (jamás pisa), así que tu trabajo pasa a ser PRESENTAR los diffs
   y resolver cada `.new` con el humano, no escribir contenido. Al resolverlos
   mandan las reglas de propiedad del paso 3 (AGENTS.md se MERGEA, las skills
   locales y `skills.yaml` no se tocan). El answers es el de la instancia: no
   lo rehagas. Si el binario lo pide en JSON, la conversión es MECÁNICA y va
   con herramienta, nunca a ojo: el esquema es el mismo del YAML (un objeto
   JSON con las MISMAS claves y el mismo anidamiento, sin renombrar ni
   aplanar), y el mecanismo es, en este orden:
   ```
   yq -o=json '.' <workspace>/harness-answers.yaml > <tmp>/answers.json
   python3 -c 'import yaml, json, sys; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' \
     <workspace>/harness-answers.yaml > <tmp>/answers.json
   ```
   (el segundo solo si `python3 -c 'import yaml'` sale 0; PyYAML no es stdlib).
   Si NINGUNO de los dos está en el host, no improvises el JSON a mano:
   **andá al fallback 2b y declaralo**, que para eso está.
   **Check de paridad, antes de generar**: el JSON tiene que reflejar las
   MISMAS decisiones que el YAML registrado. Comparalos clave por clave y decí
   cuáles comparaste, como mínimo `flow`, `models.provider` y el alias de cada
   `models.*`. Una discrepancia es tercer estado: se declara y se para, no se
   elige el valor que convenga ni se sigue porque el generate haya corrido.
   Si el binario rechaza el answers, eso también es un
   tercer estado: decilo y pasá al fallback declarándolo, no lo edites a ojo.
   El porqué: este paso es el último lugar donde un LLM improvisa con permisos
   de escritura sobre una instancia, y de acá salieron los tres incidentes más
   caros de campo (la versión `0.60.0` que no existía en ningún origen, el
   AGENTS.md regenerado que borró 70 líneas ajenas, y los casks de macOS
   instalados en una VPS Linux).
2b. **Fallback, y se declara como tal**: si el binario NO está, re-instancia
   mentalmente cada template de `${CLAUDE_PLUGIN_ROOT}/templates/` con las
   respuestas registradas en harness-answers.yaml (por eso el esquema es fijo)
   y compara contra el archivo real de la instancia. Ponelo en el reporte con
   estas palabras: "sin binario `harness`: re-instanciación manual", porque
   quien lea el resultado tiene que saber que lo produjo un LLM y no el
   generador. Regla dura del fallback: **cada línea sale de una fuente
   NOMBRADA** (el template o el answers), nada se escribe de memoria, y el
   número de versión y el digest se copian de su archivo (paso 5). Es
   exactamente lo que no se hizo cuando apareció el `0.60.0`.
3. Clasifica cada diferencia según la PROPIEDAD del archivo:
   - **Propiedad del plugin**: TODO `scripts/` sale del plugin, así que la
     lista es "todos", y se enumera para que un script NUEVO no se cuele sin
     clasificar (`tests/test_docs.sh` lo verifica: agregar un script al plugin
     y no nombrarlo acá deja a las instancias sin recibirlo).
     scripts/{doctor,bootstrap,secrets,ship,worktree-task,quiet,with-secrets,
     repo-brief,stamp-models,change-id,verdict-scaffold,plan-lint,build-slot,
     deploy-watch,emit,forge,gowork,graph-refresh,minion-probe,pull-all,
     ticket-close,ticket-pull,harness-bug,harness-version,skills-sync,
     pipeline-steps,py,fe,archived-repos,mark-read,verdict-beads,ship-wave,
     port-forwards,instance-ship}.sh,
     scripts/{harness-policy,evidence}.py, `harness-policy.json`,
     hooks, y **el panel**:
     `scripts/ui/{panel.sh,server.py,pricing.json,dist/}`): upstream gana por
     default — re-instancia con las respuestas del answers y propón el
     archivo completo. Un parche local aquí casi siempre fue un fix que
     YA subió al plugin; verifica que la lógica local esté contenida en
     la nueva versión antes de reemplazar.
     · El PANEL es especialmente importante en updates recientes: `panel.sh`
       (nuevo) hace que `make ui` corra el **daemon Go `harnessd`** en vez de
       `server.py`, y el `dist/` trae el frontend nuevo (multi-máquina,
       terminales, sonda de MCP, archivar). El BINARIO `harnessd` NO es un
       archivo a diffear — `panel.sh` lo baja solo del release público en el
       primer `make ui` (o cae a server.py si no hay acceso). Tras actualizar,
       recuérdale al humano correr `make ui` para bajar el daemon nuevo.
   - **`AGENTS.md` y cualquier archivo con BLOQUES GESTIONADOS: se MERGEA,
     nunca se regenera.** Estaba clasificado como propiedad del plugin y por eso
     se reescribía entero. En una instancia real eso borró 70 líneas de una
     sola pasada: la ley del design system del proyecto y un bloque completo de
     otra herramienta (`<!-- BEGIN BEADS INTEGRATION v:1 ... hash:6cd5cc61 -->`),
     que ni siquiera es nuestro para reescribir. `AGENTS.md` es la puerta de
     entrada MULTI-HERRAMIENTA: por diseño lo comparten Codex, Cursor y lo que
     el proyecto sume, y cada uno deja lo suyo ahí.
     Regla: preservá TODO bloque delimitado por marcas `BEGIN`/`END` de terceros
     y toda sección que el template no contenga; actualizá solo las secciones
     que vienen del template (las leyes del harness). Ante la duda, mostrá el
     diff y que decida el humano: perder la ley de un proyecto es mucho más caro
     que quedarse una versión atrás en la redacción de una ley del harness.
     · **Las leyes se actualizan como BLOQUE COMPLETO**, nunca ley por ley: la
       sección de leyes viene ENTERA del template y reemplaza entera a la de la
       instancia. Leída ley por ley, una instancia con la numeración VIEJA
       conserva cada ley que el template ya no numera (porque "el template no la
       contiene") y terminás con DOS numeraciones conviviendo en el mismo
       archivo, que es peor que cualquiera de las dos.
     · El contenido AJENO que viva DENTRO de esa sección (una ley del proyecto,
       un bloque de otra herramienta) se **RE-ANCLA después** del bloque de
       leyes, con su texto intacto y bajo su propio encabezado: jamás se pierde
       y jamás conserva su número viejo, porque ese número ahora es de otra ley.
     · Tras el merge, **verificá las citas**: cada `Ley <n>` citada en
       `.claude/commands/` de la instancia tiene que resolver a la MISMA ley en
       CLAUDE.md y en AGENTS.md. Si una cita apunta a otra cosa, el merge quedó
       a medias: decilo y arreglá la cita antes de cerrar el update.
   - **Skills, por capa**: upstream (las del manifest del generador) se
     actualizan con el plugin; las `.managed` son de skills-sync (ni las
     toques: `make skills` las gobierna); el RESTO de `.claude/skills/`
     es ley local intocable. `skills.yaml` es ley local (jamás se pisa).
   - **Propiedad de la instancia** (harness-answers, models.yaml,
     CLAUDE.md, constituciones, specs, docs): lo local gana — es ley
     del proyecto; si choca con un cambio upstream, muestra ambos y
     que decida el humano.
4. Presenta las actualizaciones como diffs individuales. NUNCA apliques
   sin confirmación explícita por archivo — **con una excepción: los
   PAQUETES ATADOS se aceptan o rechazan juntos**, porque a medias
   rompen la instancia. Decláraselo al humano antes de que elija:
   - **Renombre del pipeline a `/smart`**: `.claude/commands/smart.md` (NUEVO:
     es el playbook completo) + `.claude/commands/auto.md` (que pasa a ser un
     puntero de deprecación de pocas líneas). El diff de `auto.md` se lee como
     un borrado masivo y NO lo es: el playbook se mudó a `smart.md`, porque el
     nombre viejo chocaba con el comando homónimo de otros agentes (Kimi Code).
     A medias es lo peor de los dos mundos: solo el puntero deja a la instancia
     sin pipeline, y solo `smart.md` deja el nombre viejo enseñando un playbook
     que ya no coincide con el resto del harness. El prefijo de task-ids
     `AUTO-` NO cambia (el panel lo genera y los ledgers viejos lo contienen).
     El puntero se borra en un ciclo, no ahora.
   - **Carriles**: `harness-policy.json` + `scripts/harness-policy.py` +
     `.claude/commands/smart.md` + `scripts/ship.sh` (el /smart nuevo hace
     `init --lane`, que el policy engine viejo rechaza; gate_lane y
     escalate viven en los otros dos).
   - **Pasos-custom**: `smart.md` + `harness-policy.json` + `pipeline-steps.sh`
     + `doctor.sh` (el /smart nuevo llama a pipeline-steps.sh y usa la parada
     custom_step_failed que solo existe en el policy.json nuevo).
   - **Plan-hondo / loop-corto**: `scripts/plan-lint.sh` + `scripts/ship.sh`
     (modo `--precheck`) + `.claude/commands/{rfc,implement,review,smart}.md`
     + `.claude/agents/{architect,implementer,reviewer}.md` + `doctor.sh`
     (que exige plan-lint.sh). Los comandos nuevos llaman a plan-lint y a
     `ship.sh --precheck`: con el ship viejo, `--precheck` se interpreta
     como task-id y falla; sin los agentes nuevos, nadie corre el precheck
     ni escribe el plan en el formato que plan-lint exige. Ojo: si la
     instancia tiene planes viejos en vuelo, plan-lint los va a marcar
     rojos (no traen los bloques `### T<n>`); es esperado, se reescriben o
     se terminan con el pipeline viejo.
   - **Canal-de-vuelta**: `scripts/harness-bug.sh` +
     `.claude/skills/harness-bug-report/SKILL.md` + `CLAUDE.md`/`AGENTS.md`
     (ley 12 en los dos mapas; instancias previas a la renumeración la traían
     en AGENTS.md como ley 9) + `.claude/commands/smart.md` + `doctor.sh` + la clave
     `upstream_issues:` del answers (la migración la aplica
     `update-migrate.sh` del paso 1b con el default documentado `auto`;
     DECLARÁSELO al humano igual: es la única acción del harness que publica
     algo hacia afuera, y si no lo quiere se cambia a `off`).
     La ley sin el script manda a los agentes a un comando que no existe, y
     el script sin la skill reporta sin verificar.
   - **Veredicto-sobrevive-al-rebase**: `scripts/change-id.sh` (NUEVO, hay que
     crearlo) + `scripts/harness-policy.py` + `scripts/evidence.py` +
     `scripts/verdict-scaffold.sh` + `scripts/ship.sh` + `harness-policy.json`
     + `.claude/agents/reviewer.md`. Es el paquete que MÁS duele a medias, y el
     modo de fallo es total, no parcial: el `ship.sh` nuevo le pasa
     `--patch-id` a `validate-ship`, y el `harness-policy.py` viejo no conoce
     ese flag, así que argparse sale con error y **TODO ship queda rojo**.
     Con el scaffold viejo el veredicto no lleva `patch_id` ni `reviewed_at`,
     así que el policy nuevo se niega a reusarlo y volvés al comportamiento de
     antes (estricto, no roto). Y el `reviewer.md` viejo trae un JSON de
     "formato exacto" sin esos dos campos: un reviewer que lo copie los borra y
     desactiva el mecanismo EN SILENCIO. Sin `change-id.sh` no hay identidad de
     cambio y el resto degrada a exigir el SHA exacto.
   - **Gates-en-CI** (solo `flow: prs`): `.github/workflows/harness-gates.yml`
     de cada repo gestionado + `scripts/ship.sh` (modo `--ci`). El workflow
     llama a `ship.sh --ci`, asi que con un ship.sh viejo el check muere con
     "task-id invalido" y la cola de merge queda bloqueada para todo el equipo.
     Los dos van juntos. Y recorda que el workflow no se vuelve obligatorio
     solo: el required check y la merge queue los activa un humano en el forge.
   - **Modelos**: `models.yaml` (esquema aliases) +
     `scripts/stamp-models.sh` + re-estampado de agentes. Si la instancia
     además usa **harness-cronjobs** (repo aparte), su `cron-runner.sh` lee las
     secciones `cronjobs:`, `cronjob_effort:` y `budgets:` de este mismo
     `models.yaml`: el runner viejo parsea el esquema inline viejo y muere en
     config-error, así que hay que actualizarlo del lado de ESE repo.
4b. **`.gitignore` de la instancia**: las instalaciones previas a esta
   versión no ignoran `go.work`, `go.work.sum` ni `graphify-out/`. El grafo
   pesa cientos de MB (128 medidos con 28 repos) y el flujo invita al
   accidente (`git init` del workspace, `make graph`, `git add -A`). Propón
   el diff contra `templates/gitignore.tmpl` CONSERVANDO lo que el humano
   haya añadido: aquí lo local suma, no compite. El doctor ya avisa de las
   tres entradas caras (issue #27).
5. Al aplicar: re-corre el doctor de la instancia y actualiza el rastro. Los
   dos archivos se **copian de la fuente, nunca se escriben de memoria** — un
   número recordado es exactamente cómo apareció el `0.60.0` que no existía:
   ```
   jq -r .version ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json > .harness-version
   sed -n 's/^digest: *//p' ${CLAUDE_PLUGIN_ROOT}/templates/MANIFEST.sha256 > .harness-templates
   ```
   Si el update tocó models.yaml o agentes, corre
   `bash scripts/stamp-models.sh`: el frontmatter de los agentes se
   estampa desde la política, nunca a mano. **Migración de esquema de
   models.yaml**: la DETECTA `update-migrate.sh` (paso 1b) y no la aplica
   sola, a propósito. Si la instancia trae el esquema viejo (roles con IDs
   crudos, sin `provider:` ni secciones `models.<provider>`), el script
   nombra cada rol con su ID crudo y sale 2, porque el mapeo inverso no es
   una función: en anthropic `smart` y `deep` resuelven al MISMO id, así que
   de un ID no se deduce el alias. El `provider:` y el alias de cada rol los
   elegís CON el humano, escribís el esquema nuevo, mostrás el diff y
   verificás con `bash scripts/stamp-models.sh check`. Un migrador que
   adivina el alias se ve igual de verde que uno correcto.

6. **CIERRE OBLIGATORIO: `bash scripts/harness-version.sh --verify`.** No
   declares el update terminado sin esto, y no lo reemplaces por tu propio
   resumen de lo que aplicaste. Compara la instancia contra el último tag en
   los DOS ejes —número **y** digest de templates— y cada uno atrapa un fallo
   distinto:
   - **el número no coincide** → el rastro quedó mal escrito;
   - **el digest no coincide** → el número quedó bien y el CONTENIDO no. Es el
     fallo caro: archivos que se rechazaron o que no se llegaron a aplicar, con
     una instancia que a partir de ahí se reporta al día. Ya pasó: "1
     actualizado, 24 conflictos" y ninguno de esos 24 traía los arreglos que el
     número prometía.

   Si sale rojo, dilo **con esas palabras** — el update no aterrizó — y lista
   qué quedó sin aplicar. Si sale exit 2 (no se pudo traer el tag), eso no es
   éxito: es un update **sin verificar**, y se dice así.

7. **Publica el commit del update por la puerta**: commitea los cambios del
   workspace y corre `bash scripts/instance-ship.sh` (árbol limpio, rebase,
   gitleaks, doctor, push). El repo de la instancia tiene su propia puerta a
   main desde el issue #37: pushearlo a mano por fuera del harness era el
   único camino y eso era un bug, no una regla.

Presta atención especial a: scripts/doctor.sh (es COPIA del plugin —
casi siempre conviene actualizarla), hooks, y ship.sh (gates nuevos).

Además: si detectas abogados con ownership "TBD" o specs esqueleto,
OFRECE correr la Fase 3.5 (arqueología ligera) de la skill
harness-init para llenarlos con contenido real — es la deuda más
común de instalaciones viejas.
