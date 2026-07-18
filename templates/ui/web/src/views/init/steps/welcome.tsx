// Paso 1 — Bienvenida: dónde nace el harness. Input de ruta con validación
// server-side en vivo (dry_run debounced); el server normaliza, crea y adopta.
import { useEffect, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { toast } from "sonner"
import { Fld, Code, StatusBadge } from "@/components/bits"
import { CircleCheck, FolderOpen, FolderSearch, Loader2 } from "lucide-react"
import type { HerdrTarget, InitState } from "@/lib/harness"
import { StepShell } from "../step-shell"
import { initOp, stepOf } from "./../use-init"
import { BrowseDialog } from "./browse-dialog"

type Probe = { ok: boolean; normalized?: string; exists?: boolean; writable?: boolean; empty?: boolean; error?: string }

export function Welcome({ init, targets }: { init: InitState; targets: HerdrTarget[] }) {
  const fixed = !!init.workspace_path
  const [path, setPath] = useState(init.workspace_path || "~/harness-workspace")
  const [outside, setOutside] = useState(false)
  const [busy, setBusy] = useState(false)
  const [probe, setProbe] = useState<Probe | null>(null)
  const [browsing, setBrowsing] = useState(false)
  const timer = useRef<number | undefined>(undefined)

  // Validación en vivo: el server es quien sabe de rutas (normaliza, checa
  // permisos). Debounce para no bombardearlo tecla a tecla.
  useEffect(() => {
    if (fixed) return
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(async () => {
      const r = await initOp("workspace", { path, dry_run: true, confirm_outside_home: outside })
      setProbe(r)
    }, 450)
    return () => window.clearTimeout(timer.current)
  }, [path, outside, fixed])

  const continuar = async () => {
    setBusy(true)
    const r = await initOp("workspace", { path, create: true, confirm_outside_home: outside })
    setBusy(false)
    if (!r.ok) { toast.error(r.error || "no pude fijar el workspace"); return }
    toast.success("Workspace listo: " + r.workspace)
  }

  const ws = stepOf(init, "workspace")
  return (
    <StepShell
      title="Bienvenido a harness"
      lede={<>Vamos a construir tu harness de ingeniería agéntica: agentes con conocimiento
        real de tu código, gates deterministas que protegen main, y un pipeline de ticket a
        producción. Primero: <b>¿dónde vive?</b> Una carpeta nueva (o vacía) — tus repos se
        clonan dentro, en <Code>repos/</Code>.</>}
      steps={[ws]}
      actions={!fixed && (
        <Button disabled={busy || !probe?.ok} onClick={continuar} className="gap-1.5">
          {busy ? <Loader2 className="size-3.5 animate-spin" /> : <FolderOpen className="size-3.5" />}
          {probe?.exists === false ? "Crear carpeta y continuar" : "Usar esta carpeta"}
        </Button>
      )}
    >
      {fixed ? (
        <div className="flex items-center gap-2.5 rounded-xl border border-(--ok)/35 bg-(--ok)/8 p-3.5">
          <CircleCheck className="size-4 shrink-0 text-(--ok)" />
          <span className="text-[13px]">Workspace fijado en <Code>{init.workspace_path}</Code></span>
        </div>
      ) : (
        <>
          {targets.length > 0 && (
            <Fld label="¿Dónde se crea?" hint="local, o un VPS por SSH">
              <Select value={init.target || "local"}
                onValueChange={async (v) => {
                  const r = await initOp("target", { name: v === "local" ? "" : v })
                  if (!r.ok) toast.error(r.error)
                }}>
                <SelectTrigger className="w-full"><SelectValue>
                  {init.target ? `VPS: ${init.target}` : "esta máquina"}
                </SelectValue></SelectTrigger>
                <SelectContent>
                  <SelectItem value="local">esta máquina</SelectItem>
                  {targets.map((t) => <SelectItem key={t.name} value={t.name}>VPS: {t.name}</SelectItem>)}
                </SelectContent>
              </Select>
            </Fld>
          )}
          <Fld label="Carpeta del workspace" hint="absoluta o ~/…">
            <div className="flex gap-2">
              <Input value={path} onChange={(e) => setPath(e.target.value)} className="font-mono text-[13px]" spellCheck={false} />
              {!init.target && (
                <Button variant="outline" size="icon" title="Explorar…" onClick={() => setBrowsing(true)}>
                  <FolderSearch className="size-4" />
                </Button>
              )}
            </div>
          </Fld>
          <BrowseDialog open={browsing} onOpenChange={setBrowsing} onPick={setPath} />
          {probe && (
            <div className="flex flex-wrap items-center gap-1.5 text-[11.5px]">
              {probe.ok ? (
                <>
                  <Code>{probe.normalized}</Code>
                  <StatusBadge on={probe.exists}>{probe.exists ? "existe" : "se creará"}</StatusBadge>
                  <StatusBadge on={probe.writable}>{probe.writable ? "escribible" : "sin permiso"}</StatusBadge>
                  {probe.exists && !probe.empty && <Badge variant="outline" className="text-(--wait)">no está vacía</Badge>}
                </>
              ) : (
                <span className="text-(--bad)">{probe.error}</span>
              )}
            </div>
          )}
          <label className="flex items-center gap-2 text-[12px] text-muted-foreground">
            <Checkbox checked={outside} onCheckedChange={(v) => setOutside(v === true)} />
            permitir una ruta fuera de mi home
          </label>
        </>
      )}
    </StepShell>
  )
}
