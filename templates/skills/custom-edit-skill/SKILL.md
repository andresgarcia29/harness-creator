---
name: custom-edit-skill
description: Busca una skill que ya existe y le aplica un cambio pedido en prosa ("busca la skill de Linear y que ahora también capture los bugs de QA"), respetando la capa a la que pertenece. Úsalo cuando el humano diga "cambia la skill que…", "edita el playbook de…", "esa skill ahora debe…", "quítale esto a la skill…", o invoque /custom-edit-skill.
---

# custom-edit-skill: cambiar una skill sin perder el cambio

El modo de fallo de este comando no es escribir mal: es editar la COPIA
equivocada. Hay tres capas y solo una se edita en sitio, así que el orden es
localizar, decidir la capa, y recién entonces tocar el archivo. Para crear
una que no existe: `/custom-build-skill`.

## Paso 1. Localizar (el humano da un nombre aproximado, no exacto)

```bash
ls .claude/skills/*/SKILL.md
grep -ril "<término del pedido>" .claude/skills/*/SKILL.md
grep -h '^description:' .claude/skills/*/SKILL.md   # para desempatar
```

Con varias candidatas, muéstralas con su `description` y que el humano
elija; nunca adivines cuál era. Con ninguna, esto no es una edición: dilo y
ofrece `/custom-build-skill` con el mismo pedido.

## Paso 2. Identificar la capa (define quién puede editarla)

| Señal en el directorio | Capa | Cómo se edita de verdad |
|---|---|---|
| hay un archivo `.managed` | compartida | NO en sitio: `make skills` la va a pisar. Se edita en el repo fuente que declara `skills.yaml`, se pushea, y `make skills` la trae |
| es una de las del plugin (skill-creator, pipeline-step-creator, harness-bug-report, custom-build-skill, custom-edit-skill) | upstream | en sitio se pierde en el próximo `/harness-update`. Dos salidas: copia local con nombre propio, o llevar el cambio al plugin (verifícalo con harness-bug-report y levanta el issue) |
| ninguna de las dos | local | es tuya: se edita en sitio |

Decir la capa ANTES de editar no es trámite: es la diferencia entre un
cambio que sobrevive y uno que desaparece sin aviso en el próximo update o
en el próximo `make skills`. Si el humano quiere el cambio YA sobre una
compartida o una upstream, la salida honesta es la copia local con nombre
nuevo, declarando que la original queda intacta y que ahora hay dos.

## Paso 3. El cambio mínimo

Diff, no reescritura: conserva la voz y la estructura de la skill y toca
solo lo pedido. Cuatro reglas:

- **La `description` es el gatillo**, no la toques por cosmética. Y al revés:
  si la queja es "nunca se carga" o "se dispara de más", el arreglo ES la
  description, con las palabras que el humano diría de verdad.
- **Si lo nuevo no comparte contexto con lo viejo, son dos skills**, no una
  más larga. Una skill que necesita scroll ya se volvió un doc.
- **Herramientas nuevas se verifican antes de citarlas**:
  `jq -r '.mcpServers | keys[]' .mcp.json` y `command -v <bin>`. Un paso que
  llama a un MCP que la instancia no tiene es una skill rota escrita con
  confianza.
- **Sin guion largo** (ley de estilo del workspace) y sin valores de
  secretos, solo referencias.

Y el límite que no se negocia por pedido: la skill propone, los gates
verifican. Si el cambio pedido es "que se salte el gate" o "que pushee sin
review", eso no se edita en una skill, se discute en `harness-policy.json`
con un humano.

## Paso 4. Verificación

```bash
d=.claude/skills/<nombre>
head -1 "$d/SKILL.md" | grep -qx -- '---'        && echo "frontmatter ok"
grep -qx "name: $(basename "$d")" "$d/SKILL.md"  && echo "name coincide con el directorio"
grep -q "$(printf '\xe2\x80\x94')" "$d/SKILL.md" && echo "ROJO: guion largo" || echo "estilo ok"
wc -l < "$d/SKILL.md"
```

Además, en una skill que ya tenía kilometraje, revisa que lo que CITA siga
existiendo: los scripts y rutas que nombra (`ls scripts/<x>.sh`) y los MCPs
que asume. El deterioro típico no es el párrafo nuevo, es el comando viejo
que ya se renombró.

Las skills se descubren al abrir la sesión: si el cambio no se ve al
invocarla, reinicia la sesión antes de buscarle un bug.

## Paso 5. Cerrar

Reporta: qué cambió (en una línea por cambio), en qué capa quedó, y qué
queda pendiente para que el cambio sea permanente. El pendiente es real y
tiene dueño: push al repo fuente más `make skills` si era compartida, issue
al plugin si era upstream, nada si era local.
