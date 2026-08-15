# Plan de endurecimiento

Estado de los 34 hallazgos de la auditoría del 2026-07-25 (todos cerrados),
más los 16 que se arreglaron ese mismo día y los 2 que aparecieron durante los
arreglos. Este archivo es la cola de trabajo: se tacha lo hecho
y se agrega lo nuevo. Un hallazgo sin test que lo fije no cuenta como cerrado.

## La regla que los une

**El harness confunde "no pude mirar" con un veredicto.** Cambia solo qué
veredicto inventa:

| Forma | Costo |
|---|---|
| No pude mirar, reporto **verde** | falsa seguridad: lo que no se verificó se lee como verificado |
| No pude mirar, reporto **rojo** | rondas quemadas, y el agente aprende a desconfiar de los gates |
| No pude mirar, propongo algo **destructivo** | el más caro: una lectura equivocada se convierte en daño |
| El gate exige lo que ningún prompt pidió | el agente falla por un contrato que nadie le comunicó |
| La perilla miente | se configura y no pasa nada |
| Un eje cableado a un vendor | el instalador universal es el instalador de quien lo escribió |

**La marca mecánica**, útil para buscar a ciegas: un `2>/dev/null` que se traga
el motivo, un `|| true` que se traga el exit code, o un `if [ -f x ]` sin
`else`. Casi todos los hallazgos tienen uno de los tres.

**El patrón del arreglo**: en más de la mitad de los casos, la solución correcta
ya existía en el mismo archivo, tres líneas más abajo. `secrets.sh` tiene
`finish()` y solo GCP no la llama. `import-linter` avisa cuando falta su
herramienta y `squawk`, su vecino, no. `skills-sync.sh` resuelve la rama por
defecto con `origin/HEAD` mientras `ship.sh` cablea `main` catorce veces. No es
falta de conocimiento: es que la regla estaba en prosa y no en un test.

---

## P0: destruyen trabajo o publican código sin verificar

- [x] **Los gates de lenguaje solo cubrían cuatro stacks.** Rust, Java, Ruby,
  PHP, .NET y Elixir pasaban el precheck en verde con el build roto y `ship.sh`
  los pushaba a main. Se agregaron los seis y, sobre todo, el caso "no reconozco
  el stack" dejó de pasar callado. `ship.sh.tmpl`. Commit `62fe730`.
- [x] **`worktree-task.sh --rm` borraba commits sin publicar.** `branch -D`
  fuerza el borrado ignorando si hay trabajo sin mergear; en multi-repo, el
  `--rm` que corre `/ship` destruía la rama lista del repo que faltaba. Commit
  `89de5e9`.
- [x] **`gitleaks` corría sin `command -v`.** Quien no lo eligió tenía todo ship
  en rojo con exit 127, y el bootstrap no lo instalaba porque no fue elegido.
  Commit `62fe730`.
- [x] **`deploy-watch` revertía el sha del repo equivocado.** `tail -1` de
  `ship.log` sin filtrar por repo. Commit `98fdd56`.

## P1: mienten sobre haber verificado (cerrado)

- [x] **`secrets.sh` con GCP Secret Manager reportaba `✅` con todas las claves
  fallidas.** `dump_sm` no incrementa `MISSED` y `pull_gcp_sm` cierra con un
  `✅` fijo en vez de llamar a `finish()`, que es justo lo que Vault y AWS sí
  hacen. Con gcloud sin autenticar, `.secrets` queda vacío y el script sale 0.
  *Arreglo*: dos líneas, copiando el patrón del vecino.
  `templates/scripts/secrets.sh.tmpl:47-58`.
- [x] **`vuln-watch` sin red reportaba "limpio" y destruye la baseline.** El
  `|| true` se traga el fallo de osv-scanner, el archivo del día queda vacío, y
  la línea 27 sobreescribe la baseline con él. Al día siguiente, todas las
  vulnerabilidades preexistentes reaparecen como nuevas y el agente abre una
  tanda de PRs duplicados. *Arreglo*: distinguir "el scan falló" de "no hay
  nada", y no tocar la baseline en el primer caso.
  `templates/cronjobs/jobs/vuln-watch.sh:12-14,27-28`.
- [x] **`squawk` se saltaba en silencio, y el catálogo nunca lo ofrece.** Doble
  agujero sobre la misma migración: el gate se salta si el binario no está (a
  diferencia de `import-linter`, su vecino, que sí avisa), y el `detect:` del
  catálogo pide una señal de migraciones que el discovery no emite, así que
  nunca se recomienda instalarlo. *Arreglo*: avisar honesto en el gate, y
  agregar la señal `migrations` a `discover.sh`.
  `ship.sh.tmpl:305-309`, `catalog/capabilities.yaml:654`.
- [x] **`ci-doctor` con un forge que no sea GitHub reportaba "limpio".** El
  `gh run list` falla en silencio con GitLab, Bitbucket o Gitea, y el job
  registra "detector limpio": CI rojo invisible.
  `templates/cronjobs/jobs/ci-doctor.sh:15-21`.
- [x] **El doctor nunca validaba la vigencia del token de Vault.** Busca
  `vault_addr:` en `harness-answers.yaml`, pero el esquema canónico (declarado
  FIJO) solo tiene `source:` y `refs:`. La variable sale vacía siempre y cae a
  "token presente (sin validar)", que es exactamente lo que el README jura que
  no pasa. `scripts/doctor.sh:140,151`.
- [x] **`mutation-sentinel`: "existe npx" cuenta como "hay herramienta de
  mutación".** El skip honesto es casi inalcanzable, así que un ciclo donde no
  se mutó nada se registra como limpio.
  `templates/cronjobs/jobs/mutation-sentinel.sh:11-15`.
- [x] **`rule-miner`: una de sus dos señales estaba estructuralmente muerta.** El
  `grep '"blocking"' | jq` entrega una línea suelta de un JSON pretty-printed,
  que no es un documento válido; jq falla y el `2>/dev/null` lo silencia. La
  señal produce cero líneas siempre. *Arreglo*: correr jq sobre los archivos,
  sin grep. `templates/cronjobs/jobs/rule-miner.sh:18-20`.
- [x] **El doctor no avisaba si falta `.mcp.json`.** El bloque que verifica los
  MCPs elegidos está condicionado a que el archivo exista y no tiene `else`.
  Con MCPs declarados en answers y el archivo ausente, el doctor sale verde y
  los agentes arrancan sin ningún servidor. `scripts/doctor.sh:65-78`.

## P1: el gate exige lo que ningún prompt pidió (cerrado)

- [x] **`dag.json`: `validate-dag` lo exige y nadie manda a crearlo.** Ningún
  prompt lo nombra ni define su esquema; las únicas menciones en todo el repo
  son el validador y la línea de `/auto` que lo invoca. Toda corrida
  standard/full llega al cierre del RFC sin el archivo.
  `harness-policy.py:281-316` contra `architect.md.tmpl` y `rfc.md.tmpl`.
- [x] **El flujo manual muere en policy.** `/feature`, `/rfc` e `/implement` no
  mencionan `harness-policy.py` ni una vez, así que `state.json` nunca se crea
  ni avanza, y la transición que `/review` sí pide falla. `AGENTS.md` vende esos
  comandos como playbooks autosuficientes.
- [x] **`/ship` y `/archive` nunca solicitan sus transiciones.** Tras un ship y
  archive manuales, `state.json` queda clavado en `review` con la tarea ya
  archivada, y un `/auto <task-id>` posterior re-entra a revisar algo que ya
  está en producción.
- [x] **El delta-spec express solo se escribe con `## ADDED`, pero
  `gate_tests_untouched` solo acepta declaraciones bajo MODIFIED/REMOVED.** Una
  tarea express que legítimamente cambia un test existente queda roja, y quien
  escribió el delta-spec nunca supo que el mecanismo de declaración existía.
  `auto.md.tmpl:96-99` contra `ship.sh.tmpl:410-415`.

## P2: perillas que no hacen nada (cerrado)

- [x] **`flow: prs | trunk-staging` no lo lee nadie.** `ship.sh` hace
  `git push origin HEAD:main` incondicional. Quien eligió "prs" por política de
  su empresa recibe commits directos a main, en silencio.
- [x] **Degradar el tier de un MCP no cambia nada.** El `.mcp.json` se genera
  copiando el `config` del catálogo tal cual, y nadie lee `tier:`. El usuario
  cree que revocó escritura y el servidor sigue con capacidad completa. Es la
  perilla muerta con perfil de seguridad más alto.
- [x] **`memory.profiles` es una perilla muerta.** Se pregunta, se registra, y
  el `CLAUDE.md` generado hardcodea la respuesta por defecto.
- [x] **`{{MODEL_ESCALATION}}` es un placeholder sin fuente.** Nadie lo
  pregunta, el answers no lo registra, y el camino determinista
  (`harness generate --answers`) no tiene con qué sustituirlo. Si queda literal,
  la escalación por atasco y los cronjobs caros revientan en runtime.

