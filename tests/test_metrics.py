#!/usr/bin/env python3
"""test_metrics.py: el colector de metricas, contra artefactos reales.

Lo que se fija aca no son numeros bonitos: es que las tres leyes del subsistema
se cumplan. (1) que derive de lo que YA se escribe, (2) que salga 0 pase lo que
pase, y (3) que el informe este ACOTADO por construccion, porque un informe que
crece con los datos es el consumidero de tokens que este diseño existe para
evitar.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "templates", "scripts", "harness-metrics.py")


def ts(segundo):
    return "2026-07-30T10:%02d:%02dZ" % (segundo // 60, segundo % 60)


class MetricsBase(unittest.TestCase):
    def setUp(self):
        self.ws = tempfile.mkdtemp(prefix="metrics-ws-")
        os.makedirs(os.path.join(self.ws, ".harness"))
        os.makedirs(os.path.join(self.ws, "scripts"))
        shutil.copy(SCRIPT, os.path.join(self.ws, "scripts", "harness-metrics.py"))
        self.bus = os.path.join(self.ws, ".harness", "events.jsonl")

    def tearDown(self):
        shutil.rmtree(self.ws, ignore_errors=True)

    # ── fixtures ──
    def task(self, task_id, state):
        path = os.path.join(self.ws, "tasks", task_id)
        os.makedirs(os.path.join(path, "evidence"), exist_ok=True)
        with open(os.path.join(path, "state.json"), "w", encoding="utf-8") as fh:
            json.dump(state, fh)
        return path

    def ev(self, task_id, ev_id, **campos):
        doc = {"schema": 1, "id": ev_id, "task_id": task_id, "repo": "atlas",
               "kind": "test", "runner": "implementer", "exit_code": 0}
        doc.update(campos)
        path = os.path.join(self.ws, "tasks", task_id, "evidence", ev_id + ".json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh)

    def evento(self, **campos):
        row = {"ts": campos.pop("ts"), "kind": campos.pop("kind"),
               "task": campos.pop("task"), "actor": campos.pop("actor", "atlas"),
               "summary": campos.pop("summary", "")}
        row.update(campos)
        with open(self.bus, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")

    def run_m(self, *args):
        return subprocess.run(
            [sys.executable, os.path.join(self.ws, "scripts", "harness-metrics.py")]
            + list(args) + ["--ws", self.ws],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)

    def rows(self):
        path = os.path.join(self.ws, ".harness", "metrics", "tasks.jsonl")
        latest = {}
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    row = json.loads(line)
                    latest[row["task_id"]] = row
        return latest


class TestCollect(MetricsBase):
    def test_row_deriva_de_artefactos_existentes(self):
        """Ninguna instrumentacion nueva: state.json, los sellos y el bus."""
        self.task("T1", {"lane": "full", "phase": "archive", "repos": ["atlas"],
                         "review_rounds_by_repo": {"atlas": 3},
                         "review_blocking_by_repo": {"atlas": [4, 2, 1]}})
        self.ev("T1", "EV-TEST-aaaaaaaaaaaa", started_at=ts(0), finished_at=ts(90))
        self.ev("T1", "EV-TEST-bbbbbbbbbbbb", started_at=ts(100), finished_at=ts(130))
        self.evento(ts=ts(0), kind="phase", task="T1", summary="implement")
        self.evento(ts=ts(600), kind="phase", task="T1", summary="review")
        self.evento(ts=ts(900), kind="phase", task="T1", summary="ship")
        self.assertEqual(self.run_m("collect", "--task", "T1").returncode, 0)

        row = self.rows()["T1"]
        self.assertEqual(row["lane"], "full")
        self.assertEqual(row["durations"]["tests"]["count"], 2)
        self.assertEqual(row["durations"]["tests"]["total_s"], 120)
        self.assertEqual(row["durations"]["tests"]["max_s"], 90)
        self.assertEqual(row["durations"]["tests"]["by_repo"]["atlas"]["total_s"], 120)
        self.assertEqual(row["durations"]["by_phase_s"]["implement"], 600)
        self.assertEqual(row["durations"]["by_phase_s"]["review"], 300)
        self.assertEqual(row["review"]["rounds_by_repo"]["atlas"], 3)

    def test_rondas_gastadas(self):
        """Una ronda cuenta como gastada si NO bajo los bloqueantes: el mismo
        criterio de convergencia de la policy, mirado del otro lado."""
        self.task("T1", {"review_blocking_by_repo": {"atlas": [4, 4, 2, 2]}})
        self.run_m("collect", "--task", "T1")
        self.assertEqual(self.rows()["T1"]["review"]["wasted_rounds"], 2)

    def test_falso_rojo_solo_si_el_codigo_no_cambio(self):
        """La metrica estrella. Rojo y despues verde SIN sello de un commit
        nuevo entre medio: el rojo no era del codigo."""
        self.task("T1", {})
        self.ev("T1", "EV-TEST-000000000001", started_at=ts(0), finished_at=ts(5),
                commit="aaa")
        self.evento(ts=ts(10), kind="gate", task="T1", summary="tests \u2014 BLOQUEÓ el ship", ok=False)
        self.evento(ts=ts(20), kind="gate", task="T1", summary="tests", ok=True)
        self.run_m("collect", "--task", "T1")
        hits = self.rows()["T1"]["gates"]["false_red"]["red_then_green_same_change"]
        self.assertEqual(len(hits), 1, "rojo y verde sin commit nuevo: es falso rojo")
        self.assertEqual(hits[0]["gate"], "tests")

    def test_el_nombre_del_gate_sobrevive_a_los_tres_formatos(self):
        """El rojo y el verde del MISMO gate tienen que dar el mismo nombre, o
        no cruzan nunca y la metrica estrella sale vacia fingiendo que no hay
        falsos rojos. Un gate con parentesis en el nombre (los hay) rompia esto.
        """
        self.task("T1", {})
        self.ev("T1", "EV-TEST-000000000001", started_at=ts(0), finished_at=ts(1),
                commit="aaa")
        gate = "el test nuevo MUERDE (rojo sobre la base)"
        self.evento(ts=ts(10), kind="gate", task="T1", ok=False,
                    summary="%s \u2014 BLOQUEÓ el ship de atlas (exit 3)" % gate)
        self.evento(ts=ts(20), kind="gate", task="T1", summary=gate, ok=True)
        self.run_m("collect", "--task", "T1")
        row = self.rows()["T1"]
        hits = row["gates"]["false_red"]["red_then_green_same_change"]
        self.assertEqual([h["gate"] for h in hits], [gate],
                         "el gate con parentesis se cuenta entero, no partido")
        self.assertEqual([b["gate"] for b in row["gates"]["blocks"]], [gate])

    def test_nombre_del_gate_en_el_formato_del_precheck(self):
        """`precheck de <repo> rojo (<gate>): ...` guarda el nombre ADENTRO de
        los parentesis, al reves que los otros dos formatos."""
        self.task("T1", {})
        self.evento(ts=ts(10), kind="gate", task="T1", ok=False,
                    summary="precheck de atlas rojo (tests no debilitados): "
                            "ronda de review AHORRADA")
        self.run_m("collect", "--task", "T1")
        blocks = self.rows()["T1"]["gates"]["blocks"]
        self.assertEqual([b["gate"] for b in blocks], ["tests no debilitados"])

    def test_no_es_falso_rojo_si_hubo_un_fix(self):
        """La contra-mitad, que es la que impide que esto cuente cualquier cosa:
        si entre el rojo y el verde se sello un commit NUEVO, alguien arreglo
        algo y el gate hizo su trabajo."""
        self.task("T1", {})
        self.ev("T1", "EV-TEST-000000000001", started_at=ts(0), finished_at=ts(5),
                commit="aaa")
        self.evento(ts=ts(10), kind="gate", task="T1", summary="tests \u2014 BLOQUEÓ el ship", ok=False)
        self.ev("T1", "EV-TEST-000000000002", started_at=ts(15), finished_at=ts(18),
                commit="bbb")
        self.evento(ts=ts(20), kind="gate", task="T1", summary="tests", ok=True)
        self.run_m("collect", "--task", "T1")
        hits = self.rows()["T1"]["gates"]["false_red"]["red_then_green_same_change"]
        self.assertEqual(hits, [], "hubo un commit nuevo: el rojo era legitimo")

    def test_contencion_y_ambiente(self):
        self.task("T1", {})
        self.ev("T1", "EV-TEST-000000000001", exit_code=1,
                contention={"suspect": True, "foreign_peak": 31, "load_max": 9.1})
        self.evento(ts=ts(1), kind="assumption", task="T1",
                    summary="atlas: gate 'tests' rojo con menos de 1 GB libre "
                            "(posible causa ambiental)")
        self.run_m("collect", "--task", "T1")
        row = self.rows()["T1"]
        self.assertEqual(row["evidence"]["suspect"], 1)
        self.assertEqual(row["gates"]["false_red"]["contention"], 1)
        self.assertEqual(row["gates"]["false_red"]["ambient"], 1)

    def test_collect_es_idempotente(self):
        """Dos corridas sobre la misma tarea sin cambios no duplican la fila:
        el jsonl es append-only y crecer sin motivo lo vuelve inservible."""
        self.task("T1", {"lane": "quick"})
        self.run_m("collect", "--task", "T1")
        self.run_m("collect", "--task", "T1")
        path = os.path.join(self.ws, ".harness", "metrics", "tasks.jsonl")
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(len([l for l in fh if l.strip()]), 1)

    def test_all_recolecta_todas(self):
        self.task("T1", {"lane": "quick"})
        self.task("T2", {"lane": "full"})
        self.run_m("collect", "--all")
        self.assertEqual(sorted(self.rows()), ["T1", "T2"])


class TestStack(MetricsBase):
    def test_stack_es_generico(self):
        """Ni engram ni graphify estan cableados: caen de las claves de
        .mcp.json, de las capabilities y de la regla de artefactos. Una
        herramienta inventada tiene que capturarse igual, o el sistema solo
        sabria evaluar lo que ya sospechabamos."""
        with open(os.path.join(self.ws, ".mcp.json"), "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": {"engram": {}, "chirimoya-mcp": {}}}, fh)
        with open(os.path.join(self.ws, "harness-answers.yaml"), "w", encoding="utf-8") as fh:
            fh.write("memory:\n  provider: engram\n"
                     "capabilities:\n  - name: graphify\n    bin: zzz-inexistente\n")
        os.makedirs(os.path.join(self.ws, "graphify-out"))
        with open(os.path.join(self.ws, "graphify-out", "manifest.json"), "w") as fh:
            fh.write("{}")
        with open(os.path.join(self.ws, "models.yaml"), "w", encoding="utf-8") as fh:
            fh.write("provider: anthropic\nroles:\n  reviewer: claude-opus-5\n")

        out = self.run_m("stack")
        self.assertEqual(out.returncode, 0, out.stdout)
        stack = json.loads(out.stdout)
        self.assertIn("engram", stack["mcp"])
        self.assertIn("chirimoya-mcp", stack["mcp"], "un MCP jamas visto se captura igual")
        self.assertEqual(stack["memory_provider"], "engram")
        self.assertEqual(stack["models"]["reviewer"], "claude-opus-5")
        self.assertIn("zzz-inexistente", stack["tools"])
        self.assertFalse(stack["tools"]["zzz-inexistente"]["present"])
        self.assertTrue(stack["fp"], "el stack tiene huella para poder agrupar")

    def test_artefactos_por_convencion(self):
        """graphify-out/manifest.json cae de una REGLA por nombre, no de una
        lista: `<name>-out/manifest.json` o `.<name>ignore`."""
        with open(os.path.join(self.ws, "harness-answers.yaml"), "w", encoding="utf-8") as fh:
            fh.write("capabilities:\n  - name: x\n    bin: graphify\n")
        with open(os.path.join(self.ws, ".graphifyignore"), "w") as fh:
            fh.write("node_modules\n")
        stack = json.loads(self.run_m("stack").stdout)
        self.assertTrue(stack["tools"]["graphify"]["artifacts"])


class TestReport(MetricsBase):
    def test_informe_acotado_por_construccion(self):
        """LA ley 3. Con 40 tareas y 60 gates distintos el informe no puede
        crecer: si creciera, cada consulta costaria mas tokens que la anterior
        y el sistema se volveria el problema que vino a medir."""
        for n in range(40):
            self.task("T%d" % n, {"lane": "full"})
            for g in range(60):
                self.evento(ts=ts(g), kind="gate", task="T%d" % n,
                            summary="gate-largísimo-numero-%d %s" % (g, "x" * 200),
                            ok=False, dur=g)
        self.run_m("collect", "--all")
        out = self.run_m("report")
        self.assertEqual(out.returncode, 0)
        lineas = out.stdout.splitlines()
        self.assertLessEqual(len(lineas), 100, "el informe tiene tope duro de lineas")
        self.assertLessEqual(len(out.stdout), 8192, "y de tamaño")
        for linea in lineas:
            self.assertLessEqual(len(linea), 121, "cada linea va truncada")

    def test_n_chico_no_dictamina(self):
        """Con dos tareas no se compara nada: decir que un stack es mejor con
        n=2 seria mentir con formato de tabla."""
        self.task("T1", {})
        self.task("T2", {})
        self.run_m("collect", "--all")
        out = self.run_m("report")
        self.assertIn("insuficiente para comparar", out.stdout)
        self.assertIn("no prueba que un stack sea mejor", out.stdout)

    def test_report_sin_datos_no_revienta(self):
        out = self.run_m("report")
        self.assertEqual(out.returncode, 0)
        self.assertIn("collect", out.stdout)


class TestFailOpen(MetricsBase):
    def test_state_corrupto_y_bus_ausente(self):
        """Ley 2. Telemetria que puede tumbar a quien la invoca es un bug."""
        path = os.path.join(self.ws, "tasks", "T1")
        os.makedirs(path)
        with open(os.path.join(path, "state.json"), "w") as fh:
            fh.write("{esto no es json")
        self.assertEqual(self.run_m("collect", "--task", "T1").returncode, 0)
        self.assertEqual(self.run_m("report").returncode, 0)
        self.assertEqual(self.run_m("escalate").returncode, 0)

    def test_evidencia_con_timestamps_basura(self):
        self.task("T1", {})
        self.ev("T1", "EV-TEST-000000000001", started_at="ayer", finished_at=None)
        self.assertEqual(self.run_m("collect", "--task", "T1").returncode, 0)
        self.assertEqual(self.rows()["T1"]["durations"]["tests"]["count"], 0)


class TestEscalate(MetricsBase):
    def _tarea_con_falsos(self, task_id, veces):
        self.task(task_id, {})
        self.ev(task_id, "EV-TEST-%s0000000001" % task_id[:2],
                started_at=ts(0), finished_at=ts(1), commit="aaa")
        for n in range(veces):
            self.evento(ts=ts(10 + n * 4), kind="gate", task=task_id,
                        summary="tests \u2014 BLOQUEÓ el ship", ok=False)
            self.evento(ts=ts(12 + n * 4), kind="gate", task=task_id,
                        summary="tests", ok=True)

    def test_sobre_umbral_propone_el_reporte_upstream(self):
        """El bucle cierra en un issue de GitHub upstream, con titulo ESTABLE
        para que la huella de harness-bug.sh dedupee entre maquinas: N
        instancias con el mismo defecto convergen a UN issue, que es lo que
        hace que esto sirva con mucha gente usando el harness."""
        self._tarea_con_falsos("T1", 2)
        self._tarea_con_falsos("T2", 2)
        self.run_m("collect", "--all")
        out = self.run_m("escalate")
        self.assertEqual(out.returncode, 0)
        self.assertIn("harness-bug.sh report", out.stdout)
        self.assertIn("falsos rojos recurrentes", out.stdout)
        self.assertNotRegex(out.stdout, r"--title \"[^\"]*\d+ apariciones",
                            "el titulo no lleva numeros: la huella debe ser estable")

    def test_bajo_umbral_se_calla(self):
        self._tarea_con_falsos("T1", 1)
        self.run_m("collect", "--all")
        out = self.run_m("escalate")
        self.assertEqual(out.returncode, 0)
        self.assertNotIn("harness-bug.sh report", out.stdout)

    def test_dry_run_es_el_default(self):
        """No abre issues sin que se lo pidan: la cuota upstream es de 3 por
        dia y gastarla sola seria peor que no medir."""
        self._tarea_con_falsos("T1", 2)
        self._tarea_con_falsos("T2", 2)
        self.run_m("collect", "--all")
        out = self.run_m("escalate")
        self.assertIn("harness-bug.sh report", out.stdout,
                      "imprime el comando, no lo ejecuta")


if __name__ == "__main__":
    unittest.main(verbosity=2)
