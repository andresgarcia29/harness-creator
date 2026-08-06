#!/usr/bin/env python3
"""task-note.py: la nota que sobrevive a la tarea.

POR QUÉ EXISTE
--------------
Una tarea produce muchísimo: task.md, enrichment.md, el ledger de supuestos,
plan, delta-spec, veredictos con su compliance matrix, sellos de evidencia,
hallazgos, y `history[]` con quién autorizó qué. **Todo eso vive bajo `tasks/`,
que está gitignoreado**: muere con la máquina. El propio `.gitignore` lo dice
bien ("a la tarea se destila a docs/ en /archive: si no está en docs/, no
existe"), pero `/archive` llamaba `tasks/archive/` un AUDIT TRAIL, y un audit
trail que no se versiona es un caché local. Este script cierra esa contradicción.

Y resuelve el problema de equipo: con N ingenieros hay N máquinas, N carpetas
`tasks/` y cero aprendizaje compartido. El repo de la instancia ya está
versionado y lo clonan todos, así que ES el cerebro compartido: lo único que
faltaba era escribir ahí.

QUÉ GUARDA, Y QUÉ NO
--------------------
NO guarda el proceso. Una traza de razonamiento son cientos de miles de tokens
cuyo valor decae en días, y un archivo que nadie relee es un diario, no una
memoria. Lo que compone es la **sorpresa**: "esperábamos X, medimos Y, por eso
Z" se relee en un año.

Por eso la nota es corta a propósito y se divide en dos:
  · lo VERIFICABLE lo rellena este script desde artefactos que ya existen
    (cero tokens de modelo, misma ley que harness-metrics)
  · lo de JUICIO queda como placeholder para el orquestador, que en el momento
    de archivar todavía tiene el contexto en la cabeza

Es el mismo reparto que `verdict-scaffold.sh` hace con el veredicto, y por la
misma razón: un campo verificable que escribe el modelo es un campo que puede
mentir sin que nada lo note.

DÓNDE ATERRIZA
--------------
`docs/tareas/<id>.md`, versionado. Ese directorio es un vault de Obsidian sin
hacer nada: los `[[enlaces]]` dan el grafo, que contesta lo que ni el tracker ni
la memoria del agente contestan ("qué otras tareas tocaron este repo", "qué
tareas dependieron de este supuesto").

**Los agentes NO la leen por defecto.** Lo que un agente lee se paga en cada
tool call suyo; esta nota es para el humano, y para un agente que decide bajo
demanda que una tarea vieja es relevante.

Uso:
  task-note.py <task-id>              escribe docs/tareas/<id>.md
  task-note.py <task-id> --stdout     la imprime sin escribir (para mirarla)
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
WS = Path(os.environ.get("HARNESS_WS") or HERE.parent)

EXIT_OK, EXIT_USAGE, EXIT_NOTASK = 0, 2, 3

# Marcadores de juicio. Se eligieron VISIBLES y feos a propósito: una nota que
# se archiva con los placeholders puestos tiene que dar vergüenza al leerla, no
# pasar desapercibida.
TODO = "<!-- COMPLETAR: {} -->"


def read_text(p: Path) -> str:
    try:
        return p.read_text(errors="replace")
    except Exception:
        return ""


def read_json(p: Path):
    try:
        return json.loads(p.read_text())
    except Exception:
        return None


def redact(text: str) -> str:
    """La nota se versiona, así que la ley de secretos del bus aplica igual.

    No se delega a emit.sh para no depender de bash desde acá; los patrones son
    los mismos y hay un test que compara que no se queden atrás.
    """
    pats = [
        (r"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}", "[REDACTADO:gh]"),
        (r"(hvs|hvb)\.[A-Za-z0-9_-]{20,}", "[REDACTADO:vault]"),
        (r"sk-[A-Za-z0-9_-]{20,}", "[REDACTADO:key]"),
        (r"xox[baprs]-[A-Za-z0-9-]{10,}", "[REDACTADO:slack]"),
        (r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}",
         "[REDACTADO:jwt]"),
        (r"(AKIA|ASIA)[A-Z0-9]{12,}", "[REDACTADO:aws]"),
        (r"lin_api_[A-Za-z0-9]{20,}", "[REDACTADO:linear]"),
    ]
    for pat, rep in pats:
        text = re.sub(pat, rep, text)
    return text


def costo(task: str):
    """El costo real, ahora que se puede medir. Fail-open: sin báscula, sin dato."""
    tool = HERE / "harness-cost.py"
    if not tool.is_file():
        return None
    env = os.environ.copy()
    env.setdefault("HARNESS_WS", str(WS))
    try:
        r = subprocess.run([sys.executable, str(tool), "task", task],
                           capture_output=True, text=True, timeout=60, env=env)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    m = re.search(r"total\s+\$\s*([\d,]+\.\d\d)", r.stdout)
    return m.group(1) if m else None


def supuestos(task_dir: Path):
    """El ledger, separando los que se MIDIERON de los que se asumieron.

    Un supuesto que resultó falso es el material más valioso de una tarea: es
    justo lo que `/promote` convierte en regla para que el próximo /smart no lo
    repita. Por eso salen marcados y no mezclados con el resto.
    """
    out = []
    for line in read_text(task_dir / "assumptions.md").splitlines():
        s = line.strip()
        if not re.match(r"^[-*]\s*SUPUESTO", s):
            continue
        entorno = "SUPUESTO-ENTORNO" in s
        medido = bool(re.search(r"EV-[A-Za-z0-9-]+", s))
        texto = re.sub(r"^[-*]\s*", "", s)
        out.append({"texto": texto, "entorno": entorno, "medido": medido})
    return out


def decisiones(state: dict):
    """`history[]` es quién autorizó qué: la traza que no depende de la memoria."""
    out = []
    for h in (state.get("history") or []):
        kind = h.get("kind")
        if kind in ("phase", None):
            continue          # los movimientos de fase son ruido para la nota
        actor = h.get("actor") or "?"
        reason = h.get("reason") or ""
        detalle = h.get(kind) or h.get("delivery") or h.get("budget_usd") or ""
        out.append(f"`{kind}` {detalle} (autoriza {actor})"
                   + (f": {reason}" if reason else ""))
    return out


def veredictos(task_dir: Path):
    filas = []
    for p in sorted(task_dir.glob("verdict-*.json")):
        v = read_json(p) or {}
        repo = v.get("repo") or p.stem.replace("verdict-", "")
        blocking = v.get("blocking") or []
        tardios = sum(1 for b in blocking
                      if isinstance(b, str) and "[tardío]" in b)
        filas.append({
            "repo": repo,
            "verdict": v.get("verdict", "?"),
            "qa": v.get("qa", "?"),
            "blocking": len(blocking),
            "tardios": tardios,
            "uncovered": v.get("requirements_uncovered", "?"),
        })
    return filas


def hallazgos(task_dir: Path):
    out = []
    for line in read_text(task_dir / "findings.jsonl").splitlines():
        try:
            f = json.loads(line)
        except Exception:
            continue
        if f.get("text"):
            out.append(f"[{f.get('repo', '?')}] {f['text']}")
    return out


def build(task: str) -> str:
    task_dir = WS / "tasks" / task
    if not task_dir.is_dir():
        # Al archivar, los artefactos ya se movieron: se busca ahí también.
        cands = sorted((WS / "tasks" / "archive").glob(f"*{task}"))
        if cands:
            task_dir = cands[-1]
        else:
            print(f"task-note: no encuentro tasks/{task}", file=sys.stderr)
            sys.exit(EXIT_NOTASK)

    state = read_json(task_dir / "state.json") or {}
    repos = state.get("repos") or []
    lane = state.get("lane", "?")
    rounds = state.get("review_rounds", 0)
    by_repo = state.get("review_rounds_by_repo") or {}
    titulo = ""
    for line in read_text(task_dir / "task.md").splitlines():
        m = re.match(r"^\s*title:\s*(.+)$", line)
        if m:
            titulo = m.group(1).strip().strip('"')
            break
        if line.startswith("# "):
            titulo = line[2:].strip()
            break

    c = costo(task)
    sup = supuestos(task_dir)
    dec = decisiones(state)
    ver = veredictos(task_dir)
    hal = hallazgos(task_dir)

    L = []
    L.append("---")
    L.append(f"tarea: {task}")
    L.append(f"titulo: {titulo or TODO.format('el título de la tarea')}")
    L.append(f"carril: {lane}")
    L.append("repos: [" + ", ".join(repos) + "]")
    L.append(f"costo_usd: {c or 'n/d'}")
    L.append(f"rondas_review: {rounds}")
    L.append("tags: [tarea, harness]")
    L.append("---")
    L.append("")
    L.append(f"# {titulo or task}")
    L.append("")
    L.append("## Qué se pidió")
    L.append(TODO.format("una línea: qué pidió el humano, en sus términos"))
    L.append("")
    L.append("## Qué resultó ser el problema real")
    L.append(TODO.format(
        "si lo pedido y lo que había resultaron ser lo mismo, decilo en una "
        "línea y seguí. Si NO, esto es lo más valioso de la nota"))
    L.append("")
    L.append("## Sorpresas")
    L.append(TODO.format(
        "lo que contradijo la expectativa, en viñetas. 'Esperábamos X, medimos "
        "Y'. Si no hubo ninguna, escribí 'ninguna' y no inventes"))
    if sup:
        L.append("")
        falsos = [s for s in sup if s["entorno"] and not s["medido"]]
        L.append("### Del ledger de supuestos")
        for s in sup:
            marca = "medido" if s["medido"] else ("entorno SIN medir" if s["entorno"] else "asumido")
            L.append(f"- ({marca}) {redact(s['texto'])}")
        if falsos:
            L.append("")
            L.append("> Los marcados *entorno SIN medir* son material de "
                     "`/promote`: un supuesto de entorno que nadie midió es el "
                     "que más caro sale cuando resulta falso.")
    L.append("")
    L.append("## Decisiones")
    if dec:
        for d in dec:
            L.append(f"- {redact(d)}")
    L.append(TODO.format(
        "las decisiones de DISEÑO con su alternativa descartada. history[] de "
        "arriba trae las autorizaciones, no los porqués"))
    L.append("")

    if ver:
        L.append("## Cómo salió")
        L.append("")
        L.append("| repo | veredicto | qa | blocking | tardíos | req sin cubrir |")
        L.append("|---|---|---|---|---|---|")
        for f in ver:
            L.append(f"| [[repo/{f['repo']}]] | {f['verdict']} | {f['qa']} | "
                     f"{f['blocking']} | {f['tardios']} | {f['uncovered']} |")
        if by_repo:
            L.append("")
            L.append("Rondas por repo: "
                     + ", ".join(f"{k} {v}" for k, v in by_repo.items())
                     + ". Un plan bueno se ve como tareas de una sola ronda.")
        L.append("")

    if hal:
        L.append("## Hallazgos difundidos")
        for h in hal:
            L.append(f"- {redact(h)}")
        L.append("")

    L.append("## Enlaces")
    for r in repos:
        L.append(f"- [[repo/{r}]]")
    L.append(TODO.format(
        "ADRs que salieron de acá, PR, y tareas relacionadas como [[AUTO-...]]. "
        "Estos enlaces son lo que hace útil el grafo: sin ellos esto es una "
        "carpeta de archivos sueltos"))
    L.append("")
    L.append("---")
    L.append("")
    L.append("*Los campos verificables los rellenó `scripts/task-note.py` desde "
             "los artefactos de la tarea. Lo demás es juicio, y lo escribe quien "
             "archiva mientras todavía tiene el contexto. "
             "Si algo de acá se volvió LEY, no se queda en esta nota: sube a un "
             "ADR o a una regla. Esta nota guarda el camino; git guarda el "
             "destino.*")
    return "\n".join(L) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="task-note.py",
                                 description="La nota versionada de una tarea.")
    ap.add_argument("task")
    ap.add_argument("--stdout", action="store_true",
                    help="imprime sin escribir")
    args = ap.parse_args(argv)

    nota = build(args.task)
    if args.stdout:
        sys.stdout.write(nota)
        return EXIT_OK

    out_dir = WS / "docs" / "tareas"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{args.task}.md"
    # Idempotente y NO destructivo: si ya existe con los placeholders
    # completados, re-generarla los volvería a poner y borraría el juicio.
    if out.exists() and TODO.split("{")[0] not in out.read_text(errors="replace"):
        print(f"task-note: {out.relative_to(WS)} ya está completa, no la piso.")
        print("  ↳ si querés regenerar los campos verificables, borrala primero.")
        return EXIT_OK
    out.write_text(nota)
    pend = nota.count(TODO.split("{")[0])
    print(f"📝 {out.relative_to(WS)} ({pend} campo(s) de juicio por completar)")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