## P2: ejes cableados a un vendor (regla 8) (cerrado)

- [x] **La rama trunk se asume `main`.** Catorce ocurrencias en `ship.sh` y seis
  en `worktree-task.sh`, sin `BASE_BRANCH` ni lectura de `origin/HEAD`. Rompe
  cualquier repo con `master`, `trunk` o `develop`, y de paso
  `block-direct-push` tampoco protege esas ramas. *Nota*: `skills-sync.sh:52` ya
  usa la técnica correcta.
- [x] **Los 13 cronjobs cablean GitHub como forge y como CI.** El prompt
  inyectado ordena "entrega PR o issue vía gh" a todos, y la entrevista nunca
  pregunta cuál es tu forge.
- [x] **El CronJob de Kubernetes fuerza Vertex.** `CLAUDE_CODE_USE_VERTEX=1` y
  `ANTHROPIC_VERTEX_PROJECT_ID` incondicionales, contradiciendo el eje de
  modelos que sí despacha seis proveedores.
  `templates/cronjobs/k8s-cronjob.yaml.tmpl:35-38`.
- [x] **`kubectl` se instala con `gcloud`.** Herramienta neutral con canal de
  instalación cableado a GCP, sin `install_alt`. En EKS, AKS u on-prem la
  instalación revienta. `catalog/capabilities.yaml:134`.
- [x] **El `detect:` del catálogo pide señales que el discovery no emite.**
  squawk, goose, sentry, prometheus, k6 y GKE filtran por señales inexistentes,
  así que capacidades correctas nunca se ofrecen aunque la evidencia esté en los
  repos.
- [x] **El eje de tickets solo tiene implementación para Linear.** Para
  `tickets: github` la tabla dice "adapta los mismos contratos", o sea un script
  improvisado sin template ni test. Jira y GitLab no son opción.

## Encontrados durante los arreglos

- [x] **Una rama base inválida hacía que TODOS los gates de diff pasaran en
  verde.** `gate_tests_untouched`, `gate_lane` y el de migraciones envuelven su
  git en `|| true` para tolerar un repo sin cambios; con una ref inexistente
  git falla, el `|| true` se lo traga, el diff sale vacío y todos pasan sin
  mirar nada. El precheck imprimía "✅ precheck verde". Desarmaba justo el gate
  anti-trampa. Ahora la rama base se valida al arranque, con un fetch de
  cortesía antes de rendirse.
- [x] **`[ -n "$X" ] && VAR=...` bajo `set -e` mata el script.** El AND-list
  devuelve 1 cuando la condición es falsa, y `set -e` lo toma como fallo: el
  precheck salía con exit 128 sin imprimir una línea. Se usa `if`.

## P2: concurrencia (diez sesiones sobre el mismo workspace)

- [x] **`graph-refresh.sh` escribe el grafo sin `tmp+mv` y sin lock.** Lo lanzan
  en background el prefetch de `/auto`, `/rfc`, `pull-all.sh` y el janitor, así
  que la concurrencia es el caso normal. Un lector ve JSON a medio escribir.
  Además `: > "$LOG"` trunca el log mientras otra instancia le escribe.
- [x] **`repo-brief.sh` escribe sin `tmp+mv` y se regenera en estampida.**
  `minion-probe.sh` lo invoca desde workers en paralelo y luego hace `cat`: un
  brief truncado viaja dentro del prompt del implementer como si fuera verdad.
- [x] **`skills-sync.sh` hace `rm -rf` + `cp -R` sobre skills vivas**, y si
  muere entre medio la skill queda instalada sin su marca `.managed`, o sea que
  el próximo sync la trata como local y ya nadie la actualiza jamás.
- [x] **El dedupe de `harness-bug.sh` tiene dos llamadas de red entre el chequeo
  y la escritura del ledger.** Diez sesiones tropezando con el mismo bug del
  plugin (que es exactamente el escenario) pasan todas los tres controles antes
  de que la primera escriba: issues duplicados en el repo público.
  Lo cerró un claim local atómico sobre la huella antes de la primera llamada de
  red (misma máquina) más la reconciliación post-create por el orden del forge
  (gana el número menor, el mayor se cierra solo enlazando al superviviente),
  fijado por `tests/test_harness_bug.sh`.
- [x] **`stamp-models.sh` usa un temporal con nombre fijo** al reescribir los
  agentes. Ventana de milisegundos, pero el costo es un frontmatter corrupto y
  el arreglo es `mktemp`, que otros scripts del repo ya usan.

## P2: acciones destructivas con diagnóstico frágil (cerrado)

- [x] **El prune de `skills-sync.sh` desinstala skills si falla la red.** La
  lista de "declaradas" solo se puebla si la fuente se pudo leer; un fetch
  fallido hace `continue` y el prune corre igual, tratando la evidencia ausente
  como evidencia de desinstalación.
- [x] **`flake-warden` puede poner en cuarentena el test vecino.** El
  `grep -B0 -A2 '<failure'` captura nombres de testcases que pasaron, y el
  prompt ordena cuarentena inmediata del señalado, con un agente headless en
  `--permission-mode dontAsk`.
- [x] **El reclamo de locks huérfanos confunde "no pude mirar" con "el dueño
  murió".** `kill -0` también falla con pid vacío y con EPERM (proceso de otro
  usuario); el `2>/dev/null` borra la diferencia y se libera un lock vivo, o sea
  dos ships concurrentes del mismo repo. `ship.sh.tmpl:108-110`, y el mismo
  patrón en el job `harness-janitor.sh` del repo **aparte**
  `andresgarcia29/harness-cronjobs` (no vive en este repo: citarlo por
  número de línea desde acá hacía pensar que sí).
- [x] **`gh run list --limit 1` puede vigilar el run anterior.** En la ventana
  entre el push y la creación del run, devuelve el run previo; si ese estaba
  rojo, `red()` declara rojo un deploy que ni siquiera arrancó y propone
  revertirlo. `deploy-watch.sh.tmpl:155-158`.

---

## P0: el trunk caliente (varios workspaces, un solo main)

Auditoría del 2026-07-25 bajo la topología real: ~10 instalaciones del harness,
una por persona, todas contra los mismos repos remotos y pusheando seguido.
Bajo ese supuesto varios "riesgos" resultaron ser el estado normal.

**La regla que los une**: todos los gates se anclan a `origin/<trunk>`, que es
una referencia MÓVIL, y entre "verifiqué" y "pusheé" hay un Δ de varios
minutos. Con un workspace Δ no importa. Con diez, Δ es donde se muere todo.

- [x] **El rebase de `ship.sh` invalidaba el veredicto y la evidencia, siempre.**
  `git rebase` corre ANTES de `run_parallel_gates`, y `gate_policy_and_evidence`
  comparaba el HEAD post-rebase contra el commit al que el veredicto quedó
  sellado. Cualquier push ajeno reescribía los SHA y tiraba review + QA +
  evidencia: `POLICY-SHIP-002`, exit 3, sin llegar nunca al loop de reintentos.
  O sea que casi ningún ship pasaba a la primera y cada fallo costaba un ciclo
  completo de juicio de LLM. *Arreglo*: el veredicto se ancla a la identidad
  del CAMBIO (`scripts/change-id.sh`, `git patch-id --verbatim` sobre el diff
  contra el merge-base), no al SHA. `validate-ship` lo reusa dentro de una
  ventana (`ship.verdict_reuse`: 24h y 200 commits de base por default).
  Reproducido y fijado en `tests/test_rebase_survival.sh`.
- [x] **`--verbatim` no es un detalle.** `git patch-id` a secas IGNORA el
  whitespace: dos cambios de Python con 2 y 4 espacios de indentación daban el
  mismo id (verificado). Anclar ahí habría permitido re-indentar DESPUÉS del
  review conservando el `pass`, en un harness cuyo diseño entero es
  anti-manipulación. Con `--verbatim` se distinguen, y hay fallback para git
  <2.39 que tampoco es ciego al whitespace.
