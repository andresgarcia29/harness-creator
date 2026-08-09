#!/usr/bin/env bash
# mem-recall.sh, SessionStart: la memoria episódica se LEE, no solo se escribe.
#
# POR QUÉ EXISTE (issue #101): la capability `engram` se instalaba como MCP y su
# propio propósito en el catálogo declara el contrato de lectura ("mem_search al
# iniciar, mem_save al cerrar"), pero el generador no emitía UN SOLO artefacto
# que lo ejecutara: cero menciones en settings.json y cero en hooks/. Medido en
# una instancia: 288 observaciones acumuladas y 0 consultadas. La memoria se
# escribía y no la leía nadie.
#
# Es exactamente el "consejo vacío" que la regla 1 de CONTRIBUTING prohíbe: una
# herramienta citada por un prompt sin la cadena completa (quién la instala,
# quién la alimenta, quién la vigila, QUIÉN LA EJECUTA). El eslabón que faltaba
# era el último, y es el único que no puede depender de que el agente se acuerde:
# el CLAUDE.md mandaba leer la memoria y nada lo hacía cumplir.
#
# QUÉ HACE: en el arranque de sesión imprime un recordatorio corto. Lo que un
# hook imprime en SessionStart entra al contexto de la sesión, así que el agente
# lo lee antes de su primer turno. No llama al MCP (un hook es un script: no
# tiene las herramientas del modelo) y no lo pretende: lo que hace es que la
# consulta ocurra, que era justo lo que no ocurría.
#
# SOLO SI ENGRAM ESTÁ: la señal es `.mcp.json`, que es donde el generador deja
# los MCPs elegidos. Sin engram, este hook no imprime NADA y sale 0, así que
# instalarlo en un workspace que no lo eligió no cuesta ni un token. La
# alternativa (que el generador decida al escribir settings.json) haría que la
# respuesta dependa del día en que se generó la instancia y no de lo que la
# instancia tiene hoy.
#
# FAIL-OPEN, como todo observador (track-read, ui-emit, on-compact): un
# recordatorio que puede tumbar una sesión es un bug, no una feature. Sale 0
# pase lo que pase, incluso sin jq.
set -u

exit_ok() { exit 0; }
trap exit_ok EXIT

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
mcp="$root/.mcp.json"

[ -f "$mcp" ] || exit 0

# grep y no jq: este hook corre en CADA arranque de sesión y la pregunta es de
# presencia, no de estructura. Un jq ausente no puede costarle el recordatorio a
# nadie (y el harness ya declara jq como requisito en otros lados, donde SÍ hace
# falta parsear).
grep -q '"engram"' "$mcp" 2>/dev/null || exit 0

cat <<'RECALL'
── memoria episódica (engram) ────────────────────────────────────────
Este workspace tiene memoria de sesiones anteriores y NO se carga sola.
Antes de empezar la tarea:

  1. `mem_context` para el estado reciente del proyecto.
  2. `mem_search <palabras del pedido>` si el pedido menciona algo que
     puede haberse trabajado antes (un repo, un issue, una decisión).

Y al cerrar, `mem_save` con lo que no se deduce del código: la decisión y
su porqué, la causa raíz de un bug, la convención que se acordó. Lo que ya
está en el repo o en git no se guarda.

Si una memoria contradice lo que ves en el árbol, manda el árbol: la
memoria refleja lo que era cierto cuando se escribió.
RECALL
