import { Badge } from "@/components/ui/badge"
import { VHead, Code, PendAlert, Empty, H2 } from "@/components/bits"
import { BUSKINDS, PHASES, pending, taskRollup, sessionsOfTask, rollupSessions, rel, toEpoch,
  type Snapshot, type Task, type TaskRollup, type TaskStatus } from "@/lib/harness"
import { ArchiveButton } from "@/components/archive-button"
import { cn } from "@/lib/utils"
import { Activity, ArrowUpRight, CheckCircle2, CirclePause, GitBranch, ShieldAlert, Sparkles } from "lucide-react"
import type { Go } from "@/App"

const blank = (id: string): Task => ({ id, title: "", origin: "", phase: null, done: [], verdicts: { pass: 0, total: 0 }, assumptions: [] })

const STATUS: Record<TaskStatus, { label: string; Icon: typeof Activity; tone: string; rail: string }> = {
  work: { label: "En progreso", Icon: Activity, tone: "text-(--brand) border-(--brand)/25 bg-(--brand)/8", rail: "bg-(--brand)" },
  wait: { label: "Te espera", Icon: CirclePause, tone: "text-(--wait) border-(--wait)/25 bg-(--wait)/8", rail: "bg-(--wait)" },
  block: { label: "Bloqueada", Icon: ShieldAlert, tone: "text-(--bad) border-(--bad)/25 bg-(--bad)/8", rail: "bg-(--bad)" },
  ship: { label: "Terminada", Icon: CheckCircle2, tone: "text-(--ok) border-(--ok)/25 bg-(--ok)/8", rail: "bg-(--ok)" },
}

function TaskCard({ t, r, live, lastTs, go }: {
  t: Task; r: TaskRollup; live: number; lastTs: string; go: Go
}) {
  const st = STATUS[r.status]
  const phase = r.phase || t.phase || "sin fase"
  const phaseIndex = PHASES.findIndex(([id]) => id === phase)
  const progress = phaseIndex < 0 ? 0 : ((phaseIndex + 1) / PHASES.length) * 100
  return (
    <div role="button" tabIndex={0} onClick={() => go({ name: "task", id: t.id })}
      onKeyDown={(e) => { if (e.key === "Enter") go({ name: "task", id: t.id }) }}
      className="task-card group relative min-w-0 cursor-pointer overflow-hidden rounded-2xl border border-border/80 bg-card p-5 text-left shadow-(--shadow-soft) transition-all hover:-translate-y-0.5 hover:border-(--brand)/35 hover:shadow-(--shadow-float)">
      <i className={cn("absolute inset-y-5 left-0 w-0.5 rounded-full", st.rail)} />
      <div className="flex min-w-0 items-start gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className={cn("inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[9px] font-bold uppercase tracking-[0.12em]", st.tone)}>
              <st.Icon className={cn("size-3", r.status === "work" && "animate-pulse")} />{st.label}
            </span>
            {live > 0 && <span className="inline-flex items-center gap-1.5 text-[9.5px] font-semibold text-(--ok)"><i className="size-1.5 animate-pulse rounded-full bg-(--ok)" />{live} agente{live > 1 ? "s" : ""} vivo{live > 1 ? "s" : ""}</span>}
            <span className="ml-auto font-mono text-[9.5px] text-muted-foreground/60">{lastTs ? rel(lastTs) : "sin actividad"}</span>
          </div>
          <h3 className="mt-3 truncate font-mono text-[13px] font-semibold tracking-tight text-(--brand)">{t.id}</h3>
          <p className={cn("mt-1 line-clamp-2 min-h-9 text-[12.5px] leading-relaxed", t.title ? "text-foreground/85" : "italic text-muted-foreground/50")}>
            {t.title || r.waitingOn || "Sin título registrado"}
          </p>
        </div>
        <ArrowUpRight className="mt-1 size-4 shrink-0 text-muted-foreground/35 transition-all group-hover:-translate-y-0.5 group-hover:translate-x-0.5 group-hover:text-(--brand)" />
      </div>

      <div className="mt-4">
        <div className="mb-1.5 flex items-center justify-between text-[9px] font-semibold uppercase tracking-[0.12em] text-muted-foreground/65">
          <span>Progreso</span><span className="font-mono text-foreground/65">{phase}</span>
        </div>
        <div className="h-1 overflow-hidden rounded-full bg-foreground/[0.06]"><i className={cn("block h-full rounded-full", st.rail)} style={{ width: `${Math.max(5, progress)}%` }} /></div>
      </div>

      {r.lastDecision && <p className="mt-3 line-clamp-1 border-l border-(--brand)/25 pl-2.5 text-[10.5px] text-muted-foreground/70"><b className="text-foreground/65">Última decisión:</b> {r.lastDecision}</p>}
      <div className="mt-4 flex items-center gap-2 border-t border-border/65 pt-3 text-[9.5px] text-muted-foreground/65">
        {t.origin && <Badge variant="outline" className="h-5 rounded-full px-2 text-[8px] uppercase tracking-wider">{t.origin}</Badge>}
        <span className="inline-flex items-center gap-1"><GitBranch className="size-3" />{t.assumptions.length} supuesto{t.assumptions.length === 1 ? "" : "s"}</span>
        <span className="ml-auto"><ArchiveButton kind="task" id={t.id} className="grid size-6 place-items-center rounded-lg text-muted-foreground/40 opacity-0 hover:bg-(--bad)/10 hover:text-(--bad) group-hover:opacity-100" /></span>
      </div>
    </div>
  )
}

