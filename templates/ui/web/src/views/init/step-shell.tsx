// Marco común de cada pantalla del wizard: título, lede, contenido, fila de
// acciones y el banner de error del paso (con reintento). El estado viene del
// servidor; aquí solo se pinta y se mandan acciones.
import type { ReactNode } from "react"
import { Button } from "@/components/ui/button"
import { H2, Lede } from "@/components/bits"
import { LogTail } from "./log-tail"
import { initOp } from "./use-init"
import { Loader2, RotateCcw, TriangleAlert } from "lucide-react"
import type { InitStep } from "@/lib/harness"

// elapsed — "hace cuánto corre" legible (el snapshot llega cada 2s: el
// re-render viene solo; sin esto un paso largo parece atascado).
function elapsed(started?: number): string {
  if (!started) return ""
  const s = Math.max(0, Math.floor(Date.now() / 1000 - started))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`
}

export function StepShell({ title, lede, steps, children, actions }: {
  title: string; lede?: ReactNode
  steps?: (InitStep | undefined)[] // pasos backend de esta pantalla (para error+logs)
  children?: ReactNode; actions?: ReactNode
}) {
  const failed = (steps || []).find((s) => s?.status === "fail")
  const running = (steps || []).find((s) => s?.status === "running")
  const logs = (steps || []).flatMap((s) => s?.logs_tail || [])
  return (
    <div className="min-w-0 flex-1">
      <H2>{title}</H2>
      {lede && <Lede>{lede}</Lede>}
      {running && (
        <div className="mb-4 flex items-center gap-2.5 rounded-xl border border-(--wait)/40 bg-(--wait)/8 p-3">
          <Loader2 className="size-4 shrink-0 animate-spin text-(--wait)" />
          <span className="text-[12.5px]">
            <b>{running.title}</b> corriendo{running.started ? <> · {elapsed(running.started)}</> : null} — el
            avance va apareciendo en la bitácora de abajo.
          </span>
        </div>
      )}
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
