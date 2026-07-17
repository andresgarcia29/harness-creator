#!/usr/bin/env python3
"""harness-ui — el panel de vidrio del harness. `make ui`.

LEYES DE ESTA UI (no negociables):
  1. OBSERVAR es de solo lectura; OPERAR crea TRABAJO, jamás merges (ADR-0010).
     El panel puede lanzar /auto, responder a una sesión y guardar tokens de
     proveedores — y todo lo lanzado enfrenta LOS MISMOS gates, presupuestos y
     paradas que si lo tecleara el humano. A main se llega por una sola puerta:
     ship.sh. Guardrails del plano de operar: 127.0.0.1, token anti-CSRF por
     arranque + header custom + check de Host, secretos write-only (0600,
     jamás devueltos, jamás logueados, jamás a un agente).
  2. SOLO 127.0.0.1. Nunca 0.0.0.0.
  3. JAMÁS muestra valores de secretos: no lee .secrets, y todo texto pasa por
     redact() antes de salir. La ley de secretos también aplica a los píxeles.
  4. CERO dependencias: stdlib de Python 3. Un panel que exige `npm install`
     se pudre en tres meses.
  5. DEGRADA, NO EXPLOTA. Los transcripts de Claude Code son un formato
     INTERNO (verificado contra 2.1.211): pueden cambiar sin aviso. Si el
     parseo falla, la UI sigue viva con lo que el harness sí controla
     (.harness/events.jsonl y tasks/) y muestra el aviso arriba.

Dos fuentes, dos niveles de confianza:
  · .harness/events.jsonl + tasks/  → NUESTRO. Estable. Fases, gates, tareas.
  · transcripts de Claude Code      → PRESTADO. Best-effort. Agentes, tokens,
                                       texto en vivo.
"""

import json
import os
import re
import sys
import shutil
import subprocess
import secrets as pysecrets
import uuid
import urllib.request
import time
import threading
import queue
import glob
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
POLL_SECONDS = 0.7
ACTIVE_WINDOW = 90        # sin records nuevos en 90s → ya no está "activo"
MAX_EVENTS = 300
MAX_TEXT = 1200
MAX_SESSIONS = 12       # sesiones que el panel sigue a la vez

# ── El plano de OPERAR (ADR-0010) ─────────────────────────────────────────
# Token por arranque: se inyecta en el HTML servido y se exige como header en
# todo POST. Una página web ajena no puede mandar headers custom a 127.0.0.1
# sin un preflight CORS que este server nunca contesta → drive-by imposible.
OP_TOKEN = pysecrets.token_hex(16)
CONFIG_DIR = os.environ.get('HARNESS_CONFIG_DIR') or os.path.join(
    os.path.expanduser('~'), '.config', 'harness')

