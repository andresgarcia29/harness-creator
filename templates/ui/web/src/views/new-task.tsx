import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Textarea } from "@/components/ui/textarea"
import { toast } from "sonner"
import { VHead, H2, Code, Fld } from "@/components/bits"
import { op, type Snapshot } from "@/lib/harness"
import type { Go } from "@/App"

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
      <VHead title="Nueva tarea" sub={<>se lanza con <Code>/auto</Code> — pasa por los mismos gates que todo lo demás</>} />
      <H2>Qué hay que hacer</H2>
      <Fld label="Título">
        <Input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Permitir reagendar bookings desde el widget" />
      </Fld>
      <Fld label="Contexto" hint="(opcional, cuanto más mejor)">
        <Textarea value={ctx} onChange={(e) => setCtx(e.target.value)} className="min-h-24"
          placeholder="Qué problema resuelve, criterios de aceptación si los sabes, qué queda fuera de scope…" />
      </Fld>
      <Fld label="Origen">
        <Select value={origin} onValueChange={(v) => v != null && setOrigin(v)}>
          <SelectTrigger className="w-full"><SelectValue>
            {origin === "ticket" ? "Ticket — se enlaza a un ticket existente" : "Prompt directo — lo escribes aquí y arranca ya"}
          </SelectValue></SelectTrigger>
          <SelectContent>
            <SelectItem value="prompt">Prompt directo — lo escribes aquí y arranca ya</SelectItem>
            <SelectItem value="ticket">Ticket — se enlaza a un ticket existente</SelectItem>
          </SelectContent>
        </Select>
      </Fld>
      {origin === "ticket" && (
        <Fld label="Ticket"><Input value={ticket} onChange={(e) => setTicket(e.target.value)} placeholder="COR-123" /></Fld>
      )}
      <H2>Cómo debe trabajar</H2>
      <div className="grid gap-x-4 sm:grid-cols-2">
        <Fld label="Modelo preferido">
          <Select value={model || "auto"} onValueChange={(v) => setModel(v ?? "")}>
            <SelectTrigger className="w-full"><SelectValue>
              {model && model !== "auto" ? model : "según models.yaml (recomendado)"}
            </SelectValue></SelectTrigger>
            <SelectContent>
              <SelectItem value="auto">según models.yaml (recomendado)</SelectItem>
              {models.map((m) => <SelectItem key={m} value={m}>{m}</SelectItem>)}
            </SelectContent>
          </Select>
        </Fld>
        <Fld label="Prioridad">
          <Select value={prio} onValueChange={(v) => v != null && setPrio(v)}>
            <SelectTrigger className="w-full"><SelectValue /></SelectTrigger>
            <SelectContent>{["P0", "P1", "P2", "P3"].map((p) => <SelectItem key={p} value={p}>{p}</SelectItem>)}</SelectContent>
          </Select>
        </Fld>
        <Fld label="Agentes en paralelo (máx.)">
          <Input type="number" min={1} max={12} value={par} onChange={(e) => setPar(e.target.value)} />
        </Fld>
        <Fld label="Presupuesto máximo" hint="(USD, estimado)">
          <Input type="number" value={budget} onChange={(e) => setBudget(e.target.value)} placeholder="sin límite" />
        </Fld>
      </div>
      <label className="mb-2.5 flex cursor-pointer items-start gap-2.5 text-[12.5px] text-muted-foreground">
        <Checkbox checked={asum} onCheckedChange={(v) => setAsum(v === true)} className="mt-0.5" />
        <span>Puede hacer supuestos — cada uno queda en el ledger con su evidencia. Si lo apagas, cada ambigüedad será una parada que te espera.</span>
      </label>
      <label className="mb-5 flex cursor-pointer items-start gap-2.5 text-[12.5px] text-muted-foreground">
        <Checkbox checked={review} onCheckedChange={(v) => setReview(v === true)} className="mt-0.5" />
        <span>Pídeme revisión antes de publicar — se detendrá antes del primer ship a main hasta que des el visto bueno.</span>
      </label>
      <Button onClick={crear} disabled={busy}>{busy ? "…" : "Crear tarea"}</Button>
    </>
  )
}
