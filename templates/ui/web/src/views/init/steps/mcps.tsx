// Paso 7 — MCPs: el catálogo filtrado por señales, secretos certificados por
// sonda real (identificado = guardado · certificado = el MCP contestó con ese
// secreto), tier solo degradable, y selección de tools (deny-list nativa).
import { useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { toast } from "sonner"
import { Empty, StatusBadge } from "@/components/bits"
import { BadgeCheck, KeyRound, Loader2, Sparkles, Wrench } from "lucide-react"
import type { InitState } from "@/lib/harness"
import { StepShell } from "../step-shell"
import { initOp, stepOf } from "../use-init"

type CatalogItem = {
  name: string; category: string; purpose: string; mcp: string; tier: string
  phase?: number; secrets?: { key: string; source: string }[]
  evidence?: string; enabled: boolean; chosen_tier?: string
  tools?: string[]; tools_allowed?: string[] | null
  secrets_ok?: Record<string, boolean>
  probe?: { ok: boolean; ms: number; tools?: string[]; error?: string } | null
}

const TIERS = ["read-only", "read-write", "destructive"]

export function McpsStep({ init }: { init: InitState }) {
  const step = stepOf(init, "mcps")
  const [items, setItems] = useState<CatalogItem[] | null>(null)
  const [showAll, setShowAll] = useState(false)
  const [busy, setBusy] = useState("")
  const refresh = async () => {
    const r = await initOp("catalog")
    if (r.ok) setItems(r.catalog)
    else toast.error(r.error)
  }
  useEffect(() => { refresh() }, [init.answers_rev]) // eslint-disable-line react-hooks/exhaustive-deps

  if (!init.answers) {
    return <StepShell title="MCPs" steps={[step]}><Empty title="Primero la configuración">Completa el discover.</Empty></StepShell>
  }
  const visible = (items || []).filter((it) => showAll || it.evidence || it.enabled || !it.phase)
  return (
    <StepShell
      title="MCPs y secretos"
      lede={<>CLI &gt; MCP siempre que se pueda: un MCP se gana su lugar. Los recomendados traen
        la señal que los justifica. Un secreto queda <b>certificado</b> cuando el MCP contesta el
        handshake con él puesto — antes de eso no se guarda nada.</>}
      steps={[step]}
      actions={
        <>
          <Button variant="outline" disabled={busy === "@all"} className="gap-1.5"
            onClick={async () => {
              setBusy("@all")
              const r = await initOp("probe-all")
              setBusy("")
              if (!r.ok) { toast.error(r.error); return }
              toast.success(`${r.probed} MCP(s) sondeados con lo que ya había` +
                (r.waiting_secret?.length ? ` · ${r.waiting_secret.length} esperan secreto a mano` : ""))
              refresh()
            }}>
            {busy === "@all" ? <Loader2 className="size-3.5 animate-spin" /> : <Sparkles className="size-3.5" />}
            Probar todos
          </Button>
          <Button disabled={step?.status === "running"} className="gap-1.5"
            onClick={async () => { const r = await initOp("step", { step: "mcps", action: step?.status === "fail" ? "retry" : "run" }); if (!r.ok) toast.error(r.error) }}>
            {step?.status === "running" ? <Loader2 className="size-3.5 animate-spin" /> : <Wrench className="size-3.5" />}
            Materializar selección
          </Button>
        </>
      }
    >
      {init.target && (
        <div className="rounded-xl border bg-muted/30 p-3 text-[12px] text-muted-foreground">
          Instalación remota: la sonda corre <b>en {init.target}</b> vía SSH — mismo flujo desde
          aquí. Un secreto que pegues viaja por stdin del ssh (jamás en argumentos) y, si el MCP
          contesta allá, queda en el <span className="font-mono">.secrets</span> del VPS.
        </div>
      )}
      <div className="space-y-3">
        {visible.map((it) => (
          <div key={it.name} className="rounded-2xl border p-3.5">
            <div className="flex items-center gap-2.5">
              <Checkbox checked={it.enabled}
                onCheckedChange={async (v) => {
                  const r = await initOp("capability", { name: it.name, enabled: v === true, tier: it.chosen_tier || it.tier })
                  if (!r.ok) toast.error(r.error); else refresh()
                }} />
              <span className="font-mono text-[13px]">{it.name}</span>
              {it.evidence && (
                <span className="flex items-center gap-1 text-[10.5px] text-(--brand)">
                  <Sparkles className="size-3" /> {it.evidence}
                </span>
              )}
              {it.phase === 2 && <Badge variant="outline" className="text-[9.5px]">fase 2 — después</Badge>}
              {it.enabled && (
                <Select value={it.chosen_tier || it.tier} onValueChange={async (v) => {
                  if (!v) return
                  const r = await initOp("capability", { name: it.name, enabled: true, tier: v, tools_allowed: it.tools_allowed || undefined })
                  if (!r.ok) toast.error(r.error); else refresh()
                }}>
                  <SelectTrigger className="ml-auto h-7 w-32 text-[11px]"><SelectValue>{it.chosen_tier || it.tier}</SelectValue></SelectTrigger>
                  <SelectContent>
                    {TIERS.filter((t) => TIERS.indexOf(t) <= TIERS.indexOf(it.tier)).map((t) => (
                      <SelectItem key={t} value={t}>{t}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            </div>
            <p className="mt-1 text-[11.5px] text-muted-foreground">{it.purpose}</p>
            {it.enabled && (it.secrets?.length || 0) > 0 && it.probe?.ok ? (
              // certificado con secreto ya resuelto: nada que pedir
              <div className="mt-2 flex items-center gap-2">
                <Badge className="gap-1 bg-(--ok)/15 text-(--ok)" variant="outline">
                  <BadgeCheck className="size-3" /> certificado · {it.probe.ms}ms
                </Badge>
                <span className="text-[10.5px] text-muted-foreground/60">
                  secreto resuelto de .secrets/entorno — nada que teclear
                </span>
              </div>
            ) : it.enabled && (it.secrets?.length || 0) > 0 ? it.secrets!.map((s) => (
              <SecretRow key={s.key} mcp={it.name} k={s.key}
                saved={!!it.secrets_ok?.[s.key]} certified={!!it.probe?.ok}
                busy={busy === it.name + s.key} setBusy={(b) => setBusy(b ? it.name + s.key : "")}
                onDone={refresh} />
            )) : null}
            {it.enabled && !it.secrets?.length && (
              <div className="mt-2 flex items-center gap-2">
                <Button size="sm" variant="outline" className="h-7 gap-1.5 text-[11px]"
                  onClick={async () => { const r = await initOp("probe-mcp", { name: it.name }); if (!r.ok) toast.error(r.error || "la sonda falló"); refresh() }}>
                  Sondear
                </Button>
                {it.probe && <StatusBadge on={it.probe.ok}>{it.probe.ok ? `ok · ${it.probe.ms}ms` : it.probe.error || "falló"}</StatusBadge>}
              </div>
            )}
            {it.enabled && (it.tools?.length || 0) > 0 && (
              <ToolPicker it={it} onDone={refresh} />
            )}
          </div>
        ))}
      </div>
      {!showAll && (items || []).length > visible.length && (
        <Button variant="ghost" size="sm" onClick={() => setShowAll(true)}>ver todo el catálogo…</Button>
      )}
    </StepShell>
  )
}

function SecretRow({ mcp, k, saved, certified, busy, setBusy, onDone }: {
  mcp: string; k: string; saved: boolean; certified: boolean
  busy: boolean; setBusy: (b: boolean) => void; onDone: () => void
}) {
  const [val, setVal] = useState("")
  return (
    <div className="mt-2 flex items-center gap-2">
      <KeyRound className="size-3.5 shrink-0 text-muted-foreground/60" />
      <span className="font-mono text-[11px] text-muted-foreground">{k}</span>
      <Input type="password" value={val} onChange={(e) => setVal(e.target.value)}
        placeholder={saved ? "guardado — pega uno nuevo para rotarlo" : "valor del secreto"}
        className="h-7 flex-1 text-[11.5px]" />
      <Button size="sm" variant="outline" className="h-7 gap-1 text-[11px]" disabled={busy || !val.trim()}
        onClick={async () => {
          setBusy(true)
          const r = await initOp("mcp-secret", { name: mcp, key: k, value: val })
          setBusy(false)
          if (!r.ok) { toast.error(r.error); return }
          setVal("")
          if (r.note) toast.info(r.note, { duration: 9000 })
          else toast.success(`${mcp} certificado (${r.tools?.length || 0} tools)`)
          onDone()
        }}>
        {busy && <Loader2 className="size-3 animate-spin" />} Certificar
      </Button>
      {certified ? (
        <Badge className="gap-1 bg-(--ok)/15 text-(--ok)" variant="outline"><BadgeCheck className="size-3" /> certificado</Badge>
      ) : saved ? (
        <Badge variant="outline" className="text-(--wait)">identificado</Badge>
      ) : null}
    </div>
  )
}

function ToolPicker({ it, onDone }: { it: CatalogItem; onDone: () => void }) {
  const allowed = it.tools_allowed // null/undefined = todas
  const isAllowed = (t: string) => !allowed || allowed.includes(t)
  const toggle = async (t: string) => {
    const cur = allowed || it.tools || []
    const next = isAllowed(t) ? cur.filter((x) => x !== t) : [...cur, t]
    const r = await initOp("capability", { name: it.name, enabled: true, tier: it.chosen_tier || it.tier, tools_allowed: next })
    if (!r.ok) toast.error(r.error); else onDone()
  }
  return (
    <div className="mt-2">
      <p className="mb-1 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground/70">
        Tools permitidas <i className="font-normal normal-case">(las no marcadas se bloquean vía permissions.deny; re-sondea tras actualizar el MCP)</i>
      </p>
      <div className="flex flex-wrap gap-1.5">
        {(it.tools || []).map((t) => (
          <button key={t} onClick={() => toggle(t)}
            className={`rounded-lg border px-2 py-0.5 font-mono text-[10.5px] transition-colors ${
              isAllowed(t) ? "border-(--ok)/40 bg-(--ok)/10 text-(--ok)" : "border-border text-muted-foreground/50 line-through"}`}>
            {t}
          </button>
        ))}
      </div>
    </div>
  )
}
