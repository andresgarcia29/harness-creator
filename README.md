# harness-creator

🇬🇧 [English version](README.en.md)

**Instalador universal de harnesses de ingeniería agéntica multi-repo**, como plugin de Claude Code.

Le apuntas a una carpeta con tus repositorios y genera un *harness* completo y adaptado a tu stack: agentes con conocimiento real de tu código, gates deterministas que protegen `main`, un pipeline de trabajo de ticket a producción **dimensionado al blast radius** (una tarea chica corre con 2 sesiones LLM; una migración multi-servicio con el pipeline completo), memoria, secretos, self-healing nocturno y documentación viva. Funciona para cualquier proyecto — un SaaS multi-tenant de 24 repos o un monorepo chico — porque **descubre** tu stack en vez de asumirlo. Está orientado a Claude Code, pero genera `AGENTS.md` (el estándar multi-herramienta): Cursor, Kimi Code, Codex o cualquier otro agente pueden leer y operar el mismo harness.

> **Filosofía (una línea):** *los agentes proponen, los sistemas deterministas verifican.* Todo check que un script pueda hacer, lo hace un script; los modelos solo ponen juicio donde hay juicio. Y las leyes no son prosa: tienen hook o gate.
>
> **Corolario de velocidad:** como la seguridad vive en los gates, el canary y el rollback — no en el número de fases LLM — el pipeline recorta deliberación sin recortar verificación: carriles por blast radius, gates en paralelo, reviewer ∥ qa, prefetch determinista y arranques en caliente.

---

## Índice

