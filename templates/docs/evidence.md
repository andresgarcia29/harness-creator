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
- no esté marcada `suspect` por contención: el manifiesto sella un bloque
  `contention` (procesos de test ajenos y load durante la corrida, medidos
  por el propio runner, que además toma un slot del semáforo de builds;
  perilla `HARNESS_TEST_SLOTS`). Un resultado bajo saturación no prueba nada
  y la remediación es re-correr con menos contención, no bajar el estándar;
- conserve el output original y su hash;
- cubra los tipos de evidencia requeridos por policy.

La evidencia FRESCA (la que prueba el árbol integrado que se pushea) sigue
siendo SHA-estricta: la equivalencia por contenido jamás la satisface. Son
dos afirmaciones distintas y el pilar del ship es la segunda.

Editar un manifiesto, copiar evidencia de otra tarea o cambiar código después
de probar invalida el gate. Los manifiestos usan `schema: 1`; cualquier cambio
incompatible requiere una nueva versión de schema.
