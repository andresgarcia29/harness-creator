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


class TestCtxPorTurno(Base):
    """El panel medía lo ACUMULADO (lo que se factura) y nada más. El contexto
    que arrastra CADA turno pesa cuatro veces más que el arranque, y el harness
    no lo medía en ningún lado (issue #206). El dato ya estaba parseado."""

    def _msg(self, mid, inp, cr, cc, out=10):
        return {'type': 'assistant', 'timestamp': '2026-08-15T10:00:00Z',
                'message': {'id': mid, 'model': 'claude-sonnet-5', 'content': [],
                            'usage': {'input_tokens': inp, 'output_tokens': out,
                                      'cache_read_input_tokens': cr,
                                      'cache_creation_input_tokens': cc}}}

    def test_ctx_es_lo_que_entro_en_el_ultimo_turno(self):
        for m in (self._msg('m1', 100, 50, 10), self._msg('m2', 2000, 300, 700)):
            self.state._ingest(m, 'sess-1', 'main', [])
        a = self.state.agents[('sess-1', 'main')]
        self.assertEqual(a['ctx'], 3000)          # el ÚLTIMO turno, no la suma
        self.assertEqual(a['usage']['in'], 2100)  # lo acumulado sigue acumulando

    def test_ctx_max_recuerda_el_pico(self):
        for m in (self._msg('m1', 9000, 0, 0), self._msg('m2', 10, 0, 0)):
            self.state._ingest(m, 'sess-1', 'main', [])
        a = self.state.agents[('sess-1', 'main')]
        self.assertEqual(a['ctx'], 10)
        self.assertEqual(a['ctx_max'], 9000)      # el techo no se olvida al bajar

    def test_ctx_viaja_al_snapshot(self):
        self.state._ingest(self._msg('m1', 1000, 200, 50), 'sess-1', 'main', [])
        agentes = [ag for s in self.state.snapshot()['sessions'] for ag in s['agents']]
        self.assertTrue(agentes, 'el snapshot no trajo agentes')
        self.assertEqual(agentes[0]['ctx'], 1250)


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




class TestToolbox(Base):
    def _fixture(self):
        ws = self.ws
        os.makedirs(os.path.join(ws, '.claude', 'commands'))
        with open(os.path.join(ws, '.claude', 'commands', 'auto.md'), 'w') as fh:
            fh.write('---\ndescription: Ticket a produccion\nargument-hint: <ticket>\n---\ncuerpo')
        os.makedirs(os.path.join(ws, '.claude', 'agents'))
        with open(os.path.join(ws, '.claude', 'agents', 'architect.md'), 'w') as fh:
            fh.write('---\ndescription: El arquitecto\n---\n')
        os.makedirs(os.path.join(ws, '.claude', 'skills', 'deploy'))
        with open(os.path.join(ws, '.claude', 'skills', 'deploy', 'SKILL.md'), 'w') as fh:
            fh.write('---\nname: deploy\ndescription: despliega\n---\n')
        with open(os.path.join(ws, 'Makefile'), 'w') as fh:
            fh.write('ui: ## panel en vivo\n\techo hola\nship: ## gates + push\n\techo x\n')
        os.makedirs(os.path.join(ws, 'scripts'))
        with open(os.path.join(ws, 'scripts', 'ship.sh'), 'w') as fh:
            fh.write('gate_trailer() { :; }\ngate_secrets() { :; }\n')

    def test_inventario_real(self):
        self._fixture()
        tb = self.state.scan_toolbox()
        self.assertEqual(tb['commands'][0]['name'], '/auto')
        self.assertEqual(tb['commands'][0]['desc'], 'Ticket a produccion')
        self.assertEqual(tb['agents'][0]['name'], 'architect')
        self.assertEqual([m['target'] for m in tb['make']], ['ui', 'ship'])
        self.assertEqual(tb['gates'], ['gate_secrets', 'gate_trailer'])
        self.assertEqual(tb['skills'][0]['name'], 'deploy')

    def test_workspace_vacio_no_inventa(self):
        tb = self.state.scan_toolbox()
        self.assertEqual(tb['commands'], [])   # vacio que ensena, jamas datos fake
        self.assertEqual(tb['gates'], [])


