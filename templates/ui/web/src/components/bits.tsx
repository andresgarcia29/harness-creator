import type { ReactNode } from "react"
import { Card, CardContent } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Label } from "@/components/ui/label"
import { cn } from "@/lib/utils"
import { beats, supuesto, fecha, diaLabel, toEpoch, type Beat, type BusEvent } from "@/lib/harness"
import { CheckCircle2, CirclePause, CircleX, GitCommit, Lightbulb, Milestone } from "lucide-react"

// Cabecera de vista: título DM Sans + subtítulo — y en móvil deja aire al trigger
export function VHead({ title, sub, right, mono }: { title: ReactNode; sub?: ReactNode; right?: ReactNode; mono?: boolean }) {
  return (
    <div className="view-head mb-7 flex flex-wrap items-end gap-x-4 gap-y-2 pb-5">
      <div className="min-w-0 w-full sm:flex-1">
        <span className="mb-2 flex items-center gap-2 font-mono text-[9px] font-semibold uppercase tracking-[0.22em] text-(--brand)">
          <i className="h-px w-5 bg-(--brand)/70" /> Corvux intelligence
        </span>
        <h1 className={cn("t-display", mono && "font-mono tracking-normal")}>{title}</h1>
        {sub && <div className="mt-1.5 max-w-[72ch] text-[11.5px] leading-relaxed text-muted-foreground">{sub}</div>}
      </div>
      {right && <span className="flex w-full flex-wrap items-center gap-2 sm:w-auto sm:justify-end">{right}</span>}
    </div>
  )
}

export function H2({ children, sub }: { children: ReactNode; sub?: ReactNode }) {
  return (
    <h2 className="t-section mb-2 mt-8 flex flex-wrap items-baseline gap-2 first:mt-0">
      {children}
      {sub && <span className="normal-case tracking-normal text-muted-foreground/70">{sub}</span>}
    </h2>
  )
}

export function Lede({ children }: { children: ReactNode }) {
  return <p className="mb-3 max-w-[86ch] text-xs text-muted-foreground/80">{children}</p>
}

export function Code({ children }: { children: ReactNode }) {
  return <code className="rounded-md bg-secondary px-1.5 py-0.5 font-mono text-[11.5px] text-(--brand)">{children}</code>
}

// Stats: grid responsive (2 → 3 → 6 columnas)
export function Stats({ items }: { items: [ReactNode, ReactNode][] }) {
  return (
    <div className="mb-3 grid overflow-hidden rounded-2xl border border-border/80 bg-card shadow-(--shadow-soft)" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))" }}>
      {items.map(([v, l], i) => (
        <div key={i} className="relative border-b border-r border-border/70 p-4 last:border-r-0 lg:border-b-0">
          <i className="absolute inset-x-4 top-0 h-px bg-gradient-to-r from-transparent via-(--brand)/45 to-transparent" />
          <b className="block font-heading text-2xl font-semibold tracking-[-0.04em] tabular-nums">{v}</b>
          <i className="text-[9.5px] uppercase not-italic tracking-wider text-muted-foreground/70">{l}</i>
        </div>
      ))}
    </div>
  )
}

// Alerta derivada: ámbar = te espera · rose = un gate bloqueó
export function PendAlert({ kind, title, summary, hint, onClick }: {
  kind: "wait" | "block"; title: string; summary: string; hint?: string; onClick?: () => void
}) {
  const block = kind === "block"
  return (
    <Card
      onClick={onClick}
      className={cn(
        "mb-3.5 border py-0 transition-all",
        onClick && "cursor-pointer hover:-translate-y-px",
        block
          ? "border-(--bad)/40 bg-gradient-to-br from-(--bad)/15 to-(--bad)/4 hover:shadow-[0_4px_20px_rgba(225,29,72,.15)]"
          : "border-(--wait)/40 bg-gradient-to-br from-(--wait)/15 to-(--wait)/4 hover:shadow-[0_4px_20px_rgba(245,158,11,.12)]",
      )}
    >
      <CardContent className="flex items-start gap-4 p-4 sm:p-5">
        {block
          ? <CircleX className="mt-0.5 size-5 shrink-0 text-(--bad)" />
          : <CirclePause className="mt-0.5 size-5 shrink-0 text-(--wait)" />}
        <div className="min-w-0">
          <b className="block font-heading text-[15px] font-semibold tracking-tight">{title}</b>
          <p className="text-[13px] text-muted-foreground">{summary}</p>
          {hint && <i className="mt-1 block text-[11px] not-italic text-muted-foreground/60">{hint}</i>}
        </div>
      </CardContent>
    </Card>
  )
}

