#!/usr/bin/env python3
"""Policy engine v1 for task transitions and the final ship contract."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
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


def utcnow() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def set_phase(state: dict, phase: str) -> None:
    """La fase y CUÁNDO empezó, siempre juntas.

    `phase_since` no es telemetría: es la VENTANA que usan los dos términos de
    banda del costo. `cache_hit` y `ctx_avg` son promedios sobre transcripts
    inmutables, así que un umbral sobre toda la historia de la tarea es un
    trinquete de un solo sentido: el primer agente que cerró bajo el piso
    bloquea TODA transición futura, y la remediación que el gate imprime
    (recortar el contexto de arranque) solo puede afectar a agentes que
    todavía no corrieron (issue #95).

    Con el instante estampado acá, `harness-cost.py check` mide esos dos
    términos sobre la fase EN CURSO, que es lo único sobre lo que el operador
    puede actuar. El gasto en dólares sigue midiéndose sobre toda la tarea:
    ese sí es acumulativo.

    Se estampa en TODO cambio de fase (transition, escalate, rollback, pause y
    resume): una fase que empieza sin estampa dejaría la ventana anclada a la
    anterior, que es el bug con más pasos."""
    state["phase"] = phase
    state["phase_since"] = utcnow()


def current_session(task_dir: Path) -> str:
    """Qué sesión está manejando ESTA tarea ahora mismo, o "" si no se sabe.

    El id de sesión solo existe dentro del payload de los hooks, así que el
    puente lo deja `track-read.sh` en `tasks/<id>/.session` cada vez que la
    sesión toca algo de la tarea. `HARNESS_SESSION_ID` lo pisa, para los tests
    y para cualquier runtime que sí lo exporte. Vacío significa "no se sabe", y
    no saber no se inventa."""
    env = (os.environ.get("HARNESS_SESSION_ID") or "").strip()
    if env:
        return env
    try:
        return (task_dir / ".session").read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def fase_se_releva(state: dict, current: str, phase: str) -> bool:
    """Las tres condiciones ESTRUCTURALES del relevo de fase.

    Existe como función porque la contestan DOS lugares (quién escribe el
    marcador y quién decide si el gate de contexto puede cobrarse), y dos
    copias divergirían justo donde duele: una diría "te relevo" y la otra no
    relevaría."""
    return (phase != current and phase not in ("archive", "deploy")
            and state.get("lane") != "quick")


def relevo_efectivo(task_dir: Path, state: dict, current: str, phase: str) -> bool:
    """¿Esta transición va a relevar la sesión DE VERDAD?

    Es `fase_se_releva` más la pregunta que el marcador solo no contesta: ¿hay
    alguien que vaya a levantar la sesión nueva? El corte lo ejecuta
    `orchestrator-watch.sh`, así que con el vigilante apagado el marcador se
    escribe y no lo consume nadie: quien sigue trabajando es la MISMA sesión con
    el MISMO contexto.

    Fail-CLOSED a propósito, y es la mitad que sostiene todo el cambio: el gate
    de contexto deja de cobrarse solo cuando el contexto del que se queja está
    por descartarse. Si no se descarta, cobra como siempre."""
    if not fase_se_releva(state, current, phase):
        return False
    if os.environ.get("HARNESS_ORCH_OFF"):
        return False
    return not (task_dir.parent.parent / ".harness" / "orch-watch.off").exists()


def write_handoff(task_dir: Path, phase: str, from_session: str) -> None:
    """Deja el marcador de RELEVO: esta fase la sigue una sesión nueva.

    POR QUÉ EXISTE: medido sobre una tarea de un repo, una migración y dos
    rondas de review, el orquestador fue UNA sola sesión de punta a punta
    durante 45.3h de las 45.4h de reloj, con 688 turnos, 440k de contexto medio
    y 294M de lectura de caché. El trabajo real de los subagentes fueron 5.8h:
    el resto es una sesión sola, cada turno más lento y más caro cuanto más
    contexto arrastra. Y el contexto es cosa de FASE, no de tarea: el propio
    harness ya lo modela así (el eximido de `ctx` se ata a la fase en que se
    autorizó), pero la sesión no lo hacía, así que hubo tareas que firmaron
    CUATRO cost-waives del mismo COST-CTX, una por fase.

    QUIÉN EJECUTA EL CORTE, que es la parte que no puede quedar ambigua: un
    prompt no puede terminarse a sí mismo ni relanzarse, así que el corte lo
    ejecuta `orchestrator-watch.sh`, que ya sabe lanzar `claude -p '/smart
    <id>'` con contexto fresco. Esto solo deja el marcador; el orquestador
    cierra su turno y el vigilante retoma. Sin marcador el vigilante se
    comporta como siempre (regla de silencio de bus), así que una tarea en
    vuelo de una versión anterior no cambia de conducta."""
    payload = {"schema": 1, "phase": phase, "at": utcnow(),
               "from_session": from_session}
    try:
        task_dir.mkdir(parents=True, exist_ok=True)
        tmp = task_dir / "handoff.json.tmp"
        tmp.write_text(json.dumps(payload) + "\n", encoding="utf-8")
        tmp.replace(task_dir / "handoff.json")
    except Exception:
        pass          # fail-open: el relevo es una optimización, no un gate


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

# Cuántos minutos en una fase antes de que la tarea sea SOSPECHOSA (issue #155).
#
# POR QUÉ EXISTE: una tarea puede pasar 12h46m en `implement`, con su trabajo
# hecho y su precheck verde, y nada del harness lo detecta. La encontró un humano
# mirando timestamps de archivos. No estaba pausada ni bloqueada: estaba detenida
# y contada como si avanzara, que es el peor modo de falla porque desde afuera se
# ve IDÉNTICA a una tarea que progresa. Pasó tres veces el mismo día.
#
# El watchdog que ya existía (~3 min sin tool call) es una regla del ORQUESTADOR,
# y solo funciona mientras el orquestador esté mirando; si está esperando una
# notificación que nunca llega, no hay quien la aplique. Justo el caso.
#
# El dato ya estaba: `phase_since` lo estampa set_phase en TODO movimiento. Lo
# único que faltaba era alguien que lo comparara contra ahora.
#
# Los umbrales son por fase porque el trabajo no dura lo mismo: un `implement` de
# 40 minutos es normal, un `ship` de 40 no (ship.sh es mecánico: rebase, gates,
# push). Van holgados a propósito: un falso positivo cuesta un evento de bus, y
# el falso negativo medido costó 12h46m de reloj de nadie.
# `blocked` y `archive` quedan exentas: una es una parada REGISTRADA esperando a
# un humano, y la otra terminó.
STALE_AFTER_MIN = {
    "intake": 30,      # las preguntas de enrichment pausan a blocked; un intake activo son minutos
    "rfc": 90,
    "implement": 120,  # cadenas seriales medidas de 80 min; 2h es techo holgado
    "review": 90,      # juicio de LLM, decenas de minutos; dos rondas caben
    "ship": 30,        # mecánico de punta a punta
    "deploy": 60,      # deploy-watch midió 39 min mirando UN deploy
}


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

    No todo lo que se registra en `history` es un movimiento de fase: promover
    la entrega (`kind=delivery`) o cambiar el ALCANCE (`kind=repos`) dejan
    historia sin mover la tarea de fase. Si contaran como movimiento, el último
    quedaría sin `to` y validate-ship acusaría de editar state.json a mano a
    quien usó el CLI: exactamente lo que esos comandos existen para evitar.

    El filtro es ESTRUCTURAL, no una lista de kinds. Antes se salteaba
    `kind=delivery` por nombre, y el kind siguiente que apareció (`repos`) cayó
    en la misma trampa sin que nadie lo notara: un `repos --add` legítimo dejaba
    la tarea acusada de edición manual, y con `--remove` es peor, porque ESE es
    el camino de salida de una tarea trabada (destrabarla la volvía a trabar un
    paso después). Un movimiento de fase es, por definición, una entrada que
    DECLARA `to`; lo que no lo declara no movió nada. Así el próximo kind nace
    correcto sin tocar esta función.

    El resto de la regla queda igual: una entrada que no es un objeto sigue
    delatando la edición manual, y por eso se conserva en la lista."""
    history = state.get("history")
    if not isinstance(history, list):
        history = []
    moves = [e for e in history if not isinstance(e, dict) or "to" in e]
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

# ── LAS DOS VERSIONES DEL DAG, Y POR QUÉ CONVIVEN ─────────────────────
# schema 1: `id`, `repo`, `depends_on`. Es todo lo que hacía falta mientras dos
#           tareas del mismo repo TENÍAN que ir en serie (POLICY-DAG-010).
# schema 2: agrega `files[]` por tarea, y con eso la serialización dentro de un
#           repo deja de ser obligatoria: dos tareas que declaran conjuntos de
#           archivos DISJUNTOS pueden correr en paralelo, cada una en su propio
#           worktree de nodo (worktrees/<task>/<repo>@<Tn>, rama task/<id>@<Tn>).
#           Medido: cadenas de 80 min por 6 tareas contra una cota paralela de
#           6-15 min por nodo.
# Los dos se aceptan a propósito: un dag.json de una tarea en vuelo no se
# reescribe por actualizar el harness, y schema 1 sigue siendo la respuesta
# correcta cuando no se sabe qué archivos toca cada tarea.
DAG_SCHEMAS = (1, 2)


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


def workspace_delivery(ws: Path) -> "str | None":
    """La entrega que el flow del workspace implica, o None si no se puede saber.

    Existe para el issue #74: escalar desde /quick daba vuelta la entrega EN
    SILENCIO. quick no declara `delivery` a propósito (su ship publica con el
    flow del workspace), pero la remediación que el propio harness prescribe al
    rebotarlo es `escalate` y seguir por `/smart`, y el encabezado de /smart
    declara sin condición que registra `delivery: review`, o sea que NO PUBLICA
    NADA. Caso de campo: cinco fixes de una línea, pipeline completo con RFC,
    5 implementers, 4 reviewers, QA, cuatro veredictos pass, y CERO commits
    publicados. Nada en el camino avisó que la entrega había cambiado.

    Materializar la entrega en el escalate cierra el agujero sin depender de que
    alguien lea una advertencia en el momento justo.

    OJO con el mapeo: `flow` y `delivery` NO son el mismo vocabulario. El flow
    del answers puede ser trunk-direct-to-prod o trunk-merge-commit, que no son
    valores válidos de delivery. Se traduce explícitamente y lo que no se
    entiende NO se inventa: devolver None deja la conducta de hoy, que es que
    manda el flow del workspace al shippear."""
    answers = ws / "harness-answers.yaml"
    try:
        text = answers.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    flow = None
    for line in text.splitlines():
        # anclado en columna 0, igual que el parser de ship.sh: una clave `flow`
        # anidada bajo otro bloque no es el knob de primer nivel.
        if not line.startswith("flow:"):
            continue
        value = line[len("flow:"):]
        value = value.split("#", 1)[0]                 # comentario al margen
        flow = value.strip().strip('"').strip("'").strip()
        break
    if not flow or "{{" in flow:
        # Placeholder sin sustituir: esa instancia se generó a medias y un
        # literal no es una respuesta.
        return None
    if flow == "prs":
        return "prs"
    # trunk-staging lo RECHAZA ship.sh (no lo implementa), así que traducirlo a
    # `trunk` prometería una publicación que no va a ocurrir.
    if flow.startswith("trunk") and "staging" not in flow:
        return "trunk"
    return None


# ── EL LEDGER DE SHIPS Y EL NOMBRE QUE LO DESTRUÍA ────────────────────
# `tasks/<id>/ship.log` nunca fue un log: es un ledger JSONL, una línea por repo
# shippeado, y es la única fuente de dos cosas que deciden si la tarea avanza
# (POLICY-SHIP-004 acá, y el sha que vigila deploy-watch allá). El nombre
# invitaba justo a lo que lo destruye: `ship.sh <id> <repo> > tasks/<id>/ship.log
# 2>&1` le da a stdout un fd con offset propio, el append del ledger escribe en
# EOF, y la prosa que ship.sh imprime DESPUÉS pisa esa línea JSON byte a byte. El
# ship sale 0, el push aterriza de verdad, y la tarea queda clavada en review con
# el código ya en main (caso de campo).
#
# El ledger se mudó a `ship-ledger.jsonl`, un nombre que nadie confunde con el
# destino de una redirección. Acá se leen LOS DOS, y en ese orden (primero el
# viejo, después el nuevo, que es el orden cronológico): una tarea en vuelo al
# momento de actualizar el harness tiene la mitad de sus ships de cada lado, y
# leer solo el archivo nuevo sería olvidar ships que de verdad ocurrieron.
SHIP_LEDGER = "ship-ledger.jsonl"
SHIP_LEDGER_LEGACY = "ship.log"


def ship_ledger(task_dir: Path) -> list:
    """Las entradas del ledger de ships de la tarea, en orden cronológico.

    Solo las líneas que parsean como JSON y son objetos: el `ship.log` viejo
    puede traer prosa (es exactamente el defecto que motivó la mudanza) y una
    línea corrupta no puede fingir que un repo shippeó."""
    entries = []
    for name in (SHIP_LEDGER_LEGACY, SHIP_LEDGER):
        path = task_dir / name
        if not path.exists():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue   # una línea corrupta no debe fingir que un repo shippeó
            if isinstance(entry, dict):
                entries.append(entry)
    return entries


def repos_shipped(task_dir: Path) -> set:
    """Los repos con al menos una línea de ledger, sin mirar si aterrizaron."""
    return {e.get("repo") for e in ship_ledger(task_dir) if e.get("repo")}


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
    existen: verdict-<repo>.json y el ledger de ships (ship-ledger.jsonl, con el
    ship.log viejo leído por compatibilidad).

    Límite: un repo de la tarea que todavía no tiene veredicto no se cuenta
    AQUÍ. Ese caso lo cierra repos_missing_verdict, que lee el inventario que
    sí existe cuando hay DAG: tasks/<id>/dag.json."""
    verdicts = sorted(
        p.name[len("verdict-"):-len(".json")]
        for p in task_dir.glob("verdict-*.json")
    )
    shipped = repos_shipped(task_dir)
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
    if not isinstance(dag, dict) or dag.get("schema") not in DAG_SCHEMAS or not isinstance(tasks, list):
        fail("POLICY-SHIP-004",
             f"tasks/{task_dir.name}/dag.json no cumple schema:1|2 con tasks[]: "
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
    avisarlo a mano).

    ── POR QUÉ EL MTIME NO ALCANZABA ─────────────────────────────────────
    Comparar mtimes lo derrota CUALQUIER escritura mecánica posterior sobre el
    veredicto, y hay una que el propio flujo prescribe: fundir el campo `qa` es
    un paso de /review, o sea que en TODA tarea el veredicto se reescribe
    después del juicio del reviewer. Segundo caso de campo, con 17 segundos de
    ventana: delta-spec.md editado a las 23:20:26, verdict refundido a las
    23:20:43, gate en verde, y el reviewer había cerrado antes del texto nuevo.
    Cualquier edición del delta que caiga en esa ventana quedaba blanqueada.

    Ahora manda la IDENTIDAD DE CONTENIDO: `delta_spec_sha256`, que
    verdict-scaffold.sh sella con el delta que ese veredicto mira. No lo mueve
    ninguna escritura mecánica y además sobrevive a un `git checkout`, que
    también resetea mtimes. Un veredicto cuyo hash coincide con el delta actual
    es prueba positiva de que ese texto SÍ fue juzgado.

    El mtime queda como piso para los veredictos VIEJOS, que no traen el campo:
    sin él la señal es imperfecta (un touch o un rsync la disparan), pero el
    falso positivo cuesta un re-veredicto barato y el falso negativo costaría
    spec rot con firma de reviewer.

    Fail-open cuando falta una de las dos partes: sin delta no hay nada que
    fusionar; sin veredictos no hay juicio contra el cual comparar."""
    delta = task_dir / "delta-spec.md"
    verdicts = list(task_dir.glob("verdict-*.json"))
    if not delta.exists() or not verdicts:
        return None

    sellados = []
    for v in verdicts:
        try:
            sellados.append(json.loads(v.read_text(encoding="utf-8"))
                            .get("delta_spec_sha256") or "")
        except (OSError, json.JSONDecodeError, AttributeError):
            sellados.append("")
    if any(sellados):
        vigente = hashlib.sha256(delta.read_bytes()).hexdigest()
        if vigente in sellados:
            return None
        return ("delta-spec.md cambió después del último veredicto: su hash "
                f"({vigente[:12]}) no es el que ningún verdict-*.json declara "
                "haber revisado")

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
    deja `landed:false` en el ledger: el cambio NO está en la trunk. Avanzar a
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
    pending = []
    for entry in ship_ledger(task_dir):
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


def repo_names(ws: Path) -> "set | None":
    """Nombres declarados en manifest.yaml, o None si no se pudo leer.

    Mismo parseo a mano que repo_kinds (sin dependencia yaml), pero NO se
    puede reusar repo_kinds: ese dict solo registra el repo cuando encuentra
    su 'kind:', y un manifest con una entrada sin kind haría "desconocido" a
    un repo real, cosa que un rechazo duro (repos --add) no puede permitirse.

    None distingue "no pude leer" de "leí y no había repos": sin manifest (o
    ilegible) el llamador degrada con aviso, igual que vet_repos_for_lane;
    el backstop sigue siendo worktree-task.sh, que rechaza el repo no
    clonado al crear el worktree."""
    try:
        text = (ws / "manifest.yaml").read_text(encoding="utf-8")
    except OSError:
        return None
    names = set()
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if line.startswith("- name:"):
            names.add(line[len("- name:"):].strip().strip("'\""))
    return names


def vet_repos_for_lane(lane: str, repos: list, ws: Path) -> None:
    """Chequea carril vs repos ANTES de gastar un implementer.

    Vivía adentro de cmd_init, y por eso solo se cobraba al abrir la tarea:
    sumar un repo despues (`repos --add`) se saltaba el freno entero. Es la
    misma verificación en los dos momentos, así que es UNA función: dos copias
    divergen en silencio justo donde el carril promete algo que gate_lane va a
    cobrar al final.

    Los mensajes NO cambian sin motivo: hay tests que comparan texto literal, y
    quien los lee en la terminal ya aprendió a reconocerlos. La excepción
    deliberada es POLICY-LANE-004, que pasó de RECHAZO a AVISO (#71) porque
    decidía por el kind del repo y no por el diff; el identificador se conserva
    justo para que siga siendo grepeable y reconocible. POLICY-LANE-005 sigue
    siendo rechazo duro: que quick sea de un solo repo es una promesa
    estructural que ningún diff arregla."""
    if not repos:
        return
    # quick es de UN repo, y eso se puede comprobar ACÁ: es la única
    # promesa del carril que no necesita ver el diff. quick no genera DAG,
    # así que nada ordena el ship entre repos, y descubrirlo al final
    # costaría el trabajo del implementer más una escalada.
    distinct = list(dict.fromkeys(repos))
    # ── triado también promete UN repo, y por un motivo distinto ─────────
    # quick es de un repo porque no genera DAG. triado SÍ genera DAG, así que
    # el ship se ordenaría igual; lo que no sobrevive al segundo repo es su
    # PREMISA: el carril existe porque un triage read-only ya recorrió UN
    # código y dejó cada defecto con evidencia archivo:símbolo, y eso es lo
    # que autoriza a saltarse la sesión del architect. Dos repos son dos
    # terrenos, y el segundo no lo recorrió nadie. Medido: la ventana
    # intake→rfc→implement en lotes ya triados son 11-17 minutos para producir
    # un plan que el triage ya había escrito; recuperar eso vale solo mientras
    # la evidencia cubra todo lo que se va a tocar.
    if lane == "triado" and len(distinct) > 1:
        fail("POLICY-LANE-006",
             f"triado es de UN repo; esta tarea declara {len(distinct)}: "
             f"{', '.join(distinct)}. El carril salta la sesión del architect "
             "porque un triage read-only ya dejó cada defecto con su evidencia "
             "archivo:símbolo EN ESE código; un segundo repo no tiene esa "
             "evidencia y el plan pasaría a ser una conjetura. Remediación: "
             "una tarea triado por repo, o iniciá con --lane standard")
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
    if lane in ("quick", "express", "triado"):
        infra = [r for r in repos if kinds.get(r) in ("infra-live", "infra-module")]
        # ── EN `quick` VUELVE A SER RECHAZO DURO ──────────────────────────
        # #71 lo degradó a aviso con razón: decidía por el KIND DEL REPO y no
        # por el diff, y 20 de 31 repos del workspace son infra-* porque llevan
        # su terraform al lado del código, así que un cambio de dos líneas se
        # quedaba sin carril rápido.
        #
        # Lo que cambió desde entonces es QUIÉN elige el carril. `quick` dejó
        # de ser una promesa que solo el humano podía hacer: /smart ahora lo
        # clasifica solo (paso 0.1). Un carril que una máquina elige necesita
        # un piso que no dependa de que la máquina haya juzgado bien, y el
        # backstop que lo cubría (`gate_lane`) mira el diff RECIÉN en el
        # precheck. Para express y triado el aviso sigue siendo correcto: ésos
        # los sigue eligiendo un criterio con más evidencia delante.
        if infra and lane == "quick":
            fail("POLICY-LANE-004",
                 f"quick con repos de infra: {', '.join(infra)} (kind "
                 "infra-module/infra-live en manifest.yaml). quick es el único "
                 "carril que /smart clasifica solo y el más corto de todos, así "
                 "que su piso no puede depender de un juicio: acá se rechaza en "
                 "el acto en vez de descubrirlo en gate_lane, después de que el "
                 "implementer trabajó. Remediación: iniciá con --lane express, "
                 "que sí acepta repos de infra y verifica lo mismo sobre el "
                 "diff (gate_lane, en el precheck)")
        if infra:
            # ── AVISA, NO RECHAZA (#71) ────────────────────────────────
            # Esto rechazaba por el KIND DEL REPO, antes de que existiera un
            # diff. El gate que decía anticipar (gate_lane, en ship.sh) decide
            # por las RUTAS QUE EL DIFF TOCA, así que este chequeo era
            # estrictamente MÁS GRUESO que el que protege: miraba el repo
            # entero, no el cambio.
            #
            # Medido: 20 de 31 repos del workspace son infra-* porque son apps
            # que llevan su terraform/ al lado del código. Agregar dos líneas a
            # un .gitignore no tenía NINGÚN carril rápido: el único camino era
            # --lane standard, o sea RFC con abogados para un cambio de dos
            # líneas que gate_lane habría dejado pasar. Eso empuja justo adonde
            # la Ley 15 dice que no: ceremonia desproporcionada, o saltarse el
            # carril.
            #
            # El freno no desaparece, se muda a donde el criterio es correcto:
            # gate_lane corre en el PRECHECK, antes de gastar reviewer, así que
            # descubrirlo ahí es barato. Y va atado a haber cerrado el hueco de
            # `.tf` suelto en LANE_GUARD_PATTERN: sin eso, este aviso dejaría
            # pasar un terraform crudo sin ningún freno.
            print(f"⚠️  POLICY-LANE-004 (aviso): carril {lane} con repos de "
                  f"infra: {', '.join(infra)} (kind infra-module/infra-live en "
                  "manifest.yaml). El carril promete cero contratos, "
                  "migraciones ni infra, y quien lo verifica es gate_lane en el "
                  "precheck, sobre lo que el diff TOCA: si tu cambio no toca "
                  "terraform/helm/proto/migraciones, pasa; si los toca, ahí "
                  "escalás y no perdiste el trabajo",
                  file=sys.stderr)
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
        # La primera fase también tiene comienzo: sin esto, la ventana de las
        # bandas de costo no existiría hasta la primera transición y el gate
        # mediría toda la historia justo en el tramo más largo de la tarea.
        "phase_since": utcnow(),
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
    set_phase(state, destination)
    state.setdefault("history", []).append({
        "from": previous_phase, "to": destination, "actor": args.actor,
        "lane": f"{current_lane}→{args.to}", "reason": args.reason,
    })
    # ── LA ENTREGA ES EL TERCER DATO DE NACIMIENTO (#74) ────────────────
    # Escalar ya conserva worktree y commits. La entrega era el único de los
    # tres que el salto de carril dejaba a merced de la prosa del comando de
    # DESTINO: una tarea de /quick llega acá SIN el campo, y /smart declara en
    # su encabezado, sin condición, que registra `delivery: review` y no publica
    # nada. El humano invocó algo que iba a aterrizar, siguió la remediación que
    # el harness le indicó, y terminó verde y sin publicar.
    #
    # Materializar no publica MÁS de lo prometido: sin escalar, ese /quick iba a
    # aterrizar por el flow del workspace igual. La escalación solo agrega
    # deliberación en el medio, no cambia el destino.
    if delivery_of(state) is None:
        implied = workspace_delivery(task_dir.parent.parent)
        if implied:
            state["delivery"] = implied
            state["history"].append({
                "kind": "delivery", "delivery": implied, "actor": args.actor,
                "reason": "escalate: la entrega de nacimiento no cambia de carril "
                          f"(materializada del flow del workspace)",
            })
            print(f"📦 entrega materializada: {implied} (la tarea nació para publicar "
                  "por el flow del workspace; subir de carril no lo cambia)")
        else:
            # No se inventa. Sin answers legible, queda ausente y al shippear
            # manda el flow vigente, que es exactamente la conducta de hoy.
            print("⚠️  no pude leer el flow del workspace: la entrega queda sin "
                  "declarar y al shippear manda el flow vigente. Si seguís por "
                  "/smart, ojo que ese comando registra delivery: review",
                  file=sys.stderr)
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


def cmd_budget(args: argparse.Namespace) -> int:
    """Sube el techo de gasto de una tarea VIVA, con actor y motivo.

    POR QUÉ EXISTE: `POLICY-BUDGET-005` frena una transición cuando la tarea se
    fue de banda, y su primer mensaje ofrecía como salida "subilo con
    `init --budget-usd`". Eso era FALSO: `init` se niega sobre una tarea que ya
    tiene estado (`POLICY-STATE-001`), así que la única remediación escrita no
    existía y el gate era un callejón sin salida. Es exactamente el defecto que
    este harness persigue en todos lados (prosa que promete lo que el código no
    hace), cometido por el gate que vino a arreglar el gasto.

    SOLO SUBE, por la misma razón que `delivery`: bajar el techo de una tarea en
    vuelo no deshace lo gastado, solo deja el estado mintiendo sobre lo que ya
    ocurrió. Y queda en `history[]`, que es lo que lo vuelve auditable: un techo
    que se mueve sin dejar quién ni por qué es un techo decorativo.

    Lo que NO es: un modo de apagar el gate. Para una emergencia de producción
    están `HARNESS_CTX_CEILING` y `HARNESS_CACHE_HIT_FLOOR`, que `transition`
    propaga al medidor; eso es una perilla de operación y no deja rastro, así
    que es el último recurso y no el primero.
    """
    task_dir = Path(args.task_dir).resolve()
    path = state_path(task_dir)
    if not (isinstance(args.to, (int, float)) and math.isfinite(args.to)
            and args.to > 0):
        fail("POLICY-BUDGET-006",
             f"presupuesto inválido: {args.to} (debe ser finito y mayor que cero)")
    lock_state(task_dir)
    state = load(path, "estado")
    current = state.get("budget_usd")
    if isinstance(current, (int, float)) and args.to <= current:
        fail("POLICY-BUDGET-007",
             f"el presupuesto no se baja: esta tarea tiene ${current:.2f} y "
             f"pediste ${args.to:.2f}. Bajarlo no deshace lo gastado, solo deja "
             "el estado mintiendo sobre lo que ya ocurrió. Si querés que la "
             "tarea no siga, no la sigas: dejala donde está y reportala")
    state["budget_usd"] = float(args.to)
    state.setdefault("history", []).append({
        "kind": "budget",
        "budget_usd": f"{current}→{args.to}",
        "actor": args.actor, "reason": args.reason,
    })
    atomic(path, state)
    emit_bus(task_dir, "decision",
             f"presupuesto {current} → ${args.to:.2f} (autoriza {args.actor})"
             + (f": {args.reason}" if args.reason else ""))
    print(f"💰 {task_dir.name}: presupuesto → ${args.to:.2f} "
          f"(autoriza {args.actor})")
    return 0


COST_BANDS = {"cache": "COST-CACHE", "ctx": "COST-CTX"}


def cost_check(task_dir: Path, as_json: bool = False):
    """Corre la báscula sobre la tarea. Devuelve el CompletedProcess, o None.

    UN SOLO llamador para las dos bocas (el gate de `transition` y `cost-waive`):
    si cada uno armara su entorno, uno mediría un workspace y el otro otro, y el
    eximido no correspondería al breach que frenó."""
    tool = Path(__file__).resolve().parent / "harness-cost.py"
    if not tool.is_file():
        return None
    env = os.environ.copy()
    # El workspace se pasa explícito: harness-cost.py lo deriva de su propia
    # ruta, y eso es correcto en una instancia instalada pero no cuando el
    # script se invoca desde el árbol del generador o desde un worktree.
    env.setdefault("HARNESS_WS", str(task_dir.resolve().parent.parent))
    cmd = [sys.executable, str(tool), "check", task_dir.name]
    if as_json:
        cmd.append("--json")
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=60, env=env)
    except Exception:
        return None                      # medir no puede tumbar la corrida


