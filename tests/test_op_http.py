#!/usr/bin/env python3
"""test_op_http.py — el plano de operar POR HTTP, contra el server real.

Arranca templates/ui/server.py como subproceso en un puerto libre, con un
workspace temporal y un `claude` de palo (HARNESS_CLAUDE_BIN) que solo graba
sus argumentos. Prueba lo que un navegador haría — incluidas las defensas:

  · sin X-Corvux-Token → 403 (anti-CSRF: un <form> de otra página no puede
    poner headers custom)
  · Host raro → 403 (DNS rebinding)
  · crear tarea → task.md + runs.jsonl + evento en el bus + claude lanzado
    con --session-id conocido
  · responder → claude --resume con LA sesión pedida
  · el token viaja en el HTML de "/" (por eso recargar la página lo renueva)
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, 'templates', 'ui', 'server.py')


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


class TestOpHTTP(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ws = tempfile.mkdtemp(prefix='harness-http-ws-')
        cls.cfg = tempfile.mkdtemp(prefix='harness-http-cfg-')
        cls.stub_log = os.path.join(cls.ws, 'stub.log')
        stub = os.path.join(cls.ws, 'claude-stub')
        with open(stub, 'w') as fh:
            fh.write('#!/bin/sh\necho "$@" >> "%s"\n' % cls.stub_log)
        os.chmod(stub, 0o755)
        cls.port = free_port()
        env = dict(os.environ, HARNESS_CLAUDE_BIN=stub,
                   HARNESS_CONFIG_DIR=cls.cfg)
        cls.proc = subprocess.Popen(
            [sys.executable, SERVER, '--port', str(cls.port), '--workspace', cls.ws],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # esperar a que escuche
        for _ in range(50):
            try:
                cls.html = urllib.request.urlopen(
                    'http://127.0.0.1:%d/' % cls.port, timeout=1).read().decode()
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError('el server nunca escuchó')
        import re
        m = re.search(r'window\.__OP="([a-f0-9]+)"', cls.html)
        assert m, 'el token de operación no viaja en el HTML'
        cls.token = m.group(1)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)
        shutil.rmtree(cls.ws, ignore_errors=True)
        shutil.rmtree(cls.cfg, ignore_errors=True)

    def post(self, path, body, token=None, host=None):
        req = urllib.request.Request(
            'http://127.0.0.1:%d%s' % (self.port, path),
            data=json.dumps(body).encode(),
            headers={'Content-Type': 'application/json'})
        if token:
            req.add_header('X-Corvux-Token', token)
        if host:
            req.add_header('Host', host)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b'{}')

    def stub_lines(self, expect=1):
        # El Popen del server es asíncrono: POLL hasta 5s en vez de dormir un
        # tiempo fijo — con la máquina cargada, 0.4s no alcanzaban y el test
        # era flaky (nos pasó: 3 errores en cascada por un IndexError aquí).
        for _ in range(50):
            try:
                lines = open(self.stub_log).read().splitlines()
                if len(lines) >= expect:
                    return lines
            except OSError:
                pass
            time.sleep(0.1)
        return []

    def test_01_sin_token_403(self):
        code, body = self.post('/api/op/task', {'title': 'x'})
        self.assertEqual(code, 403)

    def test_02_token_equivocado_403(self):
        code, _ = self.post('/api/op/task', {'title': 'x'}, token='0' * 32)
        self.assertEqual(code, 403)

    def test_03_host_raro_403(self):
        code, _ = self.post('/api/op/task', {'title': 'x'},
                            token=self.token, host='evil.example.com')
        self.assertEqual(code, 403)

    def test_04_ruta_desconocida_404(self):
        code, _ = self.post('/api/op/nada', {}, token=self.token)
        self.assertEqual(code, 404)

    def test_05_crear_tarea_completo(self):
        code, r = self.post('/api/op/task',
                            {'title': 'Probar el plano de operar',
                             'context': 'e2e', 'priority': 'P1'},
                            token=self.token)
        self.assertEqual(code, 200)
        self.assertTrue(r['ok'])
        md = open(os.path.join(self.ws, 'tasks', r['id'], 'task.md')).read()
        self.assertIn('source: panel', md)
        runs = [json.loads(l) for l in
                open(os.path.join(self.ws, '.harness', 'runs.jsonl'))]
        self.assertEqual(runs[-1]['session'], r['session'])
        bus = [json.loads(l) for l in
               open(os.path.join(self.ws, '.harness', 'events.jsonl'))]
        self.assertEqual(bus[-1]['task'], r['id'])
        lines = self.stub_lines(expect=1)
        self.assertTrue(lines, 'el claude stub nunca corrió')
        self.assertIn('/auto %s' % r['id'], lines[-1])
        self.assertIn('--session-id %s' % r['session'], lines[-1])
        type(self)._sess = r['session']

    def test_06_responder_reanuda(self):
        code, r = self.post('/api/op/respond',
                            {'session': self._sess, 'text': 'sigue con Redis'},
                            token=self.token)
        self.assertEqual(code, 200)
        lines = self.stub_lines(expect=2)
        self.assertTrue(len(lines) >= 2, 'el resume nunca llegó al stub')
        self.assertIn('--resume %s' % self._sess, lines[-1])

    def test_07_validacion_es_400_con_mensaje(self):
        code, body = self.post('/api/op/task', {'title': ''}, token=self.token)
        self.assertEqual(code, 400)
        self.assertIn('título', body.get('error', ''))

    def test_08_state_expone_op_y_runs(self):
        with urllib.request.urlopen(
                'http://127.0.0.1:%d/api/state' % self.port, timeout=5) as r:
            s = json.loads(r.read())
        self.assertTrue(s['op'])
        self.assertEqual(s['mode'], 'local')
        self.assertIn('connections', s)
        self.assertTrue(any(x.get('session') == self._sess for x in s['runs']))


    # ── Lo que se rompía al dejar de ser 127.0.0.1-only ────────────────

    def get(self, path, host=None):
        req = urllib.request.Request('http://127.0.0.1:%d%s' % (self.port, path))
        if host:
            req.add_header('Host', host)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read() or b''

    def test_09_ticket_con_traversal_no_escapa_ni_lanza_agente(self):
        """El id del ticket se usaba crudo en makedirs Y en el prompt.

        Son dos fallas en una: escribir fuera del workspace, y meter texto de
        afuera en las instrucciones de un agente con git y push. Por eso el
        test comprueba las dos, no solo la del directorio.
        """
        evil = '../../harness-pwned-%d' % os.getpid()
        escaped = os.path.abspath(os.path.join(self.ws, 'tasks', evil))
        with open(self.stub_log) as fh:
            antes = len(fh.read().splitlines())

        code, body = self.post('/api/op/task',
                               {'origin': 'ticket', 'ticket': evil},
                               token=self.token)

        self.assertEqual(code, 400)
        self.assertIn('inválido', body.get('error', ''))
        self.assertFalse(os.path.exists(escaped),
                         'el id del ticket escapó del workspace: %s' % escaped)
        time.sleep(0.5)
        with open(self.stub_log) as fh:
            despues = len(fh.read().splitlines())
        self.assertEqual(antes, despues,
                         'se lanzó un agente con un id que no pasó validación')

    def test_10_ticket_legitimo_sigue_funcionando(self):
        """La guarda es una lista blanca: tiene que dejar pasar lo normal."""
        code, r = self.post('/api/op/task',
                            {'origin': 'ticket', 'ticket': 'ENG-1234'},
                            token=self.token)
        self.assertEqual(code, 200)
        self.assertEqual(r['id'], 'ENG-1234')
        self.assertTrue(os.path.isdir(os.path.join(self.ws, 'tasks', 'ENG-1234')))

    def test_11_los_GET_tambien_exigen_host_local(self):
        """La guarda vivía solo en do_POST. Mientras tanto los GET servían el
        estado, el texto de las sesiones y el HTML que LLEVA EL TOKEN, sin una
        sola comprobación."""
        for path in ('/api/state', '/api/session?id=x',
                     '/api/task-git?task=x', '/api/task-events?task=x', '/'):
            code, _ = self.get(path, host='evil.example.com')
            self.assertEqual(code, 403, 'GET %s le respondió a un Host ajeno' % path)

    def test_12_los_GET_locales_siguen_sirviendo(self):
        for path in ('/api/state', '/'):
            code, _ = self.get(path)
            self.assertEqual(code, 200, 'GET %s dejó de servir en local' % path)

    def test_13_el_ledger_dice_en_que_maquina_paso(self):
        """`actor: 'panel'` alcanzaba con un panel. Al juntar los ledgers de
        varios VPS, no responde cuál, y un pid sin máquina no se puede buscar."""
        with open(os.path.join(self.ws, '.harness', 'events.jsonl')) as fh:
            bus = [json.loads(l) for l in fh]
        self.assertTrue(bus[-1]['actor'].startswith('panel@'),
                        'el actor no identifica la máquina: %r' % bus[-1]['actor'])
        self.assertTrue(bus[-1]['host'], 'el evento no dice en qué host pasó')
        with open(os.path.join(self.ws, '.harness', 'runs.jsonl')) as fh:
            runs = [json.loads(l) for l in fh]
        self.assertTrue(runs[-1]['host'], 'el run no dice dónde vive ese pid')


    def test_14_token_no_ascii_responde_403_y_no_tumba_la_peticion(self):
        """Un header con un byte no-ASCII tiene que dar 403, no morir.

        `hmac.compare_digest` lanza TypeError comparando str con caracteres
        no-ASCII, y esa comparacion corre ANTES del try del handler: un
        `X-Corvux-Token: tokén` dejaba la peticion SIN RESPUESTA y escupia un
        traceback. No era un bypass, pero un guardia que se cae con la entrada
        que vino a inspeccionar no es un guardia. Por eso se comparan bytes.

        Se usa http.client y no urllib porque urllib rechaza el header antes de
        que salga, y entonces el server nunca veria el caso que se prueba.
        """
        import http.client
        c = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        c.putrequest('POST', '/api/op/task')
        c.putheader('Host', '127.0.0.1')
        c.putheader('X-Corvux-Token', 'tok\u00e9n'.encode('latin-1'))
        c.putheader('Content-Type', 'application/json')
        c.putheader('Content-Length', '2')
        c.endheaders()
        c.send(b'{}')
        try:
            status = c.getresponse().status
        except Exception as exc:   # RemoteDisconnected = el bug
            self.fail('el server no respondio al token no-ASCII (%s): la '
                      'comparacion del token lanzo una excepcion' % type(exc).__name__)
        self.assertEqual(status, 403)

    def test_15_el_token_se_compara_en_tiempo_constante(self):
        """Estructural: el fuente usa compare_digest y no `!=`.

        Es el unico de los tres guardias del panel que no se puede probar por
        comportamiento: un test de timing real es flaky por naturaleza, y por
        eso este arreglo viajo sin red. Verificado con una mutacion: al volver
        la linea a `!=` la suite entera seguia en verde, o sea que un refactor
        podia revertirlo sin que nada se quejara. Una asercion sobre el fuente
        es fea, pero es la que falla cuando alguien lo deshace.
        """
        src = open(SERVER, encoding='utf-8').read()
        self.assertIn('hmac.compare_digest', src,
                      'el token debe compararse con hmac.compare_digest')
        self.assertNotRegex(
            src, r"headers\.get\('X-Corvux-Token'\)\s*!=",
            'comparar el token con != filtra por tiempo cuantos caracteres '
            'acertaste: usa hmac.compare_digest sobre bytes')
        self.assertRegex(
            src, r'compare_digest\(\s*supplied',
            'compare_digest debe recibir BYTES: con str lanza TypeError ante '
            'cualquier caracter no-ASCII (ver test_14)')

if __name__ == '__main__':
    unittest.main(verbosity=0)
