import { useEffect, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { ScrollArea } from "@/components/ui/scroll-area"
import { VHead, H2, Stats, NumCell, StatusBadge } from "@/components/bits"
import { Gantt } from "@/components/charts"
import { RespondBox } from "@/components/respond-box"
import { AgentThreads } from "@/components/agent-thread"
import type { StreamText } from "@/hooks/use-snapshot"
import { cn } from "@/lib/utils"
import { estado, hhmm, n, usd, dur, who, type Snapshot } from "@/lib/harness"
import { ArrowLeft, Bot, ChevronDown, TerminalSquare } from "lucide-react"
import type { Go } from "@/App"
import { Sessions } from "./sessions"
import { PaneConsole, paneForTask, taskOfSession } from "./terminals"

// La terminal EN VIVO de la sesión, embebida junto a su grafo. Enlaza la sesión
// → su tarea (snap.runs) → el pane de herdr que la trabaja, y muestra su consola
// (la misma de Terminales: pantalla a color, teclas, responder). Es un cajón
// desplegable: se abre hacia arriba. Si la sesión no tiene una terminal abierta
// en herdr, no aparece nada.
function SessionTerminal({ s, sessionId }: { s: Snapshot; sessionId: string }) {
  const taskId = taskOfSession(s, sessionId)
  const pane = paneForTask(s, taskId)
  const [open, setOpen] = useState(true)
  if (!pane) return null
  const working = pane.agent_status === "working"
  const blocked = pane.agent_status === "blocked"
  return (
    <>
      <H2 sub="la misma terminal de Terminales, aquí junto a su avance">Terminal en vivo</H2>
      <div className={cn("overflow-hidden rounded-xl border bg-[#0e0e13] shadow-[0_10px_30px_rgba(0,0,0,.4)]",
        working ? "border-(--ok)/30" : blocked ? "border-(--bad)/35" : "border-white/10")}>
        <button onClick={() => setOpen((o) => !o)}
          className="flex w-full items-center gap-2.5 border-b border-white/8 bg-gradient-to-b from-white/[0.06] to-transparent px-4 py-2.5 text-left">
          <TerminalSquare className="size-3.5 text-white/40" />
          {pane.program && (
            <span className="flex shrink-0 items-center gap-1 rounded-md border border-(--brand)/40 bg-(--brand)/10 px-1.5 py-0.5 text-[10px] font-semibold text-(--brand)">
              <Bot className="size-3" /> {pane.program}
            </span>
          )}
          <span className="truncate font-mono text-[11.5px] text-white/70">{taskId}</span>
          {working && <span className="flex items-center gap-1 text-[10px] font-semibold text-(--ok)"><i className="size-1.5 animate-pulse rounded-full bg-(--ok)" />trabajando</span>}
          {blocked && <span className="flex items-center gap-1 text-[10px] font-semibold text-(--bad)"><i className="size-1.5 animate-pulse rounded-full bg-(--bad)" />te espera</span>}
          <span className="flex-1" />
          <span className="text-[10px] text-white/30">{open ? "ocultar" : "mostrar"}</span>
          <ChevronDown className={cn("size-3.5 text-white/30 transition-transform duration-200", !open && "-rotate-90")} />
        </button>
        <PaneConsole paneId={pane.pane_id} canOp={s.op !== false} open={open} />
      </div>
    </>
  )
}

export function SessionDetail({ s, id, go, texts }: { s: Snapshot; id: string; go: Go; texts: StreamText[] }) {
  const x = s.sessions.find((y) => y.id === id)
  const boxRef = useRef<HTMLDivElement>(null)
  const mine = texts.filter((t) => t.session === id)
  useEffect(() => {
    const el = boxRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [mine.length])
  if (!x) return <Sessions s={s} go={go} />
  const A = x.agents.filter((a) => a.first_ts && a.last_ts)
  const t0 = A.length ? Math.min(...A.map((a) => a.first_ts)) : 0
  const t1 = A.length ? Math.max(...A.map((a) => a.last_ts)) : 0
  const [g, est, on] = estado(x)
  const main = x.agents.find((a) => a.id === "main")
  const kids = x.agents.filter((a) => a.id !== "main")
  // seed: lo último dicho por agente (del snapshot) + lo llegado por SSE
  const seed = x.agents.filter((a) => a.last_text).sort((a, b) => a.last_ts - b.last_ts).slice(-8)
  const agentRow = (a: (typeof x.agents)[0], root = false) => {
    // el punto verde "trabajando" sólo si la sesión está viva DE VERDAD (herdr),
    // no por mtime — coherente con el badge de arriba.
    const act = a.active && on
    return (
    <div key={a.id} className={cn("flex items-center gap-2.5 border-b px-3.5 py-2 text-[12.5px] last:border-b-0",
      root ? "bg-secondary/60" : "relative pl-8")}>
      {!root && <span className="absolute left-3.5 text-[11px] text-border">└</span>}
      <span className={cn("w-3 shrink-0 text-center font-mono text-xs font-semibold", act && "animate-pulse text-(--ok)")}>
        {act ? "●" : "○"}
      </span>
      <span className="min-w-0 flex-1 truncate">
        {who(a)}
        <i className="ml-2 font-mono text-[10.5px] not-italic text-muted-foreground/60">{a.id === "main" ? a.model || "" : a.type || ""}</i>
      </span>
      <NumCell v={n(a.usage.out)} l="tokens" className="w-[72px]" />
      <NumCell v={usd(a.cost)} l="est." className="hidden w-[58px] sm:block" />
      <NumCell v={act ? "trabajando" : dur(a.idle)} l={act ? "ahora" : "desde hace"} className="hidden w-[98px] md:block" />
    </div>
    )
  }
  return (
    <>
      <Button variant="ghost" size="sm" className="-ml-2 mb-2 text-muted-foreground" onClick={() => go({ name: "sessions" })}>
        <ArrowLeft className="size-3.5" /> Sesiones
      </Button>
      <VHead
        title={<>Sesión <span className="font-mono">{x.short}</span></>}
        sub={<span className="font-mono">{x.model || "?"}</span>}
        right={
          <>
            <StatusBadge on={on}>{g} {est}</StatusBadge>
            <StatusBadge>solo esta sesión</StatusBadge>
          </>
        }
      />
      <Stats items={[
        [A.length ? dur(t1 - t0) : "—", "duración"], [x.n_agents, "agentes"], [x.peak, "a la vez (pico)"],
        [n(x.tokens.out), "tokens out"], [n(x.tokens.cache_read), "de caché (~10× más baratos)"], [usd(x.cost), "costo est."],
      ]} />
      {A.length > 1 && (
        <>
          <H2 sub="las barras que se solapan corrieron a la vez">Cuándo corrió cada agente</H2>
          <Card className="py-0"><CardContent className="p-4"><Gantt A={A} t0={t0} t1={t1} peak={x.peak} /></CardContent></Card>
        </>
      )}
      <SessionTerminal s={s} sessionId={x.id} />
      <H2>Sus agentes</H2>
      <div className="overflow-hidden rounded-xl border">
        {main && agentRow(main, true)}
        {kids.map((a) => agentRow(a))}
      </div>
      <H2 sub="llega por turno — cada mensaje se escribe al terminarlo">Lo último que dijeron</H2>
      <ScrollArea className="max-h-[250px] overflow-auto rounded-xl border" ref={boxRef as any}>
        {!seed.length && !mine.length ? (
          <div className="px-3.5 py-2.5 text-xs text-muted-foreground/60">
            Nadie ha dicho nada todavía. En cuanto un agente cierre un mensaje, aparece aquí.
          </div>
        ) : (
          <>
            {seed.map((a, i) => (
              <div key={"s" + i} className="border-b px-3.5 py-2.5 text-xs leading-relaxed text-muted-foreground last:border-b-0">
                <div className="mb-0.5 flex items-baseline gap-2">
                  <b className="text-[10.5px] font-bold text-(--brand)">{who(a)}</b>
                  <time className="font-mono text-[10px] text-muted-foreground/60">{hhmm(a.last_ts)}</time>
                </div>
                <p className="line-clamp-2">{a.last_text}</p>
              </div>
            ))}
            {mine.slice(-32).map((t, i) => (
              <div key={"t" + i} className="border-b px-3.5 py-2.5 text-xs leading-relaxed text-muted-foreground last:border-b-0">
                <div className="mb-0.5 flex items-baseline gap-2">
                  <b className="text-[10.5px] font-bold text-(--brand)">{t.who || t.agent.slice(0, 12)}</b>
                  <time className="font-mono text-[10px] text-muted-foreground/60">{hhmm(t.ts)}</time>
                </div>
                <p className="line-clamp-2">{t.text}</p>
              </div>
            ))}
          </>
        )}
      </ScrollArea>
      <AgentThreads sessionId={x.id} />
      <div className="mt-6">
        <RespondBox session={x.id} label="Pasar contexto al agente" placeholder="Contexto nuevo, una corrección, una decisión…" />
      </div>
    </>
  )
}
