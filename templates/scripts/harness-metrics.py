#!/usr/bin/env python3
"""harness-metrics.py: en que se va el tiempo, donde falla, y si algo empeoro.

POR QUE EXISTE
El harness ya escribe todo lo que hace falta para medirse: cada corrida de test
sella un manifiesto con started_at/finished_at/exit_code/contention, cada gate
deja un evento en el bus, y state.json guarda las rondas de review con su traza
de bloqueantes. Lo que faltaba no era instrumentacion: era que alguien lo leyera
JUNTO. Los cuatro falsos rojos que costaron rondas enteras (el diff de puntas,
el runner que no colecta, el disco lleno, la contencion por un navegador) se
descubrieron de a uno, a mano, meses despues. Estaban en los datos desde el
primer dia.

LAS TRES LEYES DE ESTE ARCHIVO
1. CERO en el camino caliente. No mide nada mientras una tarea corre: LEE
   artefactos que ya estaban escritos. Se invoca cuando la tarea ya murio
   (/archive) o a mano (`make metrics`). Una tarea no paga por esto.
2. FAIL-OPEN, como el bus. Sale 0 pase lo que pase. Telemetria que puede
   tumbar un ship es un bug, no una feature.
3. ACOTADO POR CONSTRUCCION. `report` no crece con los datos: top-N fijo,
   secciones fijas, tope duro de lineas. Ningun agente lee el jsonl crudo;
   lo unico que llega a una ventana de contexto es el informe, que lo produce
   codigo determinista. Un agente "analizando metricas" es exactamente el
   consumidero de tokens que este diseño existe para evitar.

EL LIMITE ESTADISTICO, DICHO DE FRENTE
Con decenas de tareas esto NO prueba que una intervencion (un modelo, un MCP de
memoria, un grafo de codigo) mejore nada: la varianza entre tareas se come
cualquier efecto y las tareas no son intercambiables. Para lo que SI sirve, y
es lo que se necesita, es para detectar REGRESIONES: un stack cuya tasa de
falso rojo o de rondas gastadas salta se ve con n chico. Por eso los grupos con
menos de MIN_N tareas se imprimen con su n y sin veredicto.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone

SCHEMA = 1
MIN_N = 3          # tareas por stack antes de mostrar cualquier comparacion
TOP_DEFAULT = 5
TOP_MAX = 10
MAX_LINES = 100    # tope duro del informe; tests/test_metrics.py lo asegura
MAX_COLS = 120

# Umbrales de escalacion. Constantes, no configurables: un knob aca es una
# perilla para silenciar la señal, que es justo lo que no queremos.
ESC_FALSE_RED_MIN = 3       # apariciones del mismo gate...
ESC_FALSE_RED_TASKS = 2     # ...repartidas en al menos estas tareas
ESC_WASTE_RATIO = 0.5       # rondas gastadas sobre rondas totales
ESC_WASTE_TASKS = 5


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_ts(value):
    """ISO-Z a epoch. Devuelve None ante cualquier basura: una fila con un ts
    podrido no puede tumbar la corrida entera."""
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue      # una linea rota no invalida el archivo
    except OSError:
        pass
    return rows


def _sha12(text):
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:12]


# ── models.yaml: el formato estricto de dos niveles que parsea stamp-models ──
# Se replica en python en vez de invocar al script: son cero forks y el formato
# esta congelado por contrato (secciones a columna 0, claves con dos espacios).
def _parse_models(path):
    roles, section = {}, ""
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                if not line.startswith(" "):
                    section = line.split(":", 1)[0].strip()
                    continue
                if section == "roles" and ":" in line:
                    key, _, value = line.strip().partition(":")
                    roles[key.strip()] = value.split("#", 1)[0].strip()
    except OSError:
        return {}
    return roles


# ── El STACK: que intervenciones estaban activas ─────────────────────────
# GENERICO A PROPOSITO. No hay una lista cableada de herramientas: se leen las
# claves de .mcp.json, las capabilities declaradas en harness-answers.yaml y
# una regla de artefactos por nombre. Una herramienta que se agregue mañana se
# mide sola, sin tocar este archivo. Cablear nombres seria construir el sesgo
# de solo poder evaluar lo que ya sospechabamos.
def _capability_bins(answers_path):
    names = []
    try:
        with open(answers_path, encoding="utf-8") as fh:
            for raw in fh:
                stripped = raw.strip()
                if stripped.startswith("bin:"):
                    value = stripped.split(":", 1)[1].strip()
                    if value and not value.startswith("{{"):
                        names.append(value)
    except OSError:
        pass
    return sorted(set(names))


def _tool_state(ws, name):
    """present/version/artifacts de una herramienta, sin conocerla de antemano.

    La regla de artefactos es por NOMBRE, no por catalogo: `<name>-out/` y
    `.<name>ignore` son la convencion que usan las herramientas de indexado
    (un grafo de codigo deja su manifiesto ahi). Que una caiga en la regla no
    la vuelve un caso especial de este archivo.
    """
    path = shutil.which(name)
    version = None
    if path:
        try:
            out = subprocess.run([path, "--version"], text=True, timeout=5,
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, check=False).stdout
            version = (out or "").strip().splitlines()[0][:40] or None
        except (OSError, subprocess.SubprocessError, IndexError):
            version = None
    artifacts = os.path.isfile(os.path.join(ws, name + "-out", "manifest.json")) \
        or os.path.exists(os.path.join(ws, "." + name + "ignore"))
    return {"present": bool(path), "version": version, "artifacts": artifacts}


def collect_stack(ws):
    mcp_doc = _read_json(os.path.join(ws, ".mcp.json")) or {}
    servers = mcp_doc.get("mcpServers")
    mcp = sorted(servers.keys()) if isinstance(servers, dict) else []

    answers = os.path.join(ws, "harness-answers.yaml")
    tools = {}
    for name in _capability_bins(answers):
        tools[name] = _tool_state(ws, name)

    memory = _answers_scalar(answers, "memory", "provider")

    stack = {
        "models": _parse_models(os.path.join(ws, "models.yaml")),
        "mcp": mcp,
        "memory_provider": memory,
        "tools": tools,
    }
    stack["fp"] = _sha12(json.dumps(stack, sort_keys=True))
    return stack


def _answers_scalar(path, section, key):
    """Un escalar de `<section>:\\n  <key>: valor` en harness-answers.yaml."""
    current = ""
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                if not line.startswith(" "):
                    current = line.split(":", 1)[0].strip()
                    continue
                if current == section and ":" in line:
                    name, _, value = line.strip().partition(":")
                    if name.strip() == key:
                        return value.split("#", 1)[0].strip()
    except OSError:
        pass
    return ""


# ── La fila por tarea ────────────────────────────────────────────────────
def _bus_for_task(ws, task_id):
    rows = _read_jsonl(os.path.join(ws, ".harness", "events.jsonl"))
    out = []
    for row in rows:
        if isinstance(row, dict) and row.get("task") == task_id:
            ts = _parse_ts(row.get("ts"))
            if ts is not None:
                out.append((ts, row))
    out.sort(key=lambda pair: pair[0])
    return out


def _gate_name(summary):
    """El nombre del gate dentro del summary, en los TRES formatos que emite
    ship.sh. Que los tres devuelvan el MISMO nombre es lo que hace que el rojo
    y el verde del mismo gate se puedan cruzar; con dos nombres distintos la
    metrica de falsos rojos sale vacia y parece que no hay ninguno.

    Caso de campo: la primera version cortaba en el primer ' (' para quitar el
    '(exit N)', y con eso el gate 'el test nuevo MUERDE (rojo sobre la base)'
    se partia al medio. El rojo se registraba con el nombre completo y el verde
    con la mitad, asi que jamas cruzaban. Lo cazo una corrida de humo con datos
    realistas, no la suite: los fixtures usaban nombres sin parentesis.
    """
    if not isinstance(summary, str):
        return ""
    text = summary.strip()
    # 1. `<gate> <sep> BLOQUEÓ el ship de <repo> (exit N)`, donde <sep> es el
    #    guion largo que usa ship.sh. Se construye con su codepoint porque el
    #    literal esta prohibido por la ley de estilo del repo (CONTRIBUTING #6)
    #    y el ratchet de tests/test_docs.sh lo cuenta.
    for marker in (" \u2014 BLOQUE", " - BLOQUE"):
        idx = text.find(marker)
        if idx > 0:
            return text[:idx].strip()
    # 2. `precheck de <repo> rojo (<gate>): ronda de review AHORRADA`
    if text.startswith("precheck de ") and "(" in text and ")" in text:
        inicio = text.find("(") + 1
        fin = text.rfind(")")
        if fin > inicio:
            return text[inicio:fin].strip()
    # 3. el nombre pelado del gate que paso
    return text[:60]


def _durations_from_bus(events, kind):
    """Duracion por nombre: delta hasta el evento siguiente del MISMO kind.
    Aproximado por construccion (resolucion 1s del bus, y el ultimo tramo no
    tiene sucesor), y por eso los gates prefieren el campo `dur` cuando esta.
    """
    out, marks = {}, []
    for ts, row in events:
        if row.get("kind") == kind:
            marks.append((ts, row))
    for index, (ts, row) in enumerate(marks):
        if index + 1 >= len(marks):
            continue
        name = _gate_name(row.get("summary"))
        if not name:
            continue
        out[name] = out.get(name, 0) + max(0, int(marks[index + 1][0] - ts))
    return out


def _collect_gates(events):
    by_gate, blocks = {}, {}
    for _ts, row in events:
        if row.get("kind") != "gate":
            continue
        name = _gate_name(row.get("summary"))
        if not name:
            continue
        dur = row.get("dur")
        if isinstance(dur, (int, float)) and dur >= 0:
            by_gate[name] = by_gate.get(name, 0) + int(dur)
        if row.get("ok") is False:
            key = (name, str(row.get("actor") or ""))
            blocks[key] = blocks.get(key, 0) + 1
    return by_gate, blocks


def _false_red_same_change(events, manifests):
    """LA METRICA ESTRELLA: un gate que salio ROJO y despues VERDE sin que el
    codigo cambiara entre medio. Si nadie toco el codigo, ese rojo no era del
    codigo: era del gate, del entorno o de la maquina. Cada aparicion aca es
    una ronda que alguien pago por nada, y es la clase de defecto que este
    harness descubrio cuatro veces de a una, a mano.
    """
    sellos = sorted(
        [(_parse_ts(m.get("started_at")), m.get("repo"), m.get("commit"))
         for m in manifests if _parse_ts(m.get("started_at")) is not None],
        key=lambda triple: triple[0])
    hits, abierto = [], {}
    for ts, row in events:
        if row.get("kind") != "gate":
            continue
        name = _gate_name(row.get("summary"))
        repo = str(row.get("actor") or "")
        if not name:
            continue
        key = (name, repo)
        if row.get("ok") is False:
            abierto[key] = ts
        elif row.get("ok") is True and key in abierto:
            desde = abierto.pop(key)
            commits = {c for (t, r, c) in sellos
                       if r == repo and desde < t <= ts and c}
            previos = [c for (t, r, c) in sellos if r == repo and t <= desde and c]
            base = previos[-1] if previos else None
            # Si en la ventana no se sello NINGUN commit distinto del que ya
            # habia, el arbol no se movio y el verde no lo trajo un fix.
            if not (commits - {base}):
                hits.append({"gate": name, "repo": repo})
    return hits


def _wasted_rounds(series_by_repo):
    """Rondas que no movieron la aguja: la ronda i cuenta como gastada si sus
    bloqueantes no BAJARON respecto de la anterior. Es el mismo criterio de
    convergencia que harness-policy.py usa para decidir si concede una ronda
    extra, mirado desde el otro lado."""
    total = 0
    for series in (series_by_repo or {}).values():
        if not isinstance(series, list):
            continue
        for index in range(1, len(series)):
            try:
                if int(series[index]) >= int(series[index - 1]):
                    total += 1
            except (TypeError, ValueError):
                continue
    return total


def collect_task(ws, task_id):
    task_dir = os.path.join(ws, "tasks", task_id)
    state = _read_json(os.path.join(task_dir, "state.json")) or {}
    events = _bus_for_task(ws, task_id)

    manifests = []
    ev_dir = os.path.join(task_dir, "evidence")
    try:
        names = sorted(os.listdir(ev_dir))
    except OSError:
        names = []
    for name in names:
        if name.startswith("EV-") and name.endswith(".json"):
            doc = _read_json(os.path.join(ev_dir, name))
            if isinstance(doc, dict):
                manifests.append(doc)

    tests = {"count": 0, "total_s": 0, "max_s": 0, "by_repo": {}}
    suspect = red_contention = 0
    for man in manifests:
        if man.get("contention", {}).get("suspect") is True:
            suspect += 1
            if man.get("exit_code") not in (0, None):
                red_contention += 1
        if man.get("kind") != "test":
            continue
        start, end = _parse_ts(man.get("started_at")), _parse_ts(man.get("finished_at"))
        if start is None or end is None:
            continue
        secs = max(0, int(end - start))
        repo = str(man.get("repo") or "?")
        tests["count"] += 1
        tests["total_s"] += secs
        tests["max_s"] = max(tests["max_s"], secs)
        bucket = tests["by_repo"].setdefault(repo, {"count": 0, "total_s": 0})
        bucket["count"] += 1
        bucket["total_s"] += secs

    by_gate, blocks = _collect_gates(events)
    if not by_gate:
        # Bus de una version sin el campo `dur`: se cae a los deltas entre
        # eventos. Peor resolucion, pero mejor que no medir nada.
        by_gate = _durations_from_bus(events, "gate")

    history = state.get("history") if isinstance(state.get("history"), list) else []
    ambient = sum(1 for _ts, row in events
                  if row.get("kind") == "assumption"
                  and "causa ambiental" in str(row.get("summary", "")))
    series = state.get("review_blocking_by_repo") or {}

    wall = None
    if len(events) >= 2:
        wall = max(0, int(events[-1][0] - events[0][0]))

    row = {
        "schema": SCHEMA,
        "task_id": task_id,
        "collected_at": _now(),
        "state_sha": _sha12(json.dumps(state, sort_keys=True)),
        "harness_version": _harness_version(ws),
        "lane": state.get("lane") or "",
        "delivery": state.get("delivery"),
        "phase_final": state.get("phase") or "",
        "repos": state.get("repos") if isinstance(state.get("repos"), list) else [],
        "budget_usd": state.get("budget_usd"),
        "spent_usd": state.get("spent_usd"),
        "stack": collect_stack(ws),
        "durations": {
            "wall_clock_s": wall,
            "by_phase_s": _durations_from_bus(events, "phase"),
            "by_gate_s": by_gate,
            "tests": tests,
        },
        "review": {
            "rounds_by_repo": state.get("review_rounds_by_repo") or {},
            "blocking_series_by_repo": series,
            "wasted_rounds": _wasted_rounds(series),
            "rollbacks": sum(1 for h in history
                             if isinstance(h, dict) and h.get("kind") == "rollback"),
        },
        "gates": {
            "blocks": [{"gate": g, "repo": r, "count": c}
                       for (g, r), c in sorted(blocks.items(), key=lambda kv: -kv[1])],
            "false_red": {
                "contention": red_contention,
                "ambient": ambient,
                "red_then_green_same_change": _false_red_same_change(events, manifests),
            },
        },
        "evidence": {"count": len(manifests), "suspect": suspect,
                     "red_under_contention": red_contention},
        "outcome": {
            "shipped": sorted({str(r.get("actor") or "")
                               for _t, r in events
                               if r.get("kind") == "ship" and r.get("ok") is not False}),
            "deploys_ok": sum(1 for _t, r in events
                              if r.get("kind") == "deploy" and r.get("ok") is True),
            "deploys_red": sum(1 for _t, r in events
                               if r.get("kind") == "deploy" and r.get("ok") is False),
            "stops": sum(1 for _t, r in events if r.get("kind") == "stop"),
        },
    }
    return row


def _harness_version(ws):
    try:
        with open(os.path.join(ws, ".harness-version"), encoding="utf-8") as fh:
            return fh.read().strip()[:20]
    except OSError:
        return ""


def _rows_path(ws):
    return os.path.join(ws, ".harness", "metrics", "tasks.jsonl")


def load_rows(ws):
    """Ultima fila por task_id: mismo patron append-only con last-wins que el
    bus y el ledger de harness-bug. Sin sqlite y sin un segundo formato."""
    latest = {}
    for row in _read_jsonl(_rows_path(ws)):
        if isinstance(row, dict) and row.get("task_id"):
            latest[row["task_id"]] = row
    return [latest[key] for key in sorted(latest)]


def cmd_collect(ws, args):
    tasks_dir = os.path.join(ws, "tasks")
    if "--all" in args:
        try:
            wanted = sorted(name for name in os.listdir(tasks_dir)
                            if os.path.isfile(os.path.join(tasks_dir, name, "state.json")))
        except OSError:
            wanted = []
    else:
        wanted = [args[args.index("--task") + 1]] if "--task" in args else []
    if not wanted:
        print("uso: harness-metrics.py collect (--task <id> | --all)")
        return 0

    force = "--force" in args
    known = {row.get("task_id"): row.get("state_sha") for row in load_rows(ws)}
    path = _rows_path(ws)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
    except OSError:
        return 0
    escritas = 0
    for task_id in wanted:
        try:
            row = collect_task(ws, task_id)
        except Exception:            # noqa: BLE001 - fail-open, es telemetria
            continue
        if not force and known.get(task_id) == row["state_sha"]:
            continue
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(row, sort_keys=True) + "\n")
            escritas += 1
        except OSError:
            continue
    print("✅ metricas: %d tarea(s) recolectada(s) en %s"
          % (escritas, os.path.relpath(path, ws)))
    return 0


# ── El informe: acotado por construccion ─────────────────────────────────
def _fit(text):
    return text if len(text) <= MAX_COLS else text[:MAX_COLS - 1] + "…"


def _top(counter, top):
    return sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))[:top]


def _hms(seconds):
    seconds = int(seconds or 0)
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm%02ds" % (seconds // 60, seconds % 60)
    return "%dh%02dm" % (seconds // 3600, (seconds % 3600) // 60)


def cmd_report(ws, args):
    rows = load_rows(ws)
    top = TOP_DEFAULT
    if "--top" in args:
        try:
            top = max(1, min(TOP_MAX, int(args[args.index("--top") + 1])))
        except (IndexError, ValueError):
            top = TOP_DEFAULT
    if "--json" in args:
        print(json.dumps(rows, sort_keys=True))
        return 0

    out = ["── métricas del harness: %d tarea(s)" % len(rows)]
    if not rows:
        out.append("   (sin filas: corré `harness-metrics.py collect --all`)")
        print("\n".join(out))
        return 0

    fases, gates_t, tests_repo, bloqueos, falsos = {}, {}, {}, {}, {}
    gastadas = rondas = suspect = evidencia = 0
    for row in rows:
        dur = row.get("durations", {})
        for name, secs in (dur.get("by_phase_s") or {}).items():
            fases[name] = fases.get(name, 0) + int(secs or 0)
        for name, secs in (dur.get("by_gate_s") or {}).items():
            gates_t[name] = gates_t.get(name, 0) + int(secs or 0)
        for repo, info in ((dur.get("tests") or {}).get("by_repo") or {}).items():
            tests_repo[repo] = tests_repo.get(repo, 0) + int(info.get("total_s") or 0)
        for block in (row.get("gates", {}) or {}).get("blocks") or []:
            bloqueos[block.get("gate", "?")] = \
                bloqueos.get(block.get("gate", "?"), 0) + int(block.get("count") or 0)
        for hit in ((row.get("gates", {}) or {}).get("false_red") or {}) \
                .get("red_then_green_same_change") or []:
            falsos[hit.get("gate", "?")] = falsos.get(hit.get("gate", "?"), 0) + 1
        review = row.get("review", {}) or {}
        gastadas += int(review.get("wasted_rounds") or 0)
        rondas += sum(int(v or 0) for v in (review.get("rounds_by_repo") or {}).values())
        ev = row.get("evidence", {}) or {}
        suspect += int(ev.get("suspect") or 0)
        evidencia += int(ev.get("count") or 0)

    def seccion(titulo, pares, fmt):
        out.append("")
        out.append(titulo)
        if not pares:
            out.append("   (nada registrado)")
            return
        for name, value in pares:
            out.append(_fit("   %-42s %s" % (name[:42], fmt(value))))

    seccion("· dónde se va el tiempo (por fase)", _top(fases, top), _hms)
    seccion("· gates más caros", _top(gates_t, top), _hms)
    seccion("· suites de test por repo", _top(tests_repo, top), _hms)
    seccion("· gates que más bloquean", _top(bloqueos, top), lambda v: "%d veces" % v)
    seccion("· FALSOS ROJOS (rojo y después verde sin que el código cambiara)",
            _top(falsos, top), lambda v: "%d veces" % v)

    out.append("")
    out.append("· fricción de review")
    out.append(_fit("   rondas gastadas (no bajaron bloqueantes)  %d de %d" % (gastadas, rondas)))
    out.append("")
    out.append("· contención al sellar evidencia")
    out.append(_fit("   sellos marcados sospechosos              %d de %d" % (suspect, evidencia)))

    out.append("")
    out.append("· por stack (modelos + MCP + herramientas activas)")
    porstack = {}
    for row in rows:
        fp = (row.get("stack") or {}).get("fp", "?")
        acc = porstack.setdefault(fp, {"n": 0, "falsos": 0, "gastadas": 0})
        acc["n"] += 1
        acc["falsos"] += len(((row.get("gates", {}) or {}).get("false_red") or {})
                             .get("red_then_green_same_change") or [])
        acc["gastadas"] += int((row.get("review", {}) or {}).get("wasted_rounds") or 0)
    for fp, acc in sorted(porstack.items(), key=lambda kv: -kv[1]["n"])[:TOP_DEFAULT]:
        if acc["n"] < MIN_N:
            out.append(_fit("   %s  n=%d: insuficiente para comparar" % (fp, acc["n"])))
        else:
            out.append(_fit("   %s  n=%-3d falsos rojos %-4d rondas gastadas %d"
                            % (fp, acc["n"], acc["falsos"], acc["gastadas"])))
    out.append("   (n chico solo detecta REGRESIONES; no prueba que un stack sea mejor)")

    print("\n".join(out[:MAX_LINES]))
    return 0


# ── El bucle de automejora: termina en un issue upstream, no en un dashboard ──
def _escalations(rows):
    """Señales que superan umbral, con su artefacto dueño. El titulo es ESTABLE
    (sin numeros): la huella de harness-bug.sh dedupea entre corridas y entre
    maquinas, asi que N instancias con el mismo defecto convergen al mismo
    issue upstream en vez de abrir N. Eso es lo que hace que esto sirva con
    mucha gente usando el harness."""
    por_gate, tareas = {}, {}
    gastadas = rondas = 0
    for row in rows:
        vistos = set()
        for hit in ((row.get("gates", {}) or {}).get("false_red") or {}) \
                .get("red_then_green_same_change") or []:
            gate = hit.get("gate", "?")
            por_gate[gate] = por_gate.get(gate, 0) + 1
            vistos.add(gate)
        for gate in vistos:
            tareas[gate] = tareas.get(gate, 0) + 1
        review = row.get("review", {}) or {}
        gastadas += int(review.get("wasted_rounds") or 0)
        rondas += sum(int(v or 0) for v in (review.get("rounds_by_repo") or {}).values())

    señales = []
    for gate, count in sorted(por_gate.items(), key=lambda kv: -kv[1]):
        if count >= ESC_FALSE_RED_MIN and tareas.get(gate, 0) >= ESC_FALSE_RED_TASKS:
            señales.append({
                "titulo": "metrics: falsos rojos recurrentes en el gate '%s'" % gate,
                "archivo": "scripts/ship.sh",
                "detalle": "%d apariciones en %d tareas: el gate salio rojo y despues "
                           "verde sin que el codigo cambiara entre medio"
                           % (count, tareas.get(gate, 0)),
            })
    if len(rows) >= ESC_WASTE_TASKS and rondas > 0 \
            and (gastadas / float(rondas)) >= ESC_WASTE_RATIO:
        señales.append({
            "titulo": "metrics: mas de la mitad de las rondas de review no bajan bloqueantes",
            "archivo": "scripts/harness-policy.py",
            "detalle": "%d de %d rondas en %d tareas no bajaron el conteo de bloqueantes"
                       % (gastadas, rondas, len(rows)),
        })
    return señales


def cmd_escalate(ws, args):
    rows = load_rows(ws)
    señales = _escalations(rows)
    if not señales:
        print("✅ metricas: ninguna señal supera umbral (nada que reportar upstream)")
        return 0
    repro_dir = os.path.join(ws, ".harness", "metrics")
    try:
        os.makedirs(repro_dir, exist_ok=True)
    except OSError:
        return 0
    for señal in señales:
        fp = _sha12(señal["titulo"])
        repro = os.path.join(repro_dir, "repro-%s.txt" % fp)
        try:
            with open(repro, "w", encoding="utf-8") as fh:
                fh.write("%s\n\n%s\n\nTareas consideradas: %d\n"
                         % (señal["titulo"], señal["detalle"], len(rows)))
        except OSError:
            continue
        cmd = ("scripts/harness-bug.sh report --title %s --file %s --repro %s "
               "--impact %s" % (json.dumps(señal["titulo"]), señal["archivo"],
                                os.path.relpath(repro, ws),
                                json.dumps("cualquier instancia con este stack")))
        if "--run" in args:
            subprocess.run(["bash", "-c", cmd], cwd=ws, check=False)
        else:
            print(cmd)
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[0])
        print("uso: harness-metrics.py <collect|stack|report|escalate> [flags]")
        return 0
    args = argv[2:]
    ws = os.environ.get("WS") or os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(argv[0])), ".."))
    if "--ws" in args:
        ws = os.path.abspath(args[args.index("--ws") + 1])
    command = argv[1]
    if command == "collect":
        return cmd_collect(ws, args)
    if command == "stack":
        print(json.dumps(collect_stack(ws), indent=2, sort_keys=True))
        return 0
    if command == "report":
        return cmd_report(ws, args)
    if command == "escalate":
        return cmd_escalate(ws, args)
    print("subcomando desconocido: %s" % command)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception:                # noqa: BLE001
        # Ley 2: fail-open. La telemetria jamas tumba a quien la invoca.
        sys.exit(0)
