# harness-creator

Plugin de Claude Code que instala y mantiene un **harness de ingeniería
agéntica multi-repo**: topología de agentes dimensionada a tus repos
(clustering dinámico), gates deterministas (ship.sh), hooks que hacen
cumplir las leyes, catálogo de capacidades (CLIs y MCPs con tiers de
permiso), pipeline completo (/feature → /rfc → /implement → /review →
/ship → /promote), memoria episódica, puente de tickets y
documentación viva.

Filosofía: **los agentes proponen, los sistemas deterministas
verifican.** El instalador la cumple: discovery y verificación son
scripts; el modelo solo pone juicio en topología, entrevista y
generación. Y las leyes del harness generado no son prosa: tienen hook
(push directo a main bloqueado, clon canónico protegido) o gate
(trailers, buf breaking, gitleaks, semgrep, veredicto de review).

## Instalación

```
/plugin marketplace add andresgarcia29/harness-creator
/plugin install harness-creator@harness
```

## Uso

```
mkdir mi-workspace && cd mi-workspace
git clone <tus repos> repos/   # o deja que el init te guíe
claude
/harness-init .
```

Flujo: **discovery** (script, cero tokens: lenguajes, señales y ROL por
repo) → **clustering** (el instalador propone cuántos agentes crear:
un abogado por servicio con datos; UNO para 20 terraform modules, no
20) → **entrevista** (recomienda con evidencia, tú decides — incluye
tier de permisos por capacidad) → **generación** (30+ archivos desde
templates) → **verificación** (doctor.sh con remediaciones).

## Comandos

- `/harness-init <ws>` — instalación completa
- `/harness-doctor <ws>` — salud (CLIs, MCPs, hooks, links, secretos)
- `/harness-update <ws>` — sincroniza mejoras del template a la
  instancia sin pisar personalización local

## Estructura

```
.claude-plugin/   manifest + marketplace
commands/         /harness-init /harness-doctor /harness-update
skills/           harness-init (el cerebro: clustering + entrevista + generación)
catalog/          capabilities.yaml — el menú (cli|mcp|script, bin, tier, profiles, detect)
scripts/          discover.sh, doctor.sh (deterministas, portables macOS/Linux)
templates/        CLAUDE.md, ship.sh, agentes, comandos de pipeline,
                  hooks, docs/, tickets, deploy-watch, secretos, Makefile
```

## Qué genera en la instancia

Workspace autocontenido y versionable: `CLAUDE.md` (mapa ≤110 líneas) ·
`manifest.yaml` · `models.yaml` (política de ruteo de modelos con
escalación) · agentes (arquitecto, reviewer, implementer, qa +
abogados por cluster, DRAFT hasta ratificar) · comandos del pipeline
(incluye `/archive`, el cierre del ciclo SDD) · capa SDD
(`docs/constitution.md`, `specs/<capability>/` con requirements EARS +
Given/When/Then, delta-specs por RFC, compliance matrix como gate) ·
`scripts/` (ship, worktree, doctor, quiet, with-secrets, secrets,
tickets, deploy-watch) · **cronjobs self-healing** (cron-runner con
circuit breaker + 12 jobs: ci-doctor, dep-shepherd, vuln-watch,
flake-warden, daily-digest, dead-code-reaper, ratchet-keeper,
mutation-sentinel, doc-gardener, slo-watchdog, harness-janitor,
rule-miner) · hooks de enforcement · `.mcp.json` ·
`semgrep/rules.yaml` · `docs/` (index, ownership, pipeline, intake,
testing-policy, cronjobs, quality, ADRs, changelog) · `Makefile`.

## Principios heredados en cada instancia

- Economía de tokens: quiet.sh, grafo antes que grep, edición
  simbólica, context7, estado en archivos, ccusage como báscula.
- Secretos: una sola costura (with-secrets.sh); valores jamás en repo
  ni en chat; solo referencias (vault:// | gcp-sm:// | env://).
- Rollback primero, diagnóstico después. Camino verde = cero tokens.
- La memoria propone, git dispone (/promote semanal).

## Iteración

v0.2 nace de la topología Corvux (Go gRPC + Python + TS/Vite + Flutter,
GKE + ArgoCD + Kargo + Vault, trunk direct-to-prod) pero el flujo es
genérico: generalizar = agregar entradas al catálogo y reglas de
clustering, no tocar las fases.
