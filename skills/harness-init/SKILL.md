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
     (harness-policy.json + harness-policy.py + smart.md + ship.sh) y
     **pasos-custom** (smart.md + harness-policy.json + pipeline-steps.sh +
     doctor.sh: el /smart nuevo llama a pipeline-steps.sh y usa la parada
     custom_step_failed que solo existe en el policy.json nuevo) y
     **modelos** (models.yaml esquema aliases + stamp-models.sh +
     cron-runner.sh + re-estampado). La lista completa y las migraciones
     de esquema viven en `commands/harness-update.md`.
  6. Al final: `bash scripts/stamp-models.sh` si tocaste models.yaml o
     agentes, re-corre el doctor, y actualiza el rastro (`.harness-version`
     y `.harness-templates`) COPIÁNDOLO de las fuentes de la tabla, nunca
     de memoria.
  7. **Y verificá que aterrizó: `bash scripts/harness-version.sh --verify`.**
     No declares el update terminado sin esto. Compara la instancia contra el
     último TAG de upstream en los dos ejes, número y digest de templates, y
     el segundo es el que importa: el número puede quedar bien mientras el
     contenido no, que es exactamente el fallo de los 24 conflictos. También
     mira el plugin EN DISCO, porque si `/plugin marketplace update` no corrió,
     regenerar desde ahí produce una instancia vieja que reporta éxito igual.
     Rojo se dice como rojo: **el update no aterrizó**, y qué quedó sin
     aplicar. Exit 2 no es éxito: es un update SIN VERIFICAR.
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

