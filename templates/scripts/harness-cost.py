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
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import re
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WS = os.environ.get("HARNESS_WS") or os.path.dirname(HERE)

# ── Umbrales de banda ────────────────────────────────────────────────────────
# No son opinión: salen de la distribución medida. El acierto de caché sano
# observado es 97-99%; por debajo de 90% hay reescritura sistemática. 150k de
# contexto medio es el punto donde una invalidación empieza a costar más de $1.
CACHE_HIT_FLOOR = float(os.environ.get("HARNESS_CACHE_HIT_FLOOR", "0.90"))
CTX_CEILING = int(os.environ.get("HARNESS_CTX_CEILING", "150000"))

EXIT_OK, EXIT_USAGE, EXIT_BREACH, EXIT_NODATA = 0, 2, 3, 4


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
def scan(path: str):
    """Agrega el usage de un transcript. Fail-open: un archivo ilegible no
    rompe el reporte, se salta y se cuenta aparte."""
    t = collections.Counter()
    models = collections.Counter()
    turns = tools = 0
    ctx_samples = []
    first = last = None
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
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
                turns += 1
                models[model] += 1
                i = u.get("input_tokens", 0) or 0
                cr = u.get("cache_read_input_tokens", 0) or 0
                cwt = u.get("cache_creation_input_tokens", 0) or 0
                o = u.get("output_tokens", 0) or 0
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
                    ctx_samples.append(ctx)
                ts = rec.get("timestamp")
                if ts:
                    first = first or ts
                    last = ts
                for blk in (msg.get("content") or []):
                    if isinstance(blk, dict) and blk.get("type") == "tool_use":
                        tools += 1
    except Exception:
        return None
    if not turns:
        return None
    model = models.most_common(1)[0][0]
    return {
        "path": path,
        "model": model,
        "turns": turns,
        "tools": tools,
        "usage": dict(t),
        "cost": cost_of(model, t),
        "ctx_avg": statistics.mean(ctx_samples) if ctx_samples else 0,
        "ctx_max": max(ctx_samples) if ctx_samples else 0,
        "cache_hit": (t["cache_read"] / (t["cache_read"] + t["cache_write_total"]))
        if (t["cache_read"] + t["cache_write_total"]) else 1.0,
        "first": first,
        "last": last,
    }


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
    if at and at not in ("general-purpose", "claude", "Explore"):
        return at
    desc = (m.get("description") or "").strip().lower()
    for r in ("architect", "implementer", "reviewer", "qa", "svc-agent"):
        if desc.startswith(r) or f"{r}:" in desc or f" {r} " in f" {desc} ":
            return r
    return at or "sin-rol"


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


def collect(project_dir: str, since_days=None, task_filter=None):
    """Todas las sesiones y subagentes del workspace, con su tarea si se sabe.

    `task_filter` no es azúcar: sin él, un `check` en una transición tendría que
    escanear TODOS los transcripts del workspace para tirar el 95%, y un gate
    que tarda diez segundos es un gate que alguien va a querer apagar. Con el
    filtro solo se abren los archivos de la tarea, que son unos pocos.
    """
    s2t = session_task_map()
    cutoff = time.time() - since_days * 86400 if since_days else None
    rows = []
    for path in sorted(glob.glob(os.path.join(project_dir, "*.jsonl"))):
        if cutoff and os.path.getmtime(path) < cutoff:
            continue
        if task_filter is not None:
            sid_early = os.path.basename(path)[: -len(".jsonl")]
            if s2t.get(sid_early) != task_filter:
                continue
        r = scan(path)
        if not r:
            continue
        sid = os.path.basename(path)[: -len(".jsonl")]
        r.update(sid=sid, kind="orquestador", role="orquestador",
                 task=s2t.get(sid, ""))
        rows.append(r)
        subs = os.path.join(project_dir, sid, "subagents", "agent-*.jsonl")
        for sp in sorted(glob.glob(subs)):
            sr = scan(sp)
            if not sr:
                continue
            sr.update(sid=sid, kind="subagente", role=role_of(sp),
                      task=s2t.get(sid, ""))
            rows.append(sr)
    return rows


# ── Salida ───────────────────────────────────────────────────────────────────
def usd(v):
    return "       n/d" if v is None else f"{v:>10,.2f}"


def band(r) -> str:
    """La etiqueta que hace escaneable el reporte: qué está fuera de banda."""
    flags = []
    if r["cache_hit"] < CACHE_HIT_FLOOR:
        flags.append(f"cache {r['cache_hit']*100:.0f}%")
    if r["ctx_avg"] > CTX_CEILING:
        flags.append(f"ctx {r['ctx_avg']/1000:.0f}k")
    return " ".join(flags)


