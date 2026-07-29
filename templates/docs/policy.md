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
- máximo de rondas respetado;
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
