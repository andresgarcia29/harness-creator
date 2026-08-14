# Policy engine v1

`harness-policy.json` contiene las leyes ejecutables del flujo. Los prompts
proponen el trabajo; `scripts/harness-policy.py` decide si una transición o un
ship son válidos.

## Estado

Una tarea nueva ejecuta:

```bash
scripts/harness-policy.py init tasks/<task-id> --lane <quick|express|standard|full> \
  [--delivery <review|prs|trunk>]
```

Toda transición usa:

```bash
scripts/harness-policy.py transition tasks/<task-id> <fase> --actor <identidad>
```

El motor conserva `tasks/<task-id>/state.json` con fase, **carril**,
**entrega** (`delivery`, si el comando la declaró), rondas de review e
historial. No se edita a mano.

### El camino de vuelta

`allowed_transitions` solo apunta hacia adelante, así que una fase avanzada
por error no tiene retorno por `transition`. Editar `state.json` a mano está
prohibido (y además es detectable: `validate-ship` muere con
`POLICY-STATE-003` cuando la fase no coincide con el último movimiento del
historial). El camino legítimo es:

```bash
scripts/harness-policy.py rollback tasks/<task-id> <fase> \
  --actor <identidad> --reason "<por qué>"
```

Reglas, cada una con su código:

- solo va **hacia atrás** según `workflow.phase_order` (`POLICY-ROLLBACK-003`).
  Para avanzar se usa `transition`, que sí verifica los gates del grafo: por
  construcción, deshacer y rehacer no puede saltarse un gate;
- una tarea `blocked` se rescata con `resume`, no con rollback
  (`POLICY-ROLLBACK-001`);
- la fase actual y el destino tienen que existir en el orden canónico
  (`POLICY-ROLLBACK-002`);
- el motivo es obligatorio (`POLICY-ROLLBACK-004`): un rollback sin motivo es
  una edición a mano con otro nombre.

Queda en `history[]` como `{"kind": "rollback", ...}` con actor y motivo, y
**no cobra ronda de review**: deshace un movimiento que nunca ocurrió, y
cobrarlo castigaría a quien corrige el error.

### Una fase, una sesión (el relevo)

Cada `transition` estampa en `state.json` el campo **`session_id`**: quién
manejó esa fase. Dos fases seguidas con el mismo id son la prueba de que el
orquestador arrastró una sesión, y se ve sin leer un solo transcript.

Medido sobre una tarea de un repo, una migración y dos rondas de review: el
orquestador fue UNA sesión durante 45.3h de las 45.4h de reloj de la tarea, con
688 turnos, 440k de contexto medio y 758k de pico. El trabajo real de todos los
subagentes fueron 5.8h. El contexto ya se modelaba como cosa de FASE (el eximido
de `ctx` se ata a la fase en que se autorizó); la sesión no, y hubo tareas que
firmaron cuatro eximidos del mismo `COST-CTX`, uno por fase.

Cuando la fase avanza de verdad, la transición deja **`tasks/<id>/handoff.json`**.
El orquestador cierra su turno ahí; **quien ejecuta el corte es
`orchestrator-watch.sh`**, que toma el marcador y lanza `/smart <id>` con
contexto fresco. Tiene que ser algo de afuera: un prompt no puede terminarse a sí
mismo ni relanzarse. El vigilante espera una quietud mínima
(`HARNESS_ORCH_HANDOFF`, 60 s) antes de tomarlo, para no poner una segunda
sesión encima de una que siguió trabajando.

No dejan marcador, a propósito:

| Caso | Por qué |
|---|---|
| `review → review --repo` | es la misma fase: relevar por ronda pagaría un arranque por ronda |
| carril `quick` | una sesión corta de punta a punta; su contexto nunca crece |
| `archive` | no hay fase siguiente |
| `ship → deploy` | lo escribe `deploy-watch.sh` al terminar: durante los hasta 2820 s de espera no hay ninguna sesión viva, que es justamente el punto |

