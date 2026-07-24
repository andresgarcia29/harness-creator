---
name: harness-init
description: Instala un harness de ingeniería agéntica en un workspace multi-repo. Usar cuando el usuario pida instalar, inicializar o crear el harness en una carpeta de repositorios, o invoque /harness-init. Cubre discovery de repos, propuesta de topología de agentes (clustering), entrevista de configuración, selección de capacidades (CLIs/MCPs), generación de CLAUDE.md, agentes, comandos de pipeline, gates, hooks y docs, y verificación final.
---

# harness-init — Instalador del harness

Instalas un harness siguiendo cuatro fases EN ORDEN. La regla de oro
aplica al instalador mismo: lo determinista lo hacen scripts; tú solo
pones juicio donde hace falta (topología, entrevista, generación).

## Reglas globales (todas las fases)

- **Secretos**: NUNCA leas, pidas ni escribas valores. Solo referencias
  (`vault://…`, `gcp-sm://…`, `env://VAR`).
- **Idempotencia total — /harness-init se puede correr SIEMPRE.** Si el
  workspace ya tiene `.harness-version`, entras en **MODO UPDATE**:
  1. Lee `harness-answers.yaml` — NO re-preguntes nada ya respondido;
     pregunta SOLO lo nuevo de esta versión del plugin (compara la
     versión de answers con la del plugin).
  2. Migra el esquema del answers si esta versión agregó campos (ej.
     `scope:` por capacidad, `instance:`) SIN tocar decisiones tomadas.
  3. Re-instancia los templates con las respuestas registradas y
     presenta DIFF por archivo: upstream mejoró → proponlo; el humano
     personalizó → consérvalo; chocan → muestra ambos y que decida.
  4. **Reconciliación**: toda respuesta nueva debe PROPAGARSE a los
     artefactos existentes, no solo registrarse. Ej.: si `instance.repo`
     revela que un repo clonado no es de producto, propón el diff que
     lo quita de manifest.yaml, del DAG, de la tabla del CLAUDE.md y de
     answers — y sugerir remover el clon. Una respuesta que contradice
     un artefacto sin generar su diff es una migración incompleta.
  5. Nada se pisa sin confirmación — salvo que los **PAQUETES ATADOS se
     aceptan/rechazan juntos** (a medias rompen la instancia; decláralo
     antes de que el humano elija). Los vigentes: **carriles**
     (harness-policy.json + harness-policy.py + auto.md + ship.sh) y
     **pasos-custom** (auto.md + harness-policy.json + pipeline-steps.sh +
     doctor.sh: el /auto nuevo llama a pipeline-steps.sh y usa la parada
     custom_step_failed que solo existe en el policy.json nuevo) y
     **modelos** (models.yaml esquema aliases + stamp-models.sh +
     cron-runner.sh + re-estampado). La lista completa y las migraciones
     de esquema viven en `commands/harness-update.md`.
  6. Al final: `bash scripts/stamp-models.sh` si tocaste models.yaml o
     agentes, re-corre el doctor, y actualiza `.harness-version`.
- **Idempotencia por archivo** (también en instalación fresca): si un
  archivo existe, diff y pregunta. Nunca destruyas personalización local.
- **Tokens**: no explores los repos a mano; el inventario ya lo hizo.
  Lee archivos de repos SOLO para resolver una ambigüedad concreta de
  la entrevista.
- **Registro**: TODA decisión del humano va a `harness-answers.yaml`
  (esquema FIJO: `templates/harness-answers.yaml.tmpl`; doctor.sh lo
  parsea — no cambies la forma).

## Fase 1 — Discovery (determinista, cero juicio)

```
${CLAUDE_PLUGIN_ROOT}/scripts/discover.sh <workspace>
```

Produce `inventory.json`: por repo, lenguajes, señales (buf, helm,
argocd, kargo, docker…), `role_guess` (service | frontend | mobile |
library | contracts | infra-module | infra-live | ci-library | docs) y
tamaño; más `by_role` (el insumo del clustering). Léelo completo UNA
vez. Si falla, arregla la causa (¿no hay repos/? ¿no son git?) — no
improvises el inventario a mano.

## Fase 2 — Entrevista (aquí piensas tú)

Objetivo: llenar `harness-answers.yaml`. Pregunta SOLO lo que el
inventario no responde y SIEMPRE recomienda con evidencia
("Detecté buf.yaml en `proto` → gate buf-breaking"). Agrupa 2-3
preguntas por turno; no interrogatorio.

