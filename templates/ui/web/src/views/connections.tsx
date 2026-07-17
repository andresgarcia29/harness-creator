import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { toast } from "sonner"
import { VHead, H2, Code, StatusBadge } from "@/components/bits"
import { op, type Snapshot } from "@/lib/harness"

function ProviderCard({ id, name, desc, ok, extra }: {
  id: string; name: string; desc: React.ReactNode; ok?: boolean; extra?: React.ReactNode
}) {
  const [tk, setTk] = useState("")
  const [busy, setBusy] = useState(false)
  const conectar = async () => {
    setBusy(true)
    const r = await op("/api/op/connect", { provider: id, token: tk.trim() })
    setBusy(false)
    if (r.ok) { toast.success("Listo — validado contra el proveedor y guardado."); setTk("") }
    else toast.error(r.error)
  }
  return (
    <Card className="mb-3 py-0"><CardContent className="p-4 sm:p-5">
      <h3 className="flex items-center gap-2.5 font-heading text-[14.5px] font-bold">
        {name} <StatusBadge on={ok}>{ok ? "conectado" : "sin conectar"}</StatusBadge>
      </h3>
      <p className="mb-2.5 mt-1 text-xs text-muted-foreground/80">{desc}</p>
      <div className="flex flex-col gap-2 sm:flex-row">
        <Input type="password" value={tk} onChange={(e) => setTk(e.target.value)} className="flex-1 font-mono text-[12.5px]"
          placeholder={ok ? "token guardado — pega uno nuevo para rotarlo" : "pega tu token"} />
        <Button variant="outline" onClick={conectar} disabled={busy}>{busy ? "…" : "Conectar"}</Button>
      </div>
      {extra}
    </CardContent></Card>
  )
}

function ModeCard({ name, tag, on, children }: { name: string; tag: string; on?: boolean; children: React.ReactNode }) {
  return (
    <Card className="mb-3 py-0"><CardContent className="p-4 sm:p-5">
      <h3 className="flex items-center gap-2.5 font-heading text-[14.5px] font-bold">
        {name} <StatusBadge on={on}>{tag}</StatusBadge>
      </h3>
      <p className="mt-1 text-xs text-muted-foreground/80">{children}</p>
    </CardContent></Card>
  )
}

export function Connections({ s }: { s: Snapshot }) {
  const c = s.connections || {}
  const [syncing, setSyncing] = useState(false)
  const sync = async () => {
    setSyncing(true)
    const r = await op("/api/op/sync-prices", {})
    setSyncing(false)
    if (!r.ok) { toast.error(r.error); return }
    toast.success(
      r.note ||
      [r.added.length ? `Precio nuevo para: ${r.added.join(", ")}.` : "",
       r.missing?.length ? `Sin match en OpenRouter: ${r.missing.join(", ")} — agrégalos a mano en pricing.json.` : ""]
        .filter(Boolean).join(" "),
    )
  }
  return (
    <>
      <VHead title="Conexiones"
        sub={<>los tokens se validan contra el proveedor antes de guardarse — en <Code>~/.config/harness/</Code>, chmod 600; jamás se muestran ni pasan por un agente</>} />
      <ProviderCard id="linear" name="Linear" ok={c.linear}
        desc={<>Para que los tickets entren como tareas y <Code>/auto</Code> los tome solos.</>} />
      <ProviderCard id="openrouter" name="OpenRouter" ok={c.openrouter}
        desc="Proveedor de modelos (GLM, Kimi, el que uses). El token es opcional para precios."
        extra={
          <Button variant="outline" size="sm" className="mt-2.5" onClick={sync} disabled={syncing}>
            {syncing ? "…" : "Sincronizar precios de modelos sin precio"}
          </Button>
        } />
      <H2>Modo — desde dónde se sirve el panel</H2>
      <ModeCard name="Local" tag="activo" on>Tu máquina, 127.0.0.1. Un solo usuario, cero red. Es el modo de hoy.</ModeCard>
      <ModeCard name="VPS" tag="con el daemon">
        Mientras llega el modo <Code>serve</Code>: <Code>ssh -L 7717:localhost:7717 tu-vps</Code> te da este mismo panel del VPS, hoy, sin infraestructura.
      </ModeCard>
      <ModeCard name="Kubernetes" tag="con el daemon">
        Un deployment por cliente, colector local reportando (ADR-0001/0008). Fase 7 del plan — sin botón hasta que exista de verdad.
      </ModeCard>
    </>
  )
}
