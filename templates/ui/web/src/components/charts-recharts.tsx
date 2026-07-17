// Gráficas con el Chart de shadcn (recharts): tooltips, leyendas y colores por
// CSS vars — funcionan en dark y light sin tocar nada. Los datos son REALES:
// las barras apiladas usan el desglose por modelo que calcula el server, no
// proporciones inventadas.
import { Area, AreaChart, Bar, BarChart, CartesianGrid, Cell, Pie, PieChart, XAxis, YAxis } from "recharts"
import {
  ChartContainer, ChartLegend, ChartLegendContent, ChartTooltip, ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart"
import { hhmm, usd, type Session, type Snapshot } from "@/lib/harness"

const PALETTE = ["var(--chart-1)", "var(--chart-2)", "var(--chart-3)", "var(--chart-4)", "var(--chart-5)"]
const key = (m: string) => m.replace(/[^a-zA-Z0-9-]/g, "-")

// ── Concurrencia (últimas 6 h) ────────────────────────────────────────────
export function ConcChart({ sessions, now }: { sessions: Session[]; now: number }) {
  const A = sessions.flatMap((x) => x.agents).filter((a) => a.first_ts && a.last_ts)
  if (!A.length) return <p className="text-xs text-muted-foreground/60">Sin actividad de agentes todavía.</p>
  const t0 = now - 6 * 3600
  const N = 180
  const data = Array.from({ length: N + 1 }, (_, i) => {
    const t = t0 + 6 * 3600 * (i / N)
    return { t, v: A.filter((a) => a.first_ts <= t && a.last_ts >= t).length }
  })
  const peak = Math.max(1, ...data.map((d) => d.v))
  const cur = A.filter((a) => a.active).length
  const ticks = Array.from({ length: 6 }, (_, i) => Math.ceil(t0 / 3600) * 3600 + i * 3600).filter((t) => t <= now)
  const config = { v: { label: "agentes", color: "var(--chart-1)" } } satisfies ChartConfig
  return (
    <div>
      <div className="mb-1 flex justify-between font-mono text-[10px] font-semibold text-(--brand)">
        <span>pico {peak}</span><span>ahora {cur}</span>
      </div>
      <ChartContainer config={config} className="h-[130px] w-full">
        <AreaChart data={data} margin={{ top: 4, right: 4, left: 4, bottom: 0 }}>
          <defs>
            <linearGradient id="conc" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="var(--chart-1)" stopOpacity={0.35} />
              <stop offset="100%" stopColor="var(--chart-1)" stopOpacity={0.03} />
            </linearGradient>
          </defs>
          <CartesianGrid vertical={false} strokeOpacity={0.35} />
          <XAxis dataKey="t" type="number" domain={[t0, now]} ticks={ticks} tickFormatter={hhmm}
            tickLine={false} axisLine={false} tick={{ fontSize: 9.5, fontFamily: "monospace" }} />
          <YAxis hide domain={[0, peak]} allowDecimals={false} />
          <ChartTooltip content={<ChartTooltipContent labelFormatter={(_, p) => hhmm(p?.[0]?.payload?.t ?? 0)} />} />
          <Area dataKey="v" type="monotone" stroke="var(--chart-1)" strokeWidth={1.6} fill="url(#conc)" isAnimationActive={false} />
        </AreaChart>
      </ChartContainer>
    </div>
  )
}

// ── Gasto por día, APILADO por modelo ────────────────────────────────────
export function DayCostChart({ s }: { s: Snapshot }) {
  const days = (s.days || []).slice(-10)
  if (!days.length) return <p className="text-xs text-muted-foreground/60">Sin días con actividad todavía.</p>
  // top 4 modelos por gasto total; el resto se apila como "otros"
  const totals: Record<string, number> = {}
  for (const d of days) for (const [m, c] of Object.entries(d.by_model || {})) totals[m] = (totals[m] || 0) + c
  const top = Object.entries(totals).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([m]) => m)
  const data = days.map((d) => {
    const row: Record<string, unknown> = { day: d.day.slice(5), _unpriced: d.unpriced, _total: d.cost || 0 }
    let otros = 0
    for (const [m, c] of Object.entries(d.by_model || {})) {
      if (top.includes(m)) row[key(m)] = c
      else otros += c
    }
    if (otros > 0) row.otros = otros
    return row
  })
  const hasOtros = data.some((r) => r.otros != null)
  const series = [...top.map(key), ...(hasOtros ? ["otros"] : [])]
  const config = Object.fromEntries(
    series.map((k, i) => [k, { label: k === "otros" ? "otros" : top[i], color: PALETTE[i % PALETTE.length] }]),
  ) satisfies ChartConfig
  return (
    <div>
      <ChartContainer config={config} className="h-[240px] w-full">
        <BarChart data={data} margin={{ top: 18, right: 4, left: 4, bottom: 0 }}>
          <CartesianGrid vertical={false} strokeOpacity={0.35} />
          <XAxis dataKey="day" tickLine={false} axisLine={false} tick={{ fontSize: 9.5, fontFamily: "monospace" }} />
          <YAxis hide />
          <ChartTooltip content={<ChartTooltipContent
            formatter={(value, name, item, index) => (
              <>
                <div className="size-2.5 shrink-0 rounded-[2px]" style={{ background: item.color }} />
                {config[name as string]?.label || name}
                <div className="ml-auto font-mono font-medium tabular-nums">{usd(Number(value))}</div>
                {index === (item.payload._last ?? -1) && null}
              </>
            )} />} />
          <ChartLegend content={<ChartLegendContent />} />
          {series.map((k, i) => (
            <Bar key={k} dataKey={k} stackId="d" fill={`var(--color-${k})`}
              radius={i === series.length - 1 ? [4, 4, 0, 0] : [0, 0, 0, 0]} isAnimationActive={false} />
          ))}
        </BarChart>
      </ChartContainer>
      {days.some((d) => d.unpriced) && (
        <p className="mt-1.5 text-[11.5px] text-muted-foreground/70">
          Hay días con modelos sin precio: esas barras son un piso, no el total.
        </p>
      )}
    </div>
  )
}

