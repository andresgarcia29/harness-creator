import { useState, type ReactNode } from "react"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Textarea } from "@/components/ui/textarea"
import { toast } from "sonner"
import { cn } from "@/lib/utils"
import { op, type Snapshot } from "@/lib/harness"
import { ArrowLeft, ArrowRight, Bot, Check, CircleDollarSign, Cpu, GitPullRequest, Lightbulb, ListChecks, Rocket, ShieldCheck, Sparkles, Ticket, Users } from "lucide-react"
import type { Go } from "@/App"

function Field({ label, hint, children, className }: { label: string; hint?: string; children: ReactNode; className?: string }) {
  return <div className={cn("new-task-field", className)}><div className="mb-2 flex items-baseline justify-between gap-3"><label>{label}</label>{hint && <span>{hint}</span>}</div>{children}</div>
}

export function NewTask({ s, go }: { s: Snapshot; go: Go }) {
  const models = Object.keys(s.prices || {})
  const [title, setTitle] = useState("")
  const [ctx, setCtx] = useState("")
  const [origin, setOrigin] = useState("prompt")
  const [ticket, setTicket] = useState("")
  const [model, setModel] = useState("")
  const [prio, setPrio] = useState("P2")
  const [par, setPar] = useState("3")
  const [budget, setBudget] = useState("")
  const [asum, setAsum] = useState(true)
  const [review, setReview] = useState(false)
  const [busy, setBusy] = useState(false)
  const ready = title.trim().length > 2 && (origin !== "ticket" || ticket.trim().length > 0)

  const crear = async () => {
    setBusy(true)
    const r = await op("/api/op/task", {
      title, context: ctx, origin, ticket, model: model === "auto" ? "" : model, priority: prio,
      max_parallel: +par || 3, budget, assumptions_ok: asum, review_before_ship: review,
    })
    setBusy(false)
    if (r.ok) {
      toast.success(`Lanzada como ${r.id} · sesión ${r.session.slice(0, 8)}… — aparecerá sola en Sesiones.`)
      setTimeout(() => go({ name: "task", id: r.id }), 1200)
    } else toast.error("No se lanzó: " + r.error)
  }

  return (
    <>
      <section className="new-task-hero overflow-hidden rounded-3xl border border-border/80">
        <div className="relative z-10 p-5 sm:p-7">
          <button onClick={() => go({ name: "tasks" })} className="mb-6 inline-flex items-center gap-2 text-[9px] font-bold uppercase tracking-[0.15em] text-muted-foreground hover:text-foreground"><ArrowLeft className="size-3.5" />Volver a tareas</button>
          <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_270px] lg:items-end">
            <div>
              <span className="mb-3 inline-flex items-center gap-1.5 rounded-full border border-(--brand)/20 bg-(--brand)/8 px-2.5 py-1 text-[8px] font-bold uppercase tracking-[0.14em] text-(--brand)"><Sparkles className="size-3" />Command request</span>
              <h1 className="font-heading text-[clamp(30px,4vw,48px)] font-[690] leading-none tracking-[-0.05em]">Orquesta una nueva misión.</h1>
              <p className="mt-3 max-w-[62ch] text-[12.5px] leading-relaxed text-muted-foreground">Describe el resultado. Corvux crea el plan, coordina agentes y conserva cada decisión hasta llegar a main.</p>
            </div>
            <div className="new-task-workspace">
              <span><Bot />Destino operativo</span><b>{s.workspace?.name || "workspace actual"}</b><small>Se ejecutará con <code>/auto</code> y los gates configurados.</small>
            </div>
          </div>
        </div>
      </section>

      <div className="mt-5 grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_310px]">
        <div className="space-y-4">
          <section className="new-task-card">
            <div className="new-task-card-head"><span>01</span><div><h2>Define el resultado</h2><p>Qué debe cambiar y cómo sabremos que quedó bien.</p></div></div>
            <div className="p-5 sm:p-6">
              <Field label="Título de la misión" hint={`${title.length}/120`}>
                <Input value={title} maxLength={120} onChange={(e) => setTitle(e.target.value)} className="h-11 text-[13px]" placeholder="Ej. Permitir reagendar bookings desde el widget" autoFocus />
              </Field>
              <Field label="Contexto y criterios" hint="Opcional · recomendado" className="mt-5">
                <Textarea value={ctx} onChange={(e) => setCtx(e.target.value)} className="min-h-36 resize-y leading-relaxed" placeholder={"Explica el problema, el resultado esperado y los criterios de aceptación.\n\nIncluye también qué queda fuera de alcance o restricciones importantes."} />
              </Field>
              <div className="mt-5 grid gap-4 sm:grid-cols-2">
                <Field label="Origen">
                  <Select value={origin} onValueChange={(v) => v != null && setOrigin(v)}><SelectTrigger className="w-full"><SelectValue>{origin === "ticket" ? "Ticket existente" : "Prompt directo"}</SelectValue></SelectTrigger><SelectContent><SelectItem value="prompt">Prompt directo — comienza ahora</SelectItem><SelectItem value="ticket">Ticket — enlazar trabajo existente</SelectItem></SelectContent></Select>
                </Field>
                {origin === "ticket" ? <Field label="Identificador del ticket"><Input value={ticket} onChange={(e) => setTicket(e.target.value)} placeholder="COR-123" /></Field> : <div className="new-task-context-note"><Ticket /><span><b>Inicio inmediato</b><small>La descripción será la fuente de verdad inicial.</small></span></div>}
              </div>
            </div>
          </section>

          <section className="new-task-card">
            <div className="new-task-card-head"><span>02</span><div><h2>Configura la ejecución</h2><p>Controla capacidad, urgencia y límites de la misión.</p></div></div>
            <div className="grid gap-4 p-5 sm:grid-cols-2 sm:p-6">
              <Field label="Modelo preferido"><Select value={model || "auto"} onValueChange={(v) => setModel(v ?? "")}><SelectTrigger className="w-full"><SelectValue>{model && model !== "auto" ? model : "Selección automática"}</SelectValue></SelectTrigger><SelectContent><SelectItem value="auto">Selección automática · recomendado</SelectItem>{models.map((m) => <SelectItem key={m} value={m}>{m}</SelectItem>)}</SelectContent></Select></Field>
              <Field label="Prioridad"><Select value={prio} onValueChange={(v) => v != null && setPrio(v)}><SelectTrigger className="w-full"><SelectValue /></SelectTrigger><SelectContent>{["P0", "P1", "P2", "P3"].map((p) => <SelectItem key={p} value={p}>{p}</SelectItem>)}</SelectContent></Select></Field>
              <Field label="Agentes en paralelo" hint="1–12"><Input type="number" min={1} max={12} value={par} onChange={(e) => setPar(e.target.value)} /></Field>
              <Field label="Presupuesto máximo" hint="USD estimado"><Input type="number" value={budget} onChange={(e) => setBudget(e.target.value)} placeholder="Sin límite" /></Field>
            </div>
          </section>

          <section className="new-task-card">
            <div className="new-task-card-head"><span>03</span><div><h2>Define los guardrails</h2><p>Decide cuándo puede avanzar y cuándo debe esperarte.</p></div></div>
            <div className="grid gap-3 p-5 sm:grid-cols-2 sm:p-6">
              <label className={cn("guardrail-card", asum && "is-on")}><Checkbox checked={asum} onCheckedChange={(v) => setAsum(v === true)} /><span><Lightbulb /><b>Supuestos trazables</b><small>Puede decidir con evidencia; cada supuesto queda registrado.</small></span>{asum && <Check className="guardrail-check" />}</label>
              <label className={cn("guardrail-card", review && "is-on")}><Checkbox checked={review} onCheckedChange={(v) => setReview(v === true)} /><span><GitPullRequest /><b>Revisión antes de ship</b><small>Se detendrá antes de publicar para pedir tu aprobación.</small></span>{review && <Check className="guardrail-check" />}</label>
            </div>
          </section>
        </div>

        <aside className="launch-summary xl:sticky xl:top-20">
          <div className="flex items-center gap-3 border-b border-border/65 p-5"><span className="grid size-10 place-items-center rounded-xl bg-(--brand) text-white shadow-[0_12px_28px_-12px_var(--brand-glow)]"><Rocket className="size-4" /></span><div><span className="block text-[7.5px] font-bold uppercase tracking-[0.15em] text-(--brand)">Launch control</span><h2 className="font-heading text-[15px] font-bold tracking-tight">Resumen de misión</h2></div></div>
          <div className="space-y-1 p-4">
            <div className="launch-summary-row"><Cpu /><span>Modelo</span><b>{model && model !== "auto" ? model : "Automático"}</b></div>
            <div className="launch-summary-row"><ListChecks /><span>Prioridad</span><b>{prio}</b></div>
            <div className="launch-summary-row"><Users /><span>Paralelismo</span><b>{+par || 3} agentes</b></div>
            <div className="launch-summary-row"><CircleDollarSign /><span>Presupuesto</span><b>{budget ? `$${budget}` : "Sin límite"}</b></div>
            <div className="launch-summary-row"><ShieldCheck /><span>Gate humano</span><b>{review ? "Antes de ship" : "Estándar"}</b></div>
          </div>
          <div className="border-t border-border/65 p-4">
            <div className={cn("mb-3 flex items-center gap-2 rounded-xl border px-3 py-2.5 text-[10px]", ready ? "border-(--ok)/20 bg-(--ok)/8 text-(--ok)" : "border-(--wait)/20 bg-(--wait)/8 text-(--wait)")}><i className={cn("size-1.5 rounded-full", ready ? "bg-(--ok)" : "bg-(--wait)")} /><span>{ready ? "Lista para lanzar" : "Agrega un título para continuar"}</span></div>
            <Button onClick={crear} disabled={busy || !ready} className="h-11 w-full rounded-xl bg-(--brand) text-white hover:bg-(--brand-strong)">{busy ? "Lanzando misión…" : <>Lanzar misión <ArrowRight className="size-3.5" /></>}</Button>
            <p className="mt-3 text-center text-[8.5px] leading-relaxed text-muted-foreground/55">Al lanzar, se abrirá una sesión y podrás seguir cada agente en tiempo real.</p>
          </div>
        </aside>
      </div>
    </>
  )
}
