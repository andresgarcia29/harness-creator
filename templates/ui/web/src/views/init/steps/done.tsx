// Paso 9 — Fin: el doctor como verificación final determinista, el resumen
// de lo construido, y los pendientes (bootstrap de secretos, ratificar DRAFTs).
import { Button } from "@/components/ui/button"
import { toast } from "sonner"
import { Code, Stats } from "@/components/bits"
import { CircleCheck, Loader2, PartyPopper, Server, Stethoscope } from "lucide-react"
import type { Go } from "@/App"
import type { InitState } from "@/lib/harness"
import { setTarget } from "@/lib/target"
import { StepShell } from "../step-shell"
import { initOp, stepOf } from "../use-init"

export function DoneStep({ init, go }: { init: InitState; go: Go }) {
  const step = stepOf(init, "finish")
  const finished = !init.active || step?.status === "ok"
  const nAgents = init.answers?.clusters.length || 0
  const nRepos = init.repos?.length || init.inventory?.repo_count || 0
  const nCaps = init.answers?.capabilities?.length || 0
  const source = init.answers?.secrets.source || "env"

  return (
    <StepShell
      title={finished ? "Gracias — tu harness está vivo" : "Verificación final"}
      lede={finished
        ? <>Todo lo de aquí es editable después: answers, agentes, MCPs, modelos. Los fixes del
          instalador llegan con <Code>harness update</Code>.</>
        : <>El doctor verifica TODO — archivos, hooks, agentes, secretos — y cada fallo trae su
          remediación exacta. En verde, el plano de instalación se apaga y quedan las leyes de
          siempre: a main solo por <Code>ship.sh</Code>.</>}
      steps={[step]}
      actions={!finished && (
        <Button disabled={step?.status === "running"} onClick={async () => {
          const r = await initOp("step", { step: "finish", action: step?.status === "fail" ? "retry" : "run" })
          if (!r.ok) toast.error(r.error)
        }} className="gap-1.5">
          {step?.status === "running" ? <Loader2 className="size-3.5 animate-spin" /> : <Stethoscope className="size-3.5" />}
          Correr el doctor y terminar
        </Button>
      )}
    >
      <Stats items={[
        ["workspace", <Code key="w">{init.workspace_path || "—"}</Code>],
        ["repos", String(nRepos)],
        ["agentes", String(nAgents)],
        ["capacidades", String(nCaps)],
      ]} />
      <div className="space-y-2 rounded-2xl border p-4 text-[12.5px]">
        <p className="font-medium">Pendientes después del wizard</p>
        <ul className="list-disc space-y-1 pl-5 text-muted-foreground">
          <li><b>Ratificar los DRAFT</b> — constituciones de abogados, constitution.md y specs:
            la arqueología propuso; la ley la firman humanos. Es la primera parada de <Code>/auto</Code>.</li>
          <li><b>Secretos ({source})</b> — <Code>make init</Code> en una terminal del workspace:
            instala deps de capacidades, pide credenciales interactivo (jamás por chat) y
            materializa <Code>.secrets</Code>.</li>
          <li><b>Versionar el meta-repo</b> — <Code>git init && git add -A && git commit</Code> si
            elegiste <Code>self</Code>: el harness se versiona a sí mismo.</li>
        </ul>
      </div>
      {finished && (
        <div className="flex items-center gap-3 rounded-2xl border border-(--ok)/35 bg-(--ok)/8 p-4">
          <PartyPopper className="size-5 shrink-0 text-(--ok)" />
          <div className="flex-1 text-[13px]">
            <p className="font-medium">Instalación completa.</p>
            <p className="text-muted-foreground">
              {init.target
                ? <>El harness vive en <b>{init.target}</b> — el panel lo observa por SSH (selector de máquina).</>
                : <>El panel ya observa tu workspace; el día a día es <Code>/auto</Code>.</>}
            </p>
          </div>
          <div className="flex shrink-0 flex-col gap-1.5">
            <Button className="gap-1.5" onClick={() => {
              if (init.target) setTarget(init.target) // el panel entero muta a la máquina del harness
              go({ name: "dash" })
            }}>
              {init.target ? <Server className="size-3.5" /> : <CircleCheck className="size-3.5" />}
              {init.target ? `Ir al panel de ${init.target}` : "Ir al panel"}
            </Button>
            <Button variant="ghost" size="sm" className="text-[11.5px] text-muted-foreground"
              onClick={async () => {
                const r = await initOp("restart")
                if (!r.ok) toast.error(r.error)
              }}>
              Empezar otra instalación
            </Button>
          </div>
        </div>
      )}
    </StepShell>
  )
}
