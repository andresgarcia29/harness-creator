// Paso 6 — Agentes: editar el clustering propuesto, generar el harness
// (determinista) y correr la arqueología (LLM, por cluster, saltable).
import { useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { toast } from "sonner"
import { Fld, H2, Empty } from "@/components/bits"
import { CircleCheck, CircleDashed, CircleX, Hammer, Loader2, Pickaxe, Plus, Trash2, TriangleAlert } from "lucide-react"
import type { InitCluster, InitState } from "@/lib/harness"
import { StepShell } from "../step-shell"
import { initOp, stepOf } from "../use-init"

const AICON = { ok: CircleCheck, fail: CircleX, running: Loader2, pending: CircleDashed, skipped: CircleDashed } as const
const ACOLOR = { ok: "text-(--ok)", fail: "text-(--bad)", running: "text-(--wait)", pending: "text-muted-foreground/40", skipped: "text-muted-foreground/40" } as const

export function AgentsStep({ init }: { init: InitState }) {
  const gStep = stepOf(init, "generate")
  const aStep = stepOf(init, "archaeology")
  const repos = (init.inventory?.repos || []).map((r) => r.name)
  // servicios sin abogado: el agujero clásico del clustering (a ti se te
  // fueron domos/agora/video-forge) — visible y arreglable con un clic
  const roleOf = (name: string) =>
    init.role_overrides?.[name] || init.inventory?.repos.find((r) => r.name === name)?.role_guess || "unknown"
  const [clusters, setClusters] = useState<InitCluster[] | null>(null)
  const [baseRev, setBaseRev] = useState(0)
  const [dirty, setDirty] = useState(false)
  const serverRev = init.answers_rev || 0
  const generated = gStep?.status === "ok"

  useEffect(() => {
    if (init.answers && (!clusters || (!dirty && baseRev !== serverRev))) {
      setClusters(structuredClone(init.answers.clusters))
      setBaseRev(serverRev)
      setDirty(false)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverRev, !!init.answers])

  if (!init.answers || !clusters) {
    return (
      <StepShell title="Agentes" steps={[gStep, aStep]}>
        <Empty title="Primero la configuración">Completa el auto-discover y confirma la configuración.</Empty>
      </StepShell>
    )
  }

  const upd = (fn: (cs: InitCluster[]) => void) => {
    const cs = structuredClone(clusters)
    fn(cs)
    setClusters(cs)
    setDirty(true)
  }
  const covered = new Set(clusters.flatMap((c) => c.repos))
  const uncoveredServices = repos.filter((r) => roleOf(r) === "service" && !covered.has(r))
  const guardarYGenerar = async () => {
    const r = await initOp("answers", { rev: baseRev, patch: { clusters } })
    if (!r.ok) { toast.error(r.error === "rev" ? "el borrador cambió — recarga" : r.error); return }
    setBaseRev(r.rev)
    setDirty(false)
    const r2 = await initOp("step", { step: "generate", action: gStep?.status === "fail" ? "retry" : "run" })
    if (!r2.ok) toast.error(r2.error)
  }

  return (
    <StepShell
      title="Topología de agentes"
      lede={<>Un <b>abogado</b> por servicio que posee datos; UNO para toda la infra; UNO para
        frontends. Defienden invariantes en los RFCs — nunca implementan. Más agentes no es
        mejor harness: cada uno es contexto y mantenimiento.</>}
      steps={[gStep, aStep]}
      actions={
        <Button disabled={gStep?.status === "running"} onClick={guardarYGenerar} className="gap-1.5">
          {gStep?.status === "running" ? <Loader2 className="size-3.5 animate-spin" /> : <Hammer className="size-3.5" />}
          {generated ? "Re-generar harness" : "Generar harness"}
        </Button>
      }
    >
      {uncoveredServices.length > 0 && (
        <div className="rounded-xl border border-(--wait)/40 bg-(--wait)/8 p-3">
          <p className="mb-1.5 flex items-center gap-2 text-[12.5px] font-medium">
            <TriangleAlert className="size-4 text-(--wait)" /> {uncoveredServices.length} servicio(s) sin abogado
          </p>
          <p className="mb-2 text-[11.5px] text-muted-foreground">
            Cada servicio que posee datos merece su abogado. Un clic los agrega:
          </p>
          <div className="flex flex-wrap gap-1.5">
            {uncoveredServices.map((r) => (
              <button key={r}
                className="rounded-lg border border-(--wait)/50 px-2 py-0.5 font-mono text-[11px] hover:bg-(--wait)/15"
                onClick={() => upd((cs) => { cs.push({ agent: "svc-" + r, kind: "service", repos: [r] }) })}>
                + svc-{r}
              </button>
            ))}
          </div>
        </div>
      )}
      {clusters.length > 12 && (
        <div className="flex items-center gap-2 rounded-xl border border-(--wait)/40 bg-(--wait)/8 p-3 text-[12px]">
          <TriangleAlert className="size-4 text-(--wait)" /> Más de 12 agentes — considera agrupar por dominio de negocio.
        </div>
      )}
      <div className="space-y-3">
        {clusters.map((c, i) => (
          <div key={i} className="rounded-2xl border p-3.5">
            <div className="mb-2 flex items-center gap-2">
              <Input value={c.agent} onChange={(e) => upd((cs) => { cs[i].agent = e.target.value })}
                className="h-8 w-44 font-mono text-[12.5px]" spellCheck={false} />
              <Select value={c.kind} onValueChange={(v) => v && upd((cs) => { cs[i].kind = v })}>
                <SelectTrigger className="h-8 w-32 text-[12px]"><SelectValue>{c.kind}</SelectValue></SelectTrigger>
                <SelectContent>{["service", "infra", "frontend", "contracts"].map((k) => <SelectItem key={k} value={k}>{k}</SelectItem>)}</SelectContent>
              </Select>
              <button className="ml-auto text-muted-foreground/50 hover:text-(--bad)"
                onClick={() => upd((cs) => { cs.splice(i, 1) })}><Trash2 className="size-4" /></button>
            </div>
            {/* SUS repos como chips (quitar con ×) + agregar de un dropdown —
                el grid de 27 checkboxes por cluster era ilegible */}
            <div className="mb-2 flex flex-wrap items-center gap-1.5">
              {c.repos.map((r) => (
                <span key={r} className="flex items-center gap-1 rounded-lg border bg-muted/40 px-2 py-0.5 font-mono text-[11px]">
                  {r}
                  <button className="text-muted-foreground/50 hover:text-(--bad)"
                    onClick={() => upd((cs) => { cs[i].repos = cs[i].repos.filter((x) => x !== r) })}>×</button>
                </span>
              ))}
              {c.repos.length === 0 && <span className="text-[11px] text-(--bad)">sin repos</span>}
              <Select value="" onValueChange={(v) => v && upd((cs) => { if (!cs[i].repos.includes(v)) cs[i].repos.push(v) })}>
                <SelectTrigger className="h-6 w-32 text-[10.5px]"><SelectValue>+ repo…</SelectValue></SelectTrigger>
                <SelectContent>
                  {repos.filter((r) => !c.repos.includes(r)).map((r) => (
                    <SelectItem key={r} value={r}>{r}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <Fld label="Posee" hint="qué datos/dominio defiende">
              <Input value={c.owns || ""} onChange={(e) => upd((cs) => { cs[i].owns = e.target.value })}
                placeholder="lo llena la arqueología si lo dejas vacío" className="text-[12.5px]" />
            </Fld>
          </div>
        ))}
      </div>
      <Button variant="outline" size="sm" className="gap-1.5"
        onClick={() => upd((cs) => { cs.push({ agent: "svc-nuevo", kind: "service", repos: [] }) })}>
        <Plus className="size-3.5" /> Añadir cluster
      </Button>

      {generated && (
        <div className="rounded-2xl border p-4">
          <div className="mb-1.5 flex items-center gap-2 text-[13px] font-medium">
            <Pickaxe className="size-4 text-(--brand)" /> Arqueología ligera
          </div>
          <p className="mb-3 text-[12px] text-muted-foreground">
            Un subagente por servicio lee lo barato (README, migraciones, protos) y llena
            constituciones y specs con ownership e invariantes reales, citando evidencia.
            Todo queda <Badge variant="outline" className="text-[9.5px]">DRAFT</Badge> — tú ratificas.
          </p>
          {(init.archaeology?.length || 0) > 0 && (
            <div className="mb-3 flex flex-wrap gap-2">
              {init.archaeology!.map((ar) => {
                const I = AICON[ar.status]
                return (
                  <span key={ar.agent} className="flex items-center gap-1.5 rounded-lg border px-2 py-1 text-[11.5px]">
                    <I className={`size-3.5 ${ACOLOR[ar.status]} ${ar.status === "running" ? "animate-spin" : ""}`} />
                    <span className="font-mono">{ar.agent}</span>
                    {ar.detail && <span className="max-w-48 truncate text-muted-foreground/70">{ar.detail}</span>}
                  </span>
                )
              })}
            </div>
          )}
          <div className="flex gap-2">
            <Button size="sm" variant="outline" disabled={aStep?.status === "running" || aStep?.status === "ok"} className="gap-1.5"
              onClick={async () => { const r = await initOp("step", { step: "archaeology", action: aStep?.status === "fail" ? "retry" : "run" }); if (!r.ok) toast.error(r.error) }}>
              {aStep?.status === "running" && <Loader2 className="size-3.5 animate-spin" />}
              {aStep?.status === "ok" ? "Arqueología completa ✓" : "Excavar"}
            </Button>
            {aStep?.status !== "ok" && aStep?.status !== "skipped" && (
              <Button size="sm" variant="ghost" onClick={() => initOp("step", { step: "archaeology", action: "skip" })}>Saltar</Button>
            )}
          </div>
        </div>
      )}
      {!generated && <H2 sub="al generar: ~45 archivos — agentes, gates, hooks, docs, panel">Después de editar, genera</H2>}
    </StepShell>
  )
}
