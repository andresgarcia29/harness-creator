---
description: Sincroniza mejoras del plugin a la instancia instalada (diff template ↔ instancia)
argument-hint: [ruta-al-workspace]
---

Actualización de la instancia en $ARGUMENTS (o el directorio actual).

1. Lee `.harness-version` y `harness-answers.yaml` del workspace. Si la
   versión coincide con la del plugin, dilo y termina.
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
