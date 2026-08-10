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
             ttl=None, tools=1, ts="2026-08-05T12:00:00.000Z"):
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
            "timestamp": ts,
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


class BandaConSalida(CostBase):
    """El termino que NO se puede remediar tiene que tener salida AUDITABLE.

    POR QUE ESTA SUITE (3 reportes del mismo callejon: #90, #91, #93):
    `cache_hit` y `ctx_avg` salen de transcripts de un agente que YA CERRO, o
    sea metrica historica e inmutable. La remediacion que el gate imprime
    (recortar el contexto de ARRANQUE del agente) no se puede aplicar en
    retroactivo, `budget --to` solo mueve el termino COST-BUDGET, y la unica
    salida que quedaba era HARNESS_CACHE_HIT_FLOOR: apagar el umbral sin dejar
    rastro. Una tarea con el trabajo commiteado quedaba viva e INMOVIL.

    Lo que se protege: que el eximido destrabe, que NO sea un cheque en blanco
    (algo peor vuelve a frenar), y que NUNCA sea silencioso.
    """

    def sano(self, turns=30):
        """Un orquestador dentro de banda: el breach tiene que venir del subagente."""
        self.write([self.turn(read=40_000, write=500) for _ in range(turns)])

    def subagente(self, role, turns, read, write, name="agent-uno"):
        subs = self.proj / self.sid / "subagents"
        subs.mkdir(parents=True, exist_ok=True)
        (subs / f"{name}.jsonl").write_text(
            "\n".join(self.turn(read=read, write=write) for _ in range(turns)) + "\n")
        (subs / f"{name}.meta.json").write_text(json.dumps({"agentType": role}))

    def waivers(self, *entries, phase=None):
        estado = {"cost_waivers": list(entries)}
        if phase is not None:
            estado["phase"] = phase
        (self.task / "state.json").write_text(json.dumps(estado))

    def test_sin_eximido_el_termino_historico_TRABA(self):
        # La mitad que justifica todo lo demas: sin salida, esto es permanente.
        self.sano()
        self.subagente("architect", 33, 89_000, 11_000)     # 89%, piso 90%
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("COST-CACHE", r.stdout)

    def test_el_eximido_destraba_Y_SE_DICE(self):
        self.sano()
        self.subagente("architect", 33, 89_000, 11_000)
        self.waivers({"band": "cache", "agent": "architect", "value": 0.89,
                      "actor": "humano", "reason": "subagente cerrado"})
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 0, r.stdout)
        # Un termino que deja de frenar y deja de VERSE es el mismo silencio que
        # el gate vino a matar: tiene que seguir imprimiendose con quien y por que.
        self.assertIn("EXIMIDO por humano", r.stdout, r.stdout)
        self.assertIn("subagente cerrado", r.stdout, r.stdout)
        self.assertIn("COST-CACHE", r.stdout, r.stdout)

    def test_el_eximido_se_ancla_al_valor_MEDIDO(self):
        # No es un cheque en blanco sobre la banda: cubre lo que se acepto. El
        # mismo rol cayendo mas abajo vuelve a frenar, que es lo que separa
        # "acepto este 89%" de "no me midas mas la cache de esta tarea".
        self.sano()
        self.subagente("architect", 33, 40_000, 60_000)      # 40%, mucho peor
        self.waivers({"band": "cache", "agent": "architect", "value": 0.89,
                      "actor": "humano", "reason": "subagente cerrado"})
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertNotIn("EXIMIDO", r.stdout, r.stdout)

    def test_el_eximido_CUBRE_SU_PROPIO_BREACH_pase_lo_que_pase_el_redondeo(self):
        # ISSUES #119, #122, #123, #124, #125, #126, #128: `cost-waive` decia
        # "aceptado", el eximido quedaba en state.json con EL MISMO valor que el
        # gate reportaba, y la transicion seguia frenada. Causa: el breach se
        # persiste REDONDEADO (round(cache_hit, 6)) y covered_by comparaba
        # contra la medicion CRUDA con epsilon 1e-9; cuando round() subia (la
        # mitad de los casos, por el septimo decimal) la diferencia de 5e-7 era
        # 500 veces el epsilon y el eximido no podia cubrirse a si mismo.
        #
        # La prueba es la que importa en campo y no depende de sortear decimales:
        # se toma el valor que el propio --json declara y se exime con EL. Si
        # eso no destraba, la salida auditable del gate no existe.
        self.sano()
        self.subagente("architect", 33, 89_000, 11_000)
        data = json.loads(self.run_cost("check", "T1", "--json").stdout)
        breach = next(b for b in data["breaches"] if b["code"] == "COST-CACHE")
        self.waivers({"band": "cache", "agent": "architect", "value": breach["value"],
                      "actor": "orchestrator", "reason": "el valor que el gate reporto"})
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 0,
                         "el eximido escrito con el valor que el gate REPORTA "
                         "tiene que cubrir ese mismo breach\n" + r.stdout)
        self.assertIn("EXIMIDO por orchestrator", r.stdout, r.stdout)

    def test_covered_by_no_depende_del_lado_al_que_redondee(self):
        # La misma garantia, directa sobre la funcion y en los dos sentidos del
        # redondeo, que es lo que hacia que el bug le tocara a la mitad de los
        # valores y pareciera aleatorio (#126 lo aisla asi).
        import importlib.util
        spec = importlib.util.spec_from_file_location("hc", str(SCRIPT))
        hc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hc)
        for crudo in (0.8486905, 0.8486914):       # round sube / round baja
            guardado = round(crudo, 6)
            w = [{"band": "cache", "agent": "reviewer", "value": guardado}]
            self.assertIsNotNone(hc.covered_by(w, "cache", "reviewer", crudo),
                                 f"cache crudo={crudo} guardado={guardado}")
        for crudo in (156162.6949, 156162.6851):   # idem en ctx (round a 2)
            guardado = round(crudo, 2)
            w = [{"band": "ctx", "agent": "orquestador", "value": guardado}]
            self.assertIsNotNone(hc.covered_by(w, "ctx", "orquestador", crudo),
                                 f"ctx crudo={crudo} guardado={guardado}")
        # Y lo que NO puede pasar: seguir siendo un cheque en blanco. Algo
        # PEOR que lo aceptado vuelve a frenar.
        w = [{"band": "cache", "agent": "reviewer", "value": 0.89}]
        self.assertIsNone(hc.covered_by(w, "cache", "reviewer", 0.40))

    def test_dos_agentes_del_mismo_rol_se_eximen_por_separado(self):
        # ISSUE #122: dos pasos custom corren como el mismo rol en la misma fase
        # y los dos incumplen. Cada eximido tiene su valor; el peor tiene que
        # encontrar el suyo. Antes quedaba uno vivo y la tarea trabada para
        # siempre (con el push a main YA hecho).
        self.sano()
        self.subagente("general-purpose", 33, 89_000, 11_000, name="agent-uno")
        self.subagente("general-purpose", 33, 80_000, 20_000, name="agent-dos")
        data = json.loads(self.run_cost("check", "T1", "--json").stdout)
        valores = sorted(b["value"] for b in data["breaches"] if b["code"] == "COST-CACHE")
        self.assertTrue(valores, data)
        self.waivers(*[{"band": "cache", "agent": "general-purpose", "value": v,
                        "actor": "orchestrator", "reason": f"paso custom {i}"}
                       for i, v in enumerate(valores)])
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_el_eximido_es_de_UN_rol(self):
        self.sano()
        self.subagente("implementer", 33, 89_000, 11_000)
        self.waivers({"band": "cache", "agent": "architect", "value": 0.5,
                      "actor": "humano", "reason": "otro rol"})
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)

    def test_el_ctx_tiene_la_misma_salida_y_la_misma_ancla(self):
        # Simetria: los dos terminos que no se pueden remediar en retroactivo
        # se eximen igual. Y en ctx el "peor" es al reves (mas contexto).
        self.write([self.turn(read=400_000, write=1_000) for _ in range(20)])
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        ctx = json.loads(self.run_cost("check", "T1", "--json").stdout)
        valor = next(b["value"] for b in ctx["breaches"] if b["code"] == "COST-CTX")
        self.waivers({"band": "ctx", "agent": "orquestador", "value": valor,
                      "actor": "humano", "reason": "sesion larga declarada"})
        self.assertEqual(self.run_cost("check", "T1").returncode, 0)
        self.waivers({"band": "ctx", "agent": "orquestador", "value": valor - 1,
                      "actor": "humano", "reason": "aceptado mas chico"})
        self.assertEqual(self.run_cost("check", "T1").returncode, 3,
                         "un contexto MAYOR que el aceptado tiene que volver a frenar")

    def test_el_eximido_de_ctx_atado_a_la_fase_SOBREVIVE_a_que_el_valor_crezca(self):
        # ISSUE #103: el eximido de ctx nacia VENCIDO. `cache` sale de un agente
        # que ya cerro (transcript inmutable), pero el ctx del orquestador crece
        # mientras se lo mide: lo suben las propias tool calls del waive y de la
        # transicion. Medido en campo: se autorizo 167938.23 y la medicion
        # siguiente ya daba 169k, asi que el unico escape auditable no servia
        # para el caso mas comun y quedaba HARNESS_CTX_CEILING, sin rastro.
        self.write([self.turn(read=400_000, write=1_000) for _ in range(20)])
        ctx = json.loads(self.run_cost("check", "T1", "--json").stdout)
        valor = next(b["value"] for b in ctx["breaches"] if b["code"] == "COST-CTX")
        # El waive se autoriza por MENOS de lo que ya se mide: es exactamente la
        # carrera del caso de campo, y antes de #103 esto salia 3.
        self.waivers({"band": "ctx", "agent": "orquestador", "value": valor - 5_000,
                      "phase": "implement", "actor": "humano",
                      "reason": "sesion larga declarada"}, phase="implement")
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("EXIMIDO por humano", r.stdout, r.stdout)

    def test_el_eximido_de_ctx_CADUCA_al_cambiar_de_fase(self):
        # La contra-mitad, que es la que lo separa de un cheque en blanco: vale
        # para la ventana en la que el termino se mide (la fase), ni un turno
        # mas. En la fase siguiente se vuelve a medir y a frenar.
        self.write([self.turn(read=400_000, write=1_000) for _ in range(20)])
        self.waivers({"band": "ctx", "agent": "orquestador", "value": 1,
                      "phase": "implement", "actor": "humano", "reason": "x"},
                     phase="review")
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertNotIn("EXIMIDO", r.stdout, r.stdout)

    def test_un_eximido_de_ctx_VIEJO_sigue_anclado_al_valor(self):
        # Compatibilidad: una instancia que actualiza no pierde lo que ya habia
        # autorizado. Sin `phase`, el eximido conserva la comparacion por valor.
        self.write([self.turn(read=400_000, write=1_000) for _ in range(20)])
        ctx = json.loads(self.run_cost("check", "T1", "--json").stdout)
        valor = next(b["value"] for b in ctx["breaches"] if b["code"] == "COST-CTX")
        self.waivers({"band": "ctx", "agent": "orquestador", "value": valor,
                      "actor": "humano", "reason": "viejo, sin fase"})
        self.assertEqual(self.run_cost("check", "T1").returncode, 0)
        self.waivers({"band": "ctx", "agent": "orquestador", "value": valor - 1,
                      "actor": "humano", "reason": "viejo, sin fase"})
        self.assertEqual(self.run_cost("check", "T1").returncode, 3,
                         "sin fase declarada, el ancla por valor sigue mordiendo")

    def test_la_cache_NO_se_atiene_a_la_fase(self):
        # No se toca lo que ya funcionaba: cache mide un agente CERRADO, su
        # numero no se mueve mas y el ancla por valor es lo correcto ahi. Un
        # `phase` de mas en un eximido de cache no lo convierte en permiso.
        self.sano()
        self.subagente("architect", 33, 40_000, 60_000)      # 40%, peor que 0.89
        self.waivers({"band": "cache", "agent": "architect", "value": 0.89,
                      "phase": "implement", "actor": "humano", "reason": "x"},
                     phase="implement")
        self.assertEqual(self.run_cost("check", "T1").returncode, 3)

    def test_json_para_la_maquina(self):
        # harness-policy.py cost-waive lo consume para exigir que el termino
        # EXISTA antes de dejar eximirlo: sin esto, el eximido seria una
        # declaracion sobre algo que nadie midio.
        self.sano()
        self.subagente("architect", 33, 89_000, 11_000)
        r = self.run_cost("check", "T1", "--json")
        self.assertEqual(r.returncode, 3, r.stdout)
        data = json.loads(r.stdout)
        b = [x for x in data["breaches"] if x["code"] == "COST-CACHE"]
        self.assertEqual(len(b), 1, data)
        self.assertEqual(b[0]["agent"], "architect")
        self.assertEqual(b[0]["turns"], 33)
        self.assertAlmostEqual(b[0]["value"], 0.89, places=2)
        self.assertEqual(data["min_turns_for_cache_floor"], 10)


