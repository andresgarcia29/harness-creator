#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "templates/scripts/evidence.py"


class EvidenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.task = self.root / "tasks/AUTO-20260720-evidence-test"
        self.repo.mkdir(parents=True)
        self.task.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=self.repo, check=True)
        (self.repo / "README.md").write_text("ok\n")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "init"], cwd=self.repo, check=True)
        self.commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()
        # POR QUE: evidence.py envuelve el comando en build-slot.sh, cuyo
        # semaforo es cross-sesion por diseno. Sin esto, cada `run` de esta
        # suite puede quedarse BLOQUEADO esperando un slot que tiene otra
        # sesion de la maquina. Cada test usa su propio dir de locks, dentro
        # del temporal que tearDown borra.
        # Un test del semaforo no puede correr DENTRO del semaforo. Si esta
        # suite se sella como evidencia, build-slot exporta
        # HARNESS_BUILD_SLOT_HELD=1 y evidence.py deja de envolver: el sello
        # sale con slot_wrapped false y el test mide un semaforo apagado
        # (COR-707). run.sh la limpia para toda la suite; esto cubre la
        # corrida suelta bajo un slot ya tomado.
        self._held_prev = os.environ.pop("HARNESS_BUILD_SLOT_HELD", None)
        self._slot_dir_prev = os.environ.get("HARNESS_SLOT_DIR")
        os.environ["HARNESS_SLOT_DIR"] = str(self.root / "slots")

    def tearDown(self):
        if self._slot_dir_prev is None:
            os.environ.pop("HARNESS_SLOT_DIR", None)
        else:
            os.environ["HARNESS_SLOT_DIR"] = self._slot_dir_prev
        if self._held_prev is not None:
            os.environ["HARNESS_BUILD_SLOT_HELD"] = self._held_prev
        self.tmp.cleanup()

    def _neutraliza_contencion(self, evidence_id):
        # POR QUE: el sampler mide la maquina REAL. Caso de campo: con otra
        # sesion corriendo vitest (load 8.53, 18 procesos ajenos, 6 cores) el
        # manifiesto salia suspect=true y verify rebotaba por una causa AJENA
        # al contrato bajo prueba; la misma suite era verde con la maquina
        # quieta. El manifiesto no esta protegido por hash: el fixture borra la
        # telemetria ambiental sin tocar una linea de produccion.
        path = self.task / f"evidence/{evidence_id}.json"
        data = json.loads(path.read_text())
        if isinstance(data.get("contention"), dict):
            data["contention"]["suspect"] = False
            path.write_text(json.dumps(data))

    def run_evidence(self):
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "qa-atlas", "--kind", "test",
             "--cwd", str(self.repo), "--", "sh", "-c", "printf 'tests ok\\n'"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence_id = next(line.split("=", 1)[1] for line in result.stdout.splitlines()
                           if line.startswith("EVIDENCE_ID="))
        self._neutraliza_contencion(evidence_id)
        return evidence_id

    def verdict(self, evidence_id):
        path = self.task / "verdict-atlas.json"
        path.write_text(json.dumps({
            "schema": 1, "task_id": self.task.name, "repo": "atlas",
            "commit": self.commit, "evidence": [evidence_id]
        }))
        return path

    def verify(self, verdict):
        return subprocess.run(
            ["python3", str(SCRIPT), "verify", "--task-dir", str(self.task),
             "--repo", "atlas", "--commit", self.commit, "--verdict", str(verdict),
             "--require-kind", "test"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def test_valid_evidence_is_bound_to_commit_and_output(self):
        evidence_id = self.run_evidence()
        result = self.verify(self.verdict(evidence_id))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("evidencias ligadas", result.stdout)

    def test_tampered_output_is_rejected(self):
        evidence_id = self.run_evidence()
        verdict = self.verdict(evidence_id)
        (self.task / f"evidence/{evidence_id}.log").write_text("tampered\n")
        result = self.verify(verdict)
        self.assertEqual(result.returncode, 3)
        self.assertIn("SHA-256", result.stderr)

    def test_wrong_commit_is_rejected(self):
        evidence_id = self.run_evidence()
        verdict = self.verdict(evidence_id)
        result = subprocess.run(
            ["python3", str(SCRIPT), "verify", "--task-dir", str(self.task),
             "--repo", "atlas", "--commit", "0" * 40, "--verdict", str(verdict)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        self.assertEqual(result.returncode, 3)
        self.assertIn("otro commit", result.stderr)



    def test_moved_head_announces_discarded_not_a_usable_id(self):
        # Caso de campo: el ID se imprimía ANTES de decidir la publicabilidad,
        # y un agente que parsea stdout se llevaba un EVIDENCE_ID que dos
        # líneas después se declaraba no publicable. El anuncio ahora dice lo
        # que es: EVIDENCE_DISCARDED, y ningún parser de EVIDENCE_ID= matchea.
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "qa-atlas", "--kind", "test",
             "--cwd", str(self.repo), "--", "git", "commit",
             "--allow-empty", "-qm", "mueve HEAD durante la corrida"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        self.assertEqual(result.returncode, 3)
        self.assertIn("EVIDENCE_DISCARDED=", result.stdout)
        self.assertNotIn("EVIDENCE_ID=", result.stdout)
        self.assertIn("no es publicable", result.stderr)

    def test_refuses_to_seal_a_dirty_tree(self):
        """El contrato de la evidencia es "este resultado pertenece a ESTE
        commit". before == after solo prueba que HEAD no se movió mientras
        corría; con cambios sin commitear, lo que se ejecuta es el commit MÁS
        el working tree, y el sello diría solo el commit.

        Caso de campo, tres rondas perdidas: el implementer corrió evidence.py
        antes de commitear, selló contra el padre, y al commitear la evidencia
        quedó stale. La variante cara es la otra: si nadie commitea después, el
        scaffold la acepta y queda certificando código que no corrió."""
        repo = Path(self.tmp.name) / "wt"
        repo.mkdir()
        run = lambda *a: subprocess.run(["git", "-C", str(repo), *a],
                                        capture_output=True, text=True)
        run("init", "-q", "."); run("config", "user.email", "t@t"); run("config", "user.name", "t")
        (repo / "app.txt").write_text("v1")
        run("add", "-A"); run("commit", "-qm", "init")

        # árbol limpio: sella
        ok = self.run_ev_in(repo)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertIn("EVIDENCE_ID=", ok.stdout)

        # cambios sin commitear: se niega, y explica por qué
        (repo / "app.txt").write_text("v2")
        dirty = self.run_ev_in(repo)
        self.assertEqual(dirty.returncode, 3)
        self.assertIn("SIN COMMITEAR", dirty.stderr)
        self.assertIn("app.txt", dirty.stderr)
        self.assertIn("commitea primero", dirty.stderr)

        # tras commitear vuelve a andar, y el manifiesto anota el estado
        run("add", "-A"); run("commit", "-qm", "fix")
        after = self.run_ev_in(repo)
        self.assertEqual(after.returncode, 0, after.stderr)
        manifests = sorted((Path(self.tmp.name) / "T1" / "evidence").glob("EV-*.json"))
        data = json.loads(manifests[-1].read_text())
        self.assertTrue(data["tree_clean"])

    def test_arbol_COMPARTIDO_sella_con_suciedad_ajena_y_la_declara(self):
        """ISSUE #137: el repo de la INSTANCIA no tiene worktree por tarea.

        Es UN arbol para todas, asi que "limpio" es una precondicion inalcanzable
        por construccion y sin escape: medido, ninguna prueba se podia sellar
        justo en el repo que contiene los gates de todos los demas, y el
        veredicto quedaba sin evidence[]. Lo que NO se afloja: lo que ensucio
        ESTA tarea sigue siendo rechazo.
        """
        # El repo de la instancia ES el árbol del workspace, o sea el padre de
        # tasks/<id>: esa es toda la definición, y por estructura, sin leer el
        # answers. Un árbol cualquiera de fuera del workspace NO hereda la
        # concesión (ver el test de la sonda, más abajo).
        repo = Path(self.tmp.name) / "instancia"
        (repo / "tasks").mkdir(parents=True)
        run = lambda *a: subprocess.run(["git", "-C", str(repo), *a],
                                        capture_output=True, text=True)
        run("init", "-q", "."); run("config", "user.email", "t@t"); run("config", "user.name", "t")
        (repo / "mio.txt").write_text("v1")
        (repo / "ajeno.txt").write_text("v1")
        run("add", "-A"); run("commit", "-qm", "base")
        # Un commit de ESTA tarea, con su trailer: es lo que define "lo mio".
        (repo / "mio.txt").write_text("v2")
        run("add", "mio.txt"); run("commit", "-qm", "mio\n\nTask: T1")

        # Suciedad AJENA (otra tarea en vuelo sobre el arbol compartido).
        (repo / "ajeno.txt").write_text("otra tarea trabajando")
        ok = self.run_ev_in(repo, task_dir=repo / "tasks" / "T1")
        self.assertEqual(ok.returncode, 0,
                         "el arbol compartido tiene que poder sellar\n" + ok.stderr)
        self.assertIn("COMPARTIDO", ok.stderr)
        self.assertIn("ajeno.txt", ok.stderr)
        # Y el sello lo DICE: deja de mentir por omision.
        ev = json.loads(next((repo / "tasks" / "T1" / "evidence").glob("EV-*.json")).read_text())
        self.assertTrue(any("ajeno.txt" in x for x in ev.get("shared_tree_dirty", [])), ev)

        # Lo que SI sigue frenando: ensuciar un archivo de ESTA tarea.
        (repo / "mio.txt").write_text("v3 sin commitear")
        malo = self.run_ev_in(repo, task_dir=repo / "tasks" / "T1")
        self.assertEqual(malo.returncode, 3, malo.stderr)
        self.assertIn("SIN COMMITEAR", malo.stderr)
        self.assertIn("mio.txt", malo.stderr)

    def test_un_worktree_de_tarea_NO_es_arbol_compartido(self):
        # La contra-mitad: en el arbol de una tarea la exigencia no se toca.
        repo = Path(self.tmp.name) / "worktrees" / "T1" / "r"
        repo.mkdir(parents=True)
        run = lambda *a: subprocess.run(["git", "-C", str(repo), *a],
                                        capture_output=True, text=True)
        run("init", "-q", "."); run("config", "user.email", "t@t"); run("config", "user.name", "t")
        (repo / "a.txt").write_text("v1")
        run("add", "-A"); run("commit", "-qm", "base\n\nTask: T1")
        (repo / "b.txt").write_text("x"); run("add", "b.txt"); run("commit", "-qm", "b\n\nTask: T1")
        (repo / "a.txt").write_text("sucio")          # ajeno al ultimo commit
        r = self.run_ev_in(repo)
        self.assertEqual(r.returncode, 3,
                         "en un worktree de tarea la limpieza se sigue exigiendo entera")
        self.assertNotIn("COMPARTIDO", r.stderr)

    def test_un_arbol_SONDA_de_fuera_del_workspace_NO_hereda_la_concesion(self):
        """La regla vieja era "no cuelga de worktrees/", asi que CUALQUIER arbol
        de fuera del workspace pasaba por "compartido" y su suciedad no
        bloqueaba. Un verificador que levanta un arbol descartable en /tmp para
        medir algo caia justo ahi: el sello nombraba un commit y lo que corrio
        fue ese commit MAS el checkout que el verificador acababa de hacer.
        Caso de campo: un EV-TEST verde que parecia sostener la afirmacion
        CONTRARIA a la que se estaba midiendo."""
        sonda = Path(self.tmp.name) / "sonda"      # ni worktree ni instancia
        sonda.mkdir()
        run = lambda *a: subprocess.run(["git", "-C", str(sonda), *a],
                                        capture_output=True, text=True)
        run("init", "-q", "."); run("config", "user.email", "t@t"); run("config", "user.name", "t")
        (sonda / "src.txt").write_text("v1")
        run("add", "-A"); run("commit", "-qm", "base")
        # Suciedad que NINGUN commit de la tarea explica: es exactamente lo que
        # la concesion del #137 dejaba pasar.
        (sonda / "src.txt").write_text("los fuentes de la base, puestos encima")
        r = self.run_ev_in(sonda)
        self.assertEqual(r.returncode, 3,
                         "un arbol sonda tiene que fallar CERRADO\n" + r.stderr)
        self.assertNotIn("COMPARTIDO", r.stderr)

    def test_un_artefacto_SIN_TRACKEAR_que_el_comando_nombra_no_se_sella(self):
        """Un archivo sin trackear no bloquea por si solo (un artefacto de build
        no cambia lo que el commit contiene). Pero si el COMANDO lo nombra, es
        lo que se esta probando: el sello diria "commit P" sobre una prueba que
        no esta en P. Caso de campo: un arbol con los tests nuevos copiados
        encima de los fuentes de la base; un test nuevo es un archivo nuevo, o
        sea sin trackear, y nada frenaba el sello."""
        repo = Path(self.tmp.name) / "conuntracked"
        repo.mkdir()
        run = lambda *a: subprocess.run(["git", "-C", str(repo), *a],
                                        capture_output=True, text=True)
        run("init", "-q", "."); run("config", "user.email", "t@t"); run("config", "user.name", "t")
        (repo / "app.txt").write_text("v1")
        run("add", "-A"); run("commit", "-qm", "init")
        (repo / "nuevo_test.py").write_text("# el test que se esta probando\n")

        t1 = Path(self.tmp.name) / "T1"
        t1.mkdir(exist_ok=True); (t1 / "task.md").touch()
        malo = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(t1),
             "--repo", "r", "--runner", "qa", "--kind", "test",
             "--cwd", str(repo), "--", "cat", "nuevo_test.py"],
            capture_output=True, text=True)
        self.assertEqual(malo.returncode, 3, malo.stderr)
        self.assertIn("NO están en el commit", malo.stderr)
        self.assertIn("nuevo_test.py", malo.stderr)

        # Y el sin trackear que NADIE nombra sigue sin bloquear: un artefacto de
        # build no cambia lo que el commit contiene.
        (repo / "build.log").write_text("ruido")
        (repo / "nuevo_test.py").unlink()
        ok = self.run_ev_in(repo)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertIn("sin trackear", ok.stderr)

        # Lo IGNORADO tampoco bloquea AUNQUE el comando lo nombre: el binario
        # del runner es la herramienta, no el artefacto bajo prueba, y no viaja
        # en ningun commit. Cobrarselo seria un rojo imposible de satisfacer.
        (repo / ".gitignore").write_text("node_modules/\n")
        run("add", "-A"); run("commit", "-qm", "gitignore")
        (repo / "node_modules").mkdir()
        runner = repo / "node_modules" / "runner"
        runner.write_text("#!/bin/sh\nexit 0\n"); runner.chmod(0o755)
        conherramienta = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(t1),
             "--repo", "r", "--runner", "qa", "--kind", "test",
             "--cwd", str(repo), "--", "./node_modules/runner"],
            capture_output=True, text=True)
        self.assertEqual(conherramienta.returncode, 0, conherramienta.stderr)

        # Y lo que vive FUERA del repo tampoco: un wrapper del workspace
        # (scripts/py.sh y sus hermanos) no esta ni puede estar en el commit del
        # repo que se sella, y exigirlo seria un rojo imposible de satisfacer
        # justo donde el harness pide usar el runner.
        fuera = Path(self.tmp.name) / "wrapper.sh"
        fuera.write_text("#!/bin/sh\nexit 0\n"); fuera.chmod(0o755)
        conwrapper = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(t1),
             "--repo", "r", "--runner", "qa", "--kind", "test",
             "--cwd", str(repo), "--", "sh", str(fuera)],
            capture_output=True, text=True)
        self.assertEqual(conwrapper.returncode, 0, conwrapper.stderr)

    def run_ev_in(self, repo, task_dir=None):
        # evidence.py ya NO crea task-dirs: el fixture lo crea con un marker,
        # como haría worktree-task.sh en una instancia real.
        t1 = Path(task_dir) if task_dir else Path(self.tmp.name) / "T1"
        t1.mkdir(parents=True, exist_ok=True)
        (t1 / "task.md").touch()
        return subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(t1),
             "--repo", "r", "--runner", "implementer", "--kind", "test",
             "--cwd", str(repo), "--", "true"],
            capture_output=True, text=True)

    # ── el task-dir se valida, jamás se crea (caso de campo del commit sucio) ──
    # Un --task-dir relativo corrido desde el worktree creó ./<id>/evidence/
    # DENTRO del repo; git add -A lo barrió, el árbol quedó limpio y todos los
    # gates pasaron. Lo encontró un reviewer leyendo git show, no un gate.

    def test_refuses_missing_task_dir(self):
        ghost = Path(self.tmp.name) / "AUTO-fantasma"
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(ghost),
             "--repo", "r", "--runner", "implementer", "--kind", "test",
             "--cwd", str(self.repo), "--", "true"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn(str(ghost), result.stderr)          # la ruta ABSOLUTA resuelta
        self.assertIn("worktree-task.sh", result.stderr)  # el creador legítimo
        self.assertFalse(ghost.exists())                  # y NO lo creó

    def test_refuses_dir_that_does_not_look_like_task_dir(self):
        impostor = Path(self.tmp.name) / "cualquier-dir"
        impostor.mkdir()
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(impostor),
             "--repo", "r", "--runner", "implementer", "--kind", "test",
             "--cwd", str(self.repo), "--", "true"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("no parece un task-dir", result.stderr)

    def test_accepts_marker_based_task_dir(self):
        offbeat = Path(self.tmp.name) / "layout-raro"
        offbeat.mkdir()
        (offbeat / "task.md").touch()
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(offbeat),
             "--repo", "r", "--runner", "implementer", "--kind", "test",
             "--cwd", str(self.repo), "--", "true"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    # ── el sello se mide donde vive el repo DECLARADO (#218) ──
    # `--cwd` valía "." por defecto, así que quien corría `evidence.py run
    # --repo docs` parado en la raíz del workspace sellaba contra el HEAD del
    # repo de la INSTANCIA declarando `repo: docs`. En evidence.log las dos se
    # leen IGUAL (mismo runner, mismo kind, misma aserción) y solo se
    # distinguen cruzando el commit contra el repo, que es lo que nadie hace a
    # ojo. Pasó dos veces en la misma tarea, a dos agentes distintos.

    def _mk_worktree(self, repo_name, sufijo=""):
        """Un árbol de <repo> en el layout real: worktrees/<task>/<repo>."""
        wt = self.root / "worktrees" / self.task.name / f"{repo_name}{sufijo}"
        wt.mkdir(parents=True)
        for cmd in (["git", "init", "-q", "-b", "main"],
                    ["git", "config", "user.email", "t@e.io"],
                    ["git", "config", "user.name", "T"]):
            subprocess.run(cmd, cwd=wt, check=True)
        (wt / "propio.md").write_text("del repo declarado\n")
        subprocess.run(["git", "add", "."], cwd=wt, check=True)
        subprocess.run(["git", "commit", "-qm", f"init {repo_name}"], cwd=wt, check=True)
        return wt, subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=wt, text=True).strip()

    def _run_sin_cwd(self, repo_name, desde):
        return subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", repo_name, "--runner", "implementer", "--kind", "test",
             "--", "true"],
            cwd=str(desde), capture_output=True, text=True)

    def test_run_sin_cwd_sella_contra_el_worktree_del_repo(self):
        wt, commit_bueno = self._mk_worktree("docs")
        # Se corre desde la RAÍZ DEL WORKSPACE, que es donde estaban parados los
        # dos agentes del reporte: su HEAD es otro y no existe en `docs`.
        result = self._run_sin_cwd("docs", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence_id = next(l.split("=", 1)[1] for l in result.stdout.splitlines()
                           if l.startswith("EVIDENCE_ID="))
        manifest = json.loads((self.task / f"evidence/{evidence_id}.json").read_text())
        self.assertEqual(manifest["commit"], commit_bueno,
                         "selló contra un commit que no es el del repo declarado")
        self.assertEqual(Path(manifest["cwd"]).resolve(), wt.resolve())
        self.assertIn("--cwd derivado", result.stdout)

    def test_run_rechaza_un_cwd_fuera_del_repo_declarado(self):
        self._mk_worktree("docs")
        # El árbol existe y --cwd apunta a OTRO: sellar ahí produce un manifiesto
        # que se lee bien y no sirve, así que se rechaza en vez de escribirlo.
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "docs", "--runner", "implementer", "--kind", "test",
             "--cwd", str(self.repo), "--", "true"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("NO pertenece al repo declarado", result.stderr)
        self.assertIn("docs", result.stderr)
        self.assertFalse((self.task / "evidence.log").exists(),
                         "no se escribe un sello inservible")

    def test_run_sin_worktree_sigue_sellando_donde_esta(self):
        # El repo de la INSTANCIA no tiene worktree por tarea: su árbol ES el
        # workspace. Sin árbol declarado que contradiga, se sella donde se está,
        # que es el comportamiento de siempre y el único posible.
        result = self._run_sin_cwd("atlas", self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence_id = next(l.split("=", 1)[1] for l in result.stdout.splitlines()
                           if l.startswith("EVIDENCE_ID="))
        manifest = json.loads((self.task / f"evidence/{evidence_id}.json").read_text())
        self.assertEqual(manifest["commit"], self.commit)

    def test_run_con_varios_nodos_no_elige_por_vos(self):
        # Los worktrees de nodo del DAG llevan sufijo (`<repo>@T1`). Con más de
        # uno, derivar sería elegir el árbol equivocado con la misma cara que el
        # bueno: se pide el --cwd explícito.
        self._mk_worktree("api", "@T1")
        self._mk_worktree("api", "@T2")
        result = self._run_sin_cwd("api", self.root)
        self.assertEqual(result.returncode, 2)
        self.assertIn("api@T1", result.stderr)
        self.assertIn("api@T2", result.stderr)

    # ── identidad de contenido: la evidencia sobrevive al rebase como el veredicto ──

    def mk_manifest(self, evidence_id, commit, patch_id=None, **extra):
        ev_dir = self.task / "evidence"
        ev_dir.mkdir(exist_ok=True)
        log = ev_dir / f"{evidence_id}.log"
        log.write_text("tests ok\n")
        import hashlib
        data = {
            "schema": 1, "id": evidence_id, "task_id": self.task.name,
            "repo": "atlas", "kind": "test", "runner": "implementer",
            "commit": commit, "commit_after": commit, "exit_code": 0,
            "output": f"evidence/{evidence_id}.log",
            "output_sha256": hashlib.sha256(log.read_bytes()).hexdigest(),
        }
        if patch_id:
            data["patch_id"] = patch_id
        data.update(extra)
        (ev_dir / f"{evidence_id}.json").write_text(json.dumps(data))
        return evidence_id

    def verify_with(self, verdict_extra, commit=None, evidence_ids=None):
        path = self.task / "verdict-atlas.json"
        verdict = {"schema": 1, "task_id": self.task.name, "repo": "atlas",
                   "commit": commit or self.commit,
                   "evidence": evidence_ids or []}
        verdict.update(verdict_extra)
        path.write_text(json.dumps(verdict))
        return subprocess.run(
            ["python3", str(SCRIPT), "verify", "--task-dir", str(self.task),
             "--repo", "atlas", "--commit", self.commit,
             "--reviewed-commit", verdict["commit"], "--verdict", str(path),
             "--require-kind", "test"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)

    def test_run_seals_patch_id_when_change_id_resolves(self):
        # repo con origin/main simulado y un commit propio: change-id.sh resuelve
        subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"],
                       cwd=self.repo, check=True)
        (self.repo / "feature.txt").write_text("x\n")
        subprocess.run(["git", "add", "-A"], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "feat"], cwd=self.repo, check=True)
        evidence_id = self.run_evidence()
        data = json.loads((self.task / f"evidence/{evidence_id}.json").read_text())
        expected = subprocess.check_output(
            ["bash", str(ROOT / "templates/scripts/change-id.sh"), str(self.repo)],
            text=True).strip()
        self.assertEqual(data.get("patch_id"), expected)

    def test_run_without_identity_omits_patch_id(self):
        # sin origin ref ni diff: change-id sale 2 y el campo queda AUSENTE
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "qa-atlas", "--kind", "test",
             "--cwd", str(self.repo), "--", "sh", "-c", "echo ok"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sin patch_id", result.stderr)
        evidence_id = next(line.split("=", 1)[1] for line in result.stdout.splitlines()
                           if line.startswith("EVIDENCE_ID="))
        data = json.loads((self.task / f"evidence/{evidence_id}.json").read_text())
        self.assertNotIn("patch_id", data)

    def test_cited_evidence_accepted_by_patch_equivalence(self):
        # los TRES SHAs del caso de campo: EV en C1, veredicto en R, mismo cambio
        ev = self.mk_manifest("EV-TEST-equiv0000001", "c" * 40, patch_id="P" * 40)
        result = self.verify_with({"patch_id": "P" * 40}, commit="5" * 40,
                                  evidence_ids=[ev])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MISMO cambio", result.stdout)

    def test_cited_evidence_other_patch_rejected(self):
        ev = self.mk_manifest("EV-TEST-otro0000001", "c" * 40, patch_id="Q" * 40)
        result = self.verify_with({"patch_id": "P" * 40}, commit="5" * 40,
                                  evidence_ids=[ev])
        self.assertEqual(result.returncode, 3)
        self.assertIn("OTRO cambio", result.stderr)
        self.assertIn("--rebase", result.stderr)

    def test_old_manifest_without_patch_id_stays_strict(self):
        ev = self.mk_manifest("EV-TEST-viejo000001", "c" * 40)
        result = self.verify_with({"patch_id": "P" * 40}, commit="5" * 40,
                                  evidence_ids=[ev])
        self.assertEqual(result.returncode, 3)
        self.assertIn("se esperaba", result.stderr)   # la forma del mensaje histórico

    def test_fresh_evidence_stays_sha_strict(self):
        # la equivalencia jamás satisface la FRESCA: ese pilar no se afloja
        ev = self.mk_manifest("EV-TEST-frsh0000001", "5" * 40, patch_id="P" * 40)
        path = self.task / "verdict-atlas.json"
        path.write_text(json.dumps({
            "schema": 1, "task_id": self.task.name, "repo": "atlas",
            "commit": "5" * 40, "patch_id": "P" * 40, "evidence": [ev]}))
        result = subprocess.run(
            ["python3", str(SCRIPT), "verify", "--task-dir", str(self.task),
             "--repo", "atlas", "--commit", "9" * 40,
             "--reviewed-commit", "5" * 40, "--verdict", str(path),
             "--require-kind", "test", "--require-fresh-kind", "test"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(result.returncode, 3)
        self.assertIn("FRESCA", result.stderr)


    # ── slot + contención sellada (la máquina compartida es parte del resultado) ──
    # Caso de campo: once vitest en seis núcleos; la misma suite 503s y roja
    # bajo contención, 106s y verde en máquina libre; la contaminada se firmó
    # como buena porque nada distinguía un rojo real de un rojo por RAM.

    def _load_module(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("evidence_mod", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def _fake_docker(self):
        """Un `docker` de mentira, primero en el PATH: el test mide a QUIEN se
        envuelve, no a docker. Sin esto habria que tener docker instalado y
        buildear algo de verdad para probar una decision de tres lineas."""
        bindir = self.root / "fakebin"
        bindir.mkdir(exist_ok=True)
        fake = bindir / "docker"
        fake.write_text("#!/bin/sh\necho fake-docker \"$@\"\n")
        fake.chmod(0o755)
        return dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}")

    def _corre(self, *extra, env=None):
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "qa-atlas", "--kind", "test",
             "--cwd", str(self.repo), *extra],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifests = sorted((self.task / "evidence").glob("EV-*.json"),
                           key=lambda p: p.stat().st_mtime)
        return json.loads(manifests[-1].read_text())["contention"]

    # ── A QUIEN se le cobra el semaforo (#221) ──────────────────────────
    # El default era envolver TODO comando sellado, y contradecia el contrato
    # que el harness ensena: la Ley 8 y guard-build-slot.sh hablan SOLO de
    # `docker build/run`. Caso de campo: cuatro corridas encoladas con load
    # 0.56 en 8 nucleos y ninguna era docker (dos gates de Playwright, una
    # medicion de QA, un `go test`); una espero 25 minutos con la maquina al
    # 7%. Un gate de navegador no ocupa un slot dimensionado para builds.

    def test_comando_que_no_es_docker_no_toma_slot(self):
        cont = self._corre("--", "sh", "-c", "echo ok")
        self.assertFalse(cont["slot_wrapped"])
        self.assertIsNone(cont["test_slots"])

    def test_docker_build_toma_slot_sin_pedirlo(self):
        # Fail-CLOSED del lado que importa: si esto se rompe, un docker build
        # sellado corre sin semaforo y vuelve el load 286 con 6 nucleos.
        cont = self._corre("--", "docker", "build", ".", env=self._fake_docker())
        self.assertTrue(cont["slot_wrapped"])
        # presupuesto de BUILD (Ley 8: max(1, nucleos/4)), no el de tests: para
        # docker el runner NO pisa HARNESS_BUILD_SLOTS.
        self.assertIsNone(cont["test_slots"])

    def test_docker_adentro_de_bash_c_tambien_se_detecta(self):
        cont = self._corre("--", "bash", "-c", "docker buildx build .",
                           env=self._fake_docker())
        self.assertTrue(cont["slot_wrapped"])

    def test_slot_flag_envuelve_lo_que_no_es_docker(self):
        # La leccion de los once vitest en seis nucleos sigue disponible, pero
        # ahora la pide quien SABE que su comando funde la maquina.
        cont = self._corre("--slot", "--", "sh", "-c", "echo ok")
        self.assertTrue(cont["slot_wrapped"])
        self.assertIsInstance(cont["test_slots"], int)   # presupuesto de TESTS

    def test_docker_pesado_discrimina_como_el_hook(self):
        d = self._load_module()._docker_pesado
        for cmd in (["docker", "build", "."],
                    ["docker", "run", "--rm", "img"],
                    ["docker", "buildx", "build", "."],
                    ["docker", "compose", "-f", "x.yml", "build"],
                    ["/usr/local/bin/docker", "run", "img"],
                    ["bash", "-c", "docker build ."]):
            self.assertTrue(d(cmd), cmd)
        for cmd in (["npx", "playwright", "test"],
                    ["go", "test", "./..."],
                    ["bash", "-c", "bun run test:e2e"],
                    ["docker", "ps"],
                    ["docker", "logs", "-f", "web"],
                    ["docker", "compose", "up"]):
            self.assertFalse(d(cmd), cmd)

    def test_run_seals_contention(self):
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "qa-atlas", "--kind", "test",
             "--cwd", str(self.repo), "--", "sh", "-c", "echo ok"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence_id = next(line.split("=", 1)[1] for line in result.stdout.splitlines()
                           if line.startswith("EVIDENCE_ID="))
        data = json.loads((self.task / f"evidence/{evidence_id}.json").read_text())
        cont = data.get("contention")
        self.assertIsInstance(cont, dict)      # macOS y Linux tienen ps + loadavg
        self.assertGreaterEqual(cont["cores"], 1)
        self.assertGreaterEqual(cont["foreign_test_procs_peak"], 0)
        self.assertIn(cont["suspect"], (True, False))
        # COR-350: el conteo de ACTIVOS viaja JUNTO al viejo, no en su lugar.
        # Agregar campos al sello es aditivo; sacarlos invalidaría de golpe la
        # evidencia ya emitida, que es lo que el propio archivo advierte.
        self.assertGreaterEqual(cont["foreign_active_test_procs_peak"], 0)
        self.assertLessEqual(cont["foreign_active_test_procs_peak"],
                             cont["foreign_test_procs_peak"])
        self.assertIn(cont["active_measured"], (True, False))

    def test_no_slot_le_gana_a_slot(self):
        # --no-slot es el "nunca" explicito: gana sobre --slot y sobre la
        # deteccion de docker, para el llamador que ya gestiona el semaforo.
        cont = self._corre("--slot", "--no-slot", "--", "sh", "-c", "echo ok")
        self.assertFalse(cont["slot_wrapped"])
        cont = self._corre("--no-slot", "--", "docker", "build", ".",
                           env=self._fake_docker())
        self.assertFalse(cont["slot_wrapped"])

    def test_held_slot_is_not_reacquired(self):
        # el eslabon anti-deadlock de la cadena ship -> evidence -> build-slot.
        # Con docker, que es lo que de verdad se envuelve desde #221.
        env = self._fake_docker()
        env["HARNESS_BUILD_SLOT_HELD"] = "1"
        cont = self._corre("--", "docker", "build", ".", env=env)
        self.assertFalse(cont["slot_wrapped"])

    def test_suspect_rule_and_slots_are_deterministic(self):
        module = self._load_module()
        self.assertFalse(module._suspect(0, 99.0, 4))   # load alto solo: corrida sana
        self.assertTrue(module._suspect(3, 4.1, 4))     # ajenos Y saturada: el régimen
        self.assertFalse(module._suspect(3, 3.9, 4))    # ajenos con máquina que da abasto
        old = dict(os.environ)
        try:
            os.environ.pop("HARNESS_TEST_SLOTS", None)
            os.environ.pop("HARNESS_BUILD_SLOTS", None)
            self.assertEqual(module._test_slots(12), 4)      # max(2, cores//3)
            self.assertEqual(module._test_slots(3), 2)
            os.environ["HARNESS_BUILD_SLOTS"] = "1"
            self.assertIsNone(module._test_slots(12))        # la del usuario se respeta
            os.environ["HARNESS_TEST_SLOTS"] = "5"
            self.assertEqual(module._test_slots(12), 5)      # y TEST_SLOTS gana
        finally:
            os.environ.clear()
            os.environ.update(old)

    def test_foreign_classifier_excludes_own_tree(self):
        module = self._load_module()
        rows = [(10, 1, "pytest -q"), (11, 10, "python x"),
                (20, 1, "vim notas.md"), (30, 1, "go test ./...")]
        excluded = module._excluded_pids(rows, 10)
        self.assertIn(10, excluded)
        self.assertIn(11, excluded)
        self.assertEqual(module._foreign_test_procs(rows, excluded), 1)
        self.assertFalse(module._looks_like_test_cmd("docker ps"))

    def test_classifier_matches_delimited_tokens_not_substrings(self):
        """Caso de campo: un MCP de navegador con `@scope/mcp@latest` clavaba
        foreign_peak en 6 PERMANENTES por el `test` de `latest`, y con la mitad
        izquierda de _suspect vuelta constante el detector degradaba a
        `load > cores` y bloqueaba ships con los repos en verde."""
        module = self._load_module()
        for cmd in ("npm exec @scope/mcp@latest --browser chromium",
                    "/o/.cache/ms-browser/chromium-1/chrome --type=renderer",
                    "npm exec contest-tool@1",
                    "cat latest.log",
                    "go build ./...",
                    "cargo build"):
            self.assertFalse(module._looks_like_test_cmd(cmd), cmd)
        for cmd in ("go test ./...", "cargo test", "npm test",
                    "npm run test:unit", "python3 -m pytest tests/",
                    "node_modules/.bin/vitest --watch", "setsid nice go test ./pkg"):
            self.assertTrue(module._looks_like_test_cmd(cmd), cmd)

    def test_classifier_reads_command_position_not_the_whole_line(self):
        """El vigía que el propio harness sugiere para diagnosticar contención
        NOMBRA una suite en sus argumentos sin correrla; contarlo hacía que el
        detector se contara a sí mismo. Su contra-mitad: un script que de verdad
        ejecuta una suite sí cuenta, aunque lo lance un envoltorio."""
        module = self._load_module()
        self.assertFalse(module._looks_like_test_cmd("bash vigia.sh argos go test ./..."))
        self.assertFalse(module._looks_like_test_cmd("vim internal/auth/auth_test.go"))
        self.assertTrue(module._looks_like_test_cmd("bash test_secrets.sh"))
        self.assertTrue(module._looks_like_test_cmd("bash -c go test ./..."))

    # ── COR-350: se contaban procesos de test ajenos que NO gastan CPU ────
    # Un `vitest --watch` ocioso de otra sesión, o el árbol de Chromium del MCP
    # de Playwright, CLASIFICAN como test y mantenían foreign_peak > 0 PARA
    # SIEMPRE. Con la mitad izquierda de la conjunción vuelta constante, el
    # detector degeneraba en `load > cores` a secas, que en una máquina de 6
    # núcleos con varias sesiones es el estado NORMAL (medido: suspect=True con
    # load_max 6.17 y 6 cores, o sea fallo por 0.17).

    def test_active_cpu_classifier_ignores_idle_foreign_procs(self):
        """Se cuenta solo lo que QUEMA CPU, medido por DELTA de tiempo de CPU
        entre dos muestras. Muestras sintéticas a propósito: el criterio no
        puede depender de lo que esté corriendo en la máquina del que testea."""
        module = self._load_module()
        ocioso = "node_modules/.bin/vitest --watch"
        rows1 = [(10, 1, 0.0, ocioso), (20, 1, 0.0, "go test ./..."),
                 (30, 1, 5.0, "vim notas.md")]
        ajenos, activos, snap, medible = module._classify_active(
            rows1, set(), {}, None, 100.0)
        self.assertEqual(len(ajenos), 2)          # vim no es una suite
        self.assertFalse(medible)                 # primera muestra: sin delta
        self.assertEqual(len(activos), 2)         # no medible ⇒ cuentan (conservador)

        # segunda muestra 10s después: el watcher gastó 0.05s (0.005 de un
        # core) y la suite real gastó 10s (un core entero).
        rows2 = [(10, 1, 0.05, ocioso), (20, 1, 10.0, "go test ./...")]
        ajenos, activos, _, medible = module._classify_active(
            rows2, set(), snap, 100.0, 110.0)
        self.assertTrue(medible)
        self.assertEqual(len(ajenos), 2)          # sigue estando: no desaparece
        self.assertEqual(activos, ["go test ./..."])

        # ventana demasiado corta para que el delta signifique algo: cuentan
        # los dos. Aflojar por no poder medir sería justo el error del promedio.
        _, activos_cortos, _, medible_corto = module._classify_active(
            rows2, set(), snap, 100.0, 100.4)
        self.assertFalse(medible_corto)
        self.assertEqual(len(activos_cortos), 2)

        # y el propio árbol nunca cuenta, gaste lo que gaste
        _, activos_propios, _, _ = module._classify_active(
            rows2, {10, 20}, snap, 100.0, 110.0)
        self.assertEqual(activos_propios, [])

    def test_cpu_time_parser_handles_the_two_ps_formats(self):
        """`ps -o time` no tiene UN formato: macOS da `MM:SS.ss` y pasa a
        `HH:MM:SS` con las horas; Linux agrega `DD-HH:MM:SS` para los procesos
        de días, que es exactamente lo que son los watchers de otra sesión."""
        module = self._load_module()
        self.assertAlmostEqual(module._cpu_seconds("12:34.56"), 754.56, places=2)
        self.assertAlmostEqual(module._cpu_seconds("1:02:03"), 3723.0, places=2)
        self.assertAlmostEqual(module._cpu_seconds("2-03:00:00"), 183600.0, places=2)
        self.assertAlmostEqual(module._cpu_seconds("  0:00.04 "), 0.04, places=2)
        self.assertIsNone(module._cpu_seconds("?"))
        self.assertIsNone(module._cpu_seconds(""))

    def test_source_never_uses_the_average_cpu_column(self):
        """ASERTO ESTRUCTURAL, y esto ya costó una ronda entera de review a
        otro agente: la columna de %CPU de `ps` NO es CPU actual, es
        cputime/etime, o sea el PROMEDIO sobre toda la vida del proceso.
        Medido en vivo, un proceso al 100% de un core leía 7.4 y BAJANDO. La
        ley que sale de ahí: un proceso vivo T segundos que corre una suite de
        d segundos lee d/T*100, así que con T > 20d jamás cruza un umbral del
        5% y el `vitest --watch` de otra sesión se escapa entero. Con esa
        columna el gate queda MÁS FLOJO que antes, no más limpio.

        Se ignoran las líneas de comentario a propósito: el fuente TIENE que
        poder nombrar la trampa para que nadie la reintroduzca; lo que se
        prohíbe es USARLA."""
        codigo = "\n".join(line for line in SCRIPT.read_text().splitlines()
                           if not line.lstrip().startswith("#"))
        self.assertNotIn("pcpu", codigo)
        self.assertIn("pid,ppid,time,command", codigo)   # el delta, no el promedio

    def test_suspect_declaration_names_the_foreign_suites_and_the_residual(self):
        """El mensaje tiene que nombrar QUIÉN carga la máquina (HARNESS_TEST_SLOTS
        solo baja el paralelismo PROPIO, así que recomendarlo a secas no ayuda
        cuando la carga es de otra sesión) y, sobre todo, cuál es el residuo que
        de verdad queda abierto: una suite con guards de entorno que SALTAN tests
        cuando un servicio está lento sale verde con menos tests de los que cree.
        Eso no lo cubre ningún otro gate, así que se declara para el reviewer."""
        evidence_id = self.run_evidence()
        path = self.task / f"evidence/{evidence_id}.json"
        data = json.loads(path.read_text())
        data["contention"] = {"suspect": True, "foreign_test_procs_peak": 3,
                              "foreign_test_cmds": ["go test ./internal/..."],
                              "load_avg_max": 12.0, "cores": 6}
        path.write_text(json.dumps(data))
        result = self.verify(self.verdict(evidence_id))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("go test ./internal/...", result.stderr)
        self.assertIn("OTRA sesión", result.stderr)
        self.assertIn("HARNESS_TEST_SLOTS", result.stderr)
        self.assertIn("SALTAN", result.stderr)     # el residuo, nombrado

    def test_verify_declares_suspect_cited_evidence_instead_of_blocking(self):
        """ESTE TEST CAMBIÓ DE SENTIDO A PROPÓSITO (antes: ..._rejects_...).

        Caso de campo medido: el sello de contención dejó a un agente esperando
        a que la máquina se calmara y una tarea de 5 minutos tardó 3 HORAS y
        hubo que matarla. La causa no era el umbral: era la ASIMETRÍA que el
        gate ignoraba. `verify_one` construye `expected` con exit_code 0 y muere
        ANTES de mirar la contención, así que TODA evidencia que llegaba al
        chequeo de suspect ya había salido VERDE; y la contención produce
        TIMEOUTS, o sea rojos, no aserciones que pasan de mentira. El gate
        bloqueaba la única clase de resultado que la contención no puede
        falsificar, y su remediación ('esperá a que terminen las otras
        sesiones') puede no cumplirse nunca en un workspace multi-sesión.

        Así que suspect deja de BLOQUEAR y pasa a DECLARAR: exit 0 y una
        advertencia fuerte con los números y el residuo real."""
        evidence_id = self.run_evidence()
        manifest_path = self.task / f"evidence/{evidence_id}.json"
        data = json.loads(manifest_path.read_text())
        data["contention"] = {"suspect": True, "foreign_test_procs_peak": 11,
                              "load_avg_max": 29.4, "cores": 6}
        manifest_path.write_text(json.dumps(data))
        result = self.verify(self.verdict(evidence_id))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CONTENCIÓN", result.stderr)
        self.assertIn("29.4", result.stderr)          # los números, no un adjetivo
        self.assertIn("evidencias ligadas", result.stdout)

    def test_fresh_evidence_counts_a_green_sealed_under_contention(self):
        """CONTRA-MITAD de la declaración: el descarte en `fresh_evidence` era
        la otra mitad del cepo. Un manifiesto VERDE (exit_code 0, hash del log
        OK) sellado bajo contención cuenta como evidencia fresca; la contención
        viaja declarada, no borra la prueba."""
        self.mk_manifest("EV-TEST-susp00000001", "9" * 40,
                         contention={"suspect": True,
                                     "foreign_test_procs_peak": 11,
                                     "load_avg_max": 29.4, "cores": 6})
        path = self.task / "verdict-atlas.json"
        path.write_text(json.dumps({
            "schema": 1, "task_id": self.task.name, "repo": "atlas",
            "commit": self.commit, "evidence": [self.run_evidence()]}))
        result = subprocess.run(
            ["python3", str(SCRIPT), "verify", "--task-dir", str(self.task),
             "--repo", "atlas", "--commit", "9" * 40,
             "--reviewed-commit", self.commit, "--verdict", str(path),
             "--require-kind", "test", "--require-fresh-kind", "test"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("evidencia fresca", result.stdout)
        self.assertIn("CONTENCIÓN", result.stderr)   # y se declara, no se calla

    def test_red_evidence_under_contention_is_still_rejected(self):
        """La declaración NO afloja el exit_code: un ROJO bajo contención sí
        puede ser mentira (la contención fabrica timeouts), y ese lo sigue
        rechazando el chequeo de exit_code, antes de mirar la contención."""
        evidence_id = self.run_evidence()
        path = self.task / f"evidence/{evidence_id}.json"
        data = json.loads(path.read_text())
        data["exit_code"] = 1
        data["contention"] = {"suspect": True, "foreign_test_procs_peak": 11,
                              "load_avg_max": 29.4, "cores": 6}
        path.write_text(json.dumps(data))
        result = self.verify(self.verdict(evidence_id))
        self.assertEqual(result.returncode, 3)
        self.assertIn("exit_code", result.stderr)

    def test_old_manifest_without_contention_still_verifies(self):
        evidence_id = self.run_evidence()
        result = self.verify(self.verdict(evidence_id))
        self.assertEqual(result.returncode, 0, result.stderr)

    # ── EL ÁRBOL SE MOVIÓ MIENTRAS CORRÍA ────────────────────────────────
    # El chequeo de árbol limpio miraba solo ANTES de ejecutar, y esa ventana
    # es justo la que importa: un worktree lo comparten varios agentes.
    #
    # Caso de campo: el reviewer hizo verificación por mutación (editar src/
    # para ver un test ponerse rojo) mientras QA buildeaba sobre el MISMO
    # árbol. El build absorbió el archivo mutado, el reviewer restauró, y para
    # cuando se selló la evidencia el árbol estaba limpio otra vez: el sello
    # certificaba un commit cuyo código no fue el que corrió, sin una sola
    # señal. Lo cazó la diligencia de QA, no el harness.
    def _run_mutating(self, command):
        return subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "qa-atlas", "--kind", "test",
             "--cwd", str(self.repo), "--", "sh", "-c", command],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def test_run_refuses_to_seal_when_the_tree_moved_during_the_command(self):
        result = self._run_mutating("printf 'mutado\\n' >> README.md")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("ENSUCIÓ", result.stderr)
        # El mensaje NO puede afirmar una causa que no puede saber: desde el
        # `git status` solo, "otro agente mutó el árbol" y "el comando regeneró
        # un golden" son indistinguibles. Se nombran las DOS con su remediación
        # y se deja que los archivos listados decidan cuál es.
        self.assertIn("OTRO AGENTE", result.stderr)
        self.assertIn("worktree add --detach", result.stderr)   # remediación (a)
        self.assertIn("EL COMANDO MISMO", result.stderr)
        self.assertIn("commitea lo que regeneró", result.stderr)  # remediación (b)
        self.assertNotIn("así que alguien lo tocó", result.stderr)
        # y no queda un manifiesto sellando lo que no se puede afirmar
        sealed = list((self.task / "evidence").glob("EV-*.json")) \
            if (self.task / "evidence").is_dir() else []
        self.assertEqual(sealed, [], "selló pese a que el árbol se movió")

    def test_run_still_seals_when_the_command_only_touches_untracked(self):
        # CONTRA-MITAD: sin esto, la guarda de arriba pasaría igual con un
        # chequeo que rechace SIEMPRE. Un artefacto de build sin trackear no
        # cambia lo que el commit contiene, y rechazar por eso sería inservible
        # (es la misma razón por la que el chequeo previo usa -uno).
        result = self._run_mutating("printf 'build\\n' > out.tmp")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("EVIDENCE_ID=", result.stdout)


    # ── EJECUTAR UN ARTEFACTO CUENTA COMO ABRIRLO ────────────────────────
    # gate_evidence intersecta lo CITADO por la compliance matrix con lo LEÍDO
    # según tasks/<id>/evidence.log, y ese log lo alimentaba SOLO el hook
    # track-read (o sea: abrir el archivo con Read). Correr la prueba con
    # evidence.py no dejaba rastro ahí, así que un reviewer que EJECUTABA el
    # test y citaba su ruta quedaba rojo por no haberlo "leído".
    #
    # Pasó tres veces en la misma tarea, con tres reviewers distintos, pese a
    # que el mensaje del gate ya hablaba de "abrir". Un gate que castiga la
    # conducta más fuerte (ejecutar) para premiar la más débil (leer) está
    # midiendo lo que no quiso medir: el propio hook ya declara que "un test
    # que CORRIÓ es la evidencia más fuerte que hay".
    #
    # Se registran SOLO los tokens del comando que resuelven a un archivo real:
    # no se afloja "citado no es verificado", porque nada se apunta que no se
    # haya ejecutado de verdad.
    def _log_lines(self):
        log = self.task / "evidence.log"
        return log.read_text() if log.is_file() else ""

    def test_run_registers_the_artifact_it_executed_as_read(self):
        (self.repo / "auth_test.py").write_text("def test_ok():\n    assert True\n")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "test"], cwd=self.repo, check=True)
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "reviewer", "--kind", "test",
             "--cwd", str(self.repo), "--", "sh", "-c", "echo ok auth_test.py"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("auth_test.py", self._log_lines(),
                      "el artefacto ejecutado no quedó en evidence.log")
        self.assertIn("ran-file", self._log_lines(),
                      "y se marca como CORRIDO, no como leído a mano")

    def test_run_does_not_register_paths_that_do_not_exist(self):
        # CONTRA-MITAD: sin esto, la regla de arriba se cumpliría igual con un
        # registro que apunte cualquier palabra del comando, y entonces citar
        # una ruta inventada pasaría el gate. La ley "citado no es verificado"
        # es la razón de ser del gate y no se afloja.
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "reviewer", "--kind", "test",
             "--cwd", str(self.repo), "--", "sh", "-c", "echo ok inventado_test.py"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("inventado_test.py", self._log_lines(),
                         "apuntó como leído un archivo que no existe")

    # ── Economía de contexto: el runner acota lo que entra a la ventana ──────
    # POR QUE: este runner es OBLIGATORIO para todo comando que sustenta un
    # pass, y volcaba la salida completa al contexto del agente. Medido sobre
    # 663 transcripts: releer contexto es el 43% de la factura. Un vitest de
    # 2000 lineas son ~30k tokens que se re-leen en cada tool call posterior.
    # El log en disco es la evidencia y no se toca; lo que se acota es el eco.

    def _run_ruidoso(self, script, extra=()):
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "qa-atlas", "--kind", "test",
             "--cwd", str(self.repo), *extra, "--", "sh", "-c", script],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence_id = next(line.split("=", 1)[1] for line in result.stdout.splitlines()
                           if line.startswith("EVIDENCE_ID="))
        log = (self.task / f"evidence/{evidence_id}.log").read_text()
        return result.stdout, log

    def test_salida_corta_pasa_entera(self):
        # Un comando corto tiene que verse EXACTAMENTE igual que antes: la
        # economia no puede costarle progreso al humano en el caso comun.
        out, log = self._run_ruidoso("for i in $(seq 1 30); do echo linea-$i; done")
        for n in (1, 15, 30):
            self.assertIn(f"linea-{n}\n", out, f"perdio la linea {n} de 30")
        self.assertNotIn("omitidas", out, "resumio una salida que cabia entera")
        self.assertIn("linea-30", log)

    def test_salida_larga_se_acota_pero_el_log_queda_entero(self):
        out, log = self._run_ruidoso("for i in $(seq 1 4000); do echo linea-$i; done")
        self.assertIn("linea-1\n", out, "perdio la cabeza")
        self.assertIn("linea-4000\n", out, "perdio la cola, que es donde vive el veredicto")
        self.assertIn("omitidas", out, "no acoto una salida de 4000 lineas")
        self.assertNotIn("linea-2000\n", out, "el medio entro al contexto igual")
        # Lo que importa: la evidencia NO se degrada. El log es el artefacto
        # que sella el gate y tiene que estar completo.
        self.assertIn("linea-2000\n", log, "acoto el LOG, que es la evidencia")
        self.assertEqual(len(log.splitlines()), 4000, "el log perdio lineas")
        self.assertLess(len(out.splitlines()), 200,
                        "el resumen sigue siendo enorme")

    def test_el_error_del_medio_se_rescata(self):
        # La regla de oro heredada de quiet.sh: truncar es economia, truncar EL
        # ERROR es autolesion. Un stack trace en el minuto 3 de un log de 4000
        # lineas no puede desaparecer, o el agente "arregla" a ciegas.
        out, _ = self._run_ruidoso(
            "for i in $(seq 1 2000); do echo linea-$i; done; "
            "echo 'FAILED: el assert del medio'; "
            "for i in $(seq 2001 4000); do echo linea-$i; done")
        self.assertIn("FAILED: el assert del medio", out,
                      "se comio el unico error del tramo omitido")
        self.assertIn("rescatados", out,
                      "no marco que el rescate ocurrio: un contexto lossy "
                      "debe saberse lossy")

    def test_verbose_restaura_el_volcado_completo(self):
        out, _ = self._run_ruidoso(
            "for i in $(seq 1 4000); do echo linea-$i; done", extra=("--verbose",))
        self.assertIn("linea-2000\n", out, "--verbose no volco todo")
        self.assertNotIn("omitidas", out, "--verbose resumio igual")

    def test_una_salida_sin_saltos_de_linea_igual_se_acota(self):
        # EL BUG QUE ESTA SUITE CONGELA. El acotador solo cortaba en \n, asi
        # que una salida sin saltos contaba como UNA linea, y una sola linea
        # siempre cabe en la cabeza: entraba ENTERA. Medido antes del arreglo:
        # 20 MB de una sola linea viajaron integros al contexto, o sea el
        # acotador reportando que acoto sin acotar nada.
        out, log = self._run_ruidoso(
            "python3 -c 'import sys;sys.stdout.write(\"A\"*3000000)'")
        self.assertLess(len(out), 40_000,
                        f"3 MB en una linea entraron casi enteros: {len(out)} bytes")
        self.assertEqual(len(log), 3_000_000, "el log perdio la salida completa")

    def test_una_barra_de_progreso_con_retorno_de_carro_no_es_una_sola_linea(self):
        # vitest, jest, cargo y pytest reescriben la misma linea con \r. Sin
        # cortar ahi, una suite entera es UNA linea de megabytes.
        out, _ = self._run_ruidoso(
            "python3 -c 'import sys\n"
            "for i in range(5000): sys.stdout.write(f\"\\rprogreso {i}/5000\")\n"
            "sys.stdout.write(\"\\nSUITE OK\\n\")'")
        self.assertLess(len(out), 20_000,
                        f"la barra de progreso entro entera: {len(out)} bytes")
        self.assertIn("SUITE OK", out,
                      "se comio el final, que es lo unico que importaba")

    def test_muchas_lineas_largas_tienen_techo_total(self):
        # El techo por LINEA solo no alcanza: 10.000 lineas recortadas a 2 KB
        # siguen siendo 160 KB. Por eso hay presupuesto TOTAL.
        out, _ = self._run_ruidoso(
            "python3 -c 'print(\"\\n\".join(\"X\"*3000 for _ in range(500)))'")
        self.assertLess(len(out), 40_000,
                        f"500 lineas de 3 KB dieron {len(out)} bytes de contexto")

    def test_el_contrato_de_stdout_sobrevive_al_resumen(self):
        # EVIDENCE_ID= es lo UNICO que alguien parsea de este stdout. Si el
        # resumen se lo comiera, el gate se quedaria sin evidencia y la
        # economia habria roto la seguridad, que es exactamente el intercambio
        # que este harness no acepta.
        out, _ = self._run_ruidoso("for i in $(seq 1 4000); do echo linea-$i; done")
        ids = [l for l in out.splitlines() if l.startswith("EVIDENCE_ID=")]
        self.assertEqual(len(ids), 1, f"EVIDENCE_ID= no sobrevivio intacto: {ids}")


if __name__ == "__main__":
    unittest.main()
