#!/usr/bin/env python3
"""test_harness_cost.py: la báscula tiene que ser exacta o no sirve de gate.

POR QUE ESTA SUITE: harness-cost.py entró como GATE (transition lo corre y se
niega con POLICY-BUDGET-005), y hasta ahora solo se ejercitaba de refilón desde
test_policy.py. Un gate cuyo cálculo nadie prueba es un gate que va a bloquear
corridas sanas o dejar pasar las caras, y las dos fallas cuestan.

Lo que se protege acá, en orden de importancia:
  1. La ARITMETICA. Si el costo está mal, el techo de presupuesto es ruido.
     En particular el desglose por TTL: la caché de 1h se cobra al DOBLE que
     la de 5m, y cobrarlo plano subestimaba la escritura ~38%.
  2. La HONESTIDAD ante lo que no sabe: un modelo sin tarifar no se inventa
     un precio, y sin transcripts no se afirma $0.00.
  3. Los UMBRALES: que el check muerda donde tiene que morder y no donde no.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "templates/scripts/harness-cost.py"


class CostBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        # macOS: /var es symlink a /private/var y abspath NO resuelve symlinks,
        # asi que el slug del transcript y el que busca el medidor tienen que
        # salir del MISMO string. Se resuelve una sola vez.
        self.ws = (Path(self.tmp.name) / "ws").resolve()
        self.task = self.ws / "tasks" / "T1"
        self.task.mkdir(parents=True)
        self.sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        st = self.ws / ".harness" / "session-task"
        st.mkdir(parents=True)
        (st / self.sid).write_text("T1\n")
        self.cfg = Path(self.tmp.name) / "cfg"
        slug = re.sub(r"[^a-zA-Z0-9]", "-", str(self.ws))
        self.proj = self.cfg / "projects" / slug
        self.proj.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def turn(self, model="claude-opus-5", inp=0, read=0, write=0, out=0,
             ttl=None, tools=1):
        usage = {
            "input_tokens": inp,
            "cache_read_input_tokens": read,
            "cache_creation_input_tokens": write,
            "output_tokens": out,
        }
        if ttl:
            usage["cache_creation"] = ttl
        content = [{"type": "tool_use", "id": "t", "name": "Bash", "input": {}}
                   for _ in range(tools)]
        return json.dumps({
            "type": "assistant",
            "cwd": str(self.ws),
            "timestamp": "2026-08-05T12:00:00.000Z",
            "message": {"role": "assistant", "model": model,
                        "usage": usage, "content": content},
        })

    def write(self, lines, sid=None):
        (self.proj / f"{sid or self.sid}.jsonl").write_text("\n".join(lines) + "\n")

    def run_cost(self, *args):
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(self.cfg)
        env["HARNESS_WS"] = str(self.ws)
        return subprocess.run(["python3", str(SCRIPT), *map(str, args)],
                              text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False, env=env)


class Aritmetica(CostBase):
    def test_precio_base(self):
        # Opus 5: $5 input / $25 output por MTok. 1M de input y 1M de output
        # tienen que dar exactamente $30.00.
        self.write([self.turn(inp=1_000_000, out=1_000_000)])
        r = self.run_cost("task", "T1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("30.00", r.stdout, r.stdout)

    def test_cache_read_es_un_decimo(self):
        # 10M leidos de cache = 10M x $0.50 = $5.00
        self.write([self.turn(read=10_000_000)])
        r = self.run_cost("task", "T1")
        self.assertIn("5.00", r.stdout, r.stdout)

    def test_ttl_de_una_hora_cuesta_el_doble(self):
        # EL BUG QUE ESTA SUITE EXISTE PARA CONGELAR: el panel cobraba toda la
        # escritura a 1.25x. La de 1h es 2x. 1M a 1h = $10.00, no $6.25.
        self.write([self.turn(write=1_000_000,
                              ttl={"ephemeral_1h_input_tokens": 1_000_000})])
        r = self.run_cost("task", "T1")
        self.assertIn("10.00", r.stdout, r.stdout)

    def test_ttl_de_5m_cobra_1_25x(self):
        self.write([self.turn(write=1_000_000,
                              ttl={"ephemeral_5m_input_tokens": 1_000_000})])
        r = self.run_cost("task", "T1")
        self.assertIn("6.25", r.stdout, r.stdout)

    def test_sin_desglose_cae_al_plano_de_5m(self):
        # Un transcript viejo sin el campo `cache_creation` no puede quedar sin
        # cobrar: se cae al plano y se declara en el docstring.
        self.write([self.turn(write=1_000_000)])
        r = self.run_cost("task", "T1")
        self.assertIn("6.25", r.stdout, r.stdout)

    def test_el_desglose_por_ttl_no_dobla_el_conteo(self):
        # `cache_creation_input_tokens` es el TOTAL y el desglose son sus
        # partes. Cobrar los dos seria doble conteo: 1M repartido 50/50 debe
        # dar 0.5x$6.25 + 0.5x$10.00 = $8.125, no $14.375.
        self.write([self.turn(write=1_000_000, ttl={
            "ephemeral_5m_input_tokens": 500_000,
            "ephemeral_1h_input_tokens": 500_000})])
        r = self.run_cost("task", "T1")
        self.assertIn("8.12", r.stdout, r.stdout)


class Honestidad(CostBase):
    def test_modelo_sin_tarifar_no_inventa_precio(self):
        # Los tokens son reales; el dinero no se inventa. Misma regla que el
        # panel: un modelo desconocido muestra n/d y queda FUERA del total.
        self.write([self.turn(model="glm-4-plus", read=10_000_000)])
        r = self.run_cost("task", "T1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("n/d", r.stdout, r.stdout)
        self.assertIn("sin tarifar", r.stdout, r.stdout)

    def test_variante_de_ventana_cotiza_como_su_base(self):
        # `claude-opus-5[1m]` no lleva recargo por contexto largo: normalizar
        # el sufijo es correcto, no una aproximacion. Si esto se rompiera, la
        # sesion entera saldria n/d y el gate no mediria nada.
        self.write([self.turn(model="claude-opus-5[1m]", read=10_000_000)])
        r = self.run_cost("task", "T1")
        self.assertIn("5.00", r.stdout, r.stdout)
        self.assertNotIn("n/d", r.stdout, r.stdout)

    def test_sintetico_no_cuenta(self):
        # Los mensajes `<synthetic>` los fabrica Claude Code local: no hubo
        # llamada a la API. Contarlos inflaria turnos y ensuciaria el hit ratio.
        self.write([self.turn(model="<synthetic>", read=10_000_000),
                    self.turn(read=1_000_000)])
        r = self.run_cost("task", "T1")
        self.assertIn("0.50", r.stdout, r.stdout)

    def test_sin_transcripts_lo_dice_y_no_reporta_cero(self):
        # El "verde silencioso" invertido: reportar $0.00 cuando en realidad no
        # se pudo medir es exactamente lo que este harness persigue.
        r = self.run_cost("task", "T1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("sin transcripts", (r.stdout + r.stderr).lower())

    def test_transcript_ilegible_no_tumba_el_reporte(self):
        (self.proj / f"{self.sid}.jsonl").write_bytes(b"\x00\x01 no es json\n")
        r = self.run_cost("day", "--days", "9999")
        self.assertIn(r.returncode, (0, 4), r.stderr)


class Umbrales(CostBase):
    def test_check_muerde_con_cache_rota(self):
        self.write([self.turn(read=20_000, write=200_000) for _ in range(40)])
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("COST-CACHE", r.stdout)

    def test_check_muerde_con_contexto_desbocado(self):
        self.write([self.turn(read=400_000, write=1_000) for _ in range(40)])
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("COST-CTX", r.stdout)

    def test_check_pasa_una_corrida_sana(self):
        # CONTRA-MITAD: un gate que siempre bloquea no es un gate.
        self.write([self.turn(read=40_000, write=500) for _ in range(30)])
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_los_umbrales_se_pueden_mover_por_entorno(self):
        # Un techo que no se puede ajustar es un techo que alguien comenta.
        self.write([self.turn(read=400_000, write=1_000) for _ in range(20)])
        env = os.environ.copy()
        env.update(CLAUDE_CONFIG_DIR=str(self.cfg), HARNESS_WS=str(self.ws),
                   HARNESS_CTX_CEILING="900000")
        r = subprocess.run(["python3", str(SCRIPT), "check", "T1"], text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           check=False, env=env)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_presupuesto_explicito_gana(self):
        self.write([self.turn(read=1_000_000) for _ in range(20)])  # $10
        r = self.run_cost("check", "T1", "--budget", "1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("COST-BUDGET", r.stdout)

    def test_check_sin_transcripts_falla_ABIERTO(self):
        # Fail-open ante ausencia de datos: sin transcripts no se puede afirmar
        # nada, y bloquear seria mentir al reves.
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 0, r.stdout)


class Export(CostBase):
    """El formato para una base de datos: grano de AGENTE, no de tarea.

    El hallazgo que motivo todo esto fue que el 87% del gasto vive en el
    orquestador y no en los subagentes, y eso SOLO se ve con grano de agente.
    Agregar por tarea es un GROUP BY; desagregar lo agregado es imposible.
    """

    def test_una_linea_json_por_agente(self):
        self.write([self.turn(read=1_000_000) for _ in range(5)])
        subs = self.proj / self.sid / "subagents"
        subs.mkdir(parents=True)
        (subs / "agent-a.jsonl").write_text(self.turn(read=1_000_000) + "\n")
        (subs / "agent-a.meta.json").write_text(json.dumps({"agentType": "qa"}))
        r = self.run_cost("export")
        self.assertEqual(r.returncode, 0, r.stderr)
        filas = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
        self.assertEqual(len(filas), 2, "no salio una fila por agente")
        roles = {f["rol"] for f in filas}
        self.assertIn("orquestador", roles)
        self.assertIn("qa", roles)

    def test_la_fila_trae_lo_que_una_consulta_necesita(self):
        self.write([self.turn(read=1_000_000, write=1_000) for _ in range(5)])
        r = self.run_cost("export")
        fila = json.loads(r.stdout.splitlines()[0])
        for col in ("tarea", "sesion", "rol", "modelo", "turnos", "tool_calls",
                    "ctx_medio", "acierto_cache", "costo_usd", "desde", "hasta"):
            self.assertIn(col, fila, f"falta la columna {col}")
        self.assertEqual(fila["tarea"], "T1", "no atribuyo la tarea")

    def test_es_json_valido_linea_por_linea(self):
        # JSONL o no sirve: DuckDB, jq y pandas leen linea a linea.
        self.write([self.turn(read=1_000) for _ in range(3)])
        r = self.run_cost("export")
        for l in r.stdout.splitlines():
            if l.strip():
                json.loads(l)


class Atribucion(CostBase):
    def test_solo_cuenta_la_tarea_pedida(self):
        # El filtro por tarea no es azucar: sin el, un check en una transicion
        # escanearia todos los transcripts del workspace para tirar el 95%.
        otro = "ffffffff-0000-1111-2222-333333333333"
        self.write([self.turn(read=1_000_000) for _ in range(10)])          # T1
        self.write([self.turn(read=9_000_000) for _ in range(10)], sid=otro)  # sin tarea
        r = self.run_cost("task", "T1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("5.00", r.stdout, r.stdout)   # 10M x 0.50, no 100M

    def test_los_subagentes_se_atribuyen_a_la_misma_tarea(self):
        self.write([self.turn(read=1_000_000) for _ in range(5)])
        subs = self.proj / self.sid / "subagents"
        subs.mkdir(parents=True)
        (subs / "agent-abc.jsonl").write_text(
            "\n".join(self.turn(read=1_000_000) for _ in range(5)) + "\n")
        (subs / "agent-abc.meta.json").write_text(
            json.dumps({"agentType": "reviewer", "description": "reviewer:atlas"}))
        r = self.run_cost("task", "T1")
        self.assertIn("reviewer", r.stdout, r.stdout)
        self.assertIn("5.00", r.stdout, r.stdout)   # 10M totales

    def test_rol_sin_meta_no_miente(self):
        self.write([self.turn(read=1_000) for _ in range(3)])
        subs = self.proj / self.sid / "subagents"
        subs.mkdir(parents=True)
        (subs / "agent-x.jsonl").write_text(self.turn(read=1_000) + "\n")
        r = self.run_cost("task", "T1")
        self.assertIn("sin-rol", r.stdout, r.stdout)


if __name__ == "__main__":
    unittest.main()