const beatDot: Record<Beat["k"], string> = {
  hard: "border-(--ok) bg-(--ok)",
  bad: "border-(--bad) bg-transparent shadow-[0_0_0_3px_rgba(225,29,72,.22)]",
  wait: "border-(--wait) bg-transparent shadow-[0_0_0_3px_rgba(245,158,11,.2)]",
  soft: "border-muted-foreground/60 bg-transparent",
}
const beatLbl: Record<Beat["k"], string> = {
  hard: "text-(--ok)", bad: "text-(--bad)", wait: "text-(--wait)", soft: "",
}

// La historia paso a paso — la línea que no se puede fingir.
// group=false: un beat por evento (el feed del dash mezcla tareas y ahí
// agrupar gates consecutivos mentiría sobre a quién pertenecen).
// dated: agrupa por día ("Hoy", "Ayer", "mié 17 jul") y muestra la fecha —
// sin esto, HH:MM solo es ambiguo cuando el trabajo cruza días.
export function Story({ evs, taskOf, onTask, group = true, dated = false, variant = "default" }: {
  evs: BusEvent[]; taskOf?: (b: number) => string; onTask?: (id: string) => void; group?: boolean; dated?: boolean
  variant?: "default" | "mission"
}) {
  const bs = group ? beats(evs) : evs.map((e) => beats([e])[0])
  let lastDay = ""
  if (variant === "mission") return (
    <div className="mission-story">
      {bs.map((b, i) => {
        const day = dated ? diaLabel(b.ts) : ""
        const showDay = dated && day !== lastDay
        if (showDay) lastDay = day
        const Icon = b.k === "hard" ? CheckCircle2 : b.k === "bad" ? CircleX : b.k === "wait" ? CirclePause
          : b.lbl === "Asumí" ? Lightbulb : b.lbl === "Decidí" ? GitCommit : Milestone
        const phase = b.lbl === "Fase" ? (b.p.toLowerCase().match(/\b(intake|rfc|implement|review|ship|deploy|archive)\b/) || [])[1] : ""
        const displayLabel = phase ? `Fase · ${phase}` : b.lbl
        return (
          <div key={i}>
            {showDay && <div className="mission-day"><span>{day}</span></div>}
            <article data-ts={b.ts} className={cn("mission-beat", `mission-beat-${b.k}`, onTask && "cursor-pointer")}
              onClick={onTask && taskOf ? () => onTask(taskOf(i)) : undefined}>
              <span className="mission-beat-icon"><Icon /></span>
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                  <span className="mission-beat-index">{String(i + 1).padStart(2, "0")}</span>
                  <span className={cn("mission-beat-label", beatLbl[b.k])}>{displayLabel}</span>
                  <time>{dated && toEpoch(b.ts) ? fecha(b.ts) : (b.ts || "").slice(11, 16)}</time>
                  {taskOf && <code>{taskOf(i)}</code>}
                </div>
                <p>{b.p}</p>
              </div>
            </article>
          </div>
        )
      })}
    </div>
  )
  return (
    <div className="ml-2 border-l-[1.5px] border-border">
      {bs.map((b, i) => {
        const day = dated ? diaLabel(b.ts) : ""
        const showDay = dated && day !== lastDay
        if (showDay) lastDay = day
        return (
          <div key={i}>
            {showDay && (
              <div className="relative -ml-[1.5px] mb-2 mt-1 border-l-[1.5px] border-transparent pl-6 first:mt-0">
                <span className="text-[10px] font-bold uppercase tracking-[0.12em] text-muted-foreground/50">{day}</span>
              </div>
            )}
            <div
              data-ts={b.ts}
              className={cn("relative pb-4 pl-6 last:pb-0.5", onTask && "cursor-pointer")}
              onClick={onTask && taskOf ? () => onTask(taskOf(i)) : undefined}
            >
              <span className={cn("absolute -left-[5.5px] top-1.5 size-2.5 rounded-full border-2", beatDot[b.k])} />
              <time className="mr-2 font-mono text-[10.5px] tabular-nums text-muted-foreground/60">
                {dated && toEpoch(b.ts) ? fecha(b.ts) : (b.ts || "").slice(11, 16)}
              </time>
              <span className={cn("text-[12.5px] font-bold", beatLbl[b.k])}>{b.lbl}</span>
              {taskOf && <span className="ml-2 font-mono text-[10px] text-muted-foreground/50">{taskOf(i)}</span>}
              <p className="mt-0.5 max-w-[96ch] text-xs text-muted-foreground">{b.p}</p>
            </div>
          </div>
        )
      })}
    </div>
  )
}