// ── Distribución del gasto por modelo (dona) ─────────────────────────────
export function ModelShareChart({ s }: { s: Snapshot }) {
  const models = (s.models || []).filter((m) => m.cost != null && m.cost > 0)
  if (!models.length) return null
  const data = models.map((m, i) => ({ name: m.model, value: m.cost as number, fill: PALETTE[i % PALETTE.length] }))
  const total = data.reduce((a, b) => a + b.value, 0)
  const config = Object.fromEntries(data.map((d) => [d.name, { label: d.name }])) satisfies ChartConfig
  return (
    <ChartContainer config={config} className="mx-auto aspect-square max-h-[210px] w-full">
      <PieChart>
        <ChartTooltip content={<ChartTooltipContent
          formatter={(value, name) => (
            <>
              {name}
              <div className="ml-auto font-mono font-medium tabular-nums">
                {usd(Number(value))} · {((Number(value) / total) * 100).toFixed(0)}%
              </div>
            </>
          )} />} />
        <Pie data={data} dataKey="value" nameKey="name" innerRadius={55} outerRadius={82}
          paddingAngle={2} strokeWidth={0} isAnimationActive={false}>
          {data.map((d) => <Cell key={d.name} fill={d.fill} />)}
        </Pie>
        <text x="50%" y="47%" textAnchor="middle" className="fill-foreground font-mono text-lg font-semibold">
          {usd(total)}
        </text>
        <text x="50%" y="58%" textAnchor="middle" className="fill-muted-foreground text-[9px] uppercase tracking-wider">
          cotizable
        </text>
      </PieChart>
    </ChartContainer>
  )
}
