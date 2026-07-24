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

### Changed
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
