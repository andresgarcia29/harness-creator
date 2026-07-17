import { useEffect, useState } from "react"
import { Card, CardContent } from "@/components/ui/card"
import { H2, Lede } from "@/components/bits"
import { cn } from "@/lib/utils"
import { hhmm, dur, n, usd, type AgentDetail, type SessionDetail, type ThreadItem } from "@/lib/harness"
import { ChevronRight, Brain, MessageSquare, Wrench, Clock } from "lucide-react"

const GAP = 45 // s — una pausa mayor a esto se marca: ahí se fue el tiempo

function maxGap(thread: ThreadItem[]): number {
  let m = 0, prev = 0
  for (const it of thread) {
    if (it.ts && prev) m = Math.max(m, it.ts - prev)
    if (it.ts) prev = it.ts
  }
  return m
}

function ThreadLine({ it, prevTs }: { it: ThreadItem; prevTs: number }) {
  const gap = it.ts && prevTs ? it.ts - prevTs : 0
  return (
    <>
      {gap > GAP && (
        <div className="flex items-center gap-2 py-1 pl-1 text-[10.5px] text-(--wait)/80">
          <Clock className="size-3" /> pausa de {dur(gap)}
        </div>
      )}
      <div className="flex gap-2.5 py-1.5">
        <span className="mt-0.5 shrink-0">
          {it.k === "think" ? <Brain className="size-3.5 text-(--brand)" />
            : it.k === "tool" ? <Wrench className="size-3.5 text-muted-foreground/60" />
            : <MessageSquare className="size-3.5 text-muted-foreground" />}
        </span>
        <div className="min-w-0 flex-1">
          {it.k === "tool" ? (
            <p className="font-mono text-[11.5px] text-muted-foreground">
              <b className="text-foreground/80">{it.t}</b>{it.inp ? <span className="text-muted-foreground/60"> · {it.inp}</span> : null}
            </p>
          ) : (
            <p className={cn("whitespace-pre-wrap text-[12.5px] leading-relaxed",
              it.k === "think" ? "italic text-muted-foreground" : "text-foreground/90")}>
              {it.t}
            </p>
          )}
        </div>
        {it.ts > 0 && <time className="shrink-0 font-mono text-[10px] text-muted-foreground/40">{hhmm(it.ts)}</time>}
      </div>
    </>
  )
}

function AgentBlock({ a }: { a: AgentDetail }) {
  const [open, setOpen] = useState(false)
  const gap = maxGap(a.thread)
  const think = a.thread.filter((t) => t.k === "think").length
  return (
    <Card className="py-0"><CardContent className="p-0">
      <button onClick={() => setOpen((o) => !o)}
        className="flex w-full items-center gap-3 p-3.5 text-left transition-colors hover:bg-secondary/40">
        <ChevronRight className={cn("size-4 shrink-0 text-muted-foreground/60 transition-transform", open && "rotate-90")} />
        <span className={cn("size-2 shrink-0 rounded-full", a.active ? "animate-pulse bg-(--ok)" : "bg-muted-foreground/30")} />
        <div className="min-w-0 flex-1">
          <b className="text-[13px] font-semibold">{a.who}</b>
          <span className="ml-2 font-mono text-[10.5px] text-muted-foreground/60">{a.id === "main" ? a.model : a.type}</span>
        </div>
        {gap > GAP && <span className="hidden items-center gap-1 text-[10.5px] text-(--wait)/80 sm:flex"><Clock className="size-3" />pausa {dur(gap)}</span>}
        {think > 0 && <span className="hidden items-center gap-1 text-[10.5px] text-(--brand) md:flex"><Brain className="size-3" />{think}</span>}
        <span className="font-mono text-[11px] tabular-nums text-muted-foreground">{dur(a.elapsed)}</span>
        <span className="hidden font-mono text-[11px] tabular-nums text-muted-foreground sm:inline">{n(a.usage.out)} tok</span>
        <span className="font-mono text-[11px] tabular-nums text-muted-foreground">{usd(a.cost)}</span>
      </button>
      {open && (
        <div className="border-t border-border px-4 py-2">
          {a.thread.length ? (
            a.thread.map((it, i) => <ThreadLine key={i} it={it} prevTs={i ? a.thread[i - 1].ts : 0} />)
          ) : (
            <p className="py-2 text-[12px] text-muted-foreground/60">Este agente aún no ha dejado texto ni razonamiento en su transcript.</p>
          )}
        </div>
      )}
    </CardContent></Card>
  )
}

// El drill-down: "qué pensó, qué usó, qué dijo — y dónde se le fue el tiempo".
// Se pide on-demand a /api/session para no inflar el SSE con todo el hilo.
export function AgentThreads({ sessionId }: { sessionId: string }) {
  const [d, setD] = useState<SessionDetail | null>(null)
  useEffect(() => {
    let live = true
    const load = () =>
      fetch(`/api/session?id=${encodeURIComponent(sessionId)}`)
        .then((r) => r.json()).then((x) => { if (live) setD(x) }).catch(() => {})
    load()
    const iv = setInterval(load, 4000) // se refresca mientras la sesión trabaja
    return () => { live = false; clearInterval(iv) }
  }, [sessionId])
  if (!d || !d.agents.length) return null
  return (
    <>
      <H2 sub="qué pensó y por qué tardó — clic para abrir cada agente">El razonamiento, por dentro</H2>
      <Lede>Cada agente con su hilo: <b className="text-(--brand)">pensamiento</b>, herramientas y lo que dijo, con su reloj. Las <b className="text-(--wait)">pausas</b> te muestran dónde se fue el tiempo. Se redacta como todo lo demás.</Lede>
      <div className="grid gap-2">{d.agents.map((a) => <AgentBlock key={a.id} a={a} />)}</div>
    </>
  )
}
