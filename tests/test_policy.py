#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "templates/scripts/harness-policy.py"
POLICY = ROOT / "templates/policy.json"


class PolicyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.task = Path(self.tmp.name) / "AUTO-20260720-policy-test"
        self.task.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_policy(self, *args):
        return subprocess.run(
            ["python3", str(SCRIPT), "--policy", str(POLICY), *map(str, args)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def transition(self, phase):
        return self.run_policy("transition", self.task, phase, "--actor", "orchestrator")

    def test_state_machine_rejects_skips(self):
        self.assertEqual(self.run_policy("init", self.task).returncode, 0)
        result = self.transition("ship")
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-TRANSITION-001", result.stderr)

    def test_review_round_budget_is_executable(self):
        self.assertEqual(self.run_policy("init", self.task).returncode, 0)
        self.assertEqual(self.transition("rfc").returncode, 0)
        self.assertEqual(self.transition("implement").returncode, 0)
        for round_number in range(1, 4):
            self.assertEqual(self.transition("review").returncode, 0)
            if round_number < 3:
                self.assertEqual(self.transition("implement").returncode, 0)
        self.assertEqual(self.transition("implement").returncode, 0)
        result = self.transition("review")
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-LIMIT-001", result.stderr)

    def test_ship_requires_independent_reviewer(self):
        self.assertEqual(self.run_policy("init", self.task).returncode, 0)
        for phase in ("rfc", "implement", "review"):
            self.assertEqual(self.transition(phase).returncode, 0)
        commit = "a" * 40
        verdict = self.task / "verdict-atlas.json"
        verdict.write_text(json.dumps({
            "schema": 1, "commit": commit, "verdict": "pass", "qa": "pass",
            "reviewer": "agent-a", "implementation_agents": ["agent-a"]
        }))
        result = self.run_policy("validate-ship", self.task, "--commit", commit, "--verdict", verdict)
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-ROLE-003", result.stderr)
        data = json.loads(verdict.read_text())
        data["reviewer"] = "reviewer-atlas"
        verdict.write_text(json.dumps(data))
        result = self.run_policy("validate-ship", self.task, "--commit", commit, "--verdict", verdict)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_budget_is_monotonic_and_enforced(self):
        self.assertEqual(self.run_policy("init", self.task, "--budget-usd", "2.5").returncode, 0)
        self.assertEqual(self.run_policy("record-cost", self.task, "--total-usd", "1.25").returncode, 0)
        backwards = self.run_policy("record-cost", self.task, "--total-usd", "1.0")
        self.assertIn("POLICY-BUDGET-001", backwards.stderr)
        exceeded = self.run_policy("record-cost", self.task, "--total-usd", "3.0")
        self.assertIn("POLICY-BUDGET-002", exceeded.stderr)

    def test_only_closed_pause_reasons_are_allowed(self):
        self.assertEqual(self.run_policy("init", self.task).returncode, 0)
        denied = self.run_policy("pause", self.task, "--reason", "felt_uncertain",
                                 "--detail", "no sé", "--actor", "orchestrator")
        self.assertIn("POLICY-PAUSE-001", denied.stderr)
        allowed = self.run_policy("pause", self.task, "--reason", "adr_conflict",
                                  "--detail", "ADR-42", "--actor", "orchestrator")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(self.run_policy("resume", self.task, "--actor", "human").returncode, 0)

    def test_dag_rejects_cycles_and_accepts_parallel_branches(self):
        dag = self.task / "dag.json"
        dag.write_text(json.dumps({"schema": 1, "tasks": [
            {"id": "T1", "repo": "atlas", "depends_on": []},
            {"id": "T2", "repo": "proto", "depends_on": ["T1"]},
            {"id": "T3", "repo": "docs", "depends_on": ["T1"]},
        ]}))
        self.assertEqual(self.run_policy("validate-dag", dag).returncode, 0)
        dag.write_text(json.dumps({"schema": 1, "tasks": [
            {"id": "T1", "repo": "atlas", "depends_on": ["T2"]},
            {"id": "T2", "repo": "proto", "depends_on": ["T1"]},
        ]}))
        cycle = self.run_policy("validate-dag", dag)
        self.assertIn("POLICY-DAG-007", cycle.stderr)


if __name__ == "__main__":
    unittest.main()