class TestMcp(Base):
    def _stub_mcp(self, ok=True):
        """Un MCP de palo que SI habla el protocolo (o no, para el caso triste)."""
        path = os.path.join(self.ws, 'stub-mcp.py')
        with open(path, 'w') as fh:
            if ok:
                fh.write('''import json,sys
line = sys.stdin.readline()
req = json.loads(line)
print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":{
  "serverInfo":{"name":"stub","version":"9.9"},"capabilities":{}}}), flush=True)
''')
            else:
                fh.write('import sys; sys.stderr.write("Unauthorized: bad token\\n"); sys.exit(1)\n')
        return path

    def _mcp_json(self, path):
        with open(os.path.join(self.ws, '.mcp.json'), 'w') as fh:
            json.dump({'mcpServers': {'stub': {'command': sys.executable, 'args': [path]}}}, fh)

    def test_checks_estaticos(self):
        self._mcp_json(self._stub_mcp())
        m = self.state.mcp_servers()[0]
        self.assertEqual(m['name'], 'stub')
        self.assertTrue(m['bin_ok'])
        self.assertIsNone(m['secrets_ok'])      # sin with-secrets: no aplica
        self.assertIsNone(m['probe'])           # sin sondear: no se declara nada

    def test_sonda_habla_el_protocolo(self):
        self._mcp_json(self._stub_mcp(ok=True))
        r = self.state.op_probe_mcp({})['probed']['stub']
        self.assertTrue(r['ok'])
        self.assertEqual(r['server'], 'stub')
        # y el resultado queda en el snapshot siguiente
        self.assertTrue(self.state.mcp_servers()[0]['probe']['ok'])

    def test_sonda_honesta_cuando_falla(self):
        self._mcp_json(self._stub_mcp(ok=False))
        r = self.state.op_probe_mcp({})['probed']['stub']
        self.assertFalse(r['ok'])
        self.assertIn('Unauthorized', r['error'])
        self.assertTrue(r['auth_hint'])         # el error de auth SE DICE


class TestPhase0(Base):
    def test_tool_hint(self):
        self.assertEqual(panel._tool_hint({'file_path': 'a/b.ts'}), 'a/b.ts')
        self.assertEqual(panel._tool_hint({'command': 'ls -la'}), 'ls -la')
        self.assertEqual(panel._tool_hint('no dict'), '')

    def test_session_detail_incluye_hilo(self):
        a = self.state._agent('sess-x', 'main')
        a['model'] = 'claude-sonnet-5'
        a['first_ts'] = 100; a['last_ts'] = 220
        a['thread'] = [{'k': 'think', 'ts': 100, 't': 'pensando'},
                       {'k': 'tool', 'ts': 110, 't': 'Read', 'inp': 'x.ts'},
                       {'k': 'text', 'ts': 220, 't': 'listo'}]
        d = self.state.session_detail('sess-x')
        self.assertEqual(d['short'], 'sess-x'[:8])
        ag = d['agents'][0]
        self.assertEqual(ag['elapsed'], 120)
        self.assertEqual(len(ag['thread']), 3)
        self.assertEqual(ag['who'], 'orquestador')

    def test_task_git_read_ignora_comandos(self):
        # el evidence.log guarda el COMANDO entero en las filas 'ran' — mirarlo
        # como ruta ensuciaba la lista. Solo read/scan/ran-file son rutas.
        d = os.path.join(self.ws, 'tasks', 'COR-1')
        os.makedirs(d)
        with open(os.path.join(d, 'evidence.log'), 'w') as fh:
            fh.write('2026-07-17\ts\tread\tworktrees/COR-1/atlas/auth.go\n')
            fh.write('2026-07-17\ts\tscan\tworktrees/COR-1/hermes/pay.go\n')
            fh.write('2026-07-17\ts\tran\tcd worktrees/COR-1/atlas && go test ./...\n')
        g = self.state.task_git('COR-1')
        # atlas y hermes son leídos (no hay worktrees reales → no 'touched')
        self.assertEqual(g['read'], ['atlas', 'hermes'])
        # el comando 'ran' no metió basura de shell
        self.assertNotIn('cd ', g['read'])


    def test_task_events_arco_completo(self):
        os.makedirs(os.path.join(self.ws, '.harness'))
        with open(os.path.join(self.ws, '.harness', 'events.jsonl'), 'w') as fh:
            fh.write(json.dumps({'ts': '2026-07-17T11:00:00Z', 'kind': 'phase', 'task': 'X', 'summary': 'intake'}) + '\n')
            fh.write(json.dumps({'ts': '2026-07-17T11:45:00Z', 'kind': 'gate', 'task': 'X', 'summary': 'gate_x', 'ok': 'false'}) + '\n')
            fh.write(json.dumps({'ts': '2026-07-17T12:00:00Z', 'kind': 'ship', 'task': 'Y', 'summary': 'otra tarea'}) + '\n')
        ev = self.state.task_events('X')
        self.assertEqual(len(ev), 2)                 # solo los de X, no los de Y
        self.assertIs(ev[1]['ok'], False)            # 'false' normalizado a bool
        self.assertEqual(self.state.task_events('../x'), [])

    def test_task_git_id_malicioso(self):
        g = self.state.task_git('../../etc')
        self.assertEqual(g, {'repos': [], 'read': []})


if __name__ == '__main__':
    unittest.main(verbosity=0)