// Un supuesto estructurado del ledger
export function Sup({ text }: { text: string }) {
  const u = supuesto(text)
  return (
    <Card className="mb-2 border-l-[3px] border-l-primary/50 bg-secondary/60 py-0">
      <CardContent className="p-3.5">
        <b className="block text-[12.5px]">{u.q}</b>
        {u.why && <div className="mt-1 text-[11.5px] text-muted-foreground"><b className="text-[11px] uppercase tracking-wide text-muted-foreground/60">Por qué:</b> {u.why}</div>}
        {u.iff && <div className="text-[11.5px] text-muted-foreground"><b className="text-[11px] uppercase tracking-wide text-muted-foreground/60">Si resulta falso:</b> {u.iff}</div>}
      </CardContent>
    </Card>
  )
}

export function Empty({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <Card className="empty-state border-dashed py-0">
      <CardContent className="relative overflow-hidden p-7 sm:p-8">
        <div className="empty-signal" aria-hidden="true"><i/><i/><i/></div>
        <div className="relative z-10 pr-14 sm:pr-28">
          {title && <h4 className="mb-2 font-heading text-base font-bold tracking-tight">{title}</h4>}
          <div className="max-w-[76ch] space-y-1 text-[12.5px] leading-relaxed text-muted-foreground/80">{children}</div>
        </div>
      </CardContent>
    </Card>
  )
}

export function NumCell({ v, l, className }: { v: ReactNode; l: ReactNode; className?: string }) {
  return (
    <span className={cn("shrink-0 text-right font-mono text-xs tabular-nums text-muted-foreground", className)}>
      {v}
      <s className="block text-[9.5px] uppercase tracking-wide text-muted-foreground/60 no-underline">{l}</s>
    </span>
  )
}

export function StatusBadge({ on, children }: { on?: boolean; children: ReactNode }) {
  return (
    <Badge
      variant="outline"
      className={cn("rounded-full text-[9px] font-semibold uppercase tracking-wider",
        on && "border-(--ok)/40 bg-(--ok)/12 text-(--ok)")}
    >
      {children}
    </Badge>
  )
}

// Campo de formulario con label uppercase + hint — el patrón de Nueva tarea,
// extraído aquí porque el wizard de init lo usa en todos sus formularios.
export function Fld({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <div className="mb-4">
      <Label className="mb-1.5 block text-[10.5px] font-semibold uppercase tracking-wider text-muted-foreground">
        {label} {hint && <i className="font-normal normal-case tracking-normal not-italic text-muted-foreground/60">{hint}</i>}
      </Label>
      {children}
    </div>
  )
}
