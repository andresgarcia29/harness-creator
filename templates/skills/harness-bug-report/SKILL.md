---
name: harness-bug-report
description: Verifica y reporta upstream un bug del HARNESS mismo (scripts, hooks, comandos, gates, panel, cronjobs del plugin harness-creator), no del código del proyecto. Úsala SIEMPRE que un artefacto del harness falle, se comporte distinto a lo que documenta, o te obligue a un workaround: te hace verificar que el bug es real y que vale la pena arreglarlo, y levanta el issue en el repo del plugin. Dispara sola, sin que el humano la pida.
---

# harness-bug-report: el bug del harness no muere en tu máquina

REGLA AUTOMÁTICA del workspace: si tropiezas con un bug del **harness**,
verificas y reportas. No esperas a que te lo pidan, y tampoco lo rodeas con un
workaround silencioso: un workaround local condena al siguiente usuario a
tropezar con lo mismo. Pero el reporte falso es peor que el bug no reportado
(entierra los reales), así que el filtro de abajo es obligatorio y es
fail-closed: **si una verificación no pasa, no hay issue.**

Lo verificable lo hace `scripts/harness-bug.sh` (propiedad del artefacto,
drift local, versión, dedupe, cuota, redacción). Lo que pones tú es el juicio:
¿es real, y vale la pena arreglarlo?

## Ley 0 operativa: el harness NO es tu tarea

Caso de campo, y es el que hace falta cortar: un agente haciendo una tarea de
producto choca con un gate que da falso rojo, se pone a "arreglar" el harness
para desatascarse, y ahí se pierde la tarea. No entrega lo que le pidieron,
toca la ley que lo juzga, y suele terminar en bucle.

Si el bug te BLOQUEA, el orden es LEY y no admite improvisación:

1. **NO edites el artefacto del harness y NO lo "pruebes arreglado".** El hook
   `guard-canonical` te lo bloquea, y con razón: es el juez, no el producto.
   Un agente atascado que edita el gate no está pasando el gate, lo está
   borrando, y con él todos los demás para siempre.
2. **Reportá** (los pasos de abajo). Reportar es la PRECONDICIÓN del paso 3:
   sin issue en el ledger, el desbloqueo no te lo da nadie.
3. **Desbloqueate DECLARANDO el bug**, no rodeándolo:
   `HARNESS_KNOWN_BUG='<slot>=<url-del-issue>'` en tu ship o precheck. El rojo
   queda como condición declarada (bus, sello, veredicto), nunca como verde.
   Los slots `security` y `veredicto` no se declaran jamás: un secreto
   filtrado no es un bug del harness, y sin veredicto no hubo review.
4. **Volvé a TU tarea.** El fix del harness llega por `/harness-update`, hecho
   por sus mantenedores, nunca por tu mano y nunca dentro de esta tarea.

## Paso 0: ¿es un bug DEL HARNESS?

| Lo que ves | Qué es |
|---|---|
| `scripts/*.sh` o `*.py` del harness revienta, o hace algo distinto a lo que dice su cabecera | bug del harness ✓ |
| un hook bloquea (o deja pasar) lo que su ley NO dice | bug del harness ✓ |
| un gate de ship.sh falla con entrada válida, o pasa con entrada inválida | bug del harness ✓ |
| el doctor reporta verde algo roto (o rojo algo sano) | bug del harness ✓ |
| un comando del pipeline documenta un flag/contrato que no existe | bug del harness ✓ |
| tus tests, tu build, tu servicio | bug TUYO: arréglalo en tu repo |
| tu paso custom, tu spec, tu abogado, tu answers | artefacto de tu instancia: arréglalo aquí |
| falta un CLI/MCP que elegiste | configuración: `scripts/bootstrap.sh`, no issue |
| te falta una capacidad que el harness nunca prometió | feature request, no bug |

`scripts/harness-bug.sh check <ruta>` decide la primera columna sin opinión:
propiedad del artefacto y si está personalizado localmente.

## Paso 1: verifica que es REAL (las cinco, en orden)

1. **Reprodúcelo dos veces, en shell limpia y con `bash -c`.** La sesión es
   zsh y su word-splitting da resultados falsos (ley 10 del workspace). Una
   falla que no se repite no es un bug: es un estado.
2. **Redúcelo al mínimo**: el repro NO puede depender de tus repos privados,
   tus secretos ni tu red. Si solo falla con tu workspace, todavía no sabes
   qué falla. Baja hasta el artefacto del harness solo, con entradas de
   juguete (un `mktemp -d`, dos archivos falsos).
3. **Lee el contrato antes de acusar**: la cabecera del script, su doc en
   `docs/harness/` y el CLAUDE.md. Un comportamiento documentado que no te
   gusta no es un bug, es un desacuerdo de diseño (eso va como feature
   request, con otra conversación).
4. **Descarta que sea TUYO**: ¿el archivo está parcheado localmente? ¿tu
   answers declara algo que el script asume distinto? `harness-bug.sh check`
   te dice si hay drift contra el template del plugin.
