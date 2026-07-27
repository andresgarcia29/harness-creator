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
1b. **Migra el esquema del answers** si esta versión agregó campos
   (ej. `scope:` por capacidad según el campo `cronjob:` del catálogo,
   `instance.repo`, `models.provider` — default `anthropic` si el
   answers no lo trae; los valores de `models.*` pasan a ser ALIASES
   fast|smart|deep) SIN tocar las decisiones registradas. Pregunta SOLO
   las preguntas nuevas de la entrevista que el answers no responde.
2. RE-INSTANCIA mentalmente cada template de
   `${CLAUDE_PLUGIN_ROOT}/templates/` con las respuestas registradas en
   harness-answers.yaml (por eso el esquema es fijo) y compara contra
   el archivo real de la instancia.
3. Clasifica cada diferencia según la PROPIEDAD del archivo:
   - **Propiedad del plugin**: TODO `scripts/` sale del plugin, así que la
     lista es "todos", y se enumera para que un script NUEVO no se cuele sin
     clasificar (`tests/test_docs.sh` lo verifica: agregar un script al plugin
     y no nombrarlo acá deja a las instancias sin recibirlo).
     scripts/{doctor,bootstrap,secrets,ship,worktree-task,quiet,with-secrets,
     repo-brief,stamp-models,change-id,verdict-scaffold,plan-lint,build-slot,
     deploy-watch,emit,forge,gowork,graph-refresh,minion-probe,pull-all,
     ticket-close,ticket-pull,harness-bug,harness-version,skills-sync,
     pipeline-steps,py,fe,archived-repos}.sh,
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
   - **Carriles**: `harness-policy.json` + `scripts/harness-policy.py` +
     `.claude/commands/auto.md` + `scripts/ship.sh` (el /auto nuevo hace
     `init --lane`, que el policy engine viejo rechaza; gate_lane y
     escalate viven en los otros dos).
   - **Pasos-custom**: `auto.md` + `harness-policy.json` + `pipeline-steps.sh`
     + `doctor.sh` (el /auto nuevo llama a pipeline-steps.sh y usa la parada
     custom_step_failed que solo existe en el policy.json nuevo).
   - **Plan-hondo / loop-corto**: `scripts/plan-lint.sh` + `scripts/ship.sh`
     (modo `--precheck`) + `.claude/commands/{rfc,implement,review,auto}.md`
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
     (ley 12 / ley 9) + `.claude/commands/auto.md` + `doctor.sh` + la clave
     `upstream_issues:` del answers (migración: si el answers no la trae,
     agrégala en `auto` DESPUÉS de declararle al humano que el harness va a
     publicar issues en el repo público del plugin; si no lo quiere, `off`).
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
   `bash scripts/stamp-models.sh` — el frontmatter de los agentes se
   estampa desde la política, nunca a mano. **Migración de esquema de
   models.yaml**: si la instancia trae el esquema viejo (roles con IDs
   crudos, sin `provider:` ni secciones `models.<provider>`), migra:
   `provider: anthropic`, traduce cada ID a su alias (fast|smart|deep)
   y muestra el diff.

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

Presta atención especial a: scripts/doctor.sh (es COPIA del plugin —
casi siempre conviene actualizarla), hooks, y ship.sh (gates nuevos).

Además: si detectas abogados con ownership "TBD" o specs esqueleto,
OFRECE correr la Fase 3.5 (arqueología ligera) de la skill
harness-init para llenarlos con contenido real — es la deuda más
común de instalaciones viejas.
