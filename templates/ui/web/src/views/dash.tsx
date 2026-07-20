import { Card, CardContent } from "@/components/ui/card"
import { VHead, H2, Lede, Code, Story, Empty } from "@/components/bits"
import { cn } from "@/lib/utils"
import {
  BUSKINDS, usd, fecha, rel, taskRollup, pending, taskOfCwd,
  type Snapshot, type TaskStatus, type TaskRollup, type HerdrPane,
} from "@/lib/harness"
import { CirclePause, CircleX, Rocket, Loader, ArrowRight, Bot, TerminalSquare, Activity, Sparkles, BookOpen, Plus } from "lucide-react"
import type { Go } from "@/App"

const STATUS: Record<TaskStatus, { color: string; ring: string; Icon: typeof Rocket }> = {
  wait: { color: "text-(--wait)", ring: "border-(--wait)/40 bg-(--wait)/8", Icon: CirclePause },
  block: { color: "text-(--bad)", ring: "border-(--bad)/40 bg-(--bad)/8", Icon: CircleX },
  ship: { color: "text-(--ok)", ring: "border-(--ok)/40 bg-(--ok)/8", Icon: Rocket },
  work: { color: "text-(--brand)", ring: "border-primary/40 bg-primary/8", Icon: Loader },
}

// Métrica hero: número grande, clic navega. Lo primero que ves, de impacto.
function Metric({ label, value, sub, tone, pulse, onClick }: {
  label: string; value: string | number; sub: string
  tone: "ok" | "wait" | "brand" | "muted"; pulse?: boolean; onClick: () => void
}) {
  const tint = tone === "ok" ? "text-(--ok)" : tone === "wait" ? "text-(--wait)" : tone === "brand" ? "text-(--brand)" : "text-foreground"
  return (
    <button onClick={onClick}
      className="group flex flex-col gap-0.5 rounded-2xl border border-border bg-card p-4 text-left transition-all hover:border-primary/45 hover:shadow-[0_0_16px_rgba(99,102,241,.15)]">
      <span className="flex items-center gap-1.5 text-[10.5px] font-semibold uppercase tracking-wider text-muted-foreground/70">
        {pulse && <i className={cn("size-1.5 animate-pulse rounded-full", tone === "ok" ? "bg-(--ok)" : "bg-(--wait)")} />}
        {label}
      </span>
      <span className={cn("font-heading text-[30px] font-bold leading-none tracking-tight tabular-nums", tint)}>{value}</span>
      <span className="mt-0.5 flex items-center gap-1 text-[11px] text-muted-foreground/60">
        {sub}<ArrowRight className="size-3 opacity-0 transition-opacity group-hover:opacity-100" />
      </span>
    </button>
  )
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
    </button>
  )
}

// Una terminal viva: qué agente corre, en qué tarea, y si te espera. Clic → Terminales.
function LivePane({ p, go }: { p: HerdrPane; go: Go }) {
  const blocked = p.agent_status === "blocked"
  const task = taskOfCwd(p.foreground_cwd || p.cwd)
  const cwd = (p.foreground_cwd || p.cwd || "").split("/").filter(Boolean).pop() || "terminal"
  return (
    <button onClick={() => go({ name: "terminals" })}
      className={cn("group flex items-center gap-3 rounded-2xl border p-3.5 text-left transition-all hover:shadow-[0_0_16px_rgba(99,102,241,.12)]",
        blocked ? "border-(--bad)/40 bg-(--bad)/[0.06]" : "border-(--ok)/35 bg-(--ok)/[0.06]")}>
      <i className={cn("size-2 shrink-0 animate-pulse rounded-full", blocked ? "bg-(--bad)" : "bg-(--ok)")} />
      {p.program && (
        <span className="flex shrink-0 items-center gap-1 rounded-md border border-(--brand)/40 bg-(--brand)/10 px-1.5 py-0.5 text-[10px] font-semibold text-(--brand)">
          <Bot className="size-3" /> {p.program}
        </span>
      )}
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="truncate font-mono text-[12px] font-semibold">{task || cwd}</span>
          {task && <span className="shrink-0 font-mono text-[11px] text-(--brand)">◈ {task}</span>}
        </div>
        <p className="truncate text-[11.5px] text-muted-foreground/70">{blocked ? "te está esperando en su terminal" : task ? `avanzando ${task}` : `trabajando en ${cwd}`}</p>
      </div>
      <span className={cn("shrink-0 text-[9px] font-bold uppercase tracking-wider", blocked ? "text-(--bad)" : "text-(--ok)")}>
        {blocked ? "te espera" : "trabajando"}
      </span>
      <TerminalSquare className="size-3.5 shrink-0 text-muted-foreground/40" />
    </button>
  )
}