def cmd_cost_waive(args: argparse.Namespace) -> int:
    """Acepta un término de banda del costo con actor y motivo, en history[].

    POR QUÉ EXISTE: `POLICY-BUDGET-005` agrega tres términos y hasta acá solo
    UNO tenía escape auditable. `budget --to` mueve el techo en dólares y por
    eso destraba `COST-BUDGET`, pero `COST-CACHE` y `COST-CTX` se evaluaban
    igual pasara lo que pasara con el presupuesto.

    Y esos dos términos son HISTÓRICOS: salen de los transcripts de un agente
    que ya cerró, así que la remediación que el gate imprime (recortar el
    contexto de ARRANQUE del agente) no se puede aplicar en retroactivo. Con la
    remediación inaplicable y sin override, la única salida que quedaba era
    `HARNESS_CACHE_HIT_FLOOR`: apagar el umbral de la corrida, sin rastro. Una
    tarea con el trabajo commiteado y el precheck verde quedaba viva e INMÓVIL,
    y el escape que existía era justo el que nadie puede auditar.

    LO QUE NO ES: un modo de apagar el gate.
      · El término tiene que EXISTIR: no se puede eximir por adelantado, porque
        el eximido se ancla al valor MEDIDO en el momento de autorizarlo.
      · Cubre ese valor, no la banda: algo peor vuelve a frenar (`covered_by` en
        harness-cost.py).
      · No se puede eximir `COST-BUDGET`: ese ya tiene `budget --to`, que dice
        con un número cuánto se autoriza.
      · Cada `cost-check` posterior lo IMPRIME con quién lo autorizó y por qué.
    """
    task_dir = Path(args.task_dir).resolve()
    path = state_path(task_dir)
    code = COST_BANDS.get(args.band)
    if not code:
        fail("POLICY-COST-001",
             f"banda desconocida: {args.band} (eximibles: "
             f"{', '.join(sorted(COST_BANDS))}). El gasto en dólares NO se exime "
             "acá: para eso está `harness-policy.py budget tasks/<id> --to <n>`, "
             "que autoriza un número y no una excepción")
    if not (args.reason or "").strip():
        fail("POLICY-COST-004",
             "un eximido sin motivo es un gate apagado con más pasos: "
             "--reason \"<por qué este término se acepta>\"")
    proc = cost_check(task_dir, as_json=True)
    if proc is None or not (proc.stdout or "").strip():
        fail("POLICY-COST-003",
             "no pude medir el costo de esta tarea, así que no hay término que "
             "eximir: un eximido a ciegas declara algo que nadie midió. "
             "Corré `scripts/harness-cost.py check " + task_dir.name + "` y "
             "mirá por qué no mide (¿CLAUDE_CONFIG_DIR, transcripts de otro "
             "cliente?)")
    try:
        report = json.loads(proc.stdout.strip().splitlines()[-1])
    except Exception:
        # El caso más común no es un JSON roto: es la báscula fallando ABIERTO
        # (sin transcripts no se puede afirmar nada). Se muestra su salida tal
        # cual, porque ahí está el motivo y esconderlo mandaría a depurar jq.
        fail("POLICY-COST-003",
             "la báscula no midió esta tarea, así que no hay término que "
             "eximir: un eximido a ciegas declara algo que nadie midió. Dijo:\n"
             + (proc.stdout or proc.stderr or "").strip()[:500])
    breach = next((b for b in report.get("breaches") or []
                   if b.get("code") == code and b.get("agent") == args.agent), None)
    if breach is None:
        ya = next((w for w in report.get("waived") or []
                   if w.get("code") == code and w.get("agent") == args.agent), None)
        if ya:
            print(f"✅ {task_dir.name}: {code} de {args.agent} ya estaba eximido "
                  f"por {(ya.get('waiver') or {}).get('actor', '?')} "
                  f"({(ya.get('waiver') or {}).get('reason', '')}). Nada que hacer")
            return 0
        corto = next((u for u in report.get("unmeasurable") or []
                      if u.get("code") == code and u.get("agent") == args.agent), None)
        if corto:
            fail("POLICY-COST-002",
                 f"{code} de {args.agent} NO frena esta tarea: {corto.get('text')}. "
                 "No hay nada que eximir")
        vivos = ", ".join(
            f"{b.get('code')}/{b.get('agent')}" for b in report.get("breaches") or [])
        fail("POLICY-COST-002",
             f"esta tarea no tiene un {code} de '{args.agent}' frenándola, y un "
             "eximido se ancla al valor MEDIDO: eximir por adelantado sería "
             "declarar algo que nadie midió. Lo que hay ahora es: "
             + (vivos or "nada fuera de banda"))
    lock_state(task_dir)
    state = load(path, "estado")
    waivers = state.get("cost_waivers")
    if not isinstance(waivers, list):
        waivers = []
    # Uno por (banda, rol): re-autorizar un valor PEOR reemplaza el anterior, y
    # la traza de las dos autorizaciones queda igual en history[], que es donde
    # se audita. Dos eximidos del mismo par solo servirían para que el más laxo
    # tape al otro sin que nadie lo vea.
    waivers = [w for w in waivers
               if not (isinstance(w, dict) and w.get("band") == args.band
                       and w.get("agent") == args.agent)]
    entry = {
        "band": args.band, "agent": args.agent, "value": breach.get("value"),
        "actor": args.actor, "reason": args.reason,
        "at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    # ── LA FASE, PARA EL TÉRMINO QUE NO PUEDE ANCLARSE A UN VALOR (#103) ──
    # `cache` sale de un agente que ya cerró: su transcript es inmutable y el
    # valor clavado alcanza. `ctx` del orquestador NO: está vivo por definición
    # en el momento de pedir la transición, su contexto medio solo crece, y lo
    # suben las tool calls de este mismo comando. Anclarlo a un valor lo dejaba
    # VENCIDO ANTES DE ESCRIBIRSE (medido: se autorizó 167938.23 y la siguiente
    # medición ya daba 169k), así que el único escape auditable no servía para
    # el caso más común y quedaba `HARNESS_CTX_CEILING`, que no deja rastro.
    #
    # Se ata a la fase, que es la MISMA ventana en la que el término se mide
    # (`phase_since`). Caduca sola en la próxima transición: no es un cheque en
    # blanco, es un cheque con la vigencia de lo que cubre.
    if args.band == "ctx":
        entry["phase"] = state.get("phase") or ""
    waivers.append(entry)
    state["cost_waivers"] = waivers
    # kind=cost-waive: no es un movimiento de fase (phase_is_declared lo saltea
    # como delivery y budget). Lo que registra es QUIÉN aceptó el término.
    state.setdefault("history", []).append({
        "kind": "cost-waive", "band": args.band, "agent": args.agent,
        "value": breach.get("value"), "actor": args.actor, "reason": args.reason,
    })
    atomic(path, state)
    emit_bus(task_dir, "decision",
             f"{code} de {args.agent} aceptado (autoriza {args.actor}): {args.reason}")
    print(f"🧾 {task_dir.name}: {code} de {args.agent} aceptado "
          f"(autoriza {args.actor}). Queda en history[] y cada cost-check lo dice")
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
    set_phase(state, "blocked")
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
    set_phase(state, destination)
    state.setdefault("history", []).append({
        "from": "blocked", "to": destination, "actor": args.actor,
    })
    atomic(path, state)
    emit_bus(task_dir, "phase", f"reanuda en {destination}")
    print(f"▶️  {task_dir.name}: reanuda en {destination}")
    return 0


def cmd_stale(args: argparse.Namespace) -> int:
    """Las tareas detenidas en una fase no terminal, comparando phase_since con ahora.

    Exit 0 = ninguna sospechosa. Exit 1 = hay al menos una (distinto del 3 de
    fail(), que significa "no pude mirar"). Una línea por tarea en stdout:
    `<task>\t<fase>\t<minutos>`, para que sea grepeable desde el vigilante.

    NO pausa ni relanza: avisar y actuar son cosas distintas, y una tarea que
    lleva mucho en una fase puede estar perfectamente viva (un test de 3h). El
    que relanza es orchestrator-watch, que ya sabe hacerlo.

    Sin `phase_since` legible la tarea se AVISA igual: no poder mirar no es
    verde, y es exactamente lo que pasaría con un state.json de una versión
    vieja del harness."""
    tasks_root = Path(args.tasks_root).resolve()
    if not tasks_root.is_dir():
        fail("POLICY-STALE-001", f"no existe el directorio de tareas: {tasks_root}")
    now = dt.datetime.now(dt.timezone.utc)
    found = 0
    for state_file in sorted(tasks_root.glob("*/state.json")):
        task_dir = state_file.parent
        try:
            state = json.loads(state_file.read_text(encoding="utf-8"))
        except Exception:
            continue                      # un state ilegible ya lo grita todo lo demás
        phase = state.get("phase", "")
        limit = STALE_AFTER_MIN.get(phase)
        if limit is None:                 # blocked, archive, o una fase que no conocemos
            continue
        since = parse_iso(state.get("phase_since"))
        if since is None:
            print(f"{task_dir.name}\t{phase}\t?\tsin phase_since legible")
            found += 1
            continue
        minutes = int((now - since).total_seconds() // 60)
        if minutes <= limit:
            continue
        found += 1
        print(f"{task_dir.name}\t{phase}\t{minutes}\t(techo {limit}m)")
        # El bus solo una vez por fase: el vigilante pasa cada 120s y un aviso
        # repetido cada dos minutos durante 12 horas es ruido que se aprende a
        # ignorar, o sea el mismo silencio con más pasos. El marcador guarda el
        # phase_since ya avisado: cuando la tarea se mueve, el aviso se rearma.
        marker = tasks_root.parent / ".harness" / "stale" / task_dir.name
        stamp = state.get("phase_since", "")
        already = ""
        try:
            already = marker.read_text(encoding="utf-8").strip()
        except Exception:
            pass
        if already != stamp:
            emit_bus(task_dir, "stop",
                     f"{minutes}m en {phase} sin terminar (techo {limit}m): miralo o pausalo")
            try:                          # fail-open: es un hint, no estado de la tarea
                marker.parent.mkdir(parents=True, exist_ok=True)
                marker.write_text(stamp, encoding="utf-8")
            except Exception:
                pass
    return 1 if found else 0


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


def _dag_files(task_id: str, item: dict, schema: int) -> list:
    """Los archivos que ESTA tarea del DAG declara tocar (schema 2).

    FAIL-CLOSED, y ahí está todo el diseño: con schema 2 el campo es
    OBLIGATORIO y no vacío. Un nodo sin `files` no es "un nodo que toca poco":
    es un nodo del que no se sabe nada, y la única regla que puede aplicarse a
    lo desconocido es la vieja (serializar). Permitirlo vacío convertiría el
    silencio en permiso de paralelizar, que es exactamente cómo se pierde
    trabajo: dos implementers sobre el mismo archivo, un `git add` amplio y seis
    archivos del vecino en el commit equivocado (caso de campo de DAG-010)."""
    if schema < 2:
        return []
    declared = item.get("files")
    if not isinstance(declared, list) or not declared \
       or any(not isinstance(f, str) or not f.strip() for f in declared):
        fail("POLICY-DAG-011",
             f"schema:2 exige files[] no vacío en cada tarea, y {task_id} no lo trae. "
             "files[] es lo que habilita el paralelo dentro de un repo (worktree "
             "por nodo): sin él no se puede saber si dos nodos se pisan, y lo "
             "desconocido se serializa. ↳ remediación: declará las rutas que "
             f"{task_id} va a tocar (salen del grafo, no de grep), o bajá el DAG "
             "a schema:1 y ordená los nodos con depends_on")
    # Normalizadas: el mismo archivo escrito de dos formas ("./a.go", "a.go")
    # no puede leerse como dos archivos distintos, porque eso volvería
    # "disjuntos" a dos nodos que pisan el mismo archivo.
    return sorted({f.strip().lstrip("./") for f in declared})


def load_dag_nodes(dag_path: Path) -> "tuple[dict, dict]":
    """Valida el DAG completo (DAG-001..007) y devuelve (deps, repo) por id.

    Es LA validación de cmd_validate_dag, extraída para que dag-order use
    exactamente las mismas reglas: dos validadores del mismo artefacto es una
    oportunidad de divergir."""
    dag = load(dag_path, "DAG")
    schema = dag.get("schema")
    if schema not in DAG_SCHEMAS or not isinstance(dag.get("tasks"), list) or not dag["tasks"]:
        fail("POLICY-DAG-001", "dag.json requiere schema:1 (o 2, con files[]) y tasks[] no vacío")
    nodes: dict[str, list[str]] = {}
    repos: dict[str, str] = {}
    files: dict[str, list[str]] = {}
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
        files[task_id] = _dag_files(task_id, item, schema)
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

    # ── LA EXCEPCIÓN MEDIDA: ARCHIVOS DISJUNTOS DECLARADOS (schema 2) ────
    # La premisa de DAG-010 sigue siendo cierta: un worktree por (tarea, repo)
    # significa UN árbol, UNA rama y UN index compartidos. Lo que cambia con
    # schema 2 es que el DAG puede decir qué toca cada nodo, y entonces el
    # harness puede darle a cada uno SU worktree (worktrees/<task>/<repo>@<Tn>,
    # rama task/<id>@<Tn>) y coalescer después con dag-coalesce.sh.
    #
    # El número que justifica la excepción: cadenas medidas de 80 min por 6
    # tareas, 50 por 4, 36 por 6, contra una cota paralela de max(nodo) = 6-15
    # min. Lo que NO cambia: sin `files` declarados no hay excepción (ver
    # _dag_files), y el conflicto semántico entre archivos disjuntos lo caza el
    # precheck (build + tests) antes de gastar un reviewer.
    def disjuntos(left: str, right: str) -> bool:
        a, b = set(files.get(left, [])), set(files.get(right, []))
        return bool(a) and bool(b) and not (a & b)

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
                if disjuntos(left, right):
                    continue
                if schema >= 2:
                    compartidos = sorted(set(files.get(left, [])) & set(files.get(right, [])))
                    fail("POLICY-DAG-010",
                         f"{left} y {right} comparten el repo '{repo}', el DAG no las "
                         f"ordena, y sus files[] SE PISAN: {', '.join(compartidos)}. "
                         "El paralelo dentro de un repo solo es seguro con conjuntos "
                         "de archivos disjuntos. ↳ remediación: repartí esos archivos "
                         "a un solo nodo, o agregá una arista de orden en depends_on "
                         f"({left} → {right} o al revés)")
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


def cmd_dag_nodes(args: argparse.Namespace) -> int:
    """Los NODOS del DAG en orden topológico: `<id><TAB><repo><TAB><deps>`.

    Existe para que `dag-coalesce.sh` no vuelva a implementar el orden del DAG
    en awk. El coalesce hace cherry-pick de la rama de cada nodo sobre
    `task/<id>`, y ese orden TIENE que ser el del DAG: aplicar T3 antes que T1
    cuando T3 depende de T1 produce un conflicto que no existe en el trabajo,
    solo en el orden en que se lo aplicó. Con `--repo` se filtra al repo que se
    está coalesciendo (los nodos de otros repos tienen su propio árbol).

    La TERCERA columna (`depends_on` separado por comas, vacía si no hay) la
    agregó #162: `worktree-task.sh --node` tiene que saber si el nodo que está
    creando depende de otro para decidir de dónde nace su rama, y leer el
    dag.json por su cuenta sería un segundo lector del mismo artefacto, que es
    justo lo que `load_dag_nodes` existe para evitar. Es ADITIVA: el consumidor
    que ya había toma solo `$1`."""
    task_dir = Path(args.task_dir).resolve()
    dag_path = task_dir / "dag.json"
    if not dag_path.exists():
        fail("POLICY-DAG-008",
             f"no existe tasks/{task_dir.name}/dag.json: no hay nodos que ordenar")
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

    for node in sorted(nodes):
        visit(node)
    for node in order:
        if args.repo and repos[node] != args.repo:
            continue
        print(f"{node}\t{repos[node]}\t{','.join(nodes[node])}")
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
                 "repo ya no participa, sacalo del alcance con "
                 f"'harness-policy.py repos tasks/{task_dir.name} --remove "
                 "<repo> --actor <vos> --reason \"<por qué no participa>\"' (y "
                 "si además está en dag.json, regenerá el DAG y re-corré "
                 "validate-dag): un candidato que el plan descartó nunca va a "
                 "tener veredicto, y sin sacarlo la tarea no cierra jamás")
        pending = repos_pending_ship(task_dir)
        if pending:
            fail("POLICY-SHIP-004",
                 f"faltan repos por shippear: {', '.join(pending)}. ship.sh se corre "
                 "una vez por repo y exige phase=review: si avanzas ahora, esos repos "
                 "quedan sin camino (desde ship solo se va a deploy). Shippea cada uno "
                 "con scripts/ship.sh y recién entonces pide review → ship. Si "
                 "alguno ya no participa porque el plan lo descartó, sacalo con "
                 f"'harness-policy.py repos tasks/{task_dir.name} --remove <repo> "
                 "--actor <vos> --reason \"<por qué no participa>\"'")
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
                 "sobre el delta vigente. Y si el ship YA pasó (o sea que el "
                 "worktree que el scaffold exige no existe y la fase no vuelve "
                 "a review), el camino auditable es re-sellar el delta sobre el "
                 "veredicto del repo cuyo cambio ya es inmutable en la trunk: "
                 + reseal_delta_cmd(task_dir.name, "")
                 + ". Deja el hash viejo, el nuevo, quién y por qué en el "
                 "veredicto y en state.delta_reseals[]")
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
    # ── EL PRESUPUESTO SE MIDE SOLO, NO CUANDO EL MODELO SE ACUERDA ──────────
    # POLICY-BUDGET-002 existía y no frenaba nada: dependía de que alguien
    # corriera `record-cost` con un total de ccusage, y `record-cost` no tiene
    # UNA sola llamada desde código en todo el repo. `spent_usd` se quedaba en
    # 0.0 para siempre y el techo era decorativo. Medido: la mediana de una
    # sesión son $12.52 y el top 10% se lleva el 65.8% del gasto, o sea que lo
    # que falta no es un precio más bajo, es un disyuntor para la cola.
    #
    # La transición es el punto correcto: es rara (no está en el camino
    # caliente), es donde el gasto de una fase ya se consumó, y es lo único
    # que el orquestador NO puede saltear por olvido.
    #
    # Fail-OPEN ante ausencia de datos y fail-CLOSED ante datos malos: sin
    # transcripts no se puede afirmar nada y bloquear sería mentir al revés;
    # con transcripts fuera de banda se bloquea con el número delante.
    proc = cost_check(task_dir)
    if proc is not None and proc.returncode == 3:
        # CADA TÉRMINO CON SU SALIDA, y no una lista donde el lector elige mal.
        # Caso de campo: el mensaje ofrecía `budget --to` como la salida
        # auditable, el humano la corría, y la transición seguía en exit 3
        # porque el término que frenaba era COST-CACHE, que el presupuesto no
        # toca. Tres reportes distintos del mismo callejón (#90, #91, #93).
        salida = (
            "(3) si el gasto está justificado, subir el techo con "
            "`harness-policy.py budget tasks/<id> --to <n> --actor <quien> "
            "--reason \"<por qué>\"`, que queda en history[] y es auditable."
        )
        # QUÉ FRENA, no qué aparece impreso: la salida del check también nombra
        # los términos EXIMIDOS y los no medibles, y elegir la remediación por
        # substring mandaría a eximir algo que ya está eximido. El JSON se pide
        # solo en este camino (el gate ya se negó), así que no toca la latencia
        # de una transición sana. Si no se puede leer, se cae al texto.
        frenan: list = []
        detalle = cost_check(task_dir, as_json=True)
        if detalle is not None and (detalle.stdout or "").strip():
            try:
                data = json.loads(detalle.stdout.strip().splitlines()[-1])
                frenan = [(b.get("code"), b.get("agent"))
                          for b in data.get("breaches") or []]
            except Exception:
                frenan = []
        if not frenan:
            frenan = [(c, None) for c in ("COST-CACHE", "COST-CTX")
                      if c in (proc.stdout or "")]

        # ── UN TÉRMINO SE COBRA DONDE SU REMEDIACIÓN EXISTE ─────────────────
        # LA CURA ESTABA DETRÁS DEL SÍNTOMA. Esta transición ES la remediación
        # del contexto: escribe el marcador de relevo, el orquestador cierra su
        # turno y el vigilante levanta una sesión NUEVA con contexto limpio. Y
        # COST-CTX la frenaba para exigir un perdón por el contexto que la
        # transición está a punto de tirar.
        #
        # Cobrarlo acá no recupera un peso (ese contexto ya se gastó) y no
        # protege nada: lo único que el bloqueo evitaría, que la fase siguiente
        # corra sobre la sesión inflada, ya lo evita el relevo. Lo que producía
        # era ceremonia: un waive por fase, siempre concedido, porque con la
        # tarea verde y la plata gastada no existe otra respuesta correcta.
        # Medido en el propio repo: tareas con CUATRO cost-waives del mismo
        # COST-CTX, una por fase (ver write_handoff). Y cinco reportes de campo
        # dando vueltas por el mismo cuarto: #90, #91, #93 ("la salida que
        # ofrece no destraba"), #103 y #111 ("el perdón vence antes de
        # escribirse"), y el último con la tarea entera en verde y sin camino.
        #
        # Lo que NO se afloja: COST-BUDGET sigue frenando por dólares, que es el
        # término que protege la plata, y COST-CACHE sigue igual. Y si el relevo
        # no va a ocurrir (`relevo_efectivo` es fail-closed), este término
        # frena como siempre, porque ahí la sesión SÍ continúa con ese contexto.
        # No se calla nunca: se imprime y va al bus.
        if relevo_efectivo(task_dir, state, current, args.phase):
            exentos = [f for f in frenan
                       if f[0] == "COST-CTX" and f[1] == "orquestador"]
            if exentos:
                frenan = [f for f in frenan if f not in exentos]
                print(f"🔻 COST-CTX del orquestador NO frena esta transición: "
                      f"{current} → {args.phase} releva la sesión, así que el "
                      "contexto que el término mide está por descartarse. El "
                      "vigilante levanta una sesión nueva con contexto limpio.")
                emit_bus(task_dir, "decision",
                         "COST-CTX del orquestador no frenó: la transición "
                         f"{current} → {args.phase} releva la sesión")
        if not frenan:
            proc = None            # la transición sigue: no quedó nada frenando

    if proc is not None and proc.returncode == 3:
        codigos = {c for c, _ in frenan}
        if codigos & {"COST-CACHE", "COST-CTX"}:
            salida += (
                " OJO: `budget --to` solo mueve el término COST-BUDGET. Para "
                "COST-CACHE y COST-CTX la salida auditable es "
                "`harness-policy.py cost-waive tasks/<id> --band "
                "cache|ctx --agent <rol> --actor <quien> --reason \"<por qué>\"`: "
                "queda en history[] y cada cost-check lo declara. Esos dos "
                "términos se miden sobre la FASE EN CURSO (phase_since), así "
                "que lo que frena corrió en esta fase: un agente de una fase "
                "anterior ya no puede trabar la tarea para siempre (#95)."
            )
            # ── EL CASO DEL ORQUESTADOR VIVO, QUE ES EL MÁS FRECUENTE ───────
            # El texto anterior decía "de un agente que YA CERRÓ", y eso leía
            # AL REVÉS al operador cuyo orquestador está vivo: se deducía fuera
            # de las dos ramas contempladas (no puede recortar un arranque que
            # ya ocurrió, y no califica como "cerrado" para el waive) y
            # concluía, con razón, que no tenía camino. Pasó en campo con la
            # tarea entera en verde: levantó un bug en vez de correr UN comando.
            # El waive de `ctx` se ancla a la FASE justamente porque el
            # orquestador está vivo por definición cuando pide la transición
            # (#103), así que el camino existía y el mensaje lo escondía.
            if any(c == "COST-CTX" and a == "orquestador" for c, a in frenan):
                salida += (
                    " Y si el que arrastra el contexto es el ORQUESTADOR, que "
                    "está vivo por definición al pedir esta transición: el "
                    "waive es igual de válido y se ancla a la FASE, no a un "
                    "valor, para que no venza mientras su contexto sigue "
                    "creciendo (#103). El comando exacto es "
                    "`harness-policy.py cost-waive tasks/" + task_dir.name +
                    " --band ctx --agent orquestador --actor <quien> --reason "
                    "\"<por qué>\"`. Que esté frenando acá significa que esta "
                    "transición NO releva la sesión (vas a archive o deploy, el "
                    "carril es quick, o el vigilante está apagado): en una que "
                    "releva, este término no frena, porque el contexto se "
                    "descarta con la sesión."
                )
        fail("POLICY-BUDGET-005",
             (proc.stdout or "").strip() + "\n\n"
             "El gasto de esta tarea está fuera de banda y la transición se "
             "frena acá, no cuando alguien mire la factura. Salidas, en "
             "orden de preferencia: (1) recortar el contexto de arranque de "
             "los agentes (brief destilado en vez de punteros a documentos) "
             "y acotar la salida de comandos, que es de lo poco que el "
             "harness controla de los dos términos que dominan el costo; "
             "(2) partir la tarea; " + salida + " Para una emergencia de "
             "producción, `HARNESS_CTX_CEILING` y `HARNESS_CACHE_HIT_FLOOR` "
             "mueven los umbrales de la corrida, pero NO dejan rastro: son el "
             "último recurso, no el primero.")

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

    # La concesión humana que esta transición GASTA, si gasta alguna: la
    # escribe el bloque de review y la lee el history[] de más abajo.
    ronda_concedida = None
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
            # La regla del límite vive en UN solo lugar y los dos lados la
            # consultan: acá para decidir el corte, y en validate-ship para
            # comprobar el techo. Reimplementarla fue el #182 (una ronda
            # concedida por convergencia que después no se podía shippear).
            # Se llama DESPUÉS de guardar la serie, porque la serie es su dato.
            _, hard, converging = limite_de_rondas(state, policy, args.repo)
            if this_repo > maximum:
                # QUÉ rebotaría esta ronda, si es que algo la rebota. Se
                # calcula ANTES de resolver, porque la concesión humana es la
                # respuesta al motivo del rechazo y el mensaje lo tiene que
                # nombrar: un "escala a humano" sin el motivo delante manda a
                # escalar a ciegas.
                motivo = None
                if this_repo > hard:
                    motivo = (
                        f"review round {this_repo} del repo {args.repo} excede el "
                        f"techo duro {hard} (2× el máximo {maximum}). Aunque los "
                        "bloqueantes vengan bajando, esta cantidad de rondas ya no "
                        "es convergencia sino goteo: escala a humano con el "
                        "historial de veredictos (los otros repos de la tarea no "
                        "se ven afectados)")
                elif not converging:
                    traza = (f"{seen[-2]} → {seen[-1]}" if len(seen) >= 2
                             else "sin serie legible de bloqueantes en los veredictos")
                    motivo = (
                        f"review round {this_repo} del repo {args.repo} excede el "
                        f"máximo {maximum} y NO bajó bloqueantes ({traza}). Ese repo "
                        "no converge: escala a humano con el historial de veredictos "
                        "(los otros repos de la tarea no se ven afectados)")
                if motivo is not None:
                    # ── LA ESCALADA TIENE COMANDO, Y ES ESTE ────────────────
                    ronda_concedida = consumir_ronda_concedida(
                        state, args.repo, this_repo)
                    if ronda_concedida is None:
                        fail("POLICY-LIMIT-001",
                             motivo + ". Si ese humano ya miró y decide pagar UNA "
                             "ronda más, la concede con rastro: "
                             + grant_round_cmd(task_dir.name, args.repo)
                             + " (queda en history[] y en state.round_grants[], "
                             "vale por UNA sola ronda y sube el techo del ship en "
                             "exactamente 1). Si no la concede, la salida es "
                             "cerrar el repo con lo que hay o partir la tarea")
                    aviso = (f"ronda extra {this_repo} de {args.repo} CONCEDIDA por "
                             f"{ronda_concedida.get('actor', '?')}: "
                             f"{ronda_concedida.get('reason', '')} "
                             f"(máximo {maximum}, techo duro {hard})")
                    print(f"🎟️  {aviso}")
                    emit_bus(task_dir, "decision", aviso)
                else:
                    # Sobrevivir al rechazo de arriba ES la decisión: la
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
                ronda_concedida = consumir_ronda_concedida(state, "", rounds)
                if ronda_concedida is None:
                    fail("POLICY-LIMIT-001",
                         f"review round {rounds} excede el máximo {maximum}. Si es una "
                         "tarea multi-repo, pasá --repo <repo> para que el presupuesto "
                         "se cuente por repo y no castigue a los que sí convergieron. "
                         "Y si un humano ya miró el historial de veredictos y decide "
                         "pagar UNA ronda más, la concede con rastro: "
                         + grant_round_cmd(task_dir.name, "")
                         + " (vale por UNA sola ronda, queda en history[] y sube el "
                         "techo del ship en exactamente 1)")
                aviso = (f"ronda extra {rounds} de la tarea CONCEDIDA por "
                         f"{ronda_concedida.get('actor', '?')}: "
                         f"{ronda_concedida.get('reason', '')} (máximo {maximum})")
                print(f"🎟️  {aviso}")
                emit_bus(task_dir, "decision", aviso)
            budget_warning(rounds, maximum, "")
    history = state.setdefault("history", [])
    entry = {"from": current, "to": args.phase, "actor": args.actor}
    if args.repo:
        entry["repo"] = args.repo
    if ronda_concedida is not None:
        # Quién autorizó esta ronda queda en el MOVIMIENTO, no solo en la
        # concesión: el history[] es lo que se lee para reconstruir la tarea.
        entry["round_grant"] = {"actor": ronda_concedida.get("actor"),
                                "reason": ronda_concedida.get("reason")}
    history.append(entry)
    set_phase(state, args.phase)
    state["review_rounds"] = rounds
    if rounds_by_repo:
        state["review_rounds_by_repo"] = rounds_by_repo
    # ── QUIÉN MANEJÓ ESTA FASE, escrito donde se pueda auditar ───────────
    # Sin esto, "el orquestador arrastró una sesión por toda la tarea" solo se
    # puede ver leyendo transcripts a posteriori. Con el id estampado en cada
    # cambio de fase, dos fases seguidas con el MISMO id son la prueba de que
    # el relevo no ocurrió, y se ve en el propio state.json.
    sid = current_session(task_dir)
    if sid:
        state["session_id"] = sid
    atomic(path, state)
    # El relevo se pide solo cuando la fase de verdad AVANZA. Un `review →
    # review` de otro repo es la misma fase, y `archive` no tiene fase
    # siguiente a la que relevar. `quick` queda afuera a propósito: es un
    # carril de UNA sesión corta de punta a punta, y relevarlo por fase sería
    # pagar arranques para ahorrar un contexto que nunca crece.
    #
    # Y `deploy` tampoco lo pide ACÁ, que es la parte contraintuitiva: la
    # espera del deploy son hasta 2820s por ship (Actions 1800 + ArgoCD 900 +
    # smoke 120) y relevar al entrar despertaría una sesión nueva para que se
    # siente a esperar, o sea el mismo tiempo con otro contexto cargado. El
    # relevo de deploy lo escribe `deploy-watch.sh` CUANDO TERMINA, que es un
    # proceso de bash a cero tokens: durante la espera no hay ninguna sesión
    # viva. Si el watcher muere sin escribirlo, la tarea cae en la regla de
    # silencio de bus de siempre.
    if fase_se_releva(state, current, args.phase):
        write_handoff(task_dir, args.phase, sid)
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
    set_phase(state, destination)
    atomic(path, state)
    emit_bus(task_dir, "decision", f"rollback {current} → {destination}: {args.reason}")
    print(f"↩️  {task_dir.name}: rollback {current} → {destination} ({args.reason})")
    print(f"   review_rounds sin cambios ({state.get('review_rounds', 0)}): "
          "el rollback deshace, no cobra una ronda")
    return 0


