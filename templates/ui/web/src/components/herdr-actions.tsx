// Acciones de ciclo de vida de herdr (interrumpir / cerrar). Son DESTRUCTIVAS,
// así que todo pasa por un diálogo de confirmación — nada se cierra de un clic
// accidental. El id se re-valida en el daemon contra el snapshot vivo.
import { useState } from "react"
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { cn } from "@/lib/utils"
import { op } from "@/lib/harness"
import { toast } from "sonner"
import { MoreHorizontal, OctagonX, SquareX, Trash2 } from "lucide-react"

type Action = { action: string; id: string; verb: string; danger?: boolean }

function useConfirm() {
  const [pending, setPending] = useState<{ a: Action; title: string; body: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const run = async () => {
    if (!pending) return
    setBusy(true)
    const r = await op("/api/op/herdr", { action: pending.a.action, id: pending.a.id })
    setBusy(false)
    setPending(null)
    if (r.ok) toast.success(pending.a.verb + " — listo.")
    else toast.error(r.error || "no se pudo")
  }
  const dialog = (
    <AlertDialog open={!!pending} onOpenChange={(o) => !o && setPending(null)}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{pending?.title}</AlertDialogTitle>
          <AlertDialogDescription>{pending?.body}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={busy}>Cancelar</AlertDialogCancel>
          <AlertDialogAction onClick={(e) => { e.preventDefault(); run() }} disabled={busy}
            className={cn(pending?.a.danger && "bg-(--bad) text-white hover:bg-(--bad)/90")}>
            {busy ? "…" : pending?.title}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
  const ask = (a: Action, title: string, body: string) => setPending({ a, title, body })
  return { ask, dialog }
}

// Menú de una VENTANA (pane): interrumpir o cerrar.
export function PaneActions({ paneId, label, running }: { paneId: string; label: string; running: boolean }) {
  const { ask, dialog } = useConfirm()
  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger
          onClick={(e) => e.stopPropagation()}
          title="acciones de esta terminal"
          className="grid size-6 shrink-0 place-items-center rounded-md text-white/40 transition-colors hover:bg-white/10 hover:text-white/80">
          <MoreHorizontal className="size-4" />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" onClick={(e) => e.stopPropagation()}>
          {running && (
            <DropdownMenuItem onClick={() => ask(
              { action: "interrupt", id: paneId, verb: "interrumpí el proceso" },
              "Interrumpir (Ctrl-C)",
              `Manda Ctrl-C a «${label}». Corta el proceso que corre, pero la terminal sigue abierta.`)}>
              <OctagonX className="size-3.5 text-(--wait)" /> Interrumpir (Ctrl-C)
            </DropdownMenuItem>
          )}
          <DropdownMenuItem variant="destructive" onClick={() => ask(
            { action: "close-pane", id: paneId, verb: "cerré la terminal", danger: true },
            "Cerrar terminal",
            `Cierra «${label}» y mata su proceso. No se puede deshacer.`)}>
            <SquareX className="size-3.5" /> Cerrar terminal
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      {dialog}
    </>
  )
}

// Menú de un WORKSPACE de herdr: cerrarlo entero.
export function WorkspaceActions({ wsId, label }: { wsId: string; label: string }) {
  const { ask, dialog } = useConfirm()
  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger
          title="acciones del workspace"
          className="grid size-6 place-items-center rounded-md text-muted-foreground/50 transition-colors hover:bg-accent hover:text-foreground">
          <MoreHorizontal className="size-4" />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="start">
          <DropdownMenuItem variant="destructive" onClick={() => ask(
            { action: "close-workspace", id: wsId, verb: "cerré el workspace", danger: true },
            "Cerrar workspace",
            `Cierra el workspace «${label}» de herdr y TODOS sus panes. No se puede deshacer.`)}>
            <Trash2 className="size-3.5" /> Cerrar workspace entero
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      {dialog}
    </>
  )
}
