# Contribuir a harness-creator

*(English speakers: issues and PRs in English are welcome. The code comments
are Spanish-first, but [README.en.md](README.en.md) is a full mirror of the
Spanish README, not a summary: if you change one, change the other.)*

Gracias por querer contribuir. Este proyecto tiene una filosofía fuerte y las
contribuciones que la respetan se mergean rápido.

## La filosofía (léela antes de escribir código)

**Los agentes proponen, los sistemas deterministas verifican.** Todo check que
un script pueda hacer, lo hace un script; los modelos solo ponen juicio donde
hay juicio. De ahí se derivan las reglas de este repo:

1. **La regla anti-consejo-vacío.** Toda herramienta que un prompt cite debe
   tener su cadena completa: quién la instala (catálogo → bootstrap) → quién
   la alimenta (índices/configs con ciclo de vida) → quién la vigila (doctor,
   con remediación) → quién la ejecuta (gate, cronjob de andresgarcia29/harness-cronjobs o agente). Un PR que
   añade una herramienta "recomendada" sin esa cadena no entra.
2. **Todo archivo generado se registra** en la tabla de generación de
   `skills/harness-init/SKILL.md`. Un template sin fila ahí nunca se instala.
3. **Hooks y gates que bloquean son fail-closed; observadores son fail-open.**
   No mezcles las familias.
4. **Portabilidad: bash 3.2 (macOS de fábrica), BSD grep/find, sin GNU-ismos.**
   El CI corre la suite con `/bin/bash` en macOS precisamente para cachar esto.
5. **Los mensajes de error son prompts**: cada gate/fallo incluye su
   remediación exacta.
6. **Prohibido el guion largo "—" (em dash)** en docs, prompts,
   commits y todo texto del repo: delata prosa generada por IA. Usa
   coma, dos puntos o paréntesis. Hay un ratchet en la suite: el
   conteo existente solo puede BAJAR, y un PR que lo sube no pasa.
   (El "──" de las cajas de terminal es otro carácter y se permite.)
7. **Este repo no es de ningún cliente.** `harness-creator` es un
   instalador universal, y el proyecto donde nació es solo el primero
   que lo usó. Ningún nombre de empresa, cliente, tenant, dominio,
   organización de GitHub ni recurso concreto puede aparecer en lo que
   se genera ni en la lógica del instalador. Los ejemplos usan nombres
   neutros (`acme`, `example-org`, `svc-pagos`), y la procedencia de un
   bug se cita como "caso de campo", nunca con el nombre de quien lo
   sufrió. Hay ratchet en la suite: el conteo solo BAJA.
8. **Un eje que varía entre proyectos se DETECTA y se DESPACHA, jamás
   se cablea a un vendor.** Si el harness soporta algo que cambia de un
   proyecto a otro (secretos, lenguajes, package managers, tickets,
   modelos, **deploy**), la forma es siempre la misma: el discovery
   tiene que poder VER las alternativas, la entrevista pregunta CUÁL es
   la tuya en vez de pedir los valores de una, y el script despacha a
   una función por implementación más un `none` explícito.

   No es teoría: `secrets.sh` tiene siete funciones `pull_*`, `fe.sh`
   detecta el package manager por lockfile y `ship.sh` elige el gate por
   marcador de lenguaje. El único eje que se saltó la regla fue deploy,
   cableado a ArgoCD y Kargo, y el resultado fue que a un repo de
   terraform se le aplicó un modelo de Kubernetes y se propuso revertir
   commits correctos. **Cablear un vendor convierte un instalador
   universal en el instalador de quien lo escribió.** La suite verifica
   que cada eje declarado tenga al menos dos implementaciones.

## Desarrollo

```bash
git clone https://github.com/andresgarcia29/harness-creator
cd harness-creator
./tests/run.sh          # la suite completa (unos 10 min; medido: 9m53s en macOS)
./tests/run.sh fast     # salta el test lento del lock
```

Requisitos: bash, `jq`, `python3`. Nada más: la suite no toca la red y cada
test crea y borra su workspace temporal.

## Tests: la regla de oro

**La suite prueba el código REAL de los templates, no copias.** Mira
`tests/test_ship_lock.sh` o `tests/test_ship_gates.sh`: extraen las funciones
del template con awk y las ejecutan de verdad. Si tu PR toca un template con
lógica, el test debe extraer y ejercitar ESA lógica; un test que reimplementa
lo que prueba miente cuando el template cambia.

Un PR que añade lógica sin test se revisa con lupa; un PR que la añade con
test que ejercita el template real se mergea rápido.

## Debug de CI (lecciones pagadas, no teoría)

1. **Extrae TODAS las causas de una vez.** `gh run view <id> --log-failed`
   + grep de `FAIL|❌|error` sobre el log completo. Un run rojo casi
   nunca tiene una sola causa, y arreglar de a una quema un ciclo de CI
   (~5 min) por causa. Fallos distintos comparten síntoma.
2. **El CI no es tu máquina.** ubuntu: `sh` es dash (los bashisms
   revientan), `/tmp` es plano (rutas `../..` resuelven a rutas reales
   del sistema), no hay homebrew. Antes de declarar un fix: simula
   (`dash -uc`, `PATH` restringido). La suite ya prueba dash cuando
   existe; macOS pasa bashisms de chiripa.
3. **La cascada de assets es real**: cada merge aquí invalida los
   assets embebidos de los PRs de harness-daemon en vuelo (su check de
   drift los pone rojos ANTES de sus tests, ocultando otros fallos).
   Orden correcto: estabiliza este repo primero, sincroniza el daemon
   al final (`scripts/sync-assets.sh` allá).

## Pull requests

- Un PR = un cambio coherente. Los cambios acoplados (ej. esquema de
  models.yaml + su parser) van JUNTOS: a medias rompen instancias.
- Corre `./tests/run.sh` y `shellcheck -S error` antes de abrir.
- Si cambias el contrato de estado en disco (`tasks/<id>/`, `.harness/`,
  `state.json`), decláralo en el PR: el daemon del panel lo consume
  (ADR-0003) y es un cambio de contrato, no un detalle interno.
- Español o inglés, ambos bienvenidos en issues/PRs.
