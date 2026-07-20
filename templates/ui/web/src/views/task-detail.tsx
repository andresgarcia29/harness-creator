import { useEffect, useState } from "react"
import { Badge } from "@/components/ui/badge"
import { Card, CardContent } from "@/components/ui/card"
import { H2, Lede, Code, PendAlert, Story, Sup, Empty, NumCell } from "@/components/bits"
import { RespondBox } from "@/components/respond-box"
import { TaskGitPanel } from "@/components/task-git"
import { TaskFlow } from "@/components/task-flow"
import { Constellation } from "@/components/task-constellation"
import { Gantt } from "@/components/charts"
import { cn } from "@/lib/utils"
import { BUSKINDS, PHASES, pending, sessionsOfTask, rollupSessions, estado, liveAgents, n, usd, toEpoch, taskRollup, rel,
  type BusEvent, type Session, type Snapshot, type Task, type TaskStatus } from "@/lib/harness"
import { Activity, ArrowLeft, ArrowRight, Check, CheckCircle2, CirclePause, Radio, Route, ScrollText, ShieldAlert } from "lucide-react"
import type { Go } from "@/App"
import { withTarget } from "@/lib/target"

const blank = (id: string): Task => ({ id, title: "", origin: "", phase: null, done: [], verdicts: { pass: 0, total: 0 }, assumptions: [] })

const TASK_STATUS: Record<TaskStatus, { label: string; Icon: typeof Activity; tone: string }> = {
  work: { label: "En progreso", Icon: Activity, tone: "text-(--brand) border-(--brand)/25 bg-(--brand)/10" },
  wait: { label: "Esperando decisión", Icon: CirclePause, tone: "text-(--wait) border-(--wait)/25 bg-(--wait)/10" },
  block: { label: "Bloqueada", Icon: ShieldAlert, tone: "text-(--bad) border-(--bad)/25 bg-(--bad)/10" },
  ship: { label: "Completada", Icon: CheckCircle2, tone: "text-(--ok) border-(--ok)/25 bg-(--ok)/10" },
}

function TaskHero({ t, id, phase, status, live, lastTs, eventCount, go }: {
  t: Task; id: string; phase: string; status: TaskStatus; live: number; lastTs: string; eventCount: number; go: Go
}) {
  const st = TASK_STATUS[status]
  const active = Math.max(0, PHASES.findIndex(([pid]) => pid === phase))
  return (
    <section className="task-hero mb-5 overflow-hidden rounded-3xl border border-border/80">
      <div className="relative z-10 p-5 sm:p-7">
        <button onClick={() => go({ name: "tasks" })} className="mb-6 inline-flex items-center gap-2 text-[10px] font-bold uppercase tracking-[0.14em] text-muted-foreground hover:text-foreground">
          <ArrowLeft className="size-3.5" /> Volver a tareas
        </button>
        <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_230px] lg:items-end">
          <div className="min-w-0">
            <div className="mb-3 flex flex-wrap items-center gap-2">
              <span className={cn("inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[9px] font-bold uppercase tracking-[0.12em]", st.tone)}>
                <st.Icon className={cn("size-3", status === "work" && "animate-pulse")} />{st.label}
              </span>
              {t.origin && <Badge variant="outline" className="h-6 rounded-full px-2.5 text-[8.5px] uppercase tracking-[0.14em]">{t.origin}</Badge>}
              {live > 0 && <span className="inline-flex items-center gap-1.5 text-[9.5px] font-semibold text-(--ok)"><i className="size-1.5 animate-pulse rounded-full bg-(--ok)" />{live} agente{live > 1 ? "s" : ""} en vivo</span>}
            </div>
            <span className="mb-2 block font-mono text-[9px] font-bold uppercase tracking-[0.2em] text-(--brand)">Mission brief / {phase || "intake"}</span>
            <h1 className="max-w-[25ch] break-words font-heading text-[clamp(24px,3.2vw,42px)] font-[680] leading-[1.02] tracking-[-0.045em]">{id}</h1>
            <p className={cn("mt-3 max-w-[70ch] text-[13px] leading-relaxed", t.title ? "text-foreground/75" : "italic text-muted-foreground/55")}>
              {t.title || "Ejecución trazable desde la intención hasta producción."}
            </p>
          </div>
          <div className="task-hero-console grid grid-cols-2 gap-px overflow-hidden rounded-2xl border border-border/80 bg-border/70 lg:grid-cols-1">
            <div><span>Fase actual</span><b className="capitalize text-(--brand)">{phase || "Intake"}</b></div>
            <div><span>Última señal</span><b>{lastTs ? rel(lastTs) : "sin actividad"}</b></div>
            <div><span>Eventos</span><b>{eventCount}</b></div>
            <div><span>Veredictos</span><b>{t.verdicts.total ? `${t.verdicts.pass}/${t.verdicts.total}` : "—"}</b></div>
          </div>
        </div>
        <div className="mt-7 overflow-x-auto pb-1">
          <div className="grid min-w-[620px] grid-cols-7 gap-2">
            {PHASES.map(([pid, label], i) => {
              const done = (t.done || []).includes(pid) || i < active
              const now = pid === phase
              return <div key={pid} className={cn("flight-step", done && "is-done", now && "is-now")}>
                <span>{done && !now ? <Check /> : now ? <Radio /> : String(i + 1).padStart(2, "0")}</span>
                <div><small>{now ? "Ahora" : done ? "Listo" : "Después"}</small><b>{label}</b></div>
              </div>
            })}
          </div>
        </div>
      </div>
    </section>
  )
}

