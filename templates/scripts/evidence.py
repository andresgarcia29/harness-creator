#!/usr/bin/env python3
"""Evidence v1: execute commands and bind their result to an exact Git commit.

Only this runner creates command evidence.  ``verify`` is deliberately
read-only and fail-closed so ship.sh can use it as a deterministic gate.
The implementation uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import uuid

SCHEMA = 1

# ── Contención: la máquina compartida es parte del resultado ──────────
# Caso de campo: once procesos de vitest en seis núcleos; la misma suite tardó
# 503s y salió roja bajo contención, 106s y verde en máquina libre. La
# evidencia contaminada se firmó como buena y nada distinguía un rojo real de
# un rojo por RAM. Medir acá y SELLAR la medición es lo que da esa
# distinción; build-slot.sh no puede medirla (es exec puro, sin padre).

_TEST_TOKENS = ("test", "spec", "pytest", "jest", "vitest", "rspec",
                "go test", "gradle", "mvn", "cargo")   # espejo de track-read.sh


def _cores() -> int:
    return os.cpu_count() or 1


def _load1() -> float:
    try:
        return os.getloadavg()[0]
    except (OSError, AttributeError):
        return -1.0     # plataforma sin loadavg: sin sello de contención


def _looks_like_test_cmd(cmd: str) -> bool:
    return any(tok in cmd for tok in _TEST_TOKENS)


def _ps_rows() -> list:
    try:
        out = subprocess.run(["ps", "-axo", "pid,ppid,command"], text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             check=False).stdout
    except OSError:
        return []
    rows = []
    for line in out.splitlines()[1:]:
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def _excluded_pids(rows, me: int) -> set:
    """El propio árbol (descendientes por ppid) MÁS los ancestros (mi sesión)."""
    children, parent = {}, {}
    for pid, ppid, _ in rows:
        children.setdefault(ppid, []).append(pid)
        parent[pid] = ppid
    excluded, stack = set(), [me]
    while stack:
        pid = stack.pop()
        if pid in excluded:
            continue
        excluded.add(pid)
        stack.extend(children.get(pid, []))
    pid = me
    while pid in parent and parent[pid] not in excluded and parent[pid] > 1:
        pid = parent[pid]
        excluded.add(pid)
    return excluded


def _foreign_test_procs(rows, excluded) -> int:
    return sum(1 for pid, _, cmd in rows
               if pid not in excluded and _looks_like_test_cmd(cmd))


def _suspect(foreign_peak: int, load_max: float, cores: int) -> bool:
    """Cada señal sola da falsos positivos (load alto en corridas sanas con
    make -j; procesos ajenos con máquina que da abasto). Juntas describen el
    régimen exacto donde los timeouts mienten."""
    return foreign_peak > 0 and load_max > float(cores)


def _test_slots(cores: int):
    """HARNESS_TEST_SLOTS > HARNESS_BUILD_SLOTS del usuario (se respeta: None)
    > default max(2, cores//3): los tests son más livianos que un docker build."""
    value = os.environ.get("HARNESS_TEST_SLOTS", "")
    if value.isdigit() and int(value) >= 1:
        return int(value)
    if os.environ.get("HARNESS_BUILD_SLOTS", "").isdigit():
        return None
    return max(2, cores // 3)


class ContentionSampler:
    """Muestrea cada 15s en un daemon-thread: solo inicio/fin pierde el caso
    de campo (el docker build ajeno que arranca a mitad de una suite de 10
    minutos). Fail-open total: la telemetría jamás tumba la corrida."""

    def __init__(self, interval: float = 15.0):
        self.interval = interval
        self.foreign_start = None
        self.foreign_peak = 0
        self.load_start = -1.0
        self.load_max = -1.0
        self.ok = False
        self._stop = threading.Event()
        self._thread = None

    def _sample(self) -> None:
        rows = _ps_rows()
        if not rows:
            return
        foreign = _foreign_test_procs(rows, _excluded_pids(rows, os.getpid()))
        load = _load1()
        if self.foreign_start is None:
            self.foreign_start = foreign
            self.load_start = load
        self.foreign_peak = max(self.foreign_peak, foreign)
        self.load_max = max(self.load_max, load)
        self.ok = self.ok or load >= 0.0

    def start(self) -> None:
        try:
            self._sample()
        except Exception:
            return

        def loop():
            while not self._stop.wait(self.interval):
                try:
                    self._sample()
                except Exception:
                    return

        self._thread = threading.Thread(target=loop, daemon=True)
        self._thread.start()

    def stop(self) -> dict:
        self._stop.set()
        try:
            self._sample()
        except Exception:
            pass
        if not self.ok or self.foreign_start is None:
            return {}    # ausencia honesta: sin ps o sin loadavg no se inventa
        cores = _cores()
        return {
            "cores": cores,
            "foreign_test_procs_start": self.foreign_start,
            "foreign_test_procs_peak": self.foreign_peak,
            "load_avg_start": round(self.load_start, 2),
            "load_avg_max": round(self.load_max, 2),
            "suspect": _suspect(self.foreign_peak, self.load_max, cores),
        }


def die(message: str, code: int = 2) -> "None":
    print(f"EVIDENCE: {message}", file=sys.stderr)
    raise SystemExit(code)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=cwd, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        die(f"git {' '.join(args)} falló: {result.stderr.strip()}")
    return result.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def contained(root: Path, candidate: Path) -> Path:
    root = root.resolve()
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        die(f"ruta fuera de la tarea: {candidate}")
    return resolved


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def log_executed_artifacts(task_dir: Path, cwd: Path, command: "list[str]",
                           evidence_id: str) -> None:
    """Apunta en evidence.log los artefactos que este comando EJECUTÓ.

    POR QUÉ EXISTE: `gate_evidence` de ship.sh intersecta lo CITADO por la
    compliance matrix con lo LEÍDO según `tasks/<id>/evidence.log`, y ese log
    lo alimentaba SOLO el hook track-read, o sea abrir el archivo con Read.
    Correr la prueba por acá no dejaba rastro, así que un reviewer que
    EJECUTABA el test y citaba su ruta quedaba rojo por no haberlo "leído".
    Pasó tres veces en la misma tarea, con tres reviewers distintos, pese a que
    el mensaje del gate ya hablaba de abrir el artefacto.

    Un gate que castiga la conducta MÁS fuerte (ejecutar) para premiar la más
    débil (leer) está midiendo lo que no quiso medir. El propio track-read ya
    lo dice en su código: "un test que CORRIÓ es la evidencia más fuerte que
    hay", y registra `ran-file` para los comandos que pasan por Bash. Esto le
    da la misma capacidad al camino sellado, que es el que el harness pide usar.

    NO afloja "citado no es verificado": solo se apuntan los tokens que
    resuelven a un archivo REAL, así que nada entra al log sin haberse
    ejecutado de verdad. Y es best-effort: un fallo acá no puede tumbar un
    sello que ya está en disco (mismo criterio fail-open que el hook)."""
    try:
        log = task_dir / "evidence.log"
        stamp = utc_now()
        seen: set = set()
        lines = []
        # Se parte por espacios además de por argumento: la ruta puede venir
        # dentro de un `sh -c "pytest tests/x.py"`, que llega como UN token.
        tokens = [piece for arg in command for piece in arg.split()]
        for token in tokens:
            if token.startswith("-") or "=" in token:
                continue          # flags y asignaciones no son artefactos
            base = token.split("::", 1)[0]
            if not base or base in seen:
                continue
            candidate = Path(base) if os.path.isabs(base) else (cwd / base)
            if not candidate.is_file():
                continue
            seen.add(base)
            lines.append(f"{stamp}\t{evidence_id}\tran-file\t{base}\n")
        if lines:
            task_dir.mkdir(parents=True, exist_ok=True)
            with open(log, "a", encoding="utf-8") as stream:
                stream.writelines(lines)
    except OSError:
        pass


TASK_DIR_MARKERS = ("task.md", "plan.md", "state.json")


def require_task_dir(task_dir: Path) -> None:
    """El task-dir se valida, JAMÁS se crea.

    Caso de campo: un --task-dir RELATIVO corrido desde el worktree creó
    ./<id>/evidence/ DENTRO del repo, un git add -A lo barrió y el árbol
    quedó limpio: todos los gates en verde con 147 líneas de vitest a punto
    de entrar a la raíz del repo. Lo encontró un reviewer leyendo git show,
    no un gate. Crear en silencio un directorio que parece válido es lo que
    convierte un error de ruta en un commit sucio."""
    if not task_dir.is_dir():
        die(f"task-dir inexistente: {task_dir}\n"
            "EVIDENCE: evidence.py no crea task-dirs (los crea worktree-task.sh).\n"
            f"  ↳ remediación: pasa la ruta absoluta real, normalmente "
            f"<workspace>/tasks/{task_dir.name}")
    if not (task_dir.parent.name == "tasks"
            or any((task_dir / m).is_file() for m in TASK_DIR_MARKERS)
            or (task_dir / "evidence").is_dir()):
        die(f"esto no parece un task-dir: {task_dir}\n"
            "EVIDENCE: sin task.md/plan.md/state.json/evidence/ y su padre no se "
            "llama tasks. Un sello en un directorio arbitrario acaba commiteado "
            "dentro de un repo.\n"
            "  ↳ remediación: usa <workspace>/tasks/<task-id> (lo crea "
            "scripts/worktree-task.sh)")


def change_id(cwd: Path) -> str:
    """Identidad del CAMBIO (scripts/change-id.sh), fail-open.

    Sin identidad (no hay origin/<base>, diff vacío, script ausente) el campo
    queda AUSENTE y verify exige SHA exacto: degradar jamás afloja el gate."""
    script = Path(__file__).resolve().parent / "change-id.sh"
    if not script.is_file():
        return ""
    result = subprocess.run(
        ["bash", str(script), str(cwd)], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    return result.stdout.strip() if result.returncode == 0 else ""


def command_run(args: argparse.Namespace) -> int:
    cwd = Path(args.cwd).resolve()
    task_dir = Path(args.task_dir).resolve()
    if not cwd.is_dir():
        die(f"cwd inexistente: {cwd}")
    require_task_dir(task_dir)
    before = git(cwd, "rev-parse", "HEAD")

    # EL ÁRBOL TIENE QUE ESTAR LIMPIO, Y ESTO NO ES CEREMONIA.
    #
    # Todo el contrato de la evidencia es "este resultado pertenece a ESTE
    # commit". `before == after` solo prueba que HEAD no se movió mientras
    # corría; NO prueba que lo que corrió sea lo que está commiteado. Con
    # cambios sin commitear, el sello dice "commit P" y lo que se probó fue
    # P más el working tree, que es otra cosa.
    #
    # Caso de campo, tres rondas perdidas por la misma causa: el implementer
    # corrió evidence.py ANTES de commitear, así que selló contra el commit
    # padre; al commitear, HEAD se movió y la evidencia quedó stale. Esa es la
    # variante barata. La cara es la otra: si NADIE commitea después, el
    # scaffold acepta esa evidencia como válida y queda certificando un commit
    # cuyo código no es el que se ejecutó. Un sello que miente sobre qué probó
    # es peor que no tener sello.
    #
    # Se miran los archivos VERSIONADOS (-uno): los sin trackear no cambian lo
    # que el commit contiene, y refusar por un artefacto de build sería
    # inservible. Si los hay, se avisan y quedan anotados en el manifiesto.
    tracked_dirty = git(cwd, "status", "--porcelain", "-uno")
    if tracked_dirty:
        print("EVIDENCE: el árbol tiene cambios SIN COMMITEAR:", file=sys.stderr)
        for line in tracked_dirty.splitlines()[:10]:
            print(f"  {line}", file=sys.stderr)
        print(
            "\nNo puedo sellar esto contra un commit: lo que se ejecutaría es el\n"
            "commit MÁS estos cambios, y el sello diría solo el commit. La\n"
            "evidencia quedaría certificando código que no es el que corrió.\n"
            "  ↳ remediación: commitea primero (con el trailer Task: <id>) y\n"
            "    corre esto DESPUÉS, sobre el árbol limpio.",
            file=sys.stderr)
        return 3
    untracked = git(cwd, "status", "--porcelain", "--untracked-files=normal")
    untracked_n = len([x for x in untracked.splitlines() if x.startswith("??")])
    if untracked_n:
        print(f"EVIDENCE: {untracked_n} archivo(s) sin trackear en el árbol; "
              "no bloquean, pero quedan anotados en el manifiesto.", file=sys.stderr)

    # Identidad de CONTENIDO del cambio, la misma que el veredicto (caso de
    # campo: 8-9 vueltas del ciclo re-sellar/re-scaffold/re-review porque el
    # veredicto sobrevivía al rebase por patch_id y la evidencia no).
    patch_id = change_id(cwd)
    if not patch_id:
        print("EVIDENCE: sin patch_id (no pude identificar el cambio): esta "
              "evidencia solo valdrá por SHA exacto si el trunk se mueve.",
              file=sys.stderr)

    evidence_id = f"EV-{args.kind.upper()}-{uuid.uuid4().hex[:12]}"
    evidence_dir = task_dir / "evidence"
    evidence_dir.mkdir(parents=True, exist_ok=True)
    log_path = evidence_dir / f"{evidence_id}.log"
    started = utc_now()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        die("falta el comando después de --")
    # El comando que PIDIÓ el usuario, antes de que el semáforo lo envuelva:
    # es el que nombra los artefactos, y el wrapper solo nombraría build-slot.
    user_command = list(command)

    # ── Semáforo: la suite toma un slot del MISMO pool que los builds ────
    # Caso de campo: once vitest en seis núcleos (503s y rojo vs 106s y verde
    # en máquina libre). El pool es el de build-slot a propósito: dos pools
    # sumarían presupuestos y la máquina se funde igual. La cadena no
    # re-lockea: build-slot exporta HARNESS_BUILD_SLOT_HELD=1 al hijo, y un
    # docker build interior hace exec directo.
    build_slot = Path(__file__).resolve().parent / "build-slot.sh"
    child_env = os.environ.copy()
    slot_wrapped = False
    test_slots = None
    if (not getattr(args, "no_slot", False) and build_slot.is_file()
            and os.environ.get("HARNESS_BUILD_SLOT_HELD") != "1"):
        test_slots = _test_slots(_cores())
        if test_slots is not None:
            child_env["HARNESS_BUILD_SLOTS"] = str(test_slots)
        command = ["bash", str(build_slot), *command]
        slot_wrapped = True

    sampler = ContentionSampler()
    sampler.start()
    with log_path.open("wb") as log:
        process = subprocess.Popen(
            command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=child_env,
        )
        assert process.stdout is not None
        for chunk in iter(lambda: process.stdout.read(8192), b""):
            log.write(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        return_code = process.wait()
        log.flush()
        os.fsync(log.fileno())
    contention = sampler.stop()
    if contention:
        contention["test_slots"] = test_slots
        contention["slot_wrapped"] = slot_wrapped

    after = git(cwd, "rev-parse", "HEAD")

    # ── ¿SE MOVIÓ EL ÁRBOL MIENTRAS CORRÍA? ──────────────────────────────
    # El chequeo de arriba mira el árbol ANTES de ejecutar, y eso deja abierta
    # la ventana que importa: un worktree lo comparten varios agentes.
    #
    # Caso de campo: el reviewer hizo verificación por mutación (editar src/
    # para comprobar que un test se pone rojo) sobre el MISMO árbol donde QA
    # estaba buildeando en paralelo. El build absorbió el archivo mutado, el
    # reviewer restauró, y para cuando se selló la evidencia el árbol volvía a
    # estar limpio: el sello certificaba un commit cuyo código no fue el que
    # corrió, y nada lo delataba. QA lo cazó por diligencia, no porque el
    # harness se lo dijera.
    #
    # Fail-CLOSED, como su hermano de antes de correr: o sella o no sella,
    # jamás degrada a un sello con asterisco. Un sello que miente sobre qué
    # probó es peor que no tener sello.
    dirty_after = git(cwd, "status", "--porcelain", "-uno")
    if dirty_after:
        print("EVIDENCE: el árbol se ENSUCIÓ mientras corría el comando:",
              file=sys.stderr)
        for line in dirty_after.splitlines()[:10]:
            print(f"  {line}", file=sys.stderr)
        print(
            "\nEstaba limpio al empezar, así que se movió DURANTE la corrida, y\n"
            "el sello diría 'commit P' sobre un árbol que ya no es P. No puedo\n"
            "saber cuál de las dos causas fue, así que van las dos con su\n"
            "remediación; los archivos de arriba te dicen cuál es la tuya:\n"
            "\n"
            "  (a) OTRO AGENTE comparte este worktree (caso de campo:\n"
            "      verificación por mutación del reviewer mientras QA medía\n"
            "      sobre el mismo árbol, y el build absorbió el archivo mutado).\n"
            "      ↳ re-corré cuando el árbol esté quieto. Quien necesite mutar\n"
            "        para probar algo, que use un árbol descartable:\n"
            "          git -C <worktree> worktree add --detach /tmp/sonda HEAD\n"
            "\n"
            "  (b) EL COMANDO MISMO reescribe archivos versionados: goldens o\n"
            "      snapshots que se auto-actualizan, go.sum, un lockfile. Eso es\n"
            "      legítimo, pero el resultado pertenece al árbol de DESPUÉS.\n"
            "      ↳ commitea lo que regeneró (con el trailer Task:) y re-corré\n"
            "        sobre el árbol limpio, o corré el comando en modo que no\n"
            "        reescriba (por ejemplo el flag de verificación del runner,\n"
            "        no el de actualización).",
            file=sys.stderr)
        return 3

    manifest = {
        "schema": SCHEMA,
        "id": evidence_id,
        "task_id": task_dir.name,
        "repo": args.repo,
        "kind": args.kind,
        "runner": args.runner,
        "commit": before,
        "commit_after": after,
        "command": command,
        "cwd": str(cwd),
        "started_at": started,
        "finished_at": utc_now(),
        "exit_code": return_code,
        # Informativo, NO parte de lo que verify exige: sumarlo al contrato
        # invalidaría de golpe toda la evidencia ya emitida. Sirve para que un
        # humano o un reviewer vean en qué condiciones se selló.
        "tree_clean": True,
        "untracked_files": untracked_n,
        "output": f"evidence/{evidence_id}.log",
        "output_sha256": sha256(log_path),
    }
    if patch_id:
        manifest["patch_id"] = patch_id
    if contention:
        manifest["contention"] = contention
    atomic_json(evidence_dir / f"{evidence_id}.json", manifest)
    log_executed_artifacts(task_dir, cwd, user_command, evidence_id)
    # Un sello que no va a servir se anuncia AHORA, no dos gates después.
    # Caso de campo: se selló evidencia con exit_code=1 y log vacío; verify la
    # rechazó recién en el ship, con un mensaje que hablaba de otra cosa.
    if return_code != 0:
        print(f"EVIDENCE: ojo: el comando salió con exit {return_code}. El sello "
              "queda en disco, pero verify exige exit_code 0: un veredicto que "
              "cite este ID va a rebotar en el ship. Corré el comando en verde "
              "y sellá de nuevo.", file=sys.stderr)
        if contention.get("suspect"):
            print(f"EVIDENCE: y ojo doble: el rojo pudo ser CONTENCIÓN, no el código "
                  f"({contention.get('foreign_test_procs_peak')} procesos de test "
                  f"ajenos, load {contention.get('load_avg_max')} con "
                  f"{contention.get('cores')} cores). Re-corre con "
                  "HARNESS_TEST_SLOTS=1 antes de diagnosticar nada.",
                  file=sys.stderr)
    try:
        if log_path.stat().st_size == 0:
            print("EVIDENCE: ojo: el comando no produjo NI UNA línea de salida. "
                  "Un log vacío suele ser una suite que no corrió nada; como "
                  "evidencia no prueba gran cosa y un reviewer lo va a rechazar.",
                  file=sys.stderr)
    except OSError:
        pass
    # La decisión de publicabilidad va ANTES del anuncio. Caso de campo:
    # cuatro agentes distintos parsearon un EVIDENCE_ID que dos líneas más
    # abajo se declaraba no publicable, y el fallo aparecía recién en el
    # ship. Un ID solo se anuncia como EVIDENCE_ID si el sello vale; si no,
    # sale como EVIDENCE_DISCARDED y ningún parser de stdout se lo lleva.
    if before != after:
        print(f"\nEVIDENCE_DISCARDED={evidence_id}")
        print("EVIDENCE: el comando cambió HEAD; la evidencia no es publicable", file=sys.stderr)
        return 3
    print(f"\nEVIDENCE_ID={evidence_id}")
    return return_code


def load_json(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"{label} inválido ({path}): {exc}", 3)
    if not isinstance(value, dict):
        die(f"{label} debe ser un objeto JSON: {path}", 3)
    return value


def verify_one(task_dir: Path, evidence_id: str, repo: str, commit: str,
               verdict_patch_id: "str | None" = None) -> dict:
    if not evidence_id.startswith("EV-") or "/" in evidence_id or ".." in evidence_id:
        die(f"ID de evidencia inválido: {evidence_id}", 3)
    manifest_path = contained(task_dir, task_dir / "evidence" / f"{evidence_id}.json")
    data = load_json(manifest_path, "manifiesto de evidencia")
    expected = {
        "schema": SCHEMA, "id": evidence_id, "task_id": task_dir.name,
        "repo": repo, "exit_code": 0,
    }
    for field, wanted in expected.items():
        if data.get(field) != wanted:
            die(f"{evidence_id}: {field}={data.get(field)!r}; se esperaba {wanted!r}", 3)
    ev_commit = data.get("commit")
    if data.get("commit_after") != ev_commit:
        die(f"{evidence_id}: commit_after={data.get('commit_after')!r}; se esperaba "
            f"{ev_commit!r} (HEAD se movió durante la corrida)", 3)
    if ev_commit != commit:
        # La evidencia citada sobrevive al rebase por IDENTIDAD DE CONTENIDO,
        # igual que el veredicto que la cita (caso de campo: "veredicto
        # reusado" convivía con "evidencia rechazada" por los mismos SHAs, y
        # cada vuelta costaba suite + scaffold + reviewer nuevo). Lo que ESTA
        # equivalencia jamás cubre (que el árbol integrado funcione) lo cubre
        # la evidencia FRESCA, que sigue siendo SHA-estricta.
        ev_pid = data.get("patch_id")
        if isinstance(verdict_patch_id, str) and verdict_patch_id \
                and isinstance(ev_pid, str) and ev_pid == verdict_patch_id:
            print(f"↻ reuso: {evidence_id} se selló sobre {str(ev_commit)[:12]} y el "
                  f"veredicto declara {commit[:12]}, pero es el MISMO cambio "
                  f"(patch_id {ev_pid[:12]}): se acepta")
        elif not ev_pid:
            die(f"{evidence_id}: commit={ev_commit!r}; se esperaba {commit!r}. "
                "El manifiesto no lleva patch_id (evidencia de una versión vieja "
                "de evidence.py): re-sella sobre el commit revisado con "
                "evidence.py run", 3)
        else:
            die(f"{evidence_id}: commit={ev_commit!r}; se esperaba {commit!r}, y su "
                f"patch_id ({str(ev_pid)[:12]}) tampoco es el del veredicto: la "
                "evidencia prueba OTRO cambio. Re-corre la prueba sobre el HEAD "
                "actual y después scripts/verdict-scaffold.sh --rebase y /review", 3)
    if not isinstance(data.get("runner"), str) or not data["runner"].strip():
        die(f"{evidence_id}: runner vacío", 3)
    contention = data.get("contention")
    if isinstance(contention, dict) and contention.get("suspect") is True:
        die(f"{evidence_id}: sellada bajo contención (suspect: "
            f"{contention.get('foreign_test_procs_peak')} procesos de test ajenos, "
            f"load {contention.get('load_avg_max')} con {contention.get('cores')} "
            "cores). Un resultado bajo esa carga no prueba nada: re-corre con "
            "menos contención (HARNESS_TEST_SLOTS=N) y sella de nuevo.", 3)
    output = data.get("output")
    if not isinstance(output, str) or not output:
        die(f"{evidence_id}: output inválido", 3)
    output_path = contained(task_dir, task_dir / output)
    if not output_path.is_file():
        die(f"{evidence_id}: output inexistente: {output}", 3)
    if sha256(output_path) != data.get("output_sha256"):
        die(f"{evidence_id}: SHA-256 del output no coincide", 3)
    return data


def fresh_evidence(task_dir: Path, repo: str, commit: str) -> list:
    """Evidencia del task_dir sellada contra ``commit``, sin pasar por el veredicto.

    POR QUÉ NO SE PIDE QUE ESTÉ EN ``verdict.evidence[]``: el veredicto es
    inmutable después del review, así que no puede citar una evidencia que se
    produce DESPUÉS, en el ship, sobre el árbol ya integrado con el trunk
    nuevo.  Son dos afirmaciones distintas y el contrato las tenía confundidas
    en una sola:

      · evidencia REVISADA  → "el reviewer juzgó con pruebas reales de lo que
        juzgó".  Se valida contra el commit que el veredicto declara.
      · evidencia FRESCA    → "el árbol que se pushea pasó la suite".  Se valida
        contra el HEAD que va a aterrizar, y la produce ship.sh.

    Confundirlas obligaba a re-revisar (juicio de LLM, minutos) cada vez que se
    movía el trunk, cuando lo único que hacía falta era re-correr los tests
    (determinista, gratis en tokens).

    Devuelve (found, suspect_kinds): los kinds que EXISTEN pero solo sellados
    bajo contención, para que el mensaje del gap diga la causa real."""
    found = []
    suspect_kinds = set()
    evidence_dir = task_dir / "evidence"
    if not evidence_dir.is_dir():
        return found, suspect_kinds
    for path in sorted(evidence_dir.glob("EV-*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue          # un manifiesto ilegible no cuenta como prueba
        if not isinstance(data, dict):
            continue
        if data.get("id") != path.stem:
            continue          # id falsificado: fuera (mismo criterio que el scaffold)
        checks = {
            "schema": SCHEMA, "task_id": task_dir.name, "repo": repo,
            "commit": commit, "commit_after": commit, "exit_code": 0,
        }
        if any(data.get(field) != wanted for field, wanted in checks.items()):
            continue
        if not isinstance(data.get("runner"), str) or not data["runner"].strip():
            continue
        output = data.get("output")
        if not isinstance(output, str) or not output:
            continue
        try:
            output_path = contained(task_dir, task_dir / output)
        except SystemExit:
            continue
        if not output_path.is_file() or sha256(output_path) != data.get("output_sha256"):
            continue          # el log no respalda al manifiesto
        contention = data.get("contention")
        if isinstance(contention, dict) and contention.get("suspect") is True:
            suspect_kinds.add(data.get("kind"))
            continue          # sellada bajo contención: no prueba nada
        found.append(data)
    return found, suspect_kinds


def command_verify(args: argparse.Namespace) -> int:
    task_dir = Path(args.task_dir).resolve()
    verdict = load_json(Path(args.verdict), "veredicto")
    # Sin --reviewed-commit el comportamiento es el histórico: la evidencia
    # revisada tiene que ser del mismo commit que se pushea.
    reviewed = args.reviewed_commit or args.commit
    if verdict.get("schema") != SCHEMA:
        die("el veredicto debe declarar schema: 1", 3)
    if verdict.get("task_id") != task_dir.name:
        die("task_id del veredicto no coincide", 3)
    if verdict.get("repo") != args.repo:
        die("repo del veredicto no coincide", 3)
    if verdict.get("commit") != reviewed:
        die(f"el veredicto pertenece a otro commit (declara {verdict.get('commit')!r}, "
            f"se esperaba {reviewed!r})", 3)
    evidence_ids = verdict.get("evidence")
    if not isinstance(evidence_ids, list) or not evidence_ids:
        die("el veredicto no referencia evidence[]", 3)
    # La identidad de contenido viaja en el PROPIO veredicto: cero flags
    # nuevos, cero oportunidad de que policy y evidence vean patch_ids
    # distintos del mismo archivo.
    verdict_pid = verdict.get("patch_id")
    if not isinstance(verdict_pid, str) or not verdict_pid:
        verdict_pid = None
    seen: set[str] = set()
    manifests = []
    for evidence_id in evidence_ids:
        if not isinstance(evidence_id, str) or evidence_id in seen:
            die("evidence[] contiene IDs inválidos o duplicados", 3)
        seen.add(evidence_id)
        manifests.append(verify_one(task_dir, evidence_id, args.repo, reviewed, verdict_pid))
    required = set(args.require_kind)
    present = {item.get("kind") for item in manifests}
    missing = sorted(required - present)
    if missing:
        die(f"faltan tipos de evidencia: {', '.join(missing)}", 3)

    # ── Evidencia FRESCA sobre el árbol que realmente se pushea ──────────
    # Solo se exige cuando el commit revisado NO es el que aterriza (o cuando
    # quien llama lo pide explícito).  Fail-closed: sin ella no se pushea.
    fresh_required = set(args.require_fresh_kind)
    if fresh_required:
        fresh, suspect_kinds = fresh_evidence(task_dir, args.repo, args.commit)
        fresh_kinds = {item.get("kind") for item in fresh}
        gaps = sorted(fresh_required - fresh_kinds)
        if gaps:
            tainted = sorted(set(gaps) & suspect_kinds)
            extra = ""
            if tainted:
                extra = (f" OJO: hay evidencia de {', '.join(tainted)} pero está "
                         "marcada suspect (se selló bajo contención): re-corre "
                         "con menos contención (HARNESS_TEST_SLOTS=N).")
            die(f"falta evidencia FRESCA sobre el árbol que se pushea "
                f"({args.repo}@{args.commit[:12]}): {', '.join(gaps)}. "
                "El veredicto se revisó sobre otro commit, así que la prueba de "
                "que ESTE árbol pasa la suite tiene que producirse ahora: "
                "evidence.py run --runner ship --kind test ... sobre el HEAD "
                f"actual.{extra}", 3)
        print(f"✅ evidencia fresca sobre {args.repo}@{args.commit[:12]}: "
              f"{', '.join(sorted(k for k in fresh_kinds if k in fresh_required))} "
              f"(runners: {', '.join(sorted({str(i.get('runner')) for i in fresh}))})")
    if reviewed != args.commit:
        print(f"✅ {len(manifests)} evidencias del review ligadas a {args.repo}@{reviewed[:12]} "
              f"(el árbol que se pushea es {args.commit[:12]})")
    else:
        print(f"✅ {len(manifests)} evidencias ligadas a {args.repo}@{args.commit[:12]}")
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="evidence v1")
    sub = root.add_subparsers(dest="action", required=True)
    run = sub.add_parser("run", help="ejecuta y registra un comando")
    run.add_argument("--task-dir", required=True)
    run.add_argument("--repo", required=True)
    run.add_argument("--runner", required=True)
    run.add_argument("--kind", required=True, choices=("test", "lint", "build", "security", "canary"))
    run.add_argument("--cwd", default=".")
    run.add_argument("--no-slot", action="store_true",
                     help="no envolver el comando en build-slot.sh (para "
                          "llamadores que ya gestionan el semáforo)")
    run.add_argument("command", nargs=argparse.REMAINDER)
    run.set_defaults(func=command_run)
    verify = sub.add_parser("verify", help="verifica evidencia citada por un veredicto")
    verify.add_argument("--task-dir", required=True)
    verify.add_argument("--repo", required=True)
    verify.add_argument("--commit", required=True,
                        help="el HEAD que se pushea (el árbol integrado)")
    verify.add_argument("--reviewed-commit", default=None,
                        help="el commit que el veredicto declara haber revisado; "
                             "si se omite, se exige que sea el mismo que --commit")
    verify.add_argument("--verdict", required=True)
    verify.add_argument("--require-kind", action="append", default=[],
                        help="tipos exigidos en la evidencia CITADA por el veredicto")
    verify.add_argument("--require-fresh-kind", action="append", default=[],
                        help="tipos exigidos sobre el HEAD que se pushea, "
                             "sin necesidad de estar citados en el veredicto")
    verify.set_defaults(func=command_verify)
    return root


if __name__ == "__main__":
    ns = parser().parse_args()
    raise SystemExit(ns.func(ns))
