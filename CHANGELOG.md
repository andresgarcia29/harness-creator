# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/). Este archivo empieza
en 0.47.0; la historia previa vive en el log de git (100+ commits iterando
contra una instalación real).

## [Sin publicar]

### Added (tercera corrida de campo: matar el 30% de desperdicio mecánico)
- **La evidencia sobrevive al rebase por identidad de contenido**: el
  manifiesto sella `patch_id` (change-id.sh, fail-open) y `verify` acepta la
  evidencia CITADA cuando su patch_id coincide con el del veredicto; la
  FRESCA sigue SHA-estricta (el pilar del árbol integrado no se afloja). El
  loop de campo (8-9 vueltas de re-sellar + re-scaffold + reviewer nuevo por
  cada movimiento de main) queda en 0 agentes y 1 suite por intento.
- **`verdict-scaffold.sh --merge-qa`**: la fusión qa→veredicto deja de ser
  prosa; valida que hablen del MISMO cambio derivándolo de los EV sellados
  (jamás de una declaración) y aborta con remediación en discrepancia real.
  Era el paso que metía EVs de un TERCER commit al veredicto. El predicado de
  elegibilidad es COMPARTIDO con la selección del scaffold.
- **`--rebase` puro = no-op protector**: mismo patch_id y sin `--renew`, el
  scaffold NO toca el veredicto (regenerarlo reseteaba PENDING_REVIEWER y
  cobraba un reviewer por un movimiento que nadie miró); `--renew` fuerza el
  camino viejo para la ventana vencida.
- **Fase 0 de gates baratos en ship + preflight sin lock**: veredicto,
  compliance, policy y tests-no-debilitados corren ANTES del fan-out caro
  (todos los rojos juntos; un requirements_uncovered de 200ms ya no se
  descubre tras pagar una suite de 10 minutos), y `gate_ship_preflight`
  valida el veredicto ANTES de acquire_lock (un ship condenado ya no mata de
  hambre al vecino, que moría a los 600s).
- **evidence.py toma slot y sella contención**: la suite entra al MISMO
  semáforo que los builds (`HARNESS_TEST_SLOTS`, default max(2, cores/3)) y
  el manifiesto sella `contention` (procesos de test ajenos + load, sampler
  cada 15s); `suspect: true` (ajenos > 0 Y load > cores) no satisface ningún
  gate, con remediación escrita. Caso de campo: la misma suite 503s roja bajo
  once vitest ajenos vs 106s verde, firmada como buena.