def cmd_repos(args: argparse.Namespace) -> int:
    """Suma o quita repos de una tarea YA iniciada, registrando quién y por qué.

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
    puerta de atrás en un carril que prometió cero infra.

    POR QUÉ TAMBIÉN QUITA (issue #61): el alcance se declara ANTES de saber
    cuál sobrevive. `init` recibe los repos CANDIDATOS del intake, y el patrón
    que este harness recomienda, verificar-antes-de-planear, existe justamente
    para descartar candidatos: en el caso de campo el arquitecto descartó 48 de
    51 y el plan quedó en dos repos. Los otros tres no tenían nada que
    implementar, revisar ni shippear, así que nunca iban a tener veredicto ni
    entrada en el ledger, y `review → ship` (que los exige a todos) no podía
    prosperar NUNCA. La tarea quedaba trabada en review con el código ya en
    main y desplegado verde: contabilidad trabada, no trabajo pendiente. La
    única salida era editar state.json a mano, prohibido por AGENTS.md. O sea:
    el harness recomendaba un patrón y castigaba al que lo seguía.

    Quitar es MÁS peligroso que sumar (borra una obligación en vez de crearla),
    así que va fail-closed y solo alcanza al repo que no produjo NADA:
      · con veredicto sellado → no se quita: ese repo se revisó, y borrarlo del
        alcance borraría la prueba de que fue parte de la tarea.
      · con entrada en el ledger de ships → no se quita: ya shippeó.
      · nombrado en dag.json → no se quita: el DAG ES el plan, y sacarlo solo
        de state.repos no destraba nada (`repos_missing_verdict` lee las dos
        fuentes en unión). Si el plan lo descartó, el DAG no debería nombrarlo.
      · último repo de la tarea → no se quita: una tarea sin repos no es tarea.
    Lo que queda removible es exactamente el caso del issue: un candidato que
    el plan descartó antes de que nadie tocara una línea."""
    task_dir = Path(args.task_dir).resolve()
    path = state_path(task_dir)
    lock_state(task_dir)
    state = load(path, "estado")
    if not args.reason.strip():
        fail("POLICY-REPOS-001",
             "cambiar el alcance sin motivo es una edición a mano con otro "
             "nombre: pasá --reason con la evidencia que descubrió (o descartó) "
             "el repo")
    if not (args.add or args.remove):
        fail("POLICY-REPOS-004",
             "nada que hacer: pasá --add, --remove, o los dos")
    phase = state.get("phase")
    if phase in ("ship", "deploy", "archive"):
        fail("POLICY-REPOS-002",
             f"la tarea ya está en fase {phase}: un repo agregado acá nace sin "
             "review posible (desde ship no se vuelve a review por el grafo), y "
             "uno quitado acá ya no destraba nada porque review → ship ya pasó. "
             "Remediación: rollback a review con motivo y recién entonces "
             "cambiá el alcance, o abrí una tarea nueva para ese repo")
    current = state.get("repos")
    current = [r for r in current if isinstance(r, str) and r] if isinstance(current, list) else []
    added = [r.strip() for r in (args.add or "").split(",") if r.strip()]
    added = [r for r in dict.fromkeys(added) if r not in current]
    asked_out = [r.strip() for r in (args.remove or "").split(",") if r.strip()]
    asked_out = list(dict.fromkeys(asked_out))
    removed = [r for r in asked_out if r in current or r in added]
    if not added and not removed:
        print(f"ℹ️  {task_dir.name}: sin cambios, el alcance ya es el pedido "
              f"({', '.join(current) or 'ninguno'})")
        return 0

    # ── Lo que ya produjo algo no se borra del alcance ────────────────
    if removed:
        planeados = repos_planned(task_dir)
        shipped = repos_shipped(task_dir)
        for repo in removed:
            if (task_dir / f"verdict-{repo}.json").exists():
                fail("POLICY-REPOS-005",
                     f"'{repo}' tiene veredicto sellado (tasks/{task_dir.name}/"
                     f"verdict-{repo}.json): se revisó, o sea que fue parte del "
                     "trabajo, y sacarlo del alcance borraría esa prueba. "
                     "Remediación: si el repo no debía participar, borrá su "
                     "veredicto a mano NO es opción: dejalo en el alcance y "
                     "documentá en el juicio por qué no shippeó")
            if repo in shipped:
                fail("POLICY-REPOS-005",
                     f"'{repo}' ya shippeó (aparece en tasks/{task_dir.name}/"
                     f"{SHIP_LEDGER}, o en el ship.log viejo): quitarlo del "
                     "alcance dejaría un cambio en main que ninguna tarea declara")
            if repo in planeados:
                fail("POLICY-REPOS-006",
                     f"'{repo}' está en tasks/{task_dir.name}/dag.json, que ES el "
                     "plan: sacarlo solo de state.repos no destraba nada, porque "
                     "el gate lee las dos fuentes en unión. Si el plan lo "
                     "descartó, el DAG no debería nombrarlo. Remediación: "
                     "regenerá el DAG sin ese repo (fase rfc) y validalo con "
                     f"'harness-policy.py validate-dag tasks/{task_dir.name}/dag.json'")

    combined = [r for r in current + added if r not in removed]
    if not combined:
        fail("POLICY-REPOS-007",
             "eso deja la tarea sin ningún repo, y una tarea sin repos no tiene "
             "nada que shippear. Remediación: cancelá la tarea en vez de "
             "vaciarla, o dejá al menos el repo donde vive el cambio")
    lane = state.get("lane", "full")
    vet_repos_for_lane(lane, combined, task_dir.parent.parent)
    # ── Un --add se valida contra manifest.yaml, igual que worktree-task.sh ──
    # Caso de campo (issue #62): `--add reponoexiste` se aceptaba y quedaba en
    # state.repos, pero worktree-task.sh ("repo desconocido", contra el clon
    # que el manifest manda tener) y verdict-scaffold.sh SÍ lo rechazaban: el
    # veredicto que POLICY-SHIP-004 exige era IMPOSIBLE de producir y la tarea
    # quedaba trabada en review → ship para siempre. Va DESPUÉS de
    # vet_repos_for_lane para que las promesas del carril (LANE-004/005) se
    # cobren con su propio código, y solo sobre `added`: un repo viejo ya
    # declarado no se re-juzga.
    if added:
        names = repo_names(task_dir.parent.parent)
        if names is None:
            # Degradar NO es aceptar en silencio: sin manifest no hay contra
            # qué validar (misma política fail-open que vet_repos_for_lane) y
            # el backstop sigue siendo worktree-task.sh al crear el worktree.
            print("⚠️  manifest.yaml ausente o ilegible en "
                  f"{task_dir.parent.parent}: --add NO se validó contra la "
                  "lista de repos; el backstop es worktree-task.sh, que "
                  "rechaza un repo no clonado", file=sys.stderr)
        else:
            unknown = [r for r in added if r not in names]
            if unknown:
                fail("POLICY-REPOS-008",
                     f"repo desconocido: {', '.join(unknown)} (ver "
                     "manifest.yaml). worktree-task.sh lo rechazaría al crear "
                     "el worktree y su veredicto sería imposible de producir: "
                     "la tarea quedaría trabada en review → ship "
                     "(POLICY-SHIP-004). Remediación: si el repo es real, "
                     "declaralo en manifest.yaml y clonalo bajo repos/ antes "
                     "de sumarlo a la tarea")
    state["repos"] = combined
    entry = {"kind": "repos", "actor": args.actor, "reason": args.reason}
    if added:
        entry["added"] = added
    if removed:
        entry["removed"] = removed
    state.setdefault("history", []).append(entry)
    atomic(path, state)
    cambio = []
    if added:
        cambio.append(f"+{', '.join(added)}")
    if removed:
        cambio.append(f"-{', '.join(removed)}")
    emit_bus(task_dir, "decision",
             f"alcance {' '.join(cambio)} ({args.reason})")
    print(f"✅ {task_dir.name}: repos {', '.join(combined)} ({' '.join(cambio)})")
    if added:
        print("   los sumados ahora exigen veredicto antes de review → ship "
              "(POLICY-SHIP-004)")
    if removed:
        print("   los quitados ya no lo exigen: la tarea puede cerrar sin ellos")
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


