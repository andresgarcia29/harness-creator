# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/). Este archivo empieza
en 0.47.0; la historia previa vive en el log de git (100+ commits iterando
contra una instalación real).

## [Sin publicar]

### Added
- **`scripts/plan-lint.sh`**: el plan es ejecutable o no es plan. Por tarea
  exige repo/req/archivos/criterios/complexity/deps, prohíbe decisiones
  abiertas (TBD, "por definir", "investigar si") y verifica que cada `req`
  citado exista en el delta-spec. Lo corren /rfc y /auto ANTES de implement:
  un hueco del plan se paga después en rondas de review.
- **`ship.sh --precheck <task> <repo>`**: los mismos gates mecánicos del ship
  (lenguaje, seguridad, tests-no-debilitados) sobre el worktree, sin
  veredicto, sin lock y sin push. Deja sello `precheck-<repo>.json`. El
  implementer lo corre antes de entregar y /review no lanza reviewer ni QA
  en rojo. Un precheck rojo NO consume presupuesto de loop.

- **Canal de vuelta al plugin (regla automática)**: si un agente tropieza con
  un bug del HARNESS (no del código del usuario), lo verifica y levanta el
  issue en este repo, en vez de rodearlo con un workaround que condena al
  siguiente usuario. El juicio lo pone la skill `harness-bug-report` (repro
  dos veces en shell limpia, mínimo y sin tus repos privados; ¿es del plugin
  o de tu instancia?; ¿vale la pena arreglarlo?) y lo verificable lo hace
  `scripts/harness-bug.sh`, fail-closed: propiedad del artefacto, drift
  sha256 contra el template del plugin, versión al día, repro no vacío,
  dedupe por fingerprint (local + búsqueda remota), cuota de 3 issues/24h y
  redacción de secretos (los patrones del bus) antes de publicar. Ley 12 del
  CLAUDE.md y ley 9 del AGENTS.md, decisión pre-aprobada en `/auto`, check en
  doctor, `make bug` / `make bugs`. Es la única acción del harness que publica
  hacia afuera: se declara en la entrevista y se apaga con
  `upstream_issues: off` (o `HARNESS_UPSTREAM_ISSUES=off`).

### Fixed
Los 7 issues de una instalación real con 0.47.0 (#21 a #27), uno por uno:
- **#21 `secrets.sh` inejecutable** (`pull_pull_vault: command not found` en
  toda instalación fresca): el despacho ya no interpola un nombre de función,
  resuelve el VALOR de la fuente.
- **#22 el bootstrap generado no arrancaba**: `install: "brew install node (o
  bun)"` metía paréntesis en el script y rompía el parseo del archivo entero.
  El catálogo deja de admitir prosa en `install:` y el test genera el
  bootstrap con las 44 capacidades y le pasa `bash -n`.
- **#23 capacidades que nunca se instalaban**: `install_kind: auto|manual`
  decide `ensure` vs `require` por dato, no por inferencia sobre el texto
  (8 de 25 caían a require y el doctor mandaba a correr el bootstrap otra
  vez). Y `pip install` pasa a `uv tool install` (PEP 668).
- **#24 kargo apuntaba a una fórmula inexistente** y solo-macOS: fórmula
  correcta + `install_linux`. terraform pasa a `hashicorp/tap/terraform`
  (salió de homebrew-core con BUSL).
- **#25 el grafo vacío que se reportaba sano** (el más serio): build por repo
  + `merge-graphs`, verificación por NODOS en vez de exit code, salida a
  `.cache/graph.log` en vez de `/dev/null`, y el doctor cuenta nodos en vez
  de comprobar que el archivo exista.
- **#26 el doctor confundía comentarios con declaraciones**: avisaba por una
  ref `env://` del ejemplo comentado del propio template.
- **#27 `.gitignore` divergido**: pasa a ser `templates/gitignore.tmpl`
  (canónico y testeado); faltaban `graphify-out/` (128 MB entrando a git),
  `go.work` y `go.work.sum`.

### Changed
- **El grafo de código se construye en el onboarding** (`bootstrap.sh` /
  `make init`), antes del doctor y antes de la primera tarea. El build
  inicial tarda minutos y es de una sola vez: dejarlo para la primera
  `graphify query` hacía que esa query fallara contra un grafo inexistente y
  el agente cayera a grep masivo, gastando justo los tokens que el grafo
  venía a ahorrar, y en medio del trabajo. Fail-open: sin graphify elegido,
  silencio; con `--check` solo reporta si el grafo existe.
