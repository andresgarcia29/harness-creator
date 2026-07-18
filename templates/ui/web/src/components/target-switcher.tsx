// Selector de MÁQUINA: local o un VPS por SSH. Cambia qué herdr ves en
// Terminales (y a dónde van las acciones). Cada VPS muestra un dot de conexión
// (verde=herdr corriendo, ámbar=alcanzable/parado, rojo=no conecta). Agregar
// sólo pide un alias de ~/.ssh/config o user@host — la llave la maneja OpenSSH,
// el panel nunca toca credenciales. El daemon corre `ssh <destino> herdr …` con
// quoting a prueba de inyección; el navegador manda el NOMBRE, nunca un comando.
import { useEffect, useState } from "react"
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuGroup, DropdownMenuItem, DropdownMenuLabel,
  DropdownMenuSeparator, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { cn } from "@/lib/utils"
import { toast } from "sonner"
import { op, type HerdrTarget, type TargetProbe } from "@/lib/harness"
import { useTarget } from "@/lib/target"
import { Monitor, Server, Check, Plus, Trash2, ChevronsUpDown, Loader2, Plug, KeyRound } from "lucide-react"

// Dot de conexión de un target según su probe.
function StatusDot({ p }: { p?: TargetProbe }) {
  const [tone, title] =
    !p ? ["bg-muted-foreground/40", "sin estado aún"]
      : p.running ? ["bg-(--ok) animate-pulse", "herdr corriendo"]
        : p.reachable ? ["bg-(--wait)", "herdr instalado, server parado"]
          : p.ssh_ok ? ["bg-(--wait)", "conecté por SSH, pero herdr no respondió"]
            : ["bg-(--bad)", "no conecta por SSH"]
  return <i className={cn("size-2 shrink-0 rounded-full", tone)} title={title} />
}

// Sondea el estado de todos los targets cada 15s (y al montar). SSH a cada uno,
// concurrente en el daemon — no cada 2s, para no cargar.
function useTargetStatus(count: number): Record<string, TargetProbe> {
  const [status, setStatus] = useState<Record<string, TargetProbe>>({})
  useEffect(() => {
    if (count === 0) return
    let live = true
    const poll = async () => {
      const r = await op("/api/op/targets", { action: "status", target: "" })
      if (live && r.ok && Array.isArray(r.status)) {
        const m: Record<string, TargetProbe> = {}
        for (const s of r.status as TargetProbe[]) m[s.name] = s
        setStatus(m)
      }
    }
    poll()
    const iv = setInterval(poll, 15000)
    return () => { live = false; clearInterval(iv) }
  }, [count])
  return status
}

export function TargetSwitcher({ targets, full }: { targets: HerdrTarget[]; full?: boolean }) {
  const [active, setActive] = useTarget()
  const [addOpen, setAddOpen] = useState(false)
  const status = useTargetStatus(targets.length)
  const current = active ? targets.find((t) => t.name === active) : undefined
  const label = active ? (current?.name || active) : "esta máquina"

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger className={cn("flex h-8 items-center gap-1.5 rounded-md border border-border bg-card px-2.5 text-[12px] font-medium transition-colors hover:bg-accent",
          full ? "w-full" : "")}>
          {active ? <Server className="size-3.5 shrink-0 text-(--brand)" /> : <Monitor className="size-3.5 shrink-0 text-muted-foreground" />}
          <span className={cn("truncate", full ? "flex-1 text-left" : "max-w-[140px]")}>{label}</span>
          {active && <StatusDot p={status[active]} />}
          <ChevronsUpDown className="size-3 shrink-0 text-muted-foreground/60" />
        </DropdownMenuTrigger>
        <DropdownMenuContent align={full ? "start" : "end"} className="min-w-[240px]">
          <DropdownMenuGroup>
            <DropdownMenuLabel className="text-[11px] text-muted-foreground/70">Máquina que ves</DropdownMenuLabel>
            <DropdownMenuItem onClick={() => setActive("")}>
              <Monitor className="size-3.5" /> esta máquina (local)
              {!active && <Check className="ml-auto size-3.5 text-(--ok)" />}
            </DropdownMenuItem>
            {targets.map((t) => (
              <DropdownMenuItem key={t.name} onClick={() => setActive(t.name)}>
                <StatusDot p={status[t.name]} />
                <Server className="size-3.5 text-(--brand)" />
                <span className="min-w-0 flex-1 truncate">{t.name}</span>
                <span className="ml-1 max-w-[90px] truncate font-mono text-[10px] text-muted-foreground/50">{t.ssh}</span>
                <span role="button" tabIndex={-1}
                  onClick={(e) => { e.stopPropagation(); removeTarget(t.name, active, setActive) }}
                  title="quitar este destino" className="ml-1 rounded p-0.5 text-muted-foreground/50 hover:text-(--bad)">
                  <Trash2 className="size-3" />
                </span>
                {active === t.name && <Check className="size-3.5 text-(--ok)" />}
              </DropdownMenuItem>
            ))}
          </DropdownMenuGroup>
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
    if (active === name) setActive("")
  } else toast.error(r.error || "no se pudo quitar")
}

