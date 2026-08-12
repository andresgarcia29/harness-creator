#!/usr/bin/env python3
"""test_harness_sink.py: el destino de los datos, y sobre todo su honestidad.

POR QUE ESTA SUITE: `setup` configura un destino que despues corre en `/archive`
sin nadie mirando. Las dos formas de que eso salga mal son caras y silenciosas:

  1. Configurar sin PROBAR. Un setup que acepta un DSN porque parece un DSN te
     deja creyendo que quedo configurado, y te enteras recien al archivar. Por
     eso `setup` conecta de verdad y DESACTIVA si no puede.
  2. Perder el archivado por una base caida. El archivo es el piso y se escribe
     siempre; Postgres es opcional y su fallo AVISA, no frena.

Y una tercera, de seguridad: el config se versiona, asi que la contraseña no
puede entrar ahi ni por accidente.
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
SINK = ROOT / "templates/scripts/harness-sink.py"
COST = ROOT / "templates/scripts/harness-cost.py"
PRICING = ROOT / "templates/ui/pricing.json"


class SinkBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ws = (Path(self.tmp.name) / "ws").resolve()
        (self.ws / "scripts" / "ui").mkdir(parents=True)
        (self.ws / "tasks" / "COR-42").mkdir(parents=True)
        for f in (SINK, COST):
            (self.ws / "scripts" / f.name).write_text(f.read_text())
        (self.ws / "scripts" / "ui" / "pricing.json").write_text(PRICING.read_text())
        (self.ws / "tasks" / "COR-42" / "state.json").write_text(json.dumps(
            {"lane": "express", "repos": ["atlas"], "review_rounds": 1}))
        self.sid = "abcdef00-1111-2222-3333-444444444444"
        st = self.ws / ".harness" / "session-task"
        st.mkdir(parents=True)
        (st / self.sid).write_text("COR-42\n")
        self.cfg = Path(self.tmp.name) / "cfg"
        slug = re.sub(r"[^a-zA-Z0-9]", "-", str(self.ws))
        self.proj = self.cfg / "projects" / slug
        self.proj.mkdir(parents=True)
        turn = json.dumps({
            "type": "assistant", "cwd": str(self.ws),
            "timestamp": "2026-08-06T10:00:00.000Z",
            "message": {"role": "assistant", "model": "claude-opus-5",
                        "usage": {"input_tokens": 0,
                                  "cache_read_input_tokens": 2_000_000,
                                  "cache_creation_input_tokens": 50_000,
                                  "output_tokens": 20_000},
                        "content": [{"type": "tool_use", "id": "t",
                                     "name": "Bash", "input": {}}]}})
        (self.proj / f"{self.sid}.jsonl").write_text("\n".join([turn] * 30) + "\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_sink(self, *args, stdin="", env_extra=None):
        env = os.environ.copy()
        env["CLAUDE_CONFIG_DIR"] = str(self.cfg)
        env.pop("HARNESS_SINK_DSN", None)
        if env_extra:
            env.update(env_extra)
        return subprocess.run(
            ["python3", str(self.ws / "scripts" / "harness-sink.py"),
             "--ws", str(self.ws), *map(str, args)],
            input=stdin, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=False, env=env)

    def conf(self):
        return json.loads((self.ws / "metrics-sink.json").read_text())


class Setup(SinkBase):
    def test_el_archivo_no_se_puede_desactivar(self):
        # Es el piso: si se pudiera apagar, un workspace mal configurado no
        # dejaria rastro de gasto en ningun lado.
        self.run_sink("setup", stdin="docs/metrics\nn\nn\n")
        self.assertTrue(self.conf()["archivo"]["enabled"])

    def test_postgres_sin_variable_de_entorno_queda_DESACTIVADO(self):
        # Configurar sin poder probar es como te enteras del problema recien al
        # archivar. Se desactiva y se dice por que.
        r = self.run_sink("setup", stdin="docs/metrics\nn\ns\nMI_DSN\nharness_costos\n")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertFalse(self.conf()["postgres"]["enabled"])
        self.assertIn("NO puedo probar", r.stdout)
        # Y conserva lo que el humano ya contesto, para no repreguntarlo.
        self.assertEqual(self.conf()["postgres"]["dsn_env"], "MI_DSN")

    def test_postgres_con_dsn_que_no_conecta_queda_DESACTIVADO(self):
        r = self.run_sink("setup", stdin="docs/metrics\nn\ns\nMI_DSN\nharness_costos\n",
                          env_extra={"MI_DSN": "postgresql://nadie@127.0.0.1:59999/nada"})
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertFalse(self.conf()["postgres"]["enabled"])
        self.assertIn("no conecté", r.stdout)

    def test_la_contrasena_JAMAS_entra_al_config(self):
        # El config se versiona. Un DSN con password adentro es el accidente que
        # gitleaks existe para cazar, y no lo vamos a plantar nosotros.
        secreto = "postgresql://user:SUPERSECRETO@127.0.0.1:59999/db"
        self.run_sink("setup", stdin="docs/metrics\nn\ns\nMI_DSN\nharness_costos\n",
                      env_extra={"MI_DSN": secreto})
        raw = (self.ws / "metrics-sink.json").read_text()
        self.assertNotIn("SUPERSECRETO", raw)
        self.assertNotIn("postgresql://", raw)
        self.assertIn("MI_DSN", raw, "tiene que guardar el NOMBRE de la variable")

    def test_rechaza_un_nombre_de_tabla_que_no_es_identificador(self):
        r = self.run_sink("setup", stdin='docs/metrics\nn\ns\nMI_DSN\ntabla; DROP TABLE x\n')
        self.assertEqual(r.returncode, 3)
        self.assertIn("identificador válido", r.stdout)


class Push(SinkBase):
    def setup_ok(self, linear=True):
        stdin = ("docs/metrics\n" +
                 ("s\nhttps://linear.app/corvux/issue\n" if linear else "n\n") +
                 "n\n")
        self.run_sink("setup", stdin=stdin)

    def test_escribe_una_linea_por_agente_con_el_contexto_de_la_tarea(self):
        self.setup_ok()
        r = self.run_sink("push", "COR-42")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = self.ws / "docs" / "metrics" / "COR-42.jsonl"
        self.assertTrue(out.is_file())
        fila = json.loads(out.read_text().splitlines()[0])
        self.assertEqual(fila["tarea"], "COR-42")
        self.assertEqual(fila["carril"], "express", "no trajo el carril del estado")
        self.assertEqual(fila["repos"], ["atlas"])
        self.assertEqual(fila["rondas_review"], 1)
        self.assertGreater(fila["costo_usd"], 0, "no calculo el costo")

    def test_el_link_de_linear_sale_del_id_del_ticket(self):
        self.setup_ok()
        self.run_sink("push", "COR-42")
        fila = json.loads((self.ws / "docs/metrics/COR-42.jsonl")
                          .read_text().splitlines()[0])
        self.assertEqual(fila["linear_url"],
                         "https://linear.app/corvux/issue/COR-42")

    def test_una_tarea_de_prompt_no_inventa_una_url(self):
        # Las `AUTO-...` nacen de un prompt y NO tienen ticket. Una URL que da
        # 404 es peor que un campo nulo.
        self.setup_ok()
        (self.ws / "tasks" / "AUTO-20260806-x").mkdir()
        (self.ws / "tasks" / "AUTO-20260806-x" / "state.json").write_text("{}")
        (self.ws / ".harness" / "session-task" / self.sid).write_text("AUTO-20260806-x\n")
        self.run_sink("push", "AUTO-20260806-x")
        fila = json.loads((self.ws / "docs/metrics/AUTO-20260806-x.jsonl")
                          .read_text().splitlines()[0])
        self.assertIsNone(fila["linear_url"])

    def test_sin_linear_configurado_el_campo_va_nulo(self):
        self.setup_ok(linear=False)
        self.run_sink("push", "COR-42")
        fila = json.loads((self.ws / "docs/metrics/COR-42.jsonl")
                          .read_text().splitlines()[0])
        self.assertIsNone(fila["linear_url"])

    def test_es_jsonl_valido(self):
        self.setup_ok()
        self.run_sink("push", "COR-42")
        for l in (self.ws / "docs/metrics/COR-42.jsonl").read_text().splitlines():
            if l.strip():
                json.loads(l)

    def test_re_exportar_no_duplica(self):
        # El archivo se REESCRIBE, no se appendea: correr push dos veces no
        # puede doblar el gasto reportado.
        self.setup_ok()
        self.run_sink("push", "COR-42")
        self.run_sink("push", "COR-42")
        lineas = [l for l in (self.ws / "docs/metrics/COR-42.jsonl")
                  .read_text().splitlines() if l.strip()]
        self.assertEqual(len(lineas), 1)

    def test_postgres_caido_NO_frena_el_archivado(self):
        # El peor canje posible seria perder el archivado por una base caida.
        # El archivo ya quedo escrito; esto avisa y sale 0.
        self.setup_ok()
        cfg = self.conf()
        cfg["postgres"] = {"enabled": True, "dsn_env": "MI_DSN",
                           "tabla": "harness_costos"}
        (self.ws / "metrics-sink.json").write_text(json.dumps(cfg))
        r = self.run_sink("push", "COR-42",
                          env_extra={"MI_DSN": "postgresql://nadie@127.0.0.1:59999/nada"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue((self.ws / "docs/metrics/COR-42.jsonl").is_file(),
                        "perdio el archivo por culpa de la base")

    def test_con_el_puntero_borrado_sigue_habiendo_filas(self):
        # El síntoma hermano de #153: SessionEnd borra .harness/session-task/<sid>,
        # así que al archivar (que es JUSTO cuando se hace el push) el puente ya
        # no existía y el sink daba "sin filas" para todas. El transcript sí dice
        # la tarea, y es inmutable.
        self.setup_ok()
        toca = json.dumps({
            "type": "user",
            "message": {"role": "user", "content": [
                {"type": "tool_result",
                 "content": "worktrees/COR-42/atlas/internal/server.go"}]}})
        p = self.proj / f"{self.sid}.jsonl"
        p.write_text(p.read_text() + "\n".join([toca] * 10) + "\n")
        (self.ws / ".harness" / "session-task" / self.sid).unlink()
        r = self.run_sink("push", "COR-42")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        out = self.ws / "docs" / "metrics" / "COR-42.jsonl"
        self.assertTrue(out.is_file(), r.stdout + r.stderr)
        self.assertEqual(json.loads(out.read_text().splitlines()[0])["tarea"], "COR-42")

    def test_tarea_sin_transcripts_no_frena_el_archivado(self):
        self.setup_ok()
        (self.ws / "tasks" / "SIN-DATOS").mkdir()
        r = self.run_sink("push", "SIN-DATOS")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("track-read", r.stdout, "no explica por que no hay filas")


class Ddl(SinkBase):
    def test_el_ddl_usa_la_tabla_configurada(self):
        self.run_sink("setup", stdin="docs/metrics\nn\nn\n")
        r = self.run_sink("ddl")
        self.assertIn("CREATE TABLE IF NOT EXISTS harness_costos", r.stdout)

    def test_la_clave_primaria_es_sesion_rol(self):
        # Re-exportar tiene que ACTUALIZAR, no duplicar: sin esta clave, correr
        # push dos veces dobla el gasto en la base.
        r = self.run_sink("ddl")
        self.assertIn("PRIMARY KEY (sesion, rol)", r.stdout)

    def test_el_ddl_trae_las_columnas_que_las_consultas_necesitan(self):
        r = self.run_sink("ddl")
        for col in ("carril", "repos", "costo_usd", "acierto_cache",
                    "rondas_review", "linear_url", "ctx_medio"):
            self.assertIn(col, r.stdout, f"falta la columna {col}")


class Check(SinkBase):
    def test_sin_config_lo_dice(self):
        r = self.run_sink("check")
        self.assertEqual(r.returncode, 3)
        self.assertIn("setup", r.stderr)

    def test_con_postgres_activo_y_sin_variable_falla(self):
        self.run_sink("setup", stdin="docs/metrics\nn\nn\n")
        cfg = self.conf()
        cfg["postgres"] = {"enabled": True, "dsn_env": "MI_DSN", "tabla": "t"}
        (self.ws / "metrics-sink.json").write_text(json.dumps(cfg))
        r = self.run_sink("check")
        self.assertEqual(r.returncode, 3)
        self.assertIn("with-secrets", r.stdout, "no dice por dónde va el secreto")


if __name__ == "__main__":
    unittest.main()
