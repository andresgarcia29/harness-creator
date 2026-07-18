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
   `instance.repo`) SIN tocar las decisiones registradas. Pregunta SOLO
   las preguntas nuevas de la entrevista que el answers no responde.
2. RE-INSTANCIA mentalmente cada template de
   `${CLAUDE_PLUGIN_ROOT}/templates/` con las respuestas registradas en
   harness-answers.yaml (por eso el esquema es fijo) y compara contra
   el archivo real de la instancia.
3. Clasifica cada diferencia según la PROPIEDAD del archivo:
   - **Propiedad del plugin** (scripts/{doctor,bootstrap,secrets,ship,
     worktree-task,quiet,with-secrets}.sh, hooks, y **el panel**:
     `scripts/ui/{panel.sh,server.py,pricing.json,dist/}`): upstream gana por
     default — re-instancia con las respuestas del answers y propón el
     archivo completo. Un parche local aquí casi siempre fue un fix que
     YA subió al plugin; verifica que la lógica local esté contenida en
     la nueva versión antes de reemplazar.
     · El PANEL es especialmente importante en updates recientes: `panel.sh`
       (nuevo) hace que `make ui` corra el **daemon Go `harnessd`** en vez de
       `server.py`, y el `dist/` trae el frontend nuevo (multi-máquina,
       terminales, sonda de MCP, archivar). El BINARIO `harnessd` NO es un
       archivo a diffear — `panel.sh` lo baja solo del release privado en el
       primer `make ui` (o cae a server.py si no hay acceso). Tras actualizar,
       recuérdale al humano correr `make ui` para bajar el daemon nuevo.
   - **Propiedad de la instancia** (harness-answers, models.yaml,
     CLAUDE.md, constituciones, specs, docs): lo local gana — es ley
     del proyecto; si choca con un cambio upstream, muestra ambos y
     que decida el humano.
4. Presenta las actualizaciones como diffs individuales. NUNCA apliques
   sin confirmación explícita por archivo.
5. Al aplicar: re-corre el doctor de la instancia y actualiza
   `.harness-version`.

Presta atención especial a: scripts/doctor.sh (es COPIA del plugin —
casi siempre conviene actualizarla), hooks, y ship.sh (gates nuevos).

Además: si detectas abogados con ownership "TBD" o specs esqueleto,
OFRECE correr la Fase 3.5 (arqueología ligera) de la skill
harness-init para llenarlos con contenido real — es la deuda más
común de instalaciones viejas.
