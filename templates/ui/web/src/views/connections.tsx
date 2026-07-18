import { useEffect, useState, type ReactNode } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { toast } from "sonner"
import { VHead, H2, Lede, Code, StatusBadge } from "@/components/bits"
import { n as nfmt, op, type Snapshot } from "@/lib/harness"
import { Database, Coins, Cable, Loader2, RefreshCw } from "lucide-react"

// Una integración conectable: valida contra el proveedor ANTES de guardar (0600).
function ProviderCard({ id, name, icon, desc, ok, extra, placeholder, cta = "Conectar", mono }: {
  id: string; name: string; icon: ReactNode; desc: ReactNode; ok?: boolean; extra?: ReactNode
  placeholder?: string; cta?: string; mono?: boolean
}) {
  const [tk, setTk] = useState("")
  const [busy, setBusy] = useState(false)
  const conectar = async () => {
    if (!tk.trim()) return
    setBusy(true)
    const r = await op("/api/op/connect", { provider: id, token: tk.trim() })
    setBusy(false)
    if (r.ok) { toast.success(r.note || "Validado contra el proveedor y guardado."); setTk("") }
    else toast.error(r.error || "no se pudo conectar")
  }
  return (
    <Card className="mb-3 py-0"><CardContent className="p-4 sm:p-5">
      <h3 className="flex items-center gap-2.5 font-heading text-[14.5px] font-bold">
        <span className="text-(--brand)">{icon}</span>{name} <StatusBadge on={ok}>{ok ? "conectado" : "sin conectar"}</StatusBadge>
      </h3>
      <p className="mb-2.5 mt-1 text-xs leading-relaxed text-muted-foreground/80">{desc}</p>
      <div className="flex flex-col gap-2 sm:flex-row">
        <Input type="password" value={tk} onChange={(e) => setTk(e.target.value)}
          className={mono ? "flex-1 font-mono text-[12px]" : "flex-1 font-mono text-[12.5px]"}
          placeholder={placeholder || (ok ? "token guardado — pega uno nuevo para rotarlo" : "pega tu token")}
          onKeyDown={(e) => { if (e.key === "Enter") conectar() }} />
        <Button variant="outline" onClick={conectar} disabled={busy || !tk.trim()}>{busy ? <Loader2 className="size-3.5 animate-spin" /> : cta}</Button>
      </div>
      {extra}
    </CardContent></Card>
  )
}

// El almacén REAL: refleja el MOTOR que de verdad respalda al daemon —
// SQLite (con ruta y tamaño del archivo) o Postgres (un servidor, sin archivo).
// El engine sale de /api/db, no se asume.
function DbCard() {
  const [db, setDb] = useState<{ engine: string; path?: string; size_bytes?: number; machines?: number; calls?: number; events?: number } | null>(null)
  useEffect(() => { fetch("/api/db").then((r) => r.json()).then(setDb).catch(() => {}) }, [])
  if (!db) return null
  const isPg = db.engine === "postgres"
  const mb = db.size_bytes ? (db.size_bytes / 1024 / 1024).toFixed(1) + " MB" : "—"
  const filas = `${nfmt(db.calls)} llamadas · ${nfmt(db.events)} eventos · ${db.machines} máquina${(db.machines || 0) !== 1 ? "s" : ""}`
  return (
    <Card className="mb-3 py-0"><CardContent className="p-4 sm:p-5">
      <h3 className="flex items-center gap-2.5 font-heading text-[14.5px] font-bold">
        <Database className="size-4 text-(--brand)" /> {isPg ? "Postgres" : "SQLite"} <StatusBadge on>activo</StatusBadge>
      </h3>
      <div className="mt-2 grid gap-x-6 gap-y-1 text-[12px] text-muted-foreground sm:grid-cols-2">
        {isPg
          ? <span className="font-mono text-[11px]">almacén central (servidor)</span>
          : <span className="truncate font-mono text-[11px]" title={db.path}>{db.path}</span>}
        <span>{isPg ? filas : `${mb} · ${filas}`}</span>
      </div>
      <p className="mt-2 text-[11.5px] leading-relaxed text-muted-foreground/70">
        {isPg
          ? <>El daemon está usando <b className="text-foreground/80">Postgres</b> como almacén central — el histórico de todas las máquinas conectadas vive aquí. Migraciones forward-only, se aplican solas al conectar.</>
          : <>WAL, migraciones forward-only con respaldo automático. Cada máquina lleva su almacén; para centralizar todo en uno, conecta un Postgres abajo (se usará como almacén compartido tras reiniciar el panel).</>}
      </p>
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
      [r.added?.length ? `Precio nuevo para: ${r.added.join(", ")}.` : "Todos los modelos observados ya tienen precio.",
       r.missing?.length ? `Sin match en OpenRouter: ${r.missing.join(", ")} — agrégalos a mano.` : ""]
        .filter(Boolean).join(" "),
    )
  }
  return (
    <>
      <VHead title="Conexiones"
        sub={<>los tokens se validan contra el proveedor antes de guardarse — en <Code>~/.config/harness/</Code>, chmod 600; jamás se muestran ni pasan por un agente</>} />

      {/* Precios — el motor de costos */}
      <H2>Precios de modelos</H2>
      <Lede>De aquí salen todos los costos que ves. Los modelos de Anthropic ya traen precio base; para todo lo demás — Kimi, GLM, Gemini, el que uses — <b className="text-foreground/80">OpenRouter</b> cotiza en vivo. Sincroniza cuando estrenes un modelo.</Lede>
      <ProviderCard id="openrouter" name="OpenRouter" icon={<Coins className="size-4" />} ok={c.openrouter}
        desc={<>La fuente de precios de los modelos no-Anthropic. El token es <b>opcional</b> (sin él igual cotiza el catálogo público) — sólo si quieres tus tarifas negociadas.</>}
        extra={
          <Button variant="outline" size="sm" className="mt-2.5 gap-1.5" onClick={sync} disabled={syncing}>
            {syncing ? <Loader2 className="size-3.5 animate-spin" /> : <RefreshCw className="size-3.5" />}
            Sincronizar precios de modelos sin precio
          </Button>
        } />

      {/* Integraciones */}
      <H2>Integraciones</H2>
      <ProviderCard id="linear" name="Linear" icon={<Cable className="size-4" />} ok={c.linear}
        desc={<>Para que los tickets entren como tareas y <Code>/auto</Code> los tome solos.</>} />

      {/* Almacén */}
      <H2>Almacén — dónde viven los datos</H2>
      <Lede>El histórico (llamadas, eventos, hilos, precios) persiste y sobrevive reinicios.</Lede>
      <DbCard />
      <ProviderCard id="postgres" name="Postgres" icon={<Database className="size-4" />} ok={c.postgres} mono cta="Conectar"
        placeholder="postgres://user:pass@host:5432/db?sslmode=require"
        desc={<>Opcional — un almacén <b>central</b> para juntar el histórico de varias máquinas en uno (el modo nube). Pega el DSN: se valida con un ping y se guarda cifrado; el panel lo usará cuando actives ese modo.</>} />
    </>
  )
}
