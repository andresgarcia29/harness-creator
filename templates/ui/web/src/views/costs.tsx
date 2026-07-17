import { Alert, AlertDescription } from "@/components/ui/alert"
import { Card, CardContent } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { VHead, H2, Code, Stats, Empty, NumCell } from "@/components/bits"
import { n, usd, type Snapshot } from "@/lib/harness"
import { TriangleAlert } from "lucide-react"
import type { Go } from "@/App"

const HBar = ({ pct }: { pct: number }) => (
  <div className="h-1 rounded-full bg-gradient-to-r from-primary to-(--brand)" style={{ width: `${Math.max(2, pct)}%`, minWidth: 2 }} />
)

export function Costs({ s, go }: { s: Snapshot; go: Go }) {
  const days = (s.days || []).slice(-7)
  const maxD = Math.max(0.01, ...days.map((d) => d.cost || 0))
  const models = s.models || []
  const maxM = Math.max(0.01, ...models.map((m) => m.cost || 0))
  const sess = [...s.sessions].sort((a, b) => (b.cost || 0) - (a.cost || 0)).slice(0, 8)
  const maxS = Math.max(0.01, ...sess.map((x) => x.cost || 0))
  const prices = s.prices || {}
  return (
    <>
      <VHead title="Gastos" sub={<>todo el espacio de trabajo · el costo es un <b>estimado</b>; la báscula oficial es <Code>ccusage</Code></>} />
      {s.unpriced && s.unpriced.length > 0 && (
        <Alert className="mb-3.5 border-(--wait)/45 bg-amber-950/20 text-muted-foreground">
          <TriangleAlert className="text-(--wait)" />
          <AlertDescription className="text-[12.5px] text-muted-foreground">
            Sin precio en <Code>pricing.json</Code>: <b className="text-foreground">{s.unpriced.join(", ")}</b> — sus
            costos muestran «—». Los tokens son reales; el dinero no se inventa.
          </AlertDescription>
        </Alert>
      )}
      <Stats items={[
        [usd(s.cost), "total observado"], [n(s.tokens.out), "tokens out"],
        [n(s.tokens.cache_read), "leídos de caché (~10× más baratos)"],
      ]} />
      <H2 sub="días con actividad observada">Gasto estimado por día</H2>
      <Card className="py-0"><CardContent className="p-4">
        {days.length ? (
          <>
            <div className="flex h-[120px] items-end gap-2.5">
              {days.map((d) => (
                <div key={d.day} className="flex flex-1 flex-col justify-end gap-1.5 text-center">
                  <span className="font-mono text-[10.5px] text-muted-foreground">{usd(d.cost)}{d.unpriced ? "*" : ""}</span>
                  <div className="rounded-t bg-gradient-to-b from-(--brand) to-primary" style={{ height: Math.max(3, ((d.cost || 0) / maxD) * 84) }} />
                  <span className="font-mono text-[9.5px] text-muted-foreground/60">{d.day.slice(5)}</span>
                </div>
              ))}
            </div>
            {days.some((d) => d.unpriced) && <p className="mt-2.5 text-[11.5px] text-muted-foreground/70">* ese día incluye modelos sin precio.</p>}
          </>
        ) : (
          <p className="text-xs text-muted-foreground/60">Sin días con actividad todavía.</p>
        )}
      </CardContent></Card>
      <H2>Por modelo</H2>
      <div className="overflow-x-auto">
        <Table>
          <TableHeader><TableRow>
            <TableHead>Modelo</TableHead><TableHead className="text-right">in</TableHead>
            <TableHead className="text-right">out</TableHead><TableHead className="text-right">caché lee</TableHead>
            <TableHead className="text-right">caché escribe</TableHead><TableHead className="text-right">$ est.</TableHead>
            <TableHead className="w-[90px]" />
          </TableRow></TableHeader>
          <TableBody>
            {models.length ? models.map((m) => (
              <TableRow key={m.model}>
                <TableCell className="font-mono text-xs">{m.model}</TableCell>
                <TableCell className="text-right font-mono tabular-nums">{n(m.in)}</TableCell>
                <TableCell className="text-right font-mono tabular-nums">{n(m.out)}</TableCell>
                <TableCell className="text-right font-mono tabular-nums text-muted-foreground/60">{n(m.cache_read)}</TableCell>
                <TableCell className="text-right font-mono tabular-nums text-muted-foreground/60">{n(m.cache_creation)}</TableCell>
                <TableCell className="text-right font-mono tabular-nums">{usd(m.cost)}</TableCell>
                <TableCell><HBar pct={((m.cost || 0) / maxM) * 100} /></TableCell>
              </TableRow>
            )) : (
              <TableRow><TableCell colSpan={7} className="text-muted-foreground/60">Sin datos.</TableCell></TableRow>
            )}
          </TableBody>
        </Table>
      </div>
      <H2 sub="cada una por separado">Sesiones que más han gastado</H2>
      <div className="grid gap-2.5">
        {sess.map((x) => (
          <button key={x.id} onClick={() => go({ name: "session", id: x.id })}
            className="flex w-full min-w-0 items-center gap-3.5 overflow-hidden rounded-xl border border-white/8 bg-card p-3.5 px-4 text-left transition-all hover:border-primary/45 hover:shadow-[0_0_10px_rgba(99,102,241,.2)]">
            <span className="shrink-0 font-mono text-[12.5px] font-semibold text-(--brand)">{x.short}</span>
            <span className="hidden min-w-0 flex-1 truncate text-xs text-muted-foreground/80 sm:block">{(x.last_text || "").slice(0, 110)}</span>
            <NumCell v={n(x.tokens.out)} l="tokens" />
            <NumCell v={usd(x.cost)} l="est." />
            <span className="w-[120px] shrink-0"><HBar pct={((x.cost || 0) / maxS) * 100} /></span>
          </button>
        ))}
      </div>
      <H2 sub={<>$ por millón de tokens · edítala en <Code>scripts/ui/pricing.json</Code> — el panel la relee sola</>}>Tabla de precios</H2>
      <div className="max-w-[520px]">
        <Table>
          <TableHeader><TableRow>
            <TableHead>Modelo</TableHead><TableHead className="text-right">input</TableHead><TableHead className="text-right">output</TableHead>
          </TableRow></TableHeader>
          <TableBody>
            {Object.entries(prices).map(([m, p]) => (
              <TableRow key={m}>
                <TableCell className="font-mono text-xs">{m}</TableCell>
                <TableCell className="text-right font-mono tabular-nums">${p.input.toFixed(2)}</TableCell>
                <TableCell className="text-right font-mono tabular-nums">${p.output.toFixed(2)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
      <p className="mt-2.5 max-w-[86ch] text-[11.5px] leading-relaxed text-muted-foreground/70">
        Un modelo que no esté en la tabla (GLM, Kimi, el que uses) muestra «—» hasta que agregues su precio — y al
        agregarlo, el histórico se re-cotiza solo. Caché: lectura ~0.1×, escritura 1.25×.
      </p>
      {!days.length && !models.length && <Empty><p>Sin actividad todavía.</p></Empty>}
    </>
  )
}