export function Tasks({ s, go }: { s: Snapshot; go: Go }) {
  const evs = s.events.filter((e) => BUSKINDS.includes(e.kind))
  const archived = new Set(s.archived_tasks || [])
  const ids = [...new Set([...s.tasks.map((t) => t.id), ...evs.map((e) => e.task).filter(Boolean) as string[]])]
    .filter((id) => !archived.has(id))
  if (!ids.length) return <><VHead title="Tareas" sub="todo el espacio de trabajo" /><Empty title="Sin tareas todavía"><p>Aparecen cuando corras <Code>/auto</Code> con un ticket o un prompt, o cuando <Code>ship.sh</Code> registre trabajo. Todo con datos reales: aquí no hay ejemplos.</p></Empty></>

  const pend = pending(s)
  const roll = taskRollup(s).filter((r) => ids.includes(r.id))
  const lastOf = (id: string) => {
    const te = evs.filter((e) => e.task === id)
    return te.length ? te[te.length - 1].ts : ""
  }
  const sorted = ids.slice().sort((a, b) => toEpoch(lastOf(b)) - toEpoch(lastOf(a)))
  const cards = sorted.map((id) => {
    const t = s.tasks.find((x) => x.id === id) || blank(id)
    const tevs = evs.filter((e) => e.task === id)
    const r = roll.find((x) => x.id === id) || { id, title: t.title || "", phase: t.phase || "", status: "work" as const, statusLabel: "trabajando", waitingOn: "", lastDecision: "", lastTs: lastOf(id), nEvents: tevs.length }
    return { t, r, live: rollupSessions(sessionsOfTask(s, id, tevs)).live, lastTs: lastOf(id) }
  })
  const active = cards.filter(({ r }) => r.status !== "ship")
  const done = cards.filter(({ r }) => r.status === "ship")
  const needs = roll.filter((r) => r.status === "wait" || r.status === "block").length

  return (
    <>
      <VHead title="Tareas" sub="trabajo trazable desde la intención hasta main" right={
        <div className="flex items-center gap-2 text-[9.5px] font-semibold uppercase tracking-wider text-muted-foreground">
          <span className="rounded-full border bg-card px-2.5 py-1"><b className="text-foreground">{active.length}</b> activas</span>
          <span className="rounded-full border bg-card px-2.5 py-1"><b className={needs ? "text-(--wait)" : "text-foreground"}>{needs}</b> esperan</span>
          <span className="rounded-full border bg-card px-2.5 py-1"><b className="text-(--ok)">{done.length}</b> listas</span>
        </div>
      } />
      {pend.slice(-2).map((e) => <PendAlert key={e.task} kind={e._k} onClick={() => go({ name: "task", id: e.task! })} title={`${e._k === "block" ? "Un gate bloqueó" : "Te está esperando"} — ${e.task}`} summary={e.summary} hint="Es lo último que registró esa tarea; nada ha pasado después. Clic para ver su historia." />)}
      {active.length > 0 && <><H2 sub="lo que está avanzando o necesita atención">En movimiento</H2><div className={cn("grid gap-3", active.length > 1 && "lg:grid-cols-2")}>{active.map((c) => <TaskCard key={c.t.id} {...c} go={go} />)}</div></>}
      {done.length > 0 && <><H2 sub="trabajo cerrado y verificable">Completadas</H2><div className={cn("grid gap-3", done.length > 1 && "lg:grid-cols-2")}>{done.map((c) => <TaskCard key={c.t.id} {...c} go={go} />)}</div></>}
      {!active.length && done.length > 0 && <div className="mt-5 flex items-center gap-2 rounded-2xl border border-(--ok)/20 bg-(--ok)/[0.05] px-4 py-3 text-[11.5px] text-(--ok)"><Sparkles className="size-4" />Todo el trabajo visible está cerrado.</div>}
    </>
  )
}