# ── LA RONDA QUE CONCEDE UN HUMANO ────────────────────────────────────
# POLICY-LIMIT-001 termina en "escala a humano" en sus tres bocas, y hasta acá
# ese humano no tenía NINGÚN comando con el que conceder la ronda: el CLI no
# exponía grant/waive-round/override de ninguna clase. O sea que el mensaje
# prescribía una acción que el propio harness no implementaba, y la tarea se
# quedaba en la fase sin camino legítimo (editar state.json a mano lo prohíbe
# AGENTS.md, y encima queda indistinguible de una edición no declarada).
#
# La concesión vive en `state.round_grants[]`, con el mismo patrón que
# `cost_waivers` (#90/#103/#122): quién, cuándo, por qué, y una entrada en
# history[] sin `to`, que phase_is_declared saltea porque no mueve la fase.
#
# LO QUE NO ES: un modo de apagar el techo.
#   · UNA concesión = UNA ronda. La consume la primera ronda que el techo
#     habría rebotado (queda `used_round` estampado) y no vuelve a servir.
#   · No se concede por adelantado: la tarea tiene que estar CONTRA el techo,
#     igual que un cost-waive se ancla a un valor ya medido.
#   · No se apilan: con una concesión sin usar, la siguiente se rechaza.
#   · Cada concesión sube el techo de `validate-ship` en exactamente 1, para
#     que no se repita el #182 (una ronda que el motor concedió y el ship
#     después rechazó).
def round_grants(state: dict) -> list:
    """Las concesiones de ronda del estado, ya filtradas de basura."""
    grants = state.get("round_grants")
    if not isinstance(grants, list):
        return []
    return [g for g in grants if isinstance(g, dict)]


