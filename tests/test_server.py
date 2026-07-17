#!/usr/bin/env python3
"""test_server.py — la lógica del panel (server.py) sin red y sin claude real.

Lo que protege cada bloque:
  · cost():        ADR-0004 — un modelo sin precio cuesta None, jamás "lo que Opus".
  · redact():      la ley de secretos aplica al bus también desde Python.
  · scan_events(): ok llega como string desde hooks y como bool desde el bus —
                   un solo tipo aguas adentro.
  · op_task():     valida, escribe task.md con el frontmatter que /auto respeta,
                   deduplica ids, y lanza con --session-id conocido.
  · op_respond():  reanuda LA sesión pedida y mapea la tarea desde runs.jsonl.
  · op_connect():  valida contra el proveedor ANTES de guardar; guarda 0600;
                   un 401 del proveedor es un error honesto, no un guardado.
  · op_sync_prices(): solo cotiza lo observado sin precio; sin inventar dinero.
"""
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import unittest
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# CONFIG_DIR se decide al importar: apuntarlo a un tmp ANTES del import
_CFG = tempfile.mkdtemp(prefix='harness-test-cfg-')
os.environ['HARNESS_CONFIG_DIR'] = _CFG

spec = importlib.util.spec_from_file_location(
    'panel', os.path.join(ROOT, 'templates', 'ui', 'server.py'))
panel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(panel)


def usage(inp=0, out=0, cc=0, cr=0):
    return {'in': inp, 'out': out, 'cache_creation': cc, 'cache_read': cr}


class Base(unittest.TestCase):
    def setUp(self):
        self.ws = tempfile.mkdtemp(prefix='harness-test-ws-')
        self.state = panel.State(self.ws)
        # limpiar tokens entre tests: connections() es global al CONFIG_DIR
        for f in os.listdir(_CFG):
            os.unlink(os.path.join(_CFG, f))

    def launches(self):
        """Sustituye _launch por un espía. Devuelve la lista de lanzamientos."""
        calls = []
        self.state._launch = lambda args, logname: calls.append(args) or 4242
        return calls

    def bus(self):
        try:
            with open(os.path.join(self.ws, '.harness', 'events.jsonl')) as fh:
                return [json.loads(l) for l in fh]
        except OSError:
            return []


class TestCost(Base):
    def test_modelo_sin_precio_es_none(self):
        # ADR-0004: GLM sin precio NO se factura como Opus
        self.assertIsNone(self.state.cost('glm-4.7', usage(inp=1_000_000)))

    def test_modelo_conocido_cotiza(self):
        c = self.state.cost('claude-sonnet-5', usage(inp=1_000_000, out=1_000_000))
        self.assertAlmostEqual(c, 3.0 + 15.0)

    def test_cache_pondera(self):
        base = self.state.cost('claude-sonnet-5', usage(inp=1_000_000))
        leida = self.state.cost('claude-sonnet-5', usage(cr=1_000_000))
        self.assertLess(leida, base)   # cache read ~0.1x


class TestRedact(unittest.TestCase):
    def test_redacta_tokens(self):
        s = panel.redact('corrí con ghp_0123456789012345678901234567 y sk-abcdefghijklmnopqrstuvwxyz')
        self.assertNotIn('ghp_0123456789', s)
        self.assertNotIn('sk-abcdefghijkl', s)
        self.assertIn('REDACT', s.upper())


class TestScanEvents(Base):
    def test_ok_string_se_normaliza_a_bool(self):
        os.makedirs(os.path.join(self.ws, '.harness'))
        with open(os.path.join(self.ws, '.harness', 'events.jsonl'), 'w') as fh:
            fh.write(json.dumps({'ts': '2026-07-17T00:00:00Z', 'kind': 'gate',
                                 'summary': 'x', 'ok': 'false'}) + '\n')
            fh.write(json.dumps({'ts': '2026-07-17T00:00:01Z', 'kind': 'gate',
                                 'summary': 'y', 'ok': True}) + '\n')
        self.state.scan_events()
        self.assertIs(self.state.events[0]['ok'], False)
        self.assertIs(self.state.events[1]['ok'], True)


