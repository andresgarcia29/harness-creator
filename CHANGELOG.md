# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/). Este archivo empieza
en 0.47.0; la historia previa vive en el log de git (100+ commits iterando
contra una instalación real).

## [Sin publicar]

### Added
- **`gate_test_muerde`: un test nuevo tiene que MORDER.** Tercer gate de
  integridad, de la corrida de campo que pagó una ronda entera por un assert
  que no podía fallar (evaluaba antes de que el dato llegara): en el precheck
  y en `--ci`, todo test NUEVO del diff (y todo el nombrado bajo `ADDED` del
  delta-spec) se corre también sobre el árbol base con los tests del cambio
  encima; si pasa ahí, no prueba la conducta nueva y el rojo trae la
  remediación ejecutable (rojo primero, o `MODIFIED` si es refactor, que
  saca del alcance). Cero falsos rojos por diseño: modificados sin nombrar
  quedan fuera, runner dirigido por extensión con skip declarado donde no es
  inequívoco, y el árbol base va delante en PYTHONPATH para que un editable
  install no importe el código nuevo. La regla viaja en los prompts de
  implement, quick y smart (un gate que exige lo que ningún prompt pidió ya
  costó horas una vez). Y para el territorio que ningún gate de precheck
  alcanza, el QA exploratorio: identidad ANTES de medir (qué sirve en ese
  puerto, registrado en la evidencia) y un assert verde solo cuenta si se
  demostró capaz de fallar; en `qa.md` Y en `review.md`, porque el QA
  determinista nunca lee `qa.md`.
- **Carril `quick` y comando `/quick`: cero deliberación, mismos gates.** Para
  lo trivial que el humano ya dimensionó ("cambia estos logos"): sin
  enrichment, sin abogados, sin RFC ni plan; la misma sesión implementa y el
  reviewer independiente juzga. La promesa se mide, no se confía: `gate_lane`
  aplica el patrón de express MÁS techos de tamaño (8 archivos / 200 líneas,
  datos de `harness-policy.json` servidos por `harness-policy.py
  lane-limits`), quick es de UN repo (`POLICY-LANE-005`) y el diff que excede
  la promesa escala con `escalate --to express` conservando el trabajo. De
  paso, `escalate` dejó de re-encauzar SIEMPRE por rfc: el punto de
  re-entrada se valida contra el grafo del carril DESTINO (quick → express
  cae en `intake`), porque antes una tarea escalada podía caer en una fase
  que su carril nuevo no declara: trabada, solo rescatable con rollback.
- **Tanda prosa-a-gates: seis leyes que eran prosa ahora tienen diente.** El
  sello del precheck declara CUÁNTO se miró (`verificado:
  completo|ninguno|desconocido`) y /review debe decirlo; los dos mapas de
  leyes (CLAUDE.md y AGENTS.md) comparten numeración, con test de coherencia
  en las dos direcciones y ratchet de líneas que solo baja; las actions de CI
  van pinneadas por SHA y uv con versión explícita; el dedupe de harness-bug
  cierra su TOCTOU (claim local atómico + reconciliación por el orden del
  forge: gana el issue más viejo) y su huella deja de depender del locale
  (`LC_ALL=C`); el update prefiere `harness generate` y sus migraciones son
  script (`scripts/update-migrate.sh`, tres estados de exit, `--dry-run`
  antes de escribir); y el reviewer declara `tools:` sin Write. La
  verificación adversarial previa al merge se cobró seis bugs confirmados.
