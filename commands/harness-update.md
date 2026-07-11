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
3. Clasifica cada diferencia:
   - **upstream**: el template mejoró → proponla.
   - **local**: personalización de la instancia → CONSÉRVALA (es ley
     del proyecto); si choca con un cambio upstream, muestra ambos y
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