- [x] **La prueba y el juicio eran la misma afirmación, y no lo son.**
  `evidence.py verify` exigía que TODA la evidencia fuera del commit que se
  pushea, así que un rebase la invalidaba entera. Ahora son dos: la evidencia
  REVISADA se valida contra `verdict.commit` ("el reviewer juzgó con pruebas
  reales de lo que juzgó") y la evidencia FRESCA contra el HEAD que aterriza
  ("este árbol pasa la suite"). `ship.sh` produce la fresca él mismo sellando
  la corrida de `run_lang_gates` que ya hacía. El juicio se reusa; la prueba
  jamás.
- [x] **La suite corría CUATRO veces por tarea sin un solo rework** (precheck,
  evidencia del implementer, QA determinista, ship). Ahora el precheck sella su
  propia corrida como evidencia y el ship sella la suya: dos, y las dos prueban
  algo distinto.
- [x] **El presupuesto de push era el de rondas de review.** `MAX_RETRY={{LOOP_BUDGET}}`:
  tres movimientos de main en una ventana ocupada agotaban el "presupuesto" y
  escalaban a humano por pura contención. Ahora `PUSH_RETRY_BUDGET` propio (20)
  con backoff exponencial y JITTER, porque sin jitter los que pierden la misma
  carrera reintentan en fase y se vuelven a pisar.
- [x] **`trailer` y `carril` solo existían en el camino de ship.** Un commit sin
  `Task:` o un express que tocó un `.proto` se descubrían después de pagar
  review y QA. Peor: la remediación del trailer es un amend, que mueve HEAD y
  por lo tanto invalida lo que se acaba de pagar. Ahora corren en `--precheck`,
  donde el mismo arreglo cuesta cero, y el carril se verifica ANTES incluso, en
  `plan-lint.sh`, contra los `archivos:` que el plan declara.
- [x] **`deploy-watch` estaba ciego en la etapa de Actions desde que se
  escribió.** Usaba `git -C "$WT"` y `$WT` NUNCA se define en el archivo; con
  `set -u` la sustitución moría entera, `head_sha` quedaba vacío y las dos
  ramas siguientes estaban guardadas por `[ -n "$head_sha" ]`: ni vigilaba el
  run ni emitía el aviso. Con `driver: actions` el deploy nunca se verificó, y
  de paso el arreglo de la carrera del `--limit 1` era código muerto. Ahora el
  sha sale de `ship.log` (que además pasó a guardarlo COMPLETO: la API del
  forge devuelve el completo y con el corto la comparación no matcheaba nunca).
- [x] **El rollback podía revertir tu commit por el deploy rojo de OTRO.** Con
  varios pusheadores, cuando el watcher ve rojo el trunk ya trae commits
  ajenos. Ahora compara `.status.sync.revision` contra tu sha y, si la revisión
  enferma no es tuya, no propone nada; y ensaya el revert en seco
  (`git revert --no-commit`) para detectar si alguien construyó encima, en cuyo
  caso PARA en vez de proponer una acción destructiva.
- [x] **Dos workspaces podían tomar el mismo ticket.** `ticket-pull.sh` hacía
  check-then-act: leía `agent-ready` y movía el label después. Ahora el claim
  usa lo único que los workspaces comparten (el tracker) y lo único que el
  servidor ordena de forma total (sus comentarios): todos publican su claim y
  gana el primero registrado. Exit 5 si perdés. El comentario además dice QUÉ
  workspace lo tomó, cosa que "tomado por el harness" nunca dijo.
- [x] **Los task-ids `AUTO-*` colisionaban entre máquinas.** El chequeo de
  unicidad solo mira el `tasks/` local y el trailer `Task:` viaja al main
  compartido. Lleva sufijo de identidad.
- [x] **Los trece cronjobs corrían en las diez máquinas**, entregando PRs
  duplicados a repos compartidos con un circuit breaker local. Perilla
  `cronjobs.run_on` (`any` | hostname | `k8s`), cableada en la entrevista.
- [x] **El presupuesto de rondas de review era por TAREA.** Tres repos con UN
  fix normal cada uno agotaban el presupuesto y escalaban a humano sin que nada
  estuviera mal. Ahora se cuenta por repo (`review_rounds_by_repo`), y
  `review_rounds` se conserva como el máximo para no romper lo que ya lo lee.
- [x] **`--rebase` re-emitía `qa: "pending"` siempre**, así que cada ronda de
  rework pagaba un ciclo de QA entero aunque el fix fuera un nil check, y la
  promesa de `/review` ("QA solo se repite si el fix tocó lo que QA ejercita")
  era incumplible. Ahora QA declara `surface[]` y el arrastre es mecánico.
  Sin `surface[]` se re-corre siempre: fail-closed.
- [x] **`ship.required_evidence_kinds` y `ship.require_fresh_evidence` no los
  leía nadie** (ship cableaba `--require-kind test`): perillas muertas de la
  misma clase que `flow`. Ahora `harness-policy.py evidence-policy` las sirve y
  ship construye sus flags desde ahí.
- [x] **La baseline de `buf breaking` envejecía.** `--against` lee los refs de
  `repos/<repo>`, que solo se refrescan con `pull-all.sh`, mientras el worktree
  se fetchea en cada ship. Con main caliente los dos "main" divergen en
  minutos. Se fetchea la baseline antes de comparar.
- [x] **Nada en el remoto decía con qué harness se shippeó.** Los gates corren
  en la laptop del que pushea; un workspace atrasado shippea con gates más
  débiles y su commit queda indistinguible. `ship.sh` deja una git note
  (`refs/notes/harness`) con versión, hash del manifest de gates y workspace.
  Es un paliativo auditable: la solución de fondo es correr los gates en CI.

## P0: lo que aparecio al pasar una feature REAL por el harness

Ninguno de estos lo vieron los tests unitarios. Salieron de correr una feature de
punta a punta (intake → plan-lint → implement → precheck → review → QA →
veredicto → ship) sobre un repo Python con remoto git real, y una segunda tarea
con el trunk movido por otra sesion.

**La regla que los une, otra vez `set -e`**: llamar una funcion dentro de un
`||`, un `&&` o un `if` SUPRIME `set -e` en TODO su cuerpo. Si esa funcion es la
que corre los gates, un gate rojo deja de abortar y el resultado se lee verde.

- [x] **`run_lang_gates || lrc=$?` desactivaba `set -e` sobre todos los gates de
  lenguaje.** Un `pytest` roto salia VERDE del precheck, sellaba evidencia con
  `exit_code 0` y estampaba `ok:true`. Lo introdujo la extraccion de
  `--lang-gates`. Ahora se llama suelto y el marcador lo escribe el trap.
- [x] **Seis gates usaban `A && B`** (`go vet && go build && go test`,
  `cargo build && cargo test`, flutter, dotnet, mix, composer). Bajo `set -e`
  una AND-list que falla NO aborta, asi que un build roto nunca puso el gate en
  rojo. Preexistente, y afectaba a seis stacks. Un comando por linea.
- [x] **El camino de error del rebase moria mudo.** `git rebase || { git rebase
  --abort; ...; exit 4; }`: cuando el rebase fallaba SIN dejar rebase en curso
  (arbol sucio, el caso comun), el `--abort` salia 128 y `set -e` mataba el
  script antes de imprimir nada. Ahora muestra el error real de git y distingue
  arbol sucio de conflicto, que tienen remediaciones opuestas.
- [x] **`verdict-scaffold --rebase` dejaba `implementation_agents` vacio** cuando
  la unica evidencia fresca era la de `ship` (excluida a proposito), y se negaba
  por politica de roles: callejon sin salida en toda ronda de rework posterior a
  un ship. Se arrastran los del veredicto previo.
- [x] **`gate_tests_untouched` contaba `tests/__pycache__/*.pyc` borrados como
  tests eliminados.** El patron matchea por RUTA y `/tests?/` atrapa todo lo que
  cuelgue de ahi. Dejar de versionar artefactos (que es lo correcto) bloqueaba
  el ship. Se excluyen los compilados, y borrar un test de verdad sigue
  bloqueando.
- [x] **El reclamo de locks huerfanos era codigo muerto, y dejaba el repo
  trabado para siempre.** `pid_alive "$lpid"; alive_rc=$?` es una sentencia
  suelta en el cuerpo del `until`, y `pid_alive` devuelve 1 o 2 como DATO: con
  un lock huerfano el script salia con exit 1 sin imprimir una linea y, como
  `LOCK_HELD` estaba vacio, el lock SOBREVIVIA. Preexistente. Con varias
  sesiones por maquina, un crash tras escribir el pid deadlockea ese repo.
- [x] **El gate de evidencia fresca corria en carrera contra su propio
  productor.** El slot `lang` sella el EV (minutos) y el slot `veredicto` lo
  exigia (milisegundos), en el mismo fan-out y sin orden entre si: rojo espurio
  en el primer intento. Se difiere a un gate SERIAL despues del wait.
- [x] **Un `qa: "pass"` no exigia ningun artefacto.** `check_verdict` leia solo
  el campo del veredicto, asi que la afirmacion mas cara del pipeline era
  palabra de agente. Demostrado en la corrida: una tarea shippeo con `qa:"pass"`
  sin `qa-<repo>.json` y sin una sola evidencia de `runner=qa`. Ahora exige una
  de las dos.
- [x] **La suite era ciega a esta clase entera.** `test_ship_lock.sh` extraia
  las funciones y las corria con `set -u`, no con el `set -euo pipefail` real, y
  ademas invocaba `acquire_lock && [ ... ]`, que suprime `set -e` en todo el
  cuerpo. O sea que el test medía el harness, no el codigo. Corregido, y
  verificado por mutacion: con el patron viejo el test ahora falla.

## Corridas de validacion (lo que SI quedo ejercitado)

Dos corridas completas sobre una instancia Corvux con tres repos y remotos git
reales. Sirven como linea base de que camino esta probado de punta a punta y
cual sigue sin tocarse.

**Corrida 1, carril standard, 3 repos (contracts + api + web), DAG con
dependencias.** Quedo ejercitado: `validate-dag`, worktrees multi-repo,
`plan-lint` sobre 3 bloques, `buf breaking` en expand (paso) y el ratchet de
`buf lint` reportando deuda preexistente sin bloquear, `POLICY-SHIP-004`
rechazando la transicion a ship dos veces con la lista de repos que faltaban, y
el ship en orden del DAG. Dos gates frenaron de verdad y con razon: el precheck
de api por una regresion real (el campo nuevo rompia un test de igualdad
exacta), y `gate_evidence` en contracts por una compliance matrix que citaba una
ruta inexistente.

**Corrida 2, express con dos rondas fail→fix y contencion de push real.** Quedo
ejercitado el ciclo incremental completo: `--rebase` con `compliance` a
re-juzgar, arrastre de `implementation_agents`, y las DOS ramas del arrastre de
QA (se re-corre cuando el fix toca su `surface`, se arrastra cuando no,
ahorrando el ciclo). Y la contencion, con un proceso rival pusheando en bucle:

    intento 1/20  base +9 commits   veredicto reusado (patch_id b7113f3341cf)
    intento 2/20  base +12 commits  veredicto reusado (mismo patch_id)
    intento 3/20  base +14 commits  veredicto reusado -> shipped

El `patch_id` se mantuvo constante en los tres rebases mientras la base se movia
14 commits, y la evidencia fresca se re-sello sobre cada arbol integrado. Antes
de este trabajo el intento 1 moria con `POLICY-SHIP-002`. `POLICY-LIMIT-001`
corto la cuarta ronda de api nombrando al repo.

- [x] **Un gate de lenguaje rojo reportaba `gate '"'"''"'"' fallo`, sin sujeto.** El nombre
  fino (python, go, buf) lo pone `gate()` DENTRO del proceso hijo que hace el
  sellado, asi que el subshell del slot no lo veia. Se nombra el tramo en el
  padre; el detalle sigue en la salida del hijo.

- [x] **El ensayo del revert corria contra el clon canonico, que esta STALE.**
  `deploy-watch` probaba `git revert --no-commit` en `repos/<repo>` y sobre su
  HEAD. Ese clon solo se refresca con `pull-all.sh` o al crear un worktree, asi
  que casi siempre esta atras, y el resultado del ensayo era el de OTRO arbol.
  Verificado que falla en las DOS direcciones: con el clon en un commit que no
  contiene el cambio, `revert` falla y se inventaba un conflicto que no existe
  (rollback inservible); y con el clon atrasado respecto de un commit ajeno que
  reescribio las mismas lineas, `revert` sale OK y se PROPONIA una accion
  destructiva sobre produccion que en el main real conflictua. Ese segundo caso
  es el peor: un falso OK sobre un rollback. Ademas limpiaba con `reset --hard`
  sobre el clon COMPARTIDO del que cuelgan todos los worktrees. Ahora el ensayo
  va en un worktree temporal desacoplado contra `origin/<trunk>`, y el clon no
  se toca. Primera corrida real de `deploy-watch` (459 lineas, cero ejecuciones
  hasta hoy).

- [x] **El marcador del set de templates tenia dos lecturas y solo se aceptaba
  una, asi que `make version` podia reportar drift eterno.**
  `templates/MANIFEST.sha256` termina con la linea `digest: <hash>` y la tabla
  de generacion pedia "el `digest:` de MANIFEST.sha256": eso se lee como el
  VALOR o como la LINEA. `harness-version.sh` hacia `tr -d ' \n'` y comparaba
  contra el hash pelado, asi que una instancia cuyo generador escribio la linea
  quedaba en `digest:abc...` y NUNCA igualaba. Reproducido con dos instancias
  identicas: una `✅ idénticos a upstream`, la otra `⬆️ DISTINTOS`. Es el peor
  sitio posible para un falso rojo, porque esta comprobacion existe justamente
  para que un update no pueda mentir, y mintiendo ella enseña a ignorar el
  aviso. Ahora se normalizan las dos formas (con o sin prefijo, mayusculas o
  minusculas), un marcador que no sea sha256 se declara ILEGIBLE en vez de
  drift (son remediaciones distintas), y la instruccion del generador dejo de
  ser ambigua. Mismo criterio en `doctor.sh`.

## Los dos pendientes que quedaban, cerrados

- [x] **La fase la registra el push, no el prompt.** `review → ship` era prosa
  en `/ship` y en `/auto`, y el orquestador se la olvidaba: `state.json` quedaba
  en `review` con el codigo ya en main, asi que quien auditara por el estado
  reconstruia una historia falsa y un `/auto <task-id>` posterior re-entraba a
  revisar algo publicado. Verificado en dos corridas. Ahora la pide `ship.sh`
  tras cada push, y `POLICY-SHIP-004` sigue siendo quien decide (solo prospera
  cuando todos los repos shippearon): la regla no se duplica. Es fail-open a
  proposito, porque el push YA ocurrio y salir en rojo por la contabilidad diria
  que el ship fallo cuando no fallo. Y `harness-policy.py` emite cada movimiento
  al bus: antes el panel no tenia un solo evento de fase.
- [x] **`flow: prs` implementado.** Dejo de ser la perilla que solo sabia
  negarse (exit 7). Mismos gates, otra puerta: publica la rama (con
  `--force-with-lease`, porque el rebase la reescribe y no se pisa trabajo
  ajeno) y abre el PR por la capa de forge, que gano `forge_pr_url` y
  `forge_pr_merged`. Lo que NO hace es fingir: `ship.log` queda con
  `landed:false`, el mensaje dice que el cambio no esta en la trunk, y
  `/archive` exige que haya aterrizado (fusionar el delta-spec de un PR abierto
  es spec rot al reves, y mas dificil de ver porque la spec parece adelantada).
  `deploy-watch` resuelve el commit REAL preguntando al forge, porque la cola de
  merge rebasea o hace squash y el sha que verifico ship.sh no es el que
  aterriza.

Tres bugs propios que aparecieron construyendolo, los tres del mismo tipo:

- [x] `.landed // true` en jq: el operador `//` trata `false` COMO AUSENTE, asi
  que una entrada con `landed:false` se leia como aterrizada y el watcher se
  ponia a buscar el deploy de un commit que no esta en main.
- [x] `resolve_landed_sha` devolvia el sha por stdout y ademas EXPLICABA con
  `say`, que tambien escribe a stdout: llamada dentro de `$( )`, todos los
  diagnosticos se los tragaba la variable. El canal de datos y el de
  explicacion no pueden ser el mismo.
- [x] Un mensaje afirmaba lo que el anterior negaba ("no pude abrir el PR"
  seguido de "✅ PR abierto"), y otro decia "no hay ship en ship.log" cuando si
  lo habia y lo que fallo fue resolver el merge. Dos causas con remediaciones
  distintas no pueden compartir mensaje.

## Caminos que faltaban ejercitar (corridos, y lo que salio)

Cerrando la lista de "sin probar": `escalate`, `pause`/`resume`, `archive` y la
limpieza de worktrees, sobre la instancia Corvux.

Funcionaron sin hallazgos, y queda escrito para que se sepa que se probo:
`escalate` desde intake (cambia carril, se queda) y desde implement (vuelve a
rfc CONSERVANDO worktree y commits); `plan-lint` cazando el carril antes de
implementar y pasando despues de escalar; `pause` con motivo del catalogo y
rechazando uno inventado; una tarea bloqueada que no puede shippear; `resume`;
la cadena `ship → deploy → archive`; y `worktree-task.sh --rm`, que borra el
worktree pero CONSERVA la rama con trabajo sin publicar. Ese ultimo se verifico
hasta el final: la rama sobrevive, `worktree-task.sh` la vuelve a checkoutear y
el contenido regresa intacto. No hay perdida de trabajo.

Tambien quedo comprobado que `harness-policy.py` emite ahora al bus: el panel ve
`escalate` como decision, `pause` como stop y cada transicion como fase, que es
lo que faltaba para poder reconstruir el estado de una tarea sin leer archivos.

- [x] **Con `flow: prs` se podia archivar un cambio sin mergear.** La regla
  vivia en el prompt de `/archive` y solo ahi, y la prosa no frena a nadie:
  fusionar el delta-spec de un PR abierto deja la spec maestra describiendo algo
  que no existe. Es spec rot al reves y mas dificil de ver que el normal, porque
  la spec parece adelantada en vez de vieja. Ahora `POLICY-SHIP-005` rechaza las
  transiciones a `deploy` y a `archive` mientras quede un repo con
  `landed:false`, y nombra cuales. Compatible hacia atras: `flow: trunk` no
  escribe ese campo, y un campo AUSENTE no cuenta como false (confundir esas dos
  cosas fue justo el bug del `//` de jq).

- [x] **El instalador podia INVENTAR el numero de version, y `make version`
  lo bendecia.** Encontrado en una VPS real: `.harness-version` decia `0.60.0`,
  una version que no existe en ningun origen del plugin (0.45.2 / 0.47.0 /
  0.48.0) y cuyo CONTENIDO estaba 67 commits atras. La causa es la de siempre:
  la tabla de generacion pedia "`.harness-version` | version del plugin" SIN
  decir de donde leerla, y quien instala es un agente, asi que escribio un
  numero plausible. El agravante: `harness-version.sh` comparaba con `ver_lt` y
  todo lo que no fuera "local < upstream" caia en un `else` que imprimia
  "✅ al día". Con 0.60.0 contra 0.48.0 la instancia se reportaba SANA mientras
  sus gates de lenguaje no compilaban nada. Ahora la tabla nombra la fuente
  (`plugin.json`) y prohibe escribirla de memoria, y una version MAYOR que la de
  upstream se declara imposible en vez de sana: nadie publica hacia atras, asi
  que ese numero no se leyo, se escribio.

## Lo que aprendio el plugin de una instalacion real

Tres hallazgos de operar una instancia de verdad, no de leer el codigo.

- [x] **El doctor confundia "no esta en MI PATH" con "no esta instalado".** Una
  sesion no interactiva (`ssh host cmd`, cron, un servicio) NO lee `~/.zshrc`
  ni `~/.profile`, asi que no ve Homebrew, `~/.local/bin` ni `~/go/bin`. El
  doctor reporto 22 CLIs faltantes sobre una maquina que las tenia TODAS, y de
  ahi salio un diagnostico entero equivocado (que faltaba la toolchain, que el
  bootstrap no servia en Linux, que los repos Go shippeaban sin compilar). Nada
  de eso era cierto. Ahora busca el binario en las rutas donde instalan los
  gestores de la casa y, si esta, lo dice como lo que es, con la remediacion
  correcta (`brew shellenv` va en `~/.zshenv`, que zsh lee siempre, no solo en
  `~/.zshrc`). Decir "falta" manda a reinstalar lo que ya esta y entrena a no
  creerle al doctor.
- [x] **`AGENTS.md` se regeneraba, y borro contenido ajeno.** Estaba clasificado
  como propiedad del plugin, asi que el update lo reescribio entero: se llevo 70
  lineas de una instancia real, incluidas la ley del design system del proyecto
  y un bloque completo de OTRA herramienta (`<!-- BEGIN BEADS INTEGRATION v:1
  ... hash:6cd5cc61 -->`), que ni siquiera es nuestro para tocar. `AGENTS.md` es
  la puerta MULTI-HERRAMIENTA por diseño: Codex, Cursor y lo que el proyecto
  sume dejan lo suyo ahi. Ahora se MERGEA, se preservan los bloques
  `BEGIN`/`END` de terceros y las secciones que el template no contiene.
- [x] **El instalador elegia la plataforma de la maquina que GENERA.** La regla
  decia "si el workspace corre en Linux, usa install_linux", lo que asume que se
  genera y se ejecuta en el mismo lugar. Con una instancia que se versiona y se
  clona a otras maquinas eso es falso: se genero en macOS y se clono a VPS
  Ubuntu, dejando `brew install --cask` (que en Linux no existe) y perdiendo la
  variante Linux que el catalogo SI tenia para kubectl. Ahora la tabla dice que
  la plataforma es la del DESTINO, y `bootstrap.sh` avisa al arrancar si detecta
  el cruce. Matiz que la investigacion corrigio: Homebrew si corre en Linux, asi
  que las formulas normales sobreviven; lo que no sobrevive son los `--cask`.

Y un bug propio, del mismo tipo, cazado probando: el detector del cruce de
plataforma hacia `grep -- "--cask"` sobre su propio archivo y encontraba SU
PROPIO mensaje de aviso, que menciona `--cask`. Avisaba siempre, incluso sin un
solo cask. Un detector que se detecta a si mismo es un detector roto.

- [x] **Los gates corren en infra NEUTRAL** (`ship.sh --ci` +
  `templates/ci/harness-gates.yml.tmpl`). Hasta aca corrian en la laptop del que
  pushea: con una sola persona ese modelo de confianza es razonable, con un
  equipo significa que "los sistemas deterministas verifican" vale hasta la
  laptop menos actualizada, y cualquiera puede editar su ship.sh local. El
  workflow corre EL MISMO codigo a proposito: uno que reimplemente los gates se
  desincroniza en la primera version, y entonces CI y local dicen cosas
  distintas del mismo commit, que es peor que no tener CI.
  Detalles que decidieron el diseño: `fetch-depth: 0` porque un checkout
  superficial deja el diff contra la trunk VACIO y los gates pasan sin mirar
  nada (el fallo que este repo persigue); la declaracion de un test debilitado
  viaja por `HARNESS_DELTA_SPEC_FILE` porque en CI no existe
  `tasks/<id>/delta-spec.md`, y sin ninguna de las dos bloquea (fail-closed); y
  en CI no se sella evidencia, porque no hay veredicto al que atarla y un EV
  que no respalda nada es peor que ninguno.

### Pendiente

- [ ] **Activar la cola en el forge.** Lo que falta ya no es codigo: marcar
  "gates del harness" como required check y encender la merge queue en la
  proteccion de rama. Eso lo hace un humano en la UI del forge, una vez por
  repo, y es lo que convierte el workflow en obligatorio y serializa el merge.
- [ ] **`flow: prs` + cola de merge del forge.** Todo lo de arriba MITIGA la
  carrera; la cola de merge la elimina en el origen, porque serializa en el
  servidor y corre la suite UNA vez sobre el merge result en infra neutral en
  vez de una vez por intento en diez laptops. `ship.sh` ya falla cerrado con
  exit 7 para `flow: prs` (`ship.sh.tmpl:47-64`) y su comentario ya lista el
  costo real: cambia qué significa "shippeado" para `deploy-watch` (el sha
  aterrizado sale de `gh pr view --json mergeCommit`, no de `ship.log`) y para
  `/archive` (dispara en el merge, no en el push). El anclaje por `patch_id` es
  su HABILITADOR, no su alternativa: la cola rebasea ella misma, así que sin
  eso `flow: prs` recrearía el mismo problema un paso a la derecha.
  Por la Ley 13 esta es la recomendada; lo de arriba es el camino corto que la
  hace innecesaria como urgencia, no como destino.
- [ ] **Conflicto semántico sin conflicto textual.** Un commit ajeno renombra un
  símbolo que tu diff usa sin tocar tus líneas: `patch_id` no cambia y el merge
  no compila. Por eso la evidencia FRESCA es obligatoria y ship re-corre la
  suite completa sobre el árbol integrado. Queda documentado como límite
  conocido de `change-id.sh`, no como algo resuelto.

---

## Cerrado el 2026-07-25

Dieciséis arreglos, todos con test que los fija: el gate del veredicto
diagnostica review y QA por separado; `rollback` de fase y el historial como
control; `--rebase` para el re-review incremental; resumen de fin de sesión con
atribución por sesión; lock de `state.json`; `POLICY-SHIP-004`; Kargo y ArgoCD
como supuestos declarados en vez de silencios; `guard-worktree`;
`track-read` cubriendo el workspace; el watchdog distinguiendo una llamada en
vuelo de un atasco; los drivers de deploy; `app_name` sin concatenación ciega;
la evidencia en el prompt del implementer; `loop_budget` gobernando de verdad;
la Ley 13; la fase de enrichment; y las reglas 7 y 8 de `CONTRIBUTING.md` con su
test de neutralidad.

## Cerrado el 2026-07-30

- [x] **`gate_tests_untouched` bloqueaba todo spec e2e NUEVO por su guard de
  entorno.** En un archivo de alta TODAS las lineas son `+`, asi que un solo
  `test.skip(!reachable, ...)` (el que Playwright pide para no correr contra un
  servicio caido, el `t.Skip` de Go cuando falta una dependencia) daba neto 1 y
  salia exit 3. Y no habia salida legitima: el unico escape del gate es nombrar
  el archivo bajo `MODIFIED`/`REMOVED` del delta-spec, que en un archivo nuevo
  es una declaracion FALSA (el requirement es `ADDED`), o sea que la unica forma
  de shippear un spec nuevo era mentirle al gate que existe para impedir
  exactamente eso. Ahora los skips de un archivo de test anadido no cuentan, y
  el archivo se nombra igual en la salida para que el hecho quede auditable.
  Aserciones netas eliminadas, borrados sin declarar y skips sobre archivos
  EXISTENTES siguen bloqueando. Queda un residual DECLARADO en el comentario del
  gate: un spec e2e nuevo enteramente skipeado tampoco lo caza
  `gate_test_muerde`, porque su red solo llega hasta donde el runner declarado
  colecta el archivo.
- [x] **`verdict-scaffold.sh` citaba evidencia que el propio ship iba a
  rechazar.** `gate_preflight` rechaza el veredicto que cite un EV con
  `contention.suspect` y manda a re-sellar, pero el predicado de elegibilidad no
  miraba esa marca: al re-sellar limpio, `--force` re-incluia el contaminado (y
  tiraba el juicio del reviewer) y `--rebase` se negaba porque el commit no se
  habia movido. La remediacion impresa era inalcanzable y la tarea quedaba
  trabada con el veredicto ya en `pass`.

## Cerrado el 2026-08-13 (issue #168: la capa de verificacion con sesgo a falso verde)

Siete hallazgos de una sola sesion, y cuatro comparten defecto: no fallan al
detectar un problema, **afirman que no lo hay**. Los cuatro concluyen desde una
señal indirecta en vez del artefacto (el manifiesto en lugar de los pods, el
exit code en lugar de la asercion, el arbol que el propio verificador acaba de
tocar). Un falso rojo cuesta una ronda; un falso verde cuesta el defecto entero,
en produccion, y nadie se entera.

- [x] **`deploy-watch` daba 🟢 con el rollout a medias.** Declaraba verde con
  ArgoCD `Synced+Healthy`, que habla del MANIFIESTO. Medido en ese mismo
  momento: `updated=2 ready=3 available=2` y un pod viejo Running con la imagen
  anterior, o sea un tercio del trafico contra el artefacto viejo. Segunda
  ocurrencia con contadores 2/2/2 en verde y los pods en la imagen anterior
  porque el promotor todavia no habia movido el tag: si Kargo no promovio, el
  Deployment esta legitimamente estable EN LA REVISION VIEJA. `check_rollout`
  cruza ahora rollout terminado Y pods posteriores al commit shippeado, con una
  sola terna de imagen entre los pods (la terna, no la imagen suelta: con un
  sidecar toda instalacion tendria dos). Incompleto deja de dar credito de
  cluster; no poder mirar sigue siendo ceguera con el verde del manifiesto.
- [x] **`gate_test_muerde` ponia ✅ con CERO unidades medidas.** El cierre
  imprimia "lo que SI pude correr falla sobre la base" aunque ese "lo que si"
  fuera vacio, o sea el mensaje de un gate que verifico algo puesto por uno que
  no verifico nada: un test vacuo y uno bueno recibian la misma respuesta.
- [x] **Y su ceguera en Go tenia una causa medible que ningun reporte nombro.**
  Los `use` del `go.work` son relativos al archivo y el kernel resuelve cada
  `..` sobre la ruta FISICA. El arbol base nace de `mktemp -d`, o sea bajo
  `/tmp` o `$TMPDIR`, y en macOS los dos son symlinks (`/var` → `/private/var`):
  la ruta logica queda un nivel mas corta, el relativo aterriza en
  `/private/<algo>` inexistente y `go` contesta `cannot load module ... listed
  in go.work file` en TODO arbol base, en cada corrida. `gowork.sh` resuelve con
  `pwd -P` las dos puntas del calculo. El test viejo no podia cazarlo porque
  comprobaba con `cd`, que es logico; el nuevo usa `[ -d ]`, que pregunta al
  kernel igual que `go`.
- [x] **La sonda de coleccion no sabia leer vitest 1.6.** `list` es subcomando
  desde 2.1; en 1.6 es UN FILTRO MAS, asi que corria otra seleccion de archivos
  y su salida no nombraba el archivo preguntado. El gate marcaba "tramo sin red"
  un `.test.tsx` que si muerde y en la linea siguiente imprimia su propio
  diagnostico `vitest (exit 1): Tests 17 failed | 17 passed`. La deteccion por
  texto del error no alcanzaba: 1.6 no se queja, hace otra cosa en silencio.
- [x] **`evidence.py` sellaba verde sobre arboles que no controla.** La concesion
  del #137 (en un arbol compartido, la suciedad que esta tarea no commiteo no
  bloquea) aplicaba a CUALQUIER arbol de fuera del workspace, incluida una sonda
  descartable en `/tmp`. Ahora es solo el arbol de la INSTANCIA, que se reconoce
  por estructura (el padre de `tasks/<id>`). Y una guarda nueva de la misma
  familia: si el COMANDO nombra un archivo que no esta en el commit (sin
  trackear y sin ignorar, dentro del repo), falla cerrado, porque un test nuevo
  es un archivo nuevo y por ahi el sello certificaba codigo que no viajaba en el
  commit que nombra.
