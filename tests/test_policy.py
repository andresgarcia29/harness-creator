#!/usr/bin/env python3
import datetime as dt
import hashlib
import json
import os
import re
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

    def test_a_repos_entry_is_not_a_phase_move_and_does_not_look_hand_edited(self):
        """Cambiar el ALCANCE no mueve la fase, así que no puede delatar una
        edición a mano. `phase_is_declared` salteaba solo kind=delivery, y una
        entrada kind=repos (que tampoco trae `to`) quedaba de último movimiento:
        el que usaba el CLI para ampliar o recortar el alcance recibía
        POLICY-STATE-003 acusándolo de editar state.json a mano, que es
        exactamente lo que el comando existe para evitar. Peor todavía en el
        caso de --remove, porque ESE es el camino de salida de una tarea trabada:
        destrabarla la volvía a trabar un paso después."""
        self.reach("rfc", "implement", "review")
        commit = "d" * 40
        verdict = self.valid_verdict(commit)
        # --add: el alcance se amplía por CLI, con motivo y actor
        self.assertEqual(self.run_policy(
            "repos", self.task, "--add", "proto", "--actor", "orchestrator",
            "--reason", "el enrichment lo encontró").returncode, 0)
        (self.task / "verdict-proto.json").write_text(json.dumps({
            "schema": 1, "commit": commit, "verdict": "pass", "qa": "pass",
            "reviewer": "rev", "implementation_agents": ["agent-a"],
        }))
        after_add = self.run_policy("validate-ship", self.task, "--commit", commit,
                                    "--verdict", verdict)
        self.assertEqual(after_add.returncode, 0,
                         f"un repos --add no puede leerse como edición a mano: {after_add.stderr}")
        # --remove: y el camino de salida de la tarea trabada, igual. El
        # candidato entra y sale sin producir nada, que es justo el caso real.
        self.assertEqual(self.run_policy(
            "repos", self.task, "--add", "muse", "--actor", "orchestrator",
            "--reason", "candidato del intake").returncode, 0)
        rm = self.run_policy("repos", self.task, "--remove", "muse",
                             "--actor", "orchestrator",
                             "--reason", "el plan lo descartó")
        self.assertEqual(rm.returncode, 0, rm.stderr)
        after_rm = self.run_policy("validate-ship", self.task, "--commit", commit,
                                   "--verdict", verdict)
        self.assertEqual(after_rm.returncode, 0,
                         f"un repos --remove tampoco: {after_rm.stderr}")

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

    def test_archive_sees_a_delta_amended_inside_the_qa_merge_window(self):
        """El mtime lo derrota el propio flujo: fundir el campo `qa` en el
        veredicto es un paso PRESCRITO por /review, o sea una escritura sobre el
        veredicto POSTERIOR al juicio, en toda tarea. Caso de campo con 17
        segundos de ventana: delta editado, veredicto refundido despues, gate en
        verde, y el reviewer habia cerrado antes del texto nuevo.
        Con el hash sellado, la ventana no existe."""
        self.reach_deploy()
        v = self.task / "verdict-atlas.json"
        delta = self.task / "delta-spec.md"
        delta.write_text("## ADDED\n- R1: lo que el reviewer SI vio\n")
        datos = json.loads(v.read_text())
        datos["delta_spec_sha256"] = hashlib.sha256(delta.read_bytes()).hexdigest()
        v.write_text(json.dumps(datos))
        base = 1_800_000_000
        os.utime(v, (base, base)); os.utime(delta, (base - 60, base - 60))
        self.assertEqual(self.transition("archive").returncode, 0,
                         "el delta que el veredicto declara haber visto archiva")

    def test_archive_refuses_a_delta_amended_after_the_sealed_hash(self):
        # La ventana: el delta cambia y DESPUES se refunde el veredicto, asi que
        # su mtime queda por delante. El hash sellado no se mueve.
        self.reach_deploy()
        v = self.task / "verdict-atlas.json"
        delta = self.task / "delta-spec.md"
        delta.write_text("## ADDED\n- R1: lo que el reviewer SI vio\n")
        datos = json.loads(v.read_text())
        datos["delta_spec_sha256"] = hashlib.sha256(delta.read_bytes()).hexdigest()
        v.write_text(json.dumps(datos))
        base = 1_800_000_000
        delta.write_text("## ADDED\n- R1: enmendado despues del juicio\n")
        os.utime(delta, (base + 60, base + 60))
        datos["qa"] = "pass"
        v.write_text(json.dumps(datos))       # la fusion mecanica del campo qa
        os.utime(v, (base + 77, base + 77))
        blocked = self.transition("archive")
        self.assertEqual(blocked.returncode, 3, blocked.stderr)
        self.assertIn("POLICY-ARCHIVE-001", blocked.stderr)
        self.assertIn("hash", blocked.stderr)

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
        "  - name: proto\n    kind: service\n    agent: svc\n"
        "  - name: muse\n    kind: service\n    agent: svc\n"
    )

    def ws_task(self, manifest=MANIFEST):
        ws = Path(self.tmp.name)
        task = ws / "tasks" / "AUTO-20260727-lane-kind"
        task.mkdir(parents=True)
        if manifest is not None:
            (ws / "manifest.yaml").write_text(manifest)
        return task

    def test_express_with_infra_repo_warns_and_proceeds(self):
        """#71: LANE-004 avisa, no rechaza.

        Rechazaba por el KIND del repo, antes de que existiera un diff, cuando
        el gate que decia anticipar (gate_lane) decide por las RUTAS QUE EL DIFF
        TOCA. Medido: 20 de 31 repos del workspace son infra-* porque llevan su
        terraform/ al lado del codigo, asi que un .gitignore de dos lineas no
        tenia ningun carril rapido."""
        task = self.ws_task()
        r = self.run_policy("init", task, "--lane", "express",
                            "--repos", "terraform-core")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("POLICY-LANE-004", r.stderr)    # sigue siendo grepeable
        self.assertIn("aviso", r.stderr)
        self.assertIn("terraform-core", r.stderr)
        self.assertIn("gate_lane", r.stderr)          # nombra a quien SI lo verifica
        self.assertTrue((task / "state.json").exists())
        self.assertEqual(self.state_of(task)["repos"], ["terraform-core"])

    def test_lane_005_is_still_a_hard_refusal(self):
        """#71 relajo LANE-004, no LANE-005.

        Que quick sea de UN repo es una promesa ESTRUCTURAL (quick no genera
        DAG, o sea que nada ordena el ship entre repos) y ningun diff la
        arregla. Si este test se pone rojo, el aviso se comio de mas."""
        task = self.ws_task()
        r = self.run_policy("init", task, "--lane", "quick",
                            "--repos", "atlas,muse")
        self.assertEqual(r.returncode, 3)
        self.assertIn("POLICY-LANE-005", r.stderr)
        self.assertFalse((task / "state.json").exists())

    def test_infra_warning_points_at_the_gate_that_decides(self):
        """El aviso tiene que decir QUIEN verifica de verdad y CON QUE criterio.

        Si solo dijera "ojo, infra", el agente no sabria si seguir; nombrando a
        gate_lane y el criterio (lo que el diff TOCA) la decision es tomable.

        Va sobre express: en quick el mismo caso es rechazo duro desde que
        /smart clasifica ese carril solo (ver el test de abajo)."""
        task = self.ws_task()
        r = self.run_policy("init", task, "--lane", "express", "--repos", "net-live")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("gate_lane", r.stderr)
        self.assertIn("precheck", r.stderr)
        self.assertIn("TOCA", r.stderr)

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

    # ── REPOS --add: ampliar el alcance de una tarea YA iniciada ──────────
    # Caso de campo: el enrichment descubrió con evidencia que el bug vivía
    # también en otros dos repos. worktree-task.sh los aceptó sin chistar pero
    # state.repos quedó con tres de cinco, y en los carriles sin dag.json
    # repos_missing_verdict solo lee state.repos: el repo nuevo desaparecía del
    # conteo y la fase avanzaba a ship sin su veredicto. init no se re-corre
    # (POLICY-STATE-001) y editar state.json a mano está prohibido.

    def add_repos(self, task, add, reason="el enrichment lo encontró en proto"):
        return self.run_policy("repos", task, "--add", add,
                               "--actor", "orchestrator", "--reason", reason)

    def move(self, task, phase):
        return self.run_policy("transition", task, phase, "--actor", "orchestrator")

    def test_repos_add_widens_a_started_task_and_leaves_history(self):
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        added = self.add_repos(task, "proto")
        self.assertEqual(added.returncode, 0, added.stderr)
        state = self.state_of(task)
        self.assertEqual(state["repos"], ["atlas", "proto"])
        self.assertEqual(state["history"][-1]["kind"], "repos")
        self.assertEqual(state["history"][-1]["added"], ["proto"])
        self.assertIn("enrichment", state["history"][-1]["reason"])

    def test_repos_add_of_something_already_declared_changes_nothing(self):
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        again = self.add_repos(task, "atlas")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas"])
        self.assertEqual(self.state_of(task)["history"], [])

    def test_repos_add_cannot_smuggle_a_second_repo_into_quick(self):
        # la misma promesa que init cobra, cobrada también por la puerta nueva
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "quick",
                                         "--repos", "atlas").returncode, 0)
        refused = self.add_repos(task, "proto")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-LANE-005", refused.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas"])   # sin cambios

    def test_repos_add_of_infra_into_express_warns(self):
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        avisado = self.add_repos(task, "terraform-core")
        self.assertEqual(avisado.returncode, 0, avisado.stderr)
        self.assertIn("POLICY-LANE-004", avisado.stderr)
        self.assertIn("terraform-core", avisado.stderr)
        # #71: el repo SI entra; quien decide es gate_lane, sobre el diff
        self.assertEqual(self.state_of(task)["repos"], ["atlas", "terraform-core"])

    def test_repos_add_without_a_reason_is_an_edit_by_hand(self):
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        empty = self.add_repos(task, "proto", reason="  ")
        self.assertEqual(empty.returncode, 3)
        self.assertIn("POLICY-REPOS-001", empty.stderr)

    def test_repos_add_is_refused_once_the_task_reached_ship(self):
        # un repo agregado en ship nace sin review posible: desde ship el grafo
        # solo va a deploy, así que su veredicto no tendría dónde ocurrir
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        for phase in ("implement", "review"):
            self.assertEqual(self.move(task, phase).returncode, 0)
        (task / "verdict-atlas.json").write_text(json.dumps({
            "schema": 1, "verdict": "pass", "qa": "pass", "reviewer": "rev",
            "implementation_agents": ["impl"],
        }))
        with (task / "ship.log").open("a") as log:
            log.write(json.dumps({"repo": "atlas", "sha": "abc1234"}) + "\n")
        self.assertEqual(self.move(task, "ship").returncode, 0)
        late = self.add_repos(task, "proto")
        self.assertEqual(late.returncode, 3)
        self.assertIn("POLICY-REPOS-002", late.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas"])

    def test_repos_add_closes_the_fail_open_toward_ship(self):
        """El cierre del agujero: sin dag.json, repos_missing_verdict lee
        state.repos. Si el repo nuevo no está ahí, la fase avanza a ship sin su
        veredicto (eso era el bug). Registrado con --add, SHIP-004 lo nombra."""
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        self.assertEqual(self.add_repos(task, "proto").returncode, 0)
        for phase in ("implement", "review"):
            self.assertEqual(self.move(task, phase).returncode, 0)
        (task / "verdict-atlas.json").write_text(json.dumps({
            "schema": 1, "verdict": "pass", "qa": "pass", "reviewer": "rev",
            "implementation_agents": ["impl"],
        }))
        with (task / "ship.log").open("a") as log:
            log.write(json.dumps({"repo": "atlas", "sha": "abc1234"}) + "\n")
        blocked = self.move(task, "ship")
        self.assertEqual(blocked.returncode, 3)
        self.assertIn("POLICY-SHIP-004", blocked.stderr)
        self.assertIn("proto", blocked.stderr)
        self.assertEqual(self.state_of(task)["phase"], "review")   # no se movió

    # ── REPOS --add contra manifest.yaml (issue #62) ──────────────────────
    # Caso de campo: `--add reponoexiste` se aceptó y quedó en state.repos,
    # pero worktree-task.sh lo rechazaba ("repo desconocido", contra el clon
    # que manifest.yaml manda tener): el veredicto que POLICY-SHIP-004 exige
    # era imposible de producir y la tarea quedó trabada en review → ship.

    def test_repos_add_refuses_a_repo_that_is_not_in_the_manifest(self):
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        refused = self.add_repos(task, "reponoexiste")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-REPOS-008", refused.stderr)
        self.assertIn("reponoexiste", refused.stderr)
        self.assertIn("manifest.yaml", refused.stderr)   # dónde declararlo
        self.assertEqual(self.state_of(task)["repos"], ["atlas"])   # sin cambios

    def test_repos_add_of_a_manifest_repo_still_works(self):
        # El freno es para el repo que NO existe, no para ampliar el alcance:
        # un repo declarado en manifest.yaml entra igual que antes.
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        added = self.add_repos(task, "proto")
        self.assertEqual(added.returncode, 0, added.stderr)
        self.assertNotIn("POLICY-REPOS-008", added.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas", "proto"])

    def test_repos_add_without_manifest_degrades_with_a_warning(self):
        # Decisión documentada en cmd_repos: sin manifest no hay contra qué
        # validar y se degrada (fail-open con aviso, como vet_repos_for_lane);
        # el backstop es worktree-task.sh, que rechaza el repo no clonado.
        task = self.ws_task(manifest=None)
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        added = self.add_repos(task, "reponoexiste")
        self.assertEqual(added.returncode, 0, added.stderr)
        self.assertIn("--add NO se validó", added.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas", "reponoexiste"])

    # ── REPOS --remove: el candidato que el plan descartó (issue #61) ─────
    # Caso de campo: init recibe los repos CANDIDATOS del intake y el patrón
    # verificar-antes-de-planear descarta la mayoría (48 de 51 medidos). Los
    # descartados no tienen nada que implementar ni shippear, así que nunca
    # tienen commits, y review → ship exige que TODOS shippeen: la tarea quedaba
    # trabada en review con el código ya en main y desplegado verde. La única
    # salida era editar state.json a mano, prohibido por AGENTS.md. O sea que el
    # harness recomendaba un patrón y castigaba a quien lo seguía.

    def rm_repos(self, task, remove, reason="el plan verificó y lo descartó"):
        return self.run_policy("repos", task, "--remove", remove,
                               "--actor", "orchestrator", "--reason", reason)

    def test_repos_remove_frees_a_task_stuck_by_a_discarded_candidate(self):
        """El issue completo, de punta a punta: dos candidatos, el plan usa uno,
        y la tarea llega a ship sin editar state.json a mano."""
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas,proto").returncode, 0)
        for phase in ("implement", "review"):
            self.assertEqual(self.move(task, phase).returncode, 0)
        (task / "verdict-atlas.json").write_text(json.dumps({
            "schema": 1, "verdict": "pass", "qa": "pass", "reviewer": "rev",
            "implementation_agents": ["impl"],
        }))
        with (task / "ship.log").open("a") as log:
            log.write(json.dumps({"repo": "atlas", "sha": "abc1234"}) + "\n")
        # ANTES del remove: trabada, y el gate nombra al candidato descartado
        stuck = self.move(task, "ship")
        self.assertEqual(stuck.returncode, 3)
        self.assertIn("POLICY-SHIP-004", stuck.stderr)
        self.assertIn("proto", stuck.stderr)
        # el remove registrado la destraba
        gone = self.rm_repos(task, "proto")
        self.assertEqual(gone.returncode, 0, gone.stderr)
        state = self.state_of(task)
        self.assertEqual(state["repos"], ["atlas"])
        self.assertEqual(state["history"][-1]["removed"], ["proto"])
        self.assertNotIn("added", state["history"][-1])
        self.assertIn("descartó", state["history"][-1]["reason"])
        self.assertEqual(self.move(task, "ship").returncode, 0)

    def test_repos_remove_refuses_a_repo_with_a_sealed_verdict(self):
        # ese repo se revisó: sacarlo del alcance borraría la prueba
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas,proto").returncode, 0)
        (task / "verdict-proto.json").write_text(json.dumps({
            "schema": 1, "verdict": "pass", "qa": "pass", "reviewer": "rev",
            "implementation_agents": ["impl"],
        }))
        refused = self.rm_repos(task, "proto")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-REPOS-005", refused.stderr)
        self.assertIn("verdict-proto.json", refused.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas", "proto"])

    def test_repos_remove_refuses_a_repo_that_already_shipped(self):
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas,proto").returncode, 0)
        with (task / "ship.log").open("a") as log:
            log.write(json.dumps({"repo": "proto", "sha": "abc1234"}) + "\n")
        refused = self.rm_repos(task, "proto")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-REPOS-005", refused.stderr)
        self.assertIn("ship.log", refused.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas", "proto"])

    def test_repos_remove_refuses_what_the_dag_still_declares(self):
        """Sacarlo solo de state.repos no destraba nada: repos_missing_verdict
        lee las dos fuentes en unión. Fallar acá evita el falso alivio."""
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "full",
                                         "--repos", "atlas,proto").returncode, 0)
        (task / "dag.json").write_text(json.dumps({
            "schema": 1,
            "tasks": [{"id": "T1", "repo": "atlas", "deps": []},
                      {"id": "T2", "repo": "proto", "deps": []}],
        }))
        refused = self.rm_repos(task, "proto")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-REPOS-006", refused.stderr)
        self.assertIn("dag.json", refused.stderr)
        self.assertIn("validate-dag", refused.stderr)   # remediación ejecutable
        self.assertEqual(self.state_of(task)["repos"], ["atlas", "proto"])

    def test_repos_remove_cannot_empty_the_task(self):
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        refused = self.rm_repos(task, "atlas")
        self.assertEqual(refused.returncode, 3)
        self.assertIn("POLICY-REPOS-007", refused.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas"])

    def test_repos_remove_without_a_reason_is_an_edit_by_hand(self):
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas,proto").returncode, 0)
        empty = self.rm_repos(task, "proto", reason="   ")
        self.assertEqual(empty.returncode, 3)
        self.assertIn("POLICY-REPOS-001", empty.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas", "proto"])

    def test_repos_remove_of_something_never_declared_changes_nothing(self):
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        noop = self.rm_repos(task, "muse")
        self.assertEqual(noop.returncode, 0, noop.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas"])
        self.assertEqual(self.state_of(task)["history"], [])

    def test_repos_without_add_or_remove_is_refused(self):
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        naked = self.run_policy("repos", task, "--actor", "orchestrator",
                                "--reason", "porque si")
        self.assertEqual(naked.returncode, 3)
        self.assertIn("POLICY-REPOS-004", naked.stderr)

    def test_repos_add_and_remove_in_one_call_swap_the_scope(self):
        # el plan cambió un candidato por otro: es UNA decisión, un registro
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "full",
                                         "--repos", "atlas,proto").returncode, 0)
        swap = self.run_policy("repos", task, "--add", "muse",
                               "--remove", "proto", "--actor", "orchestrator",
                               "--reason", "el plan cambió proto por muse")
        self.assertEqual(swap.returncode, 0, swap.stderr)
        state = self.state_of(task)
        self.assertEqual(state["repos"], ["atlas", "muse"])
        self.assertEqual(state["history"][-1]["added"], ["muse"])
        self.assertEqual(state["history"][-1]["removed"], ["proto"])

    def test_repos_remove_is_refused_once_the_task_reached_ship(self):
        # ahí review → ship ya pasó: quitar no destraba nada y borra historia
        task = self.ws_task()
        self.assertEqual(self.run_policy("init", task, "--lane", "express",
                                         "--repos", "atlas,proto").returncode, 0)
        for phase in ("implement", "review"):
            self.assertEqual(self.move(task, phase).returncode, 0)
        for repo in ("atlas", "proto"):
            (task / f"verdict-{repo}.json").write_text(json.dumps({
                "schema": 1, "verdict": "pass", "qa": "pass", "reviewer": "rev",
                "implementation_agents": ["impl"],
            }))
            with (task / "ship.log").open("a") as log:
                log.write(json.dumps({"repo": repo, "sha": "abc1234"}) + "\n")
        self.assertEqual(self.move(task, "ship").returncode, 0)
        late = self.rm_repos(task, "proto")
        self.assertEqual(late.returncode, 3)
        self.assertIn("POLICY-REPOS-002", late.stderr)
        self.assertEqual(self.state_of(task)["repos"], ["atlas", "proto"])

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

    def test_second_repo_can_register_its_review_entry(self):
        """La fase es GLOBAL y el review es POR REPO: en cuanto el primer repo
        entraba a review, el segundo chocaba con POLICY-TRANSITION-001 y su
        entrada nunca se registraba. Caso de campo: tarea de cinco repos que
        terminó con rondas contadas para dos, o sea tres repos revisados sin
        que el presupuesto los gobernara."""
        self.reach("rfc", "implement")
        self.assertEqual(self.transition_repo("review", "atlas").returncode, 0)
        segundo = self.transition_repo("review", "proto")
        self.assertEqual(segundo.returncode, 0, segundo.stderr)
        state = self.state()
        self.assertEqual(state["review_rounds_by_repo"]["atlas"], 1)
        self.assertEqual(state["review_rounds_by_repo"]["proto"], 1)

    def test_self_transition_still_needs_a_repo_and_still_has_a_ceiling(self):
        """Las dos contra-mitades: sin --repo la auto-transición sigue
        prohibida (sería una ronda anónima que ningún presupuesto cobra), y con
        --repo el techo por repo se sigue cobrando igual."""
        self.reach("rfc", "implement")
        self.assertEqual(self.transition_repo("review", "atlas").returncode, 0)
        anonima = self.transition("review")
        self.assertEqual(anonima.returncode, 3)
        self.assertIn("POLICY-TRANSITION-001", anonima.stderr)
        self.assertIn("--repo", anonima.stderr)
        for _ in range(2):
            self.assertEqual(self.transition_repo("review", "atlas").returncode, 0)
        techo = self.transition_repo("review", "atlas")
        self.assertEqual(techo.returncode, 3)
        self.assertIn("POLICY-LIMIT-001", techo.stderr)

    # ── LIMIT-001: el techo mira CONVERGENCIA, no solo el conteo ──────────
    # Caso de campo: una tarea bajó 4 → 2 → 1 → 0 bloqueantes y el techo de 3
    # rondas la paró con el trabajo terminado; hubo que despertar a un humano
    # de madrugada. Rondas de más no siempre son "no converge": también son un
    # reviewer que hace bien su trabajo.

    def mk_blocking(self, repo, count):
        """Deja el veredicto del repo con `count` bloqueantes: es la SEÑAL que
        el techo lee para decidir si la ronda extra se concede."""
        (self.task / f"verdict-{repo}.json").write_text(json.dumps({
            "schema": 1, "verdict": "changes_requested", "qa": "pass",
            "reviewer": "rev", "implementation_agents": ["impl"],
            "blocking": [f"b{i}" for i in range(count)],
        }))

    def review_round(self, repo, blocking_now):
        """Una ronda: se declara el veredicto que dejó la ronda ANTERIOR y se
        pide la entrada a review. El motor lee ese archivo, no la conversación."""
        self.mk_blocking(repo, blocking_now)
        return self.transition_repo("review", repo)

    def test_extra_round_is_granted_while_blocking_keeps_dropping(self):
        self.reach("rfc", "implement")
        self.assertEqual(self.transition_repo("review", "atlas").returncode, 0)
        for count in (4, 2):
            self.assertEqual(self.review_round("atlas", count).returncode, 0)
        cuarta = self.review_round("atlas", 1)      # ronda 4, sobre el techo de 3
        self.assertEqual(cuarta.returncode, 0, cuarta.stderr)
        self.assertIn("convergencia", cuarta.stdout)
        self.assertEqual(self.state()["review_rounds_by_repo"]["atlas"], 4)

    def test_extra_round_is_refused_when_blocking_does_not_drop(self):
        self.reach("rfc", "implement")
        self.assertEqual(self.transition_repo("review", "atlas").returncode, 0)
        for count in (2, 2):
            self.assertEqual(self.review_round("atlas", count).returncode, 0)
        cuarta = self.review_round("atlas", 2)
        self.assertEqual(cuarta.returncode, 3)
        self.assertIn("POLICY-LIMIT-001", cuarta.stderr)
        self.assertIn("NO bajó bloqueantes", cuarta.stderr)
        self.assertIn("2 → 2", cuarta.stderr)       # la serie que lo justifica, a la vista
        # la ronda rechazada NO se cobra: el estado quedó en la tercera
        self.assertEqual(self.state()["review_rounds_by_repo"]["atlas"], 3)

    def test_hard_ceiling_stops_a_converging_repo_at_twice_the_maximum(self):
        # Bajar de a uno desde cincuenta también "converge": el techo duro
        # (2× el máximo) existe para que la convergencia no sea barra libre.
        self.reach("rfc", "implement")
        self.assertEqual(self.transition_repo("review", "atlas").returncode, 0)
        for count in (6, 5, 4, 3, 2):               # rondas 2..6, bajada estricta
            paso = self.review_round("atlas", count)
            self.assertEqual(paso.returncode, 0, paso.stderr)
        septima = self.review_round("atlas", 1)     # ronda 7 > 2*3
        self.assertEqual(septima.returncode, 3)
        self.assertIn("POLICY-LIMIT-001", septima.stderr)
        self.assertIn("techo duro", septima.stderr)

    def test_ceiling_is_identical_to_before_without_readable_verdicts(self):
        # La contra-mitad del arreglo: sin serie de bloqueantes legible no hay
        # convergencia que invocar y el corte tiene que ser el de siempre.
        self.reach("rfc", "implement")
        for _ in range(3):
            self.assertEqual(self.transition_repo("review", "atlas").returncode, 0)
        cuarta = self.transition_repo("review", "atlas")
        self.assertEqual(cuarta.returncode, 3)
        self.assertIn("POLICY-LIMIT-001", cuarta.stderr)
        self.assertNotIn("convergencia", cuarta.stdout)

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

    def test_dag_nodes_emits_id_repo_and_depends_on(self):
        # El contrato de las TRES columnas lo consumen dos scripts: dag-coalesce.sh
        # toma $1 (el orden del cherry-pick) y worktree-task.sh --node toma $3 para
        # decidir de dónde nace la rama del nodo (#162). Sin la tercera columna ese
        # script leería dag.json por su cuenta, que es el segundo lector del mismo
        # artefacto que load_dag_nodes existe para evitar.
        self.mk_dag_items([
            {"id": "T1", "repo": "atlas", "depends_on": []},
            {"id": "T2", "repo": "proto", "depends_on": []},
            {"id": "T3", "repo": "atlas", "depends_on": ["T2", "T1"]},
        ])
        result = self.run_policy("dag-nodes", self.task)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split("\t") for line in result.stdout.splitlines() if line]
        self.assertEqual(rows[-1], ["T3", "atlas", "T2,T1"])
        # Y el nodo sin aristas trae la columna VACÍA, no ausente: el consumidor
        # parte por TAB y una fila de dos campos le correría el índice.
        self.assertIn(["T1", "atlas", ""], rows)
        # T3 después de sus dos dependencias: el orden sigue siendo topológico.
        ids = [row[0] for row in rows]
        self.assertLess(ids.index("T1"), ids.index("T3"))
        self.assertLess(ids.index("T2"), ids.index("T3"))

    def test_dag_nodes_repo_filter_keeps_deps_of_other_repos(self):
        # Con --repo se filtran las FILAS, no las aristas: T3 sigue declarando su
        # dependencia de proto aunque la fila de proto no salga. worktree-task.sh
        # necesita justamente eso para saber que esa dependencia NO vive en su
        # repo y que por lo tanto no hay nada que heredar en este árbol.
        self.mk_dag_items([
            {"id": "T1", "repo": "atlas", "depends_on": []},
            {"id": "T2", "repo": "proto", "depends_on": []},
            {"id": "T3", "repo": "atlas", "depends_on": ["T2", "T1"]},
        ])
        result = self.run_policy("dag-nodes", self.task, "--repo", "atlas")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split("\t") for line in result.stdout.splitlines() if line]
        self.assertEqual([row[0] for row in rows], ["T1", "T3"])
        self.assertEqual(rows[-1][2], "T2,T1")

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

    def test_quick_con_repo_de_infra_es_rechazo_duro(self):
        """#71 lo bajó a aviso con razón; el router lo devuelve a rechazo.

        Lo que cambió no es el criterio de infra, es QUIÉN elige el carril.
        quick dejó de ser una promesa que solo el humano podía hacer: /smart lo
        clasifica solo. Un carril que una máquina elige, y encima el más corto
        de la escalera, necesita un piso que no dependa de que la máquina haya
        juzgado bien, porque el backstop (gate_lane) recién mira el diff en el
        precheck, después de que el implementer trabajó.

        express y triado siguen AVISANDO: ésos no los clasifica el router
        solo."""
        task = self.ws_task()
        r = self.run_policy("init", task, "--lane", "quick", "--repos", "net-live")
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("POLICY-LANE-004", r.stderr)
        self.assertIn("net-live", r.stderr)
        self.assertIn("express", r.stderr)          # la remediación nombra el carril
        self.assertFalse((task / "state.json").exists())   # sin estado a medias

    def test_express_con_repo_de_infra_sigue_pasando_con_aviso(self):
        # El otro lado del cambio de arriba: endurecer quick no puede
        # reintroducir el bug de #71, que dejaba un cambio de dos líneas en un
        # repo con terraform al lado sin ningún carril rápido (20 de 31 repos
        # del workspace son infra-* por eso).
        task = self.ws_task()
        r = self.run_policy("init", task, "--lane", "express", "--repos", "net-live")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("POLICY-LANE-004", r.stderr)
        self.assertTrue((task / "state.json").exists())

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

    # ── #74: escalar daba vuelta la entrega EN SILENCIO ──────────────
    # quick NO declara delivery a proposito (su ship publica con el flow del
    # workspace). Pero cuando gate_lane o LANE-004 lo rebotan, la remediacion
    # que el harness PRESCRIBE es escalate y seguir por /smart, y /smart declara
    # en su encabezado, sin condicion, que registra delivery: review, o sea que
    # NO PUBLICA NADA. Caso de campo: cinco fixes de una linea, pipeline
    # completo con RFC, 5 implementers, 4 reviewers, QA, cuatro veredictos pass,
    # y CERO commits publicados. Nada en el camino aviso.
    def _ws_with_flow(self, flow):
        ws = Path(self.tmp.name)
        if flow is not None:
            (ws / "harness-answers.yaml").write_text(
                "project: t\nflow: %s\ntickets: linear\n" % flow)
        task = ws / "tasks" / "AUTO-20260804-delivery"
        task.mkdir(parents=True)
        return task

    def _escalate(self, task, to="express"):
        return self.run_policy("escalate", task, "--to", to, "--actor", "orch",
                               "--reason", "gate_lane lo reboto")

    def test_escalate_materializes_delivery_from_workspace_flow(self):
        task = self._ws_with_flow("prs")
        self.assertEqual(self.run_policy("init", task, "--lane", "quick",
                                         "--repos", "atlas").returncode, 0)
        self.assertEqual(self.run_policy("transition", task, "implement",
                                         "--actor", "orch").returncode, 0)
        up = self._escalate(task)
        self.assertEqual(up.returncode, 0, up.stderr)
        state = json.loads((task / "state.json").read_text())
        self.assertEqual(state["delivery"], "prs")
        self.assertIn("materializada", up.stdout)
        self.assertTrue(any(h.get("kind") == "delivery" for h in state["history"]),
                        "la materializacion tiene que quedar en el history")

    def test_escalate_translates_a_trunk_flavoured_flow(self):
        # `flow` y `delivery` NO son el mismo vocabulario: trunk-merge-commit no
        # es un delivery valido, y copiarlo crudo moriria tipado despues.
        task = self._ws_with_flow("trunk-merge-commit")
        self.assertEqual(self.run_policy("init", task, "--lane", "quick",
                                         "--repos", "atlas").returncode, 0)
        self.assertEqual(self._escalate(task).returncode, 0)
        self.assertEqual(json.loads((task / "state.json").read_text())["delivery"], "trunk")

    def test_escalate_keeps_a_delivery_that_was_declared(self):
        task = self._ws_with_flow("trunk")
        self.assertEqual(self.run_policy("init", task, "--lane", "quick",
                                         "--repos", "atlas",
                                         "--delivery", "review").returncode, 0)
        up = self._escalate(task)
        self.assertEqual(up.returncode, 0, up.stderr)
        self.assertEqual(json.loads((task / "state.json").read_text())["delivery"], "review")
        self.assertNotIn("materializada", up.stdout)

    def test_escalate_without_readable_flow_leaves_delivery_absent(self):
        # No se inventa: sin answers legible queda ausente y manda el flow
        # vigente al shippear, que es la conducta de siempre. Pero se DICE.
        task = self._ws_with_flow(None)
        self.assertEqual(self.run_policy("init", task, "--lane", "quick",
                                         "--repos", "atlas").returncode, 0)
        up = self._escalate(task)
        self.assertEqual(up.returncode, 0, up.stderr)
        self.assertNotIn("delivery", json.loads((task / "state.json").read_text()))
        self.assertIn("no pude leer el flow", up.stderr)

    def test_escalate_does_not_materialize_a_flow_ship_refuses(self):
        # trunk-staging lo RECHAZA ship.sh (no lo implementa): traducirlo a
        # trunk prometeria una publicacion que no va a ocurrir.
        task = self._ws_with_flow("trunk-staging")
        self.assertEqual(self.run_policy("init", task, "--lane", "quick",
                                         "--repos", "atlas").returncode, 0)
        self.assertEqual(self._escalate(task).returncode, 0)
        self.assertNotIn("delivery", json.loads((task / "state.json").read_text()))

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


class CostGateTest(unittest.TestCase):
    """POLICY-BUDGET-003: el gasto frena la transicion, medido y solo.

    POR QUE ESTA SUITE: POLICY-BUDGET-002 ya existia y no frenaba nada porque
    dependia de que alguien corriera `record-cost`, que no tiene una sola
    llamada desde codigo. Un techo que depende de la memoria del modelo es
    prosa. Estos tests existen para que este no vuelva a serlo: fabrican
    transcripts reales y comprueban que el gate MUERDE y que falla ABIERTO
    cuando no hay nada que medir.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ws = (Path(self.tmp.name) / "ws").resolve()
        self.task = self.ws / "tasks" / "AUTO-20260805-cost-gate"
        self.task.mkdir(parents=True)
        # El puente sid -> tarea que escribe track-read.sh
        self.sid = "11111111-2222-3333-4444-555555555555"
        st = self.ws / ".harness" / "session-task"
        st.mkdir(parents=True)
        (st / self.sid).write_text(self.task.name + "\n")
        # Un CLAUDE_CONFIG_DIR propio: nunca tocamos los transcripts reales.
        self.cfg = Path(self.tmp.name) / "cfg"
        # El slug es el que calcula find_project_dir: no-alfanumerico -> "-".
        slug = re.sub(r"[^a-zA-Z0-9]", "-", str(self.ws))
        self.proj = self.cfg / "projects" / slug
        self.proj.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def ahora(self):
        """El instante en que corre el test, con el formato de un transcript."""
        return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

    def write_subagent(self, rol, turns, cache_read, cache_write):
        """El transcript de un SUBAGENTE, que el medidor lee de
        `<sid>/subagents/agent-*.jsonl` y cuyo rol sale del `.meta.json` de al
        lado. Hace falta para probar que la exencion de COST-CTX es del
        ORQUESTADOR y de nadie mas."""
        d = self.proj / self.sid / "subagents"
        d.mkdir(parents=True, exist_ok=True)
        (d / "agent-1.meta.json").write_text(json.dumps({"agentType": rol}))
        stamp = self.ahora()
        lines = []
        for _ in range(turns):
            lines.append(json.dumps({
                "type": "assistant",
                # La ruta de la tarea, que es de donde sale la atribucion.
                "cwd": str(self.ws / "worktrees" / self.task.name / "atlas"),
                "timestamp": stamp,
                "message": {
                    "role": "assistant", "model": "claude-opus-5",
                    "usage": {"input_tokens": 0,
                              "cache_read_input_tokens": cache_read,
                              "cache_creation_input_tokens": cache_write,
                              "output_tokens": 500},
                    "content": [{"type": "tool_use", "id": "t", "name": "Bash",
                                 "input": {}}],
                },
            }))
        (d / "agent-1.jsonl").write_text("\n".join(lines) + "\n")

    def write_transcript(self, turns, cache_read, cache_write, ctx_extra=0,
                         ts=None):
        """Un transcript minimo con el usage que el medidor lee.

        Los turnos se estampan AHORA por default, que es lo que pasa en campo:
        el agente corre DURANTE la fase. Las bandas de tasa (COST-CACHE y
        COST-CTX) miden la fase en curso desde `phase_since`, asi que una fecha
        fija del pasado simula al agente de una fase ANTERIOR, y para eso esta
        el parametro `ts` explicito (issue #95).
        """
        stamp = ts or self.ahora()
        lines = []
        for _ in range(turns):
            lines.append(json.dumps({
                "type": "assistant",
                "cwd": str(self.ws),
                "timestamp": stamp,
                "message": {
                    "role": "assistant",
                    "model": "claude-opus-5",
                    "usage": {
                        "input_tokens": ctx_extra,
                        "cache_read_input_tokens": cache_read,
                        "cache_creation_input_tokens": cache_write,
                        "output_tokens": 500,
                    },
                    "content": [{"type": "tool_use", "id": "t", "name": "Bash",
                                 "input": {}}],
                },
            }))
        (self.proj / f"{self.sid}.jsonl").write_text("\n".join(lines) + "\n")

    def transition(self, phase, sin_relevo=False):
        """`sin_relevo=True` apaga el vigilante, que es la configuracion donde
        la SESION CONTINUA con su contexto: nadie va a levantar una nueva. Es la
        condicion bajo la que COST-CTX del orquestador tiene que seguir
        frenando, y por eso los tests que prueban el freno la piden explicita en
        vez de heredarla del entorno."""
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(self.cfg)
        env["HARNESS_WS"] = str(self.ws)
        if sin_relevo:
            env["HARNESS_ORCH_OFF"] = "1"
        else:
            env.pop("HARNESS_ORCH_OFF", None)
        return subprocess.run(
            ["python3", str(SCRIPT), "--policy", str(POLICY),
             "transition", str(self.task), phase, "--actor", "orchestrator"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, env=env,
        )

    def init(self, budget=None):
        args = ["python3", str(SCRIPT), "--policy", str(POLICY), "init",
                str(self.task), "--lane", "express", "--repos", "atlas",
                "--delivery", "review"]
        if budget is not None:
            args += ["--budget-usd", str(budget)]
        return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False)

    def test_cache_rota_frena_la_transicion(self):
        # La firma medida en campo: mas escritura que lectura. La peor sesion
        # real tuvo 23% de acierto y dejo $1472 en reescrituras.
        self.assertEqual(self.init().returncode, 0)
        self.write_transcript(turns=40, cache_read=20_000, cache_write=200_000)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("POLICY-BUDGET-005", r.stderr)
        self.assertIn("COST-CACHE", r.stderr)

    def test_contexto_desbocado_frena_cuando_la_sesion_CONTINUA(self):
        # El termino sigue frenando donde su remediacion existe: con el relevo
        # desarmado, quien sigue trabajando es la MISMA sesion con el MISMO
        # contexto, asi que dejarla pasar seria el falso verde de siempre.
        self.assertEqual(self.init().returncode, 0)
        # Caché sana, pero arrastra 400k de contexto: el otro modo de fuga.
        self.write_transcript(turns=40, cache_read=400_000, cache_write=1_000)
        r = self.transition("implement", sin_relevo=True)
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("COST-CTX", r.stderr)

    def test_contexto_desbocado_NO_frena_una_transicion_que_RELEVA(self):
        """ISSUE #180: la cura estaba detras del sintoma.

        Esta transicion ES la remediacion del contexto: escribe el marcador de
        relevo, el orquestador cierra su turno y el vigilante levanta una sesion
        NUEVA con contexto limpio. COST-CTX la frenaba para exigir un perdon por
        el contexto que la transicion esta por tirar, y el perdon se concedia
        siempre (la tarea esta verde y la plata ya se gasto). Medido en campo:
        tareas con CUATRO cost-waives del mismo termino, uno por fase, y un
        reporte con la tarea entera en verde y sin camino ejecutable."""
        self.assertEqual(self.init().returncode, 0)
        self.write_transcript(turns=40, cache_read=400_000, cache_write=1_000)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # NO se calla: un termino que deja de frenar y deja de verse es el
        # silencio que todo este gate existe para no tener.
        self.assertIn("COST-CTX", r.stdout)
        self.assertIn("releva la sesión", r.stdout)
        # Y sin ceremonia: no se firmo ningun perdon por algo que no lo necesita.
        state = json.loads((self.task / "state.json").read_text())
        self.assertNotIn("cost_waivers", state, state)
        self.assertEqual(
            [h for h in state["history"] if h.get("kind") == "cost-waive"], [])
        # El relevo que hace de remediacion tiene que haber quedado pedido.
        self.assertTrue((self.task / "handoff.json").exists(),
                        "sin marcador no hay sesion nueva, y entonces el "
                        "termino no debio eximirse")

    def test_el_eximido_del_ctx_de_un_SUBAGENTE_no_se_toca(self):
        # La exencion es del ORQUESTADOR y solo de el: el contexto de arranque
        # de un subagente SI es controlable (lo arma quien lo lanza), o sea que
        # ahi la remediacion que el mensaje imprime se puede aplicar de verdad.
        self.assertEqual(self.init().returncode, 0)
        self.write_transcript(turns=10, cache_read=10_000, cache_write=500)
        self.write_subagent("implementer", turns=40, cache_read=400_000,
                            cache_write=1_000)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("COST-CTX", r.stderr)

    def test_los_dolares_siguen_frenando_aunque_la_transicion_releve(self):
        # Lo que NO se afloja: el relevo tira el contexto, no la factura.
        self.assertEqual(self.init(budget=0.50).returncode, 0)
        self.write_transcript(turns=200, cache_read=100_000, cache_write=1_000)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("COST-BUDGET", r.stderr)

    def test_la_cache_rota_sigue_frenando_aunque_la_transicion_releve(self):
        self.assertEqual(self.init().returncode, 0)
        self.write_transcript(turns=40, cache_read=20_000, cache_write=200_000)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("COST-CACHE", r.stderr)

    def test_el_kill_switch_por_ARCHIVO_tambien_cierra_la_exencion(self):
        # Las dos formas del kill switch valen, porque quien lo necesita a las
        # tres de la mañana usa el archivo (mismo criterio que orchestrator-watch).
        self.assertEqual(self.init().returncode, 0)
        self.write_transcript(turns=40, cache_read=400_000, cache_write=1_000)
        (self.ws / ".harness").mkdir(parents=True, exist_ok=True)
        (self.ws / ".harness" / "orch-watch.off").touch()
        r = self.transition("implement")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("COST-CTX", r.stderr)

    def test_presupuesto_excedido_frena_la_transicion(self):
        self.assertEqual(self.init(budget=0.50).returncode, 0)
        self.write_transcript(turns=200, cache_read=100_000, cache_write=1_000)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("COST-BUDGET", r.stderr)

    def test_una_corrida_sana_pasa(self):
        # CONTRA-MITAD obligatoria: un gate que siempre bloquea no es un gate,
        # es un freno de mano. Caché sana y contexto chico tienen que pasar.
        self.assertEqual(self.init(budget=100).returncode, 0)
        self.write_transcript(turns=30, cache_read=40_000, cache_write=500)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_la_remediacion_del_gate_EXISTE(self):
        """El gate ofrecia una salida que no existia, y eso es peor que no ofrecer.

        La primera version de POLICY-BUDGET-005 decia "subilo con
        `init --budget-usd`". `init` se niega sobre una tarea con estado
        (POLICY-STATE-001), asi que la unica remediacion escrita era FALSA y el
        gate quedaba como callejon sin salida: exactamente el defecto que este
        harness persigue (prosa que promete lo que el codigo no hace), cometido
        por el gate que vino a arreglar el gasto.
        """
        self.assertEqual(self.init(budget=1).returncode, 0)
        self.write_transcript(turns=200, cache_read=100_000, cache_write=1_000)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)

        # La salida que el mensaje nombra tiene que FUNCIONAR de verdad.
        subir = subprocess.run(
            ["python3", str(SCRIPT), "--policy", str(POLICY), "budget",
             str(self.task), "--to", "500", "--actor", "humano",
             "--reason", "refactor grande, justificado"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(subir.returncode, 0, subir.stderr)
        self.assertIn("budget", (self.task / "state.json").read_text(),
                      "el cambio de techo no quedo en el estado")
        self.assertIn("humano", (self.task / "state.json").read_text(),
                      "no quedo QUIEN lo autorizo: un techo sin actor es decorativo")
        r2 = self.transition("implement")
        self.assertEqual(r2.returncode, 0, r2.stdout + r2.stderr)

    def test_el_presupuesto_no_se_baja(self):
        # Misma ley que `delivery`: bajar el techo no deshace lo gastado, solo
        # deja el estado mintiendo sobre lo que ya ocurrio.
        self.assertEqual(self.init(budget=100).returncode, 0)
        r = subprocess.run(
            ["python3", str(SCRIPT), "--policy", str(POLICY), "budget",
             str(self.task), "--to", "10", "--actor", "humano"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(r.returncode, 3)
        self.assertIn("POLICY-BUDGET-007", r.stderr)

    def test_los_umbrales_de_emergencia_llegan_al_medidor(self):
        # El ultimo recurso: `transition` copia el entorno al subprocess, asi
        # que una emergencia de produccion puede mover el umbral sin editar
        # nada. NO deja rastro, por eso es el ultimo recurso y no el primero,
        # pero tiene que EXISTIR o el gate es un boton de apagado del harness.
        self.assertEqual(self.init().returncode, 0)
        self.write_transcript(turns=40, cache_read=400_000, cache_write=1_000)
        # sin_relevo: se necesita un termino que EFECTIVAMENTE frene para poder
        # probar que el umbral de emergencia lo destraba.
        self.assertEqual(self.transition("implement", sin_relevo=True).returncode, 3)
        env = os.environ.copy()
        env.update(CLAUDE_CONFIG_DIR=str(self.cfg), HARNESS_WS=str(self.ws),
                   HARNESS_ORCH_OFF="1", HARNESS_CTX_CEILING="900000")
        r = subprocess.run(
            ["python3", str(SCRIPT), "--policy", str(POLICY), "transition",
             str(self.task), "implement", "--actor", "orchestrator"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, env=env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_el_gate_no_agrega_latencia_perceptible(self):
        # Corre en el camino caliente de CADA transicion. Medido: 0.08s con el
        # filtro por tarea. Si alguien lo rompe y pasa a escanear todo, esto
        # muerde antes de que un usuario lo sufra como "se colgo".
        import time
        self.assertEqual(self.init().returncode, 0)
        self.write_transcript(turns=50, cache_read=40_000, cache_write=500)
        t0 = time.monotonic()
        r = self.transition("implement")
        dt = time.monotonic() - t0
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertLess(dt, 10.0, f"la transicion tardo {dt:.1f}s: el gate escanea de mas")

    def test_sin_transcripts_falla_abierto(self):
        # Sin datos no se puede afirmar nada, y bloquear seria mentir al reves:
        # exactamente el "verde silencioso" invertido. La tarea avanza.
        self.assertEqual(self.init().returncode, 0)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    # ── El termino que NO se puede remediar tiene salida auditable ───────────
    # Tres reportes del mismo callejon (#90, #91, #93): con un COST-CACHE de un
    # agente ya cerrado, la tarea no podia volver a cambiar de fase NUNCA. La
    # remediacion impresa (recortar el contexto de ARRANQUE) no aplica a una
    # metrica historica, `budget --to` solo mueve COST-BUDGET, HARNESS_KNOWN_BUG
    # solo lo honra ship.sh, y HARNESS_CACHE_HIT_FLOOR apaga el umbral sin
    # rastro. Trabajo commiteado, precheck verde, tarea viva e INMOVIL.

    def write_subagente(self, role, turns, cache_read, cache_write,
                        name="agent-uno", ts=None):
        subs = self.proj / self.sid / "subagents"
        subs.mkdir(parents=True, exist_ok=True)
        stamp = ts or self.ahora()
        lines = []
        for _ in range(turns):
            lines.append(json.dumps({
                "type": "assistant", "cwd": str(self.ws),
                "timestamp": stamp,
                "message": {"role": "assistant", "model": "claude-opus-5",
                            "usage": {"input_tokens": 0,
                                      "cache_read_input_tokens": cache_read,
                                      "cache_creation_input_tokens": cache_write,
                                      "output_tokens": 100},
                            "content": [{"type": "tool_use", "id": "t",
                                         "name": "Bash", "input": {}}]}}))
        (subs / f"{name}.jsonl").write_text("\n".join(lines) + "\n")
        (subs / f"{name}.meta.json").write_text(json.dumps({"agentType": role}))

    def waive(self, band, agent, actor="humano", reason="subagente cerrado"):
        env = os.environ.copy()
        env.update(CLAUDE_CONFIG_DIR=str(self.cfg), HARNESS_WS=str(self.ws))
        return subprocess.run(
            ["python3", str(SCRIPT), "--policy", str(POLICY), "cost-waive",
             str(self.task), "--band", band, "--agent", agent,
             "--actor", actor, "--reason", reason],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, env=env)

    def cache_historica(self):
        """Orquestador sano y un subagente cerrado bajo el piso: el caso real."""
        self.assertEqual(self.init(budget=500).returncode, 0)
        self.write_transcript(turns=30, cache_read=40_000, cache_write=500)
        self.write_subagente("architect", 33, 89_000, 11_000)   # 89%, piso 90%

    def test_el_cost_cache_historico_TRABA_y_budget_no_lo_destraba(self):
        # La mitad que justifica la otra: sin esto, el escape nuevo seria una
        # solucion a un problema que nadie tiene.
        self.cache_historica()
        r = self.transition("implement")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("COST-CACHE", r.stderr)
        subir = subprocess.run(
            ["python3", str(SCRIPT), "--policy", str(POLICY), "budget",
             str(self.task), "--to", "5000", "--actor", "humano",
             "--reason", "gasto justificado"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(subir.returncode, 0, subir.stderr)
        r2 = self.transition("implement")
        self.assertEqual(r2.returncode, 3,
                         "budget --to no puede destrabar un COST-CACHE, y el "
                         "mensaje no puede ofrecerlo como si pudiera")
        self.assertIn("cost-waive", r2.stderr,
                      "el gate tiene que NOMBRAR la salida que si aplica")
        self.assertIn("solo mueve el término COST-BUDGET", r2.stderr)

    def test_el_eximido_destraba_y_queda_en_history(self):
        self.cache_historica()
        self.assertEqual(self.transition("implement").returncode, 3)
        w = self.waive("cache", "architect")
        self.assertEqual(w.returncode, 0, w.stdout + w.stderr)
        state = json.loads((self.task / "state.json").read_text())
        entrada = [h for h in state["history"] if h.get("kind") == "cost-waive"]
        self.assertEqual(len(entrada), 1, state)
        self.assertEqual(entrada[0]["actor"], "humano")
        self.assertEqual(entrada[0]["agent"], "architect")
        self.assertTrue(entrada[0]["reason"],
                        "un eximido sin motivo es un gate apagado con mas pasos")
        r = self.transition("implement")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_el_eximido_de_ctx_del_orquestador_VIVO_destraba_de_verdad(self):
        # ISSUE #103, extremo a extremo. `cache` se exime bien porque su agente
        # YA CERRO: el transcript es inmutable y el valor clavado alcanza. El
        # ctx del ORQUESTADOR es otra cosa: esta vivo por definicion cuando pide
        # la transicion, su contexto medio es monotono creciente, y lo suben las
        # propias tool calls del waive y de la transicion. Anclado a un valor,
        # el eximido nacia VENCIDO: la transicion se frenaba igual DESPUES de un
        # waive aceptado, y la unica salida que quedaba era HARNESS_CTX_CEILING,
        # que el propio mensaje describe como el recurso que no deja rastro.
        self.assertEqual(self.init(budget=500).returncode, 0)
        # `sin_relevo`: con el vigilante apagado nadie levanta una sesion
        # nueva, asi que el orquestador SIGUE siendo el mismo con el mismo
        # contexto. Es la condicion donde este waive es la salida correcta, y
        # desde el #180 tambien la unica donde el termino llega a frenar.
        self.write_transcript(turns=20, cache_read=400_000, cache_write=1_000)
        self.assertEqual(self.transition("implement", sin_relevo=True).returncode, 3)
        w = self.waive("ctx", "orquestador", reason="sesion larga declarada")
        self.assertEqual(w.returncode, 0, w.stdout + w.stderr)
        state = json.loads((self.task / "state.json").read_text())
        ctx = [x for x in state["cost_waivers"] if x.get("band") == "ctx"]
        self.assertEqual(len(ctx), 1, state)
        self.assertTrue(ctx[0].get("phase"),
                        "el eximido de ctx declara la FASE que cubre: es su vigencia")
        # Y ahora el contexto CRECE, que es exactamente lo que pasa en campo
        # entre el waive y la transicion. Antes de #103 esto volvia a salir 3.
        self.write_transcript(turns=26, cache_read=420_000, cache_write=1_000)
        r = self.transition("implement", sin_relevo=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_el_eximido_de_ctx_deja_REGISTRAR_la_fase_que_ya_se_shippeo(self):
        # ISSUE #111: el mismo defecto que el #103, reportado desde el otro
        # extremo y con la consecuencia puesta. En campo: los dos repos de la
        # tarea YA estaban en main y desplegados verdes, y la fase no se podia
        # registrar. El propio ship.sh lo habia avisado: "no pude registrar la
        # fase: POLICY-BUDGET-005 / El push SI ocurrio. Registrala a mano o el
        # estado va a mentir." El waive se sello dos veces (350474.1 y despues
        # 360800.82) y las dos veces la transicion siguiente volvio a frenar,
        # porque entre el sello y la transicion el contexto ya habia crecido.
        #
        # Lo que este caso fija y el del #103 no: que el eximido se compara
        # contra la fase de la que se SALE, no contra la que se entra. Cubre la
        # ventana que se midio, y esa ventana es la fase que ya se trabajo.
        self.assertEqual(self.init(budget=500).returncode, 0)
        # Se llega a la fase en limpio: lo que se mide es la fase que se CIERRA.
        self.assertEqual(self.transition("implement").returncode, 0)
        # El caso de campo era una fase con los dos repos YA en main y
        # desplegados: de las que no relevan la sesion por definicion
        # (a `archive` y a `deploy` no se releva). `sin_relevo` es su
        # equivalente ejecutable en este fixture.
        self.write_transcript(turns=34, cache_read=430_000, cache_write=1_000)
        frena = self.transition("review", sin_relevo=True)
        self.assertEqual(frena.returncode, 3, frena.stdout + frena.stderr)
        self.assertIn("COST-CTX", frena.stdout + frena.stderr,
                      "el que frena tiene que ser el termino que se va a eximir")
        w = self.waive("ctx", "orquestador",
                       reason="cierre de fase: los dos repos ya estan en main")
        self.assertEqual(w.returncode, 0, w.stdout + w.stderr)
        state = json.loads((self.task / "state.json").read_text())
        ctx = [x for x in state["cost_waivers"] if x.get("band") == "ctx"][0]
        self.assertEqual(ctx["phase"], "implement",
                         "el eximido cubre la fase que se esta cerrando, no la que se entra")
        # El contexto sigue creciendo entre el sello y la transicion, que es la
        # carrera entera del reporte: son tool calls del propio waive.
        self.write_transcript(turns=40, cache_read=460_000, cache_write=1_000)
        r = self.transition("review", sin_relevo=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # Y destraba DEJANDO RASTRO, que es la otra mitad del reporte: la unica
        # salida que quedaba era HARNESS_CTX_CEILING, y el propio mensaje la
        # describe como el ultimo recurso justamente porque no se puede auditar.
        final = json.loads((self.task / "state.json").read_text())
        sello = [h for h in final["history"] if h.get("kind") == "cost-waive"]
        self.assertEqual(len(sello), 1, final)
        self.assertEqual(sello[0]["actor"], "humano")
        self.assertIn("ya estan en main", sello[0]["reason"])

    def test_no_se_exime_lo_que_no_esta_frenando(self):
        # El eximido se ancla al valor MEDIDO: eximir por adelantado seria
        # declarar algo que nadie midio, y ahi si seria un boton de apagado.
        self.cache_historica()
        w = self.waive("cache", "implementer")
        self.assertEqual(w.returncode, 3, w.stdout + w.stderr)
        self.assertIn("POLICY-COST-002", w.stderr)
        self.assertIn("COST-CACHE/architect", w.stderr,
                      "y dice que SI esta frenando, que es la mitad util del rechazo")
        self.assertNotIn("cost_waivers", (self.task / "state.json").read_text())

    def test_el_gasto_en_dolares_no_se_exime_por_aca(self):
        # COST-BUDGET ya tiene `budget --to`, que autoriza un NUMERO en vez de
        # una excepcion. Dos escapes para el mismo termino es uno de mas.
        self.cache_historica()
        w = self.waive("budget", "orquestador")
        self.assertEqual(w.returncode, 3, w.stdout + w.stderr)
        self.assertIn("POLICY-COST-001", w.stderr)
        # Y el rechazo es un PROMPT: nombra el comando que SI autoriza dolares.
        # Con `choices` en argparse esto decia "invalid choice" y mandaba al --help.
        self.assertIn("budget tasks/<id> --to", w.stderr)

    def test_el_eximido_es_idempotente(self):
        self.cache_historica()
        self.assertEqual(self.transition("implement").returncode, 3)
        self.assertEqual(self.waive("cache", "architect").returncode, 0)
        w2 = self.waive("cache", "architect")
        self.assertEqual(w2.returncode, 0, w2.stdout + w2.stderr)
        self.assertIn("ya estaba eximido", w2.stdout)
        state = json.loads((self.task / "state.json").read_text())
        self.assertEqual(len(state["cost_waivers"]), 1, state)
        self.assertEqual(
            len([h for h in state["history"] if h.get("kind") == "cost-waive"]), 1,
            "una autorizacion que no cambio nada no ensucia el history")

    def test_la_salida_ofrecida_es_la_del_termino_que_FRENA(self):
        # El check imprime tambien los terminos EXIMIDOS, asi que elegir la
        # remediacion por substring mandaria a eximir algo ya eximido. Con el
        # COST-CACHE aceptado y solo el presupuesto rojo, el mensaje tiene que
        # ofrecer `budget --to` y NO repetir el discurso de cost-waive.
        self.assertEqual(self.init(budget=0.01).returncode, 0)
        self.write_transcript(turns=30, cache_read=40_000, cache_write=500)
        self.write_subagente("architect", 33, 89_000, 11_000)
        self.assertEqual(self.transition("implement").returncode, 3)
        self.assertEqual(self.waive("cache", "architect").returncode, 0)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("COST-BUDGET", r.stderr)
        self.assertIn("EXIMIDO", r.stderr, "el eximido se sigue declarando")
        self.assertNotIn("solo mueve el término COST-BUDGET", r.stderr,
                         "no ofrece cost-waive cuando lo que frena son dólares")

    # ── LA VENTANA: las bandas de tasa miran la FASE EN CURSO (#95) ─────────
    # El eximido resolvia el caso de "acepto este 89%", pero no la CLASE del
    # problema: `cache_hit` y `ctx_avg` son promedios sobre transcripts
    # inmutables, asi que sin ventana el primer agente bajo el piso cobra su
    # peaje en TODA transicion futura, una por una, para siempre. El caso de
    # campo fueron dos abogados de RFC de una sola respuesta que dejaron
    # trabada una tarea que globalmente estaba en 94.4% de acierto.

    def test_el_subagente_de_una_fase_ANTERIOR_ya_no_frena(self):
        self.assertEqual(self.init(budget=500).returncode, 0)
        self.write_transcript(turns=30, cache_read=40_000, cache_write=500)
        # El abogado de RFC cerro bajo el piso ANTES de que empezara esta fase.
        self.write_subagente("architect", 33, 89_000, 11_000,
                             ts="2026-08-05T12:00:00.000Z")
        r = self.transition("implement")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_pero_el_que_corrio_EN_esta_fase_sigue_frenando(self):
        # CONTRA-MITAD obligatoria: la ventana acota el gate, no lo apaga. Lo
        # que se gasto en la fase que se esta cerrando todavia se cobra.
        self.cache_historica()
        r = self.transition("implement")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("COST-CACHE", r.stderr)

    def test_la_ventana_avanza_con_la_fase_y_el_peaje_se_paga_UNA_vez(self):
        # El corazon del issue: la tarea vuelve a moverse sola. Se acepta el
        # termino de ESTA fase (con actor y motivo, auditable), la fase avanza,
        # y la transicion siguiente ya no arrastra al agente que cerro atras.
        self.assertEqual(self.init(budget=500).returncode, 0)
        self.write_transcript(turns=30, cache_read=40_000, cache_write=500)
        self.write_subagente("architect", 33, 89_000, 11_000,
                             ts="2026-08-06T12:00:00.000Z")
        # La fase en curso empezo ANTES que ese subagente, asi que esta
        # transicion SI lo cobra. Se fija a mano y no con el reloj: el test no
        # puede depender de cuantos milisegundos tarda en llegar hasta aca.
        estado = json.loads((self.task / "state.json").read_text())
        estado["phase_since"] = "2026-08-06T00:00:00Z"
        (self.task / "state.json").write_text(json.dumps(estado))
        self.assertEqual(self.transition("implement").returncode, 3)
        self.assertEqual(self.waive("cache", "architect").returncode, 0)
        self.assertEqual(self.transition("implement").returncode, 0)
        estado = json.loads((self.task / "state.json").read_text())
        self.assertTrue(estado.get("phase_since"),
                        "la fase nueva tiene que declarar cuando empezo, o la "
                        "ventana se queda anclada a la anterior")
        # Sin tocar el eximido ni el umbral: la fase siguiente sale limpia
        # porque el subagente quedo del otro lado de la ventana.
        (self.task / "state.json").write_text(json.dumps(
            {k: v for k, v in estado.items() if k != "cost_waivers"}))
        r = self.transition("review")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_lo_que_queda_fuera_de_la_ventana_se_DICE(self):
        # Un termino que deja de frenar y deja de verse es el mismo silencio
        # que el gate vino a matar. Se declara con nombre y con motivo.
        self.assertEqual(self.init(budget=500).returncode, 0)
        self.write_transcript(turns=30, cache_read=40_000, cache_write=500)
        self.write_subagente("architect", 33, 89_000, 11_000,
                             ts="2026-08-05T12:00:00.000Z")
        env = os.environ.copy()
        env.update(CLAUDE_CONFIG_DIR=str(self.cfg), HARNESS_WS=str(self.ws))
        r = subprocess.run(
            ["python3", str(ROOT / "templates/scripts/harness-cost.py"),
             "check", self.task.name],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, env=env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("fuera de la ventana", r.stdout, r.stdout)
        self.assertIn("architect", r.stdout, r.stdout)

    def test_un_agente_corto_no_traba_la_tarea(self):
        # El piso mide DERROCHE, no la ventana de cache: con 4 turnos el maximo
        # alcanzable es 75%, o sea que el agente no podia aprobar el piso de 90%
        # hiciera lo que hiciera. Los subagentes cortos eran los mas expuestos.
        self.assertEqual(self.init(budget=500).returncode, 0)
        self.write_transcript(turns=30, cache_read=40_000, cache_write=500)
        self.write_subagente("implementer", 4, 10_000, 90_000)
        r = self.transition("implement")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class RelevoDeSesion(unittest.TestCase):
    """Una fase, una sesión: la transición estampa quién la manejó y pide relevo.

    Medido sobre una tarea de UN repo con dos rondas de review: el orquestador
    fue UNA sesión de 45.3h sobre 45.4h de reloj, 688 turnos, 440k de contexto
    medio. El trabajo real de los subagentes fueron 5.8h. Y el contexto es cosa
    de FASE (el eximido de ctx ya se ata a la fase): la sesión no lo era.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.task = Path(self.tmp.name) / "AUTO-20260812-relevo"
        self.task.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_policy(self, *args, sid=None):
        env = os.environ.copy()
        if sid is not None:
            env["HARNESS_SESSION_ID"] = sid
        return subprocess.run(
            ["python3", str(SCRIPT), "--policy", str(POLICY), *map(str, args)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, env=env)

    def state(self):
        return json.loads((self.task / "state.json").read_text())

    def test_la_transicion_estampa_la_sesion(self):
        self.assertEqual(self.run_policy("init", self.task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        r = self.run_policy("transition", self.task, "implement",
                            "--actor", "orchestrator", sid="sesion-uno")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.state()["session_id"], "sesion-uno")

    def test_dos_fases_con_la_misma_sesion_quedan_a_la_vista(self):
        # Es la prueba de que el relevo NO ocurrió, y se ve en state.json sin
        # tener que leer transcripts a posteriori.
        self.assertEqual(self.run_policy("init", self.task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        self.run_policy("transition", self.task, "implement",
                        "--actor", "orchestrator", sid="la-misma")
        primera = self.state()["session_id"]
        self.run_policy("transition", self.task, "review",
                        "--actor", "orchestrator", sid="la-misma")
        self.assertEqual(primera, self.state()["session_id"])
        # …y con relevo de verdad, cambia.
        self.run_policy("transition", self.task, "review", "--actor",
                        "orchestrator", "--repo", "atlas", sid="otra")
        self.assertEqual(self.state()["session_id"], "otra")

    def test_el_puntero_inverso_del_hook_alcanza(self):
        # El id de sesión solo existe en el payload de los hooks: track-read.sh
        # lo deja en tasks/<id>/.session y la policy lo lee de ahí.
        self.assertEqual(self.run_policy("init", self.task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        (self.task / ".session").write_text("desde-el-hook\n")
        r = self.run_policy("transition", self.task, "implement",
                            "--actor", "orchestrator")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.state()["session_id"], "desde-el-hook")

    def test_avanzar_de_fase_pide_relevo(self):
        self.assertEqual(self.run_policy("init", self.task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        self.run_policy("transition", self.task, "implement",
                        "--actor", "orchestrator", sid="uno")
        marca = self.task / "handoff.json"
        self.assertTrue(marca.is_file(), "no dejó el marcador de relevo")
        payload = json.loads(marca.read_text())
        self.assertEqual(payload["phase"], "implement")
        self.assertEqual(payload["from_session"], "uno")

    def test_otra_ronda_del_mismo_review_NO_pide_relevo(self):
        # `review → review` con --repo es la MISMA fase: relevar ahí sería pagar
        # un arranque por ronda.
        self.assertEqual(self.run_policy("init", self.task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        self.run_policy("transition", self.task, "implement", "--actor", "orchestrator")
        self.run_policy("transition", self.task, "review", "--actor", "orchestrator")
        (self.task / "handoff.json").unlink()
        r = self.run_policy("transition", self.task, "review",
                            "--actor", "orchestrator", "--repo", "atlas")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.task / "handoff.json").exists())

    def test_quick_no_se_releva(self):
        # quick es UNA sesión corta de punta a punta: relevarlo por fase sería
        # pagar arranques para ahorrar un contexto que nunca crece.
        self.assertEqual(self.run_policy("init", self.task, "--lane", "quick",
                                         "--repos", "atlas").returncode, 0)
        r = self.run_policy("transition", self.task, "implement",
                            "--actor", "orchestrator")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.task / "handoff.json").exists())

    def test_una_tarea_en_vuelo_sin_hook_no_se_rompe(self):
        # Compatibilidad: sin puntero inverso y sin variable, no hay id que
        # estampar. No se inventa uno y la transición pasa igual.
        self.assertEqual(self.run_policy("init", self.task, "--lane", "express",
                                         "--repos", "atlas").returncode, 0)
        r = self.run_policy("transition", self.task, "implement",
                            "--actor", "orchestrator", sid="")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("session_id", self.state())


class StaleTest(unittest.TestCase):
    """`stale`: quién se da cuenta de que una tarea dejó de avanzar (#155).

    El caso de campo: 12h46m en `implement`, con el trabajo hecho, el precheck
    verde y SIN pausa. No estaba bloqueada ni esperando a un humano; estaba
    detenida y contada como si avanzara. La encontró un humano mirando
    timestamps de archivos, tres veces el mismo día.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self.tmp.name)
        self.tasks = self.ws / "tasks"
        self.tasks.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def task(self, name, phase, minutos_atras, con_since=True):
        d = self.tasks / name
        d.mkdir()
        state = {"phase": phase}
        if con_since:
            since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=minutos_atras)
            state["phase_since"] = since.strftime("%Y-%m-%dT%H:%M:%SZ")
        (d / "state.json").write_text(json.dumps(state), encoding="utf-8")
        return d

    def stale(self):
        return subprocess.run(
            ["python3", str(SCRIPT), "stale", str(self.tasks)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def test_caza_la_tarea_del_reporte(self):
        self.task("AUTO-muse", "implement", 766)   # 12h46m, el caso exacto
        r = self.stale()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("AUTO-muse", r.stdout)
        self.assertIn("implement", r.stdout)

    def test_una_fase_en_curso_normal_no_se_avisa(self):
        self.task("AUTO-sana", "implement", 5)
        r = self.stale()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.strip(), "")

    def test_el_techo_es_por_fase(self):
        # 45 min es normal en implement y no lo es en ship, que es mecánico.
        self.task("AUTO-implement", "implement", 45)
        self.task("AUTO-ship", "ship", 45)
        r = self.stale()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("AUTO-ship", r.stdout)
        self.assertNotIn("AUTO-implement", r.stdout)

    def test_blocked_y_archive_estan_exentas(self):
        # Una pausa REGISTRADA no es una tarea perdida: alguien ya sabe.
        self.task("AUTO-blocked", "blocked", 5000)
        self.task("AUTO-archive", "archive", 5000)
        r = self.stale()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_sin_phase_since_se_avisa_igual(self):
        # No poder mirar no es verde: es justo lo que daría un state.json de una
        # versión vieja del harness, y ahí el silencio sería el mismo bug.
        self.task("AUTO-vieja", "review", 0, con_since=False)
        r = self.stale()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("AUTO-vieja", r.stdout)
        self.assertIn("sin phase_since", r.stdout)

    def test_el_bus_se_avisa_una_vez_por_fase(self):
        # El vigilante pasa cada 120s: un aviso cada dos minutos durante 12 horas
        # es ruido que se aprende a ignorar, o sea el mismo silencio con más pasos.
        scripts = self.ws / "scripts"
        scripts.mkdir()
        (scripts / "emit.sh").write_text(
            '#!/usr/bin/env bash\nprintf "%s\\n" "$2" >> "$(dirname "$0")/../bus.log"\n',
            encoding="utf-8")
        d = self.task("AUTO-muse", "implement", 766)
        self.assertEqual(self.stale().returncode, 1)
        self.assertEqual(self.stale().returncode, 1)
        bus = (self.ws / "bus.log").read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(bus), 1, bus)
        self.assertIn("implement", bus[0])
        # …y cuando la tarea SE MUEVE, el aviso se rearma.
        state = json.loads((d / "state.json").read_text(encoding="utf-8"))
        state["phase_since"] = (dt.datetime.now(dt.timezone.utc)
                                - dt.timedelta(minutes=900)).strftime("%Y-%m-%dT%H:%M:%SZ")
        (d / "state.json").write_text(json.dumps(state), encoding="utf-8")
        self.assertEqual(self.stale().returncode, 1)
        bus = (self.ws / "bus.log").read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(bus), 2, bus)

    def test_un_directorio_inexistente_no_es_verde(self):
        r = subprocess.run(
            ["python3", str(SCRIPT), "stale", str(self.ws / "no-existe")],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("POLICY-STALE-001", r.stderr)


if __name__ == "__main__":
    unittest.main()