class TechoPorRol(CostBase):
    """ISSUE #120: 150k era el MISMO numero para tres modos de uso distintos.

    Un subagente de una tarea, el ORQUESTADOR de un lote y un reviewer que el
    harness declara PERSISTENTE entre rondas arrastran contexto por razones
    distintas, y los dos ultimos lo hacen por DISENO. Medido en una sola tarea:
    6 de 6 evaluaciones de banda ctx dieron breach y las 6 se eximieron a mano.
    Un gate que se exime siempre no es un gate, es un peaje.

    Lo que se protege: que el techo sea DATO por rol, que el default no se
    mueva para nadie que no lo declare, y que estar por encima del piso general
    se SIGA VIENDO aunque no frene.
    """

    def policy(self, **por_rol):
        (self.ws / "harness-policy.json").write_text(json.dumps(
            {"schema": 1, "limits": {"ctx_ceiling_by_role": por_rol}}))

    def orquestador_pesado(self):
        # ~180k de contexto medio: por encima del piso general de 150k.
        self.write([self.turn(read=180_000, write=500) for _ in range(20)])

    def test_sin_techo_declarado_el_default_sigue_frenando(self):
        self.orquestador_pesado()
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("COST-CTX", r.stdout)

    def test_con_techo_del_rol_no_frena_pero_SE_DICE(self):
        self.orquestador_pesado()
        self.policy(orquestador=220_000)
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 0, r.stdout)
        # No frena, pero no desaparece: un termino que deja de verse es el
        # mismo silencio que el gate vino a matar.
        self.assertIn("COST-CTX", r.stdout, r.stdout)
        self.assertIn("dentro del techo declarado", r.stdout, r.stdout)

    def test_el_techo_del_rol_NO_es_un_cheque_en_blanco(self):
        # Pasarse del techo propio sigue siendo breach: lo que cambio es el
        # numero, no que exista un limite.
        self.write([self.turn(read=400_000, write=1_000) for _ in range(20)])
        self.policy(orquestador=220_000)
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)

    def test_el_techo_es_de_UN_rol(self):
        # Declarar el del reviewer no le sube el techo al orquestador.
        self.orquestador_pesado()
        self.policy(reviewer=220_000)
        self.assertEqual(self.run_cost("check", "T1").returncode, 3)

    def test_el_override_por_entorno_sigue_mandando_sobre_todo(self):
        self.orquestador_pesado()
        self.policy(orquestador=220_000)
        env = dict(os.environ, HARNESS_CTX_CEILING="100000",
                   CLAUDE_CONFIG_DIR=str(self.cfg), HARNESS_WS=str(self.ws))
        r = subprocess.run(["python3", str(SCRIPT), "check", "T1"], text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.assertEqual(r.returncode, 3, r.stdout)


class PisoAlcanzable(CostBase):
    """El piso de cache no se le puede cobrar a un agente CORTO.

    El mejor caso posible para un agente de T turnos es escribir su contexto UNA
    vez y leerlo en los T-1 restantes: hit_max = (T-1)/T. Si esa COTA SUPERIOR
    ya esta por debajo del piso, el agente no podia aprobarlo hiciera lo que
    hiciera, y el breach no dice nada de su conducta: mide la ventana de cache.
    """

    def subagente(self, role, turns, read, write):
        subs = self.proj / self.sid / "subagents"
        subs.mkdir(parents=True, exist_ok=True)
        (subs / "agent-corto.jsonl").write_text(
            "\n".join(self.turn(read=read, write=write) for _ in range(turns)) + "\n")
        (subs / "agent-corto.meta.json").write_text(json.dumps({"agentType": role}))

    def test_agente_corto_NO_frena_pero_se_DECLARA(self):
        self.write([self.turn(read=40_000, write=500) for _ in range(30)])
        self.subagente("implementer", 4, 10_000, 90_000)     # 10% en 4 turnos
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("NO se evalúa", r.stdout, r.stdout)
        self.assertIn("máximo alcanzable", r.stdout, r.stdout)

    def test_un_agente_LARGO_bajo_el_piso_sigue_frenando(self):
        # CONTRA-MITAD: el arreglo del falso positivo no puede apagar el gate.
        # 33 turnos admiten hasta 97%, asi que 89% SI es una afirmacion sobre
        # como corrio ese agente.
        self.write([self.turn(read=40_000, write=500) for _ in range(30)])
        self.subagente("implementer", 33, 89_000, 11_000)
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertNotIn("NO se evalúa", r.stdout, r.stdout)

    def test_el_minimo_SALE_del_piso_no_es_un_numero_elegido(self):
        # Con el piso en 95% hacen falta 20 turnos; el mismo agente de 15 turnos
        # se evalua con el piso de fabrica (10) y no con el de 95%.
        self.write([self.turn(read=40_000, write=500) for _ in range(30)])
        self.subagente("implementer", 15, 80_000, 20_000)    # 80% en 15 turnos
        self.assertEqual(self.run_cost("check", "T1").returncode, 3,
                         "piso 90%: 15 turnos admiten 93%, o sea que 80% es real")
        env = os.environ.copy()
        env.update(CLAUDE_CONFIG_DIR=str(self.cfg), HARNESS_WS=str(self.ws),
                   HARNESS_CACHE_HIT_FLOOR="0.95")
        r = subprocess.run(["python3", str(SCRIPT), "check", "T1", "--json"],
                           text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, check=False, env=env)
        data = json.loads(r.stdout)
        self.assertEqual(data["min_turns_for_cache_floor"], 20, data)
        self.assertTrue(any(u["agent"] == "implementer"
                            for u in data["unmeasurable"]), data)


class Ventana(CostBase):
    """Las bandas de TASA miden la fase en curso; el gasto mide toda la tarea.

    POR QUE (issue #95): `cache_hit` y `ctx_avg` son promedios sobre
    transcripts inmutables. Sin ventana, el primer agente que cierra bajo el
    piso cobra su peaje en TODA transicion futura de la tarea, y la remediacion
    que el gate imprime (recortar el contexto de ARRANQUE) solo puede afectar a
    agentes que todavia no corrieron: el gate frenaba por algo que ninguna
    conducta futura podia mover. El caso de campo fueron dos abogados de RFC de
    una sola respuesta que congelaron una tarea con 94.4% de acierto global.

    Lo que se protege aca: que la ventana ACOTE sin APAGAR, que lo que queda
    afuera se DIGA, y que los dolares no se ventanen (son acumulativos: son el
    bolsillo, no una tasa que alguien pueda mejorar).
    """

    VIEJO = "2026-08-01T09:00:00.000Z"
    NUEVO = "2026-08-05T12:00:00.000Z"
    FASE = "2026-08-04T00:00:00Z"          # entre los dos

    def estado(self, **campos):
        (self.task / "state.json").write_text(json.dumps(campos))

    def orquestador_sano(self, ts=None):
        self.write([self.turn(read=40_000, write=500, ts=ts or self.NUEVO)
                    for _ in range(30)])

    def subagente(self, role, turns, read, write, ts, name="agent-uno"):
        subs = self.proj / self.sid / "subagents"
        subs.mkdir(parents=True, exist_ok=True)
        (subs / f"{name}.jsonl").write_text(
            "\n".join(self.turn(read=read, write=write, ts=ts)
                      for _ in range(turns)) + "\n")
        (subs / f"{name}.meta.json").write_text(json.dumps({"agentType": role}))

    def test_el_agente_de_una_fase_anterior_NO_frena_y_se_DICE(self):
        self.orquestador_sano()
        self.subagente("architect", 33, 89_000, 11_000, ts=self.VIEJO)
        self.estado(phase_since=self.FASE)
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 0, r.stdout)
        # Un termino que deja de frenar y deja de verse es el mismo silencio
        # que el gate vino a matar.
        self.assertIn("fuera de la ventana", r.stdout, r.stdout)
        self.assertIn("architect", r.stdout, r.stdout)

    def test_el_agente_de_ESTA_fase_sigue_frenando(self):
        # CONTRA-MITAD: la ventana acota el gate, no lo apaga.
        self.orquestador_sano()
        self.subagente("architect", 33, 89_000, 11_000, ts=self.NUEVO)
        self.estado(phase_since=self.FASE)
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("COST-CACHE", r.stdout, r.stdout)

    def test_el_gasto_en_dolares_NO_se_ventana(self):
        # Los dolares son acumulativos: recortarlos a la fase en curso haria
        # que una tarea cara pasara por barata cada vez que avanza de fase.
        self.write([self.turn(read=1_000_000, ts=self.VIEJO) for _ in range(20)])
        self.estado(phase_since=self.FASE, budget_usd=1.0)
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("COST-BUDGET", r.stdout, r.stdout)

    def test_una_ventana_corta_no_inventa_un_breach_de_cache(self):
        # El minimo de turnos se cobra sobre los turnos DE LA VENTANA: si en la
        # fase en curso solo hubo 4, el maximo alcanzable es 75% y el piso
        # mediria la ventana de cache y no el derroche.
        self.orquestador_sano()
        # UN solo agente que viene de la fase anterior (40 turnos) y ya lleva 4
        # en esta: lo que se evalua son esos 4, no los 44.
        subs = self.proj / self.sid / "subagents"
        subs.mkdir(parents=True, exist_ok=True)
        lineas = [self.turn(read=10_000, write=90_000, ts=self.VIEJO)
                  for _ in range(40)]
        lineas += [self.turn(read=10_000, write=90_000, ts=self.NUEVO)
                   for _ in range(4)]
        (subs / "agent-uno.jsonl").write_text("\n".join(lineas) + "\n")
        (subs / "agent-uno.meta.json").write_text(
            json.dumps({"agentType": "implementer"}))
        self.estado(phase_since=self.FASE)
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("NO se evalúa", r.stdout, r.stdout)

    def test_sin_phase_since_mide_toda_la_historia(self):
        # Compatibilidad: una tarea creada antes de la ventana no puede quedar
        # sin gate. Se mide todo, y se DICE que no hay ventana.
        self.orquestador_sano()
        self.subagente("architect", 33, 89_000, 11_000, ts=self.VIEJO)
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("sin ventana", r.stdout, r.stdout)

    def test_la_ventana_ilegible_se_declara_y_no_apaga_el_gate(self):
        # Fail-CLOSED ante datos malos: un phase_since roto no puede volverse
        # un apagador silencioso del umbral.
        self.orquestador_sano()
        self.subagente("architect", 33, 89_000, 11_000, ts=self.VIEJO)
        self.estado(phase_since="ayer por la tarde")
        r = self.run_cost("check", "T1")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("ventana ilegible", r.stdout, r.stdout)

    def test_since_explicito_manda_sobre_el_estado(self):
        self.orquestador_sano()
        self.subagente("architect", 33, 89_000, 11_000, ts=self.NUEVO)
        self.estado(phase_since=self.FASE)
        self.assertEqual(self.run_cost("check", "T1").returncode, 3)
        r = self.run_cost("check", "T1", "--since", "2026-08-06T00:00:00Z")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_el_json_lleva_la_ventana_y_lo_que_quedo_afuera(self):
        # Lo consume harness-policy.py cost-waive: si el termino no viaja, el
        # eximido se pediria sobre algo que el gate ya no evalua.
        self.orquestador_sano()
        self.subagente("architect", 33, 89_000, 11_000, ts=self.VIEJO)
        self.estado(phase_since=self.FASE)
        data = json.loads(self.run_cost("check", "T1", "--json").stdout)
        self.assertEqual(data["window"], self.FASE, data)
        self.assertEqual(data["breaches"], [], data)
        self.assertTrue(any(o["agent"] == "architect" for o in data["outside"]),
                        data)


if __name__ == "__main__":
    unittest.main()