# ── Redacción (defensa en profundidad: el hook ya redacta; aquí otra vez) ──
_SECRET_PATTERNS = [
    (re.compile(r'\b(gh[pousr])_[A-Za-z0-9]{20,}'), '[REDACTADO:gh]'),
    (re.compile(r'\bhv[sb]\.[A-Za-z0-9_-]{20,}'), '[REDACTADO:vault]'),
    (re.compile(r'\bsk-[A-Za-z0-9_-]{20,}'), '[REDACTADO:key]'),
    (re.compile(r'\bxox[baprs]-[A-Za-z0-9-]{10,}'), '[REDACTADO:slack]'),
    (re.compile(r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}'), '[REDACTADO:jwt]'),
    (re.compile(r'\b(AKIA|ASIA)[A-Z0-9]{12,}'), '[REDACTADO:aws]'),
    (re.compile(r'\blin_api_[A-Za-z0-9]{20,}'), '[REDACTADO:linear]'),
    (re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'), '[REDACTADO:privkey]'),
    (re.compile(r'((?:password|passwd|secret|token|api[_-]?key|authorization)["\']?\s*[:=]\s*["\']?)([^\s"\',}]{6,})',
                re.I), r'\1[REDACTADO]'),
]


def redact(text):
    if not text:
        return text
    for pat, repl in _SECRET_PATTERNS:
        text = pat.sub(repl, text)
    return text


def clip(text, n=MAX_TEXT):
    text = (text or '').strip()
    return text if len(text) <= n else text[:n] + ' […]'


def parse_ts(iso):
    """ISO-8601 → epoch. Sin dateutil: stdlib y a prueba de formatos raros."""
    if not iso:
        return None
    try:
        s = iso.replace('Z', '+0000')
        s = re.sub(r'\.(\d{3})\d*', r'.\1', s)          # ms de largo variable
        s = re.sub(r'([+-]\d{2}):(\d{2})$', r'\1\2', s)  # +00:00 → +0000
        for fmt in ('%Y-%m-%dT%H:%M:%S.%f%z', '%Y-%m-%dT%H:%M:%S%z',
                    '%Y-%m-%dT%H:%M:%S.%f', '%Y-%m-%dT%H:%M:%S'):
            try:
                import datetime
                dt = datetime.datetime.strptime(s, fmt)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=datetime.timezone.utc)
                return dt.timestamp()
            except ValueError:
                continue
    except Exception:
        pass
    return None


# ── Localizar los transcripts de Claude Code ──────────────────────────────
# El root NO es siempre ~/.claude: CLAUDE_CONFIG_DIR lo mueve (ej. perfiles).
# Asumirlo es el bug más fácil de cometer aquí. Adivinamos, y si falla,
# escaneamos y confirmamos leyendo el campo `cwd` de un transcript real.
def candidate_roots():
    roots = []
    env = os.environ.get('CLAUDE_CONFIG_DIR')
    if env:
        roots.extend(p.strip() for p in env.split(':') if p.strip())
    home = os.path.expanduser('~')
    roots.append(os.path.join(home, '.claude'))
    roots.append(os.path.join(home, '.config', 'claude'))
    roots.extend(sorted(glob.glob(os.path.join(home, '.claude', '*'))))
    out, seen = [], set()
    for r in roots:
        p = os.path.join(r, 'projects')
        if p not in seen and os.path.isdir(p):
            seen.add(p)
            out.append(p)
    return out


def find_project_dir(workspace):
    slug = re.sub(r'[^a-zA-Z0-9]', '-', os.path.abspath(workspace))
    for projects in candidate_roots():
        guess = os.path.join(projects, slug)
        if os.path.isdir(guess):
            return guess
    # El slug no matcheó: escanea y confirma por el cwd real del transcript.
    target = os.path.abspath(workspace)
    for projects in candidate_roots():
        for d in sorted(glob.glob(os.path.join(projects, '*'))):
            if not os.path.isdir(d):
                continue
            for f in sorted(glob.glob(os.path.join(d, '*.jsonl')))[:2]:
                try:
                    with open(f, 'r', errors='replace') as fh:
                        for line in fh:
                            rec = json.loads(line)
                            if rec.get('cwd') == target:
                                return d
                            break
                except Exception:
                    continue
    return None


# ── Lector incremental de JSONL (tail seguro ante truncado/rotación) ──────
class Tailer:
    def __init__(self):
        self.offsets = {}

    def read_new(self, path):
        try:
            size = os.path.getsize(path)
        except OSError:
            return []
        off = self.offsets.get(path, 0)
        if size < off:      # truncado o rotado → relee desde cero
            off = 0
        if size == off:
            return []
        recs = []
        try:
            with open(path, 'r', errors='replace') as fh:
                fh.seek(off)
                for line in fh:
                    if not line.endswith('\n'):   # línea a medio escribir
                        break
                    off += len(line.encode('utf-8', 'replace'))
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        recs.append(json.loads(line))
                    except Exception:
                        pass
        except OSError:
            return []
        self.offsets[path] = off
        return recs


# ── Estado ────────────────────────────────────────────────────────────────
PHASES = [
    ('intake', 'Intake'), ('rfc', 'RFC'), ('implement', 'Implement'),
    ('review', 'Review'), ('ship', 'Ship'), ('deploy', 'Deploy'),
    ('archive', 'Archive'),
]


class State:
    def __init__(self, workspace):
        self.ws = os.path.abspath(workspace)
        self.lock = threading.Lock()
        self.agents = {}
        self.sessions = {}
        self.events = []
        self.tasks = []
        self.subs = []
        self.warning = None
        self.project_dir = None
        self.tailer = Tailer()
        self.pricing = self._load_pricing()
        self.started = time.time()

    def _load_pricing(self):
        try:
            with open(os.path.join(HERE, 'pricing.json')) as fh:
                return json.load(fh)
        except Exception:
            return {'models': {},
                    '_cache_read_multiplier': 0.1, '_cache_write_multiplier': 1.25}

    def cost(self, model, u):
        """USD estimado, o None si el modelo no tiene precio conocido.

        ADR-0004 del daemon, que este panel violaba: un modelo sin precio
        cuesta DESCONOCIDO, no "lo que Opus". Corriendo GLM, la versión
        anterior te cobraba tarifa de Opus y lo enseñaba con dos decimales —
        un número inventado con aspecto de dato es peor que un hueco honesto.
        """
        p = self.pricing.get('models', {}).get(model)
        if not p:
            return None
        cr = self.pricing.get('_cache_read_multiplier', 0.1)
        cw = self.pricing.get('_cache_write_multiplier', 1.25)
        return (u['in'] * p['input'] + u['cache_creation'] * p['input'] * cw
                + u['cache_read'] * p['input'] * cr + u['out'] * p['output']) / 1e6

    # ── fuente 1: nuestro bus de eventos (estable) ──
    def scan_events(self):
        path = os.path.join(self.ws, '.harness', 'events.jsonl')
        for rec in self.tailer.read_new(path):
            rec['summary'] = redact(rec.get('summary', ''))[:200]
            # Un solo tipo para 'ok': los hooks lo escriben como string y el
            # bus como booleano. Normalizar aquí evita que cada consumidor
            # tenga que recordar la diferencia (ya se nos olvidó una vez).
            if rec.get('ok') in ('true', 'false'):
                rec['ok'] = rec['ok'] == 'true'
            self.events.append(rec)
        if len(self.events) > MAX_EVENTS:
            self.events = self.events[-MAX_EVENTS:]

    # ── fuente 2: tasks/ (estable: lo escribe el harness) ──
    def scan_tasks(self):
        out = []
        for d in sorted(glob.glob(os.path.join(self.ws, 'tasks', '*'))):
            if not os.path.isdir(d):
                continue
            tid = os.path.basename(d)
            has = lambda *p: os.path.exists(os.path.join(d, *p))
            verdicts = glob.glob(os.path.join(d, 'verdict-*.json'))
            passed = 0
            for v in verdicts:
                try:
                    with open(v) as fh:
                        j = json.load(fh)
                    if str(j.get('verdict', j.get('result', ''))).lower() in ('pass', 'passed', 'ok'):
                        passed += 1
                except Exception:
                    pass
            done = set()
            if has('task.md'):
                done.add('intake')
            if has('plan.md'):
                done.add('rfc')
            if glob.glob(os.path.join(d, '..', '..', 'worktrees', tid, '*')):
                done.add('implement')
            if verdicts:
                done.add('implement')
                if passed == len(verdicts) and passed:
                    done.add('review')
            if has('ship.log'):
                done.add('ship')
            if glob.glob(os.path.join(d, 'deploy-*.log')):
                done.add('deploy')
            title, origin = tid, 'ticket'
            assumptions = []
            try:
                with open(os.path.join(d, 'task.md'), errors='replace') as fh:
                    head = fh.read(4000)
                m = re.search(r'^title:\s*"?([^"\n]+)"?', head, re.M)
                if m:
                    title = m.group(1).strip()
                if re.search(r'^origin:\s*prompt', head, re.M):
                    origin = 'prompt'
            except Exception:
                pass
            try:
                with open(os.path.join(d, 'assumptions.md'), errors='replace') as fh:
                    for line in fh:
                        if line.strip().startswith('- '):
                            assumptions.append(redact(line.strip()[2:])[:240])
            except Exception:
                pass
            phase = 'intake'
            for pid, _ in PHASES:
                if pid in done:
                    phase = pid
            out.append({'id': tid, 'title': redact(title)[:120], 'origin': origin,
                        'done': sorted(done), 'phase': phase,
                        'verdicts': {'total': len(verdicts), 'pass': passed},
                        'assumptions': assumptions,
                        'mtime': os.path.getmtime(d)})
        out.sort(key=lambda t: -t['mtime'])
        self.tasks = out[:20]

    # ── fuente 3: transcripts de Claude Code (PRESTADO, best-effort) ──
    def _session(self, sid):
        if sid not in self.sessions:
            self.sessions[sid] = {'id': sid, 'first_ts': 0, 'last_ts': 0, 'path': ''}
        return self.sessions[sid]

    def _agent(self, sid, aid):
        key = (sid, aid)
        if key not in self.agents:
            self.agents[key] = {
                'id': aid, 'session': sid,
                'type': 'main' if aid == 'main' else '?', 'desc': '',
                'model': '', 'depth': 0, 'parent': None if aid == 'main' else 'main',
                'usage': {'in': 0, 'out': 0, 'cache_read': 0, 'cache_creation': 0},
                'seen': {},   # message.id → usage final (dedupe, ver _ingest)
                'msgs': 0, 'tools': [], 'last_text': '', 'first_ts': 0,
                'last_ts': 0,
            }
        return self.agents[key]

    def _ingest(self, rec, sid, aid, texts):
        a = self._agent(sid, aid)
        # El reloj es SIEMPRE el del record, JAMÁS el nuestro.
        #
        # Van tres veces que este mismo error se cuela por una puerta distinta.
        # La versión anterior caía a `or time.time()` cuando un record no traía
        # timestamp: el pasado se estampaba con la hora actual y una sesión de
        # hace tres días aparecía "ACTIVA hace 5s". Un panel que miente sobre
        # quién está vivo es peor que no tener panel.
        #
        # Regla: si no hay timestamp en el dato, NO INVENTAMOS UNO. El record se
        # ingiere (tokens, texto) pero no toca los relojes. Un agente que nunca
        # trae timestamps cae al mtime de su archivo, que sigue siendo un hecho
        # medido y no una suposición.
        ts = parse_ts(rec.get('timestamp'))
        if ts:
            a['last_ts'] = max(a['last_ts'], ts)
            if not a['first_ts'] or ts < a['first_ts']:
                a['first_ts'] = ts
            se = self._session(sid)
            se['last_ts'] = max(se['last_ts'], ts)
            if not se['first_ts'] or ts < se['first_ts']:
                se['first_ts'] = ts
        if rec.get('type') != 'assistant':
            return
        msg = rec.get('message') or {}
        # OJO: el modelo se estampa SOLO si es real. Los records sintéticos
        # traen model:"<synthetic>" y, si dejas que pisen el campo, el agente
        # queda etiquetado <synthetic> y su costo se calcula con la tarifa por
        # defecto: una etiqueta falsa con un número falso.
        if msg.get('model') and msg['model'] != '<synthetic>':
            a['model'] = msg['model']

        # DEDUPE POR message.id. Una respuesta de la API se escribe en VARIOS
        # records (thinking, tool_use, texto…) y cada uno repite el usage de la
        # respuesta COMPLETA hasta ese punto. Sumarlos cuenta los parciales de
        # más. Medido en transcripts reales: 42 records → 15 message.id, con un
        # inflado de 1.01× (no el 4× que se cita por ahí — pero el error existe
        # y crece con el tamaño de la respuesta). Nos quedamos con el máximo por
        # id: el usage final de esa respuesta.
        mid = msg.get('id')
        u = msg.get('usage') or {}
        if not mid or msg.get('model') == '<synthetic>':
            return                       # records sintéticos: no son facturables
        cur = a['seen'].get(mid)
        new = {
            'ts': ts or a['last_ts'] or 0,
            'model': msg.get('model') or a['model'],
            'in': u.get('input_tokens', 0) or 0,
            'out': u.get('output_tokens', 0) or 0,
            'cache_read': u.get('cache_read_input_tokens', 0) or 0,
            # El desglose gana sobre el campo plano: 5m y 1h se facturan
            # distinto (1.25× vs 2×) y el plano no los distingue.
            'cache_creation': (
                (u.get('cache_creation') or {}).get('ephemeral_5m_input_tokens', 0)
                + (u.get('cache_creation') or {}).get('ephemeral_1h_input_tokens', 0)
            ) or (u.get('cache_creation_input_tokens', 0) or 0),
        }
        if cur is None:
            a['msgs'] += 1
        if cur is None or new['out'] >= cur['out']:
            a['seen'][mid] = new
            a['usage'] = {k: sum(v[k] for v in a['seen'].values())
                          for k in ('in', 'out', 'cache_read', 'cache_creation')}
        for block in (msg.get('content') or []):
            if not isinstance(block, dict):
                continue
            if block.get('type') == 'text' and block.get('text'):
                t = clip(redact(block['text']))
                a['last_text'] = t
                # 'who' = la descripción, no el id: "a754eafffe4b9f08" no le
                # dice nada a nadie; "Research agent harnesses" sí.
                texts.append({'agent': aid, 'session': sid, 'text': t, 'ts': time.time(),
                              'who': ('orquestador' if aid == 'main'
                                      else (a['desc'] or a['type'] or aid[:10]))})
            elif block.get('type') == 'tool_use':
                a['tools'].append(block.get('name', '?'))
                a['tools'] = a['tools'][-40:]

    def scan_transcripts(self):
        texts = []
        if not self.project_dir:
            self.project_dir = find_project_dir(self.ws)
            if not self.project_dir:
                self.warning = ('No encuentro los transcripts de Claude Code para este '
                                'workspace. Fases, gates y tareas siguen en vivo (vienen '
                                'del harness); agentes y tokens no. ¿Corriste una sesión '
                                'aquí? ¿CLAUDE_CONFIG_DIR apunta a otro sitio?')
                return texts
        try:
            # TODAS las sesiones. Antes leíamos solo la última porque sumarlas
            # inflaba el costo y lo presentaba como "ahora" — pero la respuesta
            # no era esconderlas: es que cada sesión es una entidad con su
            # propio estado, sus agentes y su cuenta. Tú tienes cinco abiertas y
            # quieres ver las cinco.
            sessions = sorted(glob.glob(os.path.join(self.project_dir, '*.jsonl')),
                              key=os.path.getmtime, reverse=True)[:MAX_SESSIONS]
            for s in sessions:
                sid = os.path.basename(s)[:-6]
                self._session(sid)['path'] = s
                for rec in self.tailer.read_new(s):
                    self._ingest(rec, sid, 'main', texts)
                subs = os.path.join(self.project_dir, sid, 'subagents')
                for f in glob.glob(os.path.join(subs, 'agent-*.jsonl')):
                    aid = os.path.basename(f)[len('agent-'):-len('.jsonl')]
                    a = self._agent(sid, aid)
                    if a['type'] == '?':
                        try:
                            with open(f[:-6] + '.meta.json') as fh:
                                meta = json.load(fh)
                            a['type'] = meta.get('agentType', '?')
                            a['desc'] = redact(meta.get('description', ''))[:120]
                            a['depth'] = meta.get('spawnDepth', 1)
                        except Exception:
                            pass
                    for rec in self.tailer.read_new(f):
                        self._ingest(rec, sid, aid, texts)
                    if a['msgs'] and not a['last_ts']:
                        try:
                            a['last_ts'] = a['first_ts'] = os.path.getmtime(f)
                        except OSError:
                            pass
            self.warning = None
        except Exception as e:
            self.warning = ('No pude leer los transcripts (%s). El formato es interno de '
                            'Claude Code y pudo cambiar. Lo del harness sigue en vivo.'
                            % type(e).__name__)
        return texts

    def snapshot(self):
        now = time.time()
        tot = {'in': 0, 'out': 0, 'cache_read': 0, 'cache_creation': 0}
        cost = 0.0
        by_sess = {}
        for (sid, aid), a in self.agents.items():
            if not a['msgs']:
                continue
            for k in tot:
                tot[k] += a['usage'][k]
            c = self.cost(a['model'], a['usage'])
            if c is not None:
                cost += c
            idle = now - a['last_ts']
            pub = {k: v for k, v in a.items() if k != 'seen'}
            by_sess.setdefault(sid, []).append(
                dict(pub, cost=(round(c, 4) if c is not None else None),
                     priced=c is not None, idle=round(idle),
                     active=idle < ACTIVE_WINDOW,
                     elapsed=round(a['last_ts'] - a['first_ts'])))

        # Una sesión = una terminal tuya. Es la unidad: tiene su propio estado,
        # sus agentes, su cuenta. Sumarlas todas y llamarlo "ahora" fue el bug
        # que escondí limitando el panel a una sola; la respuesta correcta es
        # separarlas, no ocultarlas.
        sessions = []
        for sid, agents in by_sess.items():
            agents.sort(key=lambda x: (not x['active'], x.get('first_ts') or 0))
            se = self.sessions.get(sid, {})
            act = [a for a in agents if a['active']]
            ts = [(a['first_ts'], a['last_ts']) for a in agents if a.get('first_ts')]
            peak = 0
            if ts:
                ev = sorted([(f, 1) for f, _ in ts] + [(l, -1) for _, l in ts])
                cur = 0
                for _, d in ev:
                    cur += d
                    peak = max(peak, cur)
            last = max((a['last_ts'] for a in agents), default=0)
            main = next((a for a in agents if a['id'] == 'main'), None)
            sessions.append({
                'id': sid, 'short': sid[:8],
                'first_ts': min((a['first_ts'] for a in agents if a['first_ts']), default=0),
                'last_ts': last, 'idle': round(now - last) if last else 0,
                'active': bool(act), 'agents': agents,
                'n_agents': len(agents), 'n_active': len(act), 'peak': peak,
                'model': main['model'] if main else '',
                'last_text': main['last_text'] if main else '',
                'tokens': {k: sum(a['usage'][k] for a in agents) for k in tot},
                'cost': round(sum(a['cost'] or 0 for a in agents), 4),
                'unpriced': sorted({a['model'] for a in agents if not a['priced'] and a['model']}),
                'msgs': sum(a['msgs'] for a in agents),
            })
        sessions.sort(key=lambda x: (not x['active'], -x['last_ts']))

        # Cubos por día y por modelo, desde el ts REAL de cada mensaje.
        KEYS = ('in', 'out', 'cache_read', 'cache_creation')
        daybuck, modbuck = {}, {}
        for a in self.agents.values():
            for u in a['seen'].values():
                m = u.get('model') or a['model'] or '?'
                day = time.strftime('%Y-%m-%d', time.localtime(u.get('ts') or a['last_ts']))
                for buck, key in ((daybuck, (day, m)), (modbuck, m)):
                    e = buck.setdefault(key, {k: 0 for k in KEYS})
                    for k in KEYS:
                        e[k] += u[k]
        days = {}
        for (day, m), u in daybuck.items():
            c = self.cost(m, u)
            d = days.setdefault(day, {'day': day, 'cost': 0.0, 'out': 0,
                                      'unpriced': False, 'by_model': {}})
            d['out'] += u['out']
            if c is None:
                d['unpriced'] = True
            else:
                d['cost'] += c
                # desglose por modelo del día: la gráfica apila BARRAS REALES,
                # no proporciones inventadas
                d['by_model'][m] = round(d['by_model'].get(m, 0.0) + c, 4)
        models = []
        for m, u in modbuck.items():
            c = self.cost(m, u)
            models.append(dict(u, model=m, cost=(round(c, 4) if c is not None else None)))
        models.sort(key=lambda x: -(x['cost'] or 0))

        return {
            'ts': now, 'workspace': self.ws, 'warning': self.warning,
            'days': sorted(days.values(), key=lambda d: d['day']),
            'models': models,
            'prices': self.pricing.get('models', {}),
            'transcripts': bool(self.project_dir),
            'sessions': sessions,
            'tasks': self.tasks, 'events': self.events[-120:],
            'connections': self.connections(),
            'runs': self.runs(),
            'mode': 'local', 'op': True,
            'tokens': tot, 'cost': round(cost, 4),
            'unpriced': sorted({a['model'] for aa in by_sess.values() for a in aa
                                if not a['priced'] and a['model']}),
            'uptime': round(now - self.started),
        }

    # ── OPERAR (ADR-0010): crear trabajo, jamás merges ──────────────────
    def _emit(self, kind, summary, task='', ok=None):
        """El bus, desde Python. Mismo shape que emit.sh; mismo redact."""
        try:
            os.makedirs(os.path.join(self.ws, '.harness'), exist_ok=True)
            e = {'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                 'kind': kind, 'task': task, 'actor': 'panel',
                 'summary': redact(summary)[:400]}
            if ok is not None:
                e['ok'] = ok
            with open(os.path.join(self.ws, '.harness', 'events.jsonl'), 'a') as fh:
                fh.write(json.dumps(e) + '\n')
        except OSError:
            pass

    def _launch(self, args, logname):
        """Lanza claude headless, desacoplado del server. Devuelve pid."""
        binname = os.environ.get('HARNESS_CLAUDE_BIN', 'claude')
        claude = shutil.which(binname)
        if not claude:
            raise RuntimeError("no encuentro el CLI '%s' en PATH — el plano de "
                               "operar lanza agentes reales y lo necesita" % binname)
        logdir = os.path.join(self.ws, '.harness', 'runs')
        os.makedirs(logdir, exist_ok=True)
        lf = open(os.path.join(logdir, logname), 'ab')
        p = subprocess.Popen([claude] + args, cwd=self.ws, stdout=lf, stderr=lf,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        return p.pid

    def _record_run(self, task, session, pid, kind):
        try:
            # crea su propio directorio: depender de que _launch corrió antes
            # es un orden implícito que ya nos falló una vez (en tests)
            os.makedirs(os.path.join(self.ws, '.harness'), exist_ok=True)
            with open(os.path.join(self.ws, '.harness', 'runs.jsonl'), 'a') as fh:
                fh.write(json.dumps({'ts': int(time.time()), 'task': task,
                                     'session': session, 'pid': pid, 'kind': kind}) + '\n')
        except OSError:
            pass

    def runs(self):
        out = []
        try:
            with open(os.path.join(self.ws, '.harness', 'runs.jsonl')) as fh:
                for line in fh:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
        except OSError:
            pass
        return out[-50:]

    def op_task(self, b):
        title = (b.get('title') or '').strip()
        origin = b.get('origin') or 'prompt'
        ticket = (b.get('ticket') or '').strip()
        if origin == 'ticket' and not ticket:
            raise ValueError('origen ticket sin id de ticket')
        if origin != 'ticket' and not title:
            raise ValueError('falta el título')
        if origin == 'ticket':
            tid = ticket
        else:
            slug = re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')
            slug = '-'.join(slug.split('-')[:3]) or 'tarea'
            tid = 'AUTO-%s-%s' % (time.strftime('%Y%m%d'), slug)
            n = 2
            while os.path.exists(os.path.join(self.ws, 'tasks', tid)):
                tid = 'AUTO-%s-%s-%d' % (time.strftime('%Y%m%d'), slug, n); n += 1
        tdir = os.path.join(self.ws, 'tasks', tid)
        os.makedirs(tdir, exist_ok=True)
        fm = ['---', 'id: %s' % tid, 'title: "%s"' % title.replace('"', "'"),
              'origin: %s' % ('ticket' if origin == 'ticket' else 'prompt'),
              'source: panel',
              'priority: %s' % (b.get('priority') or 'P2'),
              'max_parallel: %d' % max(1, min(12, int(b.get('max_parallel') or 3))),
              'assumptions_ok: %s' % ('true' if b.get('assumptions_ok', True) else 'false'),
              'review_before_ship: %s' % ('true' if b.get('review_before_ship') else 'false')]
        if b.get('model'):
            fm.append('preferred_model: %s' % b['model'])
        if b.get('budget'):
            fm.append('budget_usd: %s' % b['budget'])
        fm += ['created: %s' % time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), '---', '']
        body = (b.get('context') or '').strip()
        with open(os.path.join(tdir, 'task.md'), 'w') as fh:
            fh.write('\n'.join(fm) + (body + '\n' if body else ''))
        sid = str(uuid.uuid4())
        args = ['-p', '/auto %s' % (tid if origin != 'ticket' else ticket),
                '--session-id', sid]
        if b.get('model'):
            args += ['--model', b['model']]
        pid = self._launch(args, '%s.log' % tid)
        self._record_run(tid, sid, pid, 'auto')
        self._emit('phase', 'intake — tarea creada desde el panel y lanzada '
                   '(sesión %s…)' % sid[:8], task=tid)
        return {'id': tid, 'session': sid, 'pid': pid}

    def op_respond(self, b):
        session = (b.get('session') or '').strip()
        text = (b.get('text') or '').strip()
        if not session or not text:
            raise ValueError('faltan session o text')
        pid = self._launch(['-p', text, '--resume', session],
                           'respond-%s.log' % session[:8])
        task = next((r['task'] for r in reversed(self.runs())
                     if r.get('session') == session and r.get('task')), '')
        self._record_run(task, session, pid, 'respond')
        self._emit('decision', 'el humano respondió desde el panel: %s' % text[:160],
                   task=task)
        return {'session': session, 'pid': pid}

    def op_connect(self, b):
        prov = b.get('provider')
        token = (b.get('token') or '').strip()
        if prov not in ('linear', 'openrouter'):
            raise ValueError('proveedor desconocido')
        if not token:
            raise ValueError('falta el token')
        # VALIDAR ANTES DE GUARDAR (la lección del token de Vault: presencia
        # sin vigencia es peor que ausencia).
        if prov == 'linear':
            req = urllib.request.Request('https://api.linear.app/graphql',
                data=json.dumps({'query': '{ viewer { id } }'}).encode(),
                headers={'Authorization': token, 'Content-Type': 'application/json'})
        else:
            req = urllib.request.Request('https://openrouter.ai/api/v1/key',
                headers={'Authorization': 'Bearer ' + token})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                if r.status != 200:
                    raise ValueError('el proveedor devolvió %d' % r.status)
        except urllib.error.HTTPError as e:
            raise ValueError('token inválido (%s devolvió %d)' % (prov, e.code))
        except urllib.error.URLError as e:
            raise ValueError('no pude llegar a %s: %s' % (prov, e.reason))
        os.makedirs(CONFIG_DIR, exist_ok=True)
        path = os.path.join(CONFIG_DIR, '%s-token' % prov)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as fh:
            fh.write(token + '\n')
        return {'provider': prov, 'connected': True}

    def connections(self):
        return {p: os.path.exists(os.path.join(CONFIG_DIR, '%s-token' % p))
                for p in ('linear', 'openrouter')}

    def op_sync_prices(self, _b):
        """Precios reales desde OpenRouter para los modelos observados SIN precio."""
        snap = self.snapshot()
        targets = snap.get('unpriced') or []
        if not targets:
            return {'added': [], 'missing': [],
                    'note': 'todos los modelos observados ya tienen precio'}
        req = urllib.request.Request('https://openrouter.ai/api/v1/models')
        tokf = os.path.join(CONFIG_DIR, 'openrouter-token')
        if os.path.exists(tokf):
            req.add_header('Authorization', 'Bearer ' + open(tokf).read().strip())
        with urllib.request.urlopen(req, timeout=15) as r:
            catalog = json.loads(r.read()).get('data', [])
        norm = lambda x: re.sub(r'[^a-z0-9]', '', x.lower())
        added, missing = [], []
        ppath = os.path.join(HERE, 'pricing.json')
        table = json.load(open(ppath))
        for t in targets:
            hit = next((m for m in catalog
                        if norm(t) in norm(m.get('id', '')) or
                           norm(m.get('id', '').split('/')[-1]) in norm(t)), None)
            pr = (hit or {}).get('pricing') or {}
            try:
                inp, out = float(pr.get('prompt', 0)), float(pr.get('completion', 0))
            except (TypeError, ValueError):
                inp = out = 0
            if hit and inp > 0:
                table.setdefault('models', {})[t] = {
                    'input': round(inp * 1e6, 4), 'output': round(out * 1e6, 4)}
                added.append(t)
            else:
                missing.append(t)
        if added:
            json.dump(table, open(ppath, 'w'), indent=2, ensure_ascii=False)
            self.pricing = self._load_pricing()
        return {'added': added, 'missing': missing}

    def tick(self):
        with self.lock:
            self.scan_events()
            self.scan_tasks()
            return self.scan_transcripts()


# ── HTTP + SSE ────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    state = None

    def log_message(self, *a):
        pass   # silencio: la UI no ensucia la terminal del harness

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # El frontend es React + shadcn/ui COMPILADO y vendoreado en dist/ (fuente
    # en web/; `npm run build` solo al desarrollar el plugin). El runtime sigue
    # siendo stdlib sirviendo estáticos: el usuario final jamás necesita Node.
    MIME = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript',
            '.css': 'text/css', '.svg': 'image/svg+xml', '.woff2': 'font/woff2',
            '.png': 'image/png', '.ico': 'image/x-icon', '.map': 'application/json'}

    def _serve_dist(self, rel):
        base = os.path.realpath(os.path.join(HERE, 'dist'))
        full = os.path.realpath(os.path.join(base, rel.lstrip('/')))
        if not full.startswith(base + os.sep) and full != base:
            return self._send(404, 'text/plain', b'not found')   # fuera de dist: jamás
        try:
            with open(full, 'rb') as fh:
                body = fh.read()
        except OSError:
            return self._send(404, 'text/plain', b'not found')
        ext = os.path.splitext(full)[1]
        if ext == '.html':
            # el token anti-CSRF del arranque viaja SOLO al servir (ADR-0010)
            body = body.replace(b'__OP_TOKEN__', OP_TOKEN.encode())
        return self._send(200, self.MIME.get(ext, 'application/octet-stream'), body)

    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/api/state':
            body = json.dumps(self.state.snapshot()).encode()
            return self._send(200, 'application/json', body)
        if path == '/api/stream':
            return self._stream()
        if path == '/':
            return self._serve_dist('index.html')
        if path.startswith('/assets/') or path in ('/favicon.svg', '/favicon.ico'):
            return self._serve_dist(path)
        self._send(404, 'text/plain', b'not found')

    def do_POST(self):
        # Guardias anti-CSRF (ADR-0010): Host local + token del arranque en un
        # header custom. El preflight CORS que exigiría ese header nunca se
        # contesta, así que una página web ajena no puede llegar aquí.
        host = (self.headers.get('Host') or '').split(':')[0]
        if host not in ('127.0.0.1', 'localhost'):
            return self._send(403, 'application/json',
                              b'{"error":"solo 127.0.0.1"}')
        if self.headers.get('X-Corvux-Token') != OP_TOKEN:
            return self._send(403, 'application/json',
                              b'{"error":"token de operacion invalido - recarga la pagina"}')
        try:
            ln = min(int(self.headers.get('Content-Length') or 0), 262144)
            body = json.loads(self.rfile.read(ln) or b'{}')
        except ValueError:
            return self._send(400, 'application/json', b'{"error":"JSON invalido"}')
        routes = {
            '/api/op/task': self.state.op_task,
            '/api/op/respond': self.state.op_respond,
            '/api/op/connect': self.state.op_connect,
            '/api/op/sync-prices': self.state.op_sync_prices,
        }
        fn = routes.get(self.path.split('?')[0])
        if not fn:
            return self._send(404, 'application/json', b'{"error":"no existe"}')
        try:
            with self.state.lock:
                out = fn(body)
            return self._send(200, 'application/json',
                              json.dumps({'ok': True, **out}).encode())
        except (ValueError, RuntimeError) as e:
            return self._send(400, 'application/json',
                              json.dumps({'ok': False, 'error': str(e)}).encode())
        except Exception as e:
            return self._send(500, 'application/json',
                              json.dumps({'ok': False, 'error': '%s: %s' % (type(e).__name__, e)}).encode())

    def _stream(self):
        q = queue.Queue(maxsize=200)
        with self.state.lock:
            self.state.subs.append(q)
        # SIEMPRE 200. Según la spec de EventSource, CUALQUIER respuesta que no
        # sea 200 + text/event-stream es un fallo PERMANENTE: el navegador no
        # reintenta nunca más y no avisa. Un 503 mientras el harness arranca
        # dejaría el panel muerto hasta un reload manual. Si no hay datos,
        # mandamos un stream vacío, no un error.
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Accel-Buffering', 'no')
        self.end_headers()
        # Sin Content-Length (lo prohíbe el framing de SSE) el socket no se
        # puede reusar: hay que cerrarlo al terminar, o handle_one_request
        # se queda parseando basura.
        self.close_connection = True
        try:
            self.wfile.write(b'retry: 2000\n\n')   # reconexión rápida si el server reinicia
            self._emit('snapshot', self.state.snapshot())
            last_beat = time.time()
            while True:
                try:
                    kind, data = q.get(timeout=5)
                    self._emit(kind, data)
                except queue.Empty:
                    if time.time() - last_beat > 15:
                        self.wfile.write(b': beat\n\n')
                        self.wfile.flush()
                        last_beat = time.time()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with self.state.lock:
                if q in self.state.subs:
                    self.state.subs.remove(q)

    def _emit(self, kind, data):
        payload = 'event: %s\ndata: %s\n\n' % (kind, json.dumps(data))
        self.wfile.write(payload.encode())
        self.wfile.flush()


