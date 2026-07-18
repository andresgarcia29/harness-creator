// Mini file-browser del paso 1: navega SOLO directorios bajo tu home (la
// seguridad la impone el server; aquí solo se respeta). Breadcrumb + lista.
import { useEffect, useState } from "react"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Folder, CornerLeftUp, Loader2 } from "lucide-react"
import { initOp } from "../use-init"

type Listing = { ok: boolean; path?: string; parent?: string; dirs?: string[]; error?: string }

export function BrowseDialog({ open, onOpenChange, onPick }: {
  open: boolean; onOpenChange: (v: boolean) => void; onPick: (path: string) => void
}) {
  const [lst, setLst] = useState<Listing | null>(null)
  const [busy, setBusy] = useState(false)
  const nav = async (path: string) => {
    setBusy(true)
    setLst(await initOp("browse", { path }))
    setBusy(false)
  }
  useEffect(() => { if (open) nav("") }, [open])
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Elegir carpeta</DialogTitle>
          <DialogDescription className="font-mono text-[11.5px] break-all">
            {lst?.path || "…"}
          </DialogDescription>
        </DialogHeader>
        <ScrollArea className="h-64 rounded-xl border">
          <div className="p-1.5">
            {lst?.parent != null && lst.parent !== "" && (
              <button onClick={() => nav(lst.parent!)}
                className="flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-[12.5px] text-muted-foreground hover:bg-accent">
                <CornerLeftUp className="size-3.5" /> ..
              </button>
            )}
            {busy && <div className="grid place-items-center py-8"><Loader2 className="size-4 animate-spin text-muted-foreground" /></div>}
            {!busy && lst?.error && <p className="p-3 text-[12px] text-(--bad)">{lst.error}</p>}
            {!busy && lst?.dirs?.map((d) => (
              <button key={d} onClick={() => nav(`${lst.path}/${d}`)}
                className="flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-[12.5px] hover:bg-accent">
                <Folder className="size-3.5 text-muted-foreground" /> {d}
              </button>
            ))}
            {!busy && lst?.ok && lst.dirs?.length === 0 && (
              <p className="p-3 text-[12px] text-muted-foreground/60">sin subcarpetas</p>
            )}
          </div>
        </ScrollArea>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>Cancelar</Button>
          <Button disabled={!lst?.ok} onClick={() => { if (lst?.path) { onPick(lst.path); onOpenChange(false) } }}>
            Usar esta carpeta
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
