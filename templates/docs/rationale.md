# Por qué cada regla: el archivo de casos

Este documento existe por una razón de costo, y conviene entenderla antes de
usarlo.

Las reglas del harness se escribieron casi todas después de un incidente, y la
costumbre fue dejar el incidente pegado a la regla. Eso hizo los prompts muy
convincentes de leer: cada línea trae su cicatriz. Pero un prompt no se lee una
vez, **se re-lee en cada tool call del agente que lo carga**, y el orquestador
hace cientos por corrida. Medido sobre 663 transcripts, releer contexto es el
43% de la factura del harness.

O sea que la anécdota se paga por turno y se lee una sola vez.

La separación que hace este archivo:

- **En el prompt queda la REGLA**, con el mínimo de razón que hace falta para
  aplicarla bien. Una regla sin ninguna razón se obedece mal, y eso ya lo
  pagamos: la razón corta se queda.
- **Acá queda el CASO**: qué pasó, qué costó, y por qué la regla quedó como
  quedó. Es lo que hace falta para DISCUTIR la regla o para no revertirla por
  ignorancia, y eso no ocurre en cada tool call.

Nada de lo que está acá se borró de la ley. Si una regla desapareció del
prompt, es un bug, no una optimización.

---

## `delivery` es un dato, no una frase

**Regla**: en una tarea retomada manda lo que `state.json` ya declare en
`delivery`; escalar sube el carril, no cambia el destino.

**El caso**: el párrafo que fija la entrega se leía como incondicional, así que
una tarea que había nacido para publicar (venía escalada desde `/quick`) se
trató como `delivery: review`. Resultado: RFC completo, 5 implementers, 4
reviewers, QA, cuatro veredictos pass, y **cero commits publicados**. El trabajo
estaba entero y no había llegado a nadie.

---

## El sufijo de identidad en el task-id

**Regla**: el id lleva un sufijo derivado del usuario.

**El caso**: el chequeo de colisión solo mira el `tasks/` de la máquina local,
pero el trailer `Task: <id>` viaja al main que comparten todos los workspaces.
Dos personas con prompts parecidos el mismo día producían el mismo id, y la
trazabilidad (y `/archive`) mezclaba dos trabajos distintos bajo una sola clave,
para siempre.

---

## Los briefs de explorador van numerados

**Regla**: preguntas NUMERADAS y específicas, nunca "explora X", y siempre con
"marca explícitamente lo que NO existe".

**El caso**: medido en campo, los briefs numerados vuelven densos y accionables;
los genéricos vuelven difusos y hay que repreguntar, que es pagar dos veces.

---

## Por qué `POLICY-LANE-004` avisa en vez de rechazar

**Regla**: `init` avisa (no rechaza) si un carril corto incluye un repo de
infra; quien decide con criterio es `gate_lane` en el precheck, mirando lo que
el diff TOCA.

**El caso**: lo que hace de infra a un cambio es lo que toca, no en qué repo
vive. Medido: 20 de 31 repos del workspace son `infra-*` porque llevan su
`terraform/` al lado del código, así que rechazar por el kind del repo dejaba
un `.gitignore` de dos líneas sin ningún carril rápido.

---

## El carril no se dimensiona por número de repos

**Regla**: el carril lo fija `max(blast radius, tamaño)`; express admite
multi-repo si el delta de cada repo es chico y ninguno toca contratos.

**El caso**: express exigía "1 solo repo", así que cualquier cambio cosmético
que tocara tres caía en standard y pagaba architect + RFC + reviewer + QA por
repo para mover veinte líneas de HTML. Fue el segundo componente de costo de una
tarea que terminó en $367.

---

## El prefetch clona antes de explorar

**Regla**: `scripts/pull-all.sh` va PRIMERO, antes de cualquier exploración.

**El caso**: explorar un clon 27 commits atrás fue el error más caro medido en
campo. Producía inventarios de endpoints que ya no existían, y todo lo que se
planeaba encima nacía muerto.

---