Sin marcador todo se comporta como antes (regla de silencio de bus), así que una
tarea en vuelo no cambia de conducta y `session_id` ausente no significa nada
malo: significa que esa fase corrió con una versión anterior.

### Tareas estancadas (`stale`)

Una tarea puede quedarse en una fase no terminal **con el trabajo hecho y sin
pausa**: no está bloqueada ni esperando a nadie, está detenida y contada como si
avanzara. Desde afuera se ve idéntica a una que progresa, así que el modo de
falla es silencioso y su costo es reloj que nadie contabiliza (caso medido:
12h46m en `implement`, descubierto a mano mirando timestamps).

```bash
scripts/harness-policy.py stale tasks     # exit 0 = ninguna; 1 = hay alguna
```

Compara `phase_since` (que `set_phase` ya estampa en todo movimiento) contra
ahora, con un techo **por fase**, porque el trabajo no dura lo mismo: un
`implement` de 40 minutos es normal y un `ship` de 40 no.

| fase | techo | fase | techo |
|---|---|---|---|
| `intake` | 30 min | `review` | 90 min |
| `rfc` | 90 min | `ship` | 30 min |
| `implement` | 120 min | `deploy` | 60 min |

`blocked` y `archive` están exentas: una es una parada registrada esperando a un
humano, la otra terminó. Una tarea sin `phase_since` legible se avisa igual: no
poder mirar no es verde.

Lo corre `orchestrator-watch.sh` en cada pasada (`status`, `once` y `daemon`), y
avisa **una vez por fase** por el bus. Avisa y nada más: no pausa ni relanza. Una
tarea puede llevar tres horas en una fase por buenos motivos, y el que relanza es
el vigilante, que ya sabe hacerlo. La señal es distinta de la suya: aquélla mide
**silencio de bus** y caza al agente que murió callado; ésta mide **tiempo en
fase** y caza a la que sigue emitiendo sin terminar nunca.

## Carriles

Las transiciones válidas dependen del carril: `quick` y `express` permiten
`intake → implement` (saltan rfc); `standard` y `full` exigen el grafo
completo. `escalate` sube el carril (solo hacia arriba: quick → express →
standard → full) y re-encauza la tarea donde el carril DESTINO recupera la
deliberación saltada: `rfc` si ese carril la declara (standard, full), o su
fase inicial si no (quick → express cae en `intake`). El worktree se
conserva siempre:

```bash
scripts/harness-policy.py escalate tasks/<task-id> --to standard --actor orchestrator
```

`gate_lane` en ship.sh es quien verifica que el diff real respete el
carril declarado (códigos `POLICY-LANE-001..005`: carril desconocido,
escalación solo hacia arriba, tarea bloqueada, aviso de infra en carriles
chicos, y quick de un solo repo).

`validate-dag` exige IDs únicos, repos válidos, dependencias existentes y un
grafo sin ciclos. `record-cost` conserva un total monotónico y bloquea cuando
supera el presupuesto inicial. `pause` sólo acepta los motivos cerrados de
`harness-policy.json`; `resume` devuelve la tarea a la fase que fue pausada.

## Costo fuera de banda (`POLICY-BUDGET-005`)

`transition` corre `scripts/harness-cost.py check` y se niega con
`POLICY-BUDGET-005` si la tarea está fuera de banda. El gate agrega tres
términos y **cada uno tiene su propia salida**, que es lo que hay que mirar
antes de elegir remediación:

| Término | Qué mide | Ventana | Salida auditable |
|---|---|---|---|
| `COST-BUDGET` | gasto total contra `budget_usd` | toda la tarea | `harness-policy.py budget tasks/<id> --to <n> --actor <quien> --reason "<por qué>"` |
| `COST-CACHE` | acierto de caché de un rol bajo el piso | la fase en curso | `harness-policy.py cost-waive tasks/<id> --band cache --agent <rol> --actor <quien> --reason "<por qué>"` |
| `COST-CTX` | contexto medio de un rol sobre el techo | la fase en curso | `... --band ctx --agent <rol> ...` |

