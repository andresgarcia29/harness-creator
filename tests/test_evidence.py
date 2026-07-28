#!/usr/bin/env python3
import json
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
        return subprocess.run(
            ["python3", str(SCRIPT), "run", "--task-dir", str(Path(self.tmp.name) / "T1"),
             "--repo", "r", "--runner", "implementer", "--kind", "test",
             "--cwd", str(repo), "--", "true"],
            capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