- **`scripts/instance-ship.sh`: la puerta a main del repo de la INSTANCIA**
  (issue #37). El hook bloqueaba el push (Ley 1) y ship.sh solo opera sobre
  repos/, así que el commit de cada /harness-update terminaba pusheado a mano
  POR FUERA del harness: el caso de manual de la Ley 15 ("no existe camino
  legítimo" es un bug del harness, no una regla). NO es una excepción al
  hook: es una puerta con los gates que SÍ aplican a ese repo (árbol limpio,
  rebase, gitleaks sobre el rango, doctor sin FAIL) y el push adentro del
  script sancionado, igual que ship.sh. El hook ahora nombra las DOS puertas,
  ship.sh deja de mandar al callejón de crear un worktree de la instancia, y
  /harness-update cierra publicando por ella.

### Changed
- **`/smart` ya no publica por default: la entrega la declara la invocación.**
  El síntoma llegaba como pregunta al final de cada corrida, en el chat: "no
  commiteé ni shippeé, ¿lo llevo por /review + ship?". No era timidez del
  modelo: la entrega no estaba declarada en ningún lado mecánico, así que
  preguntar era lo correcto, y el humano terminaba autorizando por frase lo que
  ninguna auditoría podía reconstruir después. Ahora es un DATO TIPADO que
  escribe el comando de entrada en `tasks/<id>/state.json`, reusando el
  vocabulario del knob `flow`: **`/smart` registra `delivery: review`** (nada se
  publica: commits locales del worktree sí, push, PR y main JAMÁS), `/smart-pr`
  registra `prs` (rama + PR) y `/smart-main` registra `trunk` (ship a main).
  Ojo al cambio de conducta: hasta hoy `/smart` llegaba a main. El "go"
  posterior a un `/smart` dejó de ser una frase y es una transición auditable
  (`harness-policy.py delivery --to prs|trunk`: actor y motivo en `history[]`, y
  solo hacia arriba, porque bajar el campo no despublica nada y dejaría al
  estado mintiendo sobre lo que ya está afuera). Con eso, **pedir autorización
  para commitear o publicar dentro de una corrida con entrega declarada quedó
  PROHIBIDO** en la lista cerrada de paradas: la invocación ya contestó esa
  pregunta, y volver a hacerla es re-litigar una decisión tomada. Nada de esto
  toca a quien ya estaba trabajando: una tarea SIN campo `delivery` (las viejas
  y las de `/quick`) conserva su conducta, `ship.sh` sigue el `flow` del
  workspace; y con `delivery: review` el ship no devuelve un gate rojo sino
  exit 8, que es "esto es lo que pediste", con la promoción escrita en la
  salida. `autonomy: checkpoint` sigue mandando por encima de la invocación
  porque es política del workspace y no de la tarea: con checkpoint, hasta
  `/smart-main` hace su única parada legítima antes de publicar.
- **El comando `/auto` pasa a llamarse `/smart`.** `/auto` chocaba con el
  comando homónimo de Kimi Code, y el harness es multi-herramienta por diseño:
  `AGENTS.md` es su puerta y promete que Cursor, Codex o Kimi operan el mismo
  pipeline, así que un nombre que otra herramienta ya se llevó no es cosmética:
  es el playbook equivocado ejecutándose con toda la confianza. El par de
  entrada queda explícito por lo que hace cada uno: **`/smart` dimensiona el
  carril por vos** (intake, blast radius, RFC solo si aplica) y **`/quick` es
  el carril que vos ya dimensionaste**. `/auto` sobrevive UN ciclo como puntero
  de deprecación (pocas líneas, cero reglas adentro, que mandan a correr
  `/smart` con los mismos argumentos) para que nadie con la memoria vieja se
  quede sin pipeline; después se borra, y un puntero que crece ya empezó a
  mentir. Dos cosas NO cambian: el prefijo de task-ids `AUTO-`, que lo genera
  el panel y lo contienen los ledgers viejos, y el panel mismo, que se
  actualiza en el ciclo que viene porque sus hints de `/auto` siguen
  funcionando mientras el puntero esté.

### Fixed
- **`harness-version.sh` reventaba al final cuando NO había supuestos que
  auditar.** `grep -c` imprime `0` y ADEMÁS sale 1 cuando no encuentra nada, así
  que el `|| echo 0` que protegía la línea agregaba un segundo `0`: la variable
  quedaba en `"0\n0"` y el `$(( ))` de la línea siguiente moría con
  `syntax error in expression`. Solo se disparaba con un `assumptions.md` que
  existe y no tiene ni un supuesto, o sea en el caso BUENO, y el error salía
  DESPUÉS de imprimir todo el reporte, así que parecía un fallo del bloque de
  worktrees y no del conteo de supuestos. Reportado desde una instancia real.
  El mismo patrón estaba en `doctor.sh`, donde no reventaba pero hacía decir
  "0\n0 archivados conocidos": un observador que imprime basura deja de ser
  creíble justo cuando hace falta creerle. Los dos normalizan ahora cualquier
  salida que no sea un número, con test que lo fija con un `grep` stub.
- **Cambiar el alcance dejó de leerse como una edición a mano de `state.json`.**
  `phase_is_declared` (el control que detecta ediciones manuales comparando
  `history[-1].to` contra `phase`) salteaba las entradas `kind=delivery` por
  NOMBRE, y el kind siguiente que apareció, `kind=repos`, cayó en la misma
  trampa sin que nadie lo notara: un `repos --add` legítimo dejaba la tarea
  acusada de `POLICY-STATE-003` en el `validate-ship`. Con `--remove` habría
  sido peor, porque ese es el camino de salida de una tarea trabada:
  destrabarla la volvía a trabar un paso después. El filtro pasa a ser
  ESTRUCTURAL: un movimiento de fase es, por definición, una entrada que
  declara `to`, y lo que no lo declara no movió nada. Así el próximo `kind`
  nace correcto sin tocar la función. La otra mitad no cambia: una entrada que
  no es un objeto sigue delatando la edición manual.
- **`pytest` sin tests que colectar deja de ser un ship imposible.** `pytest`
  sale 5 cuando no colectó NINGÚN caso, y eso no es un fallo: bajo `set -e` el
  gate de Python lo trataba como error fatal, así que un repo de contratos
  puros (cero tests Python) con un `pyproject.toml` en la raíz no podía
  shippear JAMÁS. Es la misma familia que el disco lleno y la ceguera de
  `deploy-watch`: una causa ambiental disfrazada de defecto de código. Ahora el
  5 no bloquea y tampoco pasa en silencio, que sería el falso verde de siempre:
  se dice por pantalla con su remediación (`pytest --collect-only`), el
  marcador de verificación queda en 0 (así que el sello del precheck declara
  "ninguno", no "completo") y el supuesto viaja al bus. Mismo trato que "no
  encuentro pytest", porque es el mismo hecho verificable, y la misma lectura
  del 5 que ya hacía `gate_test_muerde`. Cualquier otro código sigue matando el
  ship: un rojo de verdad es un rojo.
- **Un candidato que el plan descarta ya no traba la tarea para siempre**
  (`harness-policy.py repos --remove`). `init` recibe los repos CANDIDATOS del
  intake, y el patrón que este harness recomienda, verificar-antes-de-planear,
  existe justamente para descartar candidatos: en el caso de campo el
  arquitecto descartó 48 de 51 y el plan quedó en dos repos. Los otros tres no
  tenían nada que implementar, revisar ni shippear, así que nunca iban a tener
  veredicto, y `review → ship` los exige a todos: la tarea quedaba trabada en
  review con el código ya en main y desplegado verde. La única salida era
  editar `state.json` a mano, que `AGENTS.md` prohíbe, o sea que el harness
  recomendaba un patrón y castigaba a quien lo seguía. Quitar es más peligroso
  que sumar, así que va fail-closed y solo alcanza al repo que no produjo nada:
  con veredicto sellado, con entrada en `ship.log`, nombrado en `dag.json` (el
  DAG ES el plan, y sacarlo solo de `state.repos` no destrabaría nada porque el
  gate lee las dos fuentes en unión) o siendo el último repo, el comando se
  niega con su remediación. `--add` y `--remove` componen en una sola llamada,
  porque cambiar un candidato por otro es UNA decisión y merece UN registro. Y
  los dos mensajes de `POLICY-SHIP-004` que producían el bloqueo ahora nombran
  la salida: el gate que atrapa es el que enseña a salir.
- **El reviewer y el QA dejan de pelearse por un `go.work`.** El árbol clavado
  del reviewer (`.review-<repo>`) tiene los mismos module-paths que el worktree
  vivo, y un `go.work` no admite el módulo repetido: por eso `gowork.sh` lo
  poda. La consecuencia era que dentro del pin cualquier `go` moría con
  "directory prefix does not contain modules", y la remediación natural
  (`go work use .`, o regenerar el archivo parado ahí) REESCRIBÍA el `go.work`
  que el QA estaba usando sobre el árbol vivo. Medido en campo: el `use` quedó
  apuntando al pin mientras el QA medía sobre el vivo, y el build salió rojo por
  una razón que no era el código. No es un caso raro: reviewer y QA se lanzan en
  PARALELO por diseño, así que la carrera es la norma en cualquier tarea Go.
  Ahora `gowork.sh <task> <repo>` genera el `go.work` PROPIO del pin (el commit
  sellado gana; los otros repos vivos de la tarea siguen entrando, porque son el
  mismo cambio) y `verdict-scaffold.sh` lo emite al clavar el árbol. `go` lo
  encuentra subiendo desde el cwd antes que el de la tarea, así que los dos
  árboles dejan de compartir archivo. Fail-open como el pin: sin Go o sin
  `gowork.sh`, silencio.
- **El veredicto ya no acusa de "otro commit" a un rojo del commit correcto.**
  `verdict-scaffold` descartaba evidencia por tres motivos distintos (rojo bajo
  carga, rojo limpio, commit ajeno) y dos de ellos imprimían el mismo mensaje:
  "hay N evidencia(s) pero de OTRO commit, el implementer movió HEAD". A un EV
  que simplemente salió ROJO eso lo mandaba a perseguir un HEAD que nadie había
  movido en vez de a leer el log del test que falló, y a un diagnóstico se le
  cree. Cada descarte tiene ahora su predicado y su remediación, en la selección
  y en `--merge-qa`, que compartían el hueco.
- **Un disco lleno deja de disfrazarse de defecto de código.** Medido: 3 de 8
  corridas de la MISMA suite en rojo con el disco al 100 por ciento (56K libres
  de 193G); dos ni llegaron a colectar el archivo de test porque los workers
  murieron por ENOSPC. Con 29G libres, 16 de 16 verdes, mismo código. El daño
  no es la corrida perdida: es que ese rojo se lee igual que un defecto y manda
  al agente a arreglar lo que no está roto, quemando rondas. Es el mismo patrón
  que el rojo por ceguera de `deploy-watch`, una causa ambiental disfrazada de
  causa de código. Ahora `ship.sh` comprueba el espacio ANTES de los gates y se
  niega a correr con un mensaje que empieza por "NO ES TU CÓDIGO, ES EL DISCO",
  dice qué borrar primero y declara el escape (`HARNESS_MIN_FREE_GB=0`). El
  umbral es configurable porque una suite de Go con cachés y una de docs no
  necesitan lo mismo. `doctor.sh` avisa antes, como observador, para que se
  limpie sin perder una corrida. Y un `df` ilegible no inventa un rojo: se
  ausenta, como manda la ley de los gates que no pueden medir.
- **El `.semgrepignore` por defecto escondía los tests, y el gate salía verde.**
  semgrep trae un ignore propio que excluye `*_test.go` entre otras cosas, y
  como `ship.sh` escanea el DIRECTORIO, las ramas de las reglas que apuntan a
  tests no se evaluaban nunca: el workspace mostraba 0 matches de "no sleep en
  tests" para Go, que se leía como ausencia de deuda cuando era un gate ciego.
  Reproducido en la suite: el mismo archivo da 0 hallazgos como directorio y 1
  como target explícito. Ahora hay una segunda pasada con los archivos como
  target explícito, que es lo que los saca del ignore. Los globs salen de los
  `include:` de las PROPIAS reglas, no de una lista cableada en el gate que
  envejecería en silencio, y sin `include:` la segunda pasada no corre: un gate
  que no encuentra qué mirar se ausenta. No se escribe un `.semgrepignore` en
  el worktree aunque también funcione: ensuciaría un árbol que otros gates
  están midiendo y pisaría el del repo si lo tiene.
- **Ejecutar un artefacto por fin cuenta como tocarlo.** `gate_evidence`
  intersecta lo CITADO por la compliance matrix con lo LEÍDO según
  `tasks/<id>/evidence.log`, y ese log lo alimentaba SOLO el hook track-read,
  o sea abrir el archivo. Correr la prueba con `evidence.py` no dejaba rastro
  ahí, así que un reviewer que EJECUTABA el test y citaba su ruta quedaba rojo
  por no haberlo "leído". Pasó tres veces en la misma tarea con tres
  reviewers distintos, pese a que el mensaje del gate ya hablaba de abrir: un
  gate que castiga la conducta más fuerte (ejecutar) para premiar la más débil
  (leer) está midiendo lo que no quiso medir, y el propio hook ya declaraba
  que "un test que CORRIÓ es la evidencia más fuerte que hay". Ahora
  `evidence.py run` apunta en el log los archivos que el comando NOMBRA, y
  solo los que resuelven a un archivo real: no se afloja "citado no es
  verificado", porque nada entra sin haberse ejecutado. El mensaje del gate y
  el prompt del reviewer nombran las dos formas válidas de tocar un artefacto
  y advierten la trampa que queda: correr `go test ./internal/...` y citar
  `internal/auth/auth_test.go` no registra nada, porque el comando nunca
  nombró ese archivo.
- **El árbol de trabajo compartido deja de ser tierra de nadie: dos casos de
  campo, cuatro dientes nuevos.** (1) El reviewer hizo verificación por
  mutación (editar `src/` para ver un test ponerse rojo) sobre el árbol donde
  QA estaba buildeando EN PARALELO: el build absorbió el archivo mutado más un
  test sin trackear, y la medición quedó corrupta. Lo cazó la diligencia de
  QA, no el harness. Ahora `guard-canonical` hace del árbol clavado
  (`worktrees/<task>/.review-<repo>`) una zona de SOLO LECTURA (fail-closed,
  con la sonda descartable como remediación exacta), `evidence.py` se niega a
  sellar si el árbol se ensució MIENTRAS corría el comando (el chequeo previo
  solo miraba antes de empezar, y esa es justo la ventana que importa), y el
  prompt del reviewer por fin lo manda al árbol clavado en vez de al vivo, con
  la prohibición explícita y el recordatorio de que `gate_test_muerde` ya hace
  esa verificación aislada. QA, por su lado, comprueba la identidad del ÁRBOL
  antes de medir, igual que ya comprobaba la del servidor.
  (2) Dos tareas del mismo repo lanzadas en paralelo compartieron worktree y
  el `git add` amplio de una se llevó SEIS archivos de la otra a su commit. La
  causa de fondo era una premisa FALSA escrita en los prompts ("cada tarea
  tiene su worktree, así que las aristas del DAG van solo por conflicto de
  archivos, jamás por repo"): el árbol es `worktrees/<task-id>/<repo>`, uno por
  (tarea, repo), y las tareas del DAG lo comparten junto con la rama y el
  index. Ahora `POLICY-DAG-010` rechaza el plan que deja dos tareas del mismo
  repo sin ordenar (cualquiera de los dos órdenes sirve, y una cadena
  transitiva vale), el hook nuevo `guard-broad-add` bloquea el add amplio
  cuando el DAG declara hermanas sobre ese repo, y la doctrina se corrigió en
  `rfc`, `architect`, `implement`, `smart` e `implementer`. El paralelo que da
  ganancia de reloj, el de repos distintos, queda intacto.
- **`deploy-watch` por fin puede DEJAR de ser ciego, y `Progressing` dejó de
  leerse como "roto".** El tri-estado (observé y está sano / observé y está
  enfermo / no pude observar) ya impedía el rollback por ceguera, pero el
  watcher no tenía forma de salir de la ceguera y por eso esa era su vida
  normal. (1) El respaldo por CLI era **código muerto**: exigía `ARGOCD_URL`,
  un nombre nuestro, cuando el CLI lee `ARGOCD_SERVER` y lo quiere como HOST
  (con el esquema adelante contesta "server address unspecified", con un path
  detrás "unknown port": los dos síntomas de campo). Ahora se canonicaliza y
  se exporta lo que el CLI lee de verdad. (2) El CLI de Kargo busca
  `KARGO_API_ADDRESS`/`KARGO_API_TOKEN` y el harness guardaba
  `KARGO_ADDRESS`/`KARGO_TOKEN`: el inyector metía credenciales correctas que
  el CLI nunca miraba. Se puentea en los dos sentidos, solo con export (un
  `kargo login` dejaría estado mutable en `$HOME` y puede colgarse pidiendo
  input). (3) El catálogo declaraba el token y NO la dirección, así que el
  bootstrap instalaba la herramienta, el doctor la veía presente, y el watcher
  quedaba ciego por diseño: la cadena de la regla anti-consejo-vacío se
  cortaba en el último eslabón. (4) `argocd app wait` quemaba el timeout
  entero contra un host inalcanzable y recién después preguntaba si la app
  existía; ahora el `get` barato va primero y sin VPN cuesta segundos.
  (5) **Falso rojo nuevo, encontrado auditando lo anterior**: el health por
  `kubectl` (que es el camino preferido) hacía UNA lectura instantánea, sin
  loop y sin usar el timeout. Corriendo segundos después del push,
  `OutOfSync`/`Progressing` es el estado normal de un deploy que va bien, y se
  devolvía como enfermo, o sea rollback propuesto sobre un deploy sano. Ahora
  re-consulta hasta el deadline y solo lo que sigue enfermo al vencer es rojo;
  una salida vacía rompe el loop, porque eso es ceguera y no enfermedad. El
  contrato de tres salidas viaja también en el prompt de `/ship`, que hasta
  hoy solo modelaba verde y rojo.
- **El callejón sin salida de `review → ship`: mecanismo completo, y ahora
  también documentado y ejecutado por la suite.** Tres casos de campo
  terminaron en la misma pregunta ("avancé la fase antes de tiempo, cómo
  vuelvo"), y el mecanismo ya existía: `harness-policy.py rollback` deshace
  hacia atrás con actor y motivo en el historial, y la transición la registra
  `ship.sh` tras cada push, prosperando solo en el último repo por
  `POLICY-SHIP-004`. Lo que faltaba era que se supiera y que tuviera diente.
  (1) `docs/harness/policy.md`, que es EL doc del motor que se instala, no
  mencionaba ni el rollback ni quién mueve la fase: quien lo leía encontraba
  solo `transition`, que apunta hacia adelante, y concluía que no había vuelta.
  De ahí sale "editá `state.json` a mano", que es justo lo que la constitución
  prohíbe. Ahora documenta las dos cosas con sus códigos. (2)
  `request_ship_phase` solo estaba cubierta por asserts de presencia de texto
  en el template: podía romperse entera con la suite en verde. Ahora
  `test_ship_gates.sh` la extrae y la ejecuta contra el `harness-policy.py`
  real en sus cuatro ramas (faltan repos, último repo, fase ya avanzada, sin
  estado), y muerde: devolverle el comportamiento viejo rompe cuatro
  aserciones. (3) El paso 4 del prompt de `/ship` tenía dos redacciones de la
  misma regla pegadas por una edición previa, con dos "Después:" colgando;
  fusionadas, y ahora nombra el rollback como el rescate.
- **El precheck avisa cuando la evidencia del repo no apunta al HEAD que está
  sellando.** Caso de campo, dos veces en la misma sesión: sello `ok:true`
  sobre el hijo con las únicas evidencias del repo apuntando al padre. El
  desalineamiento lo cazaba recién `verdict-scaffold.sh`, o sea después de
  lanzar la ronda de review, y con `--allow-empty` podía no verse nunca:
  cuando se veía, la ronda ya estaba pagada. Ahora
  `aviso_evidencia_desalineada` lo dice en el precheck, con la MISMA
  remediación que da el scaffold para que las dos puertas no se contradigan.
  Es un observador, no un gate: sigue verde, porque ponerlo en rojo sería la
  mitad simétrica del defecto que el script ya rechazó (un repo sin stack no
  puede sellar evidencia en HEAD y eso es legítimo). El rebase puro no dispara
  falsa alarma: una evidencia de otra base con el mismo `patch_id` prueba el
  mismo cambio, igual que para `evidence.py` y para el predicado del scaffold.
  La regla viaja también en el prompt de `/implement`, porque un aviso que
  ningún prompt explica se ignora.
- **El cable que hace sobrevivir el review al rebase pasó a tener diente, y
  el gate dejó de ser mudo cuando no hay identidad de cambio.** Los tres
  eslabones que permiten que un rebase NO tire veredicto ni evidencia
  (`change-id.sh`, la ventana de reuso de `harness-policy.py`, la
  equivalencia por `patch_id` de `evidence.py`) estaban cada uno probado
  contra su código real, pero la función que los CONECTA
  (`gate_policy_and_evidence`) no la ejecutaba ningún test: está stubbeada
  donde se mide el fan-out, que es lo correcto ahí, y dejaba el cable al
  aire. Borrar el `--patch-id` o romper el parseo de `REVIEWED_COMMIT=`
  dejaba la suite VERDE y devolvía a producción el bucle ceremonial de
  POLICY-SHIP-002 (registrar evidencia, rebase, re-registrar, re-sellar, una
  ronda por repo). Ahora `test_rebase_survival.sh` extrae la función del
  template y la corre sobre git de verdad, con la base movida por un commit
  ajeno y el SHA reescrito por un rebase real, con el caso de campo de los
  TRES SHAs; y muerde: la mutación que corta el cable pone el test en rojo.
  Además, el gate ya no tira el stderr de `change-id.sh`: cuando no puede
  calcular el `patch_id` (diff vacío contra `origin/<base>`, o esa referencia
  no existe) DICE la causa y la remediación en vez de dejar solo
  "POLICY-SHIP-002: falta --patch-id", que nombra el síntoma, suena a bug del
  harness y casi siempre es un worktree sin commits propios.
- **Tres hallazgos de la primera corrida de campo de una instancia real
  (post 0.54.0), los tres verificados EJECUTANDO, no leyendo.** (1) El
  reviewer leía el worktree VIVO mientras el implementer (dueño del claim)
  podía seguir editando: el veredicto sellaba el commit X con un juicio de X
  más ediciones transitorias, falso verde legítimo. Ahora `verdict-scaffold`
  clava `worktrees/<task>/.review-<repo>` (detached al commit sellado,
  re-clavado en cada `--rebase`, limpiado por `--rm`) y el reviewer lee ahí;
  el pin degradado se declara, jamás mata el scaffold. El efecto colateral lo
  encontró el propio fix ejecutándose: `gowork.sh` y `py.sh` veían el pin
  como segundo módulo/paquete (con ganador por orden de `readdir`, no
  determinista), y ahora lo podan. (2) Los planes del architect afirmaban
  comportamiento runtime de una dependencia "verificado en código" leyéndole
  el fuente (dos decisiones falsas, dos rondas pagadas): la regla nueva exige
  una EJECUCIÓN con su salida citada, o la decisión es un supuesto. (3) Con
  `manifest.yaml` ilegible, `init` salteaba EN SILENCIO el freno de infra y
  el aviso de repos desconocidos, y el silencio se leyó como "chequeo
  pasado": ahora grita nombrando lo que NO corrió y el backstop.
- **#39: el precheck no sella con árbol sucio**. El fix de 0.52.0 degradó la
  EVIDENCIA honestamente pero el sello seguía grabando HEAD con ok:true: los
  gates corrieron sobre el working tree y /review leía "los gates pasaron
  sobre este commit" de un commit que no contiene lo validado. Los gates
  corren igual (feedback); la afirmación falsa ya no se emite, con la
  remediación exacta (commitea y re-corre).
- **#33: check_verdict moría MUDO por pipefail** cuando la evidencia no traía
  runner=qa: `grep -l | wc -l` sale 1 sin matches, pipefail lo hereda y set -e
  mataba la función ANTES del if que acepta el qa-<repo>.json (la rama
  prometida era inalcanzable; misma clase que el uv|ruff del #30). El runner
  del test ahora corre la función extraída bajo `set -euo pipefail`, el
  entorno real: el shell distinto del test era lo que escondía la clase
  entera.
- **#32: origin/HEAD envenenado ya no manda el worktree a otra rama**. El ref
  local se escribe UNA vez al clonar y un `remote set-head` posterior lo
  dejaba apuntando a una rama vieja para siempre, en silencio. base_branch
  (worktree-task y ship) ahora le pregunta AL REMOTO (`ls-remote --symref`) y
  SANA el ref local de paso, para los lectores que no pagan red (hooks,
  change-id); offline cae al ref local (degradar no es inventar). pull-all
  también sana el ref aprovechando la red del pull.
- **deploy-watch no puede salir MUDO, por construcción** (caso de campo:
  "salió 0 con salida vacía", y la desconfianza aprendida de verificar a
  mano contra el CI). Tres capas: un trap garantiza al menos una línea
  SIEMPRE (si algún camino nuevo sale callado, se vuelve un bug
  diagnosticable con contexto en vez de un silencio); gh ausente con driver
  distinto de none se DICE y queda como supuesto (antes la etapa de Actions
  entera se saltaba sin una palabra); y kargo CLI ausente se dice en una
  línea (un pipeline sin Kargo es legítimo; lo que no es legítimo es que
  ambos casos se lean igual).

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
