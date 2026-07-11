---
description: Instala el harness en un workspace multi-repo (discovery → clustering → entrevista → generación → verificación)
argument-hint: [ruta-al-workspace]
---

Vas a instalar un harness de ingeniería agéntica en el workspace de
$ARGUMENTS (si no se indicó, pregunta la ruta).

IDEMPOTENTE: si el workspace ya tiene `.harness-version`, entras en
MODO UPDATE (regla global de la skill): no re-preguntas lo respondido,
migras el esquema del answers, y todo cambio se presenta como diff.
Correr este comando N veces es siempre seguro.

Sigue ESTRICTAMENTE el flujo de la skill `harness-init` de este plugin.
Resumen del contrato:

1. `${CLAUDE_PLUGIN_ROOT}/scripts/discover.sh <workspace>` y lee el
   `inventory.json`. NO explores los repos a mano para lo que el script
   ya detecta.
2. Propón la TOPOLOGÍA DE AGENTES desde `by_role` (clustering: abogado
   por servicio; UNO para toda la infra; UNO para frontends; techo ~12)
   y entrevista al humano con el inventario como evidencia y
   `${CLAUDE_PLUGIN_ROOT}/catalog/capabilities.yaml` como menú.
3. Genera la instancia completa desde `${CLAUDE_PLUGIN_ROOT}/templates/`
   (tabla de generación de la skill: agentes, comandos, scripts, hooks,
   docs, .mcp.json, Makefile).
4. Verifica con `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh <workspace>` y
   reporta cada fallo CON su remediación.

Nunca escribas valores de secretos en ningún archivo. Solo referencias.