Y escribe `.serena/project.yml` con los lenguajes del inventario (#214).
NO lo generes vos ni lo edites: si Serena lo autodetecta sola, detecta
`[bash]` desde la raíz del workspace, y con `repos/` gitignoreado más el
default `ignore_all_files_in_gitignore: true` no ve UNA línea del código
de la plataforma. Si el script avisa de language servers OMITIDOS, decilo
en el resumen con su línea de instalación: un server que no arranca
bloquea la inicialización de TODOS, no solo la suya.

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
2. **Flujo a main**: `trunk-direct-to-prod` | `trunk-merge-commit` |
   `trunk-staging` | `prs`. Usa EXACTAMENTE esas cadenas en el answers:
   `ship.sh` las lee, implementa la primera, la segunda y `prs`, y con
   `trunk-staging` se niega a pushear en vez de contradecir la política
   elegida (antes la registraba y pusheaba a main igual).
   Direct-to-prod → gates estrictos + gitleaks obligatorio.
   **Preguntá si quieren poder deshacer un cambio grande de un tirón**: si la
   respuesta es sí, es `trunk-merge-commit`. Aterriza igual y con los mismos
   gates, pero deja un merge commit, y entonces revertir es
   `git revert -m 1 <sha>` en vez de averiguar el rango exacto de un
   fast-forward, que el humano no tiene a mano en el momento en que lo
   necesita. El costo es una historia con merges en la trunk.
   Esta respuesta se puede cambiar después editando `flow` en el answers:
   `ship.sh` lo relee en cada corrida, sin re-instanciar.
3. **DAG**: propón el orden inferido (contracts → shared → services →
   frontends) y pide corrección.
4. **Ownership por abogado**: qué posee / no posee / invariantes.
   Respuestas cortas; van a las constituciones DRAFT.
5. **Capacidades**: presenta el catálogo
   (`${CLAUDE_PLUGIN_ROOT}/catalog/capabilities.yaml`) FILTRADO por
   detect, agrupado por categoría, con tu recomendación marcada. Por
   cada una el humano puede DEGRADAR el tier, PERO solo es real si la
   capacidad declara `config_read_only:` en el catálogo. Degradar el tier
   NO cambia por sí solo lo que el servidor puede hacer: el `.mcp.json` se
   genera del campo `config`, y nadie lee `tier:`. Si la capacidad no
   declara `config_read_only`, dilo en la entrevista con estas palabras:
   *"puedo registrar la preferencia, pero la restricción real la da el
   alcance del TOKEN que le pases, no esta configuración"*, y ofrécele
   emitir un token de menos permisos o no instalarla. Prometer un
   read-only que no se aplica es peor que no ofrecerlo: el humano cree
   que revocó escritura. Registra nombre + bin/mcp + tier + `scope:` (core |
   cronjob, según el campo `cronjob:` del catálogo). REGLA: los cronjobs
   viven en un repo aparte (#12), así que NO palomees capacidades cuyo ÚNICO
   consumidor es un cronjob salvo que el humano diga que va a usarlo;
   regístralas comentadas como "solo para harness-cronjobs". Las `phase: 2` se mencionan como
   siguientes pasos, no se instalan.
6. **Tickets**: `linear` | `github` | `jira` | `none`. Los CUATRO están
   implementados en `ticket-pull.sh` y `ticket-close.sh` (antes solo
   existía Linear y para github la tabla decía "adapta los contratos", o
   sea un script improvisado sin template ni test). Si elige github,
   pregunta también el **repo de los issues** (`owner/repo`) y regístralo
   en `tickets.repo`: sin eso el script no sabe de qué repo es el issue
   `123`. Si elige jira NO hace falta repo (la key viaja en el ID:
   `PROJ-123`), pero SÍ hace falta decirle que Jira Cloud pide tres
   variables y autentica con Basic `email:api_token`, no con bearer:
   `JIRA_URL`, `JIRA_EMAIL` y `JIRA_API_TOKEN`. En los tres casos el
   harness solo lee, mueve labels y comenta; nunca edita el cuerpo ni
   cierra el ticket fuera de `/archive`.
7. **Memoria**: engram sí/no; perfiles (default: orquestador y
   arquitecto SOLAMENTE). La respuesta va a `memory.provider` del answers
   Y a `{{MEMORY_PROVIDER}}` del CLAUDE.md: es la MISMA respuesta en los
   dos lados, y si no la estampas la constitución queda diciendo el
   nombre de una variable en vez del de la herramienta. Antes vivía en
   una perilla propia (MEMORY_TOOL) que la entrevista nunca preguntaba,
   así que TODAS las instancias nacían con el placeholder literal y el
   agente leía una instrucción sobre una herramienta sin nombre.
   **Con `provider: none` no dejes el bloque puesto**: borra la sección
   `## Memoria` del CLAUDE.md y los pasos `mem_search`/`mem_save` de los
   prompts (arquitecto, /ship, /smart, /promote, docs/pipeline.md). Una
   instrucción que manda llamar a una herramienta que no existe se paga
   en cada tarea, con el agente buscando una tool que nadie configuró.
8. **Secretos**: vault | gcp-secret-manager | aws-secrets-manager |
   doppler | sops | 1password | env. RECOMIENDA desde
   `inventory.json → secret_hints` (el discovery detecta .sops.yaml,
   doppler.yaml, op://, aws_secretsmanager/google_secret_manager en
   terraform, VAULT_ADDR, .env.example) — evidencia, no adivinanza.
   Cuando `secret_hints` viene vacío o empatado, desempata con la NUBE:
   `summary.aws` no vacío y `summary.gcp` vacío hace de
   `aws-secrets-manager` la opción por defecto, y al revés con
   `gcp-secret-manager`; con las dos no vacías es multi-cloud y ahí sí se
   pregunta, porque la evidencia no alcanza para elegir. Estas dos señales
   se medían desde el discovery y no desempataban NADA: un workspace con 39
   repos de Terraform sobre AWS llegaba a esta pregunta igual que uno sin
   nube. No reemplaza a `secret_hints`: es el desempate de abajo.
   Si vault: VAULT_ADDR y path base del KV (solo referencias). El
   TOKEN nunca se pide por chat: bootstrap.sh lo pide interactivo
   (read -s directo al archivo) y VALIDA su vigencia — un token
   muerto se detecta y se re-pide, no se reporta como presente.
8b. **Forge** (dónde viven los repos): `github` | `gitlab` | `bitbucket`.
    Normalmente se DETECTA del remote y no hace falta preguntar; pregunta
    solo si el remote es un self-hosted con dominio propio, y registra
    `forge:` en answers para que `scripts/forge.sh` no tenga que adivinar.
    Los 13 cronjobs entregan sus PRs e issues por esa capa.
9. **Deploy** (si hay CD): org de GitHub, prefijo de apps ArgoCD,
   proyecto Kargo, tenant canary, y ROLLBACK_MODE auto|manual
   (recomienda auto: rollback primero, diagnóstico después).
   **Y el driver POR REPO que deploya**: `gitops` | `actions` | `none`,
   al bloque `deploy:` del answers (`{{DEPLOY_LIST}}`; sin declaraciones,
   deja el bloque solo con los ejemplos comentados). Sin esta respuesta
   `answers_driver()` de deploy-watch es código muerto y el driver sale
   solo del `kind` del manifest, que manda a `none` seis de nueve kinds:
   una library con workflow de release o un infra-live que auto-aplica
   quedan SIN verificación post-ship y nadie lo dice. Recomienda desde la
   evidencia: los repos con workflows de deploy en `.github/workflows/`
   (deploy/release/apply en el nombre o un `on: push` a la trunk) son los
   candidatos; `kind: service|frontend|mobile` ya caen a gitops solos y
   no hace falta declararlos.
   **Y los repos con `atlantis.yaml`** (los lista `summary.atlantis` del
   inventory): aplican infra al MERGEAR, por un comentario en el PR y sin
   workflow propio, así que su `kind` los manda a `none` y nadie los
   verifica. Van con `driver: actions` y un `verify_cmd` que interroga al
   recurso aplicado, no al plan; o con `driver: none` MÁS `verify_cmd`, que
   deploy-watch trata como verificado (salta CI/gitops y corre el verify) y
   es lo correcto cuando no hay run de Actions que mirar. Lo mismo para los
   repos de `summary.lambda`: el artefacto es la función, y se pregunta por
   ella (`aws lambda get-function --function-name <fn>`), no por el apply.
   **Y los repos de `summary.kafka`**: un consumidor puede desplegar verde y
   no estar consumiendo (grupo sin asignar, deserializador roto, topic mal
   nombrado), y un `curl` al pod no lo ve. Su verify natural es el LAG del
   consumer group, que no crece: con `confluent-mcp` es
   `get-consumer-group-lag`; sin él, `kafka-consumer-groups --describe`. Es
   la misma regla que el resto del item: se interroga al artefacto, y para un
   consumidor el artefacto es el avance del offset, no el proceso vivo.
   **Y por cada repo con driver, el verify post-deploy** (claves planas a
   4 espacios: `verify_cmd`/`verify_expect`/`verify_timeout`): un comando
   que interroga al ARTEFACTO desplegado, para TODOS los drivers (con
   `none` es la única señal). Ofrece los dos primitivos de campo: leer el
   asset DESDE el pod (no del CDN que cachea) y comparar pod vs CDN con
   `curl --compressed`. En los repos de `summary.compose` del inventario
   (traen `docker-compose*.yml`) ya existe un stack de dependencias
   declarado, así que el verify puede levantarlo en vez de inventar mocks; era
   otra señal medida desde el discovery que no despachaba nada. Si la tarea encadena publish/bump entre repos,
   pregunta también `post_ship` (lo ejecuta ship-wave tras aterrizar el
   repo). Y si el flujo usa túneles locales (port-forward a un cluster),
   llena el bloque `port_forwards:` (`{{PORT_FORWARDS_LIST}}`; sin
   túneles, déjalo solo con los ejemplos comentados): puerto, cmd y la
   sonda de IDENTIDAD (el status esperado SIN credenciales; un 401
   esperado ES identidad válida).
10. **Modelos**: primero el PROVEEDOR (anthropic | vertex | bedrock |
    kimi | minimax | openrouter; default anthropic; si eligió otro,
    recuérdale verificar los IDs de la sección `models.<provider>`
    contra su catálogo y las env vars del backend). Después el sandwich
    EN ALIASES con esta recomendación default (la semántica vive en
    models.yaml): **deep = el pensador** (orquestador, architect,
    abogados, escalación), **smart = el productor** (implementer,
    reviewer, qa), **fast = lo especificísimo** (mechanical y cronjobs
    cheap; en anthropic es Sonnet, y solo ahí). En anthropic deep y
    smart son el mismo modelo (Opus 5): lo que los separa es el
    esfuerzo de razonamiento, no el ID. Las respuestas se estampan como
    ALIASES en `models.yaml`; los IDs reales los materializa
    `scripts/stamp-models.sh` en el frontmatter de los agentes.
    **Pregunta también el alias de ESCALACIÓN** (default: deep): es el que
    usa /smart al relanzar un agente atascado y el tier `expensive` de los
    cronjobs. `models.yaml` lo referencia en dos lugares, así que sin
    respuesta el placeholder `{{MODEL_ESCALATION}}` queda literal,
    `stamp-models.sh resolve escalation` falla y cron-runner le pasa la
    cadena cruda a claude. Va a `models.escalation` del answers.
    `loop_budget` default 3. Si el humano quiere deep en TODO,
    advierte la latencia comprada donde no hay decisión (las reglas del
    tier deep de models.yaml) y registra la decisión.
9c. **¿Cuánta gente va a instalar este harness?** Si es más de una (cada
    quien en su máquina, todos contra los mismos repos remotos), hay una
    consecuencia que hay que decidir ACÁ, porque después se paga cara:
    - **`instance.repo` compartido**, no `self`. La spec maestra, los ADRs, la
      constitución y `docs/architecture/map.md` son los desempates del
      enrichment y del RFC. Con `self` cada persona tiene su propia
      legislación divergiendo en silencio: uno ratifica un ADR el lunes y otro
      litiga contra la ley vieja el martes, con toda la ceremonia en verde.
10a. **Profundidad de planeación** (no preguntes, informa): los planes,
    la síntesis del RFC y los ADRs se escriben en modo **ultrathink**, y
    el architect trabaja como hilo fino descomponiendo en probes
    (`minion_decompose: auto` = ON en standard/full, OFF en express).
    Solo pregunta si el humano quiere apagarlo (`false`), y anota que el
    intercambio es: más razonamiento en el plan a cambio de menos rondas
    de review, que es donde se van los minutos.
10b. **Autonomía de /smart**: full | checkpoint (recomendado para las
    primeras semanas). checkpoint = UNA sola pausa, un resumen antes
    del primer ship a main; full = ninguna pausa, los gates y el canary
    son la red. En ambos casos /smart redacta criterios y resuelve
    ambigüedad solo (ledger de supuestos): la autonomía gradúa cuándo
    se toca main, NO cuánto piensa el humano. Si el humano quiere
    conducir fase por fase, no usa /smart: usa los comandos sueltos.
11. **Principios del proyecto** para la constitución: 2-4 reglas
    innegociables propias del dominio (ej. multi-tenancy, localización)
    — van a `docs/constitution.md` §6, DRAFT hasta ratificar.
12. **Cronjobs self-healing**: este harness YA NO LOS INSTALA. Viven en
    `andresgarcia29/harness-cronjobs`, un repo aparte, porque su unidad de
    ejecución no es "cada quien" sino "una vez": entregan PRs e issues contra
    repos compartidos con un ledger local, así que N instalaciones producían N
    PRs duplicados del mismo hallazgo. MENCIÓNALO en una línea y sigue: si el
    humano los quiere, se clonan aparte y se apuntan a este workspace (leen su
    `models.yaml` y usan su `scripts/forge.sh`). No palomees capacidades cuyo
    ÚNICO consumidor sea un cronjob salvo que diga que va a usar ese repo.
13. **Versionado de la instancia**: ¿el workspace se versiona en sí
    mismo (git init aquí) o existe un repo destino (ej.
    `acme-harness`)? Registra `instance.repo` en answers. Si un repo
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
| `.harness-version` | **se LEE de `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` (campo `version`), jamás se escribe de memoria** | siempre. Esta fila decía solo "versión del plugin" y no nombraba la fuente: una instalación real escribió `0.60.0`, un número que no existe en ningún origen del plugin y que por contenido era MÁS VIEJO que 0.47.0. Un número inventado es peor que ninguno, porque `make version` lo compara y concluye que estás al día. Si no podés leer el archivo, dejá `.harness-version` SIN crear y decilo: la ausencia es honesta, el invento no |
| `.harness-templates` | SOLO el VALOR del `digest:` de `templates/MANIFEST.sha256` (los 64 hex, sin el prefijo ni nada mas) | **siempre, y esto no es opcional**: es el rastro de CON QUÉ SET se generó esta instancia. El número de versión no alcanza y se aprendió caro: un generador escribió la versión nueva habiendo generado desde templates viejos, produjo 24 conflictos que no traían ninguno de los arreglos que el número prometía, y nada en su salida lo decía. Un generador que no deja este rastro deja una instancia que nadie puede auditar. `make version` lo compara contra upstream y detecta el drift de CONTENIDO, no solo de número |
| `Makefile` | Makefile.tmpl | siempre |
| `.gitignore` | gitignore.tmpl | siempre: COPIA LITERAL del template, no una lista que reconstruyas de memoria. Cada entrada trae su porqué en el archivo. Cuando esto era prosa dentro de esta tabla, el generado se divergió en los dos sentidos: le faltaban `go.work`, `go.work.sum` y `graphify-out/` (128 MB del grafo entrando a un `git add -A`, con `git init` + `make graph` invitando al accidente) y le sobraban dos que la tabla no mencionaba (issue #27). Si hay que cambiar la lista, se cambia el template |
| `.claude/settings.json` | settings.json.tmpl | siempre (hooks + denials read-only + bloque `env`). El `env` no es decorado: lo que se declara ahí llega al ENTORNO DE LOS HOOKS y al de todo proceso que la sesión lance, incluido el `claude -p` que `orchestrator-watch.sh` levanta por tarea. De ahí cuelga `PONYTAIL_DEFAULT_MODE`, la perilla del plugin ponytail (`off\|lite\|full\|ultra`), fijada en `lite`. Es una elección de COMPORTAMIENTO y no de costo, y la distinción se midió corriendo el hook: `lite`, `full` y `ultra` inyectan el mismo ruleset salvo por unos 6 tokens (~1400 cada uno), y la única palanca que ahorra es `off`, que inyecta 2 bytes. O sea que bajar de `full` a `lite` para "gastar menos" no gasta menos: si lo que se busca es recortar los ~1400 tokens que se pagan por CADA nodo del DAG, el valor tiene que ser `off`. La var es inerte para quien no tenga el plugin instalado |
| `.claude/hooks/{block-direct-push,guard-canonical}.sh` | hooks/ | siempre (fail-CLOSED: bloquean) |
| `.claude/hooks/guard-build-slot.sh` | hooks/ | siempre (fail-OPEN: bloquea `docker build/run` pelado, Ley 8; ya registrado en settings.json.tmpl junto a block-direct-push) |
| `.claude/hooks/guard-gcloud.sh` | hooks/ | siempre (fail-OPEN: bloquea `gcloud/gsutil` pelado, que depende de la sesión humana y caduca en horas; su mensaje de error ("run gcloud auth login") es una ORDEN que el agente obedece, y frena la tarea teniendo el wrapper al lado). Se AUTO-APAGA si la instancia no tiene `scripts/gcloud.sh`: sin camino verde que ofrecer no hay nada que bloquear, así que instalarlo donde no aplica no cuesta un token (mismo trato que mem-recall.sh sin engram). Escape declarado: `HARNESS_GCLOUD_HUMANO=1` para lo que debe quedar atribuido a una persona en los audit logs |
| `.claude/hooks/{track-read,ui-emit}.sh` | hooks/ | siempre (fail-OPEN: observan, `async: true`). track-read alimenta `gate_evidence` de ship.sh; ui-emit alimenta `make ui`. track-read registra TAMBIÉN las tools de Serena (por eso su matcher incluye `mcp__serena__.*`): la lectura simbólica no dejaba rastro, así que el implementer que obedecía la constitución llegaba a gate_evidence sin una línea en el log y el gate lo acusaba de citar lo que "nadie leyó". El camino barato para pasarlo era volver a grep, o sea que el incentivo apuntaba contra la propia ley. Reconstruye la ruta con el proyecto que vio en `activate_project` (Serena entrega rutas relativas al proyecto activado), así la tarea se sigue derivando de la RUTA |
| `.claude/hooks/guard-symbol-grep.sh` | hooks/ | siempre (fail-OPEN, registrado en PreToolUse `Grep`). La otra mitad de lo mismo: avisa UNA vez por tarea cuando alguien grepea algo con forma de SÍMBOLO dentro de un worktree teniendo serena en `.mcp.json`, y da el `find_symbol` equivalente. Se calla si no hay serena, fuera de un worktree, ante una regex de verdad o ante una palabra suelta de prosa (`timeout`, `TODO`): exige identificador COMPUESTO o declaración (`func X`, `class Y`). Muerde UNA vez y el mensaje dice que repetir el mismo Grep pasa, porque un aviso sobre la tool más usada del harness no puede dejar a nadie atascado. NO cubre `rg`/`grep` por Bash: adivinar el patrón dentro de una línea de shell garantizaba falsos positivos, y la precisión vale más que la cobertura en un aviso que no debe volverse ruido |
| `.claude/hooks/guard-worktree.sh` | hooks/ | siempre (registrado junto a guard-canonical en Edit\|Write\|MultiEdit). Un worktree tiene UN dueño: la primera sesión que escribe lo reclama y otra sesión que intente escribir ahí se bloquea. Es la única guarda del tramo de edición concurrente (el lock de ship.sh es por repo y solo cubre el push; build-slot es por máquina y solo cubre builds). Fail-OPEN a diferencia de los otros guards: coordina, no prohíbe, y una colisión es recuperable con git |
| `.claude/hooks/guard-broad-add.sh` | hooks/ | siempre (fail-CLOSED, registrado en PreToolUse Bash). Bloquea `git add -A/--all/-u/.` y `git commit -a` dentro de un worktree que el DAG declara COMPARTIDO por dos o más tareas del mismo repo. El árbol es `worktrees/<task>/<repo>`, o sea UNO por (tarea, repo), y la doctrina decía lo contrario: sobre esa premisa falsa un add amplio se llevó seis archivos de la tarea vecina al commit ajeno. Con una sola tarea del repo en el DAG no molesta (el add amplio ahí es legítimo), y sanea comillas y heredocs antes de mirar para no confundir un mensaje de commit con un comando. `POLICY-DAG-010` cubre la otra mitad: impide PLANIFICAR el paralelo intra-repo |
| `.claude/hooks/guard-ws-scripts.sh` | hooks/ | siempre (fail-CLOSED con remediación exacta, registrado en PreToolUse Bash). `scripts/<x>.sh` relativo desde un worktree no resuelve (6-8 round-trips perdidos en campo); bloquea SOLO con doble existencia (el harness tiene el script y el worktree no) y da la línea corregida con `$CLAUDE_PROJECT_DIR`. Fail-open ante todo lo demás |
| `.claude/hooks/on-compact.sh` | hooks/ | siempre (fail-OPEN: observa, registrado en `PreCompact`, `async: true`). La señal de contexto agotado: deja `tasks/<id>/.compacted` (derivando la tarea del puntero por sesión de track-read) y emite el evento al bus. record-cost mide dólares; sin esto nada medía ventana, y en campo el humano tuvo que avisar a mano |
| `.claude/hooks/mem-recall.sh` | hooks/ | siempre (fail-OPEN: observa, registrado en `SessionStart`). El eslabón que le faltaba a engram: la capability se instalaba como MCP y NADIE la leía (medido: 288 observaciones acumuladas, 0 consultadas). Imprime el recordatorio de `mem_context`/`mem_search` al arrancar la sesión, y se AUTO-APAGA si `.mcp.json` no declara engram, así que instalarlo donde no se eligió no cuesta un token (issue #101) |
| `.claude/hooks/session-summary.sh` | hooks/ | siempre (fail-OPEN: observa, registrado en `SessionEnd`). Al cerrar la sesión escribe `.harness/sessions/<id>.md` con lo que el harness decidió, derivado de `.harness/events.jsonl`. Es determinista a propósito: el agente que resume de memoria omite justo el gate rojo y el supuesto sin confirmar |
| `scripts/instance-ship.sh` | scripts/ | siempre. La puerta a main del REPO DE LA INSTANCIA (issue #37): el hook bloqueaba el push y ship.sh solo opera sobre repos/, así que el commit de cada /harness-update se pusheaba a mano por fuera del harness. Gates que SÍ aplican acá: ningún archivo del push con ediciones sin commitear (el árbol de la instancia es COMPARTIDO entre tareas, así que la suciedad ajena se aparta con autostash en vez de bloquear), rebase, gitleaks sobre el rango (el riesgo número uno en el repo que versiona la config) y doctor sin FAIL; el push vive DENTRO del script, igual que en ship.sh |
| `scripts/instance-repo.sh` | scripts/ | siempre. Se SOURCEA: contesta quién es el repo de la INSTANCIA (`instance.repo` del answers), que es el único del workspace sin `repos/<repo>` ni worktree. Lo consultan `verdict-scaffold.sh` (para sellar contra el árbol del workspace) e `instance-ship.sh` (para registrar la fase tras el push). Vive en un solo archivo porque dos lecturas del mismo campo divergen justo cuando una tarea queda sin veredicto |
| `scripts/verdict-beads.sh` | scripts/ | siempre. non_blocking → beads como comando: por cada entrada sin bead, `bd create` + reescritura a `{text, bead}` (idempotente, atómico por entrada; sin bd sale honesto). `POLICY-ARCHIVE-002` lo exige antes de archivar cuando bd existe: tasks/ es gitignoreado y un hallazgo archivado sin bead deja de existir (Ley 7) |
| `scripts/ship-wave.sh` | scripts/ | siempre. La tarea entera en orden del DAG (`harness-policy.py dag-order`): salta lo aterrizado, ship.sh por repo, y el hook `deploy.<repo>.post_ship` de answers tras cada uno (bajo with-secrets). Con flow: prs difiere el post_ship hasta el merge. Antes el orden del DAG era prosa que nadie ejecutaba y las cadenas publish/bump se corrían a mano |
| `scripts/port-forwards.sh` | scripts/ | siempre. Túneles supervisados con sondas de IDENTIDAD (no de vida): puertos declarados UNA vez en answers (`port_forwards:`), `ensure` relevanta muertos, y un 200 donde se esperaba 401 se reporta como OTRO proceso en el puerto (el port-forward viejo de otra cosa). curl siempre con --compressed |
| `scripts/mark-read.sh` | scripts/ | siempre. El registro de lecturas para agentes SIN el hook track-read (Cursor, Kimi Code: AGENTS.md promete que pueden operar el harness): apunta en `tasks/<id>/evidence.log` un artefacto que se abrió de verdad, verificando que exista bajo el workspace o el worktree. Sin esto, gate_evidence era impasable fuera de Claude Code y la única salida era editar el log a mano, que anula el gate |
| `scripts/harness-version.sh` | scripts/ | siempre (`make version`). Contesta las dos preguntas que se hacen juntas: si la instancia está al día contra upstream, y qué está pasando ahora (tareas con su fase, sesiones, worktrees tomados, supuestos sin confirmar). Marca las tareas cuya fase no coincide con su historial, que es lo que hace fallar el ship tras un update. Si no puede comparar contra upstream lo DICE: no reporta "al día" |
| `scripts/forge.sh` | scripts/ | siempre. La capa de forge: `forge_ci_failed`, `forge_issue_create`, `forge_pr_create`, con drivers github (gh) y gitlab (glab). Los 13 cronjobs entregan por aquí; antes tenían `gh` cableado y en cualquier otro forge entregaban a la nada, en silencio |
| `scripts/ui/{panel.sh,server.py,pricing.json,dist/}` | ui/ | siempre — el panel (`make ui`). `panel.sh` prefiere el **daemon Go `harnessd`** (multi-máquina, terminales en vivo, sonda de MCP, archivar, liveness) y lo baja del release privado si falta; cae a `server.py` (Python stdlib) si no hay binario. El frontend React viaja COMPILADO en dist/ (la fuente vive en el plugin, `templates/ui/web/`) — el usuario jamás necesita Node |
| `.claude/agents/{architect,implementer,reviewer}.md` | agents/*.tmpl | siempre |
| `.claude/agents/qa.md` | agents/qa.md.tmpl | si hay frontend/mobile o canary |
| `.claude/agents/<abogado>.md` | agents/svc-agent.md.tmpl | UNO por cluster; `status: DRAFT` |
| `.claude/commands/{feature,rfc,implement,review,ship,promote,archive,smart,quick}.md` | commands/*.tmpl | siempre. El par de entrada es /smart y /quick: /smart es el pipeline completo sin intervención humana, dimensiona el carril por vos y acepta ticket O prompt literal (autonomy en answers: full \| checkpoint); /quick es el carril que YA dimensionaste vos, cero deliberación y los mismos gates |
| `.claude/commands/auto.md` | commands/auto.md.tmpl | siempre POR AHORA, y es un archivo de DEPRECACIÓN: pocas líneas, cero reglas adentro, que mandan a correr `/smart` con los mismos argumentos. El comando se renombró porque el nombre viejo chocaba con el comando homónimo de otras herramientas (Kimi Code) y el harness es multi-herramienta por diseño. La fuente de verdad es `smart.md`: si este puntero crece o repite una regla, ya empezó a mentir. Se borra en el ciclo que viene, cuando el panel deje de emitir su hint al nombre viejo |
| `models.yaml` | models.yaml.tmpl | siempre — LA perilla de modelos: provider + aliases (fast\|smart\|deep) por proveedor + rol→alias + overrides por agente |
| `AGENTS.md` | AGENTS.md.tmpl | siempre — el mapa en el estándar multi-herramienta (Cursor, Kimi Code, Codex, Gemini CLI…): leyes, playbooks, modelos, dónde está la verdad. CLAUDE.md sigue siendo el de Claude Code; ambos se generan, ninguno es symlink |
| `scripts/stamp-models.sh` | scripts/ | siempre — materializa models.yaml en el frontmatter de los agentes (`make models`); `resolve <alias\|rol>` lo usan /smart --model y cron-runner |
| `docs/constitution.md` | docs/constitution.md.tmpl | siempre (DRAFT; §6 desde entrevista #11) |
| `specs/<capability>/spec.md` | docs/spec.md.tmpl | UNO por dominio de ownership (esqueleto DRAFT; la arqueología los llena) |
| `docs/harness/testing-policy.md` | docs/testing-policy.md.tmpl | siempre |
| `ratchets.json` | inline: `{}` | si eligió ratchet-keeper |
| `scripts/doctor.sh` | COPIA de `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh` | siempre (instancia autocontenida) |
| `.github/workflows/harness-gates.yml` EN CADA REPO GESTIONADO | ci/harness-gates.yml.tmpl | solo si `flow: prs`. Mueve los gates a infra NEUTRAL: hasta aca corrian en la laptop del que pushea, y con un equipo eso significa que la verificacion vale hasta la laptop menos actualizada. Corre `ship.sh --ci`, o sea EL MISMO codigo (un workflow que reimplemente los gates se desincroniza en la primera version y entonces CI y local dicen cosas distintas del mismo commit). `{{BASE_BRANCH}}` sale de `origin/HEAD` del repo y `{{HARNESS_INSTANCE_REPO}}` de `instance.repo`. OJO: el workflow NO se vuelve obligatorio solo; hay que marcarlo como required check y activar la merge queue en la proteccion de rama, y eso lo hace un humano en el forge |
| `scripts/bootstrap.sh` | scripts/bootstrap.sh.tmpl | siempre — {{ENSURE_LINES}} se llena con UNA línea `ensure`/`require` por capacidad elegida, derivando el comando real del campo `install:` del catálogo. REGLA de decisión: la manda el campo `install_kind:` del catálogo, NO tu lectura del texto: `auto` → `ensure <bin> <install>` (auto-instala); `manual` → `require <bin> "<install>"` (solo verifica). Ej.: gcloud (`install_kind: auto`) → `ensure gcloud brew install --cask gcloud-cli`; flutter (`manual`) → `require flutter "https://..."`. Inferirlo del texto fue el bug: un generador que solo reconocía `brew` degradó a `require` 8 de 25 capacidades (npm, pip, go install, uv tool, gcloud components), el bootstrap se declaró terminado sin instalarlas y el doctor las reportó en ❌ con la remediación "corre scripts/bootstrap.sh", que ya se había corrido: bucle sin salida (issue #23). Si una entrada vieja no trae `install_kind`, el fallback es la lista CERRADA de package managers: brew, npm, npx, pnpm, yarn, pip, pip3, pipx, uv, go, cargo, gem, apt-get, apt, dnf, yum, winget, scoop, gcloud → `ensure`; una URL → `require`. Si la entrada trae `install_linux:` y el workspace corre en Linux (`uname -s`), usa ESE valor y su `install_linux_kind:` en vez del `install:` por defecto. **OJO con `uname -s`: mide la máquina que GENERA, no la que va a EJECUTAR.** Si la instancia se versiona y se clona a otras máquinas (`instance.repo` apunta a un repo, que es el caso de cualquier equipo), preguntá en qué plataforma van a correr los workspaces y usá ESA. Caso real: se generó en macOS y se clonó a diez VPS Ubuntu; `kubectl` quedó como `gcloud components install kubectl` teniendo el catálogo una variante Linux, y `gcloud` como `brew install --cask`, que en Linux no existe porque no hay casks. Nota util: Homebrew SÍ corre en Linux, así que las fórmulas normales sobreviven al cruce; lo que no sobrevive son los `--cask` y las entradas con `install_linux:` propio: una fórmula de brew sin bottle de Linux deja la capacidad en ❌ sin explicación (issue #24: kargo). Si la entrada trae `post_install:`, añade DESPUÉS de su ensure la línea `command -v <bin> >/dev/null && { <post_install> \|\| true; }` (idempotente, fail-open — ej. graphify registra su skill con `graphify install`) |
| `.claude/skills/skill-creator/SKILL.md` | skills/skill-creator/SKILL.md | siempre — la guía para detectar procedimientos repetidos y empaquetarlos como skills bien formadas; el cronjob skill-miner la sigue |
| `.claude/skills/custom-build-skill/SKILL.md` | skills/custom-build-skill/SKILL.md | siempre: el camino EJECUTABLE de skill-creator (`/custom-build-skill "quiero una skill que…"`). Destila el pedido en gatillo/pasos/herramientas/artefacto/límites, VERIFICA contra `.mcp.json` y el PATH que las herramientas citadas existan antes de escribir (prometer un MCP ausente es el modo de fallo #1: la skill queda perfecta y muere en su primer uso), y escribe en la capa local, que ningún update pisa |
| `.claude/skills/custom-edit-skill/SKILL.md` | skills/custom-edit-skill/SKILL.md | siempre: el par del anterior para cambiar una skill que ya existe. Localiza por nombre aproximado y decide la CAPA antes de tocar el archivo, que es lo que hace la diferencia entre un cambio que sobrevive y uno que desaparece en el próximo `make skills` (`.managed`) o en el próximo `/harness-update` (upstream) sin que nadie lo note |
| `.claude/skills/custom-build-rule/SKILL.md` | skills/custom-build-rule/SKILL.md | siempre: el equivalente para las LEYES propias del workspace (`/custom-build-rule "de ahora en adelante…"`). Su fase cara es el ENRICHMENT: antes de legislar va a ver cómo están las cosas hoy y trae números (cuántos casos ya cumplen, cuáles chocan con la constitución, qué habría que migrar), porque una ley que nace violada por el 70% del workspace es letra muerta y eso solo se ve contando. Escribe `.claude/rules/<id>.md` con `status: DRAFT` y el DIENTE declarado (`enforcement` + `enforced_by`) |
| `.claude/skills/custom-edit-rule/SKILL.md` | skills/custom-edit-rule/SKILL.md | siempre: el par del anterior. Antes de tocar la regla mide cómo se está cumpliendo, y clasifica el cambio en afloja/endurece/aclara: una regla que "nunca se cumple" con `enforcement: judgment` casi nunca necesita otra redacción, necesita un diente, que es el arreglo que nadie pide. Lo que cambia la EXIGENCIA vuelve a DRAFT: la firma anterior era sobre otro texto |
| `.claude/rules/.gitkeep` | inline vacío (Keep) | siempre: dir instance-owned de las reglas custom; el update jamás lo pisa (mismo trato que `.claude/pipeline/`) |
| `docs/harness/rules.md` | docs/rules.md.tmpl | siempre: el contrato de las reglas custom (frontmatter, la tabla de dientes, qué valida el doctor y cómo llega la regla a los agentes) |
| `docs/harness/rationale.md` | docs/rationale.md | siempre: el archivo de casos. Cada regla del harness nació de un incidente y la costumbre era dejar el incidente PEGADO a la regla dentro del prompt. Eso se paga por TURNO: un prompt se re-lee en cada tool call del agente que lo carga, y medido sobre 663 transcripts releer contexto es el 43% de la factura. Acá vive el caso; en el prompt queda la regla con la razón corta. Nada se borró de la ley: si una regla desapareció del prompt, es un bug |
| `docs/tareas/` | (lo llena `/archive`) | siempre: una nota por tarea archivada, VERSIONADA. `tasks/` esta gitignoreado, asi que con N ingenieros son N maquinas y cero aprendizaje compartido; el repo de la instancia ya lo clonan todos, o sea que ES el cerebro compartido y lo unico que faltaba era escribir ahi. La escribe `scripts/task-note.py`: rellena lo VERIFICABLE desde artefactos (costo real, rondas, ledger separando lo medido de lo asumido, veredictos con tardios) y deja marcado lo de JUICIO, mismo reparto que verdict-scaffold. Es un vault de Obsidian sin hacer nada. Los agentes NO la leen por defecto: lo que un agente lee se paga en cada tool call suyo |
| `scripts/harness-sink.py` + `metrics-sink.json` | scripts/ | siempre: el destino de los datos. `setup` es interactivo y **PRUEBA la conexion de verdad** antes de activar Postgres: un setup que acepta un DSN porque parece un DSN te deja creyendo que quedo configurado y te enteras recien al archivar. El ARCHIVO (`docs/metrics/<tarea>.jsonl`, uno por tarea para no chocar en el merge) es el piso y no se puede apagar; Postgres es opcional y su fallo AVISA en vez de frenar el archivado. La contrasena NUNCA entra al config, que se versiona: se guarda el NOMBRE de la variable y el valor lo inyecta with-secrets.sh. Grano de AGENTE, no de tarea: el 87% del gasto vive en el orquestador y eso solo se ve asi |
| `scripts/ship.sh` | scripts/ship.sh.tmpl | siempre |
| `scripts/worktree-task.sh`, `scripts/quiet.sh`, `scripts/with-secrets.sh` | scripts/ | siempre. `worktree-task.sh --node <Tn>` crea el árbol de UN NODO del DAG (`worktrees/<id>/<repo>@<Tn>`, rama `task/<id>@<Tn>`): es lo que permite paralelizar dos tareas del mismo repo con `files[]` disjuntos. La rama lleva `@` y no `/` porque `refs/heads/task/<id>` y `refs/heads/task/<id>/<Tn>` no pueden coexistir en git |
| `scripts/dag-coalesce.sh` | scripts/ | siempre. Junta el trabajo de los worktrees de nodo en `task/<id>`: cherry-pick en orden topológico del DAG (`harness-policy.py dag-nodes`), comparando por PARCHE (re-correrlo no duplica). Un conflicto ABORTA ese cherry-pick, deja el árbol intacto y sale 3: ese nodo se re-implementa en serie, que es el rollback previsto de la fase. Sin él, el paralelo intra-repo no tendría dónde aterrizar |
| `scripts/orchestrator-watch.sh` | scripts/ | siempre (`make orch-status` / `make orch-watch`). El watchdog de la SESIÓN PRINCIPAL, cero tokens: medido sobre 37 corridas, el 51% del reloj (34,4 h de 67,9 h) son huecos de más de 20 min sin un solo evento de bus, o sea orquestadores muertos que nadie relanza (el watchdog de smart.md vigila subagentes; a la sesión principal no la vigilaba nadie). Poller sobre `tasks/*/state.json`: >12 min sin eventos y sin llamada en vuelo → lease atómico en `.harness/claims/` y `claude -p '/smart <id>'` headless. Dos relanzamientos sin progreso (misma fase, mismo HEAD) → pausa `orchestrator_stalled`. Kill switch: `.harness/orch-watch.off` |
| `skills.yaml` | skills.yaml.tmpl | si NO existe (es ley local: declara TUS repos de skills; el update jamás lo pisa) |
| `scripts/skills-sync.sh` | scripts/ | siempre (make skills: instala la capa compartida con marca .managed; la local siempre gana) |
| `scripts/minion-probe.sh` | scripts/ | siempre (patrón MinionS: el supervisor descompone, workers responden en paralelo; activo por carril via `minion_decompose: auto`) |
| `scripts/plan-lint.sh` | scripts/ | siempre: el plan es ejecutable o no es plan, por tarea exige repo/req/archivos/criterios/complexity/deps, cero decisiones abiertas y trazabilidad al delta-spec. Lo corren /rfc y /smart ANTES de implement; un hueco aquí se paga en rondas de review |
| `scripts/pipeline-steps.sh` | scripts/ | siempre (el motor de los pasos custom del pipeline: list/gate; /smart lo llama tras cada fase) |
| `.claude/pipeline/.gitkeep` | inline vacío (Keep) | siempre (dir instance-owned de los pasos custom; el update jamás lo pisa) |
| `.claude/skills/pipeline-step-creator/SKILL.md` | skills/pipeline-step-creator/SKILL.md | siempre (la skill que guía a crear un paso custom) |
| `.claude/skills/harness-bug-report/SKILL.md` | skills/harness-bug-report/SKILL.md | siempre: el protocolo de verificación de un bug DEL HARNESS (¿es real? ¿es del plugin y no de tu instancia? ¿vale la pena arreglarlo?) antes de levantar el issue upstream |
| `scripts/harness-bug.sh` | scripts/ | siempre: el filtro determinista del canal de vuelta: propiedad del artefacto (plugin vs instancia), drift contra el template, versión al día, repro no vacío, dedupe por fingerprint (local + remoto), cuota 3/24h y redacción de secretos. Publica con `gh issue create` en el repo del plugin |
| `docs/harness/pipeline-steps.md` | docs/pipeline-steps.md.tmpl | siempre (el contrato de los pasos custom) |
| `docs/harness/minions-decomposition.md` | docs/minions-decomposition.md | siempre (capacidad MinionS, PROPUESTA/opt-in) |
| `scripts/verdict-scaffold.sh` | scripts/ | siempre (esqueleto determinista del veredicto: el reviewer solo pone juicio; campos mecánicos de fuentes verificables) |
| `scripts/adr-new.sh` | scripts/ | siempre. Reserva el número del ADR de forma ATÓMICA (lock por mkdir más noclobber) y cuenta los que están SIN COMMITEAR, que son los que colisionan. El repo de la instancia NO se aísla por tarea a propósito (guarda la ley compartida), así que dos tareas concurrentes veían el mismo máximo y elegían el mismo número: dos decisiones de arquitectura con el mismo identificador. La Ley 7 de los dos mapas manda usarlo |
| `scripts/pull-all.sh` | scripts/ | siempre (make pull: clones canónicos al último main en paralelo, sucios se saltan con aviso, dispara graph-refresh) |
| `scripts/repo-brief.sh` | scripts/ | siempre — brief determinista por repo (`.cache/briefs/`); arranque en caliente de implementers/reviewers, $0 tokens |
| `scripts/graph-refresh.sh` | scripts/ | si graphify elegido — el ciclo de vida del grafo: build inicial, `--update` incremental, stamp por HEADs. Sin esto, "usa graphify query" es un consejo vacío. Lo llama el BOOTSTRAP (build inicial en el onboarding, antes de la primera tarea), el prefetch de /smart y /rfc, harness-janitor y `make graph` |
| `scripts/harness-policy.py`, `scripts/evidence.py` | scripts/ | siempre — el policy engine v1 (transiciones por carril, escalate, validate-ship) y evidence v1; ship.sh y /smart los invocan |
| `harness-policy.json` | policy.json.tmpl | siempre — leyes ejecutables del flujo: transiciones por carril (express\|standard\|full), paradas permitidas, límites |
| `scripts/build-slot.sh` | scripts/ | siempre (semáforo de builds pesados, Ley 8; universal — perl/flock) |
| `scripts/{gowork,py,fe}.sh` | scripts/ | siempre (loop interno nativo, Ley 9; no-op limpio si el stack no está: Go/Python/frontend) |
| `scripts/bounded.sh` | scripts/bounded.sh | siempre: `run_bounded`, el acotador de llamadas externas. Lo sourcean ship.sh (sondas de los gates) y deploy-watch.sh (las nueve llamadas de red). Mata el GRUPO de procesos y escala a SIGKILL: el idiom anterior (`perl -e 'alarm N; exec'`) mataba un solo proceso y un nieto huérfano dejaba el `$( )` bloqueado igual, o sea que acotaba en el papel y no en el reloj. Sin esto, un watcher se cuelga hasta 35 días (el techo real de un workflow run de GitHub) |
| `scripts/emit.sh` | scripts/emit.sh | siempre — el bus del harness: lo que ship.sh y /smart DECIDEN. Fail-open, redacta antes de escribir. Sin esto el panel solo ve agentes y tokens (la mitad prestada), nunca las decisiones ni los gates (la nuestra) |
| `scripts/secrets.sh` | scripts/secrets.sh.tmpl | siempre (fuente según answers; subcomandos pull\|check\|doctor: doctor cruza lo que los repos declaran necesitar contra lo provisto, con candidato best-effort desde la fuente) |
| `scripts/ticket-pull.sh`, `scripts/ticket-close.sh` | scripts/ticket-*.tmpl | tickets != none. Los tres proveedores (linear, github, jira) son funciones DENTRO de los mismos dos scripts, no forks |
| `scripts/linear.sh` | scripts/linear.sh | tickets=linear: el carril compartido: el diagnóstico de "no existe" vs "tu key es de otra org" vive en UN lugar (#113) |
| `scripts/jira.sh` | scripts/jira.sh | tickets=jira: idem para Jira, que además necesita ADF↔texto: la v3 devuelve la descripción como JSON anidado y un `.description` directo escribe "null", o sea una tarea SIN requisitos |
| `scripts/deploy-watch.sh` | scripts/deploy-watch.sh.tmpl | si hay CD (gha/argocd/kargo en inventory). Con `--coalesce` hay UN watcher por repo en vez de uno por ship: los demás se anotan en `.harness/deploy-pending/<repo>.jsonl` y salen, el vivo re-apunta al sha más nuevo que DESCIENDA del que vigila (ArgoCD despliega HEAD, los ancestros van incluidos) y al terminar atribuye su `deploy-<repo>.log` a todas las tareas cubiertas. Medido: una familia de 13 lotes del mismo repo pagó 13 ciclos de deploy que uno cubría |
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
- **Las refs de secretos se reescriben a la fuente ELEGIDA.** El catálogo las
  declara en el esquema por defecto (`secrets: [{key: GH_TOKEN, source:
  "env://GH_TOKEN"}]`). Copiarlas tal cual cuando la fuente es Vault (o GCP SM)
  deja el answers pidiendo una variable de entorno que nadie va a exportar, y
  el doctor avisa por algo que ya está materializado en `.secrets` (issue #26).
  Registra `vault://<base>/<item>` (o `gcp-sm://<secret>`) con el layout real.
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
