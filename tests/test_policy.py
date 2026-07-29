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

    def transition_repo(self, phase, repo):
        return self.run_policy("transition", self.task, phase,
                               "--actor", "orchestrator", "--repo", repo)

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

    def test_missing_manifest_screams_instead_of_skipping_silently(self):
        # Caso de campo: repo_kinds vacio salteaba el chequeo carril/kind SIN
        # una linea, y el silencio se leyo como "chequeo pasado". El fail-open
        # se conserva; el silencio no.
        task = self.ws_task(manifest=None)
        r = self.run_policy("init", task, "--lane", "express",
                            "--repos", "terraform-core")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("el chequeo carril/kind NO corrio", r.stderr)
        self.assertIn("gate_lane", r.stderr)          # el backstop, nombrado

    def test_readable_manifest_does_not_scream(self):
        # El aviso existe para la ausencia, no como ruido de fondo: con
        # manifest legible y kinds resueltos no puede aparecer, o el dia que
        # importe ya nadie lo leera.
        task = self.ws_task()
        r = self.run_policy("init", task, "--lane", "express", "--repos", "atlas")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("el chequeo carril/kind NO corrio", r.stderr)

    # ── el presupuesto de rondas POR REPO (primer test que pasa --repo) ──

    def test_review_rounds_counted_per_repo(self):
        self.reach("rfc", "implement")
        for _ in range(3):
            self.assertEqual(self.transition_repo("review", "atlas").returncode, 0)
            self.assertEqual(self.transition("implement").returncode, 0)
        blocked = self.transition_repo("review", "atlas")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-LIMIT-001", blocked.stderr)
        self.assertIn("atlas", blocked.stderr)
        # el presupuesto es por repo: proto arranca su ronda 1 sin castigo
        allowed = self.transition_repo("review", "proto")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        state = self.state()
        self.assertEqual(state["review_rounds_by_repo"]["atlas"], 3)
        self.assertEqual(state["review_rounds_by_repo"]["proto"], 1)
        self.assertEqual(state["review_rounds"], 3)   # el máximo entre repos

    def test_last_round_warns_with_repo_and_only_then(self):
        self.reach("rfc", "implement")
        first = self.transition_repo("review", "atlas")
        self.assertNotIn("última ronda", first.stdout)
        self.assertEqual(self.transition("implement").returncode, 0)
        second = self.transition_repo("review", "atlas")
        self.assertNotIn("última ronda", second.stdout)
        self.assertEqual(self.transition("implement").returncode, 0)
        third = self.transition_repo("review", "atlas")
        self.assertIn("última ronda", third.stdout)
        self.assertIn("atlas", third.stdout)
        self.assertIn("pase profundo", third.stdout)

    def test_last_round_warning_reaches_the_bus_with_cost(self):
        # emit_bus exige ws/scripts/emit.sh (ws = task_dir.parent.parent)
        ws = Path(self.tmp.name)
        task = ws / "tasks" / "AUTO-20260728-bus-test"
        task.mkdir(parents=True)
        (ws / "scripts").mkdir(exist_ok=True)
        import shutil as _sh
        _sh.copy(ROOT / "templates/scripts/emit.sh", ws / "scripts/emit.sh")
        self.assertEqual(self.run_policy("init", task, "--budget-usd", "5").returncode, 0)
        self.assertEqual(self.run_policy("record-cost", task,
                                         "--total-usd", "1.25").returncode, 0)
        def t(phase, repo=None):
            args = ["transition", task, phase, "--actor", "orch"]
            if repo:
                args += ["--repo", repo]
            return self.run_policy(*args)
        for phase in ("rfc", "implement"):
            self.assertEqual(t(phase).returncode, 0)
        for _ in range(2):
            self.assertEqual(t("review", "atlas").returncode, 0)
            self.assertEqual(t("implement").returncode, 0)
        third = t("review", "atlas")
        self.assertIn("gastado $1.25 de $5.00", third.stdout)
        bus = (ws / ".harness/events.jsonl").read_text()
        self.assertIn('"decision"', bus)
        self.assertIn("ltima ronda", bus)   # sin la tilde: el bus escapa unicode

    # ── ARCHIVE-002: non_blocking sin bead no se archiva (si hay motor) ──

    def _bd_stub_env(self, present=True):
        bindir = Path(self.tmp.name) / ("bin-con-bd" if present else "bin-sin-bd")
        bindir.mkdir(exist_ok=True)
        if present:
            stub = bindir / "bd"
            stub.write_text("#!/bin/sh\necho 'Created hc-001'\n")
            stub.chmod(0o755)
        env = dict(os.environ)
        env["PATH"] = f"{bindir}:{env['PATH']}" if present else "/usr/bin:/bin"
        return env

    def run_policy_env(self, env, *args):
        return subprocess.run(
            ["python3", str(SCRIPT), "--policy", str(POLICY), *map(str, args)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, env=env)

    def _reach_deploy_with_unbeaded(self):
        self.reach("rfc", "implement", "review")
        self.mk_verdict("atlas")
        verdict = self.task / "verdict-atlas.json"
        data = json.loads(verdict.read_text())
        data["non_blocking"] = ["nombre de variable pobre"]
        verdict.write_text(json.dumps(data))
        self.mk_shipped("atlas")
        self.assertEqual(self.transition("ship").returncode, 0)
        self.assertEqual(self.transition("deploy").returncode, 0)

    def test_archive_blocks_unbeaded_non_blocking_when_bd_exists(self):
        self._reach_deploy_with_unbeaded()
        env = self._bd_stub_env(present=True)
        blocked = self.run_policy_env(env, "transition", self.task, "archive",
                                      "--actor", "orch")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-ARCHIVE-002", blocked.stderr)
        self.assertIn("verdict-atlas.json", blocked.stderr)
        self.assertIn("verdict-beads.sh", blocked.stderr)

    def test_archive_warns_without_bd(self):
        self._reach_deploy_with_unbeaded()
        env = self._bd_stub_env(present=False)
        done = self.run_policy_env(env, "transition", self.task, "archive",
                                   "--actor", "orch")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("no se exige lo que la máquina no puede dar", done.stdout)

    def test_archive_accepts_beaded_entries(self):
        self.reach("rfc", "implement", "review")
        self.mk_verdict("atlas")
        verdict = self.task / "verdict-atlas.json"
        data = json.loads(verdict.read_text())
        data["non_blocking"] = [{"text": "mejora menor", "bead": "hc-042"}]
        verdict.write_text(json.dumps(data))
        self.mk_shipped("atlas")
        self.assertEqual(self.transition("ship").returncode, 0)
        self.assertEqual(self.transition("deploy").returncode, 0)
        env = self._bd_stub_env(present=True)
        done = self.run_policy_env(env, "transition", self.task, "archive",
                                   "--actor", "orch")
        self.assertEqual(done.returncode, 0, done.stderr)

    # ── dag-order: el orden de shipping por fin EJECUTABLE ──

    def test_dag_order_topological_dedup_last_occurrence(self):
        # atlas tiene T1 y T3 (que además depende de T2 de proto): la ola hace
        # UN ship por repo, así que atlas va DESPUÉS de proto (última
        # aparición; posicionarlo en T1 aterrizaría T3 antes que su dependencia)
        #
        # T3 depende TAMBIÉN de T1 porque las dos son del mismo repo y por lo
        # tanto comparten worktree, rama e index: POLICY-DAG-010 exige que el
        # plan las ordene. Este fixture nació antes de esa regla y describía un
        # plan que hoy es ilegal; el orden explícito no cambia lo que el test
        # mide (proto antes que atlas), solo lo hace un plan que se puede
        # ejecutar sin que dos implementers se pisen.
        self.mk_dag_items([
            {"id": "T1", "repo": "atlas", "depends_on": []},
            {"id": "T2", "repo": "proto", "depends_on": []},
            {"id": "T3", "repo": "atlas", "depends_on": ["T2", "T1"]},
        ])
        result = self.run_policy("dag-order", self.task)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["proto", "atlas"])

    def test_dag_order_cycle_fails(self):
        self.mk_dag_items([
            {"id": "T1", "repo": "atlas", "depends_on": ["T2"]},
            {"id": "T2", "repo": "proto", "depends_on": ["T1"]},
        ])
        result = self.run_policy("dag-order", self.task)
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-DAG-007", result.stderr)

    def test_dag_order_missing_dag_fails(self):
        result = self.run_policy("dag-order", self.task)
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-DAG-008", result.stderr)
        self.assertIn("express", result.stderr)   # la remediación nombra el camino

    def test_dag_order_interleaved_repo_fails_closed(self):
        # T1:atlas ← T2:proto ← T3:atlas es ordenable; pero si ADEMÁS proto
        # depende de una tarea de atlas que va después, exige intercalar
        self.mk_dag_items([
            {"id": "T1", "repo": "atlas", "depends_on": ["T2"]},
            {"id": "T2", "repo": "proto", "depends_on": []},
            {"id": "T3", "repo": "proto", "depends_on": ["T1"]},
        ])
        result = self.run_policy("dag-order", self.task)
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-DAG-009", result.stderr)
        self.assertIn("a mano", result.stderr)

    def mk_dag_items(self, items):
        (self.task / "dag.json").write_text(json.dumps({
            "schema": 1, "tasks": items}))

    # ── el carril quick: recorta DELIBERACIÓN, jamás verificación ──
    # quick es una promesa del humano (un repo, diff chico). Todo lo que se
    # puede comprobar sin ver el diff se comprueba al crear la tarea; el techo
    # de tamaño lo confirma gate_lane contra el merge-base, leyendo el dato
    # desde acá y no con un jq propio.

    def test_quick_lane_skips_rfc_like_express(self):
        self.assertEqual(self.run_policy("init", self.task, "--lane", "quick").returncode, 0)
        for phase in ("implement", "review", "ship"):
            moved = self.transition(phase)
            self.assertEqual(moved.returncode, 0, moved.stderr)
        self.assertEqual(self.state()["phase"], "ship")

    def test_quick_lane_has_no_rfc_at_all(self):
        # el grafo del carril es el que manda: quick no declara la fase rfc
        self.assertEqual(self.run_policy("init", self.task, "--lane", "quick").returncode, 0)
        blocked = self.transition("rfc")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-TRANSITION-001", blocked.stderr)
        self.assertIn("quick", blocked.stderr)          # el mensaje nombra el carril

    def test_quick_ships_under_the_very_same_contract(self):
        # lo que quick recorta es deliberación: el contrato de ship es idéntico
        self.assertEqual(self.run_policy("init", self.task, "--lane", "quick").returncode, 0)
        for phase in ("implement", "review"):
            self.assertEqual(self.transition(phase).returncode, 0)
        commit = "d" * 40
        verdict = self.valid_verdict(commit)
        data = json.loads(verdict.read_text())
        data["implementation_agents"] = [data["reviewer"]]
        verdict.write_text(json.dumps(data))
        forged = self.run_policy("validate-ship", self.task, "--commit", commit,
                                 "--verdict", verdict)
        self.assertEqual(forged.returncode, 3)
        self.assertIn("POLICY-ROLE-003", forged.stderr)   # reviewer independiente igual
        ok = self.run_policy("validate-ship", self.task, "--commit", commit,
                             "--verdict", self.valid_verdict(commit))
        self.assertEqual(ok.returncode, 0, ok.stderr)

    def test_quick_with_more_than_one_repo_is_refused_at_init(self):
        task = self.ws_task()
        refused = self.run_policy("init", task, "--lane", "quick",
                                  "--repos", "atlas,proto")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-LANE-005", refused.stderr)
        self.assertIn("proto", refused.stderr)
        self.assertIn("express", refused.stderr)      # la remediación nombra el carril
        self.assertFalse((task / "state.json").exists())   # sin estado a medias

    def test_quick_with_one_repo_records_it(self):
        task = self.ws_task()
        created = self.run_policy("init", task, "--lane", "quick", "--repos", "atlas")
        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertEqual(json.loads((task / "state.json").read_text())["repos"], ["atlas"])

    def test_quick_with_infra_repo_is_refused_at_init_too(self):
        # mismo criterio que express: el carril corto promete cero infra, y
        # descubrirlo en el precheck cuesta el trabajo del implementer
        task = self.ws_task()
        refused = self.run_policy("init", task, "--lane", "quick",
                                  "--repos", "net-live")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-LANE-004", refused.stderr)
        self.assertIn("quick", refused.stderr)
        self.assertIn("net-live", refused.stderr)
        self.assertIn("standard", refused.stderr)
        self.assertFalse((task / "state.json").exists())

    def test_escalate_from_quick_lands_where_the_new_lane_can_move(self):
        # La trampa que abrió el carril nuevo: escalar mandaba SIEMPRE a rfc, y
        # el grafo de express no declara rfc. La tarea quedaba en una fase sin
        # ninguna transición válida, o sea trabada por el número de fase.
        self.assertEqual(self.run_policy("init", self.task, "--lane", "quick").returncode, 0)
        self.assertEqual(self.transition("implement").returncode, 0)
        up = self.run_policy("escalate", self.task, "--to", "express",
                             "--actor", "orchestrator", "--reason", "gate_lane: techo excedido")
        self.assertEqual(up.returncode, 0, up.stderr)
        state = self.state()
        self.assertEqual(state["lane"], "express")
        self.assertEqual(state["phase"], "intake")
        self.assertEqual(self.transition("implement").returncode, 0)

    def test_escalate_from_quick_to_standard_still_recovers_the_rfc(self):
        self.assertEqual(self.run_policy("init", self.task, "--lane", "quick").returncode, 0)
        self.assertEqual(self.transition("implement").returncode, 0)
        up = self.run_policy("escalate", self.task, "--to", "standard", "--actor", "orch")
        self.assertEqual(up.returncode, 0, up.stderr)
        self.assertEqual(self.state()["phase"], "rfc")
        self.assertEqual(self.transition("implement").returncode, 0)

    def test_escalate_down_to_quick_is_rejected(self):
        self.assertEqual(self.run_policy("init", self.task, "--lane", "express").returncode, 0)
        down = self.run_policy("escalate", self.task, "--to", "quick", "--actor", "orch")
        self.assertEqual(down.returncode, 3)
        self.assertIn("POLICY-LANE-002", down.stderr)
        self.assertEqual(self.state()["lane"], "express")

    # ── lane-limits: el techo es DATO del policy, con un solo lector ──

    def test_lane_limits_publishes_the_quick_ceiling(self):
        limits = self.run_policy("lane-limits", "quick")
        self.assertEqual(limits.returncode, 0, limits.stderr)
        self.assertEqual(limits.stdout.split(), ["max_files=8", "max_lines=200"])

    def test_lane_limits_reads_the_policy_and_not_a_hardcoded_number(self):
        # si el techo estuviera cableado en el script, editar el policy no
        # cambiaría nada y el humano creería haber movido algo
        other = self.policy_with({"max_files": 3, "max_lines": 40})
        limits = self.run_with_policy(other, "lane-limits", "quick")
        self.assertEqual(limits.returncode, 0, limits.stderr)
        self.assertEqual(limits.stdout.split(), ["max_files=3", "max_lines=40"])

    def test_lane_limits_without_ceiling_is_empty_and_explains_why(self):
        # express no promete techo de tamaño: stdout vacío con exit 0 es la
        # respuesta, y el motivo va por stderr para que no parezca un silencio
        limits = self.run_policy("lane-limits", "express")
        self.assertEqual(limits.returncode, 0, limits.stderr)
        self.assertEqual(limits.stdout.strip(), "")
        self.assertIn("no declara limits", limits.stderr)

    def test_lane_limits_of_an_unknown_lane_is_not_silence(self):
        limits = self.run_policy("lane-limits", "turbo")
        self.assertEqual(limits.returncode, 3)
        self.assertIn("POLICY-LANE-001", limits.stderr)
        self.assertEqual(limits.stdout.strip(), "")

    def test_an_unreadable_ceiling_is_never_read_as_no_ceiling(self):
        # el tercer estado: no poder leer el techo NO es "este carril no tiene
        # techo" (fail-open) ni un rojo inventado; es un error tipado
        for broken in ({"max_files": "ocho", "max_lines": 200},
                       {"max_files": 0, "max_lines": 200},
                       {"max_files": True, "max_lines": 200},
                       "8 archivos"):
            with self.subTest(limits=broken):
                mutated = self.policy_with(broken)
                limits = self.run_with_policy(mutated, "lane-limits", "quick")
                self.assertEqual(limits.returncode, 3, limits.stdout)
                self.assertIn("POLICY-SCHEMA-004", limits.stderr)
                self.assertEqual(limits.stdout.strip(), "")

    def test_a_ceiling_nobody_reads_is_refused(self):
        # una clave dentro de limits sin lector es una perilla muerta con cara
        # de garantía: el humano cree que puso un techo y ningún gate lo mide
        mutated = self.policy_with({"max_files": 8, "max_lines": 200, "max_bytes": 4096})
        limits = self.run_with_policy(mutated, "lane-limits", "quick")
        self.assertEqual(limits.returncode, 3, limits.stdout)
        self.assertIn("POLICY-SCHEMA-004", limits.stderr)
        self.assertIn("max_bytes", limits.stderr)

    def policy_with(self, limits):
        """El policy renderizado, con OTRO limits en quick, en un archivo propio."""
        data = json.loads(POLICY.read_text())
        data["workflow"]["lanes"]["quick"]["limits"] = limits
        path = Path(self.tmp.name) / "policy-mutado.json"
        path.write_text(json.dumps(data))
        return path

    def run_with_policy(self, policy_path, *args):
        return subprocess.run(
            ["python3", str(SCRIPT), "--policy", str(policy_path), *map(str, args)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    # ── la ENTREGA: un dato que declara la invocación, no una pregunta al final ──
    # Caso de campo: el agente terminaba de implementar y preguntaba en el chat
    # "no commiteé ni shippeé, ¿lo llevo por /review + ship?". La respuesta ya
    # estaba dada cuando se abrió la tarea; lo que faltaba era escribirla donde
    # los gates la puedan leer, y que subirla sea una transición con actor.

    def init_with(self, delivery, task=None):
        task = self.task if task is None else task
        created = self.run_policy("init", task, "--delivery", delivery)
        self.assertEqual(created.returncode, 0, created.stderr)
        return task

    def state_of(self, task):
        return json.loads((Path(task) / "state.json").read_text())

    def test_init_records_the_declared_delivery(self):
        for mode in ("review", "prs", "trunk"):
            with self.subTest(delivery=mode):
                task = Path(self.tmp.name) / f"AUTO-20260728-{mode}"
                created = self.run_policy("init", task, "--delivery", mode)
                self.assertEqual(created.returncode, 0, created.stderr)
                self.assertEqual(self.state_of(task)["delivery"], mode)
                self.assertIn(f"delivery={mode}", created.stdout)

    def test_a_task_without_delivery_keeps_todays_conduct(self):
        # compat: sin campo, ship usa el flow del workspace y nada cambia para
        # las tareas viejas ni para /quick
        self.assertEqual(self.run_policy("init", self.task).returncode, 0)
        self.assertNotIn("delivery", self.state())
        for phase in ("rfc", "implement", "review"):
            self.assertEqual(self.transition(phase).returncode, 0)
        commit = "e" * 40
        ok = self.run_policy("validate-ship", self.task, "--commit", commit,
                             "--verdict", self.valid_verdict(commit))
        self.assertEqual(ok.returncode, 0, ok.stderr)

    def test_init_refuses_an_entrega_nobody_implements(self):
        task = Path(self.tmp.name) / "AUTO-20260728-entrega-rara"
        refused = self.run_policy("init", task, "--delivery", "main")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-DELIVERY-001", refused.stderr)
        for valid in ("review", "prs", "trunk"):
            self.assertIn(valid, refused.stderr)      # el error dice cuáles sirven
        self.assertFalse((task / "state.json").exists())   # sin estado a medias

    def test_delivery_only_promotes_towards_publication(self):
        for origin, target in (("review", "prs"), ("review", "trunk"),
                               ("prs", "trunk")):
            with self.subTest(promocion=f"{origin}->{target}"):
                task = self.init_with(
                    origin, Path(self.tmp.name) / f"AUTO-sube-{origin}-{target}")
                done = self.run_policy("delivery", task, "--to", target,
                                       "--actor", "andres")
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertEqual(self.state_of(task)["delivery"], target)
                mode = self.run_policy("delivery-mode", task)
                self.assertEqual(mode.stdout.strip(), target)

    def test_delivery_never_degrades(self):
        # bajar el campo no despublica una rama, un PR ni un commit en la trunk:
        # solo deja el state.json mintiendo sobre lo que hay afuera
        for origin, target in (("trunk", "prs"), ("trunk", "review"),
                               ("prs", "review"), ("review", "review"),
                               ("prs", "prs")):
            with self.subTest(retroceso=f"{origin}->{target}"):
                task = self.init_with(
                    origin, Path(self.tmp.name) / f"AUTO-baja-{origin}-{target}")
                refused = self.run_policy("delivery", task, "--to", target,
                                          "--actor", "andres")
                self.assertEqual(refused.returncode, 3, refused.stdout)
                self.assertIn("POLICY-DELIVERY-002", refused.stderr)
                self.assertIn("no se despublica", refused.stderr)
                state = self.state_of(task)
                self.assertEqual(state["delivery"], origin)   # el campo, intacto
                self.assertEqual(state["history"], [])        # y sin registro falso

    def test_delivery_to_an_unknown_target_is_typed(self):
        task = self.init_with("review")
        refused = self.run_policy("delivery", task, "--to", "main", "--actor", "andres")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-DELIVERY-001", refused.stderr)
        self.assertIn("prs", refused.stderr)
        self.assertIn("trunk", refused.stderr)

    def test_delivery_refuses_a_task_that_never_declared_one(self):
        # sin peldaño de origen no hay promoción posible: declarar uno ahora
        # podría BAJAR lo que el flow del workspace ya prometía
        self.assertEqual(self.run_policy("init", self.task).returncode, 0)
        refused = self.run_policy("delivery", self.task, "--to", "trunk",
                                  "--actor", "andres")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-DELIVERY-004", refused.stderr)
        self.assertNotIn("delivery", self.state())
        # y hacia review no se promueve NUNCA, declare lo que declare la tarea:
        # review es el peldaño más bajo de la escalera
        down = self.run_policy("delivery", self.task, "--to", "review",
                               "--actor", "andres")
        self.assertEqual(down.returncode, 3)
        self.assertIn("POLICY-DELIVERY-002", down.stderr)
        self.assertNotIn("delivery", self.state())

    def test_the_go_leaves_who_authorised_it_and_why(self):
        task = self.init_with("review")
        done = self.run_policy("delivery", task, "--to", "trunk", "--actor", "andres",
                               "--reason", "el owner lo pidió tras leer el diff")
        self.assertEqual(done.returncode, 0, done.stderr)
        entry = self.state_of(task)["history"][-1]
        self.assertEqual(entry["kind"], "delivery")
        self.assertEqual(entry["delivery"], "review→trunk")
        self.assertEqual(entry["actor"], "andres")
        self.assertEqual(entry["reason"], "el owner lo pidió tras leer el diff")
        self.assertIn("andres", done.stdout)

    def test_the_go_is_visible_in_the_bus_as_a_decision(self):
        # autorizar publicar es gobierno, no telemetría de fase: va al bus como
        # decision, que es lo que el panel enseña
        ws = Path(self.tmp.name)
        task = ws / "tasks" / "AUTO-20260728-entrega-bus"
        task.mkdir(parents=True)
        (ws / "scripts").mkdir(exist_ok=True)
        import shutil as _sh
        _sh.copy(ROOT / "templates/scripts/emit.sh", ws / "scripts/emit.sh")
        self.assertEqual(self.run_policy("init", task, "--delivery", "review").returncode, 0)
        self.assertEqual(self.run_policy("delivery", task, "--to", "prs",
                                         "--actor", "andres").returncode, 0)
        bus = (ws / ".harness/events.jsonl").read_text()
        self.assertIn('"decision"', bus)
        self.assertIn("entrega", bus)
        self.assertIn("prs", bus)

    def test_delivery_mode_answers_in_one_line_and_invents_no_default(self):
        task = self.init_with("prs")
        declared = self.run_policy("delivery-mode", task)
        self.assertEqual(declared.returncode, 0, declared.stderr)
        self.assertEqual(declared.stdout.strip(), "prs")
        # sin campo: la palabra que manda al caller al flow del workspace
        plain = Path(self.tmp.name) / "AUTO-20260728-sin-entrega"
        self.assertEqual(self.run_policy("init", plain).returncode, 0)
        compat = self.run_policy("delivery-mode", plain)
        self.assertEqual(compat.returncode, 0, compat.stderr)
        self.assertEqual(compat.stdout.strip(), "flow")
        # el tercer estado: no poder mirar NO es "flow"
        (plain / "state.json").write_text("{esto no es json")
        broken = self.run_policy("delivery-mode", plain)
        self.assertEqual(broken.returncode, 3, broken.stdout)
        self.assertIn("POLICY-SCHEMA-001", broken.stderr)
        self.assertEqual(broken.stdout.strip(), "")

    def test_an_unreadable_delivery_is_never_read_as_the_workspace_flow(self):
        task = self.init_with("review")
        state = self.state_of(task)
        state["delivery"] = "main"          # state.json editado a mano
        (Path(task) / "state.json").write_text(json.dumps(state))
        mode = self.run_policy("delivery-mode", task)
        self.assertEqual(mode.returncode, 3, mode.stdout)
        self.assertIn("POLICY-DELIVERY-001", mode.stderr)
        self.assertEqual(mode.stdout.strip(), "")

    def test_ship_refuses_a_task_whose_entrega_is_review(self):
        self.init_with("review")
        for phase in ("rfc", "implement", "review"):
            self.assertEqual(self.transition(phase).returncode, 0)
        commit = "f" * 40
        verdict = self.valid_verdict(commit)
        blocked = self.run_policy("validate-ship", self.task, "--commit", commit,
                                  "--verdict", verdict)
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-DELIVERY-003", blocked.stderr)
        self.assertIn(f"delivery tasks/{self.task.name}", blocked.stderr)
        self.assertIn("--to prs|trunk", blocked.stderr)   # el camino exacto
        # el "go", y el MISMO veredicto ya pasa: lo que faltaba era la
        # autorización, no una verificación
        go = self.run_policy("delivery", self.task, "--to", "prs",
                             "--actor", "andres", "--reason", "revisado en vivo")
        self.assertEqual(go.returncode, 0, go.stderr)
        ok = self.run_policy("validate-ship", self.task, "--commit", commit,
                             "--verdict", verdict)
        self.assertEqual(ok.returncode, 0, ok.stderr)

    def test_prs_and_trunk_ship_without_asking_anything(self):
        for mode in ("prs", "trunk"):
            with self.subTest(delivery=mode):
                task = Path(self.tmp.name) / f"AUTO-20260728-ship-{mode}"
                task.mkdir()
                self.assertEqual(self.run_policy("init", task,
                                                 "--delivery", mode).returncode, 0)
                for phase in ("rfc", "implement", "review"):
                    self.assertEqual(self.run_policy(
                        "transition", task, phase, "--actor", "orch").returncode, 0)
                commit = "9" * 40
                verdict = task / "verdict-atlas.json"
                verdict.write_text(json.dumps({
                    "schema": 1, "commit": commit, "verdict": "pass", "qa": "pass",
                    "reviewer": "reviewer-atlas", "implementation_agents": ["agent-a"],
                }))
                ok = self.run_policy("validate-ship", task, "--commit", commit,
                                     "--verdict", verdict)
                self.assertEqual(ok.returncode, 0, ok.stderr)

    def test_a_delivery_entry_neither_forges_nor_masks_a_phase(self):
        # history[] es un control, no prosa: la entrada de entrega NO es un
        # movimiento de fase (si contara, validate-ship acusaría de edición a
        # mano a quien usó el CLI), y tampoco puede tapar una edición de verdad
        self.init_with("review")
        for phase in ("rfc", "implement", "review", "ship"):
            self.assertEqual(self.transition(phase).returncode, 0)
        self.assertEqual(self.run_policy("delivery", self.task, "--to", "trunk",
                                         "--actor", "andres").returncode, 0)
        self.assertEqual(self.state()["phase"], "ship")   # la fase no se movió
        commit = "1" * 40
        verdict = self.valid_verdict(commit)
        state = self.state()
        state["phase"] = "review"          # la edición a mano de siempre
        (self.task / "state.json").write_text(json.dumps(state))
        forged = self.run_policy("validate-ship", self.task, "--commit", commit,
                                 "--verdict", verdict)
        self.assertEqual(forged.returncode, 3)
        self.assertIn("POLICY-STATE-003", forged.stderr)

    def test_a_history_entry_that_is_not_a_movement_still_smells_like_a_hand_edit(self):
        # el salteo de las entradas kind=delivery no puede volverse un colador:
        # lo que NO es un objeto sigue delatando la edición a mano de siempre
        self.reach("rfc", "implement", "review")
        state = self.state()
        state["history"].append("shippeado a mano")
        (self.task / "state.json").write_text(json.dumps(state))
        commit = "2" * 40
        forged = self.run_policy("validate-ship", self.task, "--commit", commit,
                                 "--verdict", self.valid_verdict(commit))
        self.assertEqual(forged.returncode, 3)
        self.assertIn("POLICY-STATE-003", forged.stderr)

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

    # ── DOS TAREAS DEL MISMO REPO NO PUEDEN IR EN PARALELO ────────────────
    # La doctrina decía "aristas solo por conflicto REAL de archivos, jamás por
    # repo, porque cada tarea tiene su worktree". Esa premisa es FALSA:
    # worktree-task.sh crea worktrees/<task-id>/<repo>, o sea UNO por (tarea,
    # repo), y todas las tareas del DAG lo comparten junto con la rama y el
    # index. Caso de campo: dos tareas del mismo repo en vuelo a la vez, y el
    # `git add` amplio de una se llevó SEIS archivos de la otra a su commit.
    def _dag(self, tasks):
        dag = self.task / "dag.json"
        dag.write_text(json.dumps({"schema": 1, "tasks": tasks}))
        return dag

    def test_dag_refuses_two_unordered_tasks_on_the_same_repo(self):
        dag = self._dag([
            {"id": "T3", "repo": "acme", "depends_on": []},
            {"id": "T12", "repo": "acme", "depends_on": []},
        ])
        result = self.run_policy("validate-dag", dag)
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-DAG-010", result.stderr)
        self.assertIn("acme", result.stderr)          # nombra el repo
        self.assertIn("T3", result.stderr)            # y las dos tareas
        self.assertIn("T12", result.stderr)
        self.assertIn("depends_on", result.stderr)    # con la remediación exacta

    def test_dag_accepts_the_same_repo_when_an_edge_orders_them(self):
        # CONTRA-MITAD: cualquiera de los dos órdenes sirve. Sin esto, la regla
        # de arriba pasaría igual con un chequeo que prohíba repetir repo, que
        # sería inservible (una tarea de 3 pasos sobre un repo es lo normal).
        dag = self._dag([
            {"id": "T3", "repo": "acme", "depends_on": []},
            {"id": "T12", "repo": "acme", "depends_on": ["T3"]},
        ])
        self.assertEqual(self.run_policy("validate-dag", dag).returncode, 0)

    def test_dag_accepts_a_transitive_chain_on_the_same_repo(self):
        # El orden puede ser INDIRECTO: T1 → T2 → T3 serializa T1 y T3 aunque
        # no se nombren entre sí. Exigir arista directa forzaría a escribir un
        # DAG completo en vez de una cadena.
        dag = self._dag([
            {"id": "T1", "repo": "acme", "depends_on": []},
            {"id": "T2", "repo": "acme", "depends_on": ["T1"]},
            {"id": "T3", "repo": "acme", "depends_on": ["T2"]},
        ])
        self.assertEqual(self.run_policy("validate-dag", dag).returncode, 0)

    def test_dag_still_allows_parallel_across_different_repos(self):
        # El paralelo entre REPOS distintos es el que da la ganancia de reloj y
        # no toca ningún árbol compartido: intacto.
        dag = self._dag([
            {"id": "T1", "repo": "acme", "depends_on": []},
            {"id": "T2", "repo": "example-org", "depends_on": []},
            {"id": "T3", "repo": "svc-pagos", "depends_on": []},
        ])
        self.assertEqual(self.run_policy("validate-dag", dag).returncode, 0)

    def test_dag_order_applies_the_same_rule(self):
        # dag-order comparte load_dag_nodes con validate-dag a propósito: dos
        # validadores del mismo artefacto es una oportunidad de divergir.
        self.mk_dag_items([
            {"id": "T3", "repo": "acme", "depends_on": []},
            {"id": "T12", "repo": "acme", "depends_on": []},
        ])
        result = self.run_policy("dag-order", self.task)
        self.assertEqual(result.returncode, 3)
        self.assertIn("POLICY-DAG-010", result.stderr)


if __name__ == "__main__":
    unittest.main()
