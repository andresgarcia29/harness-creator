import { VHead, Empty, NumCell } from "@/components/bits"
import { cn } from "@/lib/utils"
import { estado, liveAgents, n, usd, fecha, type Snapshot } from "@/lib/harness"
import { ArchiveButton } from "@/components/archive-button"
import type { Go } from "@/App"

export function Sessions({ s, go }: { s: Snapshot; go: Go }) {
  if (!s.sessions.length)
    return (
      <>
        <VHead title="Sesiones" sub="todo el espacio de trabajo" />
        <Empty title="Ninguna sesión todavía"><p>Abre Claude Code en este workspace y aparecerá aquí sola.</p></Empty>
      </>
    )
  // procedencia: runs.jsonl vincula cada sesión con quién la lanzó y para qué
  // (la tarea de /auto, una arqueología, un enrichment…) — sin esto se ven
  // huérfanas y "(sin texto)"
  const runOf = new Map((s.runs || []).map((r) => [r.session, r]))
  const taskIds = new Set(s.tasks.map((t) => t.id))
  return (
    <>
      <VHead title="Sesiones" sub="cada una lleva su propia cuenta — nunca se suman como si fueran una" />
      <div className="grid gap-2.5">
        {s.sessions.map((x) => {
          const [g, est, on] = estado(x)
          const run = runOf.get(x.id)
          // one-shot que ya no vive = TERMINÓ (exit limpio), no "en reposo"
          const done = !on && run?.kind === "one-shot"
          const glyph = done ? "✓" : g
          const label = done ? "Terminada" : est
          const texto = (x.last_text || "").slice(0, 140) || run?.task || "(sin texto)"
          return (
            <div key={x.id} role="button" tabIndex={0} onClick={() => go({ name: "session", id: x.id })}
              onKeyDown={(e) => { if (e.key === "Enter") go({ name: "session", id: x.id }) }}
              className="group flex w-full min-w-0 cursor-pointer items-center gap-3.5 overflow-hidden rounded-xl border border-border bg-card p-3.5 px-4 text-left transition-all hover:border-primary/45 hover:shadow-[0_0_10px_rgba(99,102,241,.2)]">
              <span className={cn("w-3.5 shrink-0 text-center font-mono text-[13px] font-semibold",
                on && "animate-pulse text-(--ok)", done && "text-(--ok)/70")}>{glyph}</span>
              <span className="shrink-0 font-mono text-[12.5px] font-semibold text-(--brand)">{x.short}</span>
              <span className={cn("w-24 shrink-0 text-[13px] font-semibold", done && "text-muted-foreground")}>{label}</span>
              {run?.task && taskIds.has(run.task) && (
                <button
                  className="shrink-0 rounded-md border px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground hover:border-primary/45 hover:text-(--brand)"
                  onClick={(e) => { e.stopPropagation(); go({ name: "task", id: run.task }) }}
                  title="ir a la tarea que lanzó esta sesión">
                  {run.task.length > 28 ? run.task.slice(0, 28) + "…" : run.task}
                </button>
              )}
              <span className="hidden min-w-0 flex-1 truncate text-xs text-muted-foreground/80 sm:block">
                {texto}
              </span>
              <NumCell v={`${x.n_agents} · ${liveAgents(x)}`} l="agentes · vivos" className="hidden md:block" />
              <NumCell v={n(x.tokens.out)} l="tokens" className="hidden sm:block" />
              <NumCell v={usd(x.cost)} l="est." />
              <NumCell v={x.idle < 60 ? "ahora" : fecha(s.ts - x.idle)} l="últ. act." className="hidden md:block" />
              <ArchiveButton kind="session" id={x.id} />
            </div>
          )
        })}
      </div>
    </>
  )
}
