#!/usr/bin/env python3
"""harness-cost.py: la báscula que faltaba, y el freno que la usa.

POR QUÉ EXISTE
--------------
El harness medía todo menos lo único que se paga. `harness-metrics.py` registra
duraciones, rondas y falsos rojos, y su propio docstring explica por qué no mide
tokens ("un agente analizando métricas es exactamente el consumidero de tokens
que este diseño existe para evitar"). El panel SÍ calcula costo, pero en memoria,
sin persistir y sin cruzarlo con la tarea. Y `record-cost` es auto-reporte: no
tiene UNA sola llamada desde código en todo el repo, así que `spent_usd` se queda
en 0.0 para siempre si el modelo no se acuerda de correr ccusage.

Resultado medido antes de escribir esto, sobre 663 transcripts:

  · el 87.4% del gasto vive en las sesiones ORQUESTADORAS, no en los subagentes
    (que son el 12.6% y tienen mediana de 20 tool calls y 42k de contexto)
  · la mediana de una sesión son $12.52 y el 43% cuesta menos de $10, pero el
    top 10% se lleva el 65.8%: el problema no es el precio, es la cola
  · el acierto de caché va de 23% a 99% entre sesiones y NADIE lo mira; la peor
    dejó $1472 en reescrituras con 749 de sus 754 turnos a menos de un minuto
    uno de otro (invalidación de prefijo, no expiración de TTL)

Ninguno de esos tres hechos era observable desde el harness. Este script los
vuelve un número por tarea y, con `--check`, un gate.

LA LEY DE COSTO que gobierna todo, y que conviene tener a la vista:

    costo ≈ N_toolcalls · contexto · precio_lectura      [releer]
          + contexto_reescrito · precio_escritura        [reescribir]
          + N_toolcalls · salida · precio_salida         [pensar]

El término dominante escala como N x C: duplicar tool calls o duplicar contexto
duplica el costo, duplicar ambos lo cuadruplica. Y cada invalidación de caché
cuesta el contexto ENTERO a 12.5x el precio de lectura, así que el radio de daño
de un fallo de caché escala lineal con el contexto que arrastres.

CERO TOKENS DE MODELO: lee artefactos que ya existen (transcripts de Claude Code
y `.harness/session-task/`) y hace aritmética. Misma ley que harness-metrics.

FUENTE PRESTADA, y hay que decirlo: los transcripts son de Claude Code, no del
harness. Si el usuario corre otro cliente, o CLAUDE_CONFIG_DIR apunta a otro
lado, este script lo DICE en vez de reportar $0.00, que sería exactamente el
"verde silencioso" que el harness persigue en todos lados.

Uso:
  harness-cost.py task <id>              costo por agente y rol de una tarea
  harness-cost.py day [--days N]         top de sesiones y totales
  harness-cost.py check <id>             gate: sale 3 si algo está fuera de banda
  harness-cost.py check <id> --budget N  ídem, con techo explícito en dólares
  harness-cost.py check <id> --since T   ídem, con la ventana de banda explícita
  harness-cost.py check <id> --json      el mismo veredicto, legible por máquina

LA VENTANA: `check` mide el GASTO sobre toda la tarea y las dos bandas de tasa
(acierto de caché y contexto medio) sobre la FASE EN CURSO, que es la única
ventana donde la remediación que imprime todavía puede cambiar algo. Ver el
bloque "LA VENTANA" más abajo.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import glob
import json
import math
import os
import re
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# WS no es constante: `--ws` la pisa. Sin eso, el script solo servia dentro de
# una instancia generada por harness-creator, y el caso mas util es el
# contrario: medir un workspace CUALQUIERA (o ninguno) porque los transcripts
# son de Claude Code, no del harness.
WS = os.environ.get("HARNESS_WS") or os.path.dirname(HERE)


def set_ws(path: str) -> None:
    global WS
    WS = os.path.abspath(os.path.expanduser(path))

# ── Umbrales de banda ────────────────────────────────────────────────────────
# No son opinión: salen de la distribución medida. El acierto de caché sano
# observado es 97-99%; por debajo de 90% hay reescritura sistemática. 150k de
# contexto medio es el punto donde una invalidación empieza a costar más de $1.
CACHE_HIT_FLOOR = float(os.environ.get("HARNESS_CACHE_HIT_FLOOR", "0.90"))
CTX_CEILING = int(os.environ.get("HARNESS_CTX_CEILING", "150000"))

# ── EL TECHO DE CONTEXTO NO PUEDE SER EL MISMO PARA TODOS LOS ROLES (#120) ──
# 150k era un número solo, aplicado por igual a un subagente de una tarea, al
# ORQUESTADOR de un lote y a un reviewer que el harness declara PERSISTENTE
# entre rondas. Los dos últimos arrastran contexto por DISEÑO: el orquestador
# sostiene el plan y el estado del lote, y el reviewer conserva su ronda 1
# justamente para que la ronda 2 sea incremental (ver reviewer.md). Medido en
# UNA sola tarea: 6 de 6 evaluaciones de banda ctx dieron breach y las 6 se
# eximieron a mano (160k, 179k, 193k, 201k, 157k, 210k). Un gate que se exime
# siempre no es un gate: es un peaje.
#
# Lo que NO se hace es subir el número para todos: eso apagaría el freno donde
# sí mide derroche. El techo pasa a ser POR ROL y DATO del policy
# (`limits.ctx_ceiling_by_role`), con el default de 150k intacto para todo rol
# que no declare el suyo.
#
# Y no se compra silencio: un rol por encima de 150k pero dentro de SU techo se
# IMPRIME igual, como aviso. Lo que cambia es que no traba la transición.
# La causa de fondo se ataca aparte y en el otro extremo (que el orquestador
# guarde punteros y no enunciados, y que el loop de rondas viva en un
# sub-orquestador de contexto fresco): este techo solo deja de castigar lo que
# el propio diseño manda hacer mientras tanto.
def ctx_ceiling_for(role: str) -> int:
    """El techo de contexto de ESTE rol: el declarado, o el general."""
    if os.environ.get("HARNESS_CTX_CEILING"):
        return CTX_CEILING          # un override explícito manda sobre todo
    return CTX_CEILING_BY_ROLE.get(role or "", CTX_CEILING)


def load_ctx_ceilings() -> dict:
    """`workflow.limits.ctx_ceiling_by_role` de harness-policy.json, o {}.

    Se lee del policy y no de una constante acá por la misma razón que el techo
    de quick: un número cableado no se puede ajustar por instancia, y quien lo
    intente editaría el policy creyendo que sirve de algo."""
    path = os.path.join(WS, "harness-policy.json")
    try:
        with open(path, encoding="utf-8") as fh:
            pol = json.load(fh)
    except (OSError, ValueError):
        return {}
    limits = ((pol.get("limits") or {}) if isinstance(pol, dict) else {})
    raw = limits.get("ctx_ceiling_by_role")
    if not isinstance(raw, dict):
        return {}
    return {k: int(v) for k, v in raw.items()
            if isinstance(k, str) and isinstance(v, int) and v > 0}


CTX_CEILING_BY_ROLE: dict = {}

EXIT_OK, EXIT_USAGE, EXIT_BREACH, EXIT_NODATA = 0, 2, 3, 4


# ── El piso de caché no se le puede cobrar a un agente CORTO ─────────────────
# CASO DE CAMPO: un implementer que hizo bien su trabajo cerró en 89% con 33
# turnos y dejó la tarea trabada para siempre, porque `cache_hit` es histórico
# (sale de transcripts inmutables) y ninguna remediación futura lo mueve.
#
# Y hay un tramo donde el piso no mide derroche sino ARITMÉTICA. El mejor caso
# posible para un agente de T turnos es escribir su contexto UNA vez y leerlo en
# los T-1 turnos restantes, o sea `hit_max = (T-1)/T`. Cualquier agente real
# escribe más (el contexto crece), así que esa fracción es una COTA SUPERIOR: si
# `(T-1)/T` ya está por debajo del piso, el agente no podía aprobarlo hiciera lo
# que hiciera, y el breach no informa nada sobre su conducta.
#
# De ahí sale el mínimo, que no es un número elegido: `T >= 1/(1-piso)` (10
# turnos con el piso en 90%). Por debajo, el término se DECLARA y no bloquea;
# nunca se calla, que sería el verde silencioso al revés.
def min_turns_for_cache_floor() -> int:
    if CACHE_HIT_FLOOR <= 0:
        return 0
    if CACHE_HIT_FLOOR >= 1:
        return 1 << 30          # un piso de 100% es inalcanzable con cualquier T
    # La tolerancia no es cosmética: 1-0.9 da 0.09999999999999998 en binario y
    # el ceil crudo devolvía 11 turnos para un piso que se alcanza con 10, o sea
    # que el gate dejaba de mirar a un agente que SÍ podía aprobarlo.
    return int(math.ceil(1.0 / (1.0 - CACHE_HIT_FLOOR) - 1e-9))


def max_cache_hit(turns: int) -> float:
    """La cota superior de acierto alcanzable con `turns` turnos."""
    return (turns - 1) / turns if turns > 0 else 0.0


# ── LA VENTANA: LAS BANDAS MIDEN LA FASE EN CURSO, NO TODA LA HISTORIA ───────
# CASO DE CAMPO (issue #95, tres caras del mismo hueco): dos abogados de RFC de
# una sola respuesta cerraron con 76% y 65% de acierto, y a partir de ahí TODA
# transición de esa tarea salió en exit 3, para siempre. La tarea global estaba
# en 94.4% y sin presupuesto excedido: no había derroche en curso, había dos
# filas históricas. Y el gate imprimía como remediación "recortar el contexto de
# ARRANQUE de los agentes", que solo puede afectar a agentes que TODAVÍA NO
# corrieron: la remediación no podía tocar lo que la disparaba.
#
# `cache_hit` y `ctx_avg` son PROMEDIOS sobre transcripts inmutables. Un
# promedio que ya creció no baja porque el operador haga bien las cosas de acá
# en adelante, así que un umbral sobre toda la historia es un trinquete de un
# solo sentido: el primer agente malo congela la tarea.
#
# El arreglo es medir la ventana sobre la que la remediación PUEDE actuar: la
# fase en curso. `harness-policy.py` estampa `phase_since` en cada movimiento de
# fase, y acá cada agente se re-agrega contando solo los turnos posteriores a
# ese instante. Consecuencias, todas buscadas:
#   · un agente que cerró en una fase anterior deja de tener turnos en la
#     ventana y sale del cálculo (se DECLARA, no se calla)
#   · un agente que sigue vivo se mide por lo que hizo en ESTA fase
#   · el gasto en dólares (COST-BUDGET) NO se ventana: es acumulativo y lo que
#     mide es el bolsillo, no una tasa que alguien pueda mejorar
#   · el mínimo de turnos (min_turns_for_cache_floor) se cobra sobre los turnos
#     DE LA VENTANA, así que una ventana corta no inventa un breach de caché
def iso_epoch(value):
    """El instante de un ISO-8601, o None si no lo es.

    Se compara por epoch y no por string: los transcripts traen fracciones de
    segundo (`...:11.123Z`) y `phase_since` no, y en orden lexicográfico
    `.123Z` cae ANTES que `Z`, o sea que el turno del segundo de la transición
    quedaría del lado equivocado de la ventana."""
    if not isinstance(value, str) or not value.strip():
        return None
    txt = value.strip()
    if txt.endswith(("Z", "z")):
        txt = txt[:-1] + "+00:00"
    try:
        stamp = dt.datetime.fromisoformat(txt)
    except Exception:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=dt.timezone.utc)
    return stamp.timestamp()


# ── Precios ──────────────────────────────────────────────────────────────────
def load_pricing() -> dict:
    """pricing.json es la fuente única; el panel lo comparte.

    Corrección respecto del panel: la caché de 1 HORA se cobra 2x, no 1.25x.
    El panel usa un multiplicador plano y por eso su costo viene optimista.
    Acá, si el transcript trae el desglose por TTL (`cache_creation`), cada
    tramo se cobra a su precio; si no lo trae, se cae al plano y se declara.
    """
    for cand in (
        # instancia instalada: scripts/harness-cost.py junto a scripts/ui/
        os.path.join(HERE, "ui", "pricing.json"),
        os.path.join(WS, "scripts", "ui", "pricing.json"),
        # generador: templates/scripts/harness-cost.py con templates/ui/
        os.path.join(os.path.dirname(HERE), "ui", "pricing.json"),
        os.path.join(HERE, "pricing.json"),
    ):
        try:
            with open(cand) as fh:
                return json.load(fh)
        except Exception:
            continue
    return {}


PRICING = load_pricing()
MULT_READ = PRICING.get("_cache_read_multiplier", 0.1)
MULT_WRITE_5M = PRICING.get("_cache_write_multiplier", 1.25)
MULT_WRITE_1H = PRICING.get("_cache_write_1h_multiplier", 2.0)


def price_of(model: str):
    """(input, output) por millón, o None si el modelo no está tarifado.

    Un modelo desconocido devuelve None y su costo se reporta como 'n/d'. Los
    tokens son reales; el dinero no se inventa. Misma regla que el panel.
    """
    models = PRICING.get("models") or {}
    m = models.get(model)
    if m is None:
        # Las variantes de ventana se anotan con sufijo entre corchetes
        # (`claude-opus-5[1m]`). No llevan recargo por contexto largo, así que
        # cotizan igual que su base: normalizar es correcto, no una aproximación.
        m = models.get(re.sub(r"\[[^\]]*\]$", "", model))
    if m:
        return float(m.get("input", 0.0)), float(m.get("output", 0.0))
    return None


def cost_of(model: str, u: dict):
    """Costo en USD de un `usage`, o None si el modelo no está tarifado."""
    p = price_of(model)
    if not p:
        return None
    pin, pout = p
    i = u.get("input", 0)
    cr = u.get("cache_read", 0)
    o = u.get("output", 0)
    w5 = u.get("cache_write_5m", 0)
    w1h = u.get("cache_write_1h", 0)
    wflat = u.get("cache_write_flat", 0)
    return (
        i * pin
        + cr * pin * MULT_READ
        + w5 * pin * MULT_WRITE_5M
        + w1h * pin * MULT_WRITE_1H
        + wflat * pin * MULT_WRITE_5M
        + o * pout
    ) / 1e6


# ── Localizar transcripts (misma lógica probada que el panel) ────────────────
def candidate_roots():
    roots = []
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        roots.extend(p.strip() for p in env.split(":") if p.strip())
    home = os.path.expanduser("~")
    roots.append(os.path.join(home, ".claude"))
    roots.append(os.path.join(home, ".config", "claude"))
    roots.extend(sorted(glob.glob(os.path.join(home, ".claude", "*"))))
    out, seen = [], set()
    for r in roots:
        p = os.path.join(r, "projects")
        if p not in seen and os.path.isdir(p):
            seen.add(p)
            out.append(p)
    return out


def find_project_dir(workspace: str):
    slug = re.sub(r"[^a-zA-Z0-9]", "-", os.path.abspath(workspace))
    for projects in candidate_roots():
        guess = os.path.join(projects, slug)
        if os.path.isdir(guess):
            return guess
    target = os.path.abspath(workspace)
    for projects in candidate_roots():
        for d in sorted(glob.glob(os.path.join(projects, "*"))):
            if not os.path.isdir(d):
                continue
            for f in sorted(glob.glob(os.path.join(d, "*.jsonl")))[:2]:
                try:
                    with open(f, "r", errors="replace") as fh:
                        for line in fh:
                            rec = json.loads(line)
                            if rec.get("cwd") == target:
                                return d
                            break
                except Exception:
                    continue
    return None


# ── Lectura de un transcript ─────────────────────────────────────────────────
# Un hueco entre turnos más largo que esto no es un turno lento: es el agente
# esperando el mensaje siguiente. El default sale de la medición: los huecos de
# trabajo de un subagente están muy por debajo, y los de espera arrancan en
# minutos.
HUECO_MAX_S = float(os.environ.get("HARNESS_COST_HUECO_MAX_S", "120"))


def _acc() -> dict:
    """Un acumulador de usage.

    Existe para que el TOTAL y la VENTANA se agreguen con el mismo código: dos
    aritméticas del mismo número es una oportunidad de divergir, y acá el número
    es el que decide si una transición pasa."""
    return {"t": collections.Counter(), "models": collections.Counter(),
            "turns": 0, "tools": 0, "ctx": [], "first": None, "last": None,
            "prev": None, "activo": 0.0}


def _add(a: dict, model: str, u: dict, tools: int, ts) -> None:
    a["turns"] += 1
    a["models"][model] += 1
    i = u.get("input_tokens", 0) or 0
    cr = u.get("cache_read_input_tokens", 0) or 0
    cwt = u.get("cache_creation_input_tokens", 0) or 0
    o = u.get("output_tokens", 0) or 0
    t = a["t"]
    t["input"] += i
    t["cache_read"] += cr
    t["output"] += o
    # Desglose por TTL cuando existe: 1h se cobra al doble.
    cc = u.get("cache_creation") or {}
    w1h = cc.get("ephemeral_1h_input_tokens", 0) or 0
    w5 = cc.get("ephemeral_5m_input_tokens", 0) or 0
    if w1h or w5:
        t["cache_write_1h"] += w1h
        t["cache_write_5m"] += w5
    else:
        t["cache_write_flat"] += cwt
    t["cache_write_total"] += cwt
    ctx = i + cr + cwt
    if ctx:
        a["ctx"].append(ctx)
    a["tools"] += tools
    if ts:
        a["first"] = a["first"] or ts
        # ── EL RELOJ QUE FALTABA, Y POR QUÉ SON DOS NÚMEROS ──────────────
        # `harness-cost.py` reportaba dólares, turnos y contexto, y NO reportaba
        # tiempo, así que la latencia se diagnosticaba con el único número
        # disponible: la duración que el runtime informa al orquestador. Ese
        # número es inconsistente para los agentes CONTINUADOS (SendMessage),
        # que es como el harness hace las rondas: medido en una sesión, el
        # reviewer devolvió duración POR RONDA (12,4 min) y el implementer, la
        # vida entera del agente con el ocio adentro (33,9 min contra 12,2 de
        # trabajo). Con ese número, el diagnóstico apuntó al lugar equivocado.
        #
        # Acá se miden los dos por separado, y la diferencia ES el dato: el
        # `span` (de su primer turno al último) incluye lo que el agente pasó
        # esperando el mensaje siguiente; el `activo` suma solo los huecos
        # ENTRE TURNOS que son de trabajo. Un hueco largo no es un turno lento,
        # es un agente esperando, y sumarlo al trabajo es lo que hace que una
        # ronda de 12 minutos parezca de 34.
        if a["prev"]:
            d = (iso_epoch(ts) or 0) - (iso_epoch(a["prev"]) or 0)
            if 0 < d <= HUECO_MAX_S:
                a["activo"] += d
        a["prev"] = ts
        a["last"] = ts


def _finish(a: dict, path: str):
    if not a["turns"]:
        return None
    t = a["t"]
    model = a["models"].most_common(1)[0][0]
    return {
        "path": path,
        "model": model,
        "turns": a["turns"],
        "tools": a["tools"],
        "usage": dict(t),
        "cost": cost_of(model, t),
        "ctx_avg": statistics.mean(a["ctx"]) if a["ctx"] else 0,
        "ctx_max": max(a["ctx"]) if a["ctx"] else 0,
        "cache_hit": (t["cache_read"] / (t["cache_read"] + t["cache_write_total"]))
        if (t["cache_read"] + t["cache_write_total"]) else 1.0,
        "first": a["first"],
        "last": a["last"],
        "span_s": max(0.0, (iso_epoch(a["last"]) or 0) - (iso_epoch(a["first"]) or 0)),
        "activo_s": a["activo"],
    }


def scan(path: str, window_ts=None):
    """Agrega el usage de un transcript. Fail-open: un archivo ilegible no
    rompe el reporte, se salta y se cuenta aparte.

    Con `window_ts` se agrega DOS veces en la misma pasada: el total (que es lo
    que se reporta y lo que paga COST-BUDGET) y solo los turnos posteriores a
    ese instante, que es lo que evalúan las bandas de tasa. La sub-fila viaja en
    `row["window"]`, y es None cuando el agente no ejecutó nada en la ventana."""
    total = _acc()
    win = _acc() if window_ts is not None else None
    menciones = collections.Counter()
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                # ── A QUÉ TAREA pertenece este transcript (#153) ──
                # Se cuenta sobre la línea CRUDA, antes del filtro de turnos:
                # las rutas aparecen en el prompt del Task, en los file_path de
                # Read, en los `cd worktrees/...` de Bash y en los tool results,
                # o sea sobre todo en las líneas que NO son del asistente.
                if "worktrees/" in line or "tasks/" in line:
                    for t in _TASK_EN_RUTA.findall(line):
                        if t != "archive":
                            menciones[t] += 1
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                msg = rec.get("message") or {}
                if rec.get("type") != "assistant" and msg.get("role") != "assistant":
                    continue
                u = msg.get("usage") or {}
                if not u:
                    continue
                model = msg.get("model") or rec.get("model") or "?"
                # `<synthetic>` son mensajes que Claude Code fabrica localmente
                # (avisos, cortes): no hubo llamada a la API y no se cobran.
                # Contarlos inflaría los turnos y ensuciaría el acierto de caché.
                if model == "<synthetic>":
                    continue
                ts = rec.get("timestamp")
                tools = sum(
                    1 for blk in (msg.get("content") or [])
                    if isinstance(blk, dict) and blk.get("type") == "tool_use")
                _add(total, model, u, tools, ts)
                if win is not None:
                    at = iso_epoch(ts)
                    # Un turno sin fecha legible no se puede ubicar respecto de
                    # la ventana, así que ENTRA: fail-closed ante datos malos.
                    # Dejarlo afuera relajaría el umbral en silencio, que es la
                    # única de las dos equivocaciones que nadie ve.
                    if at is None or at >= window_ts:
                        _add(win, model, u, tools, ts)
    except Exception:
        return None
    row = _finish(total, path)
    if row is None:
        return None
    row["windowed"] = win is not None
    row["window"] = _finish(win, path) if win is not None else None
    row["menciones"] = menciones
    return row


def role_of(agent_path: str) -> str:
    """El ROL es el único dato que no vive en ningún artefacto y hace falta
    para responder '¿cuánto costó el reviewer de hermes?'.

    Se deriva del `.meta.json` que Claude Code deja junto al transcript del
    subagente: primero `agentType` (que es el subagent_type real), y si es
    genérico se cae al `description`, donde la convención del harness es
    `<rol>:<repo>`. Sin ninguno de los dos devuelve 'sin-rol', que es honesto
    y además es la señal de que alguien lanzó un agente sin nombrarlo.
    """
    meta = agent_path.rsplit(".jsonl", 1)[0] + ".meta.json"
    try:
        with open(meta) as fh:
            m = json.load(fh)
    except Exception:
        return "sin-rol"
    at = (m.get("agentType") or "").strip()
    # ── `general-purpose` YA NO SE LAVA CON LA DESCRIPCIÓN ────────────────
    # Estaba en esta lista de tipos "genéricos" para caer al `<rol>:<repo>` de
    # la descripción, y el efecto era que un agente prohibido con una
    # descripción amable se contabilizaba como implementer. Medido en UNA
    # tarea: 34 general-purpose, 3134 turnos y $357, el rubro más caro de la
    # tarea, contra 33 turnos y $2 del único Explore. Para que el criterio se
    # verifique solo hace falta que el rol se vea, así que se devuelve tal cual
    # y `band()` lo marca. `claude` y `Explore` siguen cayendo a la
    # descripción: los dos son usos legítimos.
    if at and at not in ("claude", "Explore"):
        return at
    desc = (m.get("description") or "").strip().lower()
    for r in ("architect", "implementer", "reviewer", "qa", "svc-agent"):
        if desc.startswith(r) or f"{r}:" in desc or f" {r} " in f" {desc} ":
            return r
    return at or "sin-rol"


# Las rutas por las que un transcript confiesa en qué tarea estuvo trabajando.
# `worktrees/<id>/<repo>` es contrato del implementer, y `tasks/<id>/` es donde
# vive TODO el estado de una tarea, así que cualquier agente que trabajó en una
# las nombra decenas de veces.
_TASK_EN_RUTA = re.compile(r"(?:worktrees|tasks)/([A-Za-z0-9][A-Za-z0-9._-]*)/")

# Qué tan dominante tiene que ser una tarea para quedarse con una SESIÓN entera.
# Un orquestador mono-tarea que de paso ojea la tarea vecina sigue siendo suyo;
# un barrido que reparte su trabajo entre cuatro no es de ninguna.
_DOMINIO_MIN = 0.7


def tarea_dominante(menciones, minimo=0.0) -> str:
    """La tarea más nombrada, si pasa el umbral de dominio. '' si no hay."""
    if not menciones:
        return ""
    total = sum(menciones.values())
    task, n = max(menciones.items(), key=lambda kv: (kv[1], kv[0]))
    if minimo and total and (n / total) < minimo:
        return ""
    return task


def menciona(path: str, needle: str) -> bool:
    """¿El archivo nombra este id? Sonda de bytes, sin parsear JSON.

    Es la poda barata de `task_filter`: reemplaza al descarte por puntero, que
    era justo lo que descartaba las sesiones de las tareas hermanas."""
    pat = needle.encode()
    try:
        with open(path, "rb") as fh:
            cola = b""
            while True:
                chunk = fh.read(1 << 20)
                if not chunk:
                    return False
                if pat in cola + chunk:
                    return True
                cola = chunk[-len(pat):]
    except Exception:
        return False


def session_task_map() -> dict:
    """sid → task, del puntero que ya escribe track-read.sh."""
    out = {}
    d = os.path.join(WS, ".harness", "session-task")
    for f in glob.glob(os.path.join(d, "*")):
        sid = os.path.basename(f)
        if sid.endswith(".serena"):
            continue
        try:
            with open(f) as fh:
                task = fh.readline().strip()
            if task:
                out[sid] = task
        except Exception:
            continue
    return out


def collect(project_dir: str, since_days=None, task_filter=None, window_ts=None):
    """Todas las sesiones y subagentes del workspace, con su tarea si se sabe.

    `task_filter` no es azúcar: sin él, un `check` en una transición tendría que
    escanear TODOS los transcripts del workspace para tirar el 95%, y un gate
    que tarda diez segundos es un gate que alguien va a querer apagar. Con el
    filtro solo se abren los archivos de la tarea, que son unos pocos.

    `window_ts` recorta lo que evalúan las bandas de tasa, no lo que se reporta:
    cada fila llega entera y con su sub-fila `window`.

    LA TAREA SALE DEL TRANSCRIPT, NO DEL PUNTERO (#153)
    ---------------------------------------------------
    El puente `sid→tarea` de track-read.sh es UN archivo por sesión y el último
    en escribir gana. Eso es correcto para lo que el hook hace (evidencia de
    lecturas), y era una premisa falsa acá: un orquestador de `/smart-main`
    lanza VARIAS tareas en una sesión, así que la última tocada se llevaba el
    gasto de todas y las hermanas quedaban en cero. Medido: una tarea express de
    12 líneas de diff con 477 turnos de orquestador, un architect que nunca
    corrió para ella y ocho implementers ajenos, mientras las cuatro tareas que
    hicieron el trabajo real reportaban "sin transcripts atribuidos". El gate de
    presupuesto frenaba a la barata (y hacían falta tres eximidos para
    destrabarla) y era ciego para la cola cara, que es justo lo que existe para
    cortar.

    Los transcripts ya dicen la tarea: los agentes trabajan por contrato en
    `worktrees/<id>/<repo>` y el estado vive en `tasks/<id>/`, y esas rutas
    aparecen literales decenas de veces. Es un dato INMUTABLE, así que además
    sobrevive al borrado del puntero en SessionEnd, que es por qué
    `harness-sink.py push` no escribía métricas de una tarea ya cerrada.

    El puntero queda de respaldo para el transcript que no nombra ninguna ruta.
    """
    s2t = session_task_map()
    cutoff = time.time() - since_days * 86400 if since_days else None
    rows = []
    for path in sorted(glob.glob(os.path.join(project_dir, "*.jsonl"))):
        if cutoff and os.path.getmtime(path) < cutoff:
            continue
        sid = os.path.basename(path)[: -len(".jsonl")]
        subs = sorted(glob.glob(
            os.path.join(project_dir, sid, "subagents", "agent-*.jsonl")))
        # La poda de `task_filter` sigue siendo barata, pero ya no puede confiar
        # en el puntero: la sonda de bytes es la que evita abrir y parsear el
        # 95% de los transcripts sin descartar a las hermanas. Y mira TAMBIÉN a
        # los subagentes: el trabajo de una tarea hermana vive ahí abajo, en una
        # sesión cuyo transcript principal puede no nombrarla nunca.
        mira_padre = True
        if task_filter is not None and s2t.get(sid) != task_filter:
            mira_padre = menciona(path, task_filter)
            if not mira_padre and not any(menciona(sp, task_filter) for sp in subs):
                continue
        sess_task = ""
        if mira_padre:
            r = scan(path, window_ts=window_ts)
            if r:
                # Una SESIÓN es de una tarea solo si esa tarea DOMINA lo que
                # hizo. Un barrido reparte su trabajo entre varias y no es de
                # ninguna: mejor sin tarea (visible en `day`, invisible para el
                # budget de cualquiera) que cargada entera a la que salió
                # sorteada, que es el bug. El puntero solo entra si el
                # transcript no nombra NINGUNA ruta de tarea: donde sí las
                # nombra, preguntarle al puntero es volver a la señal rota.
                sess_task = (tarea_dominante(r["menciones"], _DOMINIO_MIN)
                             if r["menciones"] else s2t.get(sid, ""))
                r.update(sid=sid, kind="orquestador", role="orquestador",
                         task=sess_task)
                rows.append(r)
        for sp in subs:
            sr = scan(sp, window_ts=window_ts)
            if not sr:
                continue
            # Un subagente sí trabaja en UNA tarea (es el contrato), así que acá
            # alcanza con la más nombrada: un reviewer que ojea la vecina pierde
            # por conteo.
            sr.update(sid=sid, kind="subagente", role=role_of(sp),
                      task=tarea_dominante(sr["menciones"]) or sess_task)
            rows.append(sr)
    if task_filter is not None:
        # La sonda deja pasar la sesión entera; acá se queda solo lo que es de
        # esta tarea. Sin esto, pedir una tarea traería a sus hermanas de vuelta.
        rows = [r for r in rows if r["task"] == task_filter]
    return rows


# ── Salida ───────────────────────────────────────────────────────────────────
def usd(v):
    return "       n/d" if v is None else f"{v:>10,.2f}"


def mins(seg) -> str:
    """Segundos → minutos, para las dos columnas de reloj."""
    if not seg:
        return "      -"
    return f"{seg / 60:>6.1f}m"


def band(r) -> str:
    """La etiqueta que hace escaneable el reporte: qué está fuera de banda.

    El sufijo `(corto)` marca el agente cuyo piso de caché no es alcanzable por
    aritmética: el dato se muestra igual (es real), pero decir que está fuera de
    banda sin decir que no podía estar dentro sería un reporte que miente."""
    flags = []
    if r["cache_hit"] < CACHE_HIT_FLOOR:
        corto = "" if r["turns"] >= min_turns_for_cache_floor() else " (corto)"
        flags.append(f"cache {r['cache_hit']*100:.0f}%{corto}")
    if r["ctx_avg"] > CTX_CEILING:
        flags.append(f"ctx {r['ctx_avg']/1000:.0f}k")
    # `general-purpose` está PROHIBIDO como subagente del pipeline: las
    # preguntas de "dónde está X" se contestan con herramienta (graphify query,
    # semble search, Serena), y cuando hace falta un agente de verdad es
    # `Explore`. No es un gate, es un flag: el criterio se verifica solo en el
    # reporte, sin que nadie tenga que acordarse de mirarlo.
    if r.get("role") == "general-purpose":
        flags.append("general-purpose PROHIBIDO")
    return " ".join(flags)


def print_rows(rows, limit=20):
    rows = sorted(rows, key=lambda r: -(r["cost"] or 0))[:limit]
    print(f"{'USD':>10} {'rol':<14} {'turnos':>7} {'tools':>6} "
          f"{'ctx medio':>10} {'cache':>6} {'activo':>7} {'reloj':>7}  fuera de banda")
    print("-" * 94)
    for r in rows:
        print(f"{usd(r['cost'])} {r['role'][:14]:<14} {r['turns']:>7} "
              f"{r['tools']:>6} {r['ctx_avg']:>10,.0f} "
              f"{r['cache_hit']*100:>5.0f}% {mins(r.get('activo_s'))} "
              f"{mins(r.get('span_s'))}  {band(r)}")


def totals(rows):
    g = collections.Counter()
    cost = 0.0
    untariffed = 0
    for r in rows:
        for k, v in r["usage"].items():
            g[k] += v
        if r["cost"] is None:
            untariffed += 1
        else:
            cost += r["cost"]
    return g, cost, untariffed


def print_totals(rows):
    g, cost, untariffed = totals(rows)
    read = g["cache_read"]
    write = g["cache_write_total"]
    hit = read / (read + write) if (read + write) else 1.0
    tools = sum(r["tools"] for r in rows)
    print()
    print(f"total            ${cost:>12,.2f}   ({len(rows)} agentes, {tools:,} tool calls)")
    print(f"acierto de caché  {hit*100:>12.1f}%   "
          f"(lectura {read:,} · escritura {write:,})")
    if tools:
        print(f"costo por tool call ${cost/tools:>10.3f}")
    if untariffed:
        print(f"nota: {untariffed} agente(s) con modelo sin tarifar, "
              f"excluidos del total (agregalo a pricing.json)")


def cmd_task(args) -> int:
    pd = find_project_dir(WS)
    if not pd:
        print("no encontré transcripts de este workspace.", file=sys.stderr)
        print("¿CLAUDE_CONFIG_DIR apunta a otro sitio, o corriste otro cliente?",
              file=sys.stderr)
        return EXIT_NODATA
    rows = collect(pd, task_filter=args.task)
    if not rows:
        print(f"sin transcripts atribuidos a {args.task}.", file=sys.stderr)
        print("la tarea sale de las rutas que el transcript nombra "
              "(worktrees/<id>/, tasks/<id>/): un agente que jamás pisó ninguna "
              "no tiene cómo atribuirse.", file=sys.stderr)
        return EXIT_NODATA
    print(f"== {args.task} ==")
    print_rows(rows)
    by_role = collections.defaultdict(float)
    act_role = collections.defaultdict(float)
    span_role = collections.defaultdict(float)
    for r in rows:
        by_role[r["role"]] += r["cost"] or 0
        act_role[r["role"]] += r.get("activo_s") or 0
        span_role[r["role"]] += r.get("span_s") or 0
    print()
    # El tiempo va JUNTO al costo y no en otro comando: la pregunta "por qué
    # tardó" y la pregunta "por qué costó" se hacen a la vez, y separarlas es
    # como se termina diagnosticando la latencia con el único número que había.
    print("por rol (activo = trabajo; reloj = de su primer turno al último, ocio incluido):")
    for role, c in sorted(by_role.items(), key=lambda x: -x[1]):
        print(f"  {role:<16} ${c:>10,.2f}  activo {mins(act_role[role])}"
              f"  reloj {mins(span_role[role])}")
    print_totals(rows)
    return EXIT_OK


def cmd_day(args) -> int:
    pd = find_project_dir(WS)
    if not pd:
        print("no encontré transcripts de este workspace.", file=sys.stderr)
        return EXIT_NODATA
    rows = collect(pd, since_days=args.days)
    if not rows:
        print(f"sin actividad en los últimos {args.days} día(s).")
        return EXIT_OK
    print(f"== últimos {args.days} día(s) ==")
    print_rows(rows, limit=args.top)
    print_totals(rows)
    out = [r for r in rows if band(r)]
    if out:
        print()
        print(f"{len(out)} agente(s) fuera de banda. "
              f"El costo de una sesión con caché rota es hasta 4x el de una sana.")
    return EXIT_OK


def task_state(task: str) -> dict:
    """El state.json de la tarea, o {} si no hay. Fail-open a propósito: la
    báscula mide transcripts, y una tarea sin estado sigue siendo medible."""
    try:
        with open(os.path.join(WS, "tasks", task, "state.json")) as fh:
            value = json.load(fh)
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def load_waivers(state: dict) -> list:
    """Los términos EXIMIDOS con actor y motivo, que escribe harness-policy.py.

    POR QUÉ EXISTE: `COST-BUDGET` tenía un escape auditable (`budget --to`, que
    queda en `history[]`) y los otros dos términos NO tenían ninguno. El
    resultado medido en campo: un subagente que ya cerró bajo el piso trababa la
    tarea para siempre, porque su métrica es histórica e inmutable y la única
    salida que quedaba era `HARNESS_CACHE_HIT_FLOOR`, que apaga el gate SIN
    dejar rastro. Un gate cuyo único escape es invisible es un gate que alguien
    va a apagar y nadie va a poder auditar.

    El eximido NO apaga nada: se declara en cada corrida del check con quién lo
    autorizó y por qué, y cubre solo hasta lo que se aceptó (ver `covered_by`)."""
    value = state.get("cost_waivers")
    if not isinstance(value, list):
        return []
    return [w for w in value if isinstance(w, dict)]


def covered_by(waivers: list, band_code: str, role: str, value: float,
               phase: str = ""):
    """El eximido que cubre este término, o None.

    UN EXIMIDO NO ES UN CHEQUE EN BLANCO: declara la banda, el rol y el valor
    MEDIDO cuando se autorizó. Algo PEOR que lo aceptado vuelve a frenar, que es
    lo que separa "acepto este 89% del architect que ya cerró" de "no me midas
    más la caché de esta tarea".

    ── PERO EL VALOR CLAVADO SOLO SIRVE SI LA MEDICIÓN NO PUEDE CRECER (#103) ──
    Anclar al valor medido es correcto para `cache`, cuyo agente YA CERRÓ: su
    transcript es inmutable y el número no se mueve más. Para `ctx` del
    orquestador es INAPLICABLE POR CONSTRUCCIÓN: el orquestador está vivo por
    definición en el momento en que pide la transición, su contexto medio es
    monótono creciente, y lo suben las propias tool calls del waive y de la
    transición. Medido en campo: se autorizó 167938.23 y para cuando el waive
    terminó de escribirse la medición ya iba en 169k. El eximido nacía vencido,
    o sea que la única salida que el gate llama auditable no funcionaba para el
    caso más común, y quedaba solo `HARNESS_CTX_CEILING`, que el propio mensaje
    describe como último recurso que NO deja rastro.

    Un eximido de `ctx` se ata entonces a la FASE en que se autorizó, que es
    exactamente la ventana en la que el término se mide (`phase_since`, ver
    LA VENTANA arriba). No es un cheque en blanco por tres razones: caduca solo
    en la siguiente transición, cubre la misma ventana que la medición (ni un
    turno más), y sigue apareciendo con actor y motivo en cada corrida.

    Los eximidos VIEJOS (sin `phase`) conservan la comparación por valor: una
    instancia que actualiza no pierde lo que ya había autorizado.

    ── LOS DOS LADOS TIENEN QUE MEDIR CON LA MISMA REGLA (#119, #124, #126) ──
    El eximido guarda el valor del BREACH, y el breach se construye REDONDEADO
    (`round(cache_hit, 6)` y `round(ctx_avg, 2)`, ver `evaluate`). Esta función
    recibía en cambio la medición CRUDA y comparaba con una tolerancia de 1e-9.
    Cuando `round()` empuja hacia el lado malo (hacia arriba en cache, hacia
    abajo en ctx) la diferencia llega a 5e-7 en cache, o sea unas 500 veces la
    tolerancia: el eximido quedaba por encima de lo que se mide y NO PODÍA
    CUBRIR SU PROPIO BREACH. Determinista, y le tocaba a la mitad de los valores
    por sorteo del séptimo decimal.
    Efecto en campo: `cost-waive` decía "aceptado", el eximido quedaba escrito
    en `state.json` con el valor exacto que el gate reportaba, y la transición
    seguía frenada igual. O sea que la ÚNICA salida que el gate llama auditable
    no funcionaba, y quedaba solo `HARNESS_CACHE_HIT_FLOOR`, que el propio
    mensaje describe como el último recurso que no deja rastro.
    El arreglo es que los dos lados usen la MISMA aritmética: se compara el
    valor con el mismo redondeo con que se persistió."""
    for w in waivers:
        if w.get("band") != band_code or w.get("agent") != role:
            continue
        if band_code == "ctx" and w.get("phase"):
            if phase and w.get("phase") == phase:
                return w
            continue                     # el eximido era de otra fase: se acabó
        at = w.get("value")
        if not isinstance(at, (int, float)):
            return w                     # sin valor declarado: cubre la banda entera
        medido = round_as_breach(band_code, value)
        # La tolerancia sube a 1e-6 además del redondeo: con los dos lados ya
        # redondeados sobra, y deja margen para un eximido viejo escrito por una
        # instancia anterior a este arreglo (el error que ese introduce está
        # acotado justamente por el paso del redondeo).
        if band_code == "cache" and medido >= float(at) - 1e-6:
            return w
        if band_code == "ctx" and medido <= float(at) + 1e-6:
            return w
    return None


def round_as_breach(band_code: str, value: float) -> float:
    """El valor con el MISMO redondeo con que `evaluate` persiste el breach.

    Vive en una función porque tiene DOS llamadores que deben coincidir byte a
    byte (el que escribe el breach y el que lo empareja con su eximido), y dos
    copias de un redondeo divergen sin que nadie lo note hasta que una
    transición queda trabada para siempre."""
    return round(float(value), 6 if band_code == "cache" else 2)


def waiver_note(w: dict) -> str:
    return (f"EXIMIDO por {w.get('actor') or '?'}"
            + (f": {w.get('reason')}" if w.get("reason") else ""))


def evaluate(rows, task: str, budget, window=None):
    """Los tres términos, partidos en lo que FRENA y lo que no.

    Devuelve (breaches, waived, unmeasurable, outside), cada uno con entradas
    autodescriptivas: el mismo cálculo alimenta el texto del gate y el `--json`
    que consume `harness-policy.py cost-waive`. Dos evaluadores del mismo umbral
    es una oportunidad de divergir.

    `window` es solo el texto del instante en que empezó la fase: quién queda
    dentro ya viene resuelto en `row["window"]`, que lo calculó `scan`."""
    estado = task_state(task)
    waivers = load_waivers(estado)
    # La fase en curso: un eximido de `ctx` vale para ELLA y no para siempre
    # (#103). Se lee acá y no dentro del bucle: es la misma para todos los roles.
    fase = estado.get("phase") or ""
    breaches, waived, unmeasurable, outside = [], [], [], []

    def entry(code, role, value, r=None, text=""):
        return {"code": code, "agent": role, "value": value, "text": text,
                "cost": (r or {}).get("cost"), "turns": (r or {}).get("turns")}

    # EL GASTO NO SE VENTANA. Los dólares son acumulativos y miden el bolsillo,
    # no una tasa: recortarlos a la fase en curso haría que una tarea cara
    # pasara por barata cada vez que avanza de fase.
    _, cost, _ = totals(rows)
    if budget and cost > float(budget):
        breaches.append(entry(
            "COST-BUDGET", None, round(cost, 4), None,
            f"COST-BUDGET: gastado ${cost:,.2f} sobre un presupuesto de "
            f"${float(budget):,.2f}"))
    min_turns = min_turns_for_cache_floor()
    for r in sorted(rows, key=lambda r: -(r["cost"] or 0)):
        # `m` es lo que se MIDE (la ventana), `r` lo que se reporta. Sin
        # ventana declarada son la misma fila y la conducta es la de siempre.
        m = r["window"] if r.get("windowed") else r
        if m is None:
            outside.append(entry(
                "COST-WINDOW", r["role"], None, r,
                f"fuera de la ventana: {r['role']} no ejecutó ningún turno "
                f"desde que empezó la fase en curso ({window}), así que sus "
                f"{r['turns']} turno(s) no se evalúan. Su métrica sale de "
                "transcripts inmutables y ninguna remediación futura la mueve: "
                "cobrársela a esta transición trabaría la tarea para siempre"))
            continue
        if m["cache_hit"] < CACHE_HIT_FLOOR:
            e = entry("COST-CACHE", r["role"], round_as_breach("cache", m["cache_hit"]), m,
                      f"COST-CACHE: {r['role']} con {m['cache_hit']*100:.0f}% de "
                      f"acierto de caché (piso {CACHE_HIT_FLOOR*100:.0f}%), "
                      f"${m['cost'] or 0:,.2f} de los cuales la reescritura es "
                      "la mayoría")
            w = covered_by(waivers, "cache", r["role"], m["cache_hit"])
            if m["turns"] < min_turns:
                e["text"] += (
                    f". NO se evalúa: con {m['turns']} turno(s) el máximo "
                    f"alcanzable es {max_cache_hit(m['turns'])*100:.0f}%, así que "
                    f"acá el piso mide la ventana de caché y no el derroche "
                    f"(hacen falta {min_turns} turnos)")
                unmeasurable.append(e)
            elif w:
                e["waiver"] = w
                e["text"] += f". {waiver_note(w)}"
                waived.append(e)
            else:
                breaches.append(e)
        techo = ctx_ceiling_for(r["role"])
        if m["ctx_avg"] > CTX_CEILING and m["ctx_avg"] <= techo:
            # Por encima del piso general y dentro del techo DECLARADO para su
            # rol: no traba, y no se calla. Verlo es lo que permite notar el día
            # que el techo del rol se quedó corto o de más (#120).
            unmeasurable.append(entry(
                "COST-CTX", r["role"], round_as_breach("ctx", m["ctx_avg"]), m,
                f"COST-CTX: {r['role']} arrastra {m['ctx_avg']/1000:.0f}k de "
                f"contexto medio, por encima del piso general "
                f"({CTX_CEILING/1000:.0f}k) pero dentro del techo declarado para "
                f"su rol ({techo/1000:.0f}k): NO frena. El rol arrastra contexto "
                "por diseño (lote, o reviewer persistente entre rondas)"))
        elif m["ctx_avg"] > techo:
            e = entry("COST-CTX", r["role"], round_as_breach("ctx", m["ctx_avg"]), m,
                      f"COST-CTX: {r['role']} arrastra {m['ctx_avg']/1000:.0f}k de "
                      f"contexto medio (techo {techo/1000:.0f}k) sobre "
                      f"{m['tools']} tool calls")
            w = covered_by(waivers, "ctx", r["role"], m["ctx_avg"], fase)
            if w:
                e["waiver"] = w
                e["text"] += f". {waiver_note(w)}"
                waived.append(e)
            else:
                breaches.append(e)
    return breaches, waived, unmeasurable, outside


def cmd_check(args) -> int:
    """El gate. Sale 3 si la tarea está fuera de banda o excedió presupuesto.

    Fail-OPEN ante ausencia de datos y fail-CLOSED ante datos malos: si no hay
    transcripts no se puede afirmar nada y bloquear sería mentir al revés; si
    los hay y están fuera de banda, se bloquea con el número delante.

    Lo eximido, lo no medible y lo que quedó fuera de la ventana se IMPRIMEN
    igual: un término que deja de frenar y deja de verse es la misma clase de
    silencio que el gate vino a matar.
    """
    pd = find_project_dir(WS)
    if not pd:
        print("cost-check: sin transcripts, no puedo medir (fail-open).")
        return EXIT_OK

    state = task_state(args.task)
    # Precedencia: lo que el llamador dijo, después lo que la tarea declara.
    window = getattr(args, "since", None) or state.get("phase_since")
    window_ts = iso_epoch(window) if window else None
    aviso_ventana = None
    if window and window_ts is None:
        aviso_ventana = (f"ventana ilegible ({window!r}): mido TODA la historia "
                         "de la tarea. phase_since lo escribe harness-policy.py "
                         "en cada movimiento de fase")
        window = None

    rows = collect(pd, task_filter=args.task, window_ts=window_ts)
    if not rows:
        print(f"cost-check: sin transcripts para {args.task} (fail-open).")
        return EXIT_OK

    _, cost, _ = totals(rows)
    budget = args.budget
    if budget is None:
        budget = state.get("budget_usd")

    breaches, waived, unmeasurable, outside = evaluate(
        rows, args.task, budget, window)

    if getattr(args, "json", False):
        print(json.dumps({
            "task": args.task,
            "cost": round(cost, 4),
            "budget": float(budget) if budget else None,
            "cache_hit_floor": CACHE_HIT_FLOOR,
            "ctx_ceiling": CTX_CEILING,
            "min_turns_for_cache_floor": min_turns_for_cache_floor(),
            "window": window,
            "breaches": breaches,
            "waived": waived,
            "unmeasurable": unmeasurable,
            "outside": outside,
        }, ensure_ascii=False))
        return EXIT_BREACH if breaches else EXIT_OK

    print(f"cost-check {args.task}: ${cost:,.2f}"
          + (f" / ${float(budget):,.2f}" if budget else ""))
    if aviso_ventana:
        print(f"  ⚠️  {aviso_ventana}")
    elif window:
        print(f"  ventana: la fase en curso, desde {window}. COST-CACHE y "
              "COST-CTX solo miran lo que corrió ahí (es lo único sobre lo que "
              "la remediación puede actuar); el gasto en dólares es de toda la "
              "tarea")
    else:
        print("  sin ventana: esta tarea no declara phase_since, así que las "
              "bandas miran toda su historia (tarea creada antes de la ventana "
              "de fase, o estado ilegible)")
    for e in waived + unmeasurable + outside:
        print(f"  {e['text']}")
    if not breaches:
        print("dentro de banda.")
        return EXIT_OK
    print()
    for b in breaches[:8]:
        print(f"  {b['text']}")
    if len(breaches) > 8:
        print(f"  ... y {len(breaches)-8} más")
    print()
    print("Remediación: el contexto se recorta en el ARRANQUE del agente "
          "(brief destilado, no punteros a documentos), y la salida de comandos "
          "se acota con scripts/quiet.sh o evidence.py run, que ya lo hace.")
    if any(b["code"] != "COST-BUDGET" for b in breaches):
        print()
        print("Si el agente que lo disparó YA CERRÓ, esa remediación no aplica: su "
              "métrica sale de transcripts inmutables. La salida auditable es "
              "`harness-policy.py cost-waive tasks/<id> --band cache|ctx "
              "--agent <rol> --actor <quien> --reason \"<por qué>\"`, que queda en "
              "history[] y se declara en cada cost-check. `budget --to` NO sirve "
              "acá: solo mueve el término COST-BUDGET.")
        if window:
            print("Lo que ves corrió en la FASE EN CURSO: un agente de una fase "
                  "anterior ya no frena esta transición, así que el eximido "
                  "cubre esta fase y no condena a la tarea entera.")
    return EXIT_BREACH


def cmd_export(args) -> int:
    """Una línea JSON por agente. El formato para una base de datos.

    POR QUÉ JSONL Y NO UNA BASE DE VERDAD: una base es un servicio que hay que
    correr, respaldar, migrar y darle acceso a diez personas. JSONL es un
    archivo: se versiona, se grepea, se appendea, y DuckDB, BigQuery, pandas o
    `jq` lo leen sin importarlo. Empezar por el archivo no cierra la puerta a la
    base; empezar por la base sí cierra la puerta a la simplicidad.

        duckdb -c "SELECT rol, sum(costo_usd) FROM read_json_auto('docs/metrics/*.jsonl') GROUP BY 1"

    UNA LÍNEA POR AGENTE, no por tarea: el hallazgo que motivó todo esto fue que
    el 87% del gasto vive en el orquestador y no en los subagentes, y eso solo
    se ve si la fila tiene grano de AGENTE. Agregar por tarea es un GROUP BY;
    desagregar lo que se guardó agregado es imposible.
    """
    pd = find_project_dir(WS)
    if not pd:
        print("no encontré transcripts de este workspace.", file=sys.stderr)
        return EXIT_NODATA
    rows = collect(pd, since_days=args.days)
    if not rows:
        return EXIT_OK
    for r in rows:
        u = r["usage"]
        # Nombres en español y planos a propósito: quien consulte esto dentro de
        # un año no debería tener que leer este script para entender la columna.
        print(json.dumps({
            "tarea": r["task"] or None,
            "sesion": r["sid"],
            "tipo": r["kind"],
            "rol": r["role"],
            "modelo": r["model"],
            "turnos": r["turns"],
            "tool_calls": r["tools"],
            "ctx_medio": round(r["ctx_avg"]),
            "ctx_max": r["ctx_max"],
            "acierto_cache": round(r["cache_hit"], 4),
            "tok_input": u.get("input", 0),
            "tok_cache_read": u.get("cache_read", 0),
            "tok_cache_write": u.get("cache_write_total", 0),
            "tok_output": u.get("output", 0),
            "costo_usd": round(r["cost"], 4) if r["cost"] is not None else None,
            "desde": r["first"],
            "hasta": r["last"],
        }, ensure_ascii=False))
    return EXIT_OK


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="harness-cost.py",
        description="Costo real por agente, rol y tarea. Cero tokens de modelo.")
    ap.add_argument("--ws", default=None,
                    help="el workspace a medir. Sin esto se usa HARNESS_WS o la "
                         "ruta del script. Los transcripts son de Claude Code, "
                         "asi que medir NO exige una instancia del harness.")
    sub = ap.add_subparsers(dest="cmd")

    t = sub.add_parser("task", help="costo por agente y rol de una tarea")
    t.add_argument("task")
    t.set_defaults(func=cmd_task)

    d = sub.add_parser("day", help="totales y top de sesiones")
    d.add_argument("--days", type=int, default=1)
    d.add_argument("--top", type=int, default=15)
    d.set_defaults(func=cmd_day)

    e = sub.add_parser("export",
                       help="una linea JSON por agente, para una base de datos")
    e.add_argument("--days", type=int, default=None,
                   help="solo lo tocado en los ultimos N dias")
    e.set_defaults(func=cmd_export)

    c = sub.add_parser("check", help="gate: sale 3 si está fuera de banda")
    c.add_argument("task")
    c.add_argument("--budget", type=float, default=None)
    c.add_argument("--since", default=None,
                   help="instante ISO-8601 desde el que se evalúan las bandas "
                        "de tasa. Sin esto se usa el `phase_since` de la tarea "
                        "(la fase EN CURSO), que es la ventana sobre la que la "
                        "remediación impresa puede actuar")
    c.add_argument("--json", action="store_true",
                   help="el mismo veredicto legible por máquina (breaches, "
                        "eximidos y no medibles). Lo consume "
                        "harness-policy.py cost-waive, que exige que el "
                        "término EXISTA antes de dejar eximirlo")
    c.set_defaults(func=cmd_check)

    args = ap.parse_args(argv)
    if getattr(args, "ws", None):
        set_ws(args.ws)
    # DESPUÉS de resolver el workspace: los techos por rol viven en el policy
    # de ESA instancia (#120), y cargarlos antes leería el policy equivocado.
    global CTX_CEILING_BY_ROLE
    CTX_CEILING_BY_ROLE = load_ctx_ceilings()
    if not getattr(args, "func", None):
        ap.print_help()
        return EXIT_USAGE
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
