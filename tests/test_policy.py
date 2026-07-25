#!/usr/bin/env python3
import json
import os
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

    def test_express_lane_skips_rfc(self):
        self.assertEqual(self.run_policy("init", self.task, "--lane", "express").returncode, 0)
        result = self.transition("implement")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_default_lane_still_requires_rfc(self):
        self.assertEqual(self.run_policy("init", self.task).returncode, 0)
        result = self.transition("implement")
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-TRANSITION-001", result.stderr)

    def test_unknown_lane_rejected(self):
        result = self.run_policy("init", self.task, "--lane", "turbo")
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-LANE-001", result.stderr)

    def test_escalate_recovers_skipped_rfc(self):
        self.assertEqual(self.run_policy("init", self.task, "--lane", "express").returncode, 0)
        self.assertEqual(self.transition("implement").returncode, 0)
        result = self.run_policy("escalate", self.task, "--to", "standard",
                                 "--actor", "orchestrator", "--reason", "gate_lane")
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((self.task / "state.json").read_text())
        self.assertEqual(state["lane"], "standard")
        self.assertEqual(state["phase"], "rfc")
        # el carril nuevo permite continuar el pipeline completo
        self.assertEqual(self.transition("implement").returncode, 0)

    def test_escalate_downward_rejected(self):
        self.assertEqual(self.run_policy("init", self.task).returncode, 0)
        result = self.run_policy("escalate", self.task, "--to", "express",
                                 "--actor", "orchestrator")
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-LANE-002", result.stderr)

    # ── rollback: el caso de campo que obligó a editar state.json a mano ──
    # Una transición review → ship adelantada por error dejaba la tarea sin
    # retorno: allowed_transitions["ship"] es ["deploy"], y el único camino
    # atrás vive en escalate, que exige subir de carril (imposible en full).

    def reach(self, *phases):
        self.assertEqual(self.run_policy("init", self.task).returncode, 0)
        for phase in phases:
            self.assertEqual(self.transition(phase).returncode, 0)

    def state(self):
        return json.loads((self.task / "state.json").read_text())

    def test_ship_phase_has_no_forward_path_back(self):
        self.reach("rfc", "implement", "review", "ship")
        stuck = self.transition("review")
        self.assertEqual(stuck.returncode, 3)
        self.assertIn("POLICY-TRANSITION-001", stuck.stderr)
        # escalate tampoco: en lane=full ya no hay carril superior
        escalate = self.run_policy("escalate", self.task, "--to", "full", "--actor", "human")
        self.assertEqual(escalate.returncode, 3)
        self.assertIn("POLICY-LANE-002", escalate.stderr)

    def test_rollback_undoes_a_wrong_advance_and_leaves_a_record(self):
        self.reach("rfc", "implement", "review", "ship")
        rounds_before = self.state()["review_rounds"]
        done = self.run_policy("rollback", self.task, "review", "--actor", "human",
                               "--reason", "transición adelantada por error")
        self.assertEqual(done.returncode, 0, done.stderr)
        state = self.state()
        self.assertEqual(state["phase"], "review")
        # el rollback deshace, no cobra una ronda de review que nunca ocurrió
        self.assertEqual(state["review_rounds"], rounds_before)
        last = state["history"][-1]
        self.assertEqual(last["kind"], "rollback")
        self.assertEqual((last["from"], last["to"]), ("ship", "review"))
        self.assertEqual(last["reason"], "transición adelantada por error")

    def test_rollback_only_goes_backwards_and_demands_a_reason(self):
        self.reach("rfc", "implement")
        forward = self.run_policy("rollback", self.task, "review", "--actor", "human",
                                  "--reason", "quiero saltarme el grafo")
        self.assertEqual(forward.returncode, 3)
        self.assertIn("POLICY-ROLLBACK-003", forward.stderr)
        same = self.run_policy("rollback", self.task, "implement", "--actor", "human",
                               "--reason", "no-op")
        self.assertIn("POLICY-ROLLBACK-003", same.stderr)
        unknown = self.run_policy("rollback", self.task, "produccion", "--actor", "human",
                                  "--reason", "typo")
        self.assertIn("POLICY-ROLLBACK-002", unknown.stderr)
        mute = self.run_policy("rollback", self.task, "rfc", "--actor", "human", "--reason", "   ")
        self.assertEqual(mute.returncode, 3)
        self.assertIn("POLICY-ROLLBACK-004", mute.stderr)

    def test_rollback_refuses_a_blocked_task(self):
        self.reach("rfc", "implement")
        self.assertEqual(self.run_policy("pause", self.task, "--reason", "adr_conflict",
                                         "--detail", "ADR-42", "--actor", "human").returncode, 0)
        blocked = self.run_policy("rollback", self.task, "rfc", "--actor", "human",
                                  "--reason", "confundí pausa con rollback")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-ROLLBACK-001", blocked.stderr)

    # ── history como control, no como prosa ──

    def valid_verdict(self, commit):
        verdict = self.task / "verdict-atlas.json"
        verdict.write_text(json.dumps({
            "schema": 1, "commit": commit, "verdict": "pass", "qa": "pass",
            "reviewer": "reviewer-atlas", "implementation_agents": ["agent-a"],
        }))
        return verdict

    def test_ship_rejects_a_phase_nobody_declared(self):
        self.reach("rfc", "implement", "review", "ship")
        commit = "b" * 40
        verdict = self.valid_verdict(commit)
        # la edición a mano: phase vuelve a review sin pasar por el motor
        state = self.state()
        state["phase"] = "review"
        (self.task / "state.json").write_text(json.dumps(state))
        forged = self.run_policy("validate-ship", self.task, "--commit", commit,
                                 "--verdict", verdict)
        self.assertEqual(forged.returncode, 3)
        self.assertIn("POLICY-STATE-003", forged.stderr)
        # el mismo destino, declarado por rollback, sí pasa
        state["phase"] = "ship"
        (self.task / "state.json").write_text(json.dumps(state))
        self.assertEqual(self.run_policy("rollback", self.task, "review", "--actor", "human",
                                         "--reason", "transición adelantada").returncode, 0)
        declared = self.run_policy("validate-ship", self.task, "--commit", commit,
                                   "--verdict", verdict)
        self.assertEqual(declared.returncode, 0, declared.stderr)

    def test_untouched_task_still_ships(self):
        # el invariante no puede romper el camino feliz de siempre
        self.reach("rfc", "implement", "review")
        commit = "c" * 40
        ok = self.run_policy("validate-ship", self.task, "--commit", commit,
                             "--verdict", self.valid_verdict(commit))
        self.assertEqual(ok.returncode, 0, ok.stderr)

    # ── la trampa multi-repo ──
    # Caso de campo: tarea de 2 repos, se avanzó review → ship tras shippear el
    # primero, y el segundo quedó listo (verdict pass, qa pass, gates verdes) y
    # trabado por el número de fase, sin vuelta atrás por CLI.

    def mk_verdict(self, repo):
        (self.task / f"verdict-{repo}.json").write_text(json.dumps({
            "schema": 1, "verdict": "pass", "qa": "pass", "reviewer": "rev",
            "implementation_agents": ["impl"],
        }))

    def mk_shipped(self, repo):
        with (self.task / "ship.log").open("a") as log:
            log.write(json.dumps({"repo": repo, "sha": "abc1234",
                                  "shipped_at": "2026-07-24T10:00:00Z"}) + "\n")

    def test_ship_phase_refuses_while_a_repo_still_has_to_ship(self):
        self.reach("rfc", "implement", "review")
        self.mk_verdict("design-system")
        self.mk_verdict("videocore")
        self.mk_shipped("design-system")     # solo el primero llegó a main
        blocked = self.transition("ship")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-SHIP-004", blocked.stderr)
        self.assertIn("videocore", blocked.stderr)
        self.assertNotIn("design-system", blocked.stderr.split("faltan repos por shippear")[1][:40])
        self.assertEqual(self.state()["phase"], "review")   # no se movió
        # shippeado el segundo, la transición pasa
        self.mk_shipped("videocore")
        self.assertEqual(self.transition("ship").returncode, 0)
        self.assertEqual(self.state()["phase"], "ship")

    def test_ship_phase_allows_a_task_with_no_verdicts_yet(self):
        # el guard no puede romper el camino de una tarea sin veredictos en disco
        self.reach("rfc", "implement", "review")
        self.assertEqual(self.transition("ship").returncode, 0)

    def test_corrupt_ship_log_line_does_not_fake_a_ship(self):
        self.reach("rfc", "implement", "review")
        self.mk_verdict("videocore")
        (self.task / "ship.log").write_text("esto no es json\n")
        blocked = self.transition("ship")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-SHIP-004", blocked.stderr)

    # ── exclusión mutua entre sesiones ──
    # Varias sesiones de Claude Code comparten el workspace. La carrera del
    # read-modify-write sobre state.json es estrecha y no se puede disparar
    # por fuerza bruta (el arranque de Python la tapa), así que en vez de
    # jugar a la probabilidad se prueba el MECANISMO: con el lock tomado por
    # otro, el comando tiene que bloquear, no pasar de largo.

    def test_state_mutations_are_mutually_exclusive(self):
        import fcntl
        self.reach("rfc", "implement")
        lock_path = self.task / ".state.lock"
        holder = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(holder, fcntl.LOCK_EX)
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                subprocess.run(
                    ["python3", str(SCRIPT), "--policy", str(POLICY),
                     "transition", str(self.task), "review", "--actor", "otra-sesion"],
                    capture_output=True, timeout=3,
                )
            # el estado no se movió mientras el lock estaba tomado
            state = json.loads((self.task / "state.json").read_text())
            self.assertEqual(state["phase"], "implement")
        finally:
            fcntl.flock(holder, fcntl.LOCK_UN)
            os.close(holder)
        # liberado el lock, el mismo comando pasa
        self.assertEqual(self.transition("review").returncode, 0)
        self.assertEqual(self.state()["phase"], "review")

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
