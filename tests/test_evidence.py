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

    def tearDown(self):
        self.tmp.cleanup()

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

    def run_ev_in(self, repo):
        # evidence.py ya NO crea task-dirs: el fixture lo crea con un marker,
        # como haría worktree-task.sh en una instancia real.
        t1 = Path(self.tmp.name) / "T1"
        t1.mkdir(exist_ok=True)
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

    def test_run_takes_a_slot_and_seals_contention(self):
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
        self.assertTrue(cont["slot_wrapped"])  # build-slot.sh vive junto a evidence.py
        self.assertGreaterEqual(cont["cores"], 1)
        self.assertGreaterEqual(cont["foreign_test_procs_peak"], 0)
        self.assertIn(cont["suspect"], (True, False))

    def test_no_slot_flag_skips_wrapper(self):
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "qa-atlas", "--kind", "test",
             "--cwd", str(self.repo), "--no-slot", "--", "sh", "-c", "echo ok"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifests = sorted((self.task / "evidence").glob("EV-*.json"),
                           key=lambda p: p.stat().st_mtime)
        data = json.loads(manifests[-1].read_text())
        self.assertFalse(data["contention"]["slot_wrapped"])

    def test_held_slot_is_not_reacquired(self):
        # el eslabón anti-deadlock de la cadena ship → evidence → build-slot
        env = dict(os.environ, HARNESS_BUILD_SLOT_HELD="1")
        result = subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(self.task),
             "--repo", "atlas", "--runner", "qa-atlas", "--kind", "test",
             "--cwd", str(self.repo), "--", "sh", "-c", "echo ok"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifests = sorted((self.task / "evidence").glob("EV-*.json"),
                           key=lambda p: p.stat().st_mtime)
        data = json.loads(manifests[-1].read_text())
        self.assertFalse(data["contention"]["slot_wrapped"])

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

    def test_verify_rejects_suspect_cited_evidence(self):
        evidence_id = self.run_evidence()
        manifest_path = self.task / f"evidence/{evidence_id}.json"
        data = json.loads(manifest_path.read_text())
        data["contention"] = {"suspect": True, "foreign_test_procs_peak": 11,
                              "load_avg_max": 29.4, "cores": 6}
        manifest_path.write_text(json.dumps(data))
        result = self.verify(self.verdict(evidence_id))
        self.assertEqual(result.returncode, 3)
        self.assertIn("contención", result.stderr)
        self.assertIn("HARNESS_TEST_SLOTS", result.stderr)

    def test_fresh_gap_names_suspect_reason(self):
        ev = self.mk_manifest("EV-TEST-susp00000001", "9" * 40,
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
        self.assertEqual(result.returncode, 3)
        self.assertIn("suspect", result.stderr)

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
        self.assertIn("otro agente", result.stderr)
        self.assertIn("worktree add --detach", result.stderr)   # la remediación exacta
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


if __name__ == "__main__":
    unittest.main()
