// Paso 4 — Requisitos: checklist viva de dependencias. Instalar solo corre
// comandos del baseline del server (brew en macOS); lo demás se muestra como
// comando manual (sudo en Linux). Re-verificar es un clic.
import { useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { toast } from "sonner"
import { Code } from "@/components/bits"
import { CircleCheck, CircleDashed, CircleX, Loader2, RefreshCcw, Wrench } from "lucide-react"
import type { InitReq, InitState } from "@/lib/harness"
import { StepShell } from "../step-shell"
import { initOp, stepOf } from "../use-init"

export function RequirementsStep({ init }: { init: InitState }) {
  const [busy, setBusy] = useState(false)
  const step = stepOf(init, "requirements")
  const reqs = init.requirements || []

  useEffect(() => {
    if (!reqs.length) initOp("requirements-check")
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const verificar = async () => {
    setBusy(true)
    await initOp("requirements-check")
    setBusy(false)
  }
  const correr = async () => {
    const r = await initOp("step", { step: "requirements", action: step?.status === "fail" ? "retry" : "run" })
    if (!r.ok) toast.error(r.error)
  }
  const instalar = async (req: InitReq) => {
    const r = await initOp("install", { name: req.name })
    if (r.manual) toast.info(<span>córrelo a mano: <span className="font-mono">{r.command}</span></span>, { duration: 12000 })
    else if (!r.ok) toast.error(r.error)
  }

  const allOk = reqs.length > 0 && reqs.every((r) => r.ok || r.optional)
  return (
    <StepShell
      title="Requisitos"
      lede={<>Lo que el wizard y el harness necesitan en esta máquina. Las capacidades que
        elijas después (toolchains, CLIs de infra) se instalan en el <Code>make init</Code> de
        la instancia — aquí solo va el piso.</>}
      steps={[step]}
      actions={
        <>
          <Button variant="outline" disabled={busy} onClick={verificar} className="gap-1.5">
            {busy ? <Loader2 className="size-3.5 animate-spin" /> : <RefreshCcw className="size-3.5" />} Re-verificar
          </Button>
          <Button disabled={!allOk && step?.status !== "fail"} onClick={correr}>
            Confirmar y continuar
          </Button>
        </>
      }
    >
      <div className="divide-y rounded-2xl border">
        {reqs.map((r) => (
          <div key={r.name} className="flex items-center gap-3 px-3.5 py-2.5">
            {r.installing ? <Loader2 className="size-4 shrink-0 animate-spin text-(--wait)" />
              : r.ok ? <CircleCheck className="size-4 shrink-0 text-(--ok)" />
              : r.optional ? <CircleDashed className="size-4 shrink-0 text-muted-foreground/50" />
              : <CircleX className="size-4 shrink-0 text-(--bad)" />}
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-2">
                <span className="font-mono text-[13px]">{r.name}</span>
                {r.optional && <Badge variant="outline" className="text-[9.5px]">opcional</Badge>}
                {r.ok && r.version && <span className="truncate text-[10.5px] text-muted-foreground/60">{r.version}</span>}
              </div>
              <p className="truncate text-[11px] text-muted-foreground/70">{r.purpose}</p>
              {!r.ok && !r.auto_run && r.install && (
                <p className="mt-0.5 font-mono text-[10.5px] text-(--wait)">{r.install}</p>
              )}
            </div>
            {!r.ok && !r.installing && r.auto_run && (
              <Button size="sm" variant="outline" className="gap-1.5 shrink-0" onClick={() => instalar(r)}>
                <Wrench className="size-3.5" /> Instalar
              </Button>
            )}
          </div>
        ))}
        {reqs.length === 0 && (
          <div className="grid place-items-center p-6"><Loader2 className="size-4 animate-spin text-muted-foreground" /></div>
        )}
      </div>
    </StepShell>
  )
}