`budget --to` **solo** mueve `COST-BUDGET`. Los otros dos salen de
transcripts, o sea que son históricos e inmutables: la remediación que el gate
imprime (recortar el contexto de arranque) no se puede aplicar en retroactivo, y
sin `cost-waive` la tarea quedaba trabada para siempre en su fase, con el
trabajo commiteado y el precheck verde.

### `COST-CTX` del orquestador no frena una transición que RELEVA

Un término se cobra donde su remediación existe, y ésta es la excepción que lo
hace explícito. La transición de fase **es** la remediación del contexto: deja
el marcador de relevo, el orquestador cierra su turno y `orchestrator-watch`
levanta una sesión nueva con contexto limpio. Cobrar `COST-CTX` ahí no recupera
un peso (ese contexto ya se gastó) y no protege nada: lo único que el bloqueo
evitaría, que la fase siguiente corra sobre la sesión inflada, ya lo evita el
relevo. Lo que producía era ceremonia, un eximido por fase concedido siempre,
porque con la tarea verde y la plata gastada no hay otra respuesta correcta.

Así que en una transición que releva, el término **se imprime y va al bus, pero
no frena**. Sigue frenando, con `cost-waive` como salida, cuando la sesión de
verdad continúa:

- se va a `archive` o a `deploy`, que no relevan;
- el carril es `quick`;
- el vigilante está apagado (`HARNESS_ORCH_OFF` o `.harness/orch-watch.off`),
  así que nadie va a levantar la sesión nueva.

Es fail-closed sobre esas tres: la exención existe solo mientras el contexto del
que el término se queja esté por descartarse. Y no afloja lo demás:
`COST-BUDGET` sigue frenando por dólares, `COST-CACHE` sigue igual, y la
exención es del **orquestador** y de nadie más, porque el contexto de arranque
de un subagente sí lo controla quien lo lanza, que es justo lo que la
remediación impresa pide.

### El aviso llega mientras todavía se puede actuar

`orchestrator-watch` corre `harness-cost.py ctx-watch` en cada pasada (una sola
lectura de los transcripts para todas las tareas, igual que `stale`) y avisa al
llegar al 80% del techo, `HARNESS_CTX_WARN_PCT`. Antes el techo se cruzaba en
silencio y el primer aviso era la transición frenada, o sea con todo gastado y
ninguna decisión disponible. La decisión que este aviso habilita solo existe a
tiempo: cerrar la fase y dejar entrar el relevo, en vez de arrancar otro tramo
de descubrimiento sobre una sesión que ya arrastra 400k.

### La ventana: los dos términos de tasa miran la fase EN CURSO

El gasto es acumulativo y se mide sobre toda la tarea. El acierto de caché y el
contexto medio **no**: son promedios sobre transcripts inmutables, así que un
umbral sobre toda la historia es un trinquete de un solo sentido y el primer
agente que cierra bajo el piso cobra su peaje en **toda** transición futura.
Caso de campo: dos abogados de RFC de una sola respuesta congelaron una tarea
que globalmente estaba en 94.4% de acierto.

Por eso `transition` estampa `phase_since` en `state.json` en cada movimiento
de fase, y `harness-cost.py check` evalúa `COST-CACHE` y `COST-CTX` solo sobre
los turnos posteriores a ese instante, que es la única ventana sobre la que la
remediación impresa puede actuar. Lo que queda afuera **se declara** en cada
corrida (nunca se calla), el mínimo de turnos se cuenta sobre la ventana, y un
`--since <iso>` explícito la pisa. Una tarea sin `phase_since` (creada antes de
esto) se mide entera, y el check lo dice.

`cost-waive` no apaga nada:

- el término tiene que **existir** (`POLICY-COST-002` si no está frenando): se
  ancla al valor MEDIDO, así que no se puede eximir por adelantado
- cubre ese valor, no la banda: algo **peor** vuelve a frenar
- exige `--reason` (`POLICY-COST-004`) y queda en `history[]` con
  `kind: cost-waive`
