// Marco común de cada pantalla del wizard: título, lede, contenido, fila de
// acciones y el banner de error del paso (con reintento). El estado viene del
// servidor; aquí solo se pinta y se mandan acciones.
import type { ReactNode } from "react"
import { Button } from "@/components/ui/button"
import { H2, Lede } from "@/components/bits"
import { LogTail } from "./log-tail"
import { initOp } from "./use-init"
import { RotateCcw, TriangleAlert } from "lucide-react"
import type { InitStep } from "@/lib/harness"

export function StepShell({ title, lede, steps, children, actions }: {
  title: string; lede?: ReactNode
  steps?: (InitStep | undefined)[] // pasos backend de esta pantalla (para error+logs)
  children?: ReactNode; actions?: ReactNode
}) {
  const failed = (steps || []).find((s) => s?.status === "fail")
  const logs = (steps || []).flatMap((s) => s?.logs_tail || [])
  return (
    <div className="min-w-0 flex-1">
      <H2>{title}</H2>
      {lede && <Lede>{lede}</Lede>}
      {failed && (
        <div className="mb-4 flex items-start gap-2.5 rounded-xl border border-(--bad)/40 bg-(--bad)/8 p-3.5">
          <TriangleAlert className="mt-0.5 size-4 shrink-0 text-(--bad)" />
          <div className="min-w-0 flex-1">
            <p className="text-[12.5px] font-medium text-(--bad)">El paso «{failed.title}» falló</p>
            {failed.error && <p className="mt-0.5 break-words font-mono text-[11.5px] text-muted-foreground">{failed.error}</p>}
          </div>
          <Button size="sm" variant="outline" className="shrink-0 gap-1.5"
            onClick={() => initOp("step", { step: failed.id, action: "retry" })}>
            <RotateCcw className="size-3.5" /> Reintentar
          </Button>
        </div>
      )}
      <div className="space-y-4">{children}</div>
      {logs.length > 0 && <LogTail lines={logs} />}
      {actions && <div className="mt-6 flex items-center justify-end gap-2.5">{actions}</div>}
    </div>
  )
}