def print_rows(rows, limit=20):
    rows = sorted(rows, key=lambda r: -(r["cost"] or 0))[:limit]
    print(f"{'USD':>10} {'rol':<14} {'turnos':>7} {'tools':>6} "
          f"{'ctx medio':>10} {'cache':>6}  fuera de banda")
    print("-" * 78)
    for r in rows:
        print(f"{usd(r['cost'])} {r['role'][:14]:<14} {r['turns']:>7} "
              f"{r['tools']:>6} {r['ctx_avg']:>10,.0f} "
              f"{r['cache_hit']*100:>5.0f}%  {band(r)}")


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
        print("el puente sid→tarea lo escribe track-read.sh: si la tarea corrió "
              "sin ese hook, no hay a quién atribuirle el gasto.", file=sys.stderr)
        return EXIT_NODATA
    print(f"== {args.task} ==")
    print_rows(rows)
    by_role = collections.defaultdict(float)
    for r in rows:
        by_role[r["role"]] += r["cost"] or 0
    print()
    print("por rol:")
    for role, c in sorted(by_role.items(), key=lambda x: -x[1]):
        print(f"  {role:<16} ${c:>10,.2f}")
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


def cmd_check(args) -> int:
    """El gate. Sale 3 si la tarea está fuera de banda o excedió presupuesto.

    Fail-OPEN ante ausencia de datos y fail-CLOSED ante datos malos: si no hay
    transcripts no se puede afirmar nada y bloquear sería mentir al revés; si
    los hay y están fuera de banda, se bloquea con el número delante.
    """
    pd = find_project_dir(WS)
    if not pd:
        print("cost-check: sin transcripts, no puedo medir (fail-open).")
        return EXIT_OK
    rows = collect(pd, task_filter=args.task)
    if not rows:
        print(f"cost-check: sin transcripts para {args.task} (fail-open).")
        return EXIT_OK

    _, cost, _ = totals(rows)
    budget = args.budget
    if budget is None:
        try:
            with open(os.path.join(WS, "tasks", args.task, "state.json")) as fh:
                budget = (json.load(fh) or {}).get("budget_usd")
        except Exception:
            budget = None

    breaches = []
    if budget and cost > float(budget):
        breaches.append(
            f"COST-BUDGET: gastado ${cost:,.2f} sobre un presupuesto de "
            f"${float(budget):,.2f}")
    for r in sorted(rows, key=lambda r: -(r["cost"] or 0)):
        if r["cache_hit"] < CACHE_HIT_FLOOR:
            breaches.append(
                f"COST-CACHE: {r['role']} con {r['cache_hit']*100:.0f}% de acierto "
                f"de caché (piso {CACHE_HIT_FLOOR*100:.0f}%), "
                f"${r['cost'] or 0:,.2f} de los cuales la reescritura es la mayoría")
        if r["ctx_avg"] > CTX_CEILING:
            breaches.append(
                f"COST-CTX: {r['role']} arrastra {r['ctx_avg']/1000:.0f}k de "
                f"contexto medio (techo {CTX_CEILING/1000:.0f}k) sobre "
                f"{r['tools']} tool calls")

    print(f"cost-check {args.task}: ${cost:,.2f}"
          + (f" / ${float(budget):,.2f}" if budget else ""))
    if not breaches:
        print("dentro de banda.")
        return EXIT_OK
    print()
    for b in breaches[:8]:
        print(f"  {b}")
    if len(breaches) > 8:
        print(f"  ... y {len(breaches)-8} más")
    print()
    print("Remediación: el contexto se recorta en el ARRANQUE del agente "
          "(brief destilado, no punteros a documentos), y la salida de comandos "
          "se acota con scripts/quiet.sh o evidence.py run, que ya lo hace.")
    return EXIT_BREACH


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="harness-cost.py",
        description="Costo real por agente, rol y tarea. Cero tokens de modelo.")
    sub = ap.add_subparsers(dest="cmd")

    t = sub.add_parser("task", help="costo por agente y rol de una tarea")
    t.add_argument("task")
    t.set_defaults(func=cmd_task)

    d = sub.add_parser("day", help="totales y top de sesiones")
    d.add_argument("--days", type=int, default=1)
    d.add_argument("--top", type=int, default=15)
    d.set_defaults(func=cmd_day)

    c = sub.add_parser("check", help="gate: sale 3 si está fuera de banda")
    c.add_argument("task")
    c.add_argument("--budget", type=float, default=None)
    c.set_defaults(func=cmd_check)

    args = ap.parse_args(argv)
    if not getattr(args, "func", None):
        ap.print_help()
        return EXIT_USAGE
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