- [x] **`POLICY-ARCHIVE-001` se derrotaba con la fusion mecanica del campo
  `qa`.** Comparaba mtimes, y fundir `qa` en el veredicto es un paso PRESCRITO
  por `/review` DESPUES del juicio del reviewer: 17 segundos de ventana bastaron
  para blanquear una enmienda del delta-spec. Ahora manda `delta_spec_sha256`,
  que sella `verdict-scaffold.sh`; el mtime queda de piso para los veredictos
  viejos, que no traen el campo.
- [x] **`delta_seccion` tiraba la linea de encabezado de las subsecciones.** Un
  test nombrado solo en el `### <archivo>` no lo veia `gate_tests_untouched`: el
  delta-spec cumplia la regla a la vista de un humano y el gate salia rojo con
  un mensaje que hablaba de SI el nombre estaba y no de DONDE.
- [x] **El contrato del rol `qa` no decia nada sobre matar procesos.** Un `kill`
  con los pids que salen de `ss -ltnp` se llevo puesto el trabajo de las
  sesiones hermanas (los dev servers del host pasaron de 15 a 3, y con ellos los
  port-forwards de observabilidad). Ahora exige matar solo los pids propios, y
  declara el corolario: `--strictPort` no protege de una colision cuando dos
  procesos bindean stacks IP distintos.