def poller(state):
    while True:
        try:
            texts = state.tick()
            snap = state.snapshot()
            with state.lock:
                subs = list(state.subs)
            for q in subs:
                for t in texts[-12:]:
                    try:
                        q.put_nowait(('text', t))
                    except queue.Full:
                        pass
                try:
                    q.put_nowait(('snapshot', snap))
                except queue.Full:
                    pass
        except Exception as e:
            sys.stderr.write('⚠️  poller: %s: %s\n' % (type(e).__name__, e))
        time.sleep(POLL_SECONDS)


def main():
    ap = argparse.ArgumentParser(description='harness-ui — panel de solo lectura')
    ap.add_argument('--port', type=int, default=7717)
    ap.add_argument('--workspace', default=os.path.join(HERE, '..', '..'))
    ap.add_argument('--open', action='store_true', help='abre el navegador')
    args = ap.parse_args()

    state = State(args.workspace)
    state.tick()
    Handler.state = state
    threading.Thread(target=poller, args=(state,), daemon=True).start()

    # 127.0.0.1 SIEMPRE: este panel muestra tu código y tus tareas.
    srv = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    url = 'http://127.0.0.1:%d' % args.port
    print('🔭 harness-ui → %s   (solo lectura · solo local · Ctrl-C para salir)' % url)
    print('   workspace: %s' % state.ws)
    print('   transcripts: %s' % (state.project_dir or '⚠️  no encontrados (ver el aviso en la UI)'))
    if args.open:
        try:
            import webbrowser
            webbrowser.open(url)
        except Exception:
            pass
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print('\n👋 harness-ui fuera. No tocó nada.')


if __name__ == '__main__':
    main()