export function Dash({ s, go }: { s: Snapshot; go: Go }) {
  const hasAny = s.sessions.length || s.tasks.length || s.events.length
  if (!hasAny)
    return (
      <>
        <VHead title="Centro de control" sub="telemetría, decisiones y agentes en una sola superficie" />
        <div className="launchpad overflow-hidden rounded-[28px] border border-(--brand)/20 p-6 sm:p-9">
          <div className="grid items-center gap-9 lg:grid-cols-[minmax(0,1fr)_360px]">
            <div className="relative z-10">
              <span className="mb-4 inline-flex items-center gap-2 rounded-full border border-(--ok)/25 bg-(--ok)/8 px-3 py-1.5 text-[10px] font-semibold uppercase tracking-[0.14em] text-(--ok)">
                <Activity className="size-3 animate-pulse" /> Sistema listo
              </span>
              <h2 className="max-w-[650px] font-heading text-[clamp(30px,5vw,54px)] font-semibold leading-[.98] tracking-[-0.055em]">
                Tu ingeniería,<br/><span className="text-(--brand)">completamente observable.</span>
              </h2>
              <p className="mt-5 max-w-[58ch] text-[13px] leading-6 text-muted-foreground">
                Corvux convierte cada tarea, agente y decisión en una señal legible. Lanza el primer trabajo y observa cómo aparece su historia en tiempo real.
              </p>
              <div className="mt-7 flex flex-wrap gap-2.5">
                {s.op !== false && <button onClick={() => go({ name: "new" })} className="hero-action"><Plus className="size-4" /> Crear primera tarea <ArrowRight className="size-3.5" /></button>}
                <button onClick={() => go({ name: "docs" })} className="hero-action hero-action-ghost"><BookOpen className="size-4" /> Explorar la guía</button>
              </div>
            </div>
            <div className="signal-orbit" aria-hidden="true">
              <div className="orbit-ring orbit-ring-a"><i /></div>
              <div className="orbit-ring orbit-ring-b"><i /></div>
              <div className="orbit-core"><Sparkles className="size-8" /><span>LIVE</span></div>
              <span className="orbit-label orbit-label-a">AGENTS</span>
              <span className="orbit-label orbit-label-b">GATES</span>
              <span className="orbit-label orbit-label-c">LEDGER</span>
            </div>
          </div>
          <div className="mt-9 grid gap-px overflow-hidden rounded-2xl border border-border bg-border sm:grid-cols-3">
            {[["01", "Tareas", "Trabajo con trazabilidad"], ["02", "Sesiones", "Agentes en tiempo real"], ["03", "Decisiones", "Nada se pierde"]].map(([n, t, d]) => (
              <div key={n} className="bg-background/60 p-4 backdrop-blur-sm"><span className="font-mono text-[9px] text-(--brand)">{n}</span><b className="ml-2 text-[12px]">{t}</b><p className="mt-1 text-[10.5px] text-muted-foreground">{d}</p></div>
            ))}
          </div>
        </div>
      </>
    )

  const rollups = taskRollup(s)
  const waiting = rollups.filter((r) => r.status === "wait" || r.status === "block")
  const active = rollups.filter((r) => r.status !== "ship")
  const inCurso = active.filter((r) => r.status !== "wait" && r.status !== "block")
  const pend = pending(s)
  const busEvents = s.events.filter((e) => BUSKINDS.includes(e.kind))
  const lastEv = busEvents[busEvents.length - 1]
  const orphanStops = lastEv && lastEv.kind === "stop" && !lastEv.task ? [lastEv] : []
  const feed = busEvents.slice(-10).reverse()

  // Lo VIVO ahora, de herdr (verdad de campo): terminales trabajando / bloqueadas.
  const panes = s.herdr?.panes || []
  const working = panes.filter((p) => p.agent_status === "working")
  const blocked = panes.filter((p) => p.agent_status === "blocked")
  const live = [...blocked, ...working]

  // Costo de HOY (los días vienen en UTC, como los agrega el daemon).
  const todayUTC = new Date(s.ts * 1000).toISOString().slice(0, 10)
  const costToday = s.days?.find((d) => d.day === todayUTC)?.cost ?? null
  const needYou = pend.length + orphanStops.length + blocked.length

  return (
    <>
      <VHead title="Resumen" sub="lo que importa de esta máquina · en vivo" />

      {/* Métricas hero — de impacto, clicables */}
      <div className="mb-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Metric label="Trabajando ahora" value={working.length} sub="terminales activas" tone="ok" pulse={working.length > 0} onClick={() => go({ name: "terminals" })} />
        <Metric label="Te esperan" value={needYou} sub="decisiones pendientes" tone={needYou > 0 ? "wait" : "muted"} pulse={needYou > 0} onClick={() => go({ name: "tasks" })} />
        <Metric label="Costo hoy" value={usd(costToday)} sub="lo que va del día" tone="brand" onClick={() => go({ name: "costs" })} />
        <Metric label="En curso" value={inCurso.length} sub="tareas avanzando" tone="muted" onClick={() => go({ name: "tasks" })} />
      </div>

      {/* 1 · Qué necesita TU decisión, en grande */}
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
            {inCurso.length ? `${inCurso.length} tarea${inCurso.length > 1 ? "s" : ""} en curso, ninguna frenada en ti.` : "Si algo necesita tu decisión, aparecerá aquí en grande."}
          </p>
        </CardContent></Card>
      )}

      {/* 2 · Ahora mismo — las terminales vivas (herdr) */}
      {live.length > 0 && (
        <>
          <H2 sub="clic para abrir su terminal en vivo">Ahora mismo</H2>
          <div className="mb-2 grid gap-2.5 lg:grid-cols-2">
            {live.map((p) => <LivePane key={p.pane_id} p={p} go={go} />)}
          </div>
        </>
      )}

      {/* 3 · En curso: una tarjeta por tarea viva */}
      {inCurso.length > 0 && (
        <>
          <H2 sub="clic para ver el hilo completo — qué razonó y por qué">En curso</H2>
          <div className="grid gap-2.5 lg:grid-cols-2">
            {inCurso.map((r) => <TaskCard key={r.id} r={r} go={go} />)}
          </div>
        </>
      )}

      {/* 4 · Costo — últimos días (de impacto, no vanidad) */}
      {s.days && s.days.length > 1 && (
        <>
          <H2 sub="lo que costó cada día · clic para el desglose">Gasto reciente</H2>
          <Card className="py-0"><CardContent className="p-4">
            <DaysBars days={s.days} onClick={() => go({ name: "costs" })} />
          </CardContent></Card>
        </>
      )}

      {/* 5 · Feed cronológico */}
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

// Barras de gasto por día (últimos ~14). Simple SVG-less: divs proporcionales.
function DaysBars({ days, onClick }: { days: NonNullable<Snapshot["days"]>; onClick: () => void }) {
  const last = days.slice(-14)
  const max = Math.max(...last.map((d) => d.cost || 0), 0.0001)
  return (
    <button onClick={onClick} className="flex w-full items-end gap-1.5" style={{ height: 88 }}>
      {last.map((d) => {
        const h = Math.max(3, ((d.cost || 0) / max) * 78)
        return (
          <div key={d.day} className="group/bar flex min-w-0 flex-1 flex-col items-center justify-end gap-1" title={`${d.day}: ${usd(d.cost)}`}>
            <span className="text-[9px] tabular-nums text-muted-foreground/0 transition-colors group-hover/bar:text-muted-foreground/70">{usd(d.cost)}</span>
            <div className={cn("w-full rounded-t transition-colors", d.unpriced ? "bg-muted-foreground/25" : "bg-(--brand)/60 group-hover/bar:bg-(--brand)")} style={{ height: h }} />
            <span className="w-full truncate text-center text-[8.5px] text-muted-foreground/50">{d.day.slice(5)}</span>
          </div>
        )
      })}
    </button>
  )
}
