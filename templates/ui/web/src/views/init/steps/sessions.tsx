// Paso 8 — Primeras sesiones: crear la primera tarea (va por el plano de
// operar normal: /api/op/task → claude -p "/auto <id>"). Saltable.
import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { toast } from "sonner"
import { Fld, Code } from "@/components/bits"
import { Loader2, Play } from "lucide-react"
import { op, type InitState } from "@/lib/harness"
import { StepShell } from "../step-shell"
import { initOp, stepOf } from "../use-init"

export function SessionsStep({ init }: { init: InitState }) {
  const step = stepOf(init, "first-task")
  const [title, setTitle] = useState("")
  const [ctx, setCtx] = useState("")
  const [busy, setBusy] = useState(false)

  if (init.target) {
    return (
      <StepShell
        title="Tu primera tarea"
        lede={<>El harness vive en <b>{init.target}</b>: las tareas se lanzan ALLÁ (con
          <Code>harness ui</Code> en el VPS, o un túnel SSH al panel remoto). Salta este paso
          y termina la instalación.</>}
        steps={[step]}
        actions={
          <Button variant="outline" onClick={() => initOp("step", { step: "first-task", action: "skip" })}>
            Saltar — las lanzo en el VPS
          </Button>
        }
      />
    )
  }

  const crear = async () => {
    setBusy(true)
    const r = await op("/api/op/task", {
      title, context: ctx, origin: "prompt", priority: "P2",
      max_parallel: 3, assumptions_ok: true, review_before_ship: true, target: "",
    })
    setBusy(false)
    if (!r.ok) { toast.error(r.error || "no se lanzó"); return }
    toast.success(`Lanzada como ${r.id} — corre /auto con checkpoint antes del primer ship`)
    setTitle("")
    setCtx("")
    const r2 = await initOp("step", { step: "first-task", action: "run" })
    if (!r2.ok) toast.error(r2.error)
  }

  return (
    <StepShell
      title="Tu primera tarea"
      lede={<>Ya puedes crear trabajo: la tarea corre <Code>/auto</Code> — intake, RFC,
        implementación, review — con los gates puestos. Con <Code>checkpoint</Code> te pedirá
        un «go» antes del primer ship a main. También puedes saltar esto y crearla después
        desde <b>Nueva tarea</b>.</>}
      steps={[step]}
      actions={
        <>
          {step?.status !== "ok" && (
            <Button variant="ghost" onClick={() => initOp("step", { step: "first-task", action: "skip" })}>
              Saltar por ahora
            </Button>
          )}
          <Button disabled={busy || !title.trim()} onClick={crear} className="gap-1.5">
            {busy ? <Loader2 className="size-3.5 animate-spin" /> : <Play className="size-3.5" />} Crear y lanzar
          </Button>
        </>
      }
    >
      <Fld label="Título">
        <Input value={title} onChange={(e) => setTitle(e.target.value)}
          placeholder="algo chico y real: arregla el typo del README del servicio X" />
      </Fld>
      <Fld label="Contexto" hint="(opcional)">
        <Textarea value={ctx} onChange={(e) => setCtx(e.target.value)} className="min-h-20"
          placeholder="criterios de aceptación si los sabes, qué queda fuera de scope…" />
      </Fld>
    </StepShell>
  )
}
