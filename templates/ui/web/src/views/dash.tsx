import { Card, CardContent } from "@/components/ui/card"
import { VHead, H2, Lede, Code, Stats, Story, Empty } from "@/components/bits"
import { ConcChart } from "@/components/charts-recharts"
import { cn } from "@/lib/utils"
import {
  BUSKINDS, n, usd, fecha, rel, taskRollup,
  type Snapshot, type TaskStatus, type TaskRollup,
} from "@/lib/harness"
import { CirclePause, CircleX, Rocket, Loader, ArrowRight } from "lucide-react"
import type { Go } from "@/App"

const STATUS: Record<TaskStatus, { color: string; ring: string; Icon: typeof Rocket }> = {
  wait: { color: "text-(--wait)", ring: "border-(--wait)/40 bg-(--wait)/8", Icon: CirclePause },
  block: { color: "text-(--bad)", ring: "border-(--bad)/40 bg-(--bad)/8", Icon: CircleX },
  ship: { color: "text-(--ok)", ring: "border-(--ok)/40 bg-(--ok)/8", Icon: Rocket },
  work: { color: "text-(--brand)", ring: "border-primary/40 bg-primary/8", Icon: Loader },
}

// Una tarjeta por tarea: dónde va, qué la detiene AHORA, qué decidió, cuándo.
function TaskCard({ r, go }: { r: TaskRollup; go: Go }) {
  const st = STATUS[r.status]
  return (
    <button onClick={() => go({ name: "task", id: r.id })}
      className="group flex w-full flex-col gap-2 rounded-2xl border border-border bg-card p-4 text-left transition-all hover:border-primary/45 hover:shadow-[0_0_16px_rgba(99,102,241,.15)]">
      <div className="flex flex-wrap items-center gap-2">
        <span className={cn("flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[10px] font-bold uppercase tracking-wider", st.ring, st.color)}>
          <st.Icon className={cn("size-3", r.status === "work" && "animate-spin")} /> {r.statusLabel}
        </span>
        <span className="font-mono text-[12.5px] font-semibold text-(--brand)">{r.id}</span>
        {r.phase && <span className="rounded-md bg-secondary px-2 py-0.5 font-mono text-[10.5px] text-muted-foreground">{r.phase}</span>}
        <span className="ml-auto font-mono text-[11px] text-muted-foreground/60">{rel(r.lastTs)}</span>
      </div>
      {r.title && <p className="text-[13px] font-medium">{r.title}</p>}
      <p className="line-clamp-2 text-[12.5px] leading-relaxed text-muted-foreground">
        <span className={cn("font-semibold", st.color)}>{r.status === "wait" ? "Esperándote: " : r.status === "block" ? "Frenada: " : "Ahora: "}</span>
        {r.waitingOn || (r.nEvents ? "—" : "sin actividad en el bus todavía")}
      </p>
      {r.lastDecision && (
        <p className="line-clamp-1 border-l-2 border-border pl-2.5 text-[11.5px] italic text-muted-foreground/70">
          última decisión — {r.lastDecision}
        </p>
      )}
      <span className="mt-0.5 flex items-center gap-1 text-[11px] font-medium text-(--brand) opacity-0 transition-opacity group-hover:opacity-100">
        ver el hilo completo <ArrowRight className="size-3" />
      </span>
    </button>
  )
}

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
  const rollups = taskRollup(s)
  const waiting = rollups.filter((r) => r.status === "wait" || r.status === "block")
  const active = rollups.filter((r) => r.status !== "ship")
  const busEvents = s.events.filter((e) => BUSKINDS.includes(e.kind))
  // parada SIN tarea: el bus a veces emite un stop sin task id. La subimos SOLO
  // si es lo último que pasó en todo el bus — así no fingimos que algo espera
  // cuando en realidad ya siguió (no la podemos ligar a su sesión para saberlo).
  const lastEv = busEvents[busEvents.length - 1]
  const orphanStops = lastEv && lastEv.kind === "stop" && !lastEv.task ? [lastEv] : []
  const feed = busEvents.slice(-10).reverse()

  return (
    <>
      <VHead title="Resumen" sub="todo el espacio de trabajo · en vivo" />

      {/* 1 · Lo primero: qué necesita TU decisión, en grande */}
      {waiting.length + orphanStops.length > 0 ? (
        <>
          <H2>Necesita tu decisión <span className="rounded-full bg-(--wait)/15 px-2 py-0.5 text-(--wait)">{waiting.length + orphanStops.length}</span></H2>
          <div className="mb-2 grid gap-2.5">
            {waiting.map((r) => <TaskCard key={r.id} r={r} go={go} />)}
            {orphanStops.map((e, i) => (
              <Card key={"o" + i} className="border-(--wait)/40 bg-(--wait)/8 py-0">
                <CardContent className="flex items-start gap-3 p-4">
                  <CirclePause className="mt-0.5 size-4 shrink-0 text-(--wait)" />
                  <div>
                    <b className="text-[13.5px]">Una sesión te espera <span className="font-normal text-muted-foreground/60">· sin tarea asociada</span></b>
                    <p className="text-[12.5px] text-muted-foreground">{e.summary}</p>
                    <i className="mt-0.5 block text-[11px] not-italic text-muted-foreground/50">{fecha(e.ts)} — respóndele en su terminal o en Sesiones.</i>
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        </>
      ) : (
        <Card className="mb-2 py-0"><CardContent className="p-4 sm:p-5">
          <b className="font-heading text-sm font-semibold">Nada te espera ahora mismo.</b>
          <p className="mt-0.5 text-[12.5px] text-muted-foreground">
            {active.length ? `${active.length} tarea${active.length > 1 ? "s" : ""} en curso, ninguna frenada en ti.` : "Si algo necesita tu decisión, aparecerá aquí en grande."}
          </p>
        </CardContent></Card>
      )}

      {/* 2 · En curso: una tarjeta por tarea viva (no las ya en main) */}
      {active.length > 0 && (
        <>
          <H2 sub="clic para ver el hilo completo — qué razonó y por qué">En curso</H2>
          <div className="grid gap-2.5 lg:grid-cols-2">
            {active.filter((r) => r.status !== "wait" && r.status !== "block").map((r) => <TaskCard key={r.id} r={r} go={go} />)}
          </div>
        </>
      )}

      {/* 3 · Signos vitales del espacio */}
      <H2>Signos vitales</H2>
      <Stats items={[
        [acts, "agentes vivos"], [s.sessions.length, "sesiones"], [rollups.length, "tareas"],
        [n(s.tokens.out), "tokens out"], [n(s.tokens.cache_read), "leídos de caché"], [usd(s.cost), "costo est."],
      ]} />
      <H2 sub="últimas 6 horas · todo el espacio">Agentes trabajando a la vez</H2>
      <Card className="py-0"><CardContent className="p-4"><ConcChart sessions={s.sessions} now={s.ts} /></CardContent></Card>

      {/* 4 · Feed cronológico con fechas */}
      <H2 sub="lo más reciente arriba · con su fecha">Últimas decisiones del harness</H2>
      <Lede>Lo que el sistema decidió o no dejó pasar. Clic en una para abrir su tarea.</Lede>
      {feed.length ? (
        <Card className="py-0"><CardContent className="p-5">
          <Story evs={feed} group={false} dated taskOf={(i) => feed[i]?.task || ""} onTask={(id) => id && go({ name: "task", id })} />
        </CardContent></Card>
      ) : (
        <Empty><p>El bus está vacío. Se llena solo cuando <Code>ship.sh</Code> o <Code>/auto</Code> trabajan en este workspace.</p></Empty>
      )}
    </>
  )
}
