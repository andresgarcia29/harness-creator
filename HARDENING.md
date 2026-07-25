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
- [ ] **El dedupe de `harness-bug.sh` tiene dos llamadas de red entre el chequeo
  y la escritura del ledger.** Diez sesiones tropezando con el mismo bug del
  plugin (que es exactamente el escenario) pasan todas los tres controles antes
  de que la primera escriba: issues duplicados en el repo público.
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
  dos ships concurrentes del mismo repo. `ship.sh.tmpl:108-110`,
  `harness-janitor.sh:22-23`.
- [x] **`gh run list --limit 1` puede vigilar el run anterior.** En la ventana
  entre el push y la creación del run, devuelve el run previo; si ese estaba
  rojo, `red()` declara rojo un deploy que ni siquiera arrancó y propone
  revertirlo. `deploy-watch.sh.tmpl:155-158`.

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
