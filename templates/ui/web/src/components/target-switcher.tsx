// Selector de MÁQUINA: local o un VPS por SSH. Cambia qué herdr ves en
// Terminales (y a dónde van las acciones). Agregar un VPS sólo pide un alias de
// ~/.ssh/config o user@host — la llave la maneja OpenSSH, el panel nunca toca
// credenciales. El daemon corre `ssh <destino> herdr …` con quoting a prueba de
// inyección; el navegador manda el NOMBRE, nunca un comando.
import { useState } from "react"
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel,
  DropdownMenuSeparator, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { cn } from "@/lib/utils"
import { toast } from "sonner"
import { op, type HerdrTarget } from "@/lib/harness"
import { useTarget } from "@/lib/target"
import { Monitor, Server, Check, Plus, Trash2, ChevronsUpDown } from "lucide-react"

export function TargetSwitcher({ targets }: { targets: HerdrTarget[] }) {
  const [active, setActive] = useTarget()
  const [addOpen, setAddOpen] = useState(false)
  const current = active ? targets.find((t) => t.name === active) : undefined
  const label = active ? (current?.name || active) : "esta máquina"

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger className="flex h-8 items-center gap-1.5 rounded-md border border-border bg-card px-2.5 text-[12px] font-medium transition-colors hover:bg-accent">
          {active ? <Server className="size-3.5 text-(--brand)" /> : <Monitor className="size-3.5 text-muted-foreground" />}
          <span className="max-w-[140px] truncate">{label}</span>
          <ChevronsUpDown className="size-3 text-muted-foreground/60" />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="min-w-[220px]">
          <DropdownMenuLabel className="text-[11px] text-muted-foreground/70">Máquina que ves</DropdownMenuLabel>
          <DropdownMenuItem onClick={() => setActive("")}>
            <Monitor className="size-3.5" /> esta máquina (local)
            {!active && <Check className="ml-auto size-3.5 text-(--ok)" />}
          </DropdownMenuItem>
          {targets.length > 0 && <DropdownMenuSeparator />}
          {targets.map((t) => (
            <DropdownMenuItem key={t.name} onClick={() => setActive(t.name)}>
              <Server className="size-3.5 text-(--brand)" />
              <span className="min-w-0 flex-1 truncate">{t.name}</span>
              <span className="ml-1 truncate font-mono text-[10px] text-muted-foreground/50">{t.ssh}</span>
              <button onClick={(e) => { e.stopPropagation(); removeTarget(t.name, active, setActive) }}
                title="quitar este destino" className="ml-1 rounded p-0.5 text-muted-foreground/50 hover:text-(--bad)">
                <Trash2 className="size-3" />
              </button>
              {active === t.name && <Check className="size-3.5 text-(--ok)" />}
            </DropdownMenuItem>
          ))}
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={() => setAddOpen(true)}>
            <Plus className="size-3.5" /> Agregar VPS…
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      <AddTargetDialog open={addOpen} onOpenChange={setAddOpen} onAdded={(name) => setActive(name)} />
    </>
  )
}

async function removeTarget(name: string, active: string, setActive: (t: string) => void) {
  const r = await op("/api/op/targets", { action: "remove", name, target: "" })
  if (r.ok) {
    toast.success(`Destino «${name}» quitado.`)
    if (active === name) setActive("") // si veías ese, vuelve a local
  } else toast.error(r.error || "no se pudo quitar")
}

function AddTargetDialog({ open, onOpenChange, onAdded }: {
  open: boolean; onOpenChange: (o: boolean) => void; onAdded: (name: string) => void
}) {
  const [name, setName] = useState("")
  const [ssh, setSsh] = useState("")
  const [busy, setBusy] = useState(false)
  const add = async () => {
    setBusy(true)
    // target:"" para que el add no herede el target activo (es meta, no de herdr)
    const r = await op("/api/op/targets", { action: "add", name, ssh, target: "" })
    setBusy(false)
    if (r.ok) {
      toast.success(`VPS «${name}» agregado.`)
      onAdded(name)
      onOpenChange(false); setName(""); setSsh("")
    } else toast.error(r.error || "no se pudo agregar")
  }
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Agregar un VPS</DialogTitle>
          <DialogDescription>
            Una máquina remota donde corre <b>herdr</b>. El panel la controla por SSH — corres tus agentes allá
            y los ves/operas desde aquí. La <b>llave SSH la maneja tu OpenSSH</b>; el panel nunca ve credenciales.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <div>
            <label className="mb-1 block text-[11px] font-medium text-muted-foreground">Nombre</label>
            <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="ej. vps-prod" autoFocus />
          </div>
          <div>
            <label className="mb-1 block text-[11px] font-medium text-muted-foreground">Destino SSH</label>
            <Input value={ssh} onChange={(e) => setSsh(e.target.value)} placeholder="alias de ~/.ssh/config o user@host" className="font-mono text-[12px]" />
            <p className="mt-1 text-[10.5px] text-muted-foreground/60">
              Debe conectar con <code className="rounded bg-muted px-1">ssh &lt;destino&gt;</code> sin pedir contraseña (llave configurada).
            </p>
          </div>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={busy}>Cancelar</Button>
          <Button onClick={add} disabled={busy || !name.trim() || !ssh.trim()} className={cn(busy && "opacity-70")}>
            {busy ? "agregando…" : "Agregar VPS"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