function MissionSectionHead({ index, title, description, kind }: {
  index: string; title: string; description: string; kind: "route" | "log"
}) {
  const Icon = kind === "route" ? Route : ScrollText
  return (
    <div className="mission-section-head mt-9 mb-3 flex items-start gap-3">
      <span className="mission-section-icon"><Icon /></span>
      <div className="min-w-0 flex-1">
        <span>{index} / Mission data</span>
        <div className="mt-0.5 flex flex-wrap items-baseline gap-x-2.5 gap-y-1">
          <h2>{title}</h2><p>{description}</p>
        </div>
      </div>
    </div>
  )
}

// Una tarea CONTIENE sus sesiones (las corridas de agente en su worktree). Aquí
// se ven dentro de la tarea, cada una con su grafo — no separadas. Clic → sesión.
function TaskSessions({ s, taskId, go, evs }: { s: Snapshot; taskId: string; go: Go; evs: BusEvent[] }) {
  const list = sessionsOfTask(s, taskId, evs)
  if (!list.length) return null
  const roll = rollupSessions(list)
  // qué lanzó cada sesión (runs.jsonl): la constelación lo enseña como contexto
  const kindOf = new Map((s.runs || []).filter((r) => r.task === taskId && r.kind).map((r) => [r.session, r.kind]))
  return (
    <>
      <H2 sub="una tarea puede correr en varias sesiones — cada una con su propio grafo">Sus sesiones</H2>
      <div className="mb-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-[11.5px] text-muted-foreground/80">
        <span className="font-medium text-foreground/70">{list.length} sesión{list.length > 1 ? "es" : ""}</span>
        {roll.live > 0 && <span className="flex items-center gap-1.5 font-semibold text-(--ok)"><i className="size-1.5 animate-pulse rounded-full bg-(--ok)" />{roll.live} agente{roll.live > 1 ? "s" : ""} vivo{roll.live > 1 ? "s" : ""}</span>}
        <span className="font-mono">{n(roll.out)} tokens</span>
        <span className="font-mono">{usd(roll.cost)} est.</span>
      </div>
      <Constellation list={list} kindOf={kindOf} go={go} />
      <div className="mb-2 grid gap-3">{list.map((x) => <SessionRow key={x.id} x={x} go={go} />)}</div>
    </>
  )
}

function SessionRow({ x, go }: { x: Session; go: Go }) {
  const [g, est, on] = estado(x)
  const A = x.agents.filter((a) => a.first_ts && a.last_ts)
  const t0 = A.length ? Math.min(...A.map((a) => a.first_ts)) : 0
  const t1 = A.length ? Math.max(...A.map((a) => a.last_ts)) : 0
  return (
    <Card className="overflow-hidden py-0">
      <button onClick={() => go({ name: "session", id: x.id })}
        className="flex w-full items-center gap-3 px-4 py-2.5 text-left transition-colors hover:bg-accent/40">
        <span className={cn("w-3 shrink-0 text-center font-mono text-[13px] font-semibold", on && "animate-pulse text-(--ok)")}>{g}</span>
        <span className="shrink-0 font-mono text-[12px] font-semibold text-(--brand)">{x.short}</span>
        <span className="w-24 shrink-0 text-[12.5px] font-medium">{est}</span>
        <span className="hidden min-w-0 flex-1 truncate text-xs text-muted-foreground/70 sm:block">{(x.last_text || "").slice(0, 110)}</span>
        <NumCell v={`${x.n_agents} · ${liveAgents(x)}`} l="agentes · vivos" className="hidden md:block" />
        <NumCell v={n(x.tokens.out)} l="tokens" className="hidden sm:block" />
        <NumCell v={usd(x.cost)} l="est." />
        <ArrowRight className="size-3.5 shrink-0 text-muted-foreground/40" />
      </button>
      {A.length > 1 && (
        <div className="border-t p-4"><Gantt A={A} t0={t0} t1={t1} peak={x.peak} /></div>
      )}
    </Card>
  )
}

