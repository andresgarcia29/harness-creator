// Gráficas custom en SVG (el gantt de agentes no existe en ninguna librería
// de charts y la curva comparte su eje) — con los colores de marca Agora.
import { hhmm, dur, n, usd, who, type Agent } from "@/lib/harness"

const INDIGO = "#6366f1", INDIGO_L = "#818cf8", INDIGO_M = "#a5b4fc"

// Gantt: cuándo corrió cada agente; las barras que se solapan corrieron a la vez.
// En móvil scrollea horizontal dentro de su Card (min-width en el svg).
export function Gantt({ A, t0, t1, peak }: { A: Agent[]; t0: number; t1: number; peak: number }) {
  const rows = [...A].sort((a, b) => a.first_ts - b.first_ts)
  const W = 1000, LBL = 228, RH = 16, PAD = 6, CH = 48
  const span = Math.max(1, t1 - t0)
  const H = CH + 18 + rows.length * RH + PAD
  const x = (t: number) => LBL + ((t - t0) / span) * (W - LBL - 8)
  const N = 160, pts: [number, number][] = []
  for (let i = 0; i <= N; i++) {
    const t = t0 + span * (i / N)
    pts.push([x(t), A.filter((a) => a.first_ts <= t && a.last_ts >= t).length])
  }
  const cy = (v: number) => CH - (v / Math.max(1, peak)) * (CH - 8)
  const line = pts.map(([px, v], i) => (i ? "L" : "M") + px.toFixed(1) + " " + cy(v).toFixed(1)).join(" ")
  const area = `M${pts[0][0]} ${CH} ` + pts.map(([px, v]) => `L${px.toFixed(1)} ${cy(v).toFixed(1)}`).join(" ") + ` L${pts[pts.length - 1][0]} ${CH} Z`
  const step = span > 4 * 3600 ? 3600 : span > 3600 ? 1800 : 600
  const hrs: number[] = []
  for (let t = Math.ceil(t0 / step) * step; t <= t1; t += step) hrs.push(t)
  return (
    <div className="overflow-x-auto">
      <svg viewBox={`0 0 ${W} ${H}`} className="block w-full min-w-[720px]" style={{ height: Math.min(760, H) }}>
        <path d={area} fill={INDIGO} opacity={0.16} />
        <path d={line} stroke={INDIGO_L} strokeWidth={1.4} fill="none" opacity={0.9} />
        <text x={LBL - 6} y={cy(peak) + 3} fontSize={9.5} fontFamily="monospace" fontWeight={600} fill={INDIGO_M} textAnchor="end">{peak} a la vez</text>
        {hrs.map((t) => (
          <g key={t}>
            <line x1={x(t)} y1={CH + 4} x2={x(t)} y2={H - PAD} stroke="var(--border)" />
            <text x={x(t)} y={CH + 14} fontSize={9.5} fontFamily="monospace" fill="var(--muted-foreground)" opacity={0.7} textAnchor="middle">{hhmm(t)}</text>
          </g>
        ))}
        {rows.map((a, i) => {
          const y = CH + 18 + i * RH
          const w = Math.max(2.5, x(a.last_ts) - x(a.first_ts))
          return (
            <g key={a.id + i} className="[&:hover>rect]:opacity-100">
              <text x={LBL - 8} y={y + RH - 4} fontSize={10} fill="var(--muted-foreground)" textAnchor="end">{who(a).slice(0, 32)}</text>
              <rect x={x(a.first_ts)} y={y + 3} width={w} height={RH - 6} rx={2.5}
                fill={a.active ? INDIGO_L : a.id === "main" ? INDIGO_M : "var(--muted-foreground)"} opacity={a.active ? 1 : a.id === "main" ? 0.9 : 0.45}>
                <title>{`${who(a)} · ${dur(a.elapsed)} · ${n(a.usage.out)} tokens · ${usd(a.cost)}`}</title>
              </rect>
            </g>
          )
        })}
      </svg>
    </div>
  )
}