class TestOpTask(Base):
    def test_valida_titulo(self):
        with self.assertRaises(ValueError):
            self.state.op_task({'title': '  '})

    def test_valida_ticket(self):
        with self.assertRaises(ValueError):
            self.state.op_task({'origin': 'ticket', 'ticket': ''})

    def test_crea_taskmd_y_lanza_con_session_conocida(self):
        calls = self.launches()
        r = self.state.op_task({'title': 'Rate limiting por tenant',
                                'context': '100 req/min', 'priority': 'P1',
                                'max_parallel': 2, 'review_before_ship': True,
                                'model': 'claude-sonnet-5'})
        md = open(os.path.join(self.ws, 'tasks', r['id'], 'task.md')).read()
        for esperado in ('source: panel', 'priority: P1', 'max_parallel: 2',
                         'review_before_ship: true',
                         'preferred_model: claude-sonnet-5', '100 req/min'):
            self.assertIn(esperado, md)
        self.assertEqual(calls[0][:2], ['-p', '/auto %s' % r['id']])
        self.assertIn('--session-id', calls[0])
        self.assertIn(r['session'], calls[0])          # sesión CONOCIDA de antemano
        self.assertIn('--model', calls[0])
        self.assertEqual(self.bus()[-1]['kind'], 'phase')
        self.assertEqual(self.bus()[-1]['task'], r['id'])

    def test_max_parallel_se_acota_1_a_12(self):
        self.launches()
        r = self.state.op_task({'title': 'a b c', 'max_parallel': 99})
        self.assertIn('max_parallel: 12',
                      open(os.path.join(self.ws, 'tasks', r['id'], 'task.md')).read())

    def test_ids_no_chocan(self):
        self.launches()
        a = self.state.op_task({'title': 'misma cosa'})
        b = self.state.op_task({'title': 'misma cosa'})
        self.assertNotEqual(a['id'], b['id'])

    def test_ticket_usa_el_id_del_ticket(self):
        calls = self.launches()
        r = self.state.op_task({'origin': 'ticket', 'ticket': 'COR-77'})
        self.assertEqual(r['id'], 'COR-77')
        self.assertEqual(calls[0][1], '/auto COR-77')


class TestOpRespond(Base):
    def test_valida(self):
        with self.assertRaises(ValueError):
            self.state.op_respond({'session': '', 'text': 'hola'})

    def test_reanuda_y_mapea_tarea(self):
        calls = self.launches()
        t = self.state.op_task({'title': 'algo que hacer'})
        self.state.op_respond({'session': t['session'], 'text': 'usa Redis'})
        self.assertEqual(calls[-1], ['-p', 'usa Redis', '--resume', t['session']])
        ev = self.bus()[-1]
        self.assertEqual(ev['kind'], 'decision')
        self.assertEqual(ev['task'], t['id'])          # la respuesta se atribuye a SU tarea


class FakeHTTP:
    """Doble de urllib.request.urlopen: el test decide qué contesta la red."""
    def __init__(self, status=200, body=b'{}'):
        self.status, self.body = status, body
    def __call__(self, req, timeout=None):
        self.req = req
        if self.status >= 400:
            raise urllib.error.HTTPError(req.full_url, self.status, 'x', {}, io.BytesIO())
        return self
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def read(self): return self.body


class TestOpConnect(Base):
    def test_proveedor_desconocido(self):
        with self.assertRaises(ValueError):
            self.state.op_connect({'provider': 'github', 'token': 'x'})

    def test_token_invalido_no_se_guarda(self):
        panel.urllib.request.urlopen = FakeHTTP(status=401)
        with self.assertRaises(ValueError) as cm:
            self.state.op_connect({'provider': 'linear', 'token': 'lin_api_FAKE'})
        self.assertIn('401', str(cm.exception))       # error honesto, con el código
        self.assertFalse(self.state.connections()['linear'])

    def test_token_valido_se_guarda_0600(self):
        panel.urllib.request.urlopen = FakeHTTP(status=200)
        r = self.state.op_connect({'provider': 'openrouter', 'token': 'sk-or-abc'})
        self.assertTrue(r['connected'])
        path = os.path.join(_CFG, 'openrouter-token')
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        # connections() dice PRESENCIA, jamás el valor
        self.assertEqual(self.state.connections(),
                         {'linear': False, 'openrouter': True})


class TestSyncPrices(Base):
    def test_sin_modelos_sin_precio_es_honesto(self):
        r = self.state.op_sync_prices({})
        self.assertIn('ya tienen precio', r['note'])

    def test_cotiza_solo_lo_observado(self):
        # HERE apunta a un tmp con una copia del pricing: el test no toca el real
        import shutil as _sh
        tmp_here = tempfile.mkdtemp(prefix='harness-test-here-')
        _sh.copy(os.path.join(ROOT, 'templates', 'ui', 'pricing.json'), tmp_here)
        old_here = panel.HERE
        panel.HERE = tmp_here
        try:
            st = panel.State(self.ws)
            st.snapshot = lambda: {'unpriced': ['glm-4.7', 'modelo-inexistente']}
            catalog = {'data': [{'id': 'z-ai/glm-4.7',
                                 'pricing': {'prompt': '0.0000006', 'completion': '0.0000022'}}]}
            panel.urllib.request.urlopen = FakeHTTP(body=json.dumps(catalog).encode())
            r = st.op_sync_prices({})
            self.assertEqual(r['added'], ['glm-4.7'])
            self.assertEqual(r['missing'], ['modelo-inexistente'])   # sin match: se DICE
            table = json.load(open(os.path.join(tmp_here, 'pricing.json')))
            self.assertAlmostEqual(table['models']['glm-4.7']['input'], 0.6)
            self.assertNotIn('modelo-inexistente', table['models'])  # jamás inventar
        finally:
            panel.HERE = old_here


if __name__ == '__main__':
    unittest.main(verbosity=0)