- cada `cost-check` posterior lo **imprime** con quién lo autorizó y por qué

El piso de caché además no se le cobra a un agente demasiado **corto**: el
mejor caso posible con T turnos es escribir el contexto una vez y leerlo T-1
veces (`(T-1)/T`), así que por debajo de `1/(1-piso)` turnos (10 con el piso de
fábrica) el umbral mediría la ventana de caché y no el derroche. Ese término se
declara en la salida y no bloquea.

## Entrega (`delivery`)

El comando de entrada declara QUÉ se publica, y el motor lo guarda en
`state.json`: `review` (nada se publica: commits del worktree sí; push, PR
y main jamás), `prs` (rama + PR) y `trunk` (ship directo a main). El
vocabulario es el del knob `flow` del workspace. `/smart` registra
`review`, `/smart-pr` registra `prs`, `/smart-main` registra `trunk`.

El "go" posterior a un `/smart` es una transición auditable, no una frase
de chat:

```bash
scripts/harness-policy.py delivery tasks/<task-id> --to prs --actor humano
```

La entrega **solo sube** (`review → prs → trunk`) y queda en `history[]`
con `kind: delivery`, actor y motivo. Códigos: `POLICY-DELIVERY-001`
(entrega desconocida, también si `state.json` trae un valor ilegible),
`-002` (degradarla, o promoverla a donde ya está), `-003` (`validate-ship`
con `delivery: review`; `ship.sh` lo devuelve como exit 8) y `-004`
(promover una tarea que no declara entrega).

Una tarea SIN campo `delivery` conserva la conducta de siempre: `ship.sh`
consulta `delivery-mode`, recibe `flow` y publica con el de
`harness-answers.yaml`. Y `autonomy: checkpoint` manda por encima de la
invocación: con checkpoint hay una parada antes de publicar aunque la
entrega declarada sea `trunk`.

## Contrato de ship

`validate-ship` exige:

- fase `review`;
- máximo de rondas respetado, **con la misma regla que usa `transition`**: si
  la serie de bloqueantes de algún repo viene bajando, el techo efectivo es el
  duro (2× el máximo), igual que la excepción por convergencia que concede la
  ronda extra. Los dos lados consultan `limite_de_rondas()`, que es donde vive
  la regla. Antes cada uno la evaluaba por su cuenta y se contradecían: una
  tarea cruzaba a la ronda 5 porque el motor se la **concedía** por convergencia
  y después el ship la rechazaba contra el máximo pelado, o sea que el mecanismo
  que premia converger terminaba bloqueando al que converge;
- verdict y QA en `pass` para el HEAD actual;
- reviewer identificado y separado de los implementadores;
- entrega coherente: con `delivery: review` no se publica nada
  (`POLICY-DELIVERY-003`, que `ship.sh` devuelve como exit 8).

### Quién mueve `review → ship`

La registra **`ship.sh`**, no el orquestador. `ship.sh` se corre una vez por
repo, pide la transición después de cada push, y solo prospera en el último:
`POLICY-SHIP-004` la rechaza mientras quede un repo planificado sin veredicto
o un repo con veredicto que no figure en `ship.log` (las fuentes son
`dag.json`, `state.repos` y `ship.log`), y el mensaje nombra cuáles faltan.

Por eso el orquestador **no** debe pedirla: adelantarla dejaba a los repos
restantes sin camino, porque `validate-ship` exige fase `review` y el grafo no
tiene arista `ship → review`. Si una tarea ya quedó adelantada, se corrige con
`rollback` (arriba), no editando el estado.

El registro es fail-open a propósito: cuando `ship.sh` la pide, el push ya
ocurrió, así que un fallo de contabilidad avisa fuerte pero no convierte un
ship exitoso en un rojo.

Evidence v1 valida por separado que las pruebas citadas pertenezcan a ese mismo
HEAD. Los errores tienen códigos estables (`POLICY-TRANSITION-001`,
`POLICY-ROLE-003`, etc.) para que un agente corrija una sola causa sin
interpretar texto libre.