export function TaskDetail({ s, id, go }: { s: Snapshot; id: string; go: Go }) {
  const t = s.tasks.find((x) => x.id === id) || blank(id)
  // arco COMPLETO de la tarea (todos sus eventos, no la ventana del snapshot);
  // mientras carga, cae a lo que sí trae el snapshot para no parpadear vacío.
  const snapEvs = s.events.filter((e) => BUSKINDS.includes(e.kind) && e.task === id)
  const [full, setFull] = useState<BusEvent[] | null>(null)
  useEffect(() => {
    let live = true
    const load = () => fetch(withTarget(`/api/task-events?task=${encodeURIComponent(id)}`))
      .then((r) => r.json()).then((d) => { if (live && Array.isArray(d)) setFull(d) }).catch(() => {})
    load()
    const iv = setInterval(load, 4000)
    return () => { live = false; clearInterval(iv) }
  }, [id])
  const tevs = (full && full.length ? full : snapEvs).filter((e) => BUSKINDS.includes(e.kind))
  // para vincular sesiones se usa TODO el bus (los eventos tool mencionan la
  // sesión por su scratchpad); el arco visible sigue siendo solo BUSKINDS
  const evsAll = full && full.length ? full : s.events.filter((e) => e.task === id)
  const p = pending(s).find((e) => e.task === id)
  const run = (s.runs || []).slice().reverse().find((r) => r.task === id && r.session)
  const roll = taskRollup(s).find((r) => r.id === id)
  const sessionRoll = rollupSessions(sessionsOfTask(s, id, evsAll))
  const phase = roll?.phase || t.phase || "intake"
  return (
    <>
      <TaskHero t={t} id={id} phase={phase} status={roll?.status || "work"} live={sessionRoll.live}
        lastTs={roll?.lastTs || tevs[tevs.length - 1]?.ts || ""} eventCount={tevs.length} go={go} />
      {p && (
        <PendAlert kind={p._k}
          title={p._k === "block" ? "Un gate bloqueó esta tarea" : "Esta tarea te está esperando"}
          summary={p.summary} />
      )}
      <TaskSessions s={s} taskId={id} go={go} evs={evsAll} />
      {(t.assumptions || []).length > 0 && (
        <>
          <H2>Supuestos que hizo el agente</H2>
          <Lede>Cada uno con su evidencia y con lo que costaría deshacerlo si resultó falso.</Lede>
          {t.assumptions.map((a, i) => <Sup key={i} text={a} />)}
        </>
      )}
      {tevs.length > 1 && (
        <>
          <MissionSectionHead index="01" kind="route" title="El recorrido" description="Fases, decisiones y fricción sobre una sola línea de tiempo." />
          <TaskFlow evs={tevs} live={sessionRoll.live > 0}
            onJump={(ts) => {
              // el nodo del grafo y su beat en la historia comparten timestamp;
              // los gates agrupados caen al beat más cercano en el tiempo
              const els = Array.from(document.querySelectorAll<HTMLElement>("[data-ts]"))
              if (!els.length) return
              const t = toEpoch(ts)
              let best = els[0], bd = Infinity
              for (const el of els) {
                const d = Math.abs(toEpoch(el.dataset.ts || "") - t)
                if (d < bd) { bd = d; best = el }
              }
              // instant: el smooth lo cancelan los relayouts del SSE en vivo
              best.scrollIntoView({ behavior: "instant", block: "center" })
              best.classList.remove("beat-flash"); void best.offsetWidth
              best.classList.add("beat-flash")
              setTimeout(() => best.classList.remove("beat-flash"), 1800)
            }} />
        </>
      )}
      <TaskGitPanel id={id} />
      <MissionSectionHead index="03" kind="log" title="La bitácora" description="Decisiones y cambios, ordenados para reconstruir cada momento." />
      <Lede>Registro verificable escrito por <Code>ship.sh</Code> y <Code>/auto</Code>. Los bloqueos conservan el mismo peso visual que los éxitos.</Lede>
      {tevs.length ? (
        <Card className="mission-log overflow-hidden py-0"><CardContent className="p-4 sm:p-6"><Story evs={tevs} dated variant="mission" /></CardContent></Card>
      ) : (
        <Empty><p>Sin eventos del bus para esta tarea todavía.</p></Empty>
      )}
      {p && run && (
        <div className="mt-6">
          <RespondBox session={run.session} label="El agente te espera — respóndele aquí" placeholder="Tu decisión o el contexto que le falta…" />
        </div>
      )}
      {p && !run && (
        <p className="mt-4 max-w-[86ch] text-[11.5px] leading-relaxed text-muted-foreground/70">
          Esta tarea no se lanzó desde el panel, así que no hay sesión que reanudar desde aquí:
          responde en su terminal (o pásale contexto desde su sesión en Sesiones).
        </p>
      )}
    </>
  )
}
