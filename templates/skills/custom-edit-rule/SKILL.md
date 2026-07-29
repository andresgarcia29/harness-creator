---
name: custom-edit-rule
description: Busca una regla custom que ya existe en .claude/rules/ y le aplica un cambio pedido en prosa ("la regla de los proyectos ahora también aplica a los frontends", "quítale la excepción a…", "esta regla nunca se cumple"), con la evidencia de cómo se está cumpliendo hoy. Úsalo cuando el humano diga "cambia la regla de…", "afloja/endurece la regla…", "esa regla ya no aplica", o invoque /custom-edit-rule.
---

# custom-edit-rule: cambiar una ley sin romper lo que ya se ratificó

Cambiar una regla no es editar un archivo: es cambiar una ley que agentes y
humanos ya están citando. Por eso el orden es localizar, medir cómo se cumple
hoy, decidir si el cambio la afloja o la endurece, y recién entonces escribir.
El contrato vive en `docs/harness/rules.md`; para crear una que no existe:
`/custom-build-rule`.

## Paso 1. Localizar

```bash
ls .claude/rules/*.md
grep -ril "<término del pedido>" .claude/rules/ docs/constitution.md
head -20 .claude/rules/<id>.md          # frontmatter + la regla en una línea
```

Con varias candidatas, muéstralas con su línea de título y que el humano elija.
Con ninguna, esto no es una edición: ofrécele `/custom-build-rule`. Y si el
pedido en realidad apunta a una ley del harness (`CLAUDE.md`,
`harness-policy.json`) o a la constitución, dilo: eso no se toca desde acá.

## Paso 2. Enrichment: cómo se está cumpliendo HOY

El pedido casi siempre nace de un síntoma ("esta regla nunca se cumple",
"me estorba"), y el síntoma no dice la causa. Antes de tocarla, trae los
números con la misma fuente que declara su `source:`:

- **Cumplimiento actual**: cuántos casos la cumplen y cuántos no.
- **Su diente**: ¿existe el `enforced_by` y corrió alguna vez? Una regla que
  "nunca se cumple" con `enforcement: judgment` no necesita otra redacción,
  necesita un diente. Ese suele ser el arreglo real, y es el que nadie pide.
- **Quién la cita**: `grep -rn "<id>" docs/ .claude/` para saber qué se rompe
  si le cambias el alcance o el id.

Di en dos líneas qué encontraste, porque cambia el cambio: aflojar una regla
que se viola por falta de diente es tratar el síntoma.

## Paso 3. Clasificar el cambio (afloja o endurece)

| El cambio… | Consecuencia |
|---|---|
| **endurece** (menos excepciones, más alcance, diente más fuerte) | casos que ayer pasaban hoy fallan: lista los que vas a romper ANTES, con números del paso 2 |
| **afloja** (más excepciones, menos alcance, de gate a judgment) | necesita razón escrita en la regla, no solo en el chat: una ley que se afloja sin motivo registrado se afloja otra vez |
| **aclara** (misma exigencia, mejor redactada) | es el cambio barato y el más común; no toques ni `id` ni alcance |

Toda regla que estaba `RATIFICADA` y cambia lo que EXIGE vuelve a
`status: DRAFT`: la firma anterior era sobre otro texto. Un cambio que solo
aclara la redacción conserva la firma, y lo dices en el reporte.

El `id` no se cambia: es lo que citan la constitución, los agentes y los
reviews. Si de verdad hay que renombrarla, es regla nueva más el borrado de la
vieja, y se actualizan los punteros.

## Paso 4. Aplicar el cambio mínimo

Diff, no reescritura. Y mantén el archivo coherente consigo mismo: si tocas
`enforcement`, tiene que existir el `enforced_by` nuevo (créalo o baja a
`judgment`); si tocas `applies_to`, mueve el puntero (constitución §7 para
workspace, el agente o el repo para alcances chicos); si tocas la exigencia,
actualiza también "Cómo se verifica" y "Excepciones", que son las dos
secciones que quedan mintiendo cuando alguien edita solo el título.

Sin guion largo, sin valores de secretos, y el límite de siempre: si el cambio
pedido es "que la regla permita saltarse un gate", eso no se edita acá, se
discute en `harness-policy.json` con un humano.

## Paso 5. Verificación

```bash
make doctor 2>&1 | grep -i "regla"                       # el contrato sigue válido
grep -rn "<id>" docs/ .claude/ 2>/dev/null               # punteros y citas coherentes
```

Además, relee la regla ya editada preguntándote si un agente que solo lee ESE
archivo haría lo correcto. Si para entenderla hace falta el chat de hoy, el
cambio no aterrizó en el texto.

## Paso 6. Cerrar

Reporta: qué exige ahora la regla (una línea), si el cambio afloja, endurece o
aclara, qué casos rompe con números, si volvió a `DRAFT` y por qué, y el
pendiente que quede (crear el verificador, migrar los casos que ya no cumplen,
la ratificación humana).
