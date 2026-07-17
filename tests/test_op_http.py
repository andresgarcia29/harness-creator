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

    def stub_lines(self):
        time.sleep(0.4)   # Popen del server es asíncrono
        try:
            return open(self.stub_log).read().splitlines()
        except OSError:
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
        launched = self.stub_lines()[-1]
        self.assertIn('/auto %s' % r['id'], launched)
        self.assertIn('--session-id %s' % r['session'], launched)
        type(self)._sess = r['session']

    def test_06_responder_reanuda(self):
        code, r = self.post('/api/op/respond',
                            {'session': self._sess, 'text': 'sigue con Redis'},
                            token=self.token)
        self.assertEqual(code, 200)
        self.assertIn('--resume %s' % self._sess, self.stub_lines()[-1])

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


if __name__ == '__main__':
    unittest.main(verbosity=0)