- **Reviewer persistente por (tarea, repo)**: la ronda ≥2 es un mensaje al
  MISMO agente con el delta que el scaffold ahora persiste (`delta_files`) e
  imprime listo para pegar; reviewer.md gana el modo sin-memoria
  (rebased_from + delta_files) y el watchdog queda acotado ("ronda siguiente
  no es agente nuevo; el heartbeat sigue siendo ley"). En campo cada ronda
  re-derivaba 70-150k tokens, ~20 veces.
- **Aviso de última ronda del presupuesto de review** (por repo y global) por
  stdout y al bus (kind decision), con el gasto acumulado; la ronda por fin
  viaja al bus en el evento de fase.
- **`scripts/verdict-beads.sh` + `POLICY-ARCHIVE-002`**: non_blocking → beads
  como comando (idempotente, atómico por entrada, honesto sin bd); archive se
  niega si quedan hallazgos sin bead cuando bd existe (tasks/ es gitignoreado:
  archivado sin bead = no existe, Ley 7). La cadena estaba afirmada en cuatro
  archivos y ejecutada en cero.
- **Deploy verify por repo, para TODOS los drivers**: claves planas
  `verify_cmd`/`verify_expect`/`verify_timeout` en el bloque deploy: de
  answers (parser generalizado `answers_repo_key`), ejecutadas también con
  driver none (el caso del infra-live verificado a mano con dos errores) y
  con perl alarm de timeout; el smoke sale del if gitops (con actions no
  corría NUNCA). Los dos primitivos de campo van de ejemplo: leer el asset
  DESDE el pod y comparar pod vs CDN con curl --compressed.
- **`harness-policy.py dag-order` + `scripts/ship-wave.sh`**: el orden del
  DAG por fin ejecutable (dedupe por última aparición del repo, DAG-009
  fail-closed si exige intercalar); la ola salta lo aterrizado, corre ship.sh
  por repo y el hook `post_ship` declarado (publish/bump) bajo with-secrets;
  con flow: prs difiere el post_ship hasta el merge con el retome exacto.
  Caso de campo: la cadena token → publish → bump → deploy corrida a mano
  dejó un eslabón a medias.
- **`scripts/port-forwards.sh`** + bloque `port_forwards:` en answers:
  túneles supervisados (ensure relevanta muertos) con sondas de IDENTIDAD:
  un 200 donde se esperaba 401 se reporta como OTRO proceso en el puerto (el
  port-forward viejo de otra cosa que costó tres specs casi diagnosticadas
  como regresión); curl siempre --compressed. Makefile: forwards/status/down.
- **`secrets.sh doctor`**: cruza lo que los repos declaran necesitar
  (.env.example, process.env en config/, secretKeyRef en charts) contra lo
  provisto (dump_*, .secrets, refs), nombrando quién requiere cada faltante y
  el candidato exacto si la fuente es consultable. Convierte "bloqueado: sin
  acceso" en "faltan tres líneas dump_kv", que en campo fue una diferencia de
  horas.
- **Hook `guard-ws-scripts.sh`**: `scripts/<x>.sh` relativo desde un worktree
  se bloquea SOLO con doble existencia (el harness lo tiene, el worktree no)
  y la línea corregida exacta; 6-8 round-trips perdidos en campo.
- **evidence.py deja de crear task-dirs**: valida que exista y parezca uno, y
  rechaza con la ruta absoluta resuelta (el `--task-dir` relativo desde el
  worktree creaba `./<id>/evidence/` DENTRO del repo y un `git add -A` casi
  commitea 147 líneas de vitest).

### Added (feedback de una corrida de campo de ~9h: 12 puntos, todos con gate o test)
- **Lock de creación por (task, repo) en `worktree-task.sh`**: /auto lanza la
  creación en paralelo y dos procesos podían pasar juntos el chequeo "ya
  existe" (TOCTOU con un fetch en medio); el único punto con riesgo de
  pérdida de datos del feedback. mkdir atómico con reclamo de huérfanos por
  pid, colisión con mensaje y exit en vez de muerte muda (se quitó el
  `2>/dev/null` que la silenciaba), `--rm` purga los locks, y el claim de
  `guard-worktree.sh` ahora se publica con mv (atómico).
- **Rama Terraform en `run_lang_gates`**: `fmt -check -recursive` +
  `init -backend=false` + `validate` por directorio con `.tf` (prof. 4). Los
  repos infra pasaban el precheck sin validar NADA y son los que auto-aplican
  producción al mergear. Sin CLI degrada honesto (patrón `need`); validate no
  cuenta como suite (`TESTS_RAN` intacto).
- **Go en subdirectorios**: `*/go.mod` (prof. 2, sin vendored) corre
  vet/build/test POR módulo. Caso de campo: package.json en la raíz y toda la
  lógica en `controller/`; los tests Go jamás corrían.
- **`POLICY-SHIP-004` ahora cuenta desde `dag.json`**: un repo planificado en
  el DAG sin veredicto bloquea `review → ship` nombrándolo (antes solo
  contaban los repos que YA tenían veredicto y la fase saltaba, dejando al
  resto sin camino). DAG corrupto bloquea (fail-closed); sin DAG (express),
  cero cambio.
- **`init --repos` + `POLICY-LANE-004`**: un carril express que incluye repos
  `infra-module`/`infra-live` (kind del manifest) se rechaza EN EL INIT, antes
  de gastar un implementer en trabajo que `gate_lane` devolvería al final.
  `state.repos` queda registrado.
- **`POLICY-ARCHIVE-001`**: `/archive` se rechaza si `delta-spec.md` es
  posterior al último veredicto: un delta enmendado que ningún reviewer vio no
  se fusiona a las specs maestras (antes dependía de que un reviewer avisara a
  mano).
- **Señal de contexto agotado**: hook `on-compact.sh` (PreCompact, fail-open)
  deja `tasks/<id>/.compacted` y emite al bus; `/auto` checkpointea al verla.
  `record-cost` medía dólares y nada medía ventana.
- **Eje deploy por fin cableado de punta a punta**: bloque `deploy:` por repo
  en harness-answers (antes `answers_driver()` leía una clave que ningún
  generador escribía), la entrevista lo pregunta con evidencia de los
  workflows, y `doctor.sh` marca repos con workflows de deploy cuyo driver
  resuelve a `none` (el hueco que dejó un apply de infra rojo sin vigilar).
- **plan-lint rechaza anclas por número de línea** (`archivo:NN` en
  `archivos:` o en la prosa): los números mueren con el primer rebase (4 veces
  en la corrida de campo), y un sufijo `:NN` esquivaba los patrones `\.sql$`
  del guard de carril. El arquitecto ancla por símbolo.
- **Regla nueva del reviewer**: la prosa normativa (delta-spec, ADR, panel) se
  verifica contra el código con el mismo rigor que el código; una
  discrepancia es blocking. Los tres errores de spec de la corrida salieron de
  leer el código, no el documento.
- **`scripts/mark-read.sh`** (segunda corrida de campo, operada desde otro
  agente): el registro de lecturas para quien NO tiene el hook track-read.
  gate_evidence era impasable fuera de Claude Code (evidence.log no existía
  jamás) y la única salida era editar el log a mano, que anula el gate. El
  script verifica que el archivo exista bajo el workspace o el worktree y
  registra la cita con el formato del hook. El mensaje del gate y el prompt
  del reviewer lo nombran, y el formato de citación (rutas, no IDs; el
  sufijo ::caso se normaliza) quedó documentado en reviewer.md, que antes
  solo se descubría leyendo el source de ship.sh.
- **Reglas nuevas del implementer** (errores de la segunda corrida que una
  regla previene): explorar y auditar SIEMPRE contra el worktree de la tarea,
  nunca contra `repos/` (un canónico 16 commits atrás produjo una auditoría
  de código inexistente); y el lockfile de un registry privado solo lo genera
  CI o el humano, jamás un `npm pack` local (no reproduce los hashes).

### Fixed (misma corrida)
- **`gate_evidence` rechazaba por forma, no por fondo** (4 ships frenados con
  el review correcto): las citas `archivo::caso` (pytest), `:NN` y `#metodo`
  se normalizan antes del chequeo de existencia, y `track-read.sh` registra
  las lecturas hechas por Bash (cat, grep, sed, git show, rg) cuando el token
  resuelve a un archivo real, sin filtro de extensión. El gate castigaba
  exactamente la conducta que la economía de tokens pide. Misma normalización
  en el arrastre de compliance de `verdict-scaffold.sh`.
- **EVIDENCE_ID fantasma** (4 agentes lo pisaron en un día): el ID solo se
  anuncia si el sello sobrevive. `evidence.py` imprime `EVIDENCE_DISCARDED=`
  cuando HEAD se movió, y el precheck filtra la línea cuando borra el sello
  de una corrida sin tests.
- **`guard-build-slot.sh` bloqueaba TEXTO, no comandos**: un `git commit -m
  "fix docker run flags"` o un heredoc que mencionara "docker build" quedaban
  bloqueados. Ahora descarta cuerpos de heredoc y tramos entrecomillados y
  exige `docker` en posición de comando. Estrena test (no tenía ninguno).
- **`answers_driver()` usaba un intervalo ERE `{2}`** que el awk BSD de macOS
  no habilita: si la regla de reset no matchea, el driver de OTRO repo del
  bloque se leía como el propio. Test con dos repos en el bloque.
- **La ley "elimina la causa" se citaba como "Ley 13"** (que es la de repos
  archivados) en /auto y en la suite; es la 15, y el assert ahora ata número y
  texto. Y `LANE_GUARD_PATTERN`, duplicado literal entre plan-lint y
  gate_lane, estrena test de coherencia.
- **#34: `POLICY-SHIP-004` ahora también cuenta desde `state.repos`**: el
  carril express no genera DAG, y una tarea express de dos repos avanzó a
  ship al shippear el primero; el segundo rebotó con TRANSITION-001/SHIP-001
  y costó tres rollbacks. La unión es dag.json + lo que `init --repos`
  registró.
- **`pull-all.sh` decía "todo al día" con repos salteados** (segunda corrida:
  un artefacto untracked dejó un repo 16 commits atrás y el resumen lo tapó).
  El resumen final nombra en rojo los repos NO actualizados con su
  remediación, y la mugre solo-untracked ya no impide el pull (el rebase no
  la toca; se pullea con nota).
- **`evidence.py run` avisa en el acto** cuando el sello no va a servir:
  exit_code distinto de 0 (verify lo exige en 0) o log vacío. Antes se
  sellaba mudo y explotaba dos gates después con un mensaje que hablaba de
  otra cosa.
- **deploy-watch da la remediación del warehouse de Kargo**: si el freight
  nuevo no aparece tras el push, el comando exacto de la anotación
  `kargo.akuity.io/refresh` está en la salida (caso de campo: se descubrió a
  mano).

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