def rondas_concedidas(state: dict, repo: "str | None" = None) -> int:
    """Cuántas rondas extra concedió un humano.

    El bucket es el repo, y `""` es el contador POR TAREA (el de una transición
    sin --repo). `repo=None` es la pregunta del ship, que mira la tarea entera:
    devuelve el máximo por bucket, porque `review_rounds` también es el MÁXIMO
    entre repos y sumar buckets le regalaría a un repo las rondas de otro."""
    grants = round_grants(state)
    if repo is not None:
        return sum(1 for g in grants if (g.get("repo") or "") == repo)
    counts = {}
    for g in grants:
        bucket = g.get("repo") or ""
        counts[bucket] = counts.get(bucket, 0) + 1
    return max(counts.values()) if counts else 0


def consumir_ronda_concedida(state: dict, repo: str, ronda: int):
    """Gasta la concesión pendiente del bucket, o devuelve None si no hay.

    Muta el dict DENTRO de state (round_grants devuelve las mismas referencias),
    así que el llamador solo tiene que persistir el estado."""
    for grant in round_grants(state):
        if (grant.get("repo") or "") != (repo or ""):
            continue
        if grant.get("used_round"):
            continue
        grant["used_round"] = ronda
        grant["used_at"] = utcnow()
        return grant
    return None


