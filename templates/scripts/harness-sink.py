#!/usr/bin/env python3
"""harness-sink.py: dónde aterrizan los datos del harness.

POR QUÉ EXISTE
--------------
La báscula (`harness-cost.py`) sabe cuánto costó cada agente, pero lo imprime y
se olvida. El único lugar donde el costo sobrevivía era el frontmatter de la
nota, que sirve para leer una tarea y no para preguntar "¿cuánto nos cuesta en
promedio un carril standard contra un express?".

Este script es el destino. Dos, en realidad, y el orden importa:

  1. ARCHIVO (siempre): `docs/metrics/<tarea>.jsonl`, versionado. Un archivo POR
     TAREA y no uno global, porque con diez personas appendeando al mismo
     archivo hay conflicto de merge en cada push; uno por tarea no choca nunca y
     el glob los lee todos igual:

         duckdb -c "SELECT carril, round(avg(costo_usd),2) FROM
                    read_json_auto('docs/metrics/*.jsonl') GROUP BY 1"

  2. POSTGRES (opcional): para cuando el volumen o los dashboards lo justifiquen.

**El archivo primero, la base después, y a propósito.** Una base es un servicio:
hay que correrlo, respaldarlo, migrarlo y darle acceso a diez personas. Empezar
por el archivo no cierra la puerta a la base; empezar por la base sí cierra la
puerta a la simplicidad. Por eso el archivo no se puede desactivar y Postgres sí.

EL GRANO: una fila por AGENTE por sesión, no por tarea. El hallazgo que motivó
todo esto (el 87% del gasto vive en el orquestador y no en los subagentes) solo
se ve con ese grano. Agregar hacia arriba es un GROUP BY; desagregar lo que se
guardó agregado es imposible.

SECRETOS: la configuración se versiona, así que **la contraseña no vive acá**.
El config guarda el NOMBRE de la variable de entorno, y el valor lo inyecta
`with-secrets.sh`, que es el único punto de inyección del harness. Un DSN con
password en un archivo versionado es el accidente que `gitleaks` existe para
cazar, y no vamos a plantarlo nosotros.

Uso:
  harness-sink.py setup           interactivo: pregunta, PRUEBA y escribe config
  harness-sink.py check           ¿está vivo el destino? (sale 3 si no)
  harness-sink.py push <tarea>    exporta esa tarea al archivo y a la base
  harness-sink.py ddl             imprime el CREATE TABLE y sale
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

EXIT_OK, EXIT_USAGE, EXIT_FAIL = 0, 2, 3

CONFIG_NAME = "metrics-sink.json"
DEFAULT_TABLE = "harness_costos"

DDL = """CREATE TABLE IF NOT EXISTS {tabla} (
  tarea            text,
  sesion           text NOT NULL,
  tipo             text,
  rol              text,
  modelo           text,
  carril           text,
  repos            text[],
  turnos           integer,
  tool_calls       integer,
  ctx_medio        bigint,
  ctx_max          bigint,
  acierto_cache    numeric(6,4),
  tok_input        bigint,
  tok_cache_read   bigint,
  tok_cache_write  bigint,
  tok_output       bigint,
  costo_usd        numeric(12,4),
  rondas_review    integer,
  linear_url       text,
  desde            timestamptz,
  hasta            timestamptz,
  -- La identidad de una fila es (sesion, rol): re-exportar una tarea tiene que
  -- ACTUALIZAR, no duplicar. Sin esto, correr push dos veces dobla el gasto
  -- reportado, que es peor que no tener el dato.
  PRIMARY KEY (sesion, rol)
);
CREATE INDEX IF NOT EXISTS {tabla}_tarea_idx ON {tabla} (tarea);
CREATE INDEX IF NOT EXISTS {tabla}_desde_idx ON {tabla} (desde);
"""


# ── Config ───────────────────────────────────────────────────────────────────
def config_path() -> Path:
    return WS / CONFIG_NAME


def load_config() -> dict:
    try:
        return json.loads(config_path().read_text())
    except Exception:
        return {}


def save_config(cfg: dict) -> None:
    config_path().write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")


def default_config() -> dict:
    return {
        "schema": 1,
        "archivo": {"enabled": True, "dir": "docs/metrics"},
        "postgres": {"enabled": False, "dsn_env": "HARNESS_SINK_DSN",
                     "tabla": DEFAULT_TABLE},
        "linear": {"enabled": False, "base_url": ""},
    }


# ── Postgres: probar de verdad, no asumir ────────────────────────────────────
def _psycopg():
    """psycopg3 o psycopg2, el que haya. Ninguno es un error CLARO, no un traceback."""
    try:
        import psycopg            # type: ignore
        return ("psycopg", psycopg)
    except Exception:
        pass
    try:
        import psycopg2           # type: ignore
        return ("psycopg2", psycopg2)
    except Exception:
        pass
    return (None, None)


def pg_test(dsn: str):
    """(ok, detalle). Prueba la conexión DE VERDAD, no valida el string.

    Un `setup` que acepta un DSN sin conectarse te deja creyendo que quedó
    configurado, y te enterás recién al archivar una tarea. Este script existe
    en parte para no hacer eso.
    """
    name, mod = _psycopg()
    if mod is not None:
        try:
            with mod.connect(dsn, connect_timeout=8) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT version()")
                    ver = cur.fetchone()[0]
            return True, f"{name}: {ver.split(',')[0]}"
        except Exception as e:
            return False, f"{name}: {e}"
    # Sin driver de Python, `psql` sirve igual y muchos equipos ya lo tienen.
    if _which("psql"):
        try:
            r = subprocess.run(["psql", dsn, "-tAc", "SELECT version()"],
                               capture_output=True, text=True, timeout=15)
            if r.returncode == 0:
                return True, "psql: " + (r.stdout.strip().split(",")[0] or "ok")
            return False, "psql: " + (r.stderr.strip().splitlines() or [""])[-1]
        except Exception as e:
            return False, f"psql: {e}"
    return False, ("no hay driver: instalá `pip install psycopg[binary]` "
                   "o tené `psql` en el PATH")


def _which(b: str):
    from shutil import which
    return which(b)


def pg_exec(dsn: str, sql: str, params_list=None):
    """Ejecuta DDL o un lote de INSERT. Devuelve (ok, detalle)."""
    name, mod = _psycopg()
    if mod is not None:
        try:
            with mod.connect(dsn, connect_timeout=10) as conn:
                with conn.cursor() as cur:
                    if params_list is None:
                        cur.execute(sql)
                    else:
                        for p in params_list:
                            cur.execute(sql, p)
                conn.commit()
            return True, "ok"
        except Exception as e:
            return False, str(e)
    if params_list is None and _which("psql"):
        try:
            r = subprocess.run(["psql", dsn, "-v", "ON_ERROR_STOP=1", "-c", sql],
                               capture_output=True, text=True, timeout=30)
            return (r.returncode == 0), (r.stderr.strip() or "ok")
        except Exception as e:
            return False, str(e)
    return False, "sin driver de Python no puedo insertar (psql solo cubre DDL)"


# ── Datos de la tarea ────────────────────────────────────────────────────────
def task_dir(task: str):
    d = WS / "tasks" / task
    if d.is_dir():
        return d
    cands = sorted((WS / "tasks" / "archive").glob(f"*{task}"))
    return cands[-1] if cands else None


def task_meta(task: str) -> dict:
    """Lo que la fila necesita y no está en el transcript: carril, repos, rondas."""
    d = task_dir(task)
    if not d:
        return {}
    try:
        st = json.loads((d / "state.json").read_text())
    except Exception:
        return {}
    return {
        "carril": st.get("lane"),
        "repos": st.get("repos") or [],
        "rondas_review": st.get("review_rounds"),
    }


def linear_url(task: str, cfg: dict):
    """El link al ticket, si la tarea nació de uno.

    Las tareas `origin: prompt` llevan id `AUTO-...` y NO tienen ticket: para
    esas el campo va nulo, que es honesto. Inventar una URL que da 404 es peor
    que no tenerla.
    """
    lin = cfg.get("linear") or {}
    base = (lin.get("base_url") or "").rstrip("/")
    if not lin.get("enabled") or not base or task.startswith("AUTO-"):
        return None
    return f"{base}/{task}"


def filas(task: str, cfg: dict):
    """Delega el cálculo a la báscula y le suma el contexto de la tarea."""
    tool = HERE / "harness-cost.py"
    if not tool.is_file():
        return [], "no encuentro harness-cost.py: sin báscula no hay filas"
    env = os.environ.copy()
    env["HARNESS_WS"] = str(WS)
    try:
        r = subprocess.run([sys.executable, str(tool), "export"],
                           capture_output=True, text=True, timeout=120, env=env)
    except Exception as e:
        return [], f"la báscula no corrió: {e}"
    if r.returncode != 0:
        return [], (r.stderr.strip() or "la báscula salió con error")
    meta = task_meta(task)
    url = linear_url(task, cfg)
    out = []
    for line in r.stdout.splitlines():
        if not line.strip():
            continue
        try:
            f = json.loads(line)
        except Exception:
            continue
        if f.get("tarea") != task:
            continue
        f.update(meta)
        f["linear_url"] = url
        out.append(f)
    return out, None


# ── Comandos ─────────────────────────────────────────────────────────────────
def cmd_setup(args) -> int:
    cfg = load_config() or default_config()
    print("── configuración del destino de métricas del harness")
    print(f"   se escribe en {config_path().name}, que se VERSIONA.")
    print("   Ninguna contraseña entra ahí: solo el nombre de la variable.\n")

    def pregunta(texto, default):
        try:
            v = input(f"{texto} [{default}]: ").strip()
        except EOFError:
            v = ""
        return v or default

    # 1. Archivo: no se pregunta si va, se pregunta dónde.
    d = pregunta("¿En qué carpeta van los .jsonl por tarea?",
                 cfg["archivo"].get("dir", "docs/metrics"))
    cfg["archivo"] = {"enabled": True, "dir": d}
    print(f"   ✅ archivo: {d}/<tarea>.jsonl (siempre activo: es el piso)\n")

    # 2. Linear
    yn = pregunta("¿Enlazar cada fila con su ticket de Linear? (s/n)",
                  "s" if cfg.get("linear", {}).get("enabled") else "n")
    if yn.lower().startswith("s"):
        base = pregunta("   URL base de tus issues "
                        "(ej. https://linear.app/corvux/issue)",
                        cfg.get("linear", {}).get("base_url", ""))
        cfg["linear"] = {"enabled": bool(base), "base_url": base}
        if base:
            print(f"   ✅ las tareas con id de ticket van a llevar {base}/<id>")
            print("      (las `AUTO-...` nacen de un prompt y no tienen ticket: "
                  "ahí el campo va nulo, no una URL que da 404)\n")
    else:
        cfg["linear"] = {"enabled": False, "base_url": ""}
        print("   · sin Linear\n")

    # 3. Postgres, y acá se PRUEBA
    yn = pregunta("¿Además de los archivos, escribir a Postgres? (s/n)",
                  "s" if cfg.get("postgres", {}).get("enabled") else "n")
    if not yn.lower().startswith("s"):
        cfg["postgres"]["enabled"] = False
        save_config(cfg)
        print("   · sin Postgres. Los archivos alcanzan para DuckDB, pandas y jq.")
        print(f"\n📝 {config_path().name} escrito.")
        return EXIT_OK

    env_name = pregunta("   ¿Qué variable de entorno trae el DSN?",
                        cfg["postgres"].get("dsn_env", "HARNESS_SINK_DSN"))
    tabla = pregunta("   ¿Nombre de la tabla?",
                     cfg["postgres"].get("tabla", DEFAULT_TABLE))
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", tabla):
        print(f"   ❌ '{tabla}' no es un identificador válido de SQL.")
        return EXIT_FAIL

    dsn = os.environ.get(env_name, "")
    if not dsn:
        print(f"\n   ⚠️  {env_name} no está en el entorno, así que NO puedo probar")
        print("      la conexión, y configurar sin probar es cómo te enterás")
        print("      del problema recién al archivar una tarea.")
        print(f"      Exportala y volvé a correr esto:")
        print(f"        export {env_name}='postgresql://usuario@host:5432/base'")
        print("      La contraseña va por with-secrets.sh, no en el config.")
        cfg["postgres"] = {"enabled": False, "dsn_env": env_name, "tabla": tabla}
        save_config(cfg)
        print(f"\n📝 {config_path().name} escrito con postgres DESACTIVADO.")
        return EXIT_FAIL

    print(f"\n   probando la conexión con {env_name}...")
    ok, detalle = pg_test(dsn)
    if not ok:
        print(f"   ❌ no conecté: {detalle}")
        cfg["postgres"] = {"enabled": False, "dsn_env": env_name, "tabla": tabla}
        save_config(cfg)
        print(f"\n📝 {config_path().name} escrito con postgres DESACTIVADO.")
        print("   Arreglá la conexión y volvé a correr `setup`.")
        return EXIT_FAIL
    print(f"   ✅ conecté: {detalle}")

    yn = pregunta("   ¿Creo la tabla ahora? (s/n)", "s")
    if yn.lower().startswith("s"):
        ok, detalle = pg_exec(dsn, DDL.format(tabla=tabla))
        print(f"   {'✅ tabla lista' if ok else '❌ ' + detalle}")
        if not ok:
            print("   ↳ podés crearla a mano: harness-sink.py ddl")

    cfg["postgres"] = {"enabled": True, "dsn_env": env_name, "tabla": tabla}
    save_config(cfg)
    print(f"\n📝 {config_path().name} escrito. Postgres ACTIVO.")
    print("   Probá con: harness-sink.py check")
    return EXIT_OK


def cmd_check(args) -> int:
    cfg = load_config()
    if not cfg:
        print(f"no hay {CONFIG_NAME}: corré `harness-sink.py setup`", file=sys.stderr)
        return EXIT_FAIL
    d = WS / cfg.get("archivo", {}).get("dir", "docs/metrics")
    print(f"archivo   : {d}  {'(existe)' if d.is_dir() else '(se crea al primer push)'}")
    lin = cfg.get("linear") or {}
    print(f"linear    : {'activo, ' + lin.get('base_url', '') if lin.get('enabled') else 'desactivado'}")
    pg = cfg.get("postgres") or {}
    if not pg.get("enabled"):
        print("postgres  : desactivado")
        return EXIT_OK
    env_name = pg.get("dsn_env", "HARNESS_SINK_DSN")
    dsn = os.environ.get(env_name, "")
    if not dsn:
        print(f"postgres  : ❌ {env_name} no está en el entorno")
        print(f"   ↳ corré esto bajo scripts/with-secrets.sh, que es el único "
              f"punto de inyección de secretos del harness")
        return EXIT_FAIL
    ok, detalle = pg_test(dsn)
    print(f"postgres  : {'✅ ' if ok else '❌ '}{detalle}")
    return EXIT_OK if ok else EXIT_FAIL


def cmd_push(args) -> int:
    cfg = load_config() or default_config()
    rows, err = filas(args.task, cfg)
    if err:
        print(f"sink: {err}", file=sys.stderr)
        return EXIT_FAIL
    if not rows:
        # Fail-open y DICIENDO por qué: sin el puente sid→tarea no hay a quién
        # atribuirle el gasto, y eso es un dato, no un error que frene el archivado.
        print(f"sink: sin filas para {args.task}. ¿La tarea corrió sin el hook "
              f"track-read, que es el que escribe .harness/session-task/?")
        return EXIT_OK

    d = WS / cfg.get("archivo", {}).get("dir", "docs/metrics")
    d.mkdir(parents=True, exist_ok=True)
    out = d / f"{args.task}.jsonl"
    out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    total = sum(r["costo_usd"] or 0 for r in rows)
    print(f"📊 {out.relative_to(WS)} · {len(rows)} fila(s) · ${total:,.2f}")

    pg = cfg.get("postgres") or {}
    if not pg.get("enabled"):
        return EXIT_OK
    env_name = pg.get("dsn_env", "HARNESS_SINK_DSN")
    dsn = os.environ.get(env_name, "")
    if not dsn:
        # El archivo YA se escribió, así que el dato no se pierde: esto avisa,
        # no falla. Perder el archivado por una base caída sería el peor canje.
        print(f"   ⚠️  postgres activo pero {env_name} no está en el entorno: "
              f"la fila quedó en el archivo y no en la base.")
        return EXIT_OK
    tabla = pg.get("tabla", DEFAULT_TABLE)
    cols = ["tarea", "sesion", "tipo", "rol", "modelo", "carril", "repos",
            "turnos", "tool_calls", "ctx_medio", "ctx_max", "acierto_cache",
            "tok_input", "tok_cache_read", "tok_cache_write", "tok_output",
            "costo_usd", "rondas_review", "linear_url", "desde", "hasta"]
    ph = ", ".join(["%s"] * len(cols))
    upd = ", ".join(f"{c}=EXCLUDED.{c}" for c in cols if c not in ("sesion", "rol"))
    sql = (f"INSERT INTO {tabla} ({', '.join(cols)}) VALUES ({ph}) "
           f"ON CONFLICT (sesion, rol) DO UPDATE SET {upd}")
    params = [tuple(r.get(c) for c in cols) for r in rows]
    ok, detalle = pg_exec(dsn, sql, params)
    print(f"   {'✅ ' + str(len(rows)) + ' fila(s) en ' + tabla if ok else '⚠️  postgres: ' + detalle}")
    return EXIT_OK


def cmd_ddl(args) -> int:
    cfg = load_config() or default_config()
    sys.stdout.write(DDL.format(tabla=(cfg.get("postgres") or {}).get("tabla", DEFAULT_TABLE)))
    return EXIT_OK


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="harness-sink.py",
        description="Dónde aterrizan los datos del harness: archivo siempre, "
                    "Postgres opcional.")
    ap.add_argument("--ws", default=None, help="el workspace")
    sub = ap.add_subparsers(dest="cmd")
    for name, fn, help_ in (("setup", cmd_setup, "interactivo: pregunta y PRUEBA"),
                            ("check", cmd_check, "¿está vivo el destino?"),
                            ("ddl", cmd_ddl, "imprime el CREATE TABLE")):
        p = sub.add_parser(name, help=help_)
        p.set_defaults(func=fn)
    p = sub.add_parser("push", help="exporta una tarea")
    p.add_argument("task")
    p.set_defaults(func=cmd_push)

    args = ap.parse_args(argv)
    if args.ws:
        global WS
        WS = Path(os.path.abspath(os.path.expanduser(args.ws)))
    if not getattr(args, "func", None):
        ap.print_help()
        return EXIT_USAGE
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
