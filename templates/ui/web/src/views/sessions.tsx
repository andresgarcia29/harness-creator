import { VHead, Empty, H2 } from "@/components/bits"
import { cn } from "@/lib/utils"
import { estado, liveAgents, n, usd, fecha, type Snapshot, type Session } from "@/lib/harness"
import { ArchiveButton } from "@/components/archive-button"
import { Activity, ArrowUpRight, Bot, CheckCircle2, Clock3, Coins, Radio } from "lucide-react"
import type { Go } from "@/App"

function SessionCard({ x, done, task, go, now, compact = false }: {
  x: Session; done: boolean; task?: string; go: Go; now: number; compact?: boolean
}) {
  const [glyph, status, on] = estado(x)
  const finalStatus = done ? "Terminada" : status
  const text = (x.last_text || "").slice(0, 180) || "Sin texto reciente"
  return (
    <div role="button" tabIndex={0} onClick={() => go({ name: "session", id: x.id })}
      onKeyDown={(e) => { if (e.key === "Enter") go({ name: "session", id: x.id }) }}
      className={cn("session-card group relative min-w-0 cursor-pointer overflow-hidden rounded-2xl border bg-card text-left shadow-(--shadow-soft) transition-all hover:-translate-y-px hover:border-(--brand)/30 hover:shadow-(--shadow-float)",
        on ? "border-(--ok)/25" : "border-border/80", compact ? "p-4" : "p-5")}>
      <div className="flex min-w-0 items-start gap-3">
        <span className={cn("mt-0.5 grid size-8 shrink-0 place-items-center rounded-xl border font-mono text-xs",
          on ? "border-(--ok)/25 bg-(--ok)/8 text-(--ok)" : done ? "border-(--ok)/20 bg-(--ok)/[0.05] text-(--ok)/75" : "border-border bg-muted/40 text-muted-foreground")}>
          {done ? <CheckCircle2 className="size-4" /> : on ? <Radio className="size-4 animate-pulse" /> : glyph}
        </span>
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <b className="font-mono text-[12px] font-semibold text-(--brand)">{x.short}</b>
            <span className={cn("rounded-full px-2 py-0.5 text-[8.5px] font-bold uppercase tracking-[0.1em]", on ? "bg-(--ok)/10 text-(--ok)" : "bg-muted text-muted-foreground")}>{finalStatus}</span>
            <ArrowUpRight className="ml-auto size-3.5 text-muted-foreground/30 transition-all group-hover:-translate-y-0.5 group-hover:translate-x-0.5 group-hover:text-(--brand)" />
          </div>
          <p className={cn("mt-2 text-[11.5px] leading-relaxed text-muted-foreground/75", compact ? "line-clamp-1" : "line-clamp-2 min-h-9")}>{text}</p>
          {task && <button onClick={(e) => { e.stopPropagation(); go({ name: "task", id: task }) }} className="mt-2 max-w-full truncate rounded-lg border border-(--brand)/15 bg-(--brand)/[0.05] px-2 py-1 font-mono text-[9px] text-(--brand) hover:bg-(--brand)/10">{task}</button>}
        </div>
      </div>
      <div className="mt-4 grid grid-cols-4 gap-2 border-t border-border/65 pt-3">
        <span className="session-stat"><Bot /> <b>{x.n_agents} · {liveAgents(x)}</b><small>agentes · vivos</small></span>
        <span className="session-stat"><Activity /> <b>{n(x.tokens.out)}</b><small>tokens</small></span>
        <span className="session-stat"><Coins /> <b>{usd(x.cost)}</b><small>estimado</small></span>
        <span className="session-stat"><Clock3 /> <b>{x.idle < 60 ? "ahora" : fecha(now - x.idle)}</b><small>última actividad</small></span>
      </div>
      <ArchiveButton kind="session" id={x.id} className="absolute bottom-3 right-3 grid size-6 place-items-center rounded-lg text-muted-foreground/35 opacity-0 hover:bg-(--bad)/10 hover:text-(--bad) group-hover:opacity-100" />
    </div>
  )
}

export function Sessions({ s, go }: { s: Snapshot; go: Go }) {
  if (!s.sessions.length) return <><VHead title="Sesiones" sub="todo el espacio de trabajo" /><Empty title="Ninguna sesión todavía"><p>Abre Claude Code en este workspace y aparecerá aquí sola.</p></Empty></>
  const runOf = new Map((s.runs || []).map((r) => [r.session, r]))
  const cards = s.sessions.map((x) => {
    const run = runOf.get(x.id)
    const [, , on] = estado(x)
    return { x, task: run?.task, on, done: !on && run?.kind === "one-shot" }
  })
  const active = cards.filter((c) => !c.done && (c.on || c.x.idle < 600))
  const history = cards.filter((c) => !active.includes(c))
  const totalCost = s.sessions.reduce((sum, x) => sum + (x.cost || 0), 0)
  const totalTokens = s.sessions.reduce((sum, x) => sum + x.tokens.out, 0)
  return (
    <>
      <VHead title="Sesiones" sub="cada ejecución conserva su contexto, agentes y costo" right={
        <div className="flex items-center gap-2 text-[9.5px] font-semibold uppercase tracking-wider text-muted-foreground">
          <span className="rounded-full border bg-card px-2.5 py-1"><b className="text-(--ok)">{active.length}</b> activas</span>
          <span className="rounded-full border bg-card px-2.5 py-1"><b className="text-foreground">{n(totalTokens)}</b> tokens</span>
          <span className="rounded-full border bg-card px-2.5 py-1"><b className="text-foreground">{usd(totalCost)}</b> observado</span>
        </div>
      } />
      {active.length > 0 && <><H2 sub="actividad confirmada en la máquina">Ahora mismo</H2><div className={cn("grid gap-3", active.length > 1 && "lg:grid-cols-2")}>{active.map((c) => <SessionCard key={c.x.id} {...c} go={go} now={s.ts} />)}</div></>}
      {history.length > 0 && <><H2 sub={`${history.length} sesiones · las más recientes primero`}>Historial</H2><div className="grid gap-3 lg:grid-cols-2">{history.map((c) => <SessionCard key={c.x.id} {...c} go={go} now={s.ts} compact />)}</div></>}
    </>
  )
}