export function AddTargetDialog({ open, onOpenChange, onAdded }: {
  open: boolean; onOpenChange: (o: boolean) => void; onAdded: (name: string) => void
}) {
  const [name, setName] = useState("")
  const [user, setUser] = useState("")
  const [host, setHost] = useState("")
  const [port, setPort] = useState("22")
  const [path, setPath] = useState("")
  const [pw, setPw] = useState("")
  const [showPw, setShowPw] = useState(false)
  const [busy, setBusy] = useState<"" | "test" | "key" | "add">("")
  const [probe, setProbe] = useState<TargetProbe | null>(null)
  const [keyOk, setKeyOk] = useState(false)

  // el destino como lo entiende OpenSSH: alias | user@host | ssh://user@host:puerto
  const dest = (() => {
    const h = host.trim()
    if (!h) return ""
    const u = user.trim()
    const p = port.trim() || "22"
    const base = u ? `${u}@${h}` : h
    return p !== "22" ? `ssh://${base}:${p}` : base
  })()

  const reset = () => { setName(""); setUser(""); setHost(""); setPort("22"); setPath(""); setPw(""); setProbe(null); setKeyOk(false); setShowPw(false) }
  const test = async () => {
    setBusy("test"); setProbe(null)
    const r = await op("/api/op/targets", { action: "test", ssh: dest, target: "" })
    setBusy("")
    if (r.ok && r.probe) setProbe(r.probe as TargetProbe)
    else toast.error(r.error || "no se pudo probar")
  }
  const installKey = async () => {
    setBusy("key")
    const r = await op("/api/op/targets", { action: "install-key", ssh: dest, password: pw, target: "" })
    setBusy("")
    setPw("") // la contraseña se usa UNA vez — fuera del estado ya
    if (!r.ok) { toast.error(r.error || "no se pudo instalar la llave"); return }
    setKeyOk(true)
    toast.success("Llave instalada — desde ahora entra sin contraseña")
    test()
  }
  const add = async () => {
    setBusy("add")
    const r = await op("/api/op/targets", { action: "add", name, ssh: dest, path, target: "" })
    setBusy("")
    if (r.ok) {
      toast.success(`VPS «${name}» agregado.`)
      onAdded(name)
      onOpenChange(false); reset()
    } else toast.error(r.error || "no se pudo agregar")
  }
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Agregar un VPS</DialogTitle>
          <DialogDescription>
            Una máquina remota controlada por SSH. La <b>llave la maneja tu OpenSSH</b>; si el VPS
            aún pide contraseña, abajo puedes instalar tu llave con ella (se usa una vez, jamás se guarda).
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <div>
            <label className="mb-1 block text-[11px] font-medium text-muted-foreground">Nombre</label>
            <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="ej. vps-prod" autoFocus />
          </div>
          <div className="grid grid-cols-[1fr_1.4fr_5rem] gap-2">
            <div>
              <label className="mb-1 block text-[11px] font-medium text-muted-foreground">Usuario</label>
              <Input value={user} onChange={(e) => { setUser(e.target.value); setProbe(null); setKeyOk(false) }} placeholder="andres" className="font-mono text-[12px]" />
            </div>
            <div>
              <label className="mb-1 block text-[11px] font-medium text-muted-foreground">Host o IP</label>
              <Input value={host} onChange={(e) => { setHost(e.target.value); setProbe(null); setKeyOk(false) }} placeholder="203.0.113.7 · vps.midominio.com · alias ssh" className="font-mono text-[12px]" />
            </div>
            <div>
              <label className="mb-1 block text-[11px] font-medium text-muted-foreground">Puerto</label>
              <Input value={port} onChange={(e) => { setPort(e.target.value.replace(/[^0-9]/g, "")); setProbe(null) }} placeholder="22" className="font-mono text-[12px]" />
            </div>
          </div>
          {dest && <p className="text-[10.5px] text-muted-foreground/60">destino: <code className="rounded bg-muted px-1">{dest}</code> — un alias de <code className="rounded bg-muted px-1">~/.ssh/config</code> también vale (deja usuario y puerto por defecto)</p>}
          <div>
            <label className="mb-1 block text-[11px] font-medium text-muted-foreground">Ruta del workspace en el VPS <span className="text-muted-foreground/50">(opcional)</span></label>
            <Input value={path} onChange={(e) => setPath(e.target.value)} placeholder="/home/user/mi-proyecto" className="font-mono text-[12px]" />
          </div>
          {!keyOk && (
            <div className="rounded-md border border-dashed p-2.5">
              <button type="button" onClick={() => setShowPw(!showPw)} className="text-[11px] font-medium text-muted-foreground hover:text-foreground">
                ¿El VPS todavía pide contraseña? {showPw ? "▾" : "▸"}
              </button>
              {showPw && (
                <div className="mt-2 flex gap-2">
                  <Input type="password" value={pw} onChange={(e) => setPw(e.target.value)}
                    placeholder="contraseña SSH (se usa una vez)" className="text-[12px]" />
                  <Button variant="outline" size="sm" onClick={installKey} disabled={busy !== "" || !dest || !pw} className="shrink-0 gap-1.5">
                    {busy === "key" ? <Loader2 className="size-3.5 animate-spin" /> : <KeyRound className="size-3.5" />} Instalar mi llave
                  </Button>
                </div>
              )}
            </div>
          )}
          {probe && (
            <div className={cn("flex items-start gap-2 rounded-md border px-3 py-2 text-[11.5px]",
              probe.running ? "border-(--ok)/40 bg-(--ok)/8 text-(--ok)"
                : probe.reachable || probe.ssh_ok ? "border-(--wait)/40 bg-(--wait)/8 text-(--wait)"
                  : "border-(--bad)/40 bg-(--bad)/8 text-(--bad)")}>
              <StatusDot p={probe} />
              <span>{probe.message}</span>
            </div>
          )}
        </div>
        <DialogFooter className="flex-col-reverse gap-2 sm:flex-row sm:justify-between">
          <Button variant="outline" onClick={test} disabled={busy !== "" || !dest} className="gap-1.5">
            {busy === "test" ? <Loader2 className="size-3.5 animate-spin" /> : <Plug className="size-3.5" />} Probar conexión
          </Button>
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={busy !== ""}>Cancelar</Button>
            <Button onClick={add} disabled={busy !== "" || !name.trim() || !dest}>Agregar VPS</Button>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