def grant_round_cmd(task_name: str, repo: str) -> str:
    """El comando EXACTO que destraba el techo, para pegarlo en el mensaje."""
    return ("scripts/harness-policy.py grant-round tasks/" + task_name
            + (f" --repo {repo}" if repo else "")
            + " --actor <quien-autoriza> --reason \"<por qué esta ronda más>\"")


def cmd_grant_round(args: argparse.Namespace) -> int:
    """Concede UNA ronda extra de review, con actor y motivo, en el estado.

    Es la otra mitad del "escala a humano" de POLICY-LIMIT-001: el mensaje
    ordenaba la escalada y no había comando con el que el humano contestara. El
    #182 cerró el brazo de la ronda concedida POR CONVERGENCIA (que validate-ship
    rechazaba); este cierra el brazo en que NO hay convergencia, que es
    justamente cuando el juicio humano es lo único que puede decidir.

    La concesión no mueve la fase ni cuenta la ronda: solo autoriza que la
    PRÓXIMA entrada a review de ese repo pase el techo una vez."""
    task_dir = Path(args.task_dir).resolve()
    policy = load(Path(args.policy), "policy")
    path = state_path(task_dir)
    if not (args.reason or "").strip():
        fail("POLICY-ROUND-001",
             "una ronda concedida sin motivo es un techo apagado con más pasos: "
             "--reason \"<por qué esta ronda más, y qué se espera de ella>\"")
    lock_state(task_dir)
    state = load(path, "estado")
    repo = (args.repo or "").strip()
    maximum, hard, converge = limite_de_rondas(state, policy, repo or None)
    rounds_by_repo = state.get("review_rounds_by_repo")
    if not isinstance(rounds_by_repo, dict):
        rounds_by_repo = {}
    if repo:
        llevadas = rounds_by_repo.get(repo)
        llevadas = llevadas if isinstance(llevadas, int) else 0
    else:
        llevadas = state.get("review_rounds")
        llevadas = llevadas if isinstance(llevadas, int) else 0
    # No se concede por adelantado, por el mismo motivo que un cost-waive se
    # ancla al valor medido: una tarea que todavía no llegó al techo no tiene
    # nada que conceder, y el permiso guardado sería un cheque en blanco que
    # nadie revisa cuando por fin se cobra.
    if llevadas < maximum:
        donde = f"del repo {repo}" if repo else "de la tarea"
        detalle = (", ".join(f"{r}={n}" for r, n in sorted(rounds_by_repo.items()))
                   or f"review_rounds={llevadas}")
        fail("POLICY-ROUND-002",
             f"las rondas {donde} van en {llevadas} y el máximo es {maximum}: "
             "todavía no hay techo que conceder, y una concesión guardada de "
             "antemano es un cheque en blanco. Pedí la ronda por el camino "
             "normal ('harness-policy.py transition tasks/" + task_dir.name +
             (f" review --repo {repo}" if repo else " review") +
             " --actor <quien>') y volvé acá SOLO si POLICY-LIMIT-001 la "
             f"rebota. Rondas contadas: {detalle}")
    pendiente = next((g for g in round_grants(state)
                      if (g.get("repo") or "") == repo and not g.get("used_round")),
                     None)
    if pendiente is not None:
        fail("POLICY-ROUND-003",
             f"ya hay una ronda concedida SIN USAR para "
             f"{repo or 'la tarea'} (la autorizó {pendiente.get('actor', '?')} "
             f"el {pendiente.get('at', '?')}: {pendiente.get('reason', '')}). "
             "Una concesión es UNA ronda: gastá esa antes de pedir otra, "
             "porque dos concesiones vivas a la vez son un techo apagado")
    entry = {
        "repo": repo, "actor": args.actor, "reason": args.reason,
        "at": utcnow(), "round": llevadas + 1,
        "max_review_rounds": maximum, "hard_ceiling": hard,
        "converging": converge,
    }
    grants = round_grants(state)
    grants.append(entry)
    state["round_grants"] = grants
    # kind=round-grant: NO declara `to`, así que phase_is_declared no lo lee
    # como un movimiento de fase (misma familia que cost-waive, budget y repos).
    state.setdefault("history", []).append({
        "kind": "round-grant", "repo": repo, "round": entry["round"],
        "actor": args.actor, "reason": args.reason,
    })
    atomic(path, state)
    etiqueta = f"del repo {repo}" if repo else "de la tarea"
    emit_bus(task_dir, "decision",
             f"ronda {entry['round']} de review {etiqueta} concedida por "
             f"{args.actor}: {args.reason}")
    print(f"🎟️  {task_dir.name}: ronda {entry['round']} de review {etiqueta} "
          f"concedida (autoriza {args.actor}). Es UNA sola: la consume la "
          "próxima entrada a review que el techo habría rebotado, y queda en "
          "history[] con quién y por qué")
    return 0


