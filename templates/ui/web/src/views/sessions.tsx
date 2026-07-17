import { VHead, Empty, NumCell } from "@/components/bits"
import { cn } from "@/lib/utils"
import { estado, n, usd, dur, type Snapshot } from "@/lib/harness"
import type { Go } from "@/App"

export function Sessions({ s, go }: { s: Snapshot; go: Go }) {
  if (!s.sessions.length)
    return (
      <>
        <VHead title="Sesiones" sub="todo el espacio de trabajo" />
        <Empty title="Ninguna sesión todavía"><p>Abre Claude Code en este workspace y aparecerá aquí sola.</p></Empty>
      </>
    )
  return (
    <>
      <VHead title="Sesiones" sub="cada una lleva su propia cuenta — nunca se suman como si fueran una" />
      <div className="grid gap-2.5">
        {s.sessions.map((x) => {
          const [g, est, on] = estado(x)
          return (
            <button key={x.id} onClick={() => go({ name: "session", id: x.id })}
              className="flex w-full min-w-0 items-center gap-3.5 overflow-hidden rounded-xl border border-border bg-card p-3.5 px-4 text-left transition-all hover:border-primary/45 hover:shadow-[0_0_10px_rgba(99,102,241,.2)]">
              <span className={cn("w-3.5 shrink-0 text-center font-mono text-[13px] font-semibold", on && "animate-pulse text-(--ok)")}>{g}</span>
              <span className="shrink-0 font-mono text-[12.5px] font-semibold text-(--brand)">{x.short}</span>
              <span className="w-24 shrink-0 text-[13px] font-semibold">{est}</span>
              <span className="hidden min-w-0 flex-1 truncate text-xs text-muted-foreground/80 sm:block">
                {(x.last_text || "").slice(0, 140) || "(sin texto)"}
              </span>
              <NumCell v={`${x.n_agents} · ${x.n_active}`} l="agentes · vivos" className="hidden md:block" />
              <NumCell v={n(x.tokens.out)} l="tokens" className="hidden sm:block" />
              <NumCell v={usd(x.cost)} l="est." />
              <NumCell v={x.idle < 60 ? "ahora" : dur(x.idle)} l="últ. act." className="hidden md:block" />
            </button>
          )
        })}
      </div>
    </>
  )
}
