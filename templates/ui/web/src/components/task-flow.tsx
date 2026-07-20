// El recorrido de una tarea como GRAFO sobre el tiempo. Los carriles (y) son
// las fases del pipeline en orden; el eje x es el tiempo. La línea conecta los
// eventos en orden: cuando SUBE de carril, la tarea RETROCEDIÓ (un gate la
// bloqueó, reabrió trabajo). Los nodos rojos son fricción (bloqueo/deploy rojo),
// los ámbar son paradas, los verdes ship/deploy/gate-ok. Todo del bus real.
//
// v2: hover = tarjeta con el evento completo · clic = salta a ese momento en
// la historia · cursor de tiempo (hora + fase bajo el mouse) · desglose de en
// qué fase se fue el tiempo · contadores de fricción. Nada se inventa: todo
// sale de los eventos del bus.
import { useRef, useState } from "react"
import { hhmm, fecha, toEpoch, PHASES, type BusEvent } from "@/lib/harness"

type Node = {
  i: number; x: number; lane: number; k: string; color: string; r: number
  label: string; summary: string; ts: string; sub?: string; sha?: string
}
type Hover = { px: number; py: number; nd: Node }

const LANE_OF: Record<string, number> = {} // phase key → lane index
PHASES.forEach(([k], i) => (LANE_OF[k] = i))
const SHIP = LANE_OF["ship"], DEPLOY = LANE_OF["deploy"]
const PHASE_LBL: Record<string, string> = {}
PHASES.forEach(([k, l]) => (PHASE_LBL[k] = l))

function subtask(summary: string): string | undefined {
  const m = summary.match(/\bT(\d)\b/)
  return m ? "T" + m[1] : undefined
}

export function fmtDur(s: number): string {
  if (s >= 3600) return `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}m`
  if (s >= 60) return `${Math.floor(s / 60)}m`
  return `${Math.max(0, Math.round(s))}s`
}

