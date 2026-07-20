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


if __name__ == "__main__":
    unittest.main()
