// Acciones de ABRIR en herdr: workspace nuevo, terminal (tab) nueva, dividir un
// pane. Todo persiste por naturaleza de herdr (sobrevive al detach). Cada una
// pasa por op/herdr-open (guardas + validación del padre en el snapshot).
import { useState, type ReactNode } from "react"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog"
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { toast } from "sonner"
import { op } from "@/lib/harness"
import { Plus, SquarePlus, SplitSquareVertical, SplitSquareHorizontal, TerminalSquare } from "lucide-react"

async function open(body: Record<string, unknown>, ok: string) {
  const r = await op("/api/op/herdr-open", body)
  if (r.ok) toast.success(ok)
  else toast.error(r.error || "no se pudo abrir")
  return r.ok
}

// Botón + diálogo: workspace nuevo (label + cwd opcionales).
export function NewWorkspace() {
  const [openD, setOpenD] = useState(false)
  const [label, setLabel] = useState("")
  const [cwd, setCwd] = useState("")
  const [busy, setBusy] = useState(false)
  const create = async () => {
    setBusy(true)
    const ok = await open({ action: "new-workspace", label, cwd }, `Workspace «${label || "nuevo"}» abierto.`)
    setBusy(false)
    if (ok) { setOpenD(false); setLabel(""); setCwd("") }
  }
  return (
    <Dialog open={openD} onOpenChange={setOpenD}>
      <DialogTrigger render={<Button size="sm" variant="outline" className="h-8" />}>
        <Plus className="size-3.5" /> Nuevo workspace
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Nuevo workspace de herdr</DialogTitle>
          <DialogDescription>Un grupo aislado de terminales, como una ventana nueva. Persiste aunque cierres la terminal.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <Input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="nombre (ej. corvux-frontend)" autoFocus />
          <Input value={cwd} onChange={(e) => setCwd(e.target.value)} placeholder="carpeta (opcional, ruta absoluta)" className="font-mono text-[12px]" />
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={() => setOpenD(false)} disabled={busy}>Cancelar</Button>
          <Button onClick={create} disabled={busy}>{busy ? "…" : "Abrir workspace"}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// Item de menú: terminal (tab) nueva en un workspace.
export function NewTerminalItem({ wsId }: { wsId: string }) {
  return (
    <DropdownMenuItem onClick={() => open({ action: "new-terminal", workspace_id: wsId }, "Terminal nueva abierta.")}>
      <TerminalSquare className="size-3.5" /> Terminal nueva aquí
    </DropdownMenuItem>
  )
}

// Items de menú de un pane: dividir a la derecha / abajo.
export function SplitItems({ paneId }: { paneId: string }) {
  return (
    <>
      <DropdownMenuItem onClick={() => open({ action: "split-pane", pane: paneId, direction: "right" }, "Dividido a la derecha.")}>
        <SplitSquareHorizontal className="size-3.5" /> Dividir a la derecha
      </DropdownMenuItem>
      <DropdownMenuItem onClick={() => open({ action: "split-pane", pane: paneId, direction: "down" }, "Dividido abajo.")}>
        <SplitSquareVertical className="size-3.5" /> Dividir abajo
      </DropdownMenuItem>
    </>
  )
}

// Menú "abrir" genérico de un workspace (trigger propio).
export function WorkspaceOpenMenu({ wsId, trigger }: { wsId: string; trigger: ReactNode }) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger className="grid size-6 place-items-center rounded-md text-muted-foreground/50 transition-colors hover:bg-accent hover:text-foreground" title="abrir aquí">
        {trigger}
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start">
        <NewTerminalItem wsId={wsId} />
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

export const OpenIcon = SquarePlus
