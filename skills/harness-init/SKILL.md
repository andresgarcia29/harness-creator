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
  5. Nada se pisa sin confirmación. Al final actualiza `.harness-version`.
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
10. **Modelos**: propone el sandwich — architect/reviewer/abogados el
    modelo de razonamiento más alto disponible, implementer el medio,
    mechanical el barato, y el modelo de ESCALACIÓN del implementer
    (regla: el gasto en razonamiento es proporcional al fan-out del
    artefacto). Va a `models.yaml` (política) y al frontmatter de los
    agentes. `loop_budget` default 3.
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

## Fase 3 — Generación

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
| `.gitignore` | inline: `repos/ worktrees/ locks/ .cache/ .secrets .secrets.d/ inventory.json` | siempre |
| `.claude/settings.json` | settings.json.tmpl | siempre (hooks + denials read-only) |
| `.claude/hooks/{block-direct-push,guard-canonical}.sh` | hooks/ | siempre |
| `.claude/agents/{architect,implementer,reviewer}.md` | agents/*.tmpl | siempre |
| `.claude/agents/qa.md` | agents/qa.md.tmpl | si hay frontend/mobile o canary |
| `.claude/agents/<abogado>.md` | agents/svc-agent.md.tmpl | UNO por cluster; `status: DRAFT` |
| `.claude/commands/{feature,rfc,implement,review,ship,promote,archive}.md` | commands/*.tmpl | siempre |
| `models.yaml` | models.yaml.tmpl | siempre (política de ruteo de modelos) |
| `docs/constitution.md` | docs/constitution.md.tmpl | siempre (DRAFT; §6 desde entrevista #11) |
| `specs/<capability>/spec.md` | docs/spec.md.tmpl | UNO por dominio de ownership (esqueleto DRAFT; la arqueología los llena) |
| `docs/harness/testing-policy.md` | docs/testing-policy.md.tmpl | siempre |
| `docs/harness/cronjobs.md` | docs/cronjobs.md.tmpl | si eligió cronjobs |
| `scripts/cronjobs/cron-runner.sh` + `scripts/cronjobs/jobs/<elegidos>.sh` | cronjobs/ | los jobs palomeados en #12 |
| `k8s/cronjobs/<job>.yaml` | cronjobs/k8s-cronjob.yaml.tmpl | si eligió GKE, uno por job |
| `ratchets.json` | inline: `{}` | si eligió ratchet-keeper |
| `scripts/doctor.sh` | COPIA de `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh` | siempre (instancia autocontenida) |
| `scripts/bootstrap.sh` | scripts/bootstrap.sh.tmpl | siempre — {{ENSURE_LINES}} se llena con UNA línea `ensure`/`require` por capacidad elegida, derivando el comando real del campo `install:` del catálogo (brew en macOS; `require` para SDKs pesados: flutter, gcloud, kubectl) |
| `scripts/ship.sh` | scripts/ship.sh.tmpl | siempre |
| `scripts/worktree-task.sh`, `scripts/quiet.sh`, `scripts/with-secrets.sh` | scripts/ | siempre |
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
- **Constituciones (abogados), constitution.md, specs y map.md son
  DRAFT**: banner "ratificar por humano antes del primer RFC". La ley
  la ratifican humanos.
- **models.yaml y los agentes deben coincidir**: el frontmatter
  `model:` de cada agente se estampa desde models.yaml; si el humano
  cambia la política después, /harness-update re-estampa.
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
token, materializa secretos y termina en doctor):

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