### 2a. Topología de agentes (clustering dinámico — TU propuesta primero)

Cuatro agentes fijos siempre: `architect`, `implementer`, `reviewer`,
`qa`. Los ABOGADOS (defienden ownership en RFCs) son dinámicos —
propón un clustering desde `by_role` y pide corrección:

| Rol detectado | Regla de clustering |
|---|---|
| service | 1 abogado por servicio (poseen datos → intereses propios) |
| contracts | SIN abogado: el repo proto es el árbitro; lo custodia el arquitecto + buf |
| infra-module, infra-live, ci-library, helm | UN solo abogado `infra` para todos (mismo interés: estabilidad de plataforma) |
| frontend, mobile | UN abogado `frontends` si hay 2+ (no poseen datos; defienden contratos de consumo y UX) |
| library | SIN abogado: los defienden sus consumidores + el arquitecto |
| docs | sin agente |

Techo: ~12 agentes en total. Si hay más servicios que eso, propone
agrupar por dominio de negocio (p. ej. `svc-mensajeria` para 3
servicios del mismo dominio) — el humano decide. Con 20 terraform
modules el resultado es UN `infra`, no 20 agentes: más agentes ≠ mejor
harness; cada agente es contexto y mantenimiento.

### 2b. Resto de preguntas obligatorias

1. **Nombre del proyecto** y prefijo de tickets.
2. **Flujo a main**: trunk direct-to-prod | trunk+staging | PRs
   (direct-to-prod → gates estrictos + gitleaks obligatorio).
3. **DAG**: propón el orden inferido (contracts → shared → services →
   frontends) y pide corrección.
4. **Ownership por abogado**: qué posee / no posee / invariantes.
   Respuestas cortas; van a las constituciones DRAFT.