def delta_hash(task_dir: Path) -> "str | None":
    """La identidad de contenido del delta-spec vigente, o None si no hay."""
    delta = task_dir / "delta-spec.md"
    if not delta.is_file():
        return None
    return hashlib.sha256(delta.read_bytes()).hexdigest()


def reseal_delta_cmd(task_name: str, repo: str) -> str:
    """El comando EXACTO del re-sello, para pegarlo en el mensaje del gate."""
    return ("scripts/harness-policy.py reseal-delta tasks/" + task_name
            + f" --repo {repo or '<repo>'} --actor <quien-autoriza> "
              "--reason \"<por qué el delta vigente es el correcto>\"")


def cmd_reseal_delta(args: argparse.Namespace) -> int:
    """Re-emite el sello del delta sobre un veredicto ya shippeado, con rastro.

    POR QUÉ EXISTE: editar tasks/<id>/delta-spec.md entre el veredicto y el ship
    dejaba la tarea TRABADA de forma terminal, y no en un caso raro: escribir el
    requirement de un blocking tardío es exactamente lo que el flujo pide. Las
    tres salidas están cerradas por construcción una vez que el ship pasó:
      · archive lo rechaza (POLICY-ARCHIVE-001: el hash del delta no es el que
        ningún verdict declara haber revisado);
      · deploy → review no existe en el carril (POLICY-TRANSITION-001);
      · el re-scaffold del veredicto exige un worktree que el propio ship borró,
        y recrearlo nace en la trunk, o sea que invalida toda la evidencia.
    Resultado medido: el cambio en producción y verificado, y el ciclo SDD sin
    cerrar, o sea el delta que nunca se fusiona a la spec maestra.

    QUÉ HABILITA, Y NADA MÁS: re-sellar el delta VIGENTE sobre el veredicto de
    un repo cuyo cambio revisado ya es inmutable en la trunk. No re-abre el
    juicio, no toca `verdict`/`qa`, no mueve la fase.

    LOS TRES CANDADOS, que son lo que lo distingue de editar el delta sin rastro:
      · solo post-ship (fase deploy o archive): antes del ship el camino legítimo
        existe y es /review, que es juicio de verdad y no un sello;
      · solo con el repo aterrizado en la trunk según el ledger de ships: sin esa
        prueba, el cambio todavía se puede corregir por el camino normal;
      · el hash viejo, el nuevo, quién y por qué quedan en el veredicto Y en
        state.json (`delta_reseals[]` + history[]), así que la concesión es
        visible para cualquiera que audite la tarea después."""
    task_dir = Path(args.task_dir).resolve()
    path = state_path(task_dir)
    repo = (args.repo or "").strip()
    if not (args.reason or "").strip():
        fail("POLICY-RESEAL-001",
             "re-sellar sin motivo es editar el delta sin rastro con más pasos: "
             "--reason \"<qué cambió en el delta y por qué el veredicto sigue "
             "valiendo>\"")
    lock_state(task_dir)
    state = load(path, "estado")
    phase = state.get("phase")
    if phase not in ("deploy", "archive"):
        fail("POLICY-RESEAL-002",
             f"la tarea está en fase {phase!r} y el re-sello es SOLO post-ship "
             "(deploy o archive). Antes del ship el camino legítimo existe y es "
             "el juicio de verdad: corré /review del repo "
             "(scripts/verdict-scaffold.sh --rebase conserva lo que el delta no "
             "tocó), que re-emite el veredicto sobre el delta vigente. El "
             "re-sello solo existe para el estado en que ese camino está cerrado "
             "por construcción: el worktree ya no está y la fase no vuelve")
    verdict_path = task_dir / f"verdict-{repo}.json"
    if not repo or not verdict_path.is_file():
        disponibles = sorted(p.name[len("verdict-"):-len(".json")]
                             for p in task_dir.glob("verdict-*.json"))
        fail("POLICY-RESEAL-003",
             f"no hay tasks/{task_dir.name}/verdict-{repo or '<repo>'}.json que "
             "re-sellar: el sello vive EN el veredicto, así que sin veredicto no "
             "hay nada que re-emitir. Veredictos de esta tarea: "
             + (", ".join(disponibles) or "ninguno"))
    vigente = delta_hash(task_dir)
    if vigente is None:
        fail("POLICY-RESEAL-004",
             f"no existe tasks/{task_dir.name}/delta-spec.md: sin delta no hay "
             "sello que emitir, y sin delta POLICY-ARCHIVE-001 tampoco frena "
             "(no hay nada que fusionar a las specs maestras)")
    # ── EL CANDADO QUE SOSTIENE TODO: el cambio ya es inmutable en la trunk ──
    # El re-sello no re-juzga: acepta que el commit que el reviewer miró ya
    # aterrizó y no se puede volver a tocar. Si NO aterrizó, esa premisa es
    # falsa y el camino correcto sigue siendo el review de verdad.
    aterrizados = [e for e in ship_ledger(task_dir)
                   if e.get("repo") == repo and e.get("landed") is not False]
    if not aterrizados:
        fail("POLICY-RESEAL-005",
             f"'{repo}' no tiene un ship aterrizado en tasks/{task_dir.name}/"
             f"{SHIP_LEDGER} (ni en el ship.log viejo): el re-sello se apoya en "
             "que el commit revisado ya es INMUTABLE en la trunk, y sin esa "
             "prueba estaría blanqueando un delta que nadie revisó sobre un "
             "cambio que todavía se puede corregir. Si el PR sigue abierto, "
             "esperá el merge; si el repo no shippeó, corré /review")
    verdict = load(verdict_path, f"veredicto de {repo}")
    viejo = verdict.get("delta_spec_sha256")
    viejo = viejo if isinstance(viejo, str) else ""
    if viejo == vigente:
        print(f"✅ {task_dir.name}: el veredicto de {repo} ya sella el delta "
              f"vigente ({vigente[:12]}). Nada que hacer")
        return 0
    sello = {
        "from_sha256": viejo, "to_sha256": vigente, "actor": args.actor,
        "reason": args.reason, "at": utcnow(), "phase": phase,
        "landed_sha": aterrizados[-1].get("sha") or "",
    }
    reseals = verdict.get("delta_reseals")
    reseals = [r for r in reseals if isinstance(r, dict)] if isinstance(reseals, list) else []
    reseals.append(sello)
    verdict["delta_reseals"] = reseals
    verdict["delta_spec_sha256"] = vigente
    atomic(verdict_path, verdict)
    # El mismo hecho en el ESTADO, que es lo que se lee para reconstruir la
    # tarea. `kind` sin `to`: no mueve la fase y phase_is_declared lo saltea,
    # igual que cost-waive, budget, repos y round-grant.
    en_estado = state.get("delta_reseals")
    en_estado = [r for r in en_estado if isinstance(r, dict)] if isinstance(en_estado, list) else []
    en_estado.append(dict(sello, repo=repo))
    state["delta_reseals"] = en_estado
    state.setdefault("history", []).append({
        "kind": "delta-reseal", "repo": repo, "actor": args.actor,
        "reason": args.reason, "from_sha256": viejo, "to_sha256": vigente,
    })
    atomic(path, state)
    emit_bus(task_dir, "decision",
             f"delta-spec re-sellado sobre el veredicto de {repo} "
             f"({(viejo or 'sin sello')[:12]} → {vigente[:12]}, autoriza "
             f"{args.actor}): {args.reason}")
    print(f"🔏 {task_dir.name}: verdict-{repo}.json re-sella el delta vigente "
          f"({(viejo or 'sin sello previo')[:12]} → {vigente[:12]}, autoriza "
          f"{args.actor}). Queda en el veredicto y en state.delta_reseals[]; "
          "POLICY-ARCHIVE-001 ya no frena, y una edición POSTERIOR del delta "
          "vuelve a frenar como siempre")
    return 0


