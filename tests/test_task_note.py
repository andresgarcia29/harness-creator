#!/usr/bin/env python3
"""test_task_note.py: la nota que sobrevive a la tarea, o no sobrevive nada.

POR QUE ESTA SUITE: `tasks/` esta gitignoreado, asi que TODO lo que una tarea
produce (ledger, enrichment, veredictos, history[]) muere con la maquina. Con N
ingenieros son N maquinas y cero aprendizaje compartido. Esta nota es lo unico
que cruza esa frontera, asi que sus dos propiedades son load-bearing:

  1. Lo VERIFICABLE sale de artefactos, no del modelo. Un campo verificable que
     escribe el modelo es un campo que puede mentir sin que nada lo note (misma
     razon por la que verdict-scaffold.sh existe).
  2. Lo de JUICIO queda MARCADO. Una nota que se archiva con los placeholders
     puestos tiene que dar verguenza, no pasar desapercibida.

Y una tercera que es de seguridad: se versiona, asi que la ley de secretos del
bus aplica igual.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "templates/scripts/task-note.py"


class TaskNoteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self.tmp.name)
        self.task = self.ws / "tasks" / "T1"
        self.task.mkdir(parents=True)
        (self.ws / "scripts").mkdir()
        (self.task / "task.md").write_text("---\ntitle: Poner el logo\n---\n")
        (self.task / "state.json").write_text(json.dumps({
            "lane": "standard", "repos": ["atlas", "hermes"],
            "review_rounds": 2, "review_rounds_by_repo": {"atlas": 1, "hermes": 2},
            "history": [
                {"kind": "phase", "phase": "implement"},
                {"kind": "budget", "budget_usd": "10→50", "actor": "humano",
                 "reason": "el sondeo justifica el gasto"},
            ]}))

    def tearDown(self):
        self.tmp.cleanup()

    def run_note(self, *args):
        env = os.environ.copy()
        env["HARNESS_WS"] = str(self.ws)
        return subprocess.run(["python3", str(SCRIPT), "T1", *args],
                              text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False, env=env)

    def nota(self):
        r = self.run_note("--stdout")
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    # ── lo verificable sale de artefactos ────────────────────────────────
    def test_el_frontmatter_sale_del_estado(self):
        n = self.nota()
        self.assertIn("carril: standard", n)
        self.assertIn("repos: [atlas, hermes]", n)
        self.assertIn("rondas_review: 2", n)
        self.assertIn("titulo: Poner el logo", n)

    def test_el_ledger_separa_lo_medido_de_lo_asumido(self):
        # Es la distincion que hace util la nota para /promote: un supuesto de
        # ENTORNO que nadie midio es el que mas caro sale cuando resulta falso.
        (self.task / "assumptions.md").write_text(
            "- SUPUESTO-ENTORNO: degrada limpio · PORQUE: es lo habitual\n"
            "- SUPUESTO-ENTORNO: respeta max-width · PORQUE: EV-TEST-abc123\n"
            "- SUPUESTO: va a la izquierda · PORQUE: convencion del repo\n")
        n = self.nota()
        self.assertIn("(entorno SIN medir) SUPUESTO-ENTORNO: degrada limpio", n)
        self.assertIn("(medido) SUPUESTO-ENTORNO: respeta max-width", n)
        self.assertIn("(asumido) SUPUESTO: va a la izquierda", n)
        self.assertIn("/promote", n, "no explica para que sirve la distincion")

    def test_los_veredictos_traen_los_tardios(self):
        # Los [tardio] son la metrica que dice si el plan estuvo bien hecho.
        (self.task / "verdict-atlas.json").write_text(json.dumps({
            "repo": "atlas", "verdict": "pass", "qa": "pass",
            "blocking": ["[tardío] falta alt en el img"],
            "requirements_uncovered": 0}))
        n = self.nota()
        self.assertIn("[[repo/atlas]]", n, "sin wikilink no hay grafo")
        self.assertIn("| pass |", n)
        self.assertRegex(n, r"\|\s*1\s*\|\s*1\s*\|", "no conto el tardio")

    def test_las_decisiones_salen_de_history(self):
        n = self.nota()
        self.assertIn("`budget` 10→50 (autoriza humano)", n)
        self.assertIn("el sondeo justifica el gasto", n)

    def test_los_movimientos_de_fase_no_ensucian_la_nota(self):
        # history[] trae cada transicion; para la nota son ruido.
        self.assertNotIn("implement", self.nota().split("## Decisiones")[1]
                         .split("## ")[0])

    def test_los_hallazgos_difundidos_entran(self):
        (self.task / "findings.jsonl").write_text(json.dumps(
            {"repo": "atlas", "text": "el guard de Helm pide charts/ plural"}) + "\n")
        self.assertIn("el guard de Helm pide charts/ plural", self.nota())

    # ── lo de juicio queda MARCADO ───────────────────────────────────────
    def test_los_campos_de_juicio_quedan_visibles(self):
        n = self.nota()
        for campo in ("Qué se pidió", "problema real", "Sorpresas", "Enlaces"):
            self.assertIn(campo, n, f"falta la seccion {campo}")
        self.assertGreaterEqual(n.count("<!-- COMPLETAR:"), 4,
                                "los campos de juicio no quedaron marcados")

    def test_no_inventa_lo_que_no_puede_saber(self):
        # Sin bascula no hay costo: n/d, no un cero que parece medido.
        self.assertIn("costo_usd: n/d", self.nota())

    # ── seguridad y operacion ────────────────────────────────────────────
    def test_redacta_secretos(self):
        # Se versiona, asi que la ley de secretos del bus aplica igual.
        (self.task / "findings.jsonl").write_text(json.dumps(
            {"repo": "atlas",
             "text": "revienta con ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}) + "\n")
        n = self.nota()
        self.assertNotIn("ghp_aaaaaaaaaaaa", n)
        self.assertIn("REDACTADO", n)

    def test_escribe_en_docs_versionado(self):
        r = self.run_note()
        self.assertEqual(r.returncode, 0, r.stderr)
        out = self.ws / "docs" / "tareas" / "T1.md"
        self.assertTrue(out.is_file(), "no escribio en docs/tareas/")

    def test_no_pisa_una_nota_ya_completada(self):
        # Regenerar volveria a poner los placeholders y borraria el juicio, que
        # es justo lo unico que no se puede reconstruir de los artefactos.
        self.run_note()
        out = self.ws / "docs" / "tareas" / "T1.md"
        out.write_text("# ya la complete a mano\ncon mi juicio adentro\n")
        r = self.run_note()
        self.assertEqual(r.returncode, 0)
        self.assertIn("ya la complete a mano", out.read_text(),
                      "piso una nota que ya tenia juicio escrito")
        self.assertIn("no la piso", r.stdout)

    def test_encuentra_la_tarea_ya_archivada(self):
        # /archive mueve los artefactos: la nota tiene que poder generarse igual.
        arch = self.ws / "tasks" / "archive" / "2026-08-05-T1"
        arch.mkdir(parents=True)
        for f in self.task.iterdir():
            f.rename(arch / f.name)
        self.task.rmdir()
        self.assertIn("carril: standard", self.nota())

    def test_tarea_inexistente_no_inventa_una_nota(self):
        env = os.environ.copy()
        env["HARNESS_WS"] = str(self.ws)
        r = subprocess.run(["python3", str(SCRIPT), "NO-EXISTE", "--stdout"],
                           text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, check=False, env=env)
        self.assertEqual(r.returncode, 3)


if __name__ == "__main__":
    unittest.main()