- [x] **Los marcadores de relevo de fase no caducaban.** 19 marcadores huerfanos
  son 19 sesiones ajenas al pedido en cuanto alguien levanta el vigilante, asi
  que nadie lo levanta y el relevo por fase queda desactivado de hecho: el
  pipeline entero corrio en una sola sesion, con el contexto del orquestador
  subiendo de 230k a 357k monotonamente y llevandose el 40% del costo de la
  tarea. `HARNESS_ORCH_HANDOFF_TTL` (6 h) los caduca y lo dice antes de tirarlos.

**Lo que NO se pudo reproducir, dicho para que no se lea como cerrado:** el
reporte afirma que `evidence.py run --cwd` RESTAURA el arbol que recibe. Medido
sobre un worktree sonda con los fuentes de la base encima, no toca nada y falla
cerrado con exit 3. Lo que si se arreglaron son los dos caminos verificables por
los que ese sello podia salir verde igual (los dos de la entrada de
`evidence.py`, arriba). Si el arbol de veras se restauro, la causa esta fuera de
ese script y hace falta el rastro para encontrarla.

## Cerrado el 2026-08-14 (issue #169: el vigilante sin techo)

- [x] **`orchestrator-watch.sh daemon` relanzaba TODAS las varadas por pasada,
  sin tope sobre cuántas sesiones quedan vivas.** Sus dos límites (`lease_taken`
  y `MAX_TRIES`) son POR TAREA y ninguno miraba el agregado, así que con un
  backlog de tareas viejas que cruzan el umbral de silencio a la vez no relanza
  una sesión: relanza decenas, cada una con su flota MCP completa. Medido el
  2026-08-14: 132 tareas en fase no terminal, 83 varadas, **125 relanzamientos
  en 71 minutos** (29 en UNA sola pasada) a 1,15 GB por sesión, o sea ~140 GB
  pedidos contra 12 de RAM y 8 de swap. No hay OOM-killer ni panic en el
  journal: la maquina dejo de poder hacer nada y hubo que reiniciarla a mano, lo
  cual vale decirlo porque buscar el rastro del incidente en el journal no
  encuentra nada y eso hace pensar que no fue memoria. La eleccion hasta hoy era
  "vigilante sin techo" o "sin vigilante" (el kill switch). Ahora hay cuatro
  frenos, y cada uno cubre lo que los otros no: tope de sesiones VIVAS
  (`HARNESS_ORCH_MAX_LIVE`, contando leases con PID vivo, dato que el lease ya
  guardaba), tope POR PASADA (`HARNESS_ORCH_MAX_PER_PASS`, rampa en vez de
  escalon), piso de memoria libre (`HARNESS_ORCH_MIN_FREE_MB`, el fail-safe de
  verdad cuando el tope esta mal calibrado para la maquina) y techo de
  antiguedad (`HARNESS_ORCH_MAX_AGE_H`). Cuando el tope muerde, el orden es
  justo: menos intentos primero y desempate por mas tiempo callada, porque con
  el glob alfabetico los slots se los llevaban siempre las mismas tareas.