## Preguntar no es parar

**Regla**: cada pregunta del enrichment trae su default y el trabajo SIGUE con
ese default.

**El caso**: una parada abierta esperando a alguien que no está mirando la
consola costó una hora de espera ciega. Corregir un supuesto reversible cuesta
minutos; esperar cuesta horas.

---

## Antes de matar a un agente, comprobá si hay una llamada en vuelo

**Regla**: "sin tool calls nuevas" y "sin trabajar" no son lo mismo. Si el
último `tool-start` del agente no tiene su cierre, está trabajando: contá el
reloj desde el `tool-start`.

**El caso**: un gate de navegador (Playwright, WebKit) es UNA llamada bloqueante
de nueve a diez minutos que por definición no produce eventos mientras corre. Se
mató a un QA sano que corría un gate de WebKit. Matar a un agente sano cuesta
doble: se pierde su trabajo en vuelo y se lo relanza con el modelo de escalación,
que es el caro.

---

## Un hallazgo se descubre una vez

**Regla**: los `blocking` que no son específicos de un repo se publican con
`scripts/finding.sh publish`, y cada implementer lee los de sus hermanos al
arrancar.

**El caso**: tres repos escribieron el MISMO guard roto en la misma tarea porque
el único difusor era el humano relayando a mano. La tercera vez costó igual que
la primera.

---

## Un supuesto de entorno se mide, no se razona

**Regla**: las entradas `SUPUESTO-ENTORNO:` del ledger exigen un `EVIDENCE_ID`
de `evidence.py run`, y `plan-lint.sh` se pone rojo sin él.

**El caso**: la pregunta que decidió una tarea entera era si un `<img>` degrada
limpio en un cliente de correo con imágenes bloqueadas. Se contestaba en diez
minutos midiendo. En vez de eso corrió architect, cuatro implementers y cuatro
reviewers, y recién ahí QA descubrió que el diseño no servía. Ese ciclo
completo, tirado, fue la mitad del costo de la tarea.

Hay un precedente más viejo con la misma forma: dos decisiones del plan salieron
marcadas "verificado en código" sobre una librería de routing, leyendo su
fuente. Las dos eran falsas y costaron dos de tres rondas.

---

## La prosa se verifica contra el código, no al revés

**Regla** (reviewer): el texto normativo que el diff toca se revisa con el mismo
rigor que el código; hay que abrir la función que la prosa describe.

**El caso**: los tres errores de spec de una corrida salieron de leer el código
fuente, no de releer el documento. Uno era una regla aritméticamente imposible
que estuvo a una fusión de entrar a las specs maestras. Otro era un panel que
explicaba mal un número que estaba bien.

---

## Nada de verificación por mutación sobre un árbol compartido

**Regla** (reviewer): mutar `src/` para ver si un test se pone rojo es legítimo
sobre un árbol TUYO, nunca sobre el vivo ni sobre el pin. Para eso ya está
`gate_test_muerde`, y si hace falta una sonda manual va sobre un worktree
descartable.

**El caso**: un build de QA absorbió un archivo mutado por el reviewer más un
test sin trackear, y la medición quedó corrupta sin que nada lo avisara. Se
salvó porque QA sospechó, no porque el harness lo dijera. Un falso rojo cuesta
una ronda; un falso verde shippea el bug.

---

## Por qué el gasto se mide solo

**Regla**: `transition` corre `harness-cost.py check` y se niega con
`POLICY-BUDGET-005` si la tarea está fuera de banda.

**El caso**: `POLICY-BUDGET-002` ya existía y no frenaba nada, porque dependía
de que alguien corriera `record-cost`, que no tenía una sola llamada desde
código. `spent_usd` se quedaba en 0.0 para siempre. Medido sobre 663
transcripts: el 87% del gasto vive en la sesión orquestadora, la mediana por
sesión son $12.52, y el top 10% de las sesiones se lleva el 66% de la factura.
Lo que faltaba nunca fue un precio más bajo: era un disyuntor para la cola.
