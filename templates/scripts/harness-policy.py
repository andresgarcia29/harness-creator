#!/usr/bin/env python3
"""Policy engine v1 for task transitions and the final ship contract."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

# Ventana por defecto para reusar un veredicto cuyo commit cambió por rebase.
# Conservadora a propósito: el juicio caduca en el TIEMPO, no solo en el texto.
DEFAULT_VERDICT_REUSE = {"enabled": True, "max_age_hours": 24, "max_base_commits": 200}


def fail(code: str, message: str) -> "None":
    print(f"{code}: {message}", file=sys.stderr)
    raise SystemExit(3)


def load(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail("POLICY-SCHEMA-001", f"{label} inválido: {exc}")
    if not isinstance(value, dict):
        fail("POLICY-SCHEMA-002", f"{label} debe ser un objeto JSON")
    return value


def atomic(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def state_path(task_dir: Path) -> Path:
    return task_dir / "state.json"


def emit_bus(task_dir: Path, kind: str, summary: str) -> None:
    """Cuenta el movimiento de fase en el bus, que es lo que el humano mira.

    Las transiciones se imprimian por stdout y nada mas, asi que el panel (la
    vista real: `make ui`) no tenia ni un evento de fase. Lo que no se emite,
    para quien mira el tablero NO PASO, y el estado de una tarea se volvia algo
    que solo se puede reconstruir leyendo archivos a mano.

    Fail-open y con timeout, igual que emit.sh: un bus caido no puede impedir
    que una tarea avance."""
    try:
        ws = task_dir.parent.parent
        script = ws / "scripts" / "emit.sh"
        if not script.is_file():
            return
        subprocess.run(
            ["bash", str(script), kind, summary, "", task_dir.name],
            cwd=str(ws), timeout=5, check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


_LOCKS_HELD = []   # mantiene vivos los fd: si el GC los cierra, se suelta el lock


def lock_state(task_dir: Path) -> None:
    """Serializa el read-modify-write de state.json ENTRE PROCESOS.

    atomic() garantiza que el archivo nunca queda a medias, pero no que dos
    procesos no se pisen, y son cosas distintas: entre el load() y el
    atomic() no hay nada que impida a otra sesión escribir en medio. Dos
    comandos concurrentes sobre la misma tarea leerían el mismo estado, cada
    uno agregaría SU entrada a history[] y el último en escribir borraría la
    del otro, sin que ninguno se entere.

    HONESTIDAD SOBRE LA MEDICIÓN: la ventana es estrecha y no se pudo
    disparar a propósito (90 rollbacks concurrentes en 3 rondas, cero
    pérdidas: el arranque del intérprete domina el tiempo y el planificador
    escalona los procesos). O sea que esto NO tapa un bug observado, cierra
    una carrera real pero difícil de provocar, en el componente que decide
    si algo se puede shippear. Cuesta un open() y un flock().

    No se libera a mano A PROPÓSITO: cada invocación de este CLI hace UNA
    mutación y sale, así que la vida del proceso es la sección crítica. El
    kernel suelta el flock al cerrar el fd pase lo que pase, incluido el
    SystemExit de fail() o un kill -9, así que no hay locks huérfanos que
    reclamar (a diferencia del lock por mkdir de ship.sh, que sí necesita su
    ronda de reclamo porque un directorio sobrevive a su dueño).

    flock es advisory y local: vale para un workspace en disco. Sobre NFS no
    es de fiar, pero un workspace de worktrees en red ya sería otro problema."""
    task_dir.mkdir(parents=True, exist_ok=True)
    fd = os.open(task_dir / ".state.lock", os.O_CREAT | os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    _LOCKS_HELD.append(fd)


# Orden canónico de fases. Solo lo usa `rollback` para saber qué es "atrás";
# el grafo de avance sigue siendo allowed_transitions. Fallback para
# instancias viejas cuyo policy.json todavía no lo declara.
DEFAULT_PHASE_ORDER = ["intake", "rfc", "implement", "review", "ship", "deploy", "archive"]


def phase_order(policy: dict) -> list:
    order = policy.get("workflow", {}).get("phase_order")
    if isinstance(order, list) and all(isinstance(p, str) for p in order) and order:
        return order
    return DEFAULT_PHASE_ORDER


def phase_is_declared(state: dict, policy: dict) -> bool:
    """La fase actual tiene que ser la que dejó el último movimiento registrado.

    Todo comando que mueve `phase` (transition, escalate, pause, resume,
    rollback) hace append a `history`, así que el invariante es: o la tarea
    nunca se movió y sigue en initial_phase, o history[-1].to == phase. Una
    edición a mano de state.json rompe el invariante y por eso se detecta:
    el `history` dejó de ser prosa y pasó a ser un control.

    Las entradas kind=delivery NO son movimientos de fase: promover la entrega
    no mueve la tarea de fase. Se saltean para buscar el último movimiento real,
    porque si contaran, un `delivery --to prs` en fase review dejaría un
    history[-1].to inexistente y validate-ship acusaría de edición a mano a
    quien usó el CLI. El resto de la regla queda igual: una entrada que no es
    un objeto sigue delatando la edición manual."""
    history = state.get("history")
    if not isinstance(history, list):
        history = []
    moves = [e for e in history
             if not (isinstance(e, dict) and e.get("kind") == "delivery")]
    if not moves:
        return state.get("phase") == policy.get("workflow", {}).get("initial_phase")
    last = moves[-1]
    return isinstance(last, dict) and last.get("to") == state.get("phase")


# ENTREGA: qué se publica al final del run, DECLARADO por el comando que abrió
# la tarea, no preguntado en el chat al terminar. El vocabulario es el mismo de
# `flow` (harness-answers.yaml) a propósito: una sola palabra para una sola
# idea. El orden de la tupla ES la escalera de publicación, y cada peldaño
# publica más que el anterior:
#   review → no se publica nada (commits locales del worktree sí; push, PR y
#            trunk jamás). Es donde termina /smart si nadie autoriza más.
#   prs    → rama publicada y PR abierto.
#   trunk  → ship directo a la trunk.
# AUSENTE en state.json es el cuarto caso y NO es un peldaño: significa que la
# tarea es de antes de esta decisión (o de /quick), y entonces ship usa el flow
# del workspace, como siempre.
DELIVERY_MODES = ("review", "prs", "trunk")


def delivery_of(state: dict) -> "str | None":
    """La entrega declarada en state.json, o None si la tarea no declara ninguna.

    Un valor fuera del catálogo muere tipado: es state.json editado a mano, y
    adivinar (o caer al flow del workspace) convertiría una entrega ilegible en
    una publicación que nadie autorizó."""
    value = state.get("delivery")
    if value is None:
        return None
    if value not in DELIVERY_MODES:
        fail("POLICY-DELIVERY-001",
             f"entrega desconocida en state.json: {value!r} "
             f"(válidas: {', '.join(DELIVERY_MODES)}). No puedo tratar una "
             "entrega ilegible como 'sin declarar': eso publicaría por el flow "
             "del workspace algo que quizá se declaró como review")
    return value


def repos_pending_ship(task_dir: Path) -> list:
    """Repos de la tarea que ya tienen veredicto pero todavía no shippearon.

    ship.sh se corre UNA VEZ POR REPO y exige phase=review. O sea que avanzar
    la fase antes de que shippee el último repo deja a los que faltan sin
    camino: allowed_transitions["ship"] es ["deploy"] y no hay vuelta.

    CASO REAL: tarea de dos repos, se hizo review → ship tras shippear el
    primero, y el segundo quedó con verdict pass, qa pass, 0 blocking, todos
    los gates mecánicos en verde... y trabado por el número de fase. Lo único
    rojo era la secuencia.

    /smart ya lo pedía en prosa ("tras todos los repos verdes solicita review →
    ship"). La prosa no frena a nadie. Las dos fuentes son artefactos que ya
    existen: verdict-<repo>.json y ship.log (una línea por repo shippeado).

    Límite: un repo de la tarea que todavía no tiene veredicto no se cuenta
    AQUÍ. Ese caso lo cierra repos_missing_verdict, que lee el inventario que
    sí existe cuando hay DAG: tasks/<id>/dag.json."""
    verdicts = sorted(
        p.name[len("verdict-"):-len(".json")]
        for p in task_dir.glob("verdict-*.json")
    )
    shipped = set()
    log = task_dir / "ship.log"
    if log.exists():
        for line in log.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                shipped.add(json.loads(line).get("repo"))
            except json.JSONDecodeError:
                continue   # una línea corrupta no debe fingir que un repo shippeó
    return [r for r in verdicts if r not in shipped]


def repos_planned(task_dir: Path) -> list:
    """Repos que el DAG de la tarea declara como parte del trabajo.

    Sin dag.json (los carriles quick y express no generan DAG) devuelve []: el
    gate se comporta como siempre. Un dag ILEGIBLE en cambio bloquea: ignorarlo sería
    fail-open (los repos planificados desaparecen del conteo y la fase avanza
    en verde), que es exactamente el agujero que esta función cierra. Caso de
    campo: shippear el primer repo movió la tarea entera a ship y el review
    del segundo, planificado en el DAG pero aún sin veredicto, quedó sin
    camino; hubo que hacer rollback."""
    dag_path = task_dir / "dag.json"
    if not dag_path.exists():
        return []
    try:
        dag = json.loads(dag_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail("POLICY-SHIP-004",
             f"tasks/{task_dir.name}/dag.json ilegible ({exc}): no puedo saber qué "
             "repos planificó esta tarea, y avanzar a ciegas deja repos sin camino. "
             "Regenerá el DAG (fase rfc) y validalo con 'harness-policy.py "
             f"validate-dag tasks/{task_dir.name}/dag.json'")
    tasks = dag.get("tasks") if isinstance(dag, dict) else None
    if not isinstance(dag, dict) or dag.get("schema") != 1 or not isinstance(tasks, list):
        fail("POLICY-SHIP-004",
             f"tasks/{task_dir.name}/dag.json no cumple schema:1 con tasks[]: "
             "corré 'harness-policy.py validate-dag' y regeneralo antes de "
             "pedir review → ship")
    repos = []
    for item in tasks:
        if isinstance(item, dict):
            repo = item.get("repo")
            if isinstance(repo, str) and repo and repo not in repos:
                repos.append(repo)
    return repos


def repos_missing_verdict(task_dir: Path, extra_repos=()) -> list:
    """Repos planificados que ni siquiera tienen veredicto todavía.

    Dos fuentes, en unión: el DAG de la tarea (tasks/<id>/dag.json) y lo que
    init registró en state.repos (issue #34: el carril express no genera DAG,
    y una tarea express de DOS repos avanzó a ship al shippear el primero;
    el segundo rebotó con TRANSITION-001/SHIP-001 y costó tres rollbacks).
    Sin ninguna de las dos fuentes, comportamiento de siempre."""
    planned = repos_planned(task_dir)
    for repo in extra_repos:
        if isinstance(repo, str) and repo and repo not in planned:
            planned.append(repo)
    if not planned:
        return []
    verdicts = {
        p.name[len("verdict-"):-len(".json")]
        for p in task_dir.glob("verdict-*.json")
    }
    return [r for r in planned if r not in verdicts]


def non_blocking_without_bead(task_dir: Path) -> list:
    """Veredictos con hallazgos non_blocking sin bead asociado.

    La cadena "los non_blocking se vuelven beads" estaba afirmada en cuatro
    prompts y ejecutada en cero. Caso de campo: una decisión de diferimiento
    vivía solo en tasks/ (gitignoreado), o sea que por la Ley 7 no existía.
    Las entradas valen como string (el reviewer las escribe así) o como
    objeto {text, bead} (scripts/verdict-beads.sh las convierte)."""
    out = []
    for path in sorted(task_dir.glob("verdict-*.json")):
        try:
            items = json.loads(path.read_text(encoding="utf-8")).get("non_blocking") or []
        except (OSError, json.JSONDecodeError, AttributeError):
            continue   # un veredicto ilegible ya lo gatea validate-ship; acá no se duplica
        for item in items:
            if (isinstance(item, str) and item.strip()) or \
                    (isinstance(item, dict) and not item.get("bead")):
                out.append(path.name)
                break
    return out


def blocking_count(task_dir: Path, repo: str):
    """Cuantos bloqueantes dejo el ultimo veredicto del repo, o None si no se sabe."""
    try:
        items = json.loads((task_dir / f"verdict-{repo}.json").read_text(encoding="utf-8")).get("blocking")
    except (OSError, json.JSONDecodeError, AttributeError):
        return None
    return len(items) if isinstance(items, list) else None


def stale_delta_spec(task_dir: Path) -> "str | None":
    """delta-spec.md más nuevo que TODOS los veredictos: nadie revisó ese texto.

    Caso de campo: el delta-spec se enmendó a mitad de corrida porque el review
    cambió la semántica, y nada impedía que /archive fusionara a las specs
    maestras un texto que ningún reviewer vio (dos reviewers tuvieron que
    avisarlo a mano). Se compara por mtime: la señal es imperfecta (un touch o
    un rsync la disparan), pero el falso positivo cuesta un re-veredicto barato
    y el falso negativo costaría spec rot con firma de reviewer.

    Follow-up más sólido: un campo delta_spec_sha256 dentro del veredicto
    (identidad de contenido, inmune a relojes); exige tocar verdict-scaffold.sh
    y el prompt del reviewer, y los veredictos viejos caerían a este mtime
    igual, así que el mtime es el piso que hay que construir de todas formas.

    Fail-open cuando falta una de las dos partes: sin delta no hay nada que
    fusionar; sin veredictos no hay juicio contra el cual comparar."""
    delta = task_dir / "delta-spec.md"
    verdicts = list(task_dir.glob("verdict-*.json"))
    if not delta.exists() or not verdicts:
        return None
    delta_m = delta.stat().st_mtime
    newest = max(v.stat().st_mtime for v in verdicts)
    if delta_m <= newest:
        return None

    def fmt(ts: float) -> str:
        return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    return (f"delta-spec.md se modificó ({fmt(delta_m)}) DESPUÉS del último "
            f"veredicto ({fmt(newest)})")


def repos_not_landed(task_dir: Path) -> list:
    """Repos cuyo ship abrió un PR que todavía NO mergeó.

    Con `flow: prs`, ship.sh termina con la rama publicada y el PR abierto, y
    deja `landed:false` en ship.log: el cambio NO está en la trunk. Avanzar a
    deploy no tiene sentido (no hay nada desplegado que vigilar) y avanzar a
    archive es peor, porque /archive fusiona el delta-spec en la spec maestra:
    la spec pasaría a describir algo que no existe. Es spec rot al revés, y más
    difícil de detectar que el normal, porque la spec parece adelantada en vez
    de vieja.

    Esto estaba escrito en el prompt de /archive. La prosa no frena a nadie, y
    esa es la leccion que este repo ya aprendió en otros seis lugares.

    Compatible hacia atrás: las entradas de `flow: trunk` no traen `landed`, y
    un campo ausente NO cuenta como false (el bug de `//` en jq salió justo de
    confundir esas dos cosas)."""
    log = task_dir / "ship.log"
    if not log.exists():
        return []
    pending = []
    for line in log.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("landed") is False:
            repo = entry.get("repo")
            if repo and repo not in pending:
                pending.append(repo)
        elif entry.get("repo") in pending:
            # Un ship posterior del mismo repo que SI aterrizo lo saca de la
            # lista: el estado vale el ultimo registro, no el primero.
            pending.remove(entry["repo"])
    return sorted(pending)


def lane_transitions(policy: dict, state: dict) -> dict:
    """Transiciones vigentes para el carril de la tarea.

    Un carril sin `allowed_transitions` propio hereda el grafo por defecto
    (standard y full son el pipeline completo; quick y express saltan rfc)."""
    workflow = policy.get("workflow", {})
    lane = state.get("lane", "full")
    lane_cfg = workflow.get("lanes", {}).get(lane, {})
    return lane_cfg.get("allowed_transitions") or workflow.get("allowed_transitions", {})


# Techos que un carril puede prometer sobre el tamaño del diff. La lista es
# CERRADA a propósito: una clave que nadie lee dentro de `limits` sería una
# perilla muerta con cara de garantía (el humano cree que puso un techo y el
# gate no lo mira), que es justo lo que persigue tests/test_dead_knobs.sh.
LANE_LIMIT_FIELDS = ("max_files", "max_lines")


def lane_limits(policy: dict, lane: str) -> list:
    """Los techos del carril como pares clave=valor, o [] si no promete ninguno.

    Un techo ILEGIBLE no devuelve [] (eso lo leería el gate como "este carril
    no tiene techo" y dejaría pasar cualquier diff): muere tipado, porque no
    poder mirar no es lo mismo que mirar y no encontrar nada."""
    lanes = policy.get("workflow", {}).get("lanes", {})
    if not isinstance(lanes, dict) or lane not in lanes:
        known = sorted(lanes) if isinstance(lanes, dict) else []
        fail("POLICY-LANE-001",
             f"carril desconocido: {lane} (permitidos: {known}). "
             "Los carriles se declaran en workflow.lanes de harness-policy.json")
    cfg = lanes.get(lane)
    limits = cfg.get("limits") if isinstance(cfg, dict) else None
    if limits is None:
        return []
    if not isinstance(limits, dict):
        fail("POLICY-SCHEMA-004",
             f"workflow.lanes.{lane}.limits debe ser un objeto, no "
             f"{type(limits).__name__}: un techo ilegible no puede pasar por "
             "'sin techo'")
    unknown = sorted(k for k in limits if k not in LANE_LIMIT_FIELDS)
    if unknown:
        fail("POLICY-SCHEMA-004",
             f"workflow.lanes.{lane}.limits declara claves que ningún gate lee: "
             f"{', '.join(unknown)} (leídas: {', '.join(LANE_LIMIT_FIELDS)}). "
             "Un techo que nadie mide promete lo que no cumple: quitalo o "
             "agregá su lector antes de declararlo")
    pairs = []
    for field in LANE_LIMIT_FIELDS:
        if field not in limits:
            continue
        value = limits[field]
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            fail("POLICY-SCHEMA-004",
                 f"workflow.lanes.{lane}.limits.{field} debe ser un entero "
                 f"positivo, no {value!r}: el gate del carril no puede comparar "
                 "contra eso y tampoco puede fingir que no hay techo")
        pairs.append(f"{field}={value}")
    return pairs


def cmd_lane_limits(args: argparse.Namespace) -> int:
    """Imprime los techos del carril, para que ship.sh no parsee el policy.

    Mismo motivo que evidence-policy: harness-policy.py es LA autoridad sobre
    harness-policy.json. Un `jq` propio en ship.sh es una segunda lectura del
    mismo dato, o sea una oportunidad de divergir en silencio justo en el gate
    que decide si un diff cumple la promesa del carril.

    Contrato para quien lo consume: una línea `clave=valor` por techo en stdout
    y exit 0; stdout VACÍO con exit 0 significa "este carril no promete techo"
    (no aplica el gate); exit 3 significa que no se pudo mirar (carril
    desconocido o policy roto) y eso no se puede leer como verde."""
    policy = load(Path(args.policy), "policy")
    pairs = lane_limits(policy, args.lane)
    if not pairs:
        print(f"ℹ️  el carril {args.lane} no declara limits en el policy: "
              "no hay techo de tamaño que verificar", file=sys.stderr)
        return 0
    for pair in pairs:
        print(pair)
    return 0


def repo_kinds(ws: Path) -> dict:
    """name → kind desde manifest.yaml, parseado a mano (sin dependencia yaml).

    El formato lo emite el propio harness (manifest.yaml.tmpl): items
    '- name:' con su 'kind:' dentro del bloque repos. Se cortan los
    comentarios primero, así los ejemplos comentados del template no
    ensucian, y un key top-level (sin indentación) resetea el item en curso
    para que un 'kind:' huérfano de otra lista no se atribuya al último repo.

    Fail-open: sin manifest, o ilegible, devuelve {} y el chequeo carril/kind
    no aplica (el backstop sigue siendo gate_lane en ship.sh)."""
    try:
        text = (ws / "manifest.yaml").read_text(encoding="utf-8")
    except OSError:
        return {}
    kinds, current = {}, None
    for raw in text.splitlines():
        if raw and not raw[0].isspace() and ":" in raw:
            current = None
        line = raw.split("#", 1)[0].strip()
        if line.startswith("- name:"):
            current = line[len("- name:"):].strip().strip("'\"")
        elif current and line.startswith("kind:"):
            kinds[current] = line[len("kind:"):].strip().strip("'\"")
    return kinds


def vet_repos_for_lane(lane: str, repos: list, ws: Path) -> None:
    """Chequea carril vs repos ANTES de gastar un implementer.

    Vivía adentro de cmd_init, y por eso solo se cobraba al abrir la tarea:
    sumar un repo despues (`repos --add`) se saltaba el freno entero. Es la
    misma verificación en los dos momentos, así que es UNA función: dos copias
    divergen en silencio justo donde el carril promete algo que gate_lane va a
    cobrar al final.

    Los mensajes NO cambian a propósito: hay tests que comparan texto literal,
    y quien los lee en la terminal ya aprendió a reconocerlos."""
    if not repos:
        return
    # quick es de UN repo, y eso se puede comprobar ACÁ: es la única
    # promesa del carril que no necesita ver el diff. quick no genera DAG,
    # así que nada ordena el ship entre repos, y descubrirlo al final
    # costaría el trabajo del implementer más una escalada.
    distinct = list(dict.fromkeys(repos))
    if lane == "quick" and len(distinct) > 1:
        fail("POLICY-LANE-005",
             f"quick es de UN repo; para multi-repo usa express o superior. "
             f"Esta tarea declara {len(distinct)}: {', '.join(distinct)}. "
             "quick no genera DAG, o sea que no hay nada que ordene el ship "
             "entre repos. Remediación: iniciá con --lane express (o "
             "superior), o partí la tarea en una por repo")
    # El aviso temprano que faltaba: gate_lane frena un carril corto que
    # toca infra, pero recién en el precheck, DESPUÉS de que el implementer
    # trabajó. Caso de campo: un carril se clasificó por el tamaño del
    # cambio en vez de por lo que toca, y el error se pagó al final.
    kinds = repo_kinds(ws)
    if not kinds:
        # Degradar sin decir fue el bug (caso de campo): con repo_kinds
        # vacio se salteaban EN SILENCIO el freno de infra Y el aviso de
        # repos desconocidos, y quien probaba leia ese silencio como
        # "chequeo pasado". Fail-open se queda (el backstop es gate_lane
        # en ship.sh); lo que no se queda es el silencio.
        manifest = ws / "manifest.yaml"
        if manifest.exists():
            estado = "presente pero sin repos con kind legibles"
        else:
            estado = f"ausente en {manifest.parent}"
        print(f"⚠️  manifest.yaml {estado}: el chequeo carril/kind NO "
              "corrio (ni el freno de infra ni el aviso de repos "
              "desconocidos); el backstop es gate_lane en ship.sh",
              file=sys.stderr)
    if lane in ("quick", "express"):
        infra = [r for r in repos if kinds.get(r) in ("infra-live", "infra-module")]
        if infra:
            fail("POLICY-LANE-004",
                 f"carril {lane} con repos de infra: {', '.join(infra)} "
                 f"(kind infra-module/infra-live en manifest.yaml). El carril "
                 f"{lane} promete cero infra y gate_lane lo va a bloquear "
                 "DESPUÉS de que el implementer trabaje. Remediación: iniciá "
                 "con --lane standard (o full), o quitá ese repo de la tarea")
    unknown = [r for r in repos if kinds and r not in kinds]
    if unknown:
        print(f"⚠️  repos fuera de manifest.yaml (sin kind conocido): "
              f"{', '.join(unknown)}; el chequeo carril/kind no los cubre",
              file=sys.stderr)


def cmd_init(args: argparse.Namespace) -> int:
    task_dir = Path(args.task_dir).resolve()
    path = state_path(task_dir)
    lock_state(task_dir)
    if path.exists():
        fail("POLICY-STATE-001", f"la tarea ya tiene estado: {path}")
    policy = load(Path(args.policy), "policy")
    if policy.get("schema") != 1:
        fail("POLICY-SCHEMA-003", "policy requiere schema: 1")
    if args.budget_usd is not None and (not math.isfinite(args.budget_usd) or args.budget_usd <= 0):
        fail("POLICY-BUDGET-003", "budget_usd debe ser finito y mayor que cero")
    if args.delivery is not None and args.delivery not in DELIVERY_MODES:
        fail("POLICY-DELIVERY-001",
             f"entrega desconocida: {args.delivery} "
             f"(válidas: {', '.join(DELIVERY_MODES)}). review no publica nada "
             "(commits locales del worktree sí; push, PR y trunk jamás), prs "
             "publica la rama y abre el PR, trunk shippea a la trunk")
    known_lanes = policy.get("workflow", {}).get("lanes", {"full": {}})
    if args.lane not in known_lanes:
        fail("POLICY-LANE-001", f"carril desconocido: {args.lane} (permitidos: {sorted(known_lanes)})")
    repos = [r.strip() for r in (getattr(args, "repos", "") or "").split(",") if r.strip()]
    vet_repos_for_lane(args.lane, repos, task_dir.parent.parent)   # tasks/<id> vive bajo el WS
    state = {
        "schema": 1,
        "task_id": task_dir.name,
        "phase": policy["workflow"]["initial_phase"],
        "lane": args.lane,
        "review_rounds": 0,
        "budget_usd": args.budget_usd,
        "spent_usd": 0.0,
        "history": [],
    }
    if repos:
        state["repos"] = repos
    # El campo solo existe si el comando lo declaró: una tarea SIN delivery es
    # la compatibilidad (ship usa el flow del workspace, como siempre), y
    # escribir un default acá se la comería en silencio.
    if args.delivery is not None:
        state["delivery"] = args.delivery
    atomic(path, state)
    print(f"✅ {task_dir.name}: phase={state['phase']} lane={args.lane}"
          + (f" delivery={args.delivery}" if args.delivery is not None else ""))
    return 0


def cmd_escalate(args: argparse.Namespace) -> int:
    """Sube la tarea de carril y la re-encauza por la deliberación que saltó.

    Escalar es barato a propósito: equivocarse de carril cuesta una re-entrada
    por rfc, jamás un ship sin la deliberación que tocaba."""
    task_dir = Path(args.task_dir).resolve()
    policy = load(Path(args.policy), "policy")
    path = state_path(task_dir)
    lock_state(task_dir)
    state = load(path, "estado")
    order = policy.get("workflow", {}).get("lane_escalation",
                                           ["quick", "express", "standard", "full"])
    current_lane = state.get("lane", "full")
    if args.to not in order or current_lane not in order:
        fail("POLICY-LANE-001", f"carril desconocido: {args.to}")
    if order.index(args.to) <= order.index(current_lane):
        fail("POLICY-LANE-002", f"solo se escala hacia arriba: {current_lane} → {args.to}")
    if state.get("phase") == "blocked":
        fail("POLICY-LANE-003", "tarea bloqueada: resume antes de escalar")
    previous_phase = state.get("phase")
    # La deliberación saltada se recupera volviendo atrás, pero el punto de
    # reentrada tiene que EXISTIR en el grafo del carril destino. Con la terna
    # vieja siempre era rfc (standard y full lo tienen); quick → express manda
    # a una fase que el grafo de express ni siquiera declara, y desde ahí no
    # sale ninguna transición: la tarea quedaba trabada donde no la salvaba ni
    # un escalate más. Cuando el destino no tiene rfc, la deliberación que
    # quick se saltó vive en intake (mini-plan y delta-spec de express).
    graph = lane_transitions(policy, dict(state, lane=args.to))
    reentry = "rfc" if "rfc" in graph else policy.get("workflow", {}).get("initial_phase", "intake")
    destination = reentry if previous_phase in ("implement", "review", "ship") else previous_phase
    state["lane"] = args.to
    state["phase"] = destination
    state.setdefault("history", []).append({
        "from": previous_phase, "to": destination, "actor": args.actor,
        "lane": f"{current_lane}→{args.to}", "reason": args.reason,
    })
    atomic(path, state)
    emit_bus(task_dir, "decision", f"carril {current_lane} → {args.to}: vuelve a {destination}")
    print(f"⤴️  {task_dir.name}: carril {current_lane} → {args.to}, fase {destination}")
    return 0


def cmd_delivery(args: argparse.Namespace) -> int:
    """El "go" del humano, tipado: promueve la entrega declarada de la tarea.

    POR QUÉ EXISTE: la entrega la declara la invocación (/smart abre en review,
    /smart-pr en prs, /smart-main en trunk), así que preguntar en el chat "¿lo
    llevo a main?" al terminar es preguntar algo YA contestado. Lo que sí puede
    cambiar después es la decisión del humano, y esa autorización no puede vivir
    en una frase de chat: se ejecuta acá y queda en history[] con actor, o no
    ocurrió.

    SOLO SUBE. Degradar la entrega no es una decisión simétrica: `prs` y `trunk`
    ya PUBLICARON (rama, PR o commits en la trunk) y bajar el campo no
    despublica nada, solo deja el state.json mintiendo sobre lo que hay afuera.
    Para no publicar, no se publica: se deja la tarea en review y se termina
    ahí, que es un final legítimo y no un error."""
    task_dir = Path(args.task_dir).resolve()
    path = state_path(task_dir)
    if args.to not in DELIVERY_MODES:
        fail("POLICY-DELIVERY-001",
             f"entrega desconocida: {args.to} "
             f"(promovibles: {', '.join(DELIVERY_MODES[1:])}). prs publica la "
             "rama y abre el PR; trunk shippea a la trunk")
    if args.to == "review":
        fail("POLICY-DELIVERY-002",
             "la entrega no se degrada: una tarea ya publicada no se despublica; "
             "para no publicar, no la publiques. review es el peldaño más bajo, "
             "así que nada se 'promueve' hacia él: si querés que esta tarea no "
             "salga, dejala donde está y no corras ship.sh")
    lock_state(task_dir)
    state = load(path, "estado")
    current = delivery_of(state)
    if current is None:
        fail("POLICY-DELIVERY-004",
             f"tasks/{task_dir.name}/state.json no declara entrega: esta tarea "
             "corre con el flow del workspace (compatibilidad), o sea que no hay "
             "peldaño desde el cual promover y declarar uno ahora podría BAJAR lo "
             "que el flow ya prometía. Si querés una entrega tipada, abrí la tarea "
             "con el comando que la declara (/smart, /smart-pr, /smart-main) o con "
             "'harness-policy.py init --delivery'")
    if DELIVERY_MODES.index(args.to) <= DELIVERY_MODES.index(current):
        fail("POLICY-DELIVERY-002",
             f"la entrega no se degrada: una tarea ya publicada no se despublica; "
             f"para no publicar, no la publiques. Esta tarea está en "
             f"{current} y pediste {args.to}"
             + ("" if current != args.to else " (ya está ahí: no hay nada que promover)"))
    state["delivery"] = args.to
    # kind=delivery: NO es un movimiento de fase, y phase_is_declared lo saltea
    # justamente por eso. Lo que registra es QUIÉN autorizó publicar más.
    state.setdefault("history", []).append({
        "kind": "delivery", "delivery": f"{current}→{args.to}",
        "actor": args.actor, "reason": args.reason,
    })
    atomic(path, state)
    emit_bus(task_dir, "decision",
             f"entrega {current} → {args.to} (autoriza {args.actor})"
             + (f": {args.reason}" if args.reason else ""))
    print(f"🚦 {task_dir.name}: entrega {current} → {args.to} "
          f"(autoriza {args.actor})")
    return 0


def cmd_delivery_mode(args: argparse.Namespace) -> int:
    """El modo EFECTIVO de entrega en una línea, para que nadie parsee state.json.

    Mismo motivo que lane-limits: harness-policy.py es LA autoridad sobre el
    estado de la tarea, y un `jq .delivery` en ship.sh sería una segunda lectura
    del mismo dato justo en el gate que decide si algo se publica.

    Contrato para quien lo consume, con los tres estados separados:
      · `review|prs|trunk` + exit 0: la tarea DECLARÓ su entrega y manda ella.
      · `flow` + exit 0: no declara ninguna, y el caller usa el flow del
        workspace (las tareas viejas y /quick no cambian de conducta).
      · exit 3: no pude mirar (state ilegible o entrega fuera del catálogo), y
        eso no se puede leer como `flow`."""
    task_dir = Path(args.task_dir).resolve()
    state = load(state_path(task_dir), "estado")
    print(delivery_of(state) or "flow")
    return 0


def cmd_pause(args: argparse.Namespace) -> int:
    task_dir = Path(args.task_dir).resolve()
    policy = load(Path(args.policy), "policy")
    path = state_path(task_dir)
    lock_state(task_dir)
    state = load(path, "estado")
    allowed = policy.get("workflow", {}).get("allowed_pause_reasons", [])
    if args.reason not in allowed:
        fail("POLICY-PAUSE-001", f"motivo no permitido: {args.reason}")
    if state.get("phase") == "blocked":
        fail("POLICY-PAUSE-002", "la tarea ya está bloqueada")
    previous = state.get("phase")
    state["paused_from"] = previous
    state["phase"] = "blocked"
    state.setdefault("history", []).append({
        "from": previous, "to": "blocked", "actor": args.actor,
        "reason": args.reason, "detail": args.detail,
    })
    atomic(path, state)
    emit_bus(task_dir, "stop", f"{args.reason}: {args.detail}")
    print(f"⏸️  {task_dir.name}: {args.reason}")
    return 0


def cmd_resume(args: argparse.Namespace) -> int:
    task_dir = Path(args.task_dir).resolve()
    path = state_path(task_dir)
    lock_state(task_dir)
    state = load(path, "estado")
    if state.get("phase") != "blocked" or not state.get("paused_from"):
        fail("POLICY-PAUSE-003", "la tarea no tiene una pausa reanudable")
    destination = state.pop("paused_from")
    state["phase"] = destination
    state.setdefault("history", []).append({
        "from": "blocked", "to": destination, "actor": args.actor,
    })
    atomic(path, state)
    emit_bus(task_dir, "phase", f"reanuda en {destination}")
    print(f"▶️  {task_dir.name}: reanuda en {destination}")
    return 0


def cmd_record_cost(args: argparse.Namespace) -> int:
    task_dir = Path(args.task_dir).resolve()
    path = state_path(task_dir)
    lock_state(task_dir)
    state = load(path, "estado")
    if not math.isfinite(args.total_usd) or args.total_usd < 0:
        fail("POLICY-BUDGET-004", "total_usd debe ser finito y no negativo")
    previous = state.get("spent_usd", 0.0)
    if args.total_usd < previous:
        fail("POLICY-BUDGET-001", f"el costo no puede retroceder: {previous} → {args.total_usd}")
    state["spent_usd"] = args.total_usd
    atomic(path, state)
    budget = state.get("budget_usd")
    if budget is not None and args.total_usd > budget:
        fail("POLICY-BUDGET-002", f"costo ${args.total_usd:.4f} excede presupuesto ${budget:.4f}")
    print(f"✅ costo registrado: ${args.total_usd:.4f}" + (f" / ${budget:.4f}" if budget is not None else ""))
    return 0


def load_dag_nodes(dag_path: Path) -> "tuple[dict, dict]":
    """Valida el DAG completo (DAG-001..007) y devuelve (deps, repo) por id.

    Es LA validación de cmd_validate_dag, extraída para que dag-order use
    exactamente las mismas reglas: dos validadores del mismo artefacto es una
    oportunidad de divergir."""
    dag = load(dag_path, "DAG")
    if dag.get("schema") != 1 or not isinstance(dag.get("tasks"), list) or not dag["tasks"]:
        fail("POLICY-DAG-001", "dag.json requiere schema:1 y tasks[] no vacío")
    nodes: dict[str, list[str]] = {}
    repos: dict[str, str] = {}
    for item in dag["tasks"]:
        if not isinstance(item, dict):
            fail("POLICY-DAG-002", "cada tarea del DAG debe ser un objeto")
        task_id, repo, deps = item.get("id"), item.get("repo"), item.get("depends_on", [])
        if not isinstance(task_id, str) or not task_id or task_id in nodes:
            fail("POLICY-DAG-003", f"id vacío o duplicado: {task_id!r}")
        if not isinstance(repo, str) or not repo or "/" in repo or ".." in repo:
            fail("POLICY-DAG-004", f"repo inválido para {task_id}: {repo!r}")
        if not isinstance(deps, list) or any(not isinstance(dep, str) for dep in deps):
            fail("POLICY-DAG-005", f"depends_on inválido para {task_id}")
        nodes[task_id] = deps
        repos[task_id] = repo
    for task_id, deps in nodes.items():
        missing = [dep for dep in deps if dep not in nodes]
        if missing:
            fail("POLICY-DAG-006", f"{task_id} depende de IDs inexistentes: {missing}")
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(node: str) -> None:
        if node in visiting:
            fail("POLICY-DAG-007", f"ciclo detectado en {node}")
        if node in visited:
            return
        visiting.add(node)
        for dependency in nodes[node]:
            visit(dependency)
        visiting.remove(node)
        visited.add(node)

    for node in nodes:
        visit(node)

    # ── DOS TAREAS DEL MISMO REPO NO PUEDEN IR EN PARALELO ───────────────
    # La doctrina decía "aristas solo por conflicto REAL de archivos, jamás por
    # repo, porque cada tarea tiene su worktree". Esa premisa es FALSA:
    # worktree-task.sh crea el árbol en worktrees/<task-id>/<repo>, o sea UNO
    # por (tarea, repo), y todas las tareas del DAG de esa tarea lo comparten,
    # junto con la rama task/<id> y el index de git.
    #
    # Caso de campo: dos tareas del mismo repo lanzadas en paralelo, el `git
    # add` amplio de una se llevó 6 archivos de la otra a su commit. No se
    # perdió trabajo de milagro (mismo trailer Task:), pero la atribución quedó
    # mezclada y el index quedó a merced de una carrera.
    #
    # El arreglo va acá y no en el prompt porque el orquestador ya lo estaba
    # haciendo a mano: una regla que depende de que alguien se acuerde ya falló.
    # Basta con que exista un CAMINO de dependencia entre las dos (cualquier
    # orden sirve, y una cadena T1 → T2 → T3 vale): el DAG serializado hace que
    # `dag-order` y `bd ready` no las ofrezcan a la vez.
    def reaches(src: str, dst: str) -> bool:
        seen: set[str] = set()
        stack = [src]
        while stack:
            cur = stack.pop()
            if cur == dst:
                return True
            if cur in seen:
                continue
            seen.add(cur)
            stack.extend(nodes.get(cur, []))
        return False

    by_repo: dict[str, list[str]] = {}
    for task_id, repo in repos.items():
        by_repo.setdefault(repo, []).append(task_id)
    for repo, ids in by_repo.items():
        if len(ids) < 2:
            continue
        ordered = sorted(ids)
        for i, left in enumerate(ordered):
            for right in ordered[i + 1:]:
                if reaches(left, right) or reaches(right, left):
                    continue
                fail("POLICY-DAG-010",
                     f"{left} y {right} comparten el repo '{repo}' y el DAG no las "
                     f"ordena: en paralelo comparten worktrees/<task>/{repo}, la rama "
                     "y el index de git, así que se pisan los commits (caso de campo: "
                     "un `git add` amplio se llevó 6 archivos de la tarea vecina). "
                     f"↳ remediación: agregá una arista de orden en depends_on "
                     f"(cualquiera de los dos órdenes sirve: {left} → {right} o al "
                     "revés), o dales repos distintos")
    return nodes, repos


def cmd_validate_dag(args: argparse.Namespace) -> int:
    nodes, _ = load_dag_nodes(Path(args.dag))
    print(f"✅ DAG válido: {len(nodes)} tareas, sin ciclos")
    return 0


def cmd_dag_order(args: argparse.Namespace) -> int:
    """El orden de shipping del DAG, EJECUTABLE: un repo por línea.

    El dag: de answers dice literal "ship.sh no lo impone" y nadie lo
    ejecutaba; el caso de campo fue una cadena publish/bump/deploy corrida a
    mano donde un eslabón quedó a medias. ship-wave.sh consume esta salida.

    Dedupe por ÚLTIMA aparición del repo: ship.sh shippea el worktree ENTERO
    una vez; posicionar el repo en su primera tarea aterrizaría las tareas
    posteriores antes que sus dependencias."""
    task_dir = Path(args.task_dir).resolve()
    dag_path = task_dir / "dag.json"
    if not dag_path.exists():
        fail("POLICY-DAG-008",
             f"no existe tasks/{task_dir.name}/dag.json: sin plan no hay ola. "
             "Los carriles quick y express no generan DAG: shippea con ship.sh "
             "directo")
    nodes, repos = load_dag_nodes(dag_path)
    order: list = []
    visited: set = set()

    def visit(node: str) -> None:
        if node in visited:
            return
        visited.add(node)
        for dependency in nodes[node]:
            visit(dependency)
        order.append(node)

    for node in nodes:
        visit(node)
    # dedupe por última aparición del repo
    repo_seq = [repos[t] for t in order]
    final = []
    for index, repo in enumerate(repo_seq):
        if repo not in repo_seq[index + 1:]:
            final.append(repo)
    # fail-closed: si una tarea de R depende de una de S y S quedó DESPUÉS de
    # R en el orden final, el DAG exige intercalar ships del mismo repo, y la
    # ola hace UN ship por repo.
    position = {repo: index for index, repo in enumerate(final)}
    for task_id, deps in nodes.items():
        for dependency in deps:
            r_task, r_dep = repos[task_id], repos[dependency]
            if r_task != r_dep and position[r_dep] > position[r_task]:
                fail("POLICY-DAG-009",
                     f"el DAG exige intercalar ships del mismo repo "
                     f"({r_task} ↔ {r_dep}): ship-wave hace UN ship por repo. "
                     "Shippeá a mano por tarea, en el orden del DAG")
    for repo in final:
        print(repo)
    return 0


def cmd_transition(args: argparse.Namespace) -> int:
    task_dir = Path(args.task_dir).resolve()
    policy = load(Path(args.policy), "policy")
    path = state_path(task_dir)
    lock_state(task_dir)
    state = load(path, "estado")
    current = state.get("phase")
    allowed = lane_transitions(policy, state).get(current, [])
    # ── review → review con --repo: la FASE es global, el REVIEW es por repo ──
    # /review manda solicitar la transición antes de CADA entrada a review
    # nombrando el repo, porque el presupuesto de rondas se cuenta POR REPO.
    # Pero la fase es una sola: en cuanto el primer repo entraba a review, el
    # segundo chocaba con POLICY-TRANSITION-001 y su entrada NUNCA se
    # registraba. Caso de campo: una tarea de cinco repos terminó con rondas
    # contadas para dos; los otros tres pasaron por reviewer y QA sin que el
    # presupuesto los gobernara, que es exactamente lo que el --repo existe
    # para evitar. Choca además con el pipeline por repo (T1 en review
    # mientras T4 se implementa) que los propios prompts endosan.
    #
    # No afloja nada: el techo lo sigue cobrando POLICY-LIMIT-001 sobre
    # review_rounds_by_repo[repo] más abajo, que es el contador que importa.
    # Sin --repo la auto-transición sigue prohibida: sería una ronda anónima
    # que ningún presupuesto puede cobrar.
    if args.phase == current == "review" and args.repo:
        allowed = list(allowed) + ["review"]
    if args.phase not in allowed:
        lane = state.get("lane", "full")
        extra = ""
        if args.phase == current == "review":
            extra = (". Si es la entrada a review de OTRO repo de la tarea, "
                     "pasá --repo <repo>: la fase es global pero las rondas se "
                     "cuentan por repo")
        fail("POLICY-TRANSITION-001",
             f"transición no permitida ({lane}): {current} → {args.phase}{extra}")
    if args.phase == "ship":
        unreviewed = repos_missing_verdict(task_dir, state.get("repos") or ())
        if unreviewed:
            fail("POLICY-SHIP-004",
                 f"el plan de la tarea (dag.json o state.repos) incluye repos "
                 f"que todavía NO tienen veredicto: "
                 f"{', '.join(unreviewed)}. El plan dijo que son parte de esta "
                 "tarea y nadie los revisó: avanzar ahora los deja sin camino "
                 "(desde ship solo se va a deploy). Corré /review de cada uno "
                 "(produce verdict-<repo>.json), shippealo con scripts/ship.sh "
                 "y recién entonces pedí review → ship. Si el plan cambió y un "
                 "repo ya no participa, regenerá tasks/<id>/dag.json y "
                 "re-corré validate-dag")
        pending = repos_pending_ship(task_dir)
        if pending:
            fail("POLICY-SHIP-004",
                 f"faltan repos por shippear: {', '.join(pending)}. ship.sh se corre "
                 "una vez por repo y exige phase=review: si avanzas ahora, esos repos "
                 "quedan sin camino (desde ship solo se va a deploy). Shippea cada uno "
                 "con scripts/ship.sh y recién entonces pide review → ship")
    # ── LAS RONDAS SE CUENTAN POR REPO ────────────────────────────────
    # El presupuesto existe para cortar un loop implementer↔reviewer que no
    # converge. Contarlo por TAREA hacía que una tarea de tres repos, donde
    # cada repo necesita UN fix normal, agotara el presupuesto y escalara a
    # humano sin que nada estuviera mal: el loop de un repo no dice nada sobre
    # la convergencia de otro.
    #
    # `review_rounds` se mantiene como el MÁXIMO entre repos: es lo que
    # validate-ship compara y lo que los reportes ya leen, así que las tareas y
    # los estados viejos siguen funcionando igual.
    if args.phase in ("deploy", "archive"):
        not_landed = repos_not_landed(task_dir)
        if not_landed:
            fail("POLICY-SHIP-005",
                 f"estos repos abrieron PR pero NO mergearon: {', '.join(not_landed)}. "
                 f"Con flow: prs el cambio no está en la trunk hasta el merge, así que "
                 f"no hay deploy que vigilar y archivar fusionaría el delta-spec de algo "
                 f"que todavía no existe. Esperá el merge y re-corré deploy-watch, que "
                 f"resuelve el commit real")
    if args.phase == "archive":
        # Solo archive: el daño es la FUSIÓN a las specs maestras. Un delta
        # enmendado no invalida un deploy ya aterrizado, y bloquear deploy
        # crearía paradas falsas durante operación.
        stale = stale_delta_spec(task_dir)
        if stale:
            fail("POLICY-ARCHIVE-001",
                 f"{stale}: ningún reviewer vio ese texto y /archive lo "
                 "fusionaría a las specs maestras. Re-corré /review del repo "
                 "afectado (scripts/verdict-scaffold.sh --rebase conserva el "
                 "juicio que el delta no tocó) para re-emitir el veredicto "
                 "sobre el delta vigente")
        unbeaded = non_blocking_without_bead(task_dir)
        if unbeaded:
            if shutil.which("bd"):
                fail("POLICY-ARCHIVE-002",
                     "hallazgos non_blocking sin bead en "
                     f"{', '.join(unbeaded)}: tasks/ es gitignoreado y al "
                     "archivar dejan de existir (Ley 7). Corré "
                     "scripts/verdict-beads.sh <task-id> <repo> por cada repo "
                     "listado y reintentá la transición")
            else:
                print("⚠️  hay non_blocking sin bead y bd NO está en PATH: no "
                      "se exige lo que la máquina no puede dar; esos hallazgos "
                      "quedarán solo en el veredicto (gitignoreado)")
    rounds_by_repo = state.get("review_rounds_by_repo")
    if not isinstance(rounds_by_repo, dict):
        rounds_by_repo = {}
    rounds = state.get("review_rounds", 0)

    def budget_warning(round_now: int, maximum: int, label: str) -> None:
        """La última ronda del presupuesto se AVISA, no solo se cobra.

        Caso de campo: ~20 rondas de review en una corrida y nadie miraba el
        costo acumulado; el techo de rondas se sorteaba con rollback (que es
        honesto) pero el goteo seguía. El aviso sale por stdout Y por el bus
        (kind decision: es gobierno de presupuesto, no una verificación
        faltante), para que el panel lo muestre."""
        if round_now != maximum:
            return
        spent = state.get("spent_usd")
        budget = state.get("budget_usd")
        cost = ""
        if isinstance(spent, (int, float)) and spent > 0:
            cost = f" (gastado ${spent:.2f}"
            if isinstance(budget, (int, float)):
                cost += f" de ${budget:.2f}"
            cost += ")"
        warning = (f"última ronda del presupuesto de review{label} "
                   f"({round_now}/{maximum}): considerá un pase profundo "
                   f"en vez de goteo{cost}")
        print(f"⚠️  {warning}")
        emit_bus(task_dir, "decision", warning)

    if args.phase == "review":
        maximum = policy.get("limits", {}).get("max_review_rounds", 3)
        if args.repo:
            rounds_by_repo[args.repo] = rounds_by_repo.get(args.repo, 0) + 1
            this_repo = rounds_by_repo[args.repo]
            # ── EL TECHO MIRA CONVERGENCIA, NO SOLO EL CONTEO ─────────────
            # CASO DE CAMPO: una tarea bajó 4 → 2 → 1 → 0 bloqueantes y el
            # techo de 3 rondas la paró con el trabajo terminado; hubo que
            # despertar a un humano de madrugada para desbloquear algo que
            # estaba convergiendo a la vista de cualquiera.
            #
            # POR QUÉ: rondas de más NO siempre son "no converge". También
            # son un reviewer que hace bien su trabajo y encuentra menos
            # cada vez. Cortar por conteo puro confunde las dos cosas y
            # cobra la escalada más cara justo en el caso bueno.
            #
            # La señal es el conteo de `blocking` del ÚLTIMO veredicto del
            # repo, acumulado ronda a ronda en review_blocking_by_repo. Si
            # baja estrictamente, la ronda extra pasa con aviso; si no baja,
            # el corte es el de siempre. El techo DURO 2*maximum existe
            # porque bajar de a uno desde cincuenta también "converge" y
            # nadie va a pagar cincuenta rondas para comprobarlo.
            #
            # Sin veredictos legibles no hay serie: `seen` queda vacío,
            # `converging` es falso y el corte es IDÉNTICO al de antes.
            blocking_by_repo = state.get("review_blocking_by_repo")
            if not isinstance(blocking_by_repo, dict):
                blocking_by_repo = {}
            seen = blocking_by_repo.get(args.repo)
            seen = [n for n in seen if isinstance(n, int)] if isinstance(seen, list) else []
            previous = blocking_count(task_dir, args.repo)
            if previous is not None:
                seen.append(previous)
            blocking_by_repo[args.repo] = seen
            state["review_blocking_by_repo"] = blocking_by_repo
            converging = len(seen) >= 2 and seen[-1] < seen[-2]
            hard = 2 * maximum
            if this_repo > maximum:
                if this_repo > hard:
                    fail("POLICY-LIMIT-001",
                         f"review round {this_repo} del repo {args.repo} excede el "
                         f"techo duro {hard} (2× el máximo {maximum}). Aunque los "
                         "bloqueantes vengan bajando, esta cantidad de rondas ya no "
                         "es convergencia sino goteo: escala a humano con el "
                         "historial de veredictos (los otros repos de la tarea no "
                         "se ven afectados)")
                if not converging:
                    traza = (f"{seen[-2]} → {seen[-1]}" if len(seen) >= 2
                             else "sin serie legible de bloqueantes en los veredictos")
                    fail("POLICY-LIMIT-001",
                         f"review round {this_repo} del repo {args.repo} excede el "
                         f"máximo {maximum} y NO bajó bloqueantes ({traza}). Ese repo "
                         "no converge: escala a humano con el historial de veredictos "
                         "(los otros repos de la tarea no se ven afectados)")
                # Sobrevivir a los dos fail() de arriba ES la decisión: la
                # ronda extra se CONCEDE, y se cuenta como tal en el bus.
                aviso = (f"ronda extra {this_repo}/{maximum} de {args.repo} "
                         f"permitida por convergencia: los bloqueantes bajan "
                         f"({' → '.join(str(n) for n in seen)}), techo duro {hard}")
                print(f"⚠️  {aviso}")
                emit_bus(task_dir, "decision", aviso)
            budget_warning(this_repo, maximum, f" de {args.repo}")
            rounds = max([rounds] + list(rounds_by_repo.values()))
        else:
            rounds += 1
            if rounds > maximum:
                fail("POLICY-LIMIT-001",
                     f"review round {rounds} excede el máximo {maximum}. Si es una "
                     "tarea multi-repo, pasá --repo <repo> para que el presupuesto "
                     "se cuente por repo y no castigue a los que sí convergieron")
            budget_warning(rounds, maximum, "")
    history = state.setdefault("history", [])
    entry = {"from": current, "to": args.phase, "actor": args.actor}
    if args.repo:
        entry["repo"] = args.repo
    history.append(entry)
    state["phase"] = args.phase
    state["review_rounds"] = rounds
    if rounds_by_repo:
        state["review_rounds_by_repo"] = rounds_by_repo
    atomic(path, state)
    detail = f" (repo {args.repo}: ronda {rounds_by_repo.get(args.repo)})" if args.repo and args.phase == "review" else ""
    # la ronda viaja al bus: el panel antes no tenía forma de contar rondas
    emit_bus(task_dir, "phase", f"{current} → {args.phase}"
             + (f" ({args.repo}{': ronda ' + str(rounds_by_repo.get(args.repo)) if args.phase == 'review' else ''})"
                if args.repo else ""))
    print(f"✅ {task_dir.name}: {current} → {args.phase}{detail}")
    return 0


def cmd_rollback(args: argparse.Namespace) -> int:
    """Deshace un avance de fase equivocado, hacia atrás y dejando registro.

    POR QUÉ EXISTE: `allowed_transitions` solo apunta hacia adelante, así que
    una fase avanzada por error no tenía retorno (el único camino atrás vive
    en `escalate`, y exige subir de carril: en lane=full es inalcanzable). El
    resultado era editar state.json a mano, que AGENTS.md prohíbe, y encima
    quedaba indistinguible de una edición no declarada.

    NO toca review_rounds a propósito. `transition ... review` incrementa el
    contador porque una ronda de review de verdad empieza; un rollback deshace
    un movimiento que nunca ocurrió, y cobrarle una ronda castigaría al que
    corrige el error con un POLICY-LIMIT-001 ajeno."""
    task_dir = Path(args.task_dir).resolve()
    policy = load(Path(args.policy), "policy")
    path = state_path(task_dir)
    lock_state(task_dir)
    state = load(path, "estado")
    current = state.get("phase")
    destination = args.phase
    if current == "blocked":
        fail("POLICY-ROLLBACK-001", "tarea bloqueada: usa resume, no rollback")
    order = phase_order(policy)
    if current not in order:
        fail("POLICY-ROLLBACK-002", f"fase actual fuera del orden canónico: {current}")
    if destination not in order:
        fail("POLICY-ROLLBACK-002", f"destino desconocido: {destination} (orden: {', '.join(order)})")
    if order.index(destination) >= order.index(current):
        fail("POLICY-ROLLBACK-003",
             f"rollback solo va hacia atrás: {current} → {destination}. "
             "Para avanzar usa transition, que sí verifica los gates del grafo")
    if not args.reason.strip():
        fail("POLICY-ROLLBACK-004", "un rollback sin motivo es una edición a mano con otro nombre")
    state.setdefault("history", []).append({
        "kind": "rollback", "from": current, "to": destination,
        "actor": args.actor, "reason": args.reason,
    })
    state["phase"] = destination
    atomic(path, state)
    emit_bus(task_dir, "decision", f"rollback {current} → {destination}: {args.reason}")
    print(f"↩️  {task_dir.name}: rollback {current} → {destination} ({args.reason})")
    print(f"   review_rounds sin cambios ({state.get('review_rounds', 0)}): "
          "el rollback deshace, no cobra una ronda")
    return 0


def cmd_repos(args: argparse.Namespace) -> int:
    """Suma repos a una tarea YA iniciada, registrando quién y por qué.

    POR QUÉ EXISTE: `init` era el único comando que aceptaba `--repos` y se
    niega a re-correrse (POLICY-STATE-001), así que ampliar el alcance de una
    tarea en curso no tenía ninguna vía registrada.

    CASO DE CAMPO: el enrichment descubrió CON EVIDENCIA que el bug vivía
    también en otros dos repos. worktree-task.sh los aceptó sin chistar, pero
    `state.repos` se quedó con tres de cinco, y en los carriles sin dag.json
    `repos_missing_verdict` lee justamente `state.repos`: el repo nuevo
    desaparecía del conteo y la fase avanzaba a ship SIN su veredicto. Editar
    state.json a mano está prohibido (AGENTS.md), así que la única salida
    honesta era esta: un comando que valide igual que init y deje historia.

    El mismo `vet_repos_for_lane` que cobra init cobra acá, sobre la lista
    COMBINADA: un repo de infra agregado después no puede colarse por la
    puerta de atrás en un carril que prometió cero infra."""
    task_dir = Path(args.task_dir).resolve()
    path = state_path(task_dir)
    lock_state(task_dir)
    state = load(path, "estado")
    if not args.reason.strip():
        fail("POLICY-REPOS-001",
             "ampliar el alcance sin motivo es una edición a mano con otro "
             "nombre: pasá --reason con la evidencia que descubrió el repo")
    phase = state.get("phase")
    if phase in ("ship", "deploy", "archive"):
        fail("POLICY-REPOS-002",
             f"la tarea ya está en fase {phase}: un repo agregado acá nace sin "
             "review posible (desde ship no se vuelve a review por el grafo). "
             "Remediación: rollback a review con motivo y recién entonces "
             "sumá el repo, o abrí una tarea nueva para ese repo")
    current = state.get("repos")
    current = [r for r in current if isinstance(r, str) and r] if isinstance(current, list) else []
    added = [r.strip() for r in args.add.split(",") if r.strip()]
    added = [r for r in dict.fromkeys(added) if r not in current]
    if not added:
        print(f"ℹ️  {task_dir.name}: sin cambios, esos repos ya estaban "
              f"declarados ({', '.join(current) or 'ninguno'})")
        return 0
    combined = current + added
    lane = state.get("lane", "full")
    vet_repos_for_lane(lane, combined, task_dir.parent.parent)
    state["repos"] = combined
    state.setdefault("history", []).append({
        "kind": "repos", "added": added,
        "actor": args.actor, "reason": args.reason,
    })
    atomic(path, state)
    emit_bus(task_dir, "decision",
             f"alcance ampliado: +{', '.join(added)} ({args.reason})")
    print(f"✅ {task_dir.name}: repos {', '.join(combined)} (+{', '.join(added)})")
    print("   esos repos ahora exigen veredicto antes de review → ship "
          "(POLICY-SHIP-004)")
    return 0


def verdict_reuse_cfg(policy: dict) -> dict:
    cfg = dict(DEFAULT_VERDICT_REUSE)
    declared = policy.get("ship", {}).get("verdict_reuse")
    if isinstance(declared, dict):
        cfg.update({k: v for k, v in declared.items() if k in cfg})
    return cfg


def parse_iso(value) -> "dt.datetime | None":
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def check_verdict_commit(verdict: dict, policy: dict, args: argparse.Namespace) -> str:
    """El veredicto vale para este HEAD, y devuelve el commit que se revisó.

    POR QUÉ NO ALCANZA CON `verdict.commit == HEAD`: con varias personas
    pusheando al mismo trunk, el rebase de ship.sh reescribe los SHA sin tocar
    el contenido del cambio.  Exigir igualdad de SHA tiraba review y QA (juicio
    de LLM, decenas de minutos) por un movimiento que el reviewer nunca miró.

    Lo que se acepta en su lugar es una identidad de CONTENIDO
    (`scripts/change-id.sh`, patch-id --verbatim: sensible al whitespace a
    propósito), y solo dentro de una ventana, porque un juicio también caduca
    en el tiempo aunque el texto sea idéntico: con el trunk 200 commits
    adelante, el mismo diff puede significar otra cosa.

    Lo que este permiso NO cubre: que el árbol integrado funcione.  Eso lo
    prueba la evidencia FRESCA que exige evidence.py --require-fresh-kind, y
    ship.sh la produce re-corriendo la suite sobre el HEAD que aterriza."""
    reviewed = verdict.get("commit")
    if not isinstance(reviewed, str) or not reviewed:
        fail("POLICY-SHIP-002", "el veredicto no declara commit")
    if reviewed == args.commit:
        return reviewed
    cfg = verdict_reuse_cfg(policy)
    if not cfg.get("enabled", True):
        fail("POLICY-SHIP-002",
             f"el veredicto es del commit {reviewed[:12]} y se pushea {args.commit[:12]}; "
             "la reutilización de veredicto está deshabilitada en harness-policy.json")
    reviewed_pid = verdict.get("patch_id")
    if not isinstance(reviewed_pid, str) or not reviewed_pid:
        fail("POLICY-SHIP-002",
             f"el veredicto es del commit {reviewed[:12]} y se pushea {args.commit[:12]}, "
             "y no declara patch_id: no hay forma de saber si es el MISMO cambio. "
             "Re-corre scripts/verdict-scaffold.sh --rebase y el review incremental")
    if not args.patch_id:
        fail("POLICY-SHIP-002",
             "falta --patch-id: sin la identidad del cambio actual no puedo comparar "
             "contra el patch_id del veredicto")
    if reviewed_pid != args.patch_id:
        fail("POLICY-SHIP-002",
             f"el cambio NO es el que se revisó (patch_id {reviewed_pid[:12]} → "
             f"{args.patch_id[:12]}). O el implementer commiteó algo nuevo, o el rebase "
             "tocó las líneas de contexto del diff. Las dos cosas piden re-review: "
             "scripts/verdict-scaffold.sh --rebase y /review")
    max_age = cfg.get("max_age_hours")
    reviewed_at = parse_iso(verdict.get("reviewed_at"))
    if isinstance(max_age, (int, float)) and max_age > 0:
        if reviewed_at is None:
            fail("POLICY-SHIP-002",
                 "el veredicto no declara reviewed_at: no puedo comprobar su vigencia. "
                 "Re-corre el scaffold, que ahora lo sella")
        age_h = (dt.datetime.now(dt.timezone.utc) - reviewed_at).total_seconds() / 3600.0
        if age_h > max_age:
            fail("POLICY-SHIP-002",
                 f"el veredicto tiene {age_h:.1f}h y el máximo para reusarlo tras un "
                 f"rebase es {max_age}h. El texto del cambio es el mismo, pero el trunk "
                 "de abajo ya no: re-revisa")
    max_base = cfg.get("max_base_commits")
    if isinstance(max_base, int) and max_base > 0 and args.base_moved is not None:
        if args.base_moved > max_base:
            fail("POLICY-SHIP-002",
                 f"la base avanzó {args.base_moved} commits desde el review y el máximo "
                 f"para reusar el veredicto es {max_base}: re-revisa")
    print(f"↻ veredicto reusado: mismo cambio (patch_id {args.patch_id[:12]}) sobre "
          f"otra base ({reviewed[:12]} → {args.commit[:12]})"
          + (f", base +{args.base_moved} commits" if args.base_moved is not None else ""))
    return reviewed


def cmd_evidence_policy(args: argparse.Namespace) -> int:
    """Imprime lo que harness-policy.json exige como evidencia.

    Existe porque `ship.required_evidence_kinds` y `ship.require_fresh_evidence`
    se declaraban en el policy y NO los leía nadie: ship.sh cableaba
    `--require-kind test`. Editarlos no cambiaba nada, en silencio, que es
    exactamente la clase de perilla muerta que este repo ya persiguió con
    `flow`. Ahora ship.sh construye sus flags desde acá."""
    policy = load(Path(args.policy), "policy")
    ship = policy.get("ship", {})
    kinds = ship.get("required_evidence_kinds")
    if not isinstance(kinds, list) or not all(isinstance(k, str) for k in kinds):
        kinds = ["test"]
    if args.field == "required_evidence_kinds":
        for kind in kinds:
            print(kind)
    elif args.field == "require_fresh_evidence":
        print("true" if ship.get("require_fresh_evidence", True) else "false")
    return 0


def cmd_validate_ship(args: argparse.Namespace) -> int:
    task_dir = Path(args.task_dir).resolve()
    policy = load(Path(args.policy), "policy")
    state = load(state_path(task_dir), "estado")
    if state.get("schema") != 1 or state.get("task_id") != task_dir.name:
        fail("POLICY-STATE-002", "state.json no corresponde a la tarea")
    if state.get("phase") != "review":
        fail("POLICY-SHIP-001", f"ship requiere phase=review; actual={state.get('phase')}")
    if not phase_is_declared(state, policy):
        history = state.get("history") or []
        last = history[-1].get("to") if history and isinstance(history[-1], dict) else "(sin history)"
        fail("POLICY-STATE-003",
             f"phase={state.get('phase')} no corresponde al último movimiento registrado "
             f"({last}): state.json se editó a mano. Reconstruye el movimiento con "
             "'harness-policy.py rollback|transition', que deja registro en history[]")
    # La entrega se comprueba ANTES que el veredicto: con delivery=review no hay
    # publicación que validar, y leer el verdict para negarse igual solo cambia
    # el motivo del rojo por uno que no es el verdadero.
    delivery = delivery_of(state)
    if delivery == "review":
        fail("POLICY-DELIVERY-003",
             f"esta tarea declaró entrega review: no se publica nada (los commits "
             f"locales del worktree sí; push, PR y trunk jamás), así que no hay "
             f"ship que validar. La autorización para publicar es una transición "
             f"auditable, no una frase en el chat: "
             f"'scripts/harness-policy.py delivery tasks/{task_dir.name} "
             f"--to prs|trunk --actor <quien-autoriza>' y volvé a correr ship.sh. "
             f"Si nadie la promueve, la tarea termina en review y ese es el "
             f"resultado correcto")
    maximum = policy.get("limits", {}).get("max_review_rounds", 3)
    if not isinstance(state.get("review_rounds"), int) or state["review_rounds"] > maximum:
        fail("POLICY-LIMIT-001", "review_rounds inválido o excedido")
    verdict = load(Path(args.verdict), "veredicto")
    if verdict.get("schema") != 1:
        fail("POLICY-SHIP-002", "veredicto sin schema v1")
    reviewed_commit = check_verdict_commit(verdict, policy, args)
    # Mismo código (la regla es una), pero el mensaje nombra al campo que
    # falló: "review y QA deben estar en pass" no distingue un review con
    # blocking de un qa que nunca corrió, y son remediaciones opuestas.
    if verdict.get("verdict") != "pass" or verdict.get("qa") != "pass":
        culprits = ", ".join(
            f"{k}={verdict.get(k)!r}"
            for k in ("verdict", "qa")
            if verdict.get(k) != "pass"
        )
        fail("POLICY-SHIP-003", f"review y QA deben estar en pass ({culprits})")
    reviewer = verdict.get("reviewer")
    implementers = verdict.get("implementation_agents")
    if policy.get("ship", {}).get("require_independent_review", True):
        if not isinstance(reviewer, str) or not reviewer:
            fail("POLICY-ROLE-001", "falta reviewer")
        if not isinstance(implementers, list) or not implementers:
            fail("POLICY-ROLE-002", "falta implementation_agents[]")
        if reviewer in implementers:
            fail("POLICY-ROLE-003", "el reviewer también figura como implementador")
    # El commit revisado se imprime en una línea parseable para que ship.sh se
    # lo pase a evidence.py --reviewed-commit sin volver a derivarlo por su
    # cuenta: dos derivaciones del mismo hecho es una oportunidad de divergir.
    print(f"REVIEWED_COMMIT={reviewed_commit}")
    print(f"✅ política de ship válida para {task_dir.name}@{args.commit[:12]}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="harness policy engine v1")
    root.add_argument("--policy", default="harness-policy.json")
    sub = root.add_subparsers(dest="action", required=True)
    init = sub.add_parser("init")
    init.add_argument("task_dir")
    init.add_argument("--budget-usd", type=float)
    init.add_argument("--lane", default="full")
    init.add_argument("--repos", default="",
                      help="repos de la tarea separados por coma; habilita el "
                           "chequeo carril vs kind (manifest.yaml) y queda en "
                           "state.repos")
    # Sin choices= a propósito: argparse mataría con exit 2 y un mensaje suyo,
    # y el contrato de este CLI es un código tipado con la remediación adentro.
    init.add_argument("--delivery", default=None,
                      help="qué se publica al terminar: review (nada), prs "
                           "(rama + PR) o trunk (ship a la trunk). Ausente = la "
                           "tarea usa el flow del workspace, como siempre")
    init.set_defaults(func=cmd_init)
    escalate = sub.add_parser("escalate")
    escalate.add_argument("task_dir")
    escalate.add_argument("--to", required=True)
    escalate.add_argument("--actor", required=True)
    escalate.add_argument("--reason", default="")
    escalate.set_defaults(func=cmd_escalate)
    transition = sub.add_parser("transition")
    transition.add_argument("task_dir")
    transition.add_argument("phase")
    transition.add_argument("--actor", required=True)
    transition.add_argument("--repo", default="",
                            help="repo cuya ronda de review se cuenta; sin él el "
                                 "presupuesto se cuenta por tarea (compat)")
    transition.set_defaults(func=cmd_transition)
    rollback = sub.add_parser("rollback")
    rollback.add_argument("task_dir")
    rollback.add_argument("phase")
    rollback.add_argument("--actor", required=True)
    rollback.add_argument("--reason", required=True)
    rollback.set_defaults(func=cmd_rollback)
    repos_cmd = sub.add_parser("repos",
                               help="suma repos a una tarea ya iniciada: init "
                                    "no se re-corre y editar state.json a mano "
                                    "está prohibido")
    repos_cmd.add_argument("task_dir")
    repos_cmd.add_argument("--add", required=True,
                           help="repos a sumar, separados por coma")
    repos_cmd.add_argument("--actor", required=True)
    repos_cmd.add_argument("--reason", required=True,
                           help="la evidencia que descubrió el repo")
    repos_cmd.set_defaults(func=cmd_repos)
    deliv = sub.add_parser("delivery",
                           help="promueve la entrega declarada de la tarea "
                                "(review → prs → trunk): el 'go' auditable")
    deliv.add_argument("task_dir")
    deliv.add_argument("--to", required=True)
    deliv.add_argument("--actor", required=True)
    deliv.add_argument("--reason", default="")
    deliv.set_defaults(func=cmd_delivery)
    dmode = sub.add_parser("delivery-mode",
                           help="entrega efectiva en una línea: review|prs|trunk, "
                                "o 'flow' si la tarea no declara ninguna")
    dmode.add_argument("task_dir")
    dmode.set_defaults(func=cmd_delivery_mode)
    pause = sub.add_parser("pause")
    pause.add_argument("task_dir")
    pause.add_argument("--reason", required=True)
    pause.add_argument("--detail", required=True)
    pause.add_argument("--actor", required=True)
    pause.set_defaults(func=cmd_pause)
    resume = sub.add_parser("resume")
    resume.add_argument("task_dir")
    resume.add_argument("--actor", required=True)
    resume.set_defaults(func=cmd_resume)
    cost = sub.add_parser("record-cost")
    cost.add_argument("task_dir")
    cost.add_argument("--total-usd", required=True, type=float)
    cost.set_defaults(func=cmd_record_cost)
    dag = sub.add_parser("validate-dag")
    dag.add_argument("dag")
    dag.set_defaults(func=cmd_validate_dag)
    dago = sub.add_parser("dag-order",
                          help="orden topológico de repos para ship-wave")
    dago.add_argument("task_dir")
    dago.set_defaults(func=cmd_dag_order)
    ship = sub.add_parser("validate-ship")
    ship.add_argument("task_dir")
    ship.add_argument("--commit", required=True,
                      help="el HEAD que se pushea (post-rebase)")
    ship.add_argument("--patch-id", default="",
                      help="identidad del cambio actual (scripts/change-id.sh); "
                           "permite reusar un veredicto cuyo SHA cambió por rebase")
    ship.add_argument("--base-moved", type=int, default=None,
                      help="commits que avanzó la base desde el review")
    ship.add_argument("--verdict", required=True)
    ship.set_defaults(func=cmd_validate_ship)
    lanelim = sub.add_parser("lane-limits",
                             help="techos de tamaño que promete un carril, una "
                                  "línea clave=valor por techo (stdout vacío = "
                                  "el carril no promete ninguno)")
    lanelim.add_argument("lane")
    lanelim.set_defaults(func=cmd_lane_limits)
    evpol = sub.add_parser("evidence-policy")
    evpol.add_argument("--field", default="required_evidence_kinds",
                       choices=("required_evidence_kinds", "require_fresh_evidence"))
    evpol.set_defaults(func=cmd_evidence_policy)
    return root


if __name__ == "__main__":
    parsed = build_parser().parse_args()
    raise SystemExit(parsed.func(parsed))