- [x] **Una tarea de hace cinco dias no es una sesion que murio hace un rato.**
  Es el punto de diseno del incidente: casi todas las 83 varadas eran del 7 al
  10 de agosto, o sea tareas ABANDONADAS, y relanzarlas no las va a terminar.
  Por encima del techo de antiguedad se escalan por el camino que ya existe
  (`escalate_to_human` → `pause` con `orchestrator_stalled`), que ademas las
  saca de la cola para siempre: `blocked` es terminal para este vigilante. El
  motivo viaja como DETALLE y no como codigo nuevo, para que toda instancia ya
  instalada pueda registrar la pausa con su `allowed_pause_reasons` de hoy.
- [x] **El lease no sobrevivia a un reinicio.** `lease_taken` decidia con
  `kill -0 $pid`, que contesta "hay UN proceso con ese numero", no "sigue vivo
  EL proceso que lance". Tras un reinicio los PIDs se reasignan desde abajo, asi
  que un lease viejo puede apuntar a un proceso ajeno del mismo usuario y dar
  "esta tarea tiene dueno" para siempre. En la maquina del incidente
  sobrevivieron 346 directorios de claim, muchos con PIDs del rango de 2.000.000.
  Ahora el lease guarda tambien el INSTANTE DE ARRANQUE del proceso (campo 22 de
  `/proc/<pid>/stat` en Linux, `ps -o lstart` en BSD y macOS): un PID reciclado
  arranca despues, asi que su marca no coincide. Los leases de la version
  anterior (pid sin identidad) dejan de creerse por el numero pelado y pasan a
  cobrar el TTL como cualquier lease sin dueno demostrable.
