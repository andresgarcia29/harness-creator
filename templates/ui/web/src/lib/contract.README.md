# Contrato daemon→UI (ADR-0003)

`contract.gen.ts` está **vendorizado** desde `harness-daemon/contract/harness.gen.ts`,
que el daemon genera desde sus structs Go (`internal/api`, vía tygo). El daemon es
la fuente de verdad del wire. Resync: `scripts/sync-contract.sh`.

## Guard automático de drift: diseñado, diferido a v53.2

Un guard de compilación (`tsc`) que vuelva el drift Go↔TS un error de build es el
objetivo, pero se probó que un espejo exacto de tipos NO funciona hoy porque la UI
**enriquece** el wire en 4 formas legítimas:

- `init` / `herdr`: el daemon emite `any` (evita ciclos de import); la UI les pone
  tipos ricos (`InitState`, `HerdrState`).
- `ThreadItem.k`: el daemon manda `string`; la UI lo estrecha a `"text"|"think"|"tool"`.
- `Snapshot.runs`: el daemon manda `map[string]any`; la UI lo tipa `{task,session,kind}`.
- null vs undefined: punteros Go sin `omitempty` → `null` en el wire; la UI mezcla
  `?`/`| null` por campo. El runtime los trata igual (`== null`).

Un guard sano necesita separar en la UI una capa **wire** (= tipos generados, 1:1)
de la capa **app** enriquecida. Eso es trabajo de v53.2 (extracción de `harness-ui`).
Hasta entonces, el resync + revisión manual del diff del `.gen.ts` es el control.
