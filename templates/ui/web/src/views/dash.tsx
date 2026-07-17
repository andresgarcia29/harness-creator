import { Card, CardContent } from "@/components/ui/card"
import { VHead, H2, Lede, Code, Stats, PendAlert, Story, Empty } from "@/components/bits"
import { ConcChart } from "@/components/charts"
import { BUSKINDS, n, usd, pending, type Snapshot } from "@/lib/harness"
import type { Go } from "@/App"

export function Dash({ s, go }: { s: Snapshot; go: Go }) {
  const acts = s.sessions.reduce((x, y) => x + y.n_active, 0)
  const hasAny = s.sessions.length || s.tasks.length || s.events.length
  if (!hasAny)
    return (
      <>
        <VHead title="Resumen" sub="todo el espacio de trabajo · en vivo" />
        <Empty title="Todavía no hay nada que observar">
          <p><b className="text-foreground/80">Tareas</b> — aparecen cuando llegue un ticket o cuando corras <Code>/auto</Code>.</p>
          <p><b className="text-foreground/80">Sesiones</b> — aparecen cuando un agente empiece a trabajar en el repositorio.</p>
          <p><b className="text-foreground/80">Alertas</b> — si algo necesita una decisión tuya, lo verás en grande.</p>
        </Empty>
      </>
    )
  const pend = pending(s).slice(-2)
  const evs = s.events.filter((e) => BUSKINDS.includes(e.kind)).slice(-8).reverse()
  return (
    <>
      <VHead title="Resumen" sub="todo el espacio de trabajo · en vivo" />
      {pend.length ? (
        pend.map((e) => (
          <PendAlert key={e.task} kind={e._k} onClick={() => go({ name: "task", id: e.task! })}
            title={`${e._k === "block" ? "Un gate bloqueó" : "Te está esperando"} — ${e.task}`}
            summary={e.summary}
            hint="Es lo último que registró esa tarea; nada ha pasado después. Clic para ver su historia." />
        ))
      ) : (
        <Card className="mb-3.5 py-0"><CardContent className="p-4 sm:p-5">
          <b className="font-heading text-sm font-semibold">Nada te espera ahora mismo.</b>
          <p className="mt-0.5 text-[12.5px] text-muted-foreground">Si algo necesita tu decisión, aparecerá aquí en grande.</p>
        </CardContent></Card>
      )}
      <Stats items={[
        [acts, "agentes vivos"], [s.sessions.length, "sesiones"], [s.tasks.length, "tareas"],
        [n(s.tokens.out), "tokens out"], [n(s.tokens.cache_read), "leídos de caché"], [usd(s.cost), "costo est."],
      ]} />
      <H2 sub="últimas 6 horas · todo el espacio">Agentes trabajando a la vez</H2>
      <Card className="py-0"><CardContent className="p-4"><ConcChart sessions={s.sessions} now={s.ts} /></CardContent></Card>
      <H2>Últimas decisiones del harness</H2>
      <Lede>Lo que el sistema decidió o no dejó pasar — el texto llega por turno. Clic en una para ver su tarea completa.</Lede>
      {evs.length ? (
        <Card className="py-0"><CardContent className="p-5">
          <Story evs={evs} group={false} taskOf={(i) => evs[i]?.task || ""} onTask={(id) => id && go({ name: "task", id })} />
        </CardContent></Card>
      ) : (
        <Empty><p>El bus está vacío. Se llena solo cuando <Code>ship.sh</Code> o <Code>/auto</Code> trabajan en este workspace.</p></Empty>
      )}
    </>
  )
}
