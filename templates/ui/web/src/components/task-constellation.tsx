// La constelación de una tarea: tarea → sesiones → agentes, como grafo vivo.
// Cuando hay trabajo en paralelo se VE el fan-out: cada sesión con su enjambre
// de agentes, los vivos pulsando y las aristas activas en movimiento. Todo es
// dato real del snapshot (sesiones con sus agentes) + runs.jsonl (qué lanzó
// cada sesión); se actualiza solo con el SSE — nada se inventa.
import { useRef, useState } from "react"
import { estado, liveAgents, who, n, usd, type Agent, type Session } from "@/lib/harness"
import { fmtDur } from "@/components/task-flow"
import type { Go } from "@/App"

const COLS = 6, DX = 52, DY = 17
const MAX_AGENTS = 24

type Hover = { px: number; py: number; kind: "session" | "agent"; x: Session; a?: Agent }

export function Constellation({ list, kindOf, go }: {
  list: Session[]; kindOf: Map<string, string>; go: Go
}) {
  const wrap = useRef<HTMLDivElement>(null)
  const [hv, setHv] = useState<Hover | null>(null)
  const totalAgents = list.reduce((s, x) => s + x.agents.length, 0)
  if (list.length < 2 && totalAgents < 2) return null

  // orden estable: vivas arriba, luego por actividad reciente
  const sorted = list.slice().sort((a, b) => {
    const la = liveAgents(a) > 0 ? 1 : 0, lb = liveAgents(b) > 0 ? 1 : 0
    if (la !== lb) return lb - la
    return a.idle - b.idle
  })

  const W = 1000, TOP = 14, TASKX = 96, SX = 430, AX = 620
  // alto por sesión: el que exija su enjambre de agentes
  const rowsOf = (x: Session) => Math.ceil(Math.min(x.agents.length, MAX_AGENTS + 1) / COLS) || 1
  const rowH = (x: Session) => Math.max(72, rowsOf(x) * DY + 46)
  let acc = TOP
  const sy: number[] = sorted.map((x) => { const y = acc + rowH(x) / 2; acc += rowH(x); return y })
  const H = acc + 6
  const taskY = H / 2

  const hover = (kind: "session" | "agent", x: Session, a?: Agent) => (e: React.MouseEvent) => {
    const wr = wrap.current?.getBoundingClientRect()
    if (!wr) return
    setHv({ px: e.clientX - wr.left, py: e.clientY - wr.top, kind, x, a })
  }
  const clampX = (px: number) => {
    const w = wrap.current?.clientWidth || 600
    return Math.min(Math.max(px, 160), w - 160)
  }

  return (
    <div ref={wrap} className="relative mb-3">
      <div className="overflow-x-auto rounded-xl border bg-card p-3">
        <svg viewBox={`0 0 ${W} ${H}`} className="block w-full min-w-[680px]"
          style={{ height: Math.min(H, 460) }} onMouseLeave={() => setHv(null)}>
          {/* nodo tarea */}
          <rect x={TASKX - 60} y={taskY - 16} width={120} height={32} rx={9}
            fill="var(--secondary)" stroke="var(--border)" />
          <text x={TASKX} y={taskY + 3.5} textAnchor="middle" fontSize={10}
            fontFamily="monospace" fontWeight={600} fill="var(--foreground)">tarea</text>
          {sorted.map((x, i) => {
            const [, est, on] = estado(x)
            const y = sy[i]
            const agents = x.agents.slice(0, MAX_AGENTS)
            const extra = x.agents.length - agents.length
            const rows = rowsOf(x)
            const blockH = rows * DY
            const ay0 = y - blockH / 2 + DY / 2
            const kind = kindOf.get(x.id)
            return (
              <g key={x.id}>
                {/* arista tarea → sesión: viva = en movimiento */}
                <path d={`M ${TASKX + 62} ${taskY} C ${TASKX + 180} ${taskY}, ${SX - 130} ${y}, ${SX - 15} ${y}`}
                  fill="none"
                  stroke={on ? "var(--ok)" : "var(--border)"} strokeOpacity={on ? 0.55 : 0.9}
                  strokeWidth={on ? 1.6 : 1.2} className={on ? "edge-live" : undefined} />
                {/* nodo sesión */}
                <g className="cursor-pointer" onPointerDown={() => go({ name: "session", id: x.id })}
                  onMouseEnter={hover("session", x)} onMouseMove={hover("session", x)} onMouseLeave={() => setHv(null)}>
                  {on && <circle cx={SX} cy={y} r={18} fill="none" stroke="var(--ok)" strokeWidth={1.5} className="animate-pulse" opacity={0.55} />}
                  <circle cx={SX} cy={y} r={13} fill="var(--card)" stroke={on ? "var(--ok)" : "var(--muted-foreground)"}
                    strokeOpacity={on ? 0.9 : 0.35} strokeWidth={1.5} />
                  <text x={SX} y={y + 3} textAnchor="middle" fontSize={8.5} fontFamily="monospace"
                    fill={on ? "var(--ok)" : "var(--muted-foreground)"} fontWeight={600}>{x.agents.length}</text>
                  <text x={SX} y={y - 22} textAnchor="middle" fontSize={9.5} fontFamily="monospace" fontWeight={600}
                    fill="var(--brand)">{x.short}</text>
                  <text x={SX} y={y + 28} textAnchor="middle" fontSize={8.5}
                    fill={on ? "var(--ok)" : "var(--muted-foreground)"} opacity={on ? 1 : 0.75}>{est}</text>
                  {kind && (
                    <text x={SX} y={y + 39} textAnchor="middle" fontSize={8}
                      fill="var(--muted-foreground)" opacity={0.6}>{kind.length > 30 ? kind.slice(0, 30) + "…" : kind}</text>
                  )}
                </g>
                {/* enjambre de agentes */}
                {agents.map((a, j) => {
                  const ax = AX + (j % COLS) * DX
                  const ayy = ay0 + Math.floor(j / COLS) * DY
                  const alive = on && a.active
                  return (
                    <g key={a.id} className="cursor-pointer" onPointerDown={() => go({ name: "session", id: x.id })}
                      onMouseEnter={hover("agent", x, a)} onMouseMove={hover("agent", x, a)} onMouseLeave={() => setHv(null)}>
                      <path d={`M ${SX + 14} ${y} Q ${(SX + ax) / 2} ${ayy}, ${ax - 7} ${ayy}`}
                        fill="none" stroke={alive ? "var(--ok)" : "var(--muted-foreground)"}
                        strokeOpacity={alive ? 0.4 : 0.14} strokeWidth={1} />
                      {alive && <circle cx={ax} cy={ayy} r={7} fill="var(--ok)" opacity={0.2} className="animate-pulse" />}
                      <circle cx={ax} cy={ayy} r={4.5}
                        fill={alive ? "var(--ok)" : a.id === "main" ? "var(--brand)" : "var(--muted-foreground)"}
                        opacity={alive ? 1 : a.id === "main" ? 0.85 : 0.4} />
                      <circle cx={ax} cy={ayy} r={8.5} fill="transparent" />
                    </g>
                  )
                })}
                {extra > 0 && (
                  <text x={AX + (agents.length % COLS) * DX} y={ay0 + Math.floor(agents.length / COLS) * DY + 3}
                    fontSize={9} fontFamily="monospace" fill="var(--muted-foreground)" opacity={0.7}>+{extra}</text>
                )}
              </g>
            )
          })}
        </svg>
        <div className="mt-1.5 flex flex-wrap gap-x-4 gap-y-1 px-1 text-[10.5px] text-muted-foreground/70">
          <span className="flex items-center gap-1.5"><i className="size-2 animate-pulse rounded-full bg-(--ok)" />vivo ahora</span>
          <span className="flex items-center gap-1.5"><i className="size-2 rounded-full bg-(--brand)/85" />orquestador</span>
          <span className="flex items-center gap-1.5"><i className="size-2 rounded-full bg-muted-foreground/40" />terminó</span>
          <span className="ml-auto italic">se actualiza en vivo · clic = abrir la sesión</span>
        </div>
      </div>
      {hv && (
        <div className="pointer-events-none absolute z-20 w-[300px] rounded-lg bg-popover p-3 text-popover-foreground shadow-md ring-1 ring-foreground/10"
          style={{ left: clampX(hv.px), top: hv.py - 12, transform: "translate(-50%,-100%)" }}>
          {hv.kind === "session" ? (
            <>
              <div className="mb-1 flex items-baseline gap-2">
                <b className="font-mono text-[12px] text-(--brand)">{hv.x.short}</b>
                <span className="text-[11px] text-muted-foreground">{estado(hv.x)[1]}</span>
                <span className="ml-auto font-mono text-[10px] text-muted-foreground">{hv.x.agents.length} ag · {liveAgents(hv.x)} vivos</span>
              </div>
              {kindOf.get(hv.x.id) && <p className="mb-1 text-[10.5px] text-muted-foreground/80">{kindOf.get(hv.x.id)}</p>}
              <p className="font-mono text-[10.5px] text-muted-foreground">{n(hv.x.tokens.out)} tokens · {usd(hv.x.cost)} est.</p>
              {hv.x.last_text && <p className="mt-1 line-clamp-3 text-[11px] leading-snug text-muted-foreground/80">{hv.x.last_text.slice(0, 150)}</p>}
              <p className="mt-1.5 text-[9.5px] uppercase tracking-wide text-muted-foreground/50">clic → abrir la sesión</p>
            </>
          ) : hv.a && (
            <>
              <div className="mb-1 flex items-baseline gap-2">
                <i className={hv.a.active ? "size-2 shrink-0 animate-pulse rounded-full bg-(--ok)" : "size-2 shrink-0 rounded-full bg-muted-foreground/40"} />
                <b className="text-[12px]">{who(hv.a)}</b>
                <span className="ml-auto font-mono text-[10px] text-muted-foreground">{hv.a.model || ""}</span>
              </div>
              <p className="font-mono text-[10.5px] text-muted-foreground">
                {hv.a.active ? "vivo ahora" : "terminó"} · {fmtDur(hv.a.elapsed)} · {n(hv.a.usage.out)} tokens · {usd(hv.a.cost)}
              </p>
              {hv.a.last_text && <p className="mt-1 line-clamp-3 text-[11px] leading-snug text-muted-foreground/80">{hv.a.last_text.slice(0, 140)}</p>}
            </>
          )}
        </div>
      )}
    </div>
  )
}
