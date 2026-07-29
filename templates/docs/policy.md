# Policy engine v1

`harness-policy.json` contiene las leyes ejecutables del flujo. Los prompts
proponen el trabajo; `scripts/harness-policy.py` decide si una transición o un
ship son válidos.

## Estado

Una tarea nueva ejecuta:

```bash
scripts/harness-policy.py init tasks/<task-id> --lane <quick|express|standard|full>
```

Toda transición usa:

```bash
scripts/harness-policy.py transition tasks/<task-id> <fase> --actor <identidad>
```

El motor conserva `tasks/<task-id>/state.json` con fase, **carril**, rondas de
review e historial. No se edita a mano.

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

## Contrato de ship

`validate-ship` exige:

- fase `review`;
- máximo de rondas respetado;
- verdict y QA en `pass` para el HEAD actual;
- reviewer identificado y separado de los implementadores.

Evidence v1 valida por separado que las pruebas citadas pertenezcan a ese mismo
HEAD. Los errores tienen códigos estables (`POLICY-TRANSITION-001`,
`POLICY-ROLE-003`, etc.) para que un agente corrija una sola causa sin
interpretar texto libre.