||||||| parent of dc07889 (fix: el verde esperaba a quien termina primero, no a quien construye (#171))
## Cerrado el 2026-08-14 (issue #171: verde 7 minutos antes de que la imagen exista)

- [x] **`deploy-watch` elegia el run de Actions por sha, o sea al azar entre los
  workflows del mismo push.** Se tomaba `.[0]` de la lista que devuelve la API.
  Caso de campo: un push disparo `e2e` y `Deploy` con el mismo head sha, se
  eligio el `e2e` (que termina antes) y el watcher canto "actions verde" con
  `Deploy` todavia `in_progress`. El verde salio **7m41s antes de que la imagen
  existiera** y 11m15s antes de que sirviera. Ahora: con UN solo run no hay
  ambiguedad y se vigila; con varios se eligen los que tienen un job CRITICO
  (la misma declaracion `critical_jobs` que el script ya usaba para decidir si
  un skipped es rojo), se puede fijar con `DEPLOY_WORKFLOW` o
  `deploy: <repo>: workflow:`, y si ninguno es reconocible se declara ceguera en
  vez de adivinar. Si dos construyen, se vigilan los DOS: esperar a uno solo es
  el mismo azar con otro disfraz.
- [x] **La promocion vacia de Kargo no frenaba nada.** Tras el #112 kargo SI
  responde, y cuando la lista viene vacia el script imprimia la sugerencia del
  refresh del warehouse y seguia. Responder "no hay freight" y seguir deja el
  MISMO agujero que dejaba no responder. La pregunta honesta ademas no es "¿hay
  promociones?" sino "¿hay una POSTERIOR a mi commit?", porque una promocion
  vieja promovio el artefacto anterior. Sin fecha del commit no se compara: se
  degrada a la presencia, que es lo unico observable.
- [x] **El smoke corria contra los pods viejos y pasaba por definicion.** Es la
  cuarta señal del caso de campo y la mas engañosa: un verde asi no es una
  defensa, es la confirmacion de que lo viejo sigue funcionando. Con el rollout
  declarado incompleto, el smoke no se corre y se dice por que.
- Nota: la condicion de salida que el reporte pedia (el tag que corren los pods
  == el del commit shippeado) ya la implementa `check_rollout`, del #168.
- Defecto que me hice yo mismo escribiendo esto, y queda anotado porque es la
  clase de error que un test si puede cazar: `elige_runs` corre dentro de un
  `$( )`, asi que sus `say` a stdout se convertian en ids de run y el watcher
  terminaba "vigilando" palabras sueltas de su propio diagnostico. Los mensajes
  van a stderr y hay una asercion que lo fija.
||||||| parent of 7e5ffa0 (fix: el onboarding de secretos es de TU fuente, no de Vault (#174, #175))
||||||| parent of b02dca4 (fix: el onboarding de secretos es de TU fuente, no de Vault (#174, #175))
## Cerrado el 2026-08-14 (issues #174 y #175: el onboarding de secretos era de Vault, no tuyo)

- [x] **`bootstrap.sh` aceptaba el token de Vault sin validarlo, y en silencio,
  cuando el CLI `vault` no estaba.** Las dos ramas que hablan (`no hay token` y
  `el token expiro`) quedaban sin tomar, `NEED_TOKEN` se quedaba en 0 y el
  onboarding se declaraba terminado con un token que nunca se verifico contra
  ningun servidor. La primera corrida al menos lo pide; de la segunda en
  adelante, silencio. El sintoma aparece lejos: `secrets.sh pull` trae 0 claves
  y el usuario culpa a sus policies o rota el token. Ahora la rama existe y
  DICE que no pudo validar, con el comando para hacerlo a mano. Le pasa a
  cualquier instancia donde la instalacion del CLI fallo por plataforma o por
  red, no solo por el #23.
- [x] **`bootstrap.sh` solo onboardeaba Vault: las otras 6 fuentes que
  `secrets.sh` implementa quedaban sin paso de credencial.** Medido sobre las
  siete: seis saltaban directo a `secrets.sh pull`, que falla sin decir como
  autenticarse, y `TOKFILE` quedaba cableado a `vault-token` aunque la instancia
  nunca hubiera elegido Vault. Con equipos que corren un harness por nube (uno
  en GCP SM, otro en AWS SM) el onboarding no existia en ninguno. Ahora se
  DESPACHA por fuente (regla 8): cada una comprueba su credencial con su propio
  CLI (`gcloud auth application-default print-access-token`,
  `aws sts get-caller-identity`, `doppler me`, `op whoami`, la llave age de
  sops, el `.secrets` a mano de `env`) y, si falta, nombra el comando exacto de
  login. Lo que el bootstrap NO hace es correr ese login: abren navegador o
  piden datos interactivos, y encadenarlos a ciegas desde un bootstrap es como
  se pierden sesiones ajenas. Sin el CLI de la fuente se declara ceguera, que es
  la misma respuesta que da el resto del harness cuando no puede mirar.
||||||| parent of eb6073c (fix: el plan pedia correr los gates que el precheck ya corre (#170))
||||||| parent of 86b9d1c (fix: el plan pedia correr los gates que el precheck ya corre (#170))
## Cerrado el 2026-08-14 (issue #170: los gates corrian dos veces por ronda)

- [x] **`plan-lint.sh` bendecia criterios que contradicen a `implementer.md` §5.**
  El §5 prohibe re-correr la suite ("antes se corria cuatro veces por tarea") y
  el formato de plan que este mismo script valida empuja a lo contrario, porque
  la forma natural de escribir un criterio binario y ejercitable es NOMBRAR los
  comandos de gate del repo. Las dos reglas son del mismo harness y se
  contradicen; gana la que el implementer tiene delante, que es el plan. Medido
  en una tarea de dos rondas del carril express (1 repo, 2 archivos de
  produccion y 2 de test): 18,9 min de reloj de herramientas, de los cuales ~10
  son el precheck y ~7,9 los MISMOS gates corridos a mano antes. Unos 8 minutos
  por tarea de ejecucion duplicada, en el carril mas barato, y en un repo cuya
  suite paga 90 s de arranque por corrida. Ahora `plan-lint` AVISA (no bloquea:
  el criterio no es incorrecto, es caro) y la plantilla del architect dice que
  el criterio correcto es la CONDUCTA que el cambio agrega.
- [x] **`harness-cost.py` no reportaba tiempo, y por eso el diagnostico apunto
  al lugar equivocado.** Reportaba dolares, turnos y contexto, asi que la
  latencia se diagnosticaba con el unico numero disponible: la duracion que el
  runtime informa al orquestador. Ese numero es inconsistente para los agentes
  CONTINUADOS (`SendMessage`), que es como el harness hace las rondas: en la
  misma sesion, el reviewer devolvio duracion POR RONDA (12,4 min) y el
  implementer la vida entera del agente con el ocio adentro (33,9 min contra
  12,2 de trabajo). Ahora el reporte trae DOS columnas y la diferencia es el
  dato: `activo` suma solo los huecos entre turnos que son trabajo (perilla
  `HARNESS_COST_HUECO_MAX_S`), y `reloj` va del primer turno al ultimo. El
  tiempo va junto al costo y no en otro comando: "por que tardo" y "por que
  costo" se preguntan a la vez.

## Cerrado el 2026-08-14 (issue #180: la cura estaba detras del sintoma)

- [x] **`COST-CTX` frenaba la transicion que ES su propia remediacion.** La
  transicion de fase deja el marcador de relevo, el orquestador cierra su turno
  y el vigilante levanta una sesion NUEVA con contexto limpio. El termino la
  frenaba para exigir un perdon por el contexto que la transicion estaba por
  tirar. Cobrarlo ahi no recupera un peso (ya se gasto) y no protege nada: lo
  unico que el bloqueo evitaria, que la fase siguiente corra sobre la sesion
  inflada, ya lo evita el relevo. Lo que producia era CEREMONIA: un eximido por
  fase, concedido siempre, porque con la tarea verde y la plata gastada no hay
  otra respuesta correcta. La evidencia estaba en el propio repo antes del
  reporte: el comentario de `write_handoff` registra tareas que firmaron CUATRO
  cost-waives del mismo `COST-CTX`, uno por fase. Y cinco reportes de campo
  dando vueltas por el mismo cuarto: #90, #91 y #93 ("la salida que ofrece no
  destraba"), #103 y #111 ("el perdon vence antes de escribirse"), y el #180 con
  la tarea entera en verde y sin camino ejecutable.
- [x] **Fail-CLOSED donde la sesion SI continua.** La exencion vale solo si el
  relevo va a ocurrir de verdad: no a `archive` ni a `deploy`, carril distinto
  de `quick`, y el vigilante encendido (`HARNESS_ORCH_OFF` /
  `.harness/orch-watch.off`). Con el vigilante apagado el marcador se escribe y
  no lo consume nadie, asi que quien sigue trabajando es la MISMA sesion con el
  MISMO contexto y el termino frena como siempre. La exencion es ademas del
  ORQUESTADOR y de nadie mas: el contexto de arranque de un subagente si lo
  controla quien lo lanza, que es justo lo que la remediacion impresa pide.
  Verificado por mutacion: sin el fail-closed caen 5 aserciones, y con la
  exencion abierta a cualquier rol cae la del subagente.
- [x] **El mensaje leia AL REVES al operador del caso mas frecuente.** Decia que
  `cost-waive` es la salida "de un agente que YA CERRO", asi que quien tenia el
  orquestador VIVO se deducia fuera de las dos ramas contempladas: no puede
  recortar un arranque que ya ocurrio, y no califica como cerrado. Concluia, con
  razon, que no tenia camino. El waive de `ctx` se ancla a la FASE justamente
  porque el orquestador esta vivo por definicion al pedir la transicion (#103),
  o sea que el camino existia y el mensaje lo escondia. Ahora lo nombra, da el
  comando exacto con el task-id puesto, y dice que si esta frenando es porque
  esta transicion no releva.
- [x] **El techo se cruzaba en silencio.** El primer aviso era la transicion
  frenada, con todo gastado y ninguna decision disponible. `harness-cost.py
  ctx-watch` avisa al 80% del techo (`HARNESS_CTX_WARN_PCT`) y lo corre
  `orchestrator-watch` en cada pasada, con UNA sola lectura de transcripts para
  todas las tareas (igual que `stale`): N escaneos por pasada serian el gasto
  que el aviso viene a evitar.
- Lo que NO se hizo, y por que: el reporte pedia un comando `handoff` nuevo que
  traspasara la tarea a un orquestador nuevo. Ya existe y es automatico
  (`write_handoff` en cada transicion que releva); lo que faltaba era que la
  transicion no estuviera bloqueada. Un comando mas seria un tercer camino al
  mismo lugar.

## Cerrado el 2026-08-14 (issues #182 y #185: dos autoridades, un hecho, respuestas distintas)

- [x] **`transition` concedia una ronda extra por convergencia y
  `validate-ship` la rechazaba.** Las dos mitades del mismo
  `harness-policy.py` evaluaban el mismo numero con reglas distintas:
  `transition` conocia la excepcion por convergencia y su techo duro (2x el
  maximo), y `validate-ship` comparaba contra el maximo pelado. Medido en campo:
  la tarea cruzo a la ronda 5 porque el propio motor se la CONCEDIO (bloqueantes
  4 → 0 → 1 → 0, con su aviso al bus), el reviewer firmo `pass` con cero
  requisitos sin cubrir, el precheck quedo verde, y el ship se nego con
  `POLICY-LIMIT-001`. El mecanismo que existe para premiar al que converge
  terminaba bloqueandolo: gasto una ronda que su propio harness autorizo y no
  pudo publicarla. Ahora la regla vive en `limite_de_rondas()` y la consultan
  los dos; nadie la reimplementa. Ningun test cubria la divergencia, que es por
  lo que llego a campo: el nuevo falla contra el codigo anterior.
- [x] **Y su mensaje era "review_rounds invalido o excedido".** No decia el
  numero, ni el techo, ni cual de las dos cosas paso, ni que hacer. Los mensajes
  de este repo son prompts (regla 5): ahora trae el valor, el techo efectivo y,
  cuando el techo no se movio, por que (la serie de bloqueantes no baja).
- [x] **El gate del doctor de `instance-ship` confundia host sin provisionar con
  instancia rota.** `doctor.sh` cuenta con el mismo simbolo y el mismo peso dos
  cosas de naturaleza distinta: salud de la INSTANCIA (links de docs, hooks
  cableados, reglas con verificador, drift de templates) y provision del HOST
  (falta flutter, falta gcloud, falta terraform). Solo la primera dice algo
  sobre si el commit es seguro para main. Caso de campo: un commit de documentos
  mas el bump del harness quedo sin publicar por 16 `cli faltante`, ninguno de
  los cuales ese commit ejecuta, y los dos SDK mas pesados (flutter ~1GB, gcloud
  ~500MB) son ademas los mas caros de instalar, asi que el gate empujaba a
  provisionar media maquina para publicar un markdown. El operador termino
  declarando un `HARNESS_KNOWN_BUG` que no era un bug del harness, por falta de
  una tercera opcion: la señal de que el gate medía lo que no le competia.
  Ahora `doctor.sh --instance-only` baja esa clase a aviso (se sigue VIENDO, con
  su remediacion) y el gate pide ese modo; `make doctor` sigue cobrando todo.
  Le pasa a todo host acotado: CI, un contenedor, una VPS sin los SDK de
  cliente, que es justo donde el repo de la instancia se queda sin camino a main
  (el hueco que `instance-ship.sh` existe para cerrar, #37).

## Cerrado el 2026-08-14 (issue #190: el catalogo asumia que brew corre en Linux)

- [x] **`install_linux` cubria 3 de 60 capacidades, e `install_alt` 8.** El
  catalogo se apoyaba en una premisa escrita en la propia tabla de generacion:
  "Homebrew SI corre en Linux, asi que las formulas normales sobreviven al
  cruce". Los #184, #186 y #188 la derribaron: en un host Linux acotado brew no
  esta, y como ROOT no puede estar (su instalador aborta con "Don't run this as
  root!" y no admite override, que es decision de upstream). Con la premisa
  caida, cada `install: brew ...` sin `install_linux` es una capacidad que esa
  maquina no puede instalar, y el catalogo no lo decia.
  Medido sobre una instancia real: de las 16 CLIs que hacian falta, 8 no tenian
  NINGUN dato de Linux y hubo que resolver a mano su release, su artefacto y su
  archivo de checksums; las otras 8 salieron bien solo porque su install ya era
  portable (npm/uv/go), no porque el catalogo lo declarara. O sea que comandos
  que existen, son estables y publica el fabricante se reconstruian desde cero
  en cada instalacion.
  Ahora las 23 que faltaban declaran su camino: `install_linux` pasa de 3 a 26.
- [x] **El criterio de que es `auto` y que es `manual`, porque no es cosmetico.**
  `auto` solo donde hay UN comando no interactivo de un canal que el catalogo YA
  usa y cuyo paquete se verifico en vivo (go install, npm, uv, cargo, y los
  instaladores oficiales de helm y uv). Es el patron que el propio reporte midio
  funcionando: las 8 CLIs que salieron bien eran las de install ecosistema-nativo.
  El resto queda `manual` con la URL oficial del fabricante, que hace que
  `require` compruebe presencia y NOMBRE de donde sacarlo. Dos razones:
  `install_linux` es UN campo para todo Linux, asi que un `apt-get` romperia en
  Fedora; y un comando de descarga que no pude ejercitar es peor que un enlace
  correcto, porque falla en la maquina de otro y con un error que no es el suyo.
- [x] **Y el ratchet, que es lo que lo convierte en un arreglo.** `test_catalog`
  exige que toda capacidad con `install: brew` declare `install_linux`. Sin eso,
  la proxima capacidad que se agregue reabre el hueco y se descubre igual que
  esta vez: en una maquina, a mano, resolviendo releases uno por uno.
- Pendiente declarado, que NO se toco acá: el `install_linux` de kubectl (el que
  ya existia) baja un binario con curl y lo hace ejecutable SIN verificar el
  checksum del fabricante, teniendo kubernetes publicado su `.sha256`. Es la
  misma clase de agujero de cadena de suministro para gcloud y kargo. Cambiarlo
  a ciegas seria tocar un comando que hoy funciona sin poder ejercitarlo en
  Linux, asi que va como issue aparte y no colado acá.
