// El recorrido de una tarea como GRAFO sobre el tiempo. Los carriles (y) son
// las fases del pipeline en orden; el eje x es el tiempo. La línea conecta los
// eventos en orden: cuando SUBE de carril, la tarea RETROCEDIÓ (un gate la
// bloqueó, reabrió trabajo). Los nodos rojos son fricción (bloqueo/deploy rojo),
// los ámbar son paradas, los verdes ship/deploy/gate-ok. Todo del bus real.
import { hhmm, fecha, toEpoch, PHASES, type BusEvent } from "@/lib/harness"

type Node = {
  x: number; lane: number; k: string; color: string; r: number
  label: string; summary: string; ts: string; sub?: string
}

const LANE_OF: Record<string, number> = {} // phase key → lane index
PHASES.forEach(([k], i) => (LANE_OF[k] = i))
const SHIP = LANE_OF["ship"], DEPLOY = LANE_OF["deploy"]

function subtask(summary: string): string | undefined {
  const m = summary.match(/\bT(\d)\b/)
  return m ? "T" + m[1] : undefined
}

export function TaskFlow({ evs }: { evs: BusEvent[] }) {
  if (evs.length < 2) return null
  const ts = evs.map((e) => toEpoch(e.ts))
  const t0 = Math.min(...ts), t1 = Math.max(...ts)
  const span = t1 - t0
  const W = 1000, LBL = 150, PADR = 20, ROW = 34, TOP = 8
  const lanes = PHASES.length
  const H = TOP + lanes * ROW + 8
  const x = (i: number) => {
    if (span <= 0) return LBL + (i / (evs.length - 1)) * (W - LBL - PADR)
    return LBL + ((toEpoch(evs[i].ts) - t0) / span) * (W - LBL - PADR)
  }
  const laneY = (l: number) => TOP + l * ROW + ROW / 2

  const V = (name: string) => `var(${name})`
  let cur = LANE_OF["intake"]
  const nodes: Node[] = evs.map((e, i) => {
    let lane = cur, k = e.kind, color = V("--muted-foreground"), r = 4
    if (e.kind === "phase") {
      const m = e.summary.toLowerCase().match(/\b(intake|rfc|implement|review|ship|deploy|archive)\b/)
      if (m) { lane = LANE_OF[m[1]]; cur = lane }
      color = V("--brand"); r = 4.5
    } else if (e.kind === "gate") {
      lane = SHIP
      if (e.ok === false) { color = V("--bad"); r = 6.5 } else { color = V("--ok"); r = 4 }
    } else if (e.kind === "ship") { lane = SHIP; color = V("--ok"); r = 6 }
    else if (e.kind === "deploy") { lane = DEPLOY; color = e.ok === false ? V("--bad") : V("--ok"); r = 6 }
    else if (e.kind === "stop") { color = V("--wait"); r = 6 }
    else if (e.kind === "decision") { color = V("--brand"); r = 3.5 }
    else if (e.kind === "assumption") { color = V("--muted-foreground"); r = 3 }
    const label = { phase: "fase", gate: e.ok === false ? "bloqueó" : "gate ok", decision: "decidió",
      assumption: "supuso", stop: "te espera", ship: "ship", deploy: e.ok === false ? "deploy rojo" : "deploy" }[e.kind] || e.kind
    return { x: x(i), lane, k, color, r, label, summary: e.summary, ts: e.ts, sub: subtask(e.summary) }
  })

  const path = nodes.map((nd, i) => (i ? "L" : "M") + nd.x.toFixed(1) + " " + laneY(nd.lane).toFixed(1)).join(" ")
  // marcas de tiempo en x
  const ticks: number[] = []
  if (span > 0) {
    const step = span > 4 * 3600 ? 3600 : span > 3600 ? 1800 : span > 600 ? 600 : 120
    for (let t = Math.ceil(t0 / step) * step; t <= t1; t += step) ticks.push(t)
  }

  return (
    <div className="overflow-x-auto rounded-xl border bg-card p-3">
      <svg viewBox={`0 0 ${W} ${H}`} className="block w-full min-w-[680px]" style={{ height: Math.min(H, 320) }}>
        {/* carriles */}
        {PHASES.map(([, lbl], i) => (
          <g key={i}>
            <line x1={LBL} y1={laneY(i)} x2={W - PADR} y2={laneY(i)} stroke="var(--border)" strokeDasharray="2 4" strokeWidth={1} />
            <text x={LBL - 10} y={laneY(i) + 3.5} textAnchor="end" fontSize={10.5}
              fill="var(--muted-foreground)" className="font-medium">{lbl}</text>
          </g>
        ))}
        {/* ticks de tiempo */}
        {ticks.map((t) => {
          const px = LBL + ((t - t0) / span) * (W - LBL - PADR)
          return <text key={t} x={px} y={H - 1} textAnchor="middle" fontSize={9}
            fontFamily="monospace" fill="var(--muted-foreground)" opacity={0.6}>{hhmm(t)}</text>
        })}
        {/* la línea del recorrido */}
        <path d={path} fill="none" stroke="var(--brand)" strokeWidth={1.6} strokeOpacity={0.55}
          strokeLinejoin="round" />
        {/* nodos */}
        {nodes.map((nd, i) => (
          <g key={i}>
            {(nd.k === "gate" && nd.color.includes("bad")) || nd.k === "stop" || (nd.k === "deploy" && nd.color.includes("bad")) ? (
              <circle cx={nd.x} cy={laneY(nd.lane)} r={nd.r + 3} fill={nd.color} opacity={0.16} />
            ) : null}
            <circle cx={nd.x} cy={laneY(nd.lane)} r={nd.r} fill={nd.color}>
              <title>{`${fecha(nd.ts)} · ${nd.label}${nd.sub ? " (" + nd.sub + ")" : ""}\n${nd.summary}`}</title>
            </circle>
            {nd.sub && (
              <text x={nd.x} y={laneY(nd.lane) - nd.r - 3} textAnchor="middle" fontSize={8.5}
                fontFamily="monospace" fill="var(--muted-foreground)">{nd.sub}</text>
            )}
          </g>
        ))}
      </svg>
      <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 px-1 text-[10.5px] text-muted-foreground/70">
        <span className="flex items-center gap-1.5"><i className="size-2 rounded-full bg-(--ok)" />gate ok · ship · deploy</span>
        <span className="flex items-center gap-1.5"><i className="size-2 rounded-full bg-(--bad)" />bloqueó · deploy rojo</span>
        <span className="flex items-center gap-1.5"><i className="size-2 rounded-full bg-(--wait)" />te espera</span>
        <span className="flex items-center gap-1.5"><i className="size-2 rounded-full bg-primary" />fase · decisión</span>
        <span className="ml-auto italic">la línea que sube = la tarea retrocedió</span>
      </div>
    </div>
  )
}