5. **Descarta que ya esté arreglado**: si tu instancia está atrasada, corre
   `/harness-update` y re-verifica. Reportar un bug ya corregido es el error
   más frecuente de este canal (`harness-bug.sh report` lo bloquea solo).

Guarda la salida del repro en un archivo (`tasks/<id>/harness-bug-<slug>.log`
o `.cache/`): es el `--repro` obligatorio.

## Paso 2: ¿VALE LA PENA arreglarlo?

Un bug real que no vale la pena arreglar tampoco se reporta. Responde las
tres; si alguna es "no", cierra el asunto con una nota al humano y sigue:

- **¿Le pasa a alguien más?** Si depende de tu layout, tu versión de una
  herramienta exótica o tu parche local, no. Eso es el `--impact` y es
  obligatorio escribirlo.
- **¿Qué cuesta?** Bloquea un ship / corrompe estado / miente en verde
  (reportar SIEMPRE) · fricción repetida (reportar) · cosmético una vez
  (no, salvo que la corrección sea de una línea y la propongas tú).
- **¿Es arreglable upstream sin romper a los demás?** Si el fix exige que el
  plugin adivine tu entorno, no es un bug del plugin: es una capacidad que
  falta, y va como feature request.

## Paso 3: reporta

```bash
scripts/harness-bug.sh report \
  --title "ship.sh --precheck interpreta el flag como task-id en bash 3.2" \
  --file scripts/ship.sh \
  --repro tasks/COR-42/harness-bug-precheck.log \
  --impact "cualquier instancia en macOS: --precheck es el paso previo a review de TODA tarea" \
  --dry-run          # míralo antes de publicar; quítalo para abrir el issue
```

El script verifica, redacta secretos, deduplica (local y remoto), respeta la
cuota de 3 issues **creados** por 24h (un issue que resultó duplicado, o que
cediste a otra máquina, no te la gasta) y publica en el repo del plugin. Sale
distinto de cero con la razón exacta cuando NO procede: propiedad (3), repro
ausente (4), cuota (5), instancia atrasada (6), drift local (7), canal apagado
(8), claim huérfano (9), claim imposible de tomar (10).

Si la cuota (5) te frena y abres el issue **a mano**, anótalo en el ledger o el
dedupe local quedará ciego justo para el bug que más se repite:

```bash
scripts/harness-bug.sh record \
  --url https://github.com/andresgarcia29/harness-creator/issues/45 \
  --file scripts/ship.sh \
  --title "ship.sh --precheck se lee como task-id"   # el MISMO título del issue
```

El título tiene que ser el del issue: la huella sale de él, y una huella distinta
no dedupea nada. La fila queda con status `manual`, que no consume cuota.

Los dos últimos vienen del candado local contra duplicados (`.harness/claims/`)
y no se destraban solos. Son problemas distintos con remedios distintos:

| Exit | Qué pasó | Qué hacer |
|---|---|---|
| 9 | ya había un claim sobre esa huella, el proceso que lo tomó ya no existe y no dejó `url` adentro: nadie sabe si alcanzó a publicar | busca la huella en los issues del plugin. Si aparece, ya está reportado. Si no aparece, borra ese claim (`rm -rf '.harness/claims/<fp>.lock.d'`) y re-corre |
| 10 | el claim no se pudo ni intentar: `.harness/claims/` no es un directorio escribible (permisos, disco lleno, un archivo con ese nombre) | arregla el directorio (el motivo exacto lo imprimió `mkdir` en la salida) y re-corre. Sin claim no hay dedupe, y sin dedupe el script no publica |

Nunca borres un claim "por si acaso": el que tiene una `url` adentro es el
rastro de un issue YA abierto, y borrarlo reabre la puerta al duplicado.

**Antes de publicar, lee el cuerpo del `--dry-run` completo.** Sale a un repo
PÚBLICO: nombres de tus repos privados, hosts internos, rutas con tu usuario y
IDs de tickets se quitan a mano (la redacción automática solo cubre patrones de
secretos). El repro debe ser genérico: si no lo es, vuelve al paso 1.2.

## Después

- Emite al bus lo que decidiste: reportado (con URL) o descartado (con la
  razón). El humano lee el panel, no tu consola.
- El ÚNICO workaround legítimo para un gate del harness es
  `HARNESS_KNOWN_BUG='<slot>=<url>'`, que se audita solo. Si además tuviste
  que parchear TU código de producto para rodear al harness, déjalo comentado
  con la URL del issue y quítalo cuando llegue el fix. Lo que no existe es un
  workaround dentro del harness: eso es editarlo, y eso está prohibido.
- Si el fix es de una línea y lo tienes claro, dilo en el issue (o manda el PR):
  un issue con diagnóstico y parche se arregla el mismo día.
- Nunca desactives un gate ni un hook para esquivar un bug del harness. Eso no
  es un workaround: es apagar la red de seguridad de todo el workspace.