- **El architect es un hilo fino que piensa hondo**: sus planes se escriben
  en modo `ultrathink` (igual la síntesis del RFC, el mini-plan express y
  los ADRs; el loop de edición NO lo usa), y su contexto son briefs, grafo y
  el pack de probes, nunca volcados de código. Si le falta un hecho emite
  otra probe, no abre el archivo. Máximo 2 rondas de probes.
- **MinionS pasa a activo por carril**: `minion_decompose: auto` (ON en
  standard/full, OFF en express). `true`/`false` siguen forzando.
- **El reviewer entrega la lista de blocking COMPLETA en la ronda 1**: los
  hallazgos tardíos van marcados `[tardío]` y los `non_blocking` se vuelven
  beads de seguimiento, nunca otra ronda. El reporte final de /auto cuenta
  rondas por tarea, prechecks rojos y blocking tardíos.

## [0.47.0] · 2026-07-21

### Added
- **Carriles por blast radius** (express | standard | full): el pipeline se
  dimensiona a la tarea: express salta el RFC (2 sesiones LLM) y `gate_lane`
  en ship.sh verifica que el diff cumpla la promesa del carril; `escalate`
  sube de carril conservando el worktree. Transiciones por carril en el
  policy engine (`harness-policy.py`, `harness-policy.json`).
- **Gates de ship.sh en paralelo**: lang ∥ security ∥ tests-no-debilitados ∥
  veredicto+evidencia; los rojos se reportan JUNTOS (un solo prompt de fix).
- **Reviewer ∥ QA** en /review (qa escribe `qa-<repo>.json`, merge mecánico)
  y re-review incremental en rondas ≥2.
- **Modelos: una perilla**: `models.yaml` con aliases `fast|smart|deep` por
  proveedor (anthropic/vertex/bedrock/kimi/openrouter), rol→alias, overrides
  por agente; `scripts/stamp-models.sh` (stamp/resolve/check) + `make models`;
  `--model <alias>` por tarea en /auto.
- **AGENTS.md multi-herramienta**: el mapa del workspace en el estándar que
  leen Cursor, Kimi Code, Codex, etc.; comandos como playbooks portables.
- **skill-creator** (guía de skills de instancia) + cronjob **skill-miner**
  (detecta procedimientos repetidos → skills vía PR).
- **Ciclo de vida del grafo de graphify**: `scripts/graph-refresh.sh`
  (build inicial, `--update` incremental, stamp por HEADs) llamado desde el
  prefetch de /auto//rfc, harness-janitor y `make graph`; check en doctor.
- **Arranque en caliente**: `scripts/repo-brief.sh` (brief determinista por
  repo, cacheado por HEAD) + prefetch de worktrees/deps durante el RFC.
- **Watchdog por heartbeat** (~3 min sin tool calls) con relanzamiento ya
  escalado de modelo.
- **Gates activados por config**: import-linter, go-arch-lint y squawk
  (migraciones SQL nuevas) en ship.sh.
- Cadenas completas para herramientas del catálogo que solo se citaban:
  trivy en vuln-watch, stryker en mutation-sentinel, semble en CLAUDE.md,
  k6 en qa, check de beads en doctor, `post_install` (graphify install).
- OSS: LICENSE (MIT), CI matrix macOS (bash 3.2 real) + shellcheck,
  CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, issue templates, README.en.md,
  tests de `discover.sh` y `doctor.sh`.

### Changed
- `/harness-update`: paquetes atados (carriles y modelos se aceptan/rechazan
  juntos), migración de esquema de models.yaml, propiedad de archivos
  ampliada (policy engine, cron-runner, scripts nuevos).
- `cron-runner.sh` resuelve aliases de modelo vía stamp-models (con fallback
  a IDs crudos).
- Escalación de modelo más temprana: 1 fail de comprensión basta.

### Fixed
- La tabla de generación no registraba `harness-policy.py`, `evidence.py` ni
  `harness-policy.json` (instalaciones nuevas quedaban sin policy engine).
- Trap EXIT de subshell bajo `set -e` perdía locals (bash 3.2 y 5.x) en los
  gates paralelos de ship.sh.
- qa.md escribía el campo `qa` del veredicto (carrera con el reviewer
  paralelo); ahora escribe su propio artefacto.