5. **Capacidades**: presenta el catálogo
   (`${CLAUDE_PLUGIN_ROOT}/catalog/capabilities.yaml`) FILTRADO por
   detect, agrupado por categoría, con tu recomendación marcada. Por
   cada una el humano puede DEGRADAR el tier (ej. github-mcp a
   read-only). Registra nombre + bin/mcp + tier + `scope:` (core |
   cronjob, según el campo `cronjob:` del catálogo). REGLA: si los
   cronjobs quedaron deshabilitados (#12), NO palomees capacidades
   cuyo ÚNICO consumidor es un cronjob — regístralas comentadas como
   "pendientes de activar cronjobs". Las `phase: 2` se mencionan como
   siguientes pasos, no se instalan.
6. **Tickets**: linear | github | none.
7. **Memoria**: engram sí/no; perfiles (default: orquestador y
   arquitecto SOLAMENTE).
8. **Secretos**: vault | gcp-secret-manager | aws-secrets-manager |
   doppler | sops | 1password | env. RECOMIENDA desde
   `inventory.json → secret_hints` (el discovery detecta .sops.yaml,
   doppler.yaml, op://, aws_secretsmanager/google_secret_manager en
   terraform, VAULT_ADDR, .env.example) — evidencia, no adivinanza.
   Si vault: VAULT_ADDR y path base del KV (solo referencias). El
   TOKEN nunca se pide por chat: bootstrap.sh lo pide interactivo
   (read -s directo al archivo) y VALIDA su vigencia — un token
   muerto se detecta y se re-pide, no se reporta como presente.
9. **Deploy** (si hay CD): org de GitHub, prefijo de apps ArgoCD,
   proyecto Kargo, tenant canary, y ROLLBACK_MODE auto|manual
   (recomienda auto: rollback primero, diagnóstico después).
10. **Modelos**: primero el PROVEEDOR (anthropic | vertex | bedrock |
    kimi | minimax | openrouter; default anthropic; si eligió otro,
    recuérdale verificar los IDs de la sección `models.<provider>`
    contra su catálogo y las env vars del backend). Después el sandwich
    EN ALIASES con esta recomendación default (la semántica vive en
    models.yaml): **deep = el pensador** (orquestador, architect,
    abogados, escalación; en anthropic es Fable), **smart = el
    productor** (implementer, reviewer, qa; en anthropic es Opus 4.8),
    **fast = lo especificísimo** (mechanical y cronjobs cheap; en
    anthropic es Sonnet, y solo ahí). Las respuestas se estampan como
    ALIASES en `models.yaml`; los IDs reales los materializa
    `scripts/stamp-models.sh` en el frontmatter de los agentes.
    `loop_budget` default 3. Si el humano quiere deep en TODO,
    advierte la latencia comprada donde no hay decisión (las reglas de
    Fable de models.yaml) y registra la decisión.
10a. **Profundidad de planeación** (no preguntes, informa): los planes,
    la síntesis del RFC y los ADRs se escriben en modo **ultrathink**, y
    el architect trabaja como hilo fino descomponiendo en probes
    (`minion_decompose: auto` = ON en standard/full, OFF en express).
    Solo pregunta si el humano quiere apagarlo (`false`), y anota que el
    intercambio es: más razonamiento en el plan a cambio de menos rondas
    de review, que es donde se van los minutos.
10b. **Autonomía de /auto**: full | checkpoint (recomendado para las
    primeras semanas). checkpoint = UNA sola pausa, un resumen antes
    del primer ship a main; full = ninguna pausa, los gates y el canary
    son la red. En ambos casos /auto redacta criterios y resuelve
    ambigüedad solo (ledger de supuestos): la autonomía gradúa cuándo
    se toca main, NO cuánto piensa el humano. Si el humano quiere
    conducir fase por fase, no usa /auto: usa los comandos sueltos.
11. **Principios del proyecto** para la constitución: 2-4 reglas
    innegociables propias del dominio (ej. multi-tenancy, localización)
    — van a `docs/constitution.md` §6, DRAFT hasta ratificar.
12. **Cronjobs self-healing**: presenta el catálogo de
    `templates/cronjobs/jobs/` con tu recomendación por etapa
    (arranque mínimo: daily-digest, doc-gardener, harness-janitor,
    ci-doctor; el resto cuando sus detectores tengan herramienta
    instalada). Pregunta dónde corren: crontab local | GKE (genera
    los manifiestos K8s) | GitHub Actions schedule. Si el humano los
    deshabilita, respeta la regla de #5 (sin capacidades cronjob-only).
13. **Versionado de la instancia**: ¿el workspace se versiona en sí
    mismo (git init aquí) o existe un repo destino (ej.
    corvux-harness)? Registra `instance.repo` en answers. Si un repo
    clonado en repos/ ES ese destino, EXCLÚYELO del clustering, del
    DAG y del manifest — no es un repo de producto.
14. **Bootstrap de secretos** (si source ≠ env): explica el flujo y
    deja las instrucciones listas — el humano coloca su token FUERA
    del chat (`~/.config/harness/vault-token`, chmod 600; tú NUNCA lo
    ves), luego corre `scripts/secrets.sh pull` y verificas con
    `scripts/secrets.sh check`. La instalación no está completa sin
    `.secrets` materializado (doctor lo audita como warning).
    **VERIFICA EL LAYOUT, no lo asumas**: si hay token válido
    disponible, lista los paths y los NOMBRES de campo reales
    (`vault kv list …` y `vault kv get -format=json … | jq
    '.data.data | keys'` — solo nombres, JAMÁS valores) y genera las
    líneas dump_kv con esos campos. Cada Vault nombra distinto
    (token vs password, api_key vs LINEAR_API_KEY); asumir el campo
    rompe la materialización con el layout real.

15. **Canal de vuelta al plugin** (`upstream_issues`, default `auto`):
    cuando un agente tropiece con un bug DEL HARNESS (no del código del
    usuario), lo verifica y levanta un issue en el repo público del
    plugin. DECLÁRALO, no lo escondas: es la única acción del harness que
    publica algo hacia afuera. Di qué viaja (artefacto, repro que el
    agente redujo, versión, OS) y qué no (valores de secretos: el cuerpo
    pasa por la redacción del bus; hay dedupe por fingerprint y cuota de
    3 issues/24h). Si el humano prefiere que nada salga de su máquina:
    `off`, y los hallazgos se le reportan a él. Registra la decisión.

## Fase 3 — Generación

**Camino preferido (determinista, cero tokens):** si `command -v harness`
existe (instalado con `brew install andresgarcia29/agm/harness`), NO
instancies a mano: escribe las respuestas de la entrevista como JSON del
esquema de answers y corre

```bash
harness generate --workspace <ws> --answers <answers.json>
```

El binario embebe estos mismos templates (sincronizados por release), aplica
la tabla completa de abajo con idempotencia por sha256 (lo personalizado va a
`.new`, jamás se pisa) y registra la instancia para `harness update`. Después
salta directo a la Fase 3.5. La tabla manual queda como fallback cuando el
binario no está — y como especificación de paridad (el test de la suite
compara ambos sets de destinos).

Instancia desde `${CLAUDE_PLUGIN_ROOT}/templates/` al workspace.
Scripts SIEMPRE con `chmod +x`. Tabla completa:

| Destino | Fuente | Condición |
|---|---|---|
| `README.md` | README.md.tmpl | siempre — onboarding para HUMANOS: {{SECRETS_ONBOARDING}} se instancia según la fuente elegida (de dónde sale el token/credencial, comandos exactos). Un usuario nuevo debe poder llegar a make init sin preguntarle a nadie |
| `CLAUDE.md` | CLAUDE.md.tmpl | siempre (mapa ≤110 líneas; tabla de repos desde inventory) |
| `manifest.yaml` | manifest.yaml.tmpl | siempre |
| `harness-answers.yaml` | harness-answers.yaml.tmpl | siempre (esquema fijo) |
| `.harness-version` | versión del plugin | siempre |
| `Makefile` | Makefile.tmpl | siempre |
| `.gitignore` | inline: `repos/ worktrees/ locks/ .cache/ .secrets .secrets.d/ inventory.json go.work go.work.sum graphify-out/` (go.work lo genera scripts/gowork.sh: derivable y por-máquina; .cache/ cubre el CPython de py.sh, el corepack de fe.sh, los briefs y el stamp del grafo; graphify-out/ es derivable del código) | siempre |
| `.claude/settings.json` | settings.json.tmpl | siempre (hooks + denials read-only) |
| `.claude/hooks/{block-direct-push,guard-canonical}.sh` | hooks/ | siempre (fail-CLOSED: bloquean) |
| `.claude/hooks/guard-build-slot.sh` | hooks/ | siempre (fail-OPEN: bloquea `docker build/run` pelado, Ley 8; ya registrado en settings.json.tmpl junto a block-direct-push) |
| `.claude/hooks/{track-read,ui-emit}.sh` | hooks/ | siempre (fail-OPEN: observan, `async: true`). track-read alimenta `gate_evidence` de ship.sh; ui-emit alimenta `make ui` |
| `scripts/ui/{panel.sh,server.py,pricing.json,dist/}` | ui/ | siempre — el panel (`make ui`). `panel.sh` prefiere el **daemon Go `harnessd`** (multi-máquina, terminales en vivo, sonda de MCP, archivar, liveness) y lo baja del release privado si falta; cae a `server.py` (Python stdlib) si no hay binario. El frontend React viaja COMPILADO en dist/ (la fuente vive en el plugin, `templates/ui/web/`) — el usuario jamás necesita Node |
| `.claude/agents/{architect,implementer,reviewer}.md` | agents/*.tmpl | siempre |
| `.claude/agents/qa.md` | agents/qa.md.tmpl | si hay frontend/mobile o canary |
| `.claude/agents/<abogado>.md` | agents/svc-agent.md.tmpl | UNO por cluster; `status: DRAFT` |
| `.claude/commands/{feature,rfc,implement,review,ship,promote,archive,auto}.md` | commands/*.tmpl | siempre — /auto es el pipeline completo sin intervención humana y acepta ticket O prompt literal (autonomy en answers: full \| checkpoint) |
| `models.yaml` | models.yaml.tmpl | siempre — LA perilla de modelos: provider + aliases (fast\|smart\|deep) por proveedor + rol→alias + overrides por agente |
| `AGENTS.md` | AGENTS.md.tmpl | siempre — el mapa en el estándar multi-herramienta (Cursor, Kimi Code, Codex, Gemini CLI…): leyes, playbooks, modelos, dónde está la verdad. CLAUDE.md sigue siendo el de Claude Code; ambos se generan, ninguno es symlink |
| `scripts/stamp-models.sh` | scripts/ | siempre — materializa models.yaml en el frontmatter de los agentes (`make models`); `resolve <alias\|rol>` lo usan /auto --model y cron-runner |
| `docs/constitution.md` | docs/constitution.md.tmpl | siempre (DRAFT; §6 desde entrevista #11) |
| `specs/<capability>/spec.md` | docs/spec.md.tmpl | UNO por dominio de ownership (esqueleto DRAFT; la arqueología los llena) |
| `docs/harness/testing-policy.md` | docs/testing-policy.md.tmpl | siempre |
| `docs/harness/cronjobs.md` | docs/cronjobs.md.tmpl | si eligió cronjobs |
| `scripts/cronjobs/cron-runner.sh` + `scripts/cronjobs/jobs/<elegidos>.sh` | cronjobs/ | los jobs palomeados en #12 |
| `k8s/cronjobs/<job>.yaml` | cronjobs/k8s-cronjob.yaml.tmpl | si eligió GKE, uno por job |
| `ratchets.json` | inline: `{}` | si eligió ratchet-keeper |
| `scripts/doctor.sh` | COPIA de `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh` | siempre (instancia autocontenida) |
| `scripts/bootstrap.sh` | scripts/bootstrap.sh.tmpl | siempre — {{ENSURE_LINES}} se llena con UNA línea `ensure`/`require` por capacidad elegida, derivando el comando real del campo `install:` del catálogo. REGLA de decisión: la manda el campo `install_kind:` del catálogo, NO tu lectura del texto: `auto` → `ensure <bin> <install>` (auto-instala); `manual` → `require <bin> "<install>"` (solo verifica). Ej.: gcloud (`install_kind: auto`) → `ensure gcloud brew install --cask gcloud-cli`; flutter (`manual`) → `require flutter "https://..."`. Inferirlo del texto fue el bug: un generador que solo reconocía `brew` degradó a `require` 8 de 25 capacidades (npm, pip, go install, uv tool, gcloud components), el bootstrap se declaró terminado sin instalarlas y el doctor las reportó en ❌ con la remediación "corre scripts/bootstrap.sh", que ya se había corrido: bucle sin salida (issue #23). Si una entrada vieja no trae `install_kind`, el fallback es la lista CERRADA de package managers: brew, npm, npx, pnpm, yarn, pip, pip3, pipx, uv, go, cargo, gem, apt-get, apt, dnf, yum, winget, scoop, gcloud → `ensure`; una URL → `require`. Si la entrada trae `post_install:`, añade DESPUÉS de su ensure la línea `command -v <bin> >/dev/null && { <post_install> \|\| true; }` (idempotente, fail-open — ej. graphify registra su skill con `graphify install`) |
| `.claude/skills/skill-creator/SKILL.md` | skills/skill-creator/SKILL.md | siempre — la guía para detectar procedimientos repetidos y empaquetarlos como skills bien formadas; el cronjob skill-miner la sigue |
| `scripts/ship.sh` | scripts/ship.sh.tmpl | siempre |
| `scripts/worktree-task.sh`, `scripts/quiet.sh`, `scripts/with-secrets.sh` | scripts/ | siempre |
| `skills.yaml` | skills.yaml.tmpl | si NO existe (es ley local: declara TUS repos de skills; el update jamás lo pisa) |
| `scripts/skills-sync.sh` | scripts/ | siempre (make skills: instala la capa compartida con marca .managed; la local siempre gana) |
| `scripts/minion-probe.sh` | scripts/ | siempre (patrón MinionS: el supervisor descompone, workers responden en paralelo; activo por carril via `minion_decompose: auto`) |
| `scripts/plan-lint.sh` | scripts/ | siempre: el plan es ejecutable o no es plan, por tarea exige repo/req/archivos/criterios/complexity/deps, cero decisiones abiertas y trazabilidad al delta-spec. Lo corren /rfc y /auto ANTES de implement; un hueco aquí se paga en rondas de review |
| `scripts/pipeline-steps.sh` | scripts/ | siempre (el motor de los pasos custom del pipeline: list/gate; /auto lo llama tras cada fase) |
| `.claude/pipeline/.gitkeep` | inline vacío (Keep) | siempre (dir instance-owned de los pasos custom; el update jamás lo pisa) |
| `.claude/skills/pipeline-step-creator/SKILL.md` | skills/pipeline-step-creator/SKILL.md | siempre (la skill que guía a crear un paso custom) |
| `.claude/skills/harness-bug-report/SKILL.md` | skills/harness-bug-report/SKILL.md | siempre: el protocolo de verificación de un bug DEL HARNESS (¿es real? ¿es del plugin y no de tu instancia? ¿vale la pena arreglarlo?) antes de levantar el issue upstream |
| `scripts/harness-bug.sh` | scripts/ | siempre: el filtro determinista del canal de vuelta: propiedad del artefacto (plugin vs instancia), drift contra el template, versión al día, repro no vacío, dedupe por fingerprint (local + remoto), cuota 3/24h y redacción de secretos. Publica con `gh issue create` en el repo del plugin |
| `docs/harness/pipeline-steps.md` | docs/pipeline-steps.md.tmpl | siempre (el contrato de los pasos custom) |
| `docs/harness/minions-decomposition.md` | docs/minions-decomposition.md | siempre (capacidad MinionS, PROPUESTA/opt-in) |
| `scripts/verdict-scaffold.sh` | scripts/ | siempre (esqueleto determinista del veredicto: el reviewer solo pone juicio; campos mecánicos de fuentes verificables) |
| `scripts/pull-all.sh` | scripts/ | siempre (make pull: clones canónicos al último main en paralelo, sucios se saltan con aviso, dispara graph-refresh) |
| `scripts/repo-brief.sh` | scripts/ | siempre — brief determinista por repo (`.cache/briefs/`); arranque en caliente de implementers/reviewers, $0 tokens |
| `scripts/graph-refresh.sh` | scripts/ | si graphify elegido — el ciclo de vida del grafo: build inicial, `--update` incremental, stamp por HEADs. Sin esto, "usa graphify query" es un consejo vacío. Lo llama el BOOTSTRAP (build inicial en el onboarding, antes de la primera tarea), el prefetch de /auto y /rfc, harness-janitor y `make graph` |
| `scripts/harness-policy.py`, `scripts/evidence.py` | scripts/ | siempre — el policy engine v1 (transiciones por carril, escalate, validate-ship) y evidence v1; ship.sh y /auto los invocan |
| `harness-policy.json` | policy.json | siempre — leyes ejecutables del flujo: transiciones por carril (express\|standard\|full), paradas permitidas, límites |
| `scripts/build-slot.sh` | scripts/ | siempre (semáforo de builds pesados, Ley 8; universal — perl/flock) |
| `scripts/{gowork,py,fe}.sh` | scripts/ | siempre (loop interno nativo, Ley 9; no-op limpio si el stack no está: Go/Python/frontend) |
| `scripts/emit.sh` | scripts/emit.sh | siempre — el bus del harness: lo que ship.sh y /auto DECIDEN. Fail-open, redacta antes de escribir. Sin esto el panel solo ve agentes y tokens (la mitad prestada), nunca las decisiones ni los gates (la nuestra) |
| `scripts/secrets.sh` | scripts/secrets.sh.tmpl | siempre (fuente según answers) |
| `scripts/ticket-pull.sh`, `scripts/ticket-close.sh` | scripts/ticket-*.tmpl | tickets=linear (github: adapta los mismos contratos a `gh issue`) |
| `scripts/deploy-watch.sh` | scripts/deploy-watch.sh.tmpl | si hay CD (gha/argocd/kargo en inventory) |
| `semgrep/rules.yaml` | semgrep-rules.yaml.tmpl | si semgrep elegido |
| `.mcp.json` | campo `config` del catálogo por MCP elegido | si hay MCPs |
| `docs/index.md` | docs/index.md.tmpl | siempre |
| `docs/architecture/map.md` | docs/architecture-map.md.tmpl | siempre (DRAFT; tabla desde 2a/2b-4) |
| `docs/harness/pipeline.md` | docs/pipeline.md.tmpl | siempre |
| `docs/harness/intake.md` | docs/intake.md.tmpl | siempre |
| `docs/quality.md` | docs/quality.md.tmpl | siempre (todo 🟡 hasta arqueología) |
| `docs/adr/ADR-0000-template.md` | docs/adr-template.md | siempre |
| `docs/changelog/.gitkeep`, `docs/services/.gitkeep`, `scripts/smoke/.gitkeep` | — | siempre |

Reglas de generación:
- **Todo script generado pasa `bash -n` ANTES de escribirlo (o justo
  después).** Es el cierre barato de una clase entera de bugs: un valor del
  catálogo interpolado con paréntesis o comillas rompe el parseo del archivo
  COMPLETO, el script no arranca y el síntoma aparece lejos de la causa (el
  doctor culpa a los CLIs faltantes). Pasó de verdad con
  `install: "brew install node (o bun)"`: el bootstrap no instaló nada
  (issue #22). Lo mismo para los `.py` con `python3 -m py_compile`. Un script
  generado que no parsea NO se entrega: se arregla el dato de origen.
- **Constituciones (abogados), constitution.md, specs y map.md son
  DRAFT**: banner "ratificar por humano antes del primer RFC". La ley
  la ratifican humanos.
- **models.yaml y los agentes deben coincidir**: tras generar agentes y
  models.yaml, corre `bash scripts/stamp-models.sh` — resuelve
  alias→ID del proveedor y estampa el frontmatter `model:`. Después el
  humano cambia modelos editando SOLO models.yaml + `make models`
  (nunca los agentes a mano); `stamp-models.sh check` lo vigila desde
  doctor.
- **.mcp.json**: entradas con `wrap: true` en el catálogo se envuelven:
  `command: "scripts/with-secrets.sh"`, `args: [<command>, <args…>]`.
  Engram: fija `--project <slug>` explícito.
- **Perfiles**: respeta `profiles` del catálogo — en los agentes cuyo
  perfil NO incluye un MCP, decláralo en su prompt ("no usas engram").
  Serena→implementer; Engram→orquestador/arquitecto; Playwright→qa.
- En `ship.sh` solo cambian `{{LOOP_BUDGET}}` y `{{GATES_LIST}}`
  (comentario informativo): los gates de lenguaje se autodetectan por
  archivo; semgrep/gitleaks entran si fueron elegidos.
- Ofrece `git init` + commit inicial del workspace (meta-repo) si no es
  repo — el harness se versiona a sí mismo.

## Fase 3.5 — Arqueología ligera (default: SÍ; pide confirmación)

Los abogados y las specs NO se entregan como esqueletos "TBD" — un
abogado sin ownership real no puede litigar y una spec vacía no se
puede citar. Salvo que el humano la rechace (por tiempo/costo), corre
la arqueología ligera:

- Por cada cluster `kind: service`, lanza UN subagente (modelo del rol
  `mechanical` o `implementer`; en paralelo, máx 4 a la vez) que lee
  SOLO lo barato y denso del repo: README, CLAUDE.md propio,
  migraciones/esquema de datos, definiciones proto/rutas expuestas, y
  nombres de directorios top-level. NO lee el código completo.
- Cada subagente devuelve: **Posee / NO posee / Invariantes** reales
  (2-4 líneas c/u, citando evidencia: archivo o tabla) + **3-5
  requirements EARS** del comportamiento actual con un escenario
  Given/When/Then cada uno.
- Con eso rellenas la constitución del abogado y siembras
  `specs/<svc>/spec.md`. TODO queda `status: DRAFT` igualmente: la
  arqueología PROPONE con evidencia, el humano ratifica — pero ahora
  ratifica contenido real, no llena huecos.
- Clusters infra/frontends: una pasada más superficial (qué módulos
  existen, qué consumen) basta.

## Fase 4 — Bootstrap + Verificación

Primero OFRECE correr el bootstrap (instala lo que falta, guía el
token, materializa secretos, CONSTRUYE EL GRAFO de código y termina en
doctor). El orden importa: el grafo se construye antes de que nadie lo
use. Su build inicial tarda minutos y es de una sola vez; si se deja
para la primera tarea, la primera `graphify query` falla contra un
grafo inexistente y el agente cae a grep masivo, que es justo el gasto
que el grafo venía a evitar. Avísale al humano de esos minutos:

```
<workspace>/scripts/bootstrap.sh          # o --check para solo reportar
```

Si el humano prefiere no instalar nada aún, corre solo el doctor:

```
${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh <workspace>
```

Reporta cada resultado. Por cada ❌ da la remediación EXACTA y ofrece
arreglarla ahí mismo. No declares éxito con fallos abiertos. Cierra con:
qué se generó, qué quedó DRAFT pendiente de RATIFICAR (constituciones
ya llenadas por la arqueología, constitution.md §6, map.md), el
bootstrap de secretos si falta (token + `secrets.sh pull`), y los tres
primeros pasos: (1) ratificar lo que la arqueología propuso, (2) correr
UNA feature pequeña end-to-end, (3) profundizar la arqueología de los
dominios 🔴 de quality.md.
