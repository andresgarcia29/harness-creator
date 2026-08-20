# Evidence v1

`ship.sh` no acepta un “pass” narrativo. Cada prueba que sustenta el veredicto
se ejecuta con el runner:

```bash
scripts/evidence.py run \
  --task-dir tasks/<task-id> \
  --repo <repo> \
  --runner <identidad> \
  --kind test \
  --cwd worktrees/<task-id>/<repo> \
  -- <comando de prueba>
```

El runner conserva el output y un manifiesto JSON con task, repo, identidad,
comando, commit antes/después, exit code y SHA-256. El ID impreso se agrega a
`verdict-<repo>.json` bajo `evidence[]`.

Durante ship, `evidence.py verify` exige que cada ID:

- pertenezca a esta tarea y repositorio;
- haya terminado en cero;
- pertenezca al commit que el veredicto declara, O al MISMO cambio: el
  manifiesto sella `patch_id` (identidad de contenido, `change-id.sh`) y la
  evidencia CITADA sobrevive a un rebase igual que el veredicto que la cita.
  Manifiestos sin `patch_id` (versiones viejas) exigen SHA exacto;
- conserve el output original y su hash;
- cubra los tipos de evidencia requeridos por policy.

## Contención: se DECLARA, no bloquea

El manifiesto sella un bloque `contention` que mide la máquina compartida
durante la corrida: procesos de test ajenos, cuántos de ellos estaban
realmente quemando CPU (medido por delta de tiempo de CPU entre muestras, no
por el promedio de vida del proceso) y el load.

El runner toma un slot del semáforo de builds **solo cuando corresponde**: si
el comando es un `docker build/run` (lo único que la Ley 8 manda al semáforo)
o si el llamador pasa `--slot` porque sabe que su suite funde la máquina
(perilla `HARNESS_TEST_SLOTS`). Un gate de navegador de 10 minutos NO ocupa un
slot dimensionado para builds: envolver todo por defecto dejó cuatro corridas
encoladas con load 0.56 en 8 núcleos y ninguna era docker. `--no-slot` es el
"nunca" explícito y le gana a los dos.

Ese bloque VIAJA con la evidencia y `verify` lo DECLARA por stderr, pero **no
la rechaza**. La razón es una asimetría: `verify` mata cualquier manifiesto que
no tenga `exit_code: 0`, así que todo lo que llega al chequeo de contención ya
salió VERDE, y la contención no fabrica verdes: fabrica TIMEOUTS, o sea rojos,
que el chequeo de exit code ya rechaza. Un verde bajo carga es, si acaso, más
confiable que uno en máquina libre. Rechazarlo mandaba a esperar una ventana
tranquila que en un workspace multi-sesión puede no llegar nunca (caso de
campo: una tarea de 5 minutos que tardó 3 horas hasta que hubo que matarla).

Lo que la declaración sí deja abierto, y es lo que el reviewer tiene que
mirar: **una suite cuyos guards de entorno SALTAN tests cuando un servicio está
lento sale verde con menos tests corridos de los que cree**. Ningún otro gate
lo cubre. Ante un sello con `suspect: true`, comparar el conteo de tests del
log contra el esperado; si la suite tiene skips condicionales por timeout o
healthcheck, re-correr en ventana tranquila (`HARNESS_TEST_SLOTS=N` baja el
paralelismo PROPIO; si la carga es de otra sesión, no la toca).

El aviso de `run` cuando el comando sale ROJO bajo contención sí sigue en pie:
ahí la contención sí puede ser la causa del fallo.

La evidencia FRESCA (la que prueba el árbol integrado que se pushea) sigue
siendo SHA-estricta: la equivalencia por contenido jamás la satisface. Son
dos afirmaciones distintas y el pilar del ship es la segunda.

Editar un manifiesto, copiar evidencia de otra tarea o cambiar código después
de probar invalida el gate. Los manifiestos usan `schema: 1`; cualquier cambio
incompatible requiere una nueva versión de schema.
