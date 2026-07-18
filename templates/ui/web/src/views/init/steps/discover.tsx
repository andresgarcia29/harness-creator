// Paso 5 — Auto-discover + la entrevista como formularios.
// Hallazgos: lo que discover.sh encontró (roles corregibles, señales, hints).
// Configuración: el borrador de answers pre-llenado con evidencia; el cliente
// edita LOCAL y guarda con rev — el SSE jamás pisa un input.
import { useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import { Textarea } from "@/components/ui/textarea"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { toast } from "sonner"
import { Fld, H2, Code, Empty } from "@/components/bits"
import { ArrowDown, ArrowUp, Loader2, ScanSearch, Sparkles, Save, CircleCheck } from "lucide-react"
import type { InitAnswers, InitState } from "@/lib/harness"
import { StepShell } from "../step-shell"
import { initOp, stepOf } from "../use-init"

const ROLES = ["service", "frontend", "mobile", "library", "contracts", "infra-module", "infra-live", "ci-library", "docs", "unknown"]
const FLOWS = [
  ["trunk-direct-to-prod", "Trunk → prod directo (canary + rollback como red)"],
  ["trunk-staging", "Trunk → staging → prod"],
  ["prs", "PRs con review humano"],
] as const
const SECRET_SOURCES = ["vault", "gcp-secret-manager", "aws-secrets-manager", "doppler", "sops", "1password", "env"]

// Rec — la evidencia bajo un campo pre-llenado (el porqué del default).
function Rec({ k, recs }: { k: string; recs?: Record<string, string> }) {
  const ev = recs?.[k]
  if (!ev) return null
  return (
    <p className="mt-1 flex items-start gap-1 text-[10.5px] text-muted-foreground/60">
      <Sparkles className="mt-px size-3 shrink-0" /> {ev}
    </p>
  )
}

export function DiscoverStep({ init }: { init: InitState }) {
  const dStep = stepOf(init, "discover")
  const eStep = stepOf(init, "enrich")
  const inv = init.inventory
  const serverRev = init.answers_rev || 0

  // borrador local: se siembra del server UNA vez (o al recargar a mano)
  const [draft, setDraft] = useState<InitAnswers | null>(null)
  const [baseRev, setBaseRev] = useState(0)
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    if (init.answers && (!draft || (!dirty && baseRev !== serverRev))) {
      setDraft(structuredClone(init.answers))
      setBaseRev(serverRev)
      setDirty(false)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverRev, !!init.answers])

  const upd = (fn: (d: InitAnswers) => void) => {
    if (!draft) return
    const d = structuredClone(draft)
    fn(d)
    setDraft(d)
    setDirty(true)
  }
  const guardar = async () => {
    if (!draft) return
    setBusy(true)
    const r = await initOp("answers", { rev: baseRev, patch: draft })
    setBusy(false)
    if (!r.ok) {
      if (r.error === "rev") toast.error("El borrador cambió en el servidor — recarga la propuesta")
      else toast.error(r.error)
      return
    }
    setBaseRev(r.rev)
    setDirty(false)
    toast.success("Configuración guardada")
  }
  const confirmar = async () => {
    await guardar()
    const r = await initOp("answers-confirm")
    if (!r.ok) { toast.error(r.error); return }
    toast.success("Configuración confirmada — sigue Agentes")
  }

  if (dStep?.status !== "ok") {
    return (
      <StepShell
        title="Auto-discover"
        lede={<>Un script determinista (cero tokens) escanea <Code>repos/</Code>: lenguajes,
          rol por repo, señales de infra y tu fuente de secretos. Después, el modelo propone
          topología de agentes con evidencia — propuesta editable, nunca ley.</>}
        steps={[dStep]}
        actions={
          <Button disabled={dStep?.status === "running"} className="gap-1.5"
            onClick={async () => { const r = await initOp("step", { step: "discover", action: dStep?.status === "fail" ? "retry" : "run" }); if (!r.ok) toast.error(r.error) }}>
            {dStep?.status === "running" ? <Loader2 className="size-3.5 animate-spin" /> : <ScanSearch className="size-3.5" />}
            Correr auto-discover
          </Button>
        }
      />
    )
  }

  return (
    <StepShell title="Hallazgos y configuración" steps={[dStep, eStep]}
      actions={
        <>
          <Button variant="outline" disabled={busy || !dirty} onClick={guardar} className="gap-1.5">
            <Save className="size-3.5" /> Guardar
          </Button>
          <Button disabled={busy} onClick={confirmar} className="gap-1.5">
            <CircleCheck className="size-3.5" /> Confirmar configuración
          </Button>
        </>
      }>
      {dirty && baseRev !== serverRev && (
        <div className="flex items-center justify-between rounded-xl border border-(--wait)/40 bg-(--wait)/8 p-3 text-[12px]">
          <span>El borrador cambió en el servidor (rev {serverRev}) y tienes ediciones locales.</span>
          <Button size="sm" variant="outline" onClick={() => { setDraft(structuredClone(init.answers!)); setBaseRev(serverRev); setDirty(false) }}>
            Descartar y recargar
          </Button>
        </div>
      )}
      <Tabs defaultValue="hallazgos">
        <TabsList>
          <TabsTrigger value="hallazgos">Hallazgos</TabsTrigger>
          <TabsTrigger value="config">Configuración</TabsTrigger>
        </TabsList>

        <TabsContent value="hallazgos" className="space-y-4 pt-3">
          {!inv ? <Empty title="Sin inventario">Corre el auto-discover.</Empty> : (
            <>
              <div className="overflow-x-auto rounded-2xl border">
                <table className="w-full text-[12px]">
                  <thead><tr className="border-b text-left text-[10.5px] uppercase tracking-wider text-muted-foreground">
                    <th className="px-3 py-2">Repo</th><th className="px-3 py-2">Rol</th><th className="px-3 py-2">Lenguajes</th><th className="px-3 py-2">Señales</th>
                  </tr></thead>
                  <tbody>
                    {inv.repos.map((r) => {
                      const eff = init.role_overrides?.[r.name] || r.role_guess
                      return (
                        <tr key={r.name} className="border-b last:border-b-0">
                          <td className="px-3 py-1.5 font-mono">{r.name}</td>
                          <td className="px-3 py-1.5">
                            <Select value={eff} onValueChange={async (v) => {
                              if (!v) return
                              const res = await initOp("role", { repo: r.name, role: v })
                              if (!res.ok) toast.error(res.error)
                            }}>
                              <SelectTrigger className="h-7 w-36 text-[11.5px]"><SelectValue>{eff}</SelectValue></SelectTrigger>
                              <SelectContent>{ROLES.map((role) => <SelectItem key={role} value={role}>{role}</SelectItem>)}</SelectContent>
                            </Select>
                          </td>
                          <td className="px-3 py-1.5 text-muted-foreground">{r.languages.join(", ") || "—"}</td>
                          <td className="px-3 py-1.5">
                            <div className="flex flex-wrap gap-1">
                              {r.signals.map((sg) => <Badge key={sg} variant="outline" className="text-[9.5px]">{sg}</Badge>)}
                            </div>
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
              {inv.secret_hints.length > 0 && (
                <p className="text-[12px] text-muted-foreground">
                  Fuentes de secretos detectadas: {inv.secret_hints.map((h) => <Badge key={h} variant="outline" className="ml-1 text-[10px]">{h}</Badge>)}
                </p>
              )}
              <div className="rounded-2xl border p-4">
                <div className="mb-1.5 flex items-center gap-2 text-[13px] font-medium">
                  <Sparkles className="size-4 text-(--brand)" /> Enriquecimiento (LLM)
                </div>
                <p className="mb-3 text-[12px] text-muted-foreground">
                  El modelo lee el inventario y propone clustering con dominios (`owns`), DAG y
                  principios. Es una propuesta editable — puedes saltarlo: los defaults deterministas ya están.
                </p>
                <div className="flex gap-2">
                  <Button size="sm" variant="outline" disabled={eStep?.status === "running" || eStep?.status === "ok"} className="gap-1.5"
                    onClick={async () => { const r = await initOp("step", { step: "enrich", action: eStep?.status === "fail" ? "retry" : "run" }); if (!r.ok) toast.error(r.error) }}>
                    {eStep?.status === "running" && <Loader2 className="size-3.5 animate-spin" />}
                    {eStep?.status === "ok" ? "Propuesta aplicada ✓" : "Proponer con el modelo"}
                  </Button>
                  {eStep?.status !== "ok" && eStep?.status !== "skipped" && (
                    <Button size="sm" variant="ghost"
                      onClick={() => initOp("step", { step: "enrich", action: "skip" })}>Saltar</Button>
                  )}
                </div>
              </div>
            </>
          )}
        </TabsContent>

        <TabsContent value="config" className="pt-3">
          {!draft ? <Empty title="Sin borrador">Corre el auto-discover primero.</Empty> : (
            <div className="space-y-1">
              <H2>Proyecto</H2>
              <div className="grid gap-x-4 sm:grid-cols-2">
                <Fld label="Nombre"><Input value={draft.project.name} onChange={(e) => upd((d) => { d.project.name = e.target.value })} /></Fld>
                <Fld label="Prefijo de tickets"><Input value={draft.project.ticket_prefix} onChange={(e) => upd((d) => { d.project.ticket_prefix = e.target.value.toUpperCase() })} className="font-mono" /></Fld>
              </div>
              <Fld label="Flujo a main">
                <Select value={draft.flow} onValueChange={(v) => v && upd((d) => { d.flow = v })}>
                  <SelectTrigger className="w-full"><SelectValue>{FLOWS.find(([v]) => v === draft.flow)?.[1] || draft.flow}</SelectValue></SelectTrigger>
                  <SelectContent>{FLOWS.map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}</SelectContent>
                </Select>
                <Rec k="flow" recs={init.recommendations} />
              </Fld>
              <Fld label="Autonomía de /auto">
                <Select value={draft.autonomy} onValueChange={(v) => v && upd((d) => { d.autonomy = v })}>
                  <SelectTrigger className="w-full"><SelectValue>
                    {draft.autonomy === "full" ? "full — nunca pausa (gates + canary como red)" : "checkpoint — UNA pausa antes del primer ship (recomendado al inicio)"}
                  </SelectValue></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="checkpoint">checkpoint — UNA pausa antes del primer ship (recomendado al inicio)</SelectItem>
                    <SelectItem value="full">full — nunca pausa (gates + canary como red)</SelectItem>
                  </SelectContent>
                </Select>
              </Fld>

              <H2>Modelos</H2>
              <div className="grid gap-x-4 sm:grid-cols-2">
                {(["architect", "reviewer", "implementer", "mechanical"] as const).map((rol) => (
                  <Fld key={rol} label={rol}>
                    <Input value={draft.models[rol]} onChange={(e) => upd((d) => { d.models[rol] = e.target.value })} className="font-mono text-[12px]" />
                  </Fld>
                ))}
              </div>
              <Fld label="Presupuesto de loop" hint="reintentos antes de parar">
                <Input type="number" min={1} max={10} value={draft.loop_budget}
                  onChange={(e) => upd((d) => { d.loop_budget = +e.target.value || 3 })} className="w-24" />
              </Fld>

              <H2>Orden de shipping (DAG)</H2>
              <div className="mb-4 space-y-1 rounded-2xl border p-3">
                {draft.dag.map((repo, i) => (
                  <div key={repo} className="flex items-center gap-2 text-[12.5px]">
                    <span className="w-5 text-right font-mono text-[10.5px] text-muted-foreground/60">{i + 1}</span>
                    <span className="flex-1 font-mono">{repo}</span>
                    <button disabled={i === 0} className="text-muted-foreground/60 hover:text-foreground disabled:opacity-30"
                      onClick={() => upd((d) => { [d.dag[i - 1], d.dag[i]] = [d.dag[i], d.dag[i - 1]] })}><ArrowUp className="size-3.5" /></button>
                    <button disabled={i === draft.dag.length - 1} className="text-muted-foreground/60 hover:text-foreground disabled:opacity-30"
                      onClick={() => upd((d) => { [d.dag[i + 1], d.dag[i]] = [d.dag[i], d.dag[i + 1]] })}><ArrowDown className="size-3.5" /></button>
                  </div>
                ))}
                <Rec k="dag" recs={init.recommendations} />
              </div>

              <H2>Secretos, tickets y memoria</H2>
              <div className="grid gap-x-4 sm:grid-cols-2">
                <Fld label="Fuente de secretos">
                  <Select value={draft.secrets.source} onValueChange={(v) => v && upd((d) => { d.secrets.source = v })}>
                    <SelectTrigger className="w-full"><SelectValue>{draft.secrets.source}</SelectValue></SelectTrigger>
                    <SelectContent>{SECRET_SOURCES.map((s) => <SelectItem key={s} value={s}>{s}</SelectItem>)}</SelectContent>
                  </Select>
                  <Rec k="secrets.source" recs={init.recommendations} />
                </Fld>
                <Fld label="Tickets">
                  <Select value={draft.tickets.provider} onValueChange={(v) => v && upd((d) => { d.tickets.provider = v })}>
                    <SelectTrigger className="w-full"><SelectValue>{draft.tickets.provider}</SelectValue></SelectTrigger>
                    <SelectContent>{["linear", "github", "none"].map((s) => <SelectItem key={s} value={s}>{s}</SelectItem>)}</SelectContent>
                  </Select>
                </Fld>
              </div>
              {draft.secrets.source === "vault" && (
                <div className="grid gap-x-4 sm:grid-cols-2">
                  <Fld label="VAULT_ADDR"><Input value={draft.secrets.vault_addr || ""} onChange={(e) => upd((d) => { d.secrets.vault_addr = e.target.value })} className="font-mono text-[12px]" /></Fld>
                  <Fld label="KV base" hint="p.ej. corvux/harness"><Input value={draft.secrets.kv_base || ""} onChange={(e) => upd((d) => { d.secrets.kv_base = e.target.value })} className="font-mono text-[12px]" /></Fld>
                </div>
              )}
              <label className="mb-4 flex items-center gap-2 text-[12.5px] text-muted-foreground">
                <Checkbox checked={draft.memory.provider === "engram"}
                  onCheckedChange={(v) => upd((d) => { d.memory.provider = v === true ? "engram" : "none" })} />
                memoria episódica (engram) para orquestador y arquitecto
              </label>

              <H2>Principios del proyecto</H2>
              <Fld label="2-4 reglas, una por línea" hint="van a constitution.md">
                <Textarea value={(draft.principles || []).join("\n")} className="min-h-20 text-[12.5px]"
                  onChange={(e) => upd((d) => { d.principles = e.target.value.split("\n").filter((l) => l.trim()) })} />
                <Rec k="principles" recs={init.recommendations} />
              </Fld>

              <H2>Instancia y cronjobs</H2>
              <Fld label="Dónde se versiona esta instancia" hint='"self" o URL de repo'>
                <Input value={draft.instance.repo} onChange={(e) => upd((d) => { d.instance.repo = e.target.value })} className="font-mono text-[12px]" />
              </Fld>
              <label className="flex items-center gap-2 text-[12.5px] text-muted-foreground">
                <Checkbox checked={draft.cronjobs.enabled}
                  onCheckedChange={(v) => upd((d) => { d.cronjobs.enabled = v === true })} />
                cronjobs de self-healing (se configuran al final; puedes activarlos después)
              </label>
              {draft.cronjobs.enabled && (
                <Fld label="Runner">
                  <Select value={draft.cronjobs.runner || "crontab"} onValueChange={(v) => v && upd((d) => { d.cronjobs.runner = v })}>
                    <SelectTrigger className="w-48"><SelectValue>{draft.cronjobs.runner || "crontab"}</SelectValue></SelectTrigger>
                    <SelectContent>{["crontab", "gke", "gha"].map((s) => <SelectItem key={s} value={s}>{s}</SelectItem>)}</SelectContent>
                  </Select>
                </Fld>
              )}
            </div>
          )}
        </TabsContent>
      </Tabs>
    </StepShell>
  )
}