export function TaskFlow({ evs, live = false, onJump }: {
  evs: BusEvent[]; live?: boolean; onJump?: (ts: string) => void
}) {
  const wrap = useRef<HTMLDivElement>(null)
  const svgRef = useRef<SVGSVGElement>(null)
  const [hv, setHv] = useState<Hover | null>(null)
  const [tcur, setTcur] = useState<number | null>(null) // x en coords del viewBox
  if (evs.length < 2) return null
  const ts = evs.map((e) => toEpoch(e.ts))
  const t0 = Math.min(...ts), t1 = Math.max(...ts)
  const span = t1 - t0
  const W = 960, LBL = 104, PADR = 18, ROW = 29, TOP = 18
  const lanes = PHASES.length
  const H = TOP + lanes * ROW + 10
  const x = (i: number) => {
    if (span <= 0) return LBL + (i / (evs.length - 1)) * (W - LBL - PADR)
    return LBL + ((toEpoch(evs[i].ts) - t0) / span) * (W - LBL - PADR)
  }
  const laneY = (l: number) => TOP + l * ROW + ROW / 2

  const V = (name: string) => `var(${name})`
  let cur = LANE_OF["intake"]
  let retro = 0
  const counts = { dec: 0, sup: 0, gok: 0, blk: 0, ship: 0, stop: 0, depBad: 0 }
  const nodes: Node[] = evs.map((e, i) => {
    let lane = cur, k = e.kind, color = V("--muted-foreground"), r = 4
    if (e.kind === "phase") {
      const m = e.summary.toLowerCase().match(/\b(intake|rfc|implement|review|ship|deploy|archive)\b/)
      if (m) {
        const nl = LANE_OF[m[1]]
        if (nl < cur) retro++
        lane = nl; cur = nl
      }
      color = V("--brand"); r = 4.5
    } else if (e.kind === "gate") {
      lane = SHIP
      if (e.ok === false) { color = V("--bad"); r = 6.5; counts.blk++ } else { color = V("--ok"); r = 4; counts.gok++ }
    } else if (e.kind === "ship") { lane = SHIP; color = V("--ok"); r = 6; counts.ship++ }
    else if (e.kind === "deploy") { lane = DEPLOY; color = e.ok === false ? V("--bad") : V("--ok"); r = 6; if (e.ok === false) counts.depBad++ }
    else if (e.kind === "stop") { color = V("--wait"); r = 6; counts.stop++ }
    else if (e.kind === "decision") { color = V("--brand"); r = 3.5; counts.dec++ }
    else if (e.kind === "assumption") { color = V("--muted-foreground"); r = 3; counts.sup++ }
    const label = { phase: "fase", gate: e.ok === false ? "bloqueó" : "gate ok", decision: "decidió",
      assumption: "supuso", stop: "te espera", ship: "ship", deploy: e.ok === false ? "deploy rojo" : "deploy" }[e.kind] || e.kind
    const sha = e.kind === "ship" ? (e.summary.match(/@ ([0-9a-f]{7,10})\b/) || [])[1] : undefined
    return { i, x: x(i), lane, k, color, r, label, summary: e.summary, ts: e.ts, sub: subtask(e.summary), sha }
  })

  // dónde se fue el tiempo: segmentos de fase (una fase dura hasta la próxima)
  const segs: { ph: string; a: number; b: number }[] = []
  let curPh: { ph: string; a: number } | null = null
  for (const e of evs) {
    if (e.kind !== "phase") continue
    const m = e.summary.toLowerCase().match(/\b(intake|rfc|implement|review|ship|deploy|archive)\b/)
    if (!m) continue
    const t = toEpoch(e.ts)
    if (curPh) segs.push({ ph: curPh.ph, a: curPh.a, b: t })
    curPh = { ph: m[1], a: t }
  }
  if (curPh) segs.push({ ph: curPh.ph, a: curPh.a, b: t1 })
  const agg = new Map<string, number>()
  for (const sg of segs) agg.set(sg.ph, (agg.get(sg.ph) || 0) + (sg.b - sg.a))
  const aggList = PHASES.map(([k]) => [k, agg.get(k) || 0] as const).filter(([, v]) => v > 0)
  const aggTotal = aggList.reduce((s, [, v]) => s + v, 0)
  const phaseAt = (t: number): string => {
    let ph = ""
    for (const sg of segs) if (t >= sg.a) ph = sg.ph
    return ph
  }

  const path = nodes.map((nd, i) => (i ? "L" : "M") + nd.x.toFixed(1) + " " + laneY(nd.lane).toFixed(1)).join(" ")
  const ticks: number[] = []
  if (span > 0) {
    // ≤ ~11 marcas siempre, aunque la tarea dure días
    const step = [120, 300, 600, 1800, 3600, 2 * 3600, 4 * 3600, 8 * 3600, 24 * 3600]
      .find((st) => span / st <= 11) || 24 * 3600
    for (let t = Math.ceil(t0 / step) * step; t <= t1; t += step) ticks.push(t)
  }
  const curLane = nodes[nodes.length - 1].lane

  // coords del mouse → viewBox (para el cursor de tiempo) y → wrap (tarjeta)
  const onMove = (e: React.MouseEvent) => {
    const r = svgRef.current?.getBoundingClientRect()
    if (!r || r.width === 0) return
    const vx = ((e.clientX - r.left) / r.width) * W
    setTcur(vx >= LBL && vx <= W - PADR && span > 0 ? vx : null)
  }
  const hoverNode = (nd: Node) => (e: React.MouseEvent) => {
    const wr = wrap.current?.getBoundingClientRect()
    if (!wr) return
    setHv({ px: e.clientX - wr.left, py: e.clientY - wr.top, nd })
  }
  const clampX = (px: number) => {
    const w = wrap.current?.clientWidth || 600
    return Math.min(Math.max(px, 150), w - 150)
  }
  const tAtCursor = tcur != null ? t0 + ((tcur - LBL) / (W - LBL - PADR)) * span : null

  return (
    <div ref={wrap} className="relative">
      <div className="task-flow overflow-hidden rounded-2xl border border-border/80 bg-card shadow-(--shadow-soft)">
        {/* fricción y volumen, contados del bus — no editorializados */}
        <div className="flex flex-wrap items-center gap-2 border-b border-border/65 bg-foreground/[0.018] px-4 py-3.5 sm:px-5">
          <div className="mr-auto">
            <b className="block font-heading text-[13px] tracking-tight">Telemetría de ejecución</b>
            <span className="text-[9.5px] text-muted-foreground/65">{nodes.length} señales conectadas · selecciónalas para abrir el instante</span>
          </div>
          <span className="flow-current"><i className={live ? "animate-pulse" : ""} />{PHASES[curLane]?.[1] || "Intake"}</span>
          <span className="flow-kpi"><b>{fmtDur(span)}</b><small>duración</small></span>
          {counts.dec > 0 && <span className="flow-kpi"><b>{counts.dec}</b><small>decisiones</small></span>}
          {counts.sup > 0 && <span className="flow-kpi"><b>{counts.sup}</b><small>supuestos</small></span>}
          {(counts.blk + counts.depBad + retro) > 0 && <span className="flow-kpi flow-kpi-warn"><b>{counts.blk + counts.depBad + retro}</b><small>fricciones</small></span>}
          {live && <span className="ml-1 flex items-center gap-1.5 rounded-full border border-(--ok)/20 bg-(--ok)/8 px-2.5 py-1 text-[9px] font-bold uppercase tracking-wider text-(--ok)"><i className="size-1.5 animate-pulse rounded-full bg-(--ok)" />en vivo</span>}
        </div>
        <div className="overflow-x-auto px-3 pt-4 sm:px-5">
        <svg ref={svgRef} viewBox={`0 0 ${W} ${H}`} className="block w-full min-w-[590px]"
          style={{ height: Math.min(H, 280) }} onMouseMove={onMove} onMouseLeave={() => { setTcur(null); setHv(null) }}>
          <defs>
            <linearGradient id="flow-path" x1="0" x2="1"><stop stopColor="var(--brand-strong)" /><stop offset="1" stopColor="var(--brand-soft)" /></linearGradient>
          </defs>
          {/* carriles */}
          {PHASES.map(([k, lbl], i) => (
            <g key={i}>
              {live && i === curLane && <rect x={LBL - 8} y={laneY(i) - ROW / 2 + 2} width={W - LBL - PADR + 8} height={ROW - 4} rx={7} fill="var(--brand)" opacity={0.055} />}
              <line x1={LBL} y1={laneY(i)} x2={W - PADR} y2={laneY(i)} stroke="var(--border)" strokeDasharray="2 4" strokeWidth={1} />
              <text x={LBL - 10} y={laneY(i) + 3.5} textAnchor="end" fontSize={10.5}
                fill={live && i === curLane ? "var(--brand)" : "var(--muted-foreground)"}
                className={live && i === curLane ? "font-semibold" : "font-medium"}>{lbl}</text>
              {k === "x" ? null : null}
            </g>
          ))}
          {/* ticks de tiempo */}
          {ticks.map((t) => {
            const px = LBL + ((t - t0) / span) * (W - LBL - PADR)
            return <text key={t} x={px} y={H - 1} textAnchor="middle" fontSize={9}
              fontFamily="monospace" fill="var(--muted-foreground)" opacity={0.6}>{hhmm(t)}</text>
          })}
          {/* cursor de tiempo: sabes en qué momento estás parado y en qué fase iba */}
          {tcur != null && tAtCursor != null && (
            <g className="pointer-events-none">
              <line x1={tcur} y1={TOP - 4} x2={tcur} y2={H - 12} stroke="var(--foreground)" strokeOpacity={0.25} strokeWidth={1} />
              <text x={Math.min(Math.max(tcur, LBL + 34), W - PADR - 34)} y={TOP - 4} textAnchor="middle" fontSize={9.5}
                fontFamily="monospace" fill="var(--foreground)" opacity={0.75}>
                {hhmm(tAtCursor)}{phaseAt(tAtCursor) ? ` · ${PHASE_LBL[phaseAt(tAtCursor)] || phaseAt(tAtCursor)}` : ""}
              </text>
            </g>
          )}
          {/* la línea del recorrido */}
          <path d={path} fill="none" stroke="url(#flow-path)" strokeWidth={2.2} strokeOpacity={0.72}
            strokeLinejoin="round" />
          {/* nodos */}
          {nodes.map((nd, i) => {
            const cy = laneY(nd.lane)
            const bad = nd.color.includes("bad")
            const isLast = i === nodes.length - 1
            return (
              <g key={i} className={onJump ? "cursor-pointer" : undefined}
                onMouseEnter={hoverNode(nd)} onMouseMove={hoverNode(nd)} onMouseLeave={() => setHv(null)}
                onPointerDown={onJump ? () => onJump(nd.ts) : undefined}>
                {((nd.k === "gate" && bad) || nd.k === "stop" || (nd.k === "deploy" && bad)) && (
                  <circle cx={nd.x} cy={cy} r={nd.r + 3} fill={nd.color} opacity={0.16} />
                )}
                {live && isLast && (
                  <circle cx={nd.x} cy={cy} r={nd.r + 5} fill="none" stroke={nd.color} strokeWidth={1.5}
                    className="animate-pulse" opacity={0.6} />
                )}
                <circle cx={nd.x} cy={cy} r={nd.r} fill={nd.color} />
                {/* glifo dentro de los nodos grandes: se lee sin leyenda */}
                {bad && nd.r >= 6 && (
                  <path d={`M ${nd.x - 2.2} ${cy - 2.2} L ${nd.x + 2.2} ${cy + 2.2} M ${nd.x + 2.2} ${cy - 2.2} L ${nd.x - 2.2} ${cy + 2.2}`}
                    stroke="white" strokeWidth={1.3} strokeLinecap="round" />
                )}
                {nd.k === "stop" && (
                  <path d={`M ${nd.x - 1.4} ${cy - 2.2} V ${cy + 2.2} M ${nd.x + 1.4} ${cy - 2.2} V ${cy + 2.2}`}
                    stroke="white" strokeWidth={1.3} strokeLinecap="round" />
                )}
                {nd.k === "ship" && (
                  <path d={`M ${nd.x} ${cy - 2.6} L ${nd.x + 2.4} ${cy + 2} L ${nd.x - 2.4} ${cy + 2} Z`} fill="white" />
                )}
                {nd.sub && (
                  <text x={nd.x} y={cy - nd.r - 3} textAnchor="middle" fontSize={8.5}
                    fontFamily="monospace" fill="var(--muted-foreground)">{nd.sub}</text>
                )}
                {/* zona de hover generosa */}
                <circle cx={nd.x} cy={cy} r={Math.max(nd.r + 6, 9)} fill="transparent" />
              </g>
            )
          })}
        </svg></div>
        {/* dónde se fue el tiempo: fase a fase, del bus real */}
        {aggTotal > 0 && aggList.length > 1 && (
          <div className="border-t border-border/55 px-4 py-3 sm:px-5">
            <div className="flex h-1.5 overflow-hidden rounded-full">
              {aggList.map(([ph, secs]) => (
                <div key={ph} style={{ width: `${(secs / aggTotal) * 100}%`, background: "var(--brand)", opacity: 0.22 + 0.1 * LANE_OF[ph] }} />
              ))}
            </div>
            <div className="mt-1.5 flex flex-wrap gap-x-3 gap-y-0.5 text-[10px] text-muted-foreground/75">
              {aggList.map(([ph, secs]) => (
                <span key={ph} className="flex items-center gap-1">
                  <i className="size-1.5 rounded-full" style={{ background: "var(--brand)", opacity: 0.22 + 0.1 * LANE_OF[ph] }} />
                  {PHASE_LBL[ph] || ph} {fmtDur(secs)}
                </span>
              ))}
            </div>
          </div>
        )}
        <div className="flex flex-wrap gap-x-4 gap-y-1 border-t border-border/55 px-4 py-2.5 text-[9.5px] text-muted-foreground/70 sm:px-5">
          <span className="flex items-center gap-1.5"><i className="size-2 rounded-full bg-(--ok)" />gate ok · ship · deploy</span>
          <span className="flex items-center gap-1.5"><i className="size-2 rounded-full bg-(--bad)" />bloqueó · deploy rojo</span>
          <span className="flex items-center gap-1.5"><i className="size-2 rounded-full bg-(--wait)" />te espera</span>
          <span className="flex items-center gap-1.5"><i className="size-2 rounded-full bg-primary" />fase · decisión</span>
          {retro > 0 && <span className="ml-auto font-semibold text-(--wait)">{retro} retroceso{retro > 1 ? "s" : ""} detectado{retro > 1 ? "s" : ""}</span>}
        </div>
      </div>
      {/* tarjeta de hover: el evento completo, no un tooltip nativo */}
      {hv && (
        <div className="pointer-events-none absolute z-20 w-[300px] rounded-lg bg-popover p-3 text-popover-foreground shadow-md ring-1 ring-foreground/10"
          style={{ left: clampX(hv.px), top: hv.py - 12, transform: "translate(-50%,-100%)" }}>
          <div className="mb-1 flex items-baseline gap-2">
            <i className="size-2 shrink-0 translate-y-[-1px] rounded-full" style={{ background: hv.nd.color }} />
            <b className="text-[12px] capitalize">{hv.nd.label}</b>
            {hv.nd.sub && <span className="rounded border px-1 font-mono text-[9px] text-muted-foreground">{hv.nd.sub}</span>}
            {hv.nd.sha && <span className="rounded border px-1 font-mono text-[9px] text-muted-foreground">{hv.nd.sha}</span>}
            <span className="ml-auto font-mono text-[10px] text-muted-foreground">{fecha(hv.nd.ts)}</span>
          </div>
          <p className="line-clamp-6 text-[11.5px] leading-snug text-muted-foreground">{hv.nd.summary}</p>
          {onJump && <p className="mt-1.5 text-[9.5px] uppercase tracking-wide text-muted-foreground/50">clic → ver en la historia</p>}
        </div>
      )}
    </div>
  )
}