1. [Quickstart](#quickstart)
2. [Cómo funciona el instalador](#cómo-funciona-el-instalador)
3. [Qué genera: anatomía de una instancia](#qué-genera-anatomía-de-una-instancia)
4. [El diagrama maestro: qué pasa cuando corres `/auto`](#el-diagrama-maestro-qué-pasa-cuando-corres-auto)
5. [Cómo leer el diagrama](#cómo-leer-el-diagrama)
6. [El panel: `make ui`](#el-panel-make-ui)
7. [Componentes, explicados uno por uno](#componentes-explicados-uno-por-uno)
8. [Self-healing: los cronjobs](#self-healing-los-cronjobs)
9. [Secretos](#secretos)
10. [Qué tan flexible es](#qué-tan-flexible-es)
11. [Actualizaciones](#actualizaciones)
12. [Estructura de este repo](#estructura-de-este-repo)
13. [Tests](#tests)

---

## Quickstart

**Camino A — el wizard web (recomendado):**

```bash
brew install andresgarcia29/agm/harness
harness init          # abre el wizard en http://127.0.0.1:7180/#/init
```

El wizard te lleva de cero a harness: carpeta → GitHub (gh o PAT) → clonar
repos → requisitos → auto-discover → entrevista pre-llenada con evidencia →
agentes + arqueología → MCPs con secretos certificados → primeras tareas →
doctor en verde. Todo idempotente y reanudable: si algo muere, `harness init`
retoma en el paso exacto. Scriptable sin UI: `harness discover` +
`harness generate --answers answers.json`.

**Camino B — el plugin de Claude Code (la entrevista conversacional):**

```bash
# 1. Prepara el workspace: tus repos clonados bajo repos/
mkdir mi-workspace && cd mi-workspace
mkdir repos && git clone <tus-repos> repos/

# 2. Instala el plugin (dentro de una sesión de Claude Code)
/plugin marketplace add andresgarcia29/harness-creator
/plugin install harness-creator@harness

# 3. Instala el harness (entrevista guiada, ~10 min)
/harness-init .

# 4. Onboarding de una pasada (deps, credenciales, secretos, salud)
make init
```

Después de eso, el día a día es **una sola línea**:

```
/auto COR-123                                  # un ticket de Linear
/auto "agrega rate limiting por tenant al gateway, 100 req/min"   # o un prompt literal
/auto COR-123 --model deep                     # misma tarea, modelo elegido por ti
```

`/auto` corre el pipeline entero — intake, carril, [RFC], implementación, review, ship, deploy, archive — **sin preguntarte nada** y dimensionado al blast radius: un cambio de 1 repo sin contratos va por el carril express (salta el RFC; `gate_lane` verifica que el diff cumpla la promesa). Si prefieres conducir fase por fase, los comandos sueltos siguen ahí: `/feature` → `/rfc` → `/implement` → `/review` → `/ship` → `/archive`.

**Requisitos**: macOS o Linux, `git`, `jq` (`brew install jq`), Claude Code. Todo lo demás lo instala el bootstrap.

---

## Cómo funciona el instalador

Cinco fases. Las deterministas son scripts (cero tokens); el modelo solo interviene donde hay decisiones.

```mermaid
flowchart LR
    A["1 · Discovery<br/><i>script, 0 tokens</i><br/>lenguajes, señales,<br/>ROL por repo,<br/>fuente de secretos"] --> B["2 · Entrevista<br/><i>modelo + humano</i><br/>clustering de agentes,<br/>capacidades, tiers,<br/>modelos, secretos"]
    B --> C["3 · Generación<br/><i>templates</i><br/>~45 archivos:<br/>agentes, gates, hooks,<br/>docs, scripts"]
    C --> D["3.5 · Arqueología<br/><i>subagentes paralelos</i><br/>llena abogados y specs<br/>con TU código real"]
    D --> E["4 · Bootstrap + Doctor<br/><i>script</i><br/>instala deps, pide token,<br/>materializa secretos,<br/>verifica TODO"]
```

- **Discovery** (`scripts/discover.sh`): escanea `repos/` y produce `inventory.json` — por repo: lenguajes, señales (buf, helm, argocd, kargo, docker…) y un **rol inferido** (service · frontend · mobile · library · contracts · infra-module · infra-live · ci-library · docs). También detecta tu **fuente de secretos** (`.sops.yaml`, `doppler.yaml`, `op://`, terraform con secret managers, `VAULT_ADDR`…).
- **Entrevista**: el instalador **recomienda con evidencia** ("detecté buf.yaml en `proto` → gate buf-breaking") y tú decides. Nunca pregunta lo que el inventario ya responde.
- **Generación**: instancia ~45 archivos desde templates. Idempotente: si algo existe, diff y pregunta.
- **Arqueología ligera**: un subagente por servicio lee lo denso y barato (README, migraciones, protos) y llena las constituciones de los abogados y las specs con **ownership, invariantes y requirements reales, citando evidencia**. Todo queda `DRAFT`: la arqueología propone, el humano ratifica.
- **Bootstrap + Doctor**: `make init` instala lo que falte, pide credenciales (interactivo — los valores jamás pasan por el agente), materializa secretos y termina en un reporte de salud donde **cada fallo trae su remediación exacta**.

**El instalador es idempotente**: `/harness-init .` sobre un workspace ya instalado entra en *modo update* — no re-pregunta nada, migra esquemas, y todo cambio se presenta como diff.

### La decisión clave: clustering dinámico de agentes

El instalador **no** crea un agente por repo. Crea *abogados* por dominio de ownership:

| Rol detectado | Regla |
|---|---|
| `service` (posee datos) | 1 abogado por servicio |
| `contracts` (proto) | sin abogado — es el árbitro; lo custodian el arquitecto + buf |
| `infra-module`, `infra-live`, `ci-library`, helm | **UN** solo abogado `infra` para todos |
| `frontend`, `mobile` | **UN** abogado `frontends` (no poseen datos; defienden contratos de consumo y UX) |
| `library` | sin abogado — la defienden sus consumidores |

Techo ~12 agentes; si hay más servicios, propone agrupar por dominio de negocio. **20 terraform modules = 1 agente, no 20.** Más agentes no es mejor harness: cada agente es contexto y mantenimiento.

---

## Qué genera: anatomía de una instancia

```
mi-workspace/
├── README.md                 ← onboarding para HUMANOS (make init, de dónde sale el token)
├── CLAUDE.md                 ← mapa para Claude Code (≤110 líneas; las leyes, dónde está la verdad)
├── AGENTS.md                 ← el MISMO mapa en el estándar multi-herramienta (Cursor, Kimi, Codex…)
├── manifest.yaml             ← lista canónica de repos + DAG de dependencias
├── models.yaml               ← LA perilla de modelos: provider + aliases fast|smart|deep + rol→alias + overrides
├── harness-answers.yaml      ← TODAS tus decisiones de la entrevista (insumo de updates)
├── Makefile                  ← interfaz humana: init, doctor, secrets, wt, ship, watch
├── .mcp.json                 ← MCPs elegidos (los autenticados, envueltos en with-secrets)
├── .claude/
│   ├── agents/               ← architect, reviewer, implementer, qa + abogados por cluster
│   ├── commands/             ← /auto (todo el pipeline, sin intervención)
│   │                           /feature /rfc /implement /review /ship /promote /archive
│   ├── hooks/                ← block-direct-push, guard-canonical (leyes con dientes)
│   │                           track-read, ui-emit (observadores, fail-open)
│   ├── skills/               ← skill-creator (la guía) + las skills que el
│   │                           skill-miner mina de tus procedimientos repetidos
│   └── settings.json         ← hooks registrados + denials (kubectl apply, terraform apply…)
├── docs/
│   ├── constitution.md       ← principios innegociables, inyectados a TODOS los agentes
│   ├── architecture/map.md   ← ownership de datos por servicio (la Ley 3)
│   ├── harness/              ← pipeline.md, intake.md, testing-policy.md, cronjobs.md
│   ├── adr/                  ← decisiones; nada es oficial fuera de aquí
│   └── changelog/            ← digest diario generado
├── specs/<capability>/       ← specs maestras EARS+Gherkin, una por dominio
├── scripts/
│   ├── bootstrap.sh          ← onboarding: deps + token + secretos + doctor
│   ├── doctor.sh             ← salud total, cada fallo con remediación
│   ├── ship.sh               ← LA única puerta a main (gates)
│   ├── worktree-task.sh      ← una tarea = un worktree por repo
│   ├── secrets.sh            ← materializa secretos desde tu fuente
│   ├── with-secrets.sh       ← único punto de inyección de secretos
│   ├── quiet.sh              ← trunca outputs ruidosos (economía de tokens)
│   ├── deploy-watch.sh       ← vigila Actions→Kargo→ArgoCD→smoke; rollback seguro
│   ├── ticket-pull/close.sh  ← puente Linear (GraphQL, cero tokens)
│   ├── ui/                   ← panel local de solo lectura (make ui)
│   └── cronjobs/             ← cron-runner + jobs de self-healing elegidos
├── semgrep/rules.yaml        ← sensores custom CON remediación en el mensaje
├── repos/                    ← tus clones (regenerables, protegidos por hook)
├── .harness/events.jsonl     ← bus de eventos del harness (lo lee el panel)
├── worktrees/<task>/<repo>   ← donde se trabaja de verdad
└── tasks/<id>/               ← estado por tarea: task.md, assumptions.md (ledger),
                                 state.json (fase + carril — lo mueve harness-policy.py),
                                 plan.md, veredictos, qa-<repo>.json, logs
```

---

## El diagrama maestro: qué pasa cuando corres `/auto`

Primero la **espina dorsal**: las tres entradas, dónde despierta cada agente, qué lo bloquea, y el hecho central — **todas las salidas hacia un humano están enumeradas en `/auto`, y están en un solo nodo rojo**. Cada bloque tiene su zoom en la sección siguiente. Los colores importan; la leyenda está debajo.

```mermaid
flowchart TD

E1["🎫 <b>COR-123</b><br/>ticket de Linear"]:::human
E2["💬 <b>'agrega rate limiting por<br/>tenant al gateway, 100 req/min'</b><br/>prompt literal"]:::human
E3["♻️ <b>AUTO-20260716-rate-limit</b><br/>task-id de una corrida muerta"]:::human

E1 --> P0
E2 --> P0
E3 --> P0

P0{"<b>① /auto · paso 0</b><br/>¿ticket, prompt o retomar?"}:::dec

P0 -->|"COR-N o URL"| TP(["<b>ticket-pull.sh</b> · GraphQL · $0<br/>materializa task.md · label → in-harness"]):::script
P0 -->|"texto libre"| PR["<b>redacta el intake</b> · id AUTO-fecha-slug<br/>criterios binarios · scope mínimo · repos vía grafo"]:::agent
P0 -->|"task-id ya existente"| RE(["<b>RETOMA</b> · entra por la 1ª fase<br/>sin artefacto válido · nada se re-genera"]):::script

TP --> TASK
PR --> TASK
TASK["<b>tasks/&lt;id&gt;/task.md</b>"]:::art --> INT

INT{"<b>② INTAKE</b> · ¿cumple el contrato?<br/>sin humano, la ambigüedad NO se rebota"}:::dec
INT -->|"6 leyes rotas"| PARA(["<b>⛔ LAS 10 PARADAS</b><br/>ADR contradicho · decisión irreversible<br/>abogado DRAFT · bug irreproducible<br/>RFC sin converger · loop agotado<br/>gate rojo x2 · subagente muerto x2<br/>deploy 🔴 · ticket inexistente"]):::stop
INT -->|"resuelto con evidencia"| LED["<b>assumptions.md</b> · el ledger<br/>SUPUESTO · PORQUE ⟨evidencia⟩ · SI ES FALSO ⟨costo⟩<br/>spec &gt; ADR &gt; CLAUDE.md &gt; código · empate → lo REVERSIBLE"]:::art

LED --> LANE{"<b>②b CARRIL</b> por blast radius<br/>señales deterministas del inventario/grafo<br/>en duda: el carril MAYOR"}:::dec
LANE -->|"<b>express</b> · 1 repo · 1 dominio · sin contratos<br/>mini-plan del orquestador · SALTA el RFC"| IMP
LANE -->|"standard · architect sin abogados<br/>full · pipeline completo"| RFC["<b>③ RFC</b> · abogados SOLO de dominios cruzados, en PARALELO<br/>una respuesta JSON c/u · no implementan nunca<br/><b>architect</b> = hilo fino en <b>ultrathink</b>: descompone en probes,<br/>workers responden en paralelo, él sintetiza → plan.md · DAG · delta-spec<br/><b>plan-lint.sh</b> verde o no hay implement · <i>prefetch en background ($0)</i>"]:::agent
RFC -.-> PARA

RFC --> IMP["<b>④ IMPLEMENT</b> · bd ready manda · arranque en caliente<br/>(worktree+deps+brief ya prefetcheados) · 1 implementer =<br/>1 tarea = 1 worktree = 1 repo · lo paralelo NO se serializa<br/>watchdog por heartbeat (~3 min sin tool calls)<br/><b>ship.sh --precheck</b> antes de entregar: rojo NO llega a review"]:::agent
IMP -.-> PARA

IMP --> REV["<b>⑤ REVIEW</b> · encola al terminar, no al final<br/><b>reviewer ∥ qa</b> EN PARALELO · merge mecánico del campo qa<br/>reviewer: verdict.json + compliance matrix 100% · <b>ronda 1 exhaustiva</b><br/>qa: ejercita los criterios · re-review incremental en rondas ≥2"]:::agent
REV -->|"🔴 fail · el error ES el prompt del fix"| IMP
REV -.-> PARA

REV --> CHK{"<b>autonomy</b> en harness-answers.yaml"}:::dec
CHK -->|"checkpoint · UNA pausa en todo el pipeline"| GO(["resumen de 10 líneas → 'go'"]):::human
CHK -->|"full · ninguna"| SHIP
GO --> SHIP

SHIP(["<b>⑥ ship.sh</b> · LA única puerta a main · $0<br/>serie: rebase → trailer → carril (gate_lane)<br/>EN PARALELO: build/test ∥ buf ∥ gitleaks ∥ semgrep<br/>∥ tests-no-debilitados ∥ veredicto+evidencia · luego lock → push"]):::script
HOOK{{"<b>🚫 hooks + denials</b> · fail-closed<br/>block-direct-push · guard-canonical<br/>kubectl/terraform apply · push --force"}}:::hook
HOOK -.->|"bloquean a TODO agente"| IMP
HOOK -.->|"dejan pasar SOLO a"| SHIP
SHIP -->|"🔴 gate · máx 2 autofixes"| IMP
SHIP -.-> PARA

SHIP --> DW(["<b>⑦ deploy-watch.sh</b> · $0, solo CPU<br/>Actions → Kargo → ArgoCD health → smoke canary"]):::script
DW -->|"🔴"| RB(["<b>ROLLBACK PRIMERO</b> · abort-to-stable o revert<br/>diagnóstico DESPUÉS · nunca argocd app rollback"]):::script
RB --> PARA
DW -->|"🟢 · quedan tareas en el DAG"| SHIP

DW -->|"🟢 · DAG completo"| ARCH["<b>⑧ /archive</b> · fusiona el delta-spec en la<br/>spec maestra ← por esto no hay spec-rot<br/>ticket-close.sh · mem_save"]:::agent

ARCH --> REP(["<b>REPORTE FINAL</b> — lo único que lees<br/>qué se shippeó · <b>el ledger completo</b><br/>paradas · costo ccusage"]):::human
REP -.->|"<b>/promote</b> semanal · el loop se cierra:<br/>supuesto falso → regla semgrep · decisión madura → ADR"| SHIP

classDef script fill:#0b3d2e,stroke:#10b981,stroke-width:2px,color:#d1fae5
classDef agent fill:#1e2a5a,stroke:#60a5fa,stroke-width:2px,color:#dbeafe
classDef dec fill:#4a3410,stroke:#f59e0b,stroke-width:2px,color:#fef3c7
classDef hook fill:#2d0f0f,stroke:#dc2626,stroke-width:3px,color:#fecaca
classDef stop fill:#450a0a,stroke:#f87171,stroke-width:3px,color:#fee2e2
classDef human fill:#3b1a4a,stroke:#c084fc,stroke-width:2px,color:#f3e8ff
classDef art fill:#1f2937,stroke:#9ca3af,stroke-width:1px,color:#e5e7eb
```

### Leyenda

| Forma / color | Qué es | Cuesta |
|---|---|---|
| 🟩 **verde, redondeado** | script determinista | **$0** — cero tokens, solo CPU |
| 🟦 **azul, rectángulo** | agente (LLM) | tokens, modelo según `models.yaml` |
| 🟨 **ámbar, rombo** | decisión que el sistema toma **solo** | — |
| 🟥 **rojo, doble borde** | **gate** de `ship.sh` — bloquea el push | $0 |
| 🟥 **rojo oscuro, hexágono** | **hook / denial** — bloquea al agente antes de actuar | $0 |
| 🔴 **⛔ PARA** | las **10 salidas** a un humano. La lista es cerrada | — |
| 🟪 **morado** | los únicos puntos donde un humano toca el flujo | — |
| ⬜ **gris** | artefacto en disco (el estado real) | — |

---

## Cómo leer el diagrama

Nueve bloques (los ocho del pipeline + el carril que decide cuánta ceremonia merece cada tarea). Lo que sigue explica **por qué** cada uno es como es — el diagrama dice qué pasa, esto dice por qué.

### ① Entrada — tres formas de empezar, ninguna te hace trabajar

Un ticket de Linear, un prompt literal entre comillas, o el `task-id` de una corrida que se murió. `/auto` decide cuál es sin preguntarte. El tercer caso es el que más vas a agradecer: como **todo el estado vive en `tasks/<id>/` y en los commits del worktree — nunca en la conversación de un agente** — una sesión muerta a mitad del pipeline se retoma con `/auto <task-id>`, y entra por la primera fase cuyo artefacto falte. Un artefacto válido jamás se re-genera.

### ② Intake — la pieza nueva, y la que hace posible el resto

Aquí está el cambio conceptual. Con un ticket, el intake clásico **rebota** lo ambiguo: cuesta centavos rebotar y cuesta el pipeline entero implementar una ambigüedad. Pero cuando la entrada es tu prompt y tú ya te fuiste, **no hay a quién rebotarle**. La ambigüedad no desaparece por eso — así que en vez de rebotarse, se **resuelve, se declara y se hace barata de revertir**:

- **Se resuelve con evidencia, no con opinión.** Hay una precedencia estricta: *spec maestra > ADR vigente > el CLAUDE.md del repo > el patrón del código*. Un supuesto que no se apoya en ninguna de las cuatro no es un supuesto, es una invención — y las invenciones no se implementan.
- **Ante empate, gana lo reversible.** Entre dos lecturas de tu prompt, la que sea más fácil de deshacer, aunque haga menos. Esto es lo que vuelve segura la autonomía: no que el agente acierte siempre, sino que equivocarse sea barato.
- **Se declara en `tasks/<id>/assumptions.md`.** Cada línea dice qué asumió, con qué evidencia, y qué cuesta deshacerlo si era falso. El ledger es lo primero del reporte final: en 30 segundos ves todas las decisiones que se tomaron por ti.
- **Alimenta al sistema.** Un supuesto que resultó falso es material de `/promote`: se convierte en regla semgrep o en ADR, y el siguiente `/auto` ya no lo repite. Por eso la flecha punteada del reporte vuelve al gate de semgrep — **el loop se cierra**.

`/auto` también reescribe lo difuso en binario ("que ande rápido" → "p95 < 300ms en `/x`, medido por el smoke") y divide un prompt que mezcla dos features en dos tareas del DAG. Lo que **no** hace es fingir que un bug irreproducible es arreglable, ni tomar una decisión que la constitución reserva a humanos.

**Zoom: los cinco criterios de rebote, y qué hace `/auto` con cada uno.** Con ticket, los cinco rebotan. Con prompt no se relajan: se transforman.

```mermaid
flowchart LR
  V{"criterio de<br/>docs/harness/intake.md"}:::dec
  V -->|"1 · criterio no verificable<br/>'que ande rápido'"| A1["lo reescribe binario<br/>+ el umbral elegido al ledger"]:::agent
  V -->|"5 · mezcla 2 features"| A2["las divide en<br/>tareas del DAG"]:::agent
  V -->|"2 · bug sin repro"| D2{"¿logro<br/>reproducirlo?"}:::dec
  D2 -->|"sí"| A3["escribe el repro"]:::agent
  D2 -->|"no"| S1(["⛔ PARA<br/>no hay bug demostrable<br/>que arreglar"]):::stop
  V -->|"3 · decisión de arquitectura"| D3{"¿reversible <b>Y</b> dentro de<br/>un ownership existente?"}:::dec
  D3 -->|"sí"| A4["decide lo mínimo<br/>y lo anota"]:::agent
  D3 -->|"no: servicio nuevo · dep externa<br/>· breaking · mueve ownership"| A5["escribe ADR-N<br/>status: PROPOSED<br/>+ su recomendación"]:::agent
  A5 --> S2(["⛔ PARA<br/>la ley la ratifican humanos"]):::stop
  V -->|"4 · contradice un ADR vigente"| S3(["⛔ PARA · lo cita<br/>no lo re-litiga"]):::stop
  A1 --> L
  A2 --> L
  A3 --> L
  A4 --> L
  L["<b>assumptions.md</b><br/>una línea por decisión tomada por ti"]:::art
  L --> DR{"¿abogado afectado<br/>en status: DRAFT?"}:::dec
  DR -->|"sí"| S4(["⛔ PARA · pide ratificación"]):::stop
  DR -->|"no"| R(["→ ③ RFC"]):::script

classDef agent fill:#1e2a5a,stroke:#60a5fa,stroke-width:2px,color:#dbeafe
classDef dec fill:#4a3410,stroke:#f59e0b,stroke-width:2px,color:#fef3c7
classDef stop fill:#450a0a,stroke:#f87171,stroke-width:2px,color:#fee2e2
classDef art fill:#1f2937,stroke:#9ca3af,stroke-width:1px,color:#e5e7eb
classDef script fill:#0b3d2e,stroke:#10b981,stroke-width:2px,color:#d1fae5
```

### ②b Carriles — el pipeline se dimensiona al blast radius

La seguridad de este harness vive en los gates deterministas, el canary y el rollback — **no en el número de fases LLM**. De ahí el cambio estructural de velocidad: un typo-fix no paga el mismo peaje que una migración multi-servicio.

| Carril | Señales (deterministas: inventario + grafo + manifest) | Qué salta |
|---|---|---|
| **express** | 1 repo · 1 dominio · sin contratos/migraciones/infra | el RFC entero: el orquestador escribe mini-plan + delta-spec mínimo → implementer → reviewer. **2 sesiones LLM** |
| **standard** | 2-3 repos · dominios no cruzados · sin breaking | los abogados (no hay frontera que defender) |
| **full** | cruza ownership · breaking · servicio nuevo · migración | nada |

Tres redes lo hacen seguro. En duda entre dos carriles, gana el mayor. La clasificación es una *propuesta* que `ship.sh` verifica: **`gate_lane`** compara el diff real contra el carril declarado en `state.json` — un express que tocó un `.proto` o una migración no pasa. Y escalar es barato y pre-aprobado: `harness-policy.py escalate` sube el carril y re-encauza por `/rfc` conservando el worktree. **Equivocarse de carril cuesta una re-entrada, jamás un ship sin la deliberación que tocaba.** Los gates, la compliance matrix, la evidencia, el canary y el rollback son idénticos en los tres carriles: el carril recorta deliberación, nunca verificación.

### ③ RFC — por qué existen los abogados (y cuándo NO)

Un solo agente implementando una feature cruza fronteras de datos sin que nadie objete: no tiene con quién discutir. Los **abogados** (`svc-*`, `infra`, `frontends`) son un tech lead por dominio de ownership que **defiende invariantes en el RFC y nunca implementa**. Responden **una vez, en paralelo, en JSON** — no es una conversación, es un alegato.

La contraparte exacta: el abogado existe para defender fronteras, así que **si la tarea no cruza ninguna, no se convoca a ninguno** (carril standard). Un abogado leyendo 10 minutos de contexto para responder "sin objeción" sobre un dominio que nadie tocó es puro costo — en tokens y en camino crítico. Mientras el architect redacta, el orquestador ya corre el **prefetch** en background ($0): worktrees, briefs por repo y warmup de dependencias, para que los implementers arranquen con la mesa puesta.

Cuando chocan, el desempate **no es consenso ni la opinión del arquitecto**: es evidencia. Contratos → el repo proto es el árbitro. Datos → `docs/architecture/map.md`. Máximo 2 rondas; si no convergen, las posiciones van en limpio a un humano — porque un desacuerdo real entre dos dominios *es* una decisión de negocio, y esas no las toma un modelo.

**El arquitecto es un hilo fino que piensa hondo.** Son dos decisiones opuestas y deliberadas. Piensa hondo: todo artefacto de planeación (el plan, la síntesis del RFC, el mini-plan del carril express, los ADRs) se escribe en modo **ultrathink**, porque es lo único que van a ejecutar N implementers sin poder preguntarle nada; el loop de edición, en cambio, no lo usa nunca (ahí el valor está en el diff y pensar de más es latencia comprada). Y lee poco: en vez de abrirse 20 archivos hasta llenar su ventana, **descompone la incertidumbre en sub-preguntas con scope** (`probes.json`), unos workers baratos las responden EN PARALELO citando `archivo:línea`, y él sintetiza sobre ese pack. Si le falta un hecho, emite otra probe; no abre el archivo. Máximo dos rondas, y lo que siga faltando después de la segunda no es un hueco de contexto: es una decisión que le toca a un humano.

Antes de que salga un solo implementer, el plan pasa por **`plan-lint.sh`** (determinista, $0): cada tarea declara repo, requirement IDs, archivos, criterios binarios, complexity y deps; cero "TBD", "por definir" o "investigar si"; y cada `req` citado existe de verdad en el delta-spec. La razón es de velocidad, no de burocracia: **lo que el plan no decide lo decide un implementer solo y a ciegas, y vuelve como blocking una hora después**. Es la única revisión del plan que no cuesta una ronda.

La parada por **abogado en `DRAFT`** parece burocracia y es lo contrario: la constitución de un abogado la propuso la arqueología leyendo tu código, pero hasta que un humano la ratifica **nadie la firmó**. Litigar citando una ley sin firmar es teatro. Por eso `/auto` para ahí — y es la primera cosa que vas a ratificar después de instalar.

### ④ Implement — paralelo por defecto, contexto mínimo por diseño

Un implementer = una tarea = un worktree = un repo. Sesiones cortas y desechables que **nunca llegan a compactación de contexto**, y aislamiento que hace imposible el scope creep. `bd ready --json` (beads) dice qué tareas no tienen dependencias entre sí, y **todas esas arrancan a la vez**: serializar lo paralelizable es la forma más cara de perder tiempo.

El arranque es **en caliente**: el prefetch ya dejó el worktree, las deps y el brief (`repo-brief.sh` destila estructura, comandos de test y convenciones a `.cache/briefs/<repo>.md`, cacheado por HEAD, $0 tokens). El implementer recibe su entrada del plan + criterios + brief y **no explora el repo desde cero** — sus primeros minutos son de edición, no de arqueología; Serena cubre el nivel símbolo.

El **watchdog** es la lección de una crisis real, ahora por **heartbeat**: un agente sano llama herramientas constantemente, así que ~3 minutos sin una sola tool call = atascado — se interrumpe y se relanza **ya con el modelo de escalación** (repetir el mismo experimento con el mismo modelo es repetir el mismo atasco). Límite duro de 10 min como respaldo. Es seguro *precisamente* porque su conversación no era el estado — el estado son los commits. Dos muertes del mismo rol en la misma tarea sí escalan a un humano.

**Zoom: el fan-out real, y por qué el review no espera.**

```mermaid
flowchart LR
  WT(["worktree-task.sh<br/>un worktree por repo · $0"]):::script --> BD(["<b>bd ready --json</b><br/>¿qué tareas no tienen deps?"]):::script
  BD --> T1["implementer <b>T1</b> · proto<br/>Serena: edición por símbolo"]:::agent
  BD --> T2["implementer <b>T2</b> · atlas"]:::agent
  BD --> T3["implementer <b>T3</b> · hermes"]:::agent
  T1 --> R1["reviewer + qa · T1"]:::agent
  T2 --> R2["reviewer + qa · T2"]:::agent
  T3 --> R3["reviewer + qa · T3"]:::agent
  R1 --> S1(["ship T1"]):::script
  R2 -->|"🔴 fail"| T2
  R3 --> S3(["ship T3"]):::script
  T1 -.-> W{"watchdog heartbeat:<br/>¿tool calls en los últimos 3 min?"}:::dec
  W -->|"no · 1ª vez"| RL["relanza YA ESCALADO de modelo — el estado vive<br/>en tasks/&lt;id&gt;/ y en los commits, NO en su conversación"]:::agent
  RL -.-> T1
  W -->|"no · 2ª muerte del mismo rol"| ST(["⛔ PARA<br/>último estado al humano"]):::stop

classDef agent fill:#1e2a5a,stroke:#60a5fa,stroke-width:2px,color:#dbeafe
classDef dec fill:#4a3410,stroke:#f59e0b,stroke-width:2px,color:#fef3c7
classDef stop fill:#450a0a,stroke:#f87171,stroke-width:2px,color:#fee2e2
classDef script fill:#0b3d2e,stroke:#10b981,stroke-width:2px,color:#d1fae5
```

T1 ya se está shippeando mientras T2 vuelve a implementación por un review rojo. Nadie espera a nadie: **el DAG es la única autoridad sobre el orden**.

Y antes de entregar, cada implementer corre **`ship.sh --precheck <task> <repo>`**: los mismos gates mecánicos del ship (build, tests, lint, gitleaks, tests-no-debilitados) sobre su worktree, sin veredicto y sin push. La aritmética es toda la razón: un test roto detectado por un script cuesta segundos y cero tokens; el mismo test roto detectado por un reviewer cuesta una ronda completa de 10 a 20 minutos. Por eso un precheck rojo **no consume presupuesto de loop** (el reviewer no vio nada) y `/review` simplemente no lanza a nadie hasta que el sello `precheck-<repo>.json` esté verde sobre el HEAD actual.

### ⑤ Review — contra el "listo" autodeclarado

El modo de fallo #1 de los agentes es declararse terminados. Contra eso, dos capas que no se pisan: el **reviewer** emite el JSON que `ship.sh` exige, con una **compliance matrix** — cada requirement del delta-spec apareado con el test que lo prueba. "El review aprobó" es difuso; "requirements cubiertos: 100%" lo verifica una máquina. Y **qa** no lee código: ejercita tus criterios de aceptación como un usuario, con Playwright si hay frontend, local y en el canary.

Las dos capas corren **en paralelo** — qa ejercita comportamiento y no necesita el veredicto; serializarlas regalaba la fase entera al camino crítico. Cada una escribe su archivo (`verdict-<repo>.json`, `qa-<repo>.json`) y el merge del campo `qa` es mecánico (jq, mismo commit obligatorio). Y el loop fail→fix es **incremental**: el reviewer re-evalúa el diff desde su veredicto anterior más el cierre de cada blocking — no el cambio completo otra vez — aunque el veredicto nuevo siempre ata al HEAD completo.

**La ronda 1 es exhaustiva, y ese es el contrato anti-goteo.** El costo real de un review no es la pasada del reviewer: son las rondas que provoca. Un blocking que aparece en la ronda 3 y ya estaba a la vista en la ronda 1 le costó al proyecto dos ciclos completos de implementer. Por eso el reviewer revisa el diff entero antes de escribir su primer blocking y entrega la lista COMPLETA de una vez; en rondas siguientes solo puede abrir hallazgos nuevos por código que el fix tocó, por regresión, o por algo que el fix hizo observable. Lo que no impide shippear va a `non_blocking` y de ahí a un bead de seguimiento, **nunca a otra ronda**. Y si algo llega tarde igual se reporta (ocultar un defecto real sería peor), pero marcado `[tardío]`: esa cuenta sale en el reporte final junto con `review_rounds`, porque es la métrica que dice si el plan estuvo bien hecho.

Cada tarea encola su review **al terminar**, no al final de todas: T1 puede estar en review mientras T4 se implementa. Es un pipeline, no una barrera.

### ⑥ Ship — las leyes con dientes

`ship.sh` es la **única** puerta a main. En serie corre solo lo que tiene orden real (rebase → trailer → carril); **todo gate independiente corre en paralelo** — build/test, buf, gitleaks, semgrep, tests-no-debilitados, veredicto+evidencia — y los rojos se reportan **juntos**: el implementer recibe un solo prompt de fix con todos los errores, en vez de descubrirlos gate por gate en rondas sucesivas. Lo importante sigue siendo que **el mensaje de error de cada gate es el prompt del fix** — trae su remediación exacta, para que el agente corrija en una iteración. Presupuesto: 2 rondas de autofix; la tercera es tuya, con el error completo y sin resumir.

```mermaid
flowchart TD
  A["cualquier agente<br/>implementer · reviewer · qa · /auto"]:::agent -->|"git push origin main"| H1{{"🚫 <b>block-direct-push</b><br/>hook PreToolUse · <b>fail-closed</b><br/>sin jq → bloquea por precaución"}}:::hook
  A -->|"edita repos/atlas"| H2{{"🚫 <b>guard-canonical</b><br/>el clon base es intocable"}}:::hook
  A -->|"kubectl apply · terraform apply<br/>argocd app rollback · push --force"| H3{{"🚫 <b>denials</b> de settings.json"}}:::hook
  H1 --> X(["⛔ la llamada NUNCA ocurre"]):::stop
  H2 --> X
  H3 --> X

  SH(["<b>ship.sh</b>"]):::script --> G1[["1 · rebase sobre origin/main"]]:::gate
  G1 --> G2[["2 · trailer Task: &lt;id&gt; en TODO commit"]]:::gate
  G2 --> GL[["3 · carril · gate_lane verifica que el diff<br/>respete lo que el intake declaró"]]:::gate
  GL --> G3[["build + test + buf breaking<br/>autodetectado por lenguaje"]]:::gate
  GL --> G5[["gitleaks + semgrep<br/>sensores con remediación"]]:::gate
  GL --> GT[["tests no debilitados"]]:::gate
  GL --> G7[["veredicto + compliance 100%<br/>+ evidencia + policy v1"]]:::gate
  G3 --> J(("∥")):::script
  G5 --> J
  GT --> J
  G7 --> J
  J -->|"TODOS verdes — los rojos se reportan JUNTOS,<br/>un solo prompt de fix con todo"| G8[["lock por repo · un ship a la vez"]]:::gate
  G8 --> P(["git push origin main"]):::script
  H1 -.->|"<b>deja pasar SOLO a</b>"| P
  J -.->|"🔴 el mensaje de CADA gate rojo ES el prompt del fix"| F{"¿3er intento?"}:::dec
  F -->|"no · máx 2 autofixes"| A
  F -->|"sí"| ST(["⛔ PARA · error completo, sin resumir"]):::stop

classDef agent fill:#1e2a5a,stroke:#60a5fa,stroke-width:2px,color:#dbeafe
classDef dec fill:#4a3410,stroke:#f59e0b,stroke-width:2px,color:#fef3c7
classDef gate fill:#3f1d1d,stroke:#ef4444,stroke-width:3px,color:#fee2e2
classDef hook fill:#2d0f0f,stroke:#dc2626,stroke-width:3px,color:#fecaca
classDef stop fill:#450a0a,stroke:#f87171,stroke-width:2px,color:#fee2e2
classDef script fill:#0b3d2e,stroke:#10b981,stroke-width:2px,color:#d1fae5
```

Los **hooks** son la diferencia entre una regla y una ley. "No pushees a main" en un CLAUDE.md es una sugerencia que un agente puede racionalizar a las 3am. `block-direct-push` es un hook PreToolUse que intercepta la llamada **antes de que ocurra**, y es *fail-closed*: si falta `jq`, bloquea por precaución. Mismo caso con `guard-canonical` (el clon de `repos/` es intocable; se trabaja en worktrees) y con los denials de `settings.json`.

Fíjate en la asimetría del diagrama, porque es **todo** el diseño: el mismo hook que bloquea a *cualquier* agente es el que **deja pasar a `ship.sh`**. No hay dos caminos a main con distinta severidad — hay uno solo, y está pavimentado de gates.

### ⑦ Deploy — rollback primero, diagnóstico después

`deploy-watch.sh` sigue la cadena Actions → Kargo → ArgoCD health → smoke del canary, y es un script: **el camino verde no gasta un solo token**. En rojo, el orden no se negocia: **rollback primero** (Argo Rollouts abort-to-stable o revert en git — nunca `argocd app rollback`, que es un cañón), y el diagnóstico después, con producción ya sana. Un agente diagnosticando con el incendio encendido es el peor lugar posible para gastar 20 minutos.

### ⑧ Archive — la pieza que evita el spec-rot

Cuando el canary queda verde, `/archive` **fusiona el delta-spec en la spec maestra automáticamente**. Esta es la razón por la que el SDD de este harness no muere: si esa fusión dependiera de disciplina humana, en un trimestre las specs mentirían — y una spec podrida es peor que ninguna, porque los agentes la ejecutan con confianza.

### Las 10 paradas — la lista es cerrada, y ese es el punto

`/auto` sólo para en la lista cerrada que vive en su comando, y **cada caso es una ley del harness, no una preferencia**. Esa plantilla es la fuente de verdad: añadir o retirar una parada exige cambiar el contrato y sus pruebas, no corregir un número repetido en prosa.

La regla que lo hace funcionar es negativa: **si la razón para parar no está en esa lista, no es una razón — decide.** Preguntarte es un fallo de diseño, no prudencia. La red que sostiene esto no eres tú: son los gates deterministas, el canary y el rollback. Y `autonomy: checkpoint` en `harness-answers.yaml` te da **una** pausa —un resumen de 10 líneas antes del primer ship a main— para las primeras semanas, mientras le agarras confianza. Gradúa *cuándo se toca main*, no *cuánto piensa el agente*.

---

## El panel: `make ui`

`/auto` corre solo — pero "solo" no debería significar "a ciegas". `make ui` abre el panel local (por defecto `127.0.0.1:7180`) que te deja ver, mientras el harness trabaja: **qué agentes están vivos ahora mismo** y en paralelo, en qué fase va cada tarea, el texto que van produciendo, tokens y costo por agente, el grafo de quién lanzó a quién, y **el ledger de supuestos** de cada tarea.

```
make ui          # o: make ui PORT=8080
```

Dos zonas en la barra lateral, y la distinción es la arquitectura entera:

- **OBSERVAR** — Resumen (qué te espera, la curva de concurrencia, las últimas decisiones), Tareas (pipeline + ledger de supuestos + la historia paso a paso que escriben `ship.sh` y `/auto`), Sesiones (cada terminal con su gantt de agentes, árbol de spawns y el texto por turno), Gastos (día × modelo, por sesión, tabla de precios).
- **OPERAR** — Nueva tarea (un formulario que escribe `tasks/<id>/task.md` y lanza `claude -p "/auto <id>"` headless con `--session-id` conocido: la tarea aparece sola en Sesiones), responder a un agente que te espera (reanuda SU sesión con `claude --resume`), Conexiones (Linear/OpenRouter: el token se **valida contra el proveedor antes de guardarse**, va a `~/.config/harness/` con chmod 600, y jamás se muestra ni pasa por un agente), y sincronizar precios reales desde OpenRouter para los modelos observados sin precio.

### De dónde sale el panel: tres repos (ADR-0003)

El panel NO vive en este repo. Es un stack de tres repositorios con una
dependencia estrictamente unidireccional — el mismo DAG `infra → service →
frontend` que el harness le impone a la plataforma del usuario:

| Repo | Rol |
|---|---|
| **harness-creator** (este) | Genera la *policy* (agentes, pipeline, gates, hooks, docs) y su salida en disco. NO contiene el panel. |
| **harness-daemon** | Observador **por-máquina**. Sirve el panel en `127.0.0.1` y es **dueño del contrato de API**. |
| **harness-ui** | Cliente **fleet** (Vite/React). Se conecta a N daemons por SSH/herdr; consume el contrato por codegen. |

**La ley de la dependencia:** el daemon *no contiene las reglas del harness* — las
**lee como datos**. Su entrada es el **contrato de estado en disco** que este
repo produce en cada workspace: `tasks/<id>/` (task.md, plan, veredictos,
supuestos), `.beads/` (issues), `.harness/runs.jsonl` (procedencia sesión→tarea)
y los transcripts de los agentes. El daemon observa ese estado y lo reporta; la
UI lo muestra. Cambiar la *forma* de ese estado en disco es un cambio de contrato
que impacta al daemon — no un detalle interno de harness-creator.

**Auth:** ninguna a nivel app. El multi-máquina va por túneles SSH (herdr), así
que las llaves SSH son la auth y cada daemon sigue `127.0.0.1-only`. `make ui`
prefiere el `harness` instalado por brew (el binario del daemon, versionado por
su cuenta) sobre cualquier binario vendorizado — ver `templates/ui/panel.sh`.

**Disponibilidad:** lo que este repo genera funciona **completo y sin red**
con el server vendoreado (`server.py`, stdlib de Python + frontend
precompilado): tareas, agentes vivos, costos, ledger. El daemon Go
([harness-daemon](https://github.com/andresgarcia29/harness-daemon)) y el
cliente fleet ([harness-ui](https://github.com/andresgarcia29/harness-ui)) son
repos aparte, **también open source (MIT)** — aportan el multi-máquina y las
terminales en vivo, `panel.sh` baja el binario de sus releases públicos y cae
automáticamente a `server.py` si no está disponible.

### Las cinco leyes del panel

Un panel en un sistema cuya filosofía es "los agentes proponen, los sistemas deterministas verifican" tiene que ganarse su lugar. Estas son sus reglas, y explican casi todo su diseño:

1. **OPERAR CREA TRABAJO, JAMÁS MERGES** (ADR-0010 del daemon). El panel puede *crear* una tarea y *pasarle contexto* a un agente — exactamente lo que ya podías hacer desde una terminal — pero todo lo que lanza pasa por los mismos gates: a main solo se llega por `ship.sh`. No hay botón de aprobar, ni de mergear, ni de saltarse un gate; el operador tampoco puede editar `ship.sh`, hooks ni `settings.json` desde aquí. Crear trabajo ≠ publicar trabajo.
2. **Solo `127.0.0.1`.** Nunca `0.0.0.0`. Y como ahora hay endpoints que actúan: cada arranque genera un token anti-CSRF que viaja en el HTML y debe volver en el header `X-Corvux-Token` (un `<form>` de otra página no puede poner headers custom), y se verifica el header `Host` contra DNS rebinding. Los tres controles tienen test.
3. **Jamás muestra valores de secretos.** No lee `.secrets`, `connections` expone presencia (`true`/`false`), nunca el valor, y todo texto pasa por redacción (GitHub, Vault, JWT, AWS, Slack, Linear…) antes de salir. La ley de secretos también aplica a los píxeles. *(La suite mete un token de cada familia y verifica que sale `[REDACTADO]` — y ya cachó un bug real: el `\b` de sed no existe en macOS y cuatro familias viajaban sin redactar.)*
4. **Cero dependencias en runtime.** El frontend es React + shadcn/ui (los mismos componentes que Agora) pero viaja **compilado y vendoreado** en `dist/`: el server es stdlib de Python sirviendo estáticos y el usuario jamás corre `npm install`. Node existe solo para construir el panel (repo `harness-ui`; el installer lo trae con `scripts/sync-ui.sh`).
5. **Degrada, no explota.** Lee dos fuentes con dos niveles de confianza: `.harness/events.jsonl` + `tasks/` son **nuestros** (estables); los transcripts de Claude Code son **prestados** (formato interno, cambia entre versiones). Si el parseo falla, el panel sigue vivo con lo que el harness sí controla y te lo dice arriba en rojo.

El formulario de Nueva tarea escribe preferencias que `/auto` **respeta como ley**: `review_before_ship: true` fuerza una pausa antes del primer ship, `assumptions_ok: false` convierte cada ambigüedad en una parada en vez de un supuesto, `max_parallel` acota los implementers y `budget_usd` convierte pasarse de presupuesto en una parada.

### Lo que el panel NO hace, y por qué

**No hay streaming token por token.** Lo medimos: el transcript de un agente vivo se quedó quieto 36 segundos y luego saltó 52 KB de golpe — Claude Code escribe los mensajes al **cerrarlos**. El panel muestra el texto por turno, que es lo más en vivo que existe sin mentir. Poner un typewriter falso encima sería teatro, en la única herramienta cuyo trabajo es observar con honestidad.

**El costo es un estimado.** La báscula oficial sigue siendo `ccusage`; el panel calcula con `scripts/ui/pricing.json` (editable, se relee sola) para que veas la tendencia sin salir. Dos cosas que aprendimos construyéndolo, contra datos reales:

- Una respuesta de la API se escribe en **varios records que repiten el mismo `usage`**. Sumarlos ingenuamente infla la cuenta. Se deduplica por `message.id`. *(Se cita por ahí un 4× de inflado; nosotros medimos 1.01× en transcripts reales — el error existe, la magnitud que circula no.)*
- El desglose `ephemeral_5m` / `ephemeral_1h` gana sobre el campo plano: la caché de 5 min se escribe a 1.25× y la de 1 h a 2×, y el campo plano no los distingue.

**Y un aviso honesto:** el panel lee un formato que Anthropic documenta como **interno y sujeto a cambio entre versiones** (verificado contra Claude Code 2.1.211). Por eso los transcripts son la capa de *enriquecimiento*, nunca la de verdad: si un día cambian, pierdes las tarjetas de agentes y los tokens — no las fases, ni los gates, ni las tareas.

---

## Componentes, explicados uno por uno

### Los agentes (`.claude/agents/`)

| Agente | Qué es | Por qué existe |
|---|---|---|
| **abogados** (`svc-*`, `infra`, `frontends`) | Un "tech lead" por dominio que **defiende ownership e invariantes en los RFCs**. No implementa nunca. Su constitución la llenó la arqueología con datos reales de tu código y tú la ratificaste. **Se convocan SOLO cuando la tarea cruza fronteras de ownership** (carril full) — sin frontera cruzada no hay litigio que valga sus tokens. | Sin abogados, un agente que implementa una feature cruza fronteras de datos sin que nadie objete. Con ellos, cada cambio multi-servicio se *litiga* citando specs, no opiniones. |
| **architect** | Convierte el RFC en un plan ejecutable: tareas por repo con dependencias (beads), orden de shipping, criterios por tarea. | Alguien tiene que sintetizar el debate y trazar el DAG. Modelo caro porque su output lo consumen N agentes aguas abajo. |
| **implementer** | Ejecuta UNA tarea, en UN worktree, de UN repo. Contexto mínimo: el plan y el CLAUDE.md del repo. | Sesiones cortas y desechables = nunca llegar a compactación de contexto. El aislamiento evita scope creep. |
| **reviewer** | Emite el veredicto JSON que ship.sh exige: correctness + **compliance matrix** (cada requirement del delta-spec ↔ el test que lo prueba). | "El review aprobó" es difuso; "requirements cubiertos: 100%" es verificable por máquina. |
| **qa** | Ejercita los criterios de aceptación **como usuario real** (Playwright en frontends), local y en el canary post-deploy. | El modo de fallo #1 de agentes es el "completado" autodeclarado. QA no opina de código: comprueba comportamiento. |

### La capa SDD (Spec-Driven Development)

- **`docs/constitution.md`** — principios innegociables inyectados a *todos* los agentes: no asumas, código mínimo, cambios quirúrgicos (cada línea traza a la solicitud), ejecución verificable. Es el desempate de cualquier RFC.
- **`specs/<capability>/spec.md`** — el comportamiento ACTUAL del sistema en notación EARS (`WHEN <evento> THE SYSTEM SHALL <resultado>`) + escenarios Given/When/Then, cada requirement enlazado a su test. Es lo que los abogados **citan** ("esto viola AUTH-3").
- **Delta-specs** — cada RFC produce sus cambios como secciones ADDED/MODIFIED/REMOVED contra la spec maestra. El delta ES la definición formal del blast radius. *(En el carril express lo redacta el orquestador — 2-6 líneas EARS desde los criterios: express recorta sesiones LLM, jamás artefactos; la compliance matrix y `gate_evidence` operan igual en los tres carriles.)*
- **`/archive`** — cuando el deploy queda verde, fusiona el delta en la spec maestra automáticamente. **Esta pieza es la razón por la que el SDD de este harness no muere de spec-rot**: si la fusión dependiera de disciplina humana, en un trimestre las specs mentirían — y una spec podrida es peor que ninguna, porque los agentes la ejecutan con confianza.

### Economía de tokens (el contexto es el recurso escaso)

| Herramienta | Qué es | Para qué sirve aquí |
|---|---|---|
| **Serena** (MCP) | Servidor que expone **LSP** (Language Server Protocol — el mismo motor de "ir a definición / encontrar referencias" de tu IDE) como herramientas del agente. | El implementer navega y edita **por símbolo** (`find_symbol`, `find_referencing_symbols`) en vez de leer archivos completos o grepear texto. Es el ahorro de tokens más grande en implementación. En multi-repo se activa **por worktree**. |
| **Graphify** (CLI) | Knowledge graph del código cross-repo (Tree-sitter + detección de comunidades). | Preguntas de *comprensión* ("¿quién consume este servicio?", "¿qué camino conecta A con B?") se responden con el grafo (~71× menos tokens, [cifra reportada por Graphify](https://github.com/Graphify-Labs/graphify)) en vez de grep masivo. Lo usan arquitecto y orquestador; los implementers no lo necesitan (Serena cubre el nivel símbolo). **El grafo se mantiene solo**: `graph-refresh.sh` (build inicial, `--update` incremental, stamp por HEADs) corre en el prefetch de /auto, en harness-janitor y en `make graph`; el doctor avisa si graphify está instalado sin grafo construido. |
| **context7** (MCP) | Documentación de librerías bajo demanda, versionada. | El agente no alucina APIs ni repite web-searches de la misma librería. |
| **quiet.sh** | Wrapper para CLIs ruidosos (`kubectl logs`, `gh run view`, `gcloud`). | Si el output pasa ~120 líneas: muestra head+tail y guarda el dump completo en `.cache/quiet/` para leer bajo demanda. |
| **repo-brief.sh** | Brief determinista por repo (`.cache/briefs/<repo>.md`, cacheado por HEAD): stack, comandos de test, estructura, convenciones. | El arranque frío de cada implementer/reviewer re-descubría lo mismo en cada tarea — minutos y miles de tokens de exploración. El brief se genera UNA vez con $0 tokens y viaja en el prompt: el agente arranca editando, no explorando. |
| **Carriles** (express/standard/full) | El pipeline dimensionado al blast radius (ver ②b). | El ahorro más grande de todos: una tarea chica pasa de ~6 sesiones LLM a 2. Menos sesiones = menos arranques fríos = menos tokens Y menos minutos, con los mismos gates. |
| **ccusage** | La báscula: costo por sesión/tarea. | No optimizas lo que no mides. |
| **models.yaml + stamp-models.sh** | LA perilla de modelos: aliases `fast\|smart\|deep` por proveedor (anthropic, vertex, bedrock, kimi, openrouter), rol→alias, overrides por agente. `make models` estampa; `resolve` traduce. | Cambiar un modelo, un agente o el proveedor entero es UNA línea + un comando — nadie edita frontmatter a mano y el doctor detecta el drift. El sandwich sigue: caro donde el output tiene fan-out (planes, veredictos), medio en implementación, barato en lo mecánico; reglas de escalación y presupuestos USD por cronjob incluidos. Por tarea: `/auto <id> --model deep`. |

**La regla del catálogo (anti-consejo-vacío):** toda herramienta que un prompt cite debe tener su cadena completa — *quién la instala* (bootstrap, desde el catálogo) → *quién la alimenta* (índices/configs con ciclo de vida propio, como `graph-refresh.sh`) → *quién la vigila* (doctor, con remediación) → *quién la ejecuta de verdad* (gate, cronjob o agente). Una herramienta citada sin esa cadena es un consejo vacío: la query falla y el agente cae al camino caro que la herramienta existía para evitar. Las capacidades sin consumidor automático (cosign, sloth, jscpd…) lo declaran en su entrada del catálogo — no se vende lo que nadie corre.

### Modelos: una perilla, cinco proveedores

Todo el harness habla en **aliases** (`fast | smart | deep`) y su semántica es de roles, no de precio: **deep piensa** (plan, RFC, litigios, escalación), **smart produce** (todo el código, review, QA) y **fast despacha** lo especificísimo sin juicio (digest, triage; Sonnet, y solo ahí). En Anthropic deep y smart son el mismo modelo (Opus 5) y lo que los separa es el esfuerzo de razonamiento (`ultrathink`), no el ID; en proveedores con un tier de razonamiento aparte el alias sí cambia de modelo. `models.yaml` documenta las reglas de uso del tier deep y traduce cada alias al ID real del proveedor activo (Anthropic, Vertex, Bedrock, Kimi, MiniMax, OpenRouter). Tres niveles de control, todos de una línea:

```yaml
provider: anthropic        # ← cambiar de proveedor entero: ESTA línea
roles:
  implementer: smart       # ← cambiar un rol: esta línea + make models
overrides:
  svc-atlas: fast          # ← excepción por agente: una línea + make models
```

```
/auto COR-123 --model deep       # ← una sola tarea, sin tocar nada
```

`scripts/stamp-models.sh` materializa la política en el frontmatter de los agentes (determinista, $0 tokens), `resolve <alias|rol>` la traduce para headless/cronjobs, y `check` (lo corre el doctor) detecta si alguien editó un agente a mano. Las tablas `models.vertex`, `models.bedrock`, `models.kimi` y `models.openrouter` traen el formato de ID de cada proveedor (verifica el ID exacto contra tu catálogo) y las env vars que Claude Code necesita para cada backend (`CLAUDE_CODE_USE_VERTEX=1`, `CLAUDE_CODE_USE_BEDROCK=1`…).

### Multi-herramienta: Claude Code primero, nadie afuera

El harness está orientado a Claude Code (hooks, agentes, comandos nativos), pero **su capa de verdad es agnóstica**: gates, policy engine, worktrees y tickets son shell/Python que cualquier agente puede ejecutar. La instancia genera **`AGENTS.md`** — el estándar que leen Cursor, Kimi Code, Codex, Gemini CLI y compañía — con las leyes, el mapa de la verdad y una clave: los comandos de `.claude/commands/*.md` **son playbooks markdown**; una herramienta sin slash-commands los abre y los sigue tal cual, y los agentes de `.claude/agents/` sirven como system prompts del rol. Una honestidad importante: los hooks que frenan el push directo solo corren en Claude Code — `AGENTS.md` lo advierte y recomienda branch protection en el remoto como red equivalente para las demás herramientas.

### Skills en tres capas (lo custom sobrevive al update)

Una instancia mezcla skills de tres dueños, y la procedencia es **verificable, no de fe**: las **upstream** las trae el plugin (las renueva `harness update`, gobernadas por el manifest del generador); las **compartidas** viven en TUS repos (ej. `corvux-skills`), se declaran en `skills.yaml` y las instala `make skills` con una marca `.managed` (repo + ref + sha exactos); las **locales** (`.claude/skills/<nombre>/` sin marca) no las toca NADIE: ni el update ni el sync. En colisión de nombres la local siempre gana, con error explícito. Y hay promoción, el `/promote` de las skills: una local que probó su valor se muda al repo compartido y todas tus instancias la heredan. El doctor vigila el drift de la capa compartida.

### Memoria (tres tipos, tres lugares)

| Tipo | Dónde vive | Herramienta |
|---|---|---|
| **Semántica** (decisiones) | `docs/adr/` — git es la única verdad duradera | ADRs |
| **Estado del trabajo** (qué va cómo) | DAG de tareas git-backed | **beads** (`bd ready --json`) — el plan del arquitecto son beads con dependencias |
| **Episódica** (qué aprendimos) | Base local con búsqueda FTS | **engram** (MCP): `mem_search` al iniciar tarea, `mem_save` al cerrar. SOLO en perfiles orquestador/arquitecto — nunca en implementers (costo de contexto). |

El ritual **`/promote`** (semanal) cierra el loop: *la memoria propone, git dispone* — decisión madura → ADR; error repetido → regla semgrep o gate; ruido → expira.

### Gates y hooks (las leyes con dientes)

- **`ship.sh`** — la única puerta a main. En serie lo que tiene orden real: rebase → trailer `Task:` → **carril** (`gate_lane`: el diff respeta lo que el intake declaró). Después, **en paralelo**: build/test por lenguaje + `buf breaking` ∥ `gitleaks` + `semgrep` ∥ **tests-no-debilitados** ∥ veredicto+compliance+**evidencia**+policy. Al final: lock por repo → push. Los rojos se reportan juntos y **el error de cada gate es un prompt**: incluye su remediación, para que el agente corrija TODO en una iteración (máx 2 rondas de autofix).
- **Gates activados por config** — la config del repo es el opt-in; con ella presente son gates duros, sin ella silencio: `import-linter` (fronteras de capas Python, `.importlinter`), `go-arch-lint` (grafo de dependencias Go, `.go-arch-lint.yml`) y `squawk` (lint de migraciones SQL nuevas del diff — las viejas no se re-litigan). Config presente sin herramienta instalada = warning honesto, jamás un gate fingido.

  Los dos gates nuevos existen porque nos hicieron una pregunta incómoda: *nuestros gates confían en cosas que el agente puede editar.*

  - **`gate_tests_untouched`** — el gate de test confía en el test suite, y el test suite es un archivo. La forma más barata de pasar a verde no es arreglar el código: es borrar la aserción. Está medido en la literatura (en [SWE-Bench+](https://arxiv.org/abs/2410.06992), ~31% de los parches "exitosos" pasaban gracias a tests débiles) y los harnesses que solo escriben *"no borres tests"* en prosa lo escriben porque no tienen gate. Este bloquea aserciones eliminadas, `skip`s añadidos y tests borrados — **salvo** que el delta-spec declare el cambio como `MODIFIED`/`REMOVED`, porque entonces no es trampa: es cumplir la spec. Los tests son el contrato; cambiar uno es un RFC.
  - **`gate_evidence`** — la compliance matrix la escribe un agente. Nada comprobaba que hubiera *abierto* el test que cita. O sea: **el verificador estaba proponiendo**, justo lo que nuestra filosofía prohíbe. Ahora el hook `track-read.sh` registra qué artefactos se leyeron de verdad y el gate intersecta lo citado con lo leído: si un requirement dice `covered: true` citando un archivo que nadie abrió (o que no existe), no pasa. Cero LLM, cero opinión — es una intersección de conjuntos.
- **Hooks, en dos familias con leyes opuestas.** Los que **bloquean** son *fail-closed*: `block-direct-push` (ningún `git push` a main sobrevive) y `guard-canonical` (el clon base es intocable **y ahora también `ship.sh`, los hooks y `settings.json`** — un agente atascado en un gate que "arregla" ship.sh no está pasando el gate: lo está borrando, y con él todos los demás para siempre). Sin `jq`, bloquean por precaución. Los que **observan** son *fail-open* y `async`: `track-read.sh` (el libro de a bordo de la evidencia) y `ui-emit.sh` (el bus del panel). Salen 0 siempre: un hook de telemetría que puede tumbar el pipeline es un bug, no una feature.
- **Denials** — `kubectl apply`, `terraform apply`, `argocd app rollback`, `git push --force` y la regeneración ciega de snapshots están denegados a los agentes en `settings.json`. Writes de infra: solo por GitOps.
- **semgrep/rules.yaml** — sensores custom donde **cada regla incluye su remediación en el mensaje**. Crece solo: el cronjob `rule-miner` mina reglas nuevas de los bugs de cada mes.

### El canal de vuelta: un bug del harness no muere en tu máquina

El harness corre en la máquina de cada usuario, así que sus propias fallas se quedan ahí: el agente pone un workaround local, sigue con su tarea, y el siguiente usuario tropieza con lo mismo. Por eso la instancia trae una **regla automática** (ley 12 del CLAUDE.md, ley 9 del AGENTS.md): si un artefacto **del plugin** falla o contradice lo que su propia cabecera documenta, el agente lo verifica y levanta el issue en este repo, sin que nadie se lo pida.

Lo delicado no es reportar: es no convertir el canal en spam. Por eso el juicio y la verificación están separados. El juicio lo pone la skill `harness-bug-report` (¿el repro se sostiene dos veces en shell limpia? ¿es del plugin o de tu instancia? ¿le pasa a alguien más? ¿vale la pena arreglarlo?) y lo verificable lo hace `scripts/harness-bug.sh`, que es **fail-closed** y no publica nada si algo no cuadra:

| Verificación | Por qué existe |
|---|---|
| **Propiedad del artefacto** (plugin vs instancia) | tu spec, tu paso custom o tu abogado no son bugs del plugin, aunque duelan igual |
| **Drift contra el template** (sha256) | un archivo que parcheaste no lo reproduce upstream: exige `--force` con justificación |
| **Versión al día** | reportar un bug ya corregido es la falla más común de estos canales |
| **Repro adjunto y no vacío** | un reporte sin repro es una queja |
| **Dedupe por fingerprint** (local + búsqueda remota) | el mismo bug en 20 máquinas es un issue, no 20 |
| **Cuota de 3 issues/24h** | una tormenta automática entierra los reportes reales |
| **Redacción de secretos** (los mismos patrones del bus, ya testeados) | el repro suele ser la salida de un comando, y sale a un repo público |

Es la única acción del harness que publica algo hacia afuera, así que se declara en la entrevista y se apaga con una línea: `upstream_issues: off` en `harness-answers.yaml` (o `HARNESS_UPSTREAM_ISSUES=off`), y los hallazgos se te reportan a ti. Lo ya reportado: `make bugs`.

---

## Self-healing: los cronjobs

Arquitectura innegociable: **un detector determinista (script, cero LLM) produce hallazgos; el agente solo despierta si hay algo que arreglar**, con modelo y presupuesto USD de `models.yaml`, y todo aterriza como PR o issue — jamás push directo. El `cron-runner.sh` trae circuit breaker (3 fallos → se apaga y avisa) y un ledger de gasto que el digest reporta: **el harness se auto-audita**.

```mermaid
flowchart LR
    C["⏰ cron / webhook"] --> DET["detector determinista<br/>(script, $0)"]
    DET -->|"limpio"| Z["fin — cero tokens"]
    DET -->|"hallazgos"| AG["claude -p<br/>modelo/presupuesto de models.yaml<br/>--permission-mode dontAsk"]
    AG --> PR["PR o issue<br/>(nunca push a main)"]
    AG --> L["ledger de gasto<br/>+ circuit breaker"]
```

| Job | Detecta | El agente… |
|---|---|---|
| **ci-doctor** | runs rojos en main | fix quirúrgico o PR de revert |
| **dep-shepherd** | PRs de Renovate sin automerge | matriz de riesgo, grep de imports reales, merge o fix |
| **vuln-watch** | vulns nuevas (osv-scanner + trivy) | PR de bump con tests |
| **flake-warden** | tests que pasan Y fallan en el mismo commit | cuarentena inmediata + root-cause |
| **daily-digest** | (siempre) | changelog del día + gasto de la noche → Slack |
| **dead-code-reaper** | código muerto (knip/vulture/deadcode) | borra en lotes con tests; FP → whitelist |
| **ratchet-keeper** | métricas que solo pueden mejorar | sube el piso o issue de regresión |
| **mutation-sentinel** | mutantes que ningún test mata | escribe el test que falta |
| **doc-gardener** | links rotos, símbolos perdidos, diagramas drifteados | PR de jardinería |
| **slo-watchdog** | burn-rate de SLOs (webhook) | diagnóstico read-only + PR de revert |
| **harness-janitor** | worktrees/ramas/locks huérfanos, memoria inflada | destila la memoria |
| **rule-miner** | los bugs del mes (commits fix/revert) | **mina reglas semgrep que los habrían atrapado** — el sistema mejora solo cada mes |
| **skill-miner** | supuestos idénticos en ≥3 tareas · decisiones/paradas repetidas en el bus | **empaqueta el procedimiento repetido como skill** (`.claude/skills/`), siguiendo la guía de skill-creator; PR = ratificación humana |

Corren donde elijas: crontab local, K8s CronJobs (manifiesto incluido, auth keyless por Workload Identity) o GitHub Actions schedule. Son opcionales y se activan después con un update.

---

## Secretos

Reglas: **los valores jamás tocan el repo, el chat ni los logs**. Solo referencias.

```mermaid
flowchart LR
    V["🔐 Fuente<br/>(Vault · GCP SM · AWS SM<br/>· doppler · sops · 1Password · env)"] -->|"secrets.sh pull"| S[".secrets<br/>(gitignoreado, chmod 600)"]
    T["~/.config/harness/vault-token<br/>(lo tecleas TÚ — read -s,<br/>nunca pasa por el agente)"] --> V
    S -->|"with-secrets.sh <cmd><br/>(ÚNICO punto de inyección)"| U["MCPs autenticados<br/>CLIs (kubectl, kargo…)<br/>deploy-watch, tickets"]
```

- El **discovery detecta** tu fuente (señales: `.sops.yaml`, `doppler.yaml`, `op://`, secret managers en terraform, `VAULT_ADDR`) y la entrevista recomienda con evidencia.
- El generador **verifica el layout real** de tu Vault (nombres de paths y campos — nunca valores) antes de escribir los mapeos.
- `make init` detecta token **faltante o expirado** (lo valida con `vault token lookup`, no solo su existencia), te enseña cómo conseguir uno, te lo pide interactivo y lo valida al guardarlo.
- La materialización es **honesta**: si una clave no se pudo leer, falla con el detalle, no dice "✅".

---

## Qué tan flexible es

El flujo es fijo (discovery → entrevista → generación → verificación); **todo lo demás es dato, no código**:

| Quieres… | Tocas… |
|---|---|
| Soportar una herramienta nueva (CLI o MCP) | agrega una entrada a `catalog/capabilities.yaml` (provider, bin/mcp, tier, profiles, detect, install) — la entrevista la ofrecerá cuando su señal aparezca |
| Otro lenguaje/stack | agrega la detección de rol en `discover.sh` + el gate de lenguaje en `ship.sh.tmpl` |
| Otro tracker de tickets | los contratos de `ticket-pull/close` están especificados; se adaptan a `gh issue` o a cualquier API |
| Otra fuente de secretos | `secrets.sh` ya trae 7; una nueva es una función `pull_*` más |
| Cambiar el modelo de un rol, un agente o TODO | UNA línea en `models.yaml` (roles/overrides, en aliases fast\|smart\|deep) + `make models` |
| Cambiar de proveedor (Anthropic ↔ Vertex ↔ Bedrock ↔ Kimi ↔ OpenRouter) | la línea `provider:` de `models.yaml` + `make models` — roles y comandos no se tocan |
| Modelo para UNA tarea puntual | `/auto <id> --model deep` (o `model:` en el frontmatter de task.md) |
| Usar el harness desde Cursor, Kimi Code u otro agente | ya está: `AGENTS.md` (estándar multi-herramienta) es el punto de entrada; los comandos de `.claude/commands/` son playbooks markdown legibles por cualquiera |
| Otro cronjob de self-healing | un archivo en `cronjobs/jobs/`: metadata + `detect()` + prompt. El runner hace el resto |
| Más/menos agentes | el clustering se decide en la entrevista y se corrige en `harness-answers.yaml` |
| Que `/auto` te pida un "go" antes de tocar main (o que no lo pida) | `autonomy: checkpoint \| full` en `harness-answers.yaml` |
| Endurecer/relajar qué bloquea el carril express | `LANE_GUARD_PATTERN` (env de ship.sh) + las señales del paso 0.1 de `/auto`; las transiciones por carril viven en `harness-policy.json` |
| Endurecer/relajar leyes | hooks y denials en `settings.json.tmpl`; gates en `ship.sh.tmpl` |

Lo **no** negociable (a propósito): push a main solo por gates, worktrees, valores de secretos fuera del chat, rollback seguro (nunca `argocd app rollback` automático — Argo Rollouts abort-to-stable o revert en git), y que la ley la ratifiquen humanos.

## Actualizaciones

Los fixes se hacen en ESTE repo y las instancias los reciben por diff:

```bash
/plugin marketplace update harness    # refresca el plugin
/harness-init .                       # en el workspace: modo update
```

El modo update **no re-pregunta** lo respondido, migra esquemas sin tocar tus decisiones (`harness-answers.yaml`; y `models.yaml` viejo con IDs crudos → provider + aliases), **reconcilia** (una respuesta nueva propaga diffs a manifest/CLAUDE.md/DAG) y distingue propiedad: los scripts del plugin se actualizan con upstream; tus answers, models, specs y constituciones son ley local y se conservan. Nada se pisa sin confirmación, con una excepción declarada: los **paquetes atados** (carriles: policy+auto+ship · modelos: models.yaml+stamp+cron-runner · plan-hondo/loop-corto: plan-lint+ship --precheck+comandos+agentes) se aceptan o rechazan juntos, porque a medias romperían la instancia. Al aplicar, el update re-estampa modelos y re-corre el doctor.

## Estructura de este repo

```
.claude-plugin/    manifest del plugin + marketplace
commands/          /harness-init · /harness-doctor · /harness-update
skills/            harness-init/SKILL.md — el cerebro: fases, clustering, entrevista, tabla de generación
catalog/           capabilities.yaml (el menú): 59 capacidades con detect/tier/profiles/install
scripts/           discover.sh · doctor.sh (deterministas, portables macOS/Linux, bash 3.2)
tests/             la suite (./tests/run.sh) — ver "Tests" abajo
templates/         todo lo que se genera:
  ├── CLAUDE.md, README, manifest, models, answers, settings, Makefile, semgrep
  ├── agents/      architect · implementer · reviewer · qa · svc-agent (abogado genérico)
  ├── commands/    auto (pipeline autónomo: ticket o prompt → prod) · feature · rfc
  │                implement · review · ship · promote · archive
  ├── docs/        constitution · spec (EARS) · pipeline · intake · testing-policy · quality · ADR · cronjobs
  ├── scripts/     bootstrap · ship (+ --precheck) · plan-lint · worktree · repo-brief · stamp-models · secrets · with-secrets · quiet · deploy-watch · tickets
  ├── skills/      skill-creator (guía para minar/crear skills de instancia)
  ├── hooks/       block-direct-push · guard-canonical (fail-closed: bloquean)
  │                track-read · ui-emit (fail-open: observan)
  ├── ui/          server.py · pricing.json · web/ (fuente React+shadcn) · dist/ (build vendoreado)
  └── cronjobs/    cron-runner + 13 jobs + manifiesto K8s
```

## Tests

```
./tests/run.sh        # todo (~40s: el lock prueba su gracia de 15s en tiempo real)
./tests/run.sh fast   # salta el test lento del lock
```

La suite prueba **el código real de los templates** — no copias ni mocks del sistema bajo prueba — y cada test crea su workspace temporal y lo borra: nada toca tu workspace ni la red.

| Test | Qué protege |
|---|---|
| `test_emit.sh` | El bus: shape del evento, `ok` booleano, **redacción de las 7 familias de secretos**, fail-open, sourceable desde sh/zsh con `set -u` |
| `test_track_read.sh` | La evidencia: la tarea se deriva de la ruta (jamás de estado compartido), cero contaminación entre tareas, ids maliciosos no construyen rutas |
| `test_ship_lock.sh` | El lock de ship: las dos ventanas de muerte que costaron un lock inmortal, y que un dueño vivo jamás pierde su lock |
| `test_ship_gates.sh` | Los añadidos de velocidad de ship.sh: `gate_lane` (un express que toca contratos/migraciones NO pasa; full no se ve afectado) y los gates paralelos (un rojo no esconde a los demás; verde agregado exige todos verdes) — extraídos del template real, como el lock |
| `test_policy.py` (carriles) | La máquina de estados por carril: express salta rfc, el default no; carril desconocido rechazado; `escalate` solo sube, recupera la fase rfc y conserva el resto del estado |
| `test_stamp_models.sh` | La perilla de modelos: rol→alias→ID, overrides por agente, cambio de proveedor en una línea, `resolve`, `check` detecta drift con remediación, alias inexistente falla en vez de estampar basura |
| `test_graph_refresh.sh` | El ciclo de vida del grafo de graphify: fail-open sin binario, build inicial sin `--update`, refresh incremental con `--update`, y cero llamadas cuando ningún HEAD cambió (stamp) |
| `test_discover.sh` | La Fase 1 contra fixtures reales: cada familia de rol (contracts/service/library/frontend/infra-module/docs) se infiere bien — es la ENTRADA del clustering; y el caso vacío falla con remediación en vez de inventariar mentiras |
| `test_doctor.sh` | El doctor no miente en ninguna dirección: workspace roto = exit no-cero con remediación por fallo; drift de modelos detectado y su verde tras `make models`; y los checks de cadena-completa (graphify, beads, AGENTS.md) existen |
| `test_plan_lint.sh` | El plan es ejecutable o no es plan: tarea sin `archivos` o con `complexity` inventada es roja, `req` que el delta-spec no define es rojo, y prosa legítima en español ("todo el diff") NO se confunde con un TODO de código |
| `test_precheck.sh` | `ship.sh --precheck`: corre los gates mecánicos SIN exigir veredicto (si lo exigiera no podría correr antes del review), deja sello atado al HEAD revisado, y no toca `origin/main` ni el lock de ship |
| `test_server.py` | El panel: ADR-0004 (modelo sin precio = None, jamás tarifa de Opus), normalización del bus, y todo el plano de operar sin red (validación, frontmatter, dedupe de ids, tokens 0600) |
| `test_op_http.py` | El plano de operar por HTTP contra el server real: 403 sin token / token malo / Host raro, crear tarea lanza un `claude` de verdad (stub que graba sus args), responder reanuda LA sesión pedida |

La suite ya se pagó el primer día: cachó que el `\b` de sed no existe en macOS (cuatro familias de secretos viajaban sin redactar), seis templates sin bit de ejecución, y un `_record_run` que dependía en silencio del orden de llamadas.

## Canon de referencia

Este diseño destila: OpenAI *Harness engineering* · Anthropic *Effective harnesses for long-running agents* y *Building effective agents* · Böckeler (martinfowler.com) *harness engineering + sensors* · Stripe *Minions* · Yegge *beads/Gas Town* · GitHub Spec Kit / OpenSpec / Kiro (EARS) · Hashimoto *My AI Adoption Journey* · Manus *Context engineering*.

---

**Licencia**: MIT · **Autor**: Andres Garcia · Construido iterando contra una instalación real: cada fricción de la primera instancia se convirtió en una versión de este plugin.
