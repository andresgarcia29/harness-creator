#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "templates/scripts/harness-policy.py"
POLICY_TMPL = ROOT / "templates/policy.json.tmpl"

# El policy de la instancia se RENDERIZA: max_review_rounds sale de
# loop_budget. Mientras estuvo hardcodeado en 3, pipeline.md prometía
# "máx {{LOOP_BUDGET}} iteraciones" y el motor paraba en 3 igual, así que
# quien configuraba 5 recibía 3 sin enterarse.
_LOOP_BUDGET = 3
_rendered = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
_rendered.write(POLICY_TMPL.read_text().replace("{{LOOP_BUDGET}}", str(_LOOP_BUDGET)))
_rendered.close()
POLICY = Path(_rendered.name)


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

    def test_review_budget_comes_from_loop_budget_not_a_hardcoded_3(self):
        # Regresión: el numero que el humano configura tiene que ser el que
        # gobierna. Con 3 a fuego, subir loop_budget no servía de nada y el
        # pipeline paraba antes de lo configurado, sin decir por qué.
        self.assertIn("{{LOOP_BUDGET}}", POLICY_TMPL.read_text(),
                      "max_review_rounds volvió a estar hardcodeado")
        generous = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
        generous.write(POLICY_TMPL.read_text().replace("{{LOOP_BUDGET}}", "5"))
        generous.close()
        self.assertEqual(self.run_policy("init", self.task).returncode, 0)
        for phase in ("rfc", "implement"):
            self.assertEqual(self.transition(phase).returncode, 0)
        # con presupuesto 5, la cuarta ronda de review ya no muere
        for _ in range(4):
            self.assertEqual(subprocess.run(
                ["python3", str(SCRIPT), "--policy", generous.name,
                 "transition", str(self.task), "review", "--actor", "orch"],
                capture_output=True, text=True).returncode, 0)
            self.assertEqual(subprocess.run(
                ["python3", str(SCRIPT), "--policy", generous.name,
                 "transition", str(self.task), "implement", "--actor", "orch"],
                capture_output=True, text=True).returncode, 0)
        os.unlink(generous.name)

    # ── SHIP-004 desde el DAG ──
    # Caso de campo: la fase saltó a ship con repos del DAG sin veredicto.
    # El gate contaba repos CON veredicto, no repos PLANIFICADOS: shippear
    # proto movió la tarea entera y bloqueó el review de video-forge (hubo
    # que hacer rollback).

    def mk_dag(self, *repos):
        (self.task / "dag.json").write_text(json.dumps({
            "schema": 1,
            "tasks": [{"id": f"T{i+1}", "repo": r, "depends_on": []}
                      for i, r in enumerate(repos)],
        }))

    def test_ship_refuses_while_a_dag_repo_has_no_verdict(self):
        self.reach("rfc", "implement", "review")
        self.mk_dag("proto", "video-forge")
        self.mk_verdict("proto")
        self.mk_shipped("proto")
        blocked = self.transition("ship")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-SHIP-004", blocked.stderr)
        self.assertIn("video-forge", blocked.stderr)
        self.assertIn("/review", blocked.stderr)      # la remediación nombra el paso
        self.assertEqual(self.state()["phase"], "review")
        # con veredicto pero sin ship sigue bloqueado (la rama pendiente de hoy)
        self.mk_verdict("video-forge")
        self.assertEqual(self.transition("ship").returncode, 3)
        # shippeado, pasa
        self.mk_shipped("video-forge")
        self.assertEqual(self.transition("ship").returncode, 0)

    def test_ship_without_dag_behaves_like_today(self):
        # el carril express no genera DAG: cero regresión
        self.reach("rfc", "implement", "review")
        self.assertEqual(self.transition("ship").returncode, 0)

    def test_corrupt_dag_blocks_ship_instead_of_vanishing_repos(self):
        self.reach("rfc", "implement", "review")
        (self.task / "dag.json").write_text("esto no es json")
        blocked = self.transition("ship")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-SHIP-004", blocked.stderr)
        self.assertIn("validate-dag", blocked.stderr)
        self.assertEqual(self.state()["phase"], "review")

    def test_ship_refuses_while_a_state_repo_has_no_verdict(self):
        # issue #34: el carril express NO genera DAG, y una tarea de dos repos
        # avanzó a ship al shippear el primero; el segundo rebotó con
        # TRANSITION-001/SHIP-001 y costó tres rollbacks. La fuente que sí
        # existe siempre que init recibió --repos es state.repos.
        self.assertEqual(self.run_policy("init", self.task,
                                         "--repos", "proto,video-forge").returncode, 0)
        for phase in ("rfc", "implement", "review"):
            self.assertEqual(self.transition(phase).returncode, 0)
        self.mk_verdict("proto")
        self.mk_shipped("proto")
        blocked = self.transition("ship")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-SHIP-004", blocked.stderr)
        self.assertIn("video-forge", blocked.stderr)
        self.assertEqual(self.state()["phase"], "review")
        self.mk_verdict("video-forge")
        self.mk_shipped("video-forge")
        self.assertEqual(self.transition("ship").returncode, 0)

    def test_verdict_outside_the_dag_still_counts_as_pending(self):
        # la unión: un repo con veredicto que el DAG no lista sigue exigiendo ship
        self.reach("rfc", "implement", "review")
        self.mk_dag("proto")
        self.mk_verdict("proto")
        self.mk_shipped("proto")
        self.mk_verdict("extra")             # fuera del DAG, sin ship
        blocked = self.transition("ship")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("extra", blocked.stderr)

    # ── ARCHIVE-001: el delta-spec que ningún reviewer vio ──
    # Caso de campo: el delta-spec se enmendó a mitad de corrida y dos
    # reviewers tuvieron que avisar a mano "no archives el texto viejo". Si
    # ninguno lo nota, las specs maestras heredan una regla que nadie revisó.

    def reach_deploy(self):
        self.reach("rfc", "implement", "review")
        self.mk_verdict("atlas")
        self.mk_shipped("atlas")
        self.assertEqual(self.transition("ship").returncode, 0)
        self.assertEqual(self.transition("deploy").returncode, 0)

    def test_archive_refuses_a_delta_spec_amended_after_the_verdicts(self):
        self.reach_deploy()
        (self.task / "delta-spec.md").write_text("## ADDED\n- R1: enmendado\n")
        base = 1_800_000_000
        os.utime(self.task / "verdict-atlas.json", (base, base))
        os.utime(self.task / "delta-spec.md", (base + 60, base + 60))
        blocked = self.transition("archive")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-ARCHIVE-001", blocked.stderr)
        self.assertIn("/review", blocked.stderr)      # remediación nombrada
        self.assertEqual(self.state()["phase"], "deploy")
        # veredicto re-emitido (más nuevo que el delta): pasa
        os.utime(self.task / "verdict-atlas.json", (base + 120, base + 120))
        self.assertEqual(self.transition("archive").returncode, 0)

    def test_archive_without_delta_spec_keeps_working(self):
        self.reach_deploy()
        self.assertEqual(self.transition("archive").returncode, 0)

    def test_deploy_is_not_blocked_by_a_stale_delta(self):
        # la decisión: el gate protege la FUSIÓN de specs, no el deploy
        self.reach("rfc", "implement", "review")
        self.mk_verdict("atlas")
        self.mk_shipped("atlas")
        self.assertEqual(self.transition("ship").returncode, 0)
        (self.task / "delta-spec.md").write_text("x")
        base = 1_800_000_000
        os.utime(self.task / "verdict-atlas.json", (base, base))
        os.utime(self.task / "delta-spec.md", (base + 60, base + 60))
        self.assertEqual(self.transition("deploy").returncode, 0)

    # ── LANE-004: el carril se valida contra lo que TOCA, no contra el tamaño ──
    # Caso de campo: express asignado a una tarea que tocaba terraform/; el
    # gate_lane la frenó, pero DESPUÉS de que el implementer hiciera el trabajo.

    MANIFEST = (
        "project: t\n"
        "repos:\n"
        "  - name: atlas\n    kind: service\n    agent: svc\n"
        "  - name: terraform-core\n    kind: infra-module\n    agent: infra\n"
        "  - name: net-live\n    kind: infra-live\n    agent: infra\n"
    )

    def ws_task(self, manifest=MANIFEST):
        ws = Path(self.tmp.name)
        task = ws / "tasks" / "AUTO-20260727-lane-kind"
        task.mkdir(parents=True)
        if manifest is not None:
            (ws / "manifest.yaml").write_text(manifest)
        return task

    def test_express_with_infra_repo_is_refused_at_init(self):
        task = self.ws_task()
        r = self.run_policy("init", task, "--lane", "express",
                            "--repos", "terraform-core")
        self.assertEqual(r.returncode, 3)
        self.assertIn("POLICY-LANE-004", r.stderr)
        self.assertIn("terraform-core", r.stderr)
        self.assertIn("standard", r.stderr)           # la remediación nombra el carril
        self.assertFalse((task / "state.json").exists())   # no dejó estado a medias

    def test_express_with_service_repo_records_repos(self):
        task = self.ws_task()
        r = self.run_policy("init", task, "--lane", "express", "--repos", "atlas")
        self.assertEqual(r.returncode, 0, r.stderr)
        state = json.loads((task / "state.json").read_text())
        self.assertEqual(state["repos"], ["atlas"])

    def test_standard_lane_accepts_infra_repos(self):
        task = self.ws_task()
        r = self.run_policy("init", task, "--lane", "standard",
                            "--repos", "net-live,atlas")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_init_without_repos_flag_is_unchanged(self):
        # compat: prompts viejos que no pasan --repos
        self.assertEqual(self.run_policy("init", self.task,
                                         "--lane", "express").returncode, 0)
        self.assertNotIn("repos", self.state())

    def test_missing_manifest_fails_open(self):
        task = self.ws_task(manifest=None)
        r = self.run_policy("init", task, "--lane", "express",
                            "--repos", "terraform-core")
        self.assertEqual(r.returncode, 0, r.stderr)   # aviso, no bloqueo

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
