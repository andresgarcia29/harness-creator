---
description: Sincroniza mejoras del plugin a la instancia instalada (diff template ↔ instancia)
argument-hint: [ruta-al-workspace]
---

Actualización de la instancia en $ARGUMENTS (o el directorio actual).

0. `/harness-init` en un workspace ya instalado hace EXACTAMENTE esto
   (modo update) — son el mismo flujo; este comando es el atajo.
1. Lee `.harness-version` y `harness-answers.yaml` del workspace. Si la
   versión coincide con la del plugin, dilo y termina.
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
   - **Propiedad del plugin** (scripts/{doctor,bootstrap,secrets,ship,
     worktree-task,quiet,with-secrets,repo-brief,stamp-models}.sh,
     scripts/{harness-policy,evidence}.py, `harness-policy.json`,
     `scripts/cronjobs/cron-runner.sh`, hooks, `AGENTS.md`, y **el panel**:
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
   - **Modelos**: `models.yaml` (esquema aliases) +
     `scripts/stamp-models.sh` + `scripts/cronjobs/cron-runner.sh` (el
     runner viejo parsea el esquema inline viejo: con el models.yaml
     nuevo muere en config-error) + re-estampado de agentes.
5. Al aplicar: re-corre el doctor de la instancia y actualiza
   `.harness-version`. Si el update tocó models.yaml o agentes, corre
   `bash scripts/stamp-models.sh` — el frontmatter de los agentes se
   estampa desde la política, nunca a mano. **Migración de esquema de
   models.yaml**: si la instancia trae el esquema viejo (roles con IDs
   crudos, sin `provider:` ni secciones `models.<provider>`), migra:
   `provider: anthropic`, traduce cada ID a su alias (fast|smart|deep)
   y muestra el diff.

Presta atención especial a: scripts/doctor.sh (es COPIA del plugin —
casi siempre conviene actualizarla), hooks, y ship.sh (gates nuevos).

Además: si detectas abogados con ownership "TBD" o specs esqueleto,
OFRECE correr la Fase 3.5 (arqueología ligera) de la skill
harness-init para llenarlos con contenido real — es la deuda más
común de instalaciones viejas.