def limite_de_rondas(state: dict, policy: dict, repo: "str | None" = None):
    """El límite de rondas de review: (máximo, techo duro, ¿converge?).

    POR QUÉ EXISTE, y es todo el arreglo del #182: este número lo evaluaban DOS
    lugares con reglas distintas. `transition` conocía la excepción por
    convergencia y su techo duro (2× el máximo); `validate-ship` comparaba
    contra el máximo pelado. Consecuencia medida: una tarea cruzó a la ronda 5
    porque el propio motor se la CONCEDIÓ por convergencia (bloqueantes
    4 → 0 → 1 → 0, aviso al bus incluido), el reviewer firmó `pass` con cero
    requisitos sin cubrir, y el ship se negó con `POLICY-LIMIT-001`. O sea que
    el mecanismo que existe para premiar al que converge terminaba bloqueándolo:
    gastó una ronda que su propio harness autorizó y no pudo publicarla.

    La regla vive acá y nadie la reimplementa. Quien la consulta decide QUÉ
    hacer con ella (transition corta y explica por qué; validate-ship solo
    comprueba el techo efectivo), pero el número y la condición son uno solo.

    `repo=None` es la pregunta del ship, que mira la tarea entera: si ALGÚN
    repo tiene la serie que habilita la excepción, el techo efectivo de la tarea
    es el duro. Es la lectura correcta porque `review_rounds` es el MÁXIMO entre
    repos (lo dice su propio comentario en transition), así que ese máximo puede
    venir justo del repo al que se le concedió la ronda extra.

    Sin serie legible no hay convergencia y el corte es el de siempre: no poder
    mirar nunca habilita nada."""
    maximum = policy.get("limits", {}).get("max_review_rounds", 3)
    por_repo = state.get("review_blocking_by_repo")
    if not isinstance(por_repo, dict):
        por_repo = {}
    series = [por_repo.get(repo)] if repo is not None else list(por_repo.values())
    converge = False
    for seen in series:
        seen = [n for n in seen if isinstance(n, int)] if isinstance(seen, list) else []
        if len(seen) >= 2 and seen[-1] < seen[-2]:
            converge = True
            break
    return maximum, 2 * maximum, converge


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
    # ── EL MISMO LÍMITE QUE `transition`, PORQUE LA REGLA ES UNA (#182) ──
    # Y las rondas que un humano concedió con `grant-round` suben el techo acá
    # EXACTAMENTE lo que autorizaron (una por concesión). Es la misma lección
    # del #182 en su otro brazo: una ronda que el motor dejó pasar y el ship
    # después rechaza es una tarea trabada con el trabajo terminado.
    maximum, hard, converge = limite_de_rondas(state, policy)
    concedidas = rondas_concedidas(state)
    techo = (hard if converge else maximum) + concedidas
    rondas = state.get("review_rounds")
    if not isinstance(rondas, int):
        fail("POLICY-LIMIT-001",
             f"review_rounds no es un número ({rondas!r}): state.json está "
             "corrupto o editado a mano. Reconstruilo con "
             "'harness-policy.py rollback|transition', que deja registro")
    if rondas > techo:
        # El mensaje ANTERIOR era "review_rounds inválido o excedido", que no
        # decía el número, ni el techo, ni cuál de las dos cosas pasó, ni qué
        # hacer. Los mensajes de este repo son prompts (regla 5).
        extra = ("" if converge else
                 f". El techo se queda en {maximum} porque los bloqueantes de "
                 "esta tarea NO vienen bajando: sin esa serie no hay excepción "
                 "por convergencia que aplicar")
        if concedidas:
            extra += (f" (ya cuenta {concedidas} ronda(s) concedida(s) a mano "
                      "en state.round_grants[])")
        fail("POLICY-LIMIT-001",
             f"review_rounds={rondas} excede el techo {techo}{extra}. Un repo "
             "que no converge en esa cantidad de rondas necesita un humano, no "
             "otra vuelta: escalá con el historial de veredictos. Si ese humano "
             "ya miró y acepta la ronda de más, la concede con rastro y el "
             "techo sube en 1: "
             + grant_round_cmd(task_dir.name, "<repo>"))
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
                               help="cambia el alcance de una tarea ya iniciada "
                                    "(--add / --remove): init no se re-corre y "
                                    "editar state.json a mano está prohibido")
    repos_cmd.add_argument("task_dir")
    repos_cmd.add_argument("--add", default="",
                           help="repos a sumar, separados por coma")
    repos_cmd.add_argument("--remove", default="",
                           help="repos a quitar, separados por coma; solo los "
                                "que no produjeron nada (sin veredicto, sin "
                                "ship, fuera del dag)")
    repos_cmd.add_argument("--actor", required=True)
    repos_cmd.add_argument("--reason", required=True,
                           help="la evidencia que descubrió o descartó el repo")
    repos_cmd.set_defaults(func=cmd_repos)
    deliv = sub.add_parser("delivery",
                           help="promueve la entrega declarada de la tarea "
                                "(review → prs → trunk): el 'go' auditable")
    deliv.add_argument("task_dir")
    deliv.add_argument("--to", required=True)
    deliv.add_argument("--actor", required=True)
    deliv.add_argument("--reason", default="")
    deliv.set_defaults(func=cmd_delivery)
    budg = sub.add_parser("budget",
                          help="sube el techo de gasto de una tarea viva")
    budg.add_argument("task_dir")
    budg.add_argument("--to", type=float, required=True)
    budg.add_argument("--actor", required=True)
    budg.add_argument("--reason", default="")
    budg.set_defaults(func=cmd_budget)
    waive = sub.add_parser("cost-waive",
                           help="acepta un término de banda del costo "
                                "(cache|ctx) de un agente que ya cerró, con "
                                "actor y motivo, en history[]")
    waive.add_argument("task_dir")
    # Sin `choices`: la banda la valida cmd_cost_waive para poder CONTESTAR con
    # la remediación. Un `--band budget` rebotado por argparse dice "invalid
    # choice" y manda a leer el --help; POLICY-COST-001 dice que ese término se
    # autoriza con `budget --to`, que es lo que el humano vino a buscar.
    waive.add_argument("--band", required=True,
                       help="cache|ctx (el gasto en dólares se autoriza con "
                            "`budget --to`, no acá)")
    waive.add_argument("--agent", required=True,
                       help="el rol tal como lo nombra el cost-check "
                            "(orquestador, architect, implementer, qa...)")
    waive.add_argument("--actor", required=True)
    waive.add_argument("--reason", required=True)
    waive.set_defaults(func=cmd_cost_waive)
    grant = sub.add_parser("grant-round",
                           help="concede UNA ronda extra de review cuando "
                                "POLICY-LIMIT-001 manda escalar a humano: la "
                                "gasta la próxima entrada a review y queda en "
                                "history[] con actor y motivo")
    grant.add_argument("task_dir")
    grant.add_argument("--repo", default="",
                       help="repo cuya ronda se concede; sin él se concede "
                            "sobre el contador POR TAREA (el de una transición "
                            "sin --repo)")
    grant.add_argument("--actor", required=True)
    grant.add_argument("--reason", required=True,
                       help="qué miró el humano y qué espera de esta ronda")
    grant.set_defaults(func=cmd_grant_round)
    reseal = sub.add_parser("reseal-delta",
                            help="re-emite el sello del delta vigente sobre el "
                                 "veredicto de un repo YA aterrizado en la "
                                 "trunk (solo en deploy/archive): destraba "
                                 "POLICY-ARCHIVE-001 dejando rastro")
    reseal.add_argument("task_dir")
    reseal.add_argument("--repo", required=True,
                        help="repo cuyo veredicto re-sella el delta; su ship "
                             "tiene que estar aterrizado en el ledger")
    reseal.add_argument("--actor", required=True)
    reseal.add_argument("--reason", required=True,
                        help="qué cambió en el delta y por qué el veredicto "
                             "sigue valiendo sobre el cambio ya inmutable")
    reseal.set_defaults(func=cmd_reseal_delta)
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
    stale = sub.add_parser("stale",
                           help="tareas detenidas en una fase no terminal "
                                "(task<TAB>fase<TAB>minutos); exit 1 = hay alguna")
    stale.add_argument("tasks_root", nargs="?", default="tasks")
    stale.set_defaults(func=cmd_stale)
    cost = sub.add_parser("record-cost")
    cost.add_argument("task_dir")
    cost.add_argument("--total-usd", required=True, type=float)
    cost.set_defaults(func=cmd_record_cost)
    dag = sub.add_parser("validate-dag")
    dag.add_argument("dag")
    dag.set_defaults(func=cmd_validate_dag)
    dagn = sub.add_parser("dag-nodes",
                          help="nodos del DAG en orden topológico (id<TAB>repo)")
    dagn.add_argument("task_dir")
    dagn.add_argument("--repo", default="")
    dagn.set_defaults(func=cmd_dag_nodes)
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
