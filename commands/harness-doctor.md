---
description: Verifica la salud de la instalación del harness (CLIs, MCPs, hooks, links, secretos)
argument-hint: [ruta-al-workspace]
---

Ejecuta el doctor sobre $ARGUMENTS (o el directorio actual):
- si el workspace tiene `scripts/doctor.sh`, usa ESE (es su copia
  versionada);
- si no, usa `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh <workspace>`.

Presenta los resultados agrupados: ✅ ok, ⚠️ advertencias, ❌ fallos.
Para cada fallo, da el comando exacto de remediación y ofrece
ejecutarlo. Si todo pasa, dilo en una línea y termina.
