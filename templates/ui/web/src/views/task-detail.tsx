import { useEffect, useState } from "react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { VHead, H2, Lede, Code, PendAlert, Story, Sup, Empty, NumCell } from "@/components/bits"
import { RespondBox } from "@/components/respond-box"
import { TaskGitPanel } from "@/components/task-git"
import { TaskFlow } from "@/components/task-flow"
import { Gantt } from "@/components/charts"
import { cn } from "@/lib/utils"
import { BUSKINDS, PHASES, pending, sessionsOfTask, rollupSessions, estado, liveAgents, n, usd,
  type BusEvent, type Session, type Snapshot, type Task } from "@/lib/harness"
import { ArrowLeft, ArrowRight } from "lucide-react"
import type { Go } from "@/App"
import { withTarget } from "@/lib/target"

const blank = (id: string): Task => ({ id, title: "", origin: "", phase: null, done: [], verdicts: { pass: 0, total: 0 }, assumptions: [] })

// Una tarea CONTIENE sus sesiones (las corridas de agente en su worktree). Aquí
// se ven dentro de la tarea, cada una con su grafo — no separadas. Clic → sesión.
function TaskSessions({ s, taskId, go }: { s: Snapshot; taskId: string; go: Go }) {
  const list = sessionsOfTask(s, taskId)
  if (!list.length) return null
  const roll = rollupSessions(list)
  return (
    <>
      <H2 sub="una tarea puede correr en varias sesiones — cada una con su propio grafo">Sus sesiones</H2>
      <div className="mb-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-[11.5px] text-muted-foreground/80">
        <span className="font-medium text-foreground/70">{list.length} sesión{list.length > 1 ? "es" : ""}</span>
        {roll.live > 0 && <span className="flex items-center gap-1.5 font-semibold text-(--ok)"><i className="size-1.5 animate-pulse rounded-full bg-(--ok)" />{roll.live} agente{roll.live > 1 ? "s" : ""} vivo{roll.live > 1 ? "s" : ""}</span>}
        <span className="font-mono">{n(roll.out)} tokens</span>
        <span className="font-mono">{usd(roll.cost)} est.</span>
      </div>
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
  const p = pending(s).find((e) => e.task === id)
  const run = (s.runs || []).slice().reverse().find((r) => r.task === id && r.session)
  return (
    <>
      <Button variant="ghost" size="sm" className="-ml-2 mb-2 text-muted-foreground" onClick={() => go({ name: "tasks" })}>
        <ArrowLeft className="size-3.5" /> Tareas
      </Button>
      <VHead mono title={id} sub={t.title || ""} right={
        <>
          {t.origin && <Badge variant="outline" className="rounded-full text-[9px] uppercase tracking-wider text-muted-foreground">{t.origin}</Badge>}
          {t.verdicts.total > 0 && <Badge variant="outline" className="rounded-full text-[9px] uppercase tracking-wider text-muted-foreground">veredictos {t.verdicts.pass}/{t.verdicts.total}</Badge>}
        </>
      } />
      {p && (
        <PendAlert kind={p._k}
          title={p._k === "block" ? "Un gate bloqueó esta tarea" : "Esta tarea te está esperando"}
          summary={p.summary} />
      )}
      {t.phase && (
        <Card className="mb-3.5 py-0"><CardContent className="p-4">
          <div className="flex">
            {PHASES.map(([pid, lb]) => {
              const d = (t.done || []).includes(pid), now = t.phase === pid
              return (
                <div key={pid} className="relative flex-1 pt-[19px] text-center">
                  {pid !== "archive" && (
                    <span className={cn("absolute left-1/2 right-[-50%] top-[5px] h-[1.5px]", d && !now ? "bg-primary/55" : "bg-border")} />
                  )}
                  <span className={cn(
                    "absolute left-1/2 top-0 z-10 size-[11px] -translate-x-1/2 rounded-full border-2",
                    d && !now ? "border-primary bg-primary" : now
                      ? "animate-pulse border-(--brand) bg-card shadow-[0_0_0_4px_rgba(99,102,241,.2)]" : "border-border bg-card",
                  )} />
                  <b className={cn("text-[10.5px] font-medium",
                    now ? "font-semibold text-(--brand)" : d ? "text-muted-foreground" : "text-muted-foreground/60")}>{lb}</b>
                </div>
              )
            })}
          </div>
        </CardContent></Card>
      )}
      <TaskSessions s={s} taskId={id} go={go} />
      {(t.assumptions || []).length > 0 && (
        <>
          <H2>Supuestos que hizo el agente</H2>
          <Lede>Cada uno con su evidencia y con lo que costaría deshacerlo si resultó falso.</Lede>
          {t.assumptions.map((a, i) => <Sup key={i} text={a} />)}
        </>
      )}
      {tevs.length > 1 && (
        <>
          <H2 sub="cómo avanzó y cuándo retrocedió — pasa el mouse por cada nodo">El recorrido</H2>
          <TaskFlow evs={tevs} />
        </>
      )}
      <TaskGitPanel id={id} />
      <H2>La historia, paso a paso</H2>
      <Lede>Lo escriben <Code>ship.sh</Code> y <Code>/auto</Code> — funciona con cualquier agente. Un gate que bloquea se enseña igual de grande que un éxito: es la única línea que no se puede fingir.</Lede>
      {tevs.length ? (
        <Card className="py-0"><CardContent className="p-5"><Story evs={tevs} dated /></CardContent></Card>
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
