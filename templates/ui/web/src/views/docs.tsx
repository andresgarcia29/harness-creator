// Docs: TODO leído de la instancia real (.claude/commands, agents, Makefile,
// ship.sh, settings.json) — nada de prosa que se pudra. Si un comando no
// existe aquí, no aparece aquí.
import { useState } from "react"
import { Card, CardContent } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { toast } from "sonner"
import { Gavel, Loader2 } from "lucide-react"
import { VHead, H2, Lede, Code, Empty } from "@/components/bits"
import { op, type Snapshot } from "@/lib/harness"

// Contexto de uso para lo CONOCIDO del harness; lo desconocido cae al desc real
const GATE_DOCS: Record<string, string> = {
  gate_trailer: "todo commit lleva 'Task: <id>' — sin trazabilidad no hay merge",
  gate_secrets: "gitleaks sobre el diff: una llave en el código muere aquí",
  gate_tests_untouched: "el diff no puede debilitar tests (skip/comentar asserts) salvo delta-spec",
  gate_evidence: "lo CITADO por la compliance matrix ∩ lo LEÍDO de verdad (evidence.log)",
}
const HOOK_DOCS: Record<string, string> = {
  "block-direct-push.sh": "bloquea git push directo a main — fail-closed",
  "guard-canonical.sh": "protege repos/ canónicos y los archivos de ley (ship.sh, hooks, settings) — fail-closed",
  "track-read.sh": "apunta qué artefactos abrió cada agente (evidencia para gate_evidence) — observa, jamás bloquea",
  "ui-emit.sh": "manda eventos de sesión al bus del panel — observa, jamás bloquea",
}

// Ratificar — la ley que la arqueología propuso y nadie ha firmado. Un
// abogado en DRAFT es la primera parada de /auto: aquí se firma, uno por
// uno o todos. El flip es DRAFT→RATIFIED; el contenido no se toca.
function DraftsPanel({ s }: { s: Snapshot }) {
  const [busy, setBusy] = useState("")
  const drafts = s.drafts || []
  if (!drafts.length || s.op === false) return null
  const ratify = async (path?: string) => {
    setBusy(path || "@all")
    const r = await op("/api/op/ratify", path ? { path } : { all: true })
    setBusy("")
    if (!r.ok && r.failed?.length) toast.error(`Fallaron: ${r.failed.join(" · ")}`)
    else toast.success(path ? `Ratificado: ${path}` : `${r.ratified?.length || 0} documentos ratificados`)
  }
  return (
    <div className="mb-6 rounded-2xl border border-(--wait)/45 bg-(--wait)/8 p-4">
      <div className="mb-1 flex items-center gap-2">
        <Gavel className="size-4 text-(--wait)" />
        <span className="text-[13.5px] font-medium">{drafts.length} documento(s) en DRAFT — la ley espera tu firma</span>
        <Button size="sm" className="ml-auto gap-1.5" disabled={busy !== ""} onClick={() => ratify()}>
          {busy === "@all" && <Loader2 className="size-3.5 animate-spin" />} Ratificar todos
        </Button>
      </div>
      <p className="mb-3 text-[11.5px] text-muted-foreground">
        La arqueología propone; los humanos ratifican. <b>Léelos antes de firmar</b> — un abogado
        en DRAFT es la primera parada de <Code>/auto</Code>. Se firman aquí (status → RATIFIED); editar el
        contenido sigue siendo cosa del editor.
      </p>
      <div className="divide-y rounded-xl border bg-card">
        {drafts.map((d) => (
          <div key={d.path} className="flex items-center gap-2.5 px-3 py-1.5">
            <Badge variant="outline" className="text-[9.5px]">{d.kind}</Badge>
            <span className="text-[12.5px]">{d.title}</span>
            <span className="truncate font-mono text-[10.5px] text-muted-foreground/60">{d.path}</span>
            <Button size="sm" variant="outline" className="ml-auto h-6 shrink-0 text-[11px]"
              disabled={busy !== ""} onClick={() => ratify(d.path)}>
              {busy === d.path ? <Loader2 className="size-3 animate-spin" /> : "Ratificar"}
            </Button>
          </div>
        ))}
      </div>
    </div>
  )
}

export function Docs({ s }: { s: Snapshot }) {
  const tb = s.toolbox
  if (!tb) return <Empty><p>El server todavía no reporta el inventario.</p></Empty>
  const empty = !tb.commands.length && !tb.make.length && !tb.agents.length
  return (
    <>
      <VHead title="Docs" sub={<>leído de esta instancia en vivo{tb.version ? <> · harness <b className="font-mono">v{tb.version}</b></> : null}</>} />
      <DraftsPanel s={s} />
      {empty && (
        <Empty title="Esta instancia aún no tiene el harness completo">
          <p>No encuentro comandos en <Code>.claude/commands/</Code> ni targets documentados en el <Code>Makefile</Code>. Corre <Code>/harness-update .</Code> y esta página se llena sola.</p>
        </Empty>
      )}

      {tb.commands.length > 0 && (
        <>
          <H2 sub="slash commands en .claude/commands/ — se usan dentro de una sesión de Claude Code">Comandos del pipeline</H2>
          <Lede>El día a día es una línea: <Code>/auto &lt;ticket|prompt&gt;</Code>. Los demás existen para conducir fase por fase cuando quieras el volante.</Lede>
          <div className="grid gap-2.5 md:grid-cols-2">
            {tb.commands.map((c) => (
              <Card key={c.name} className="py-0"><CardContent className="p-4">
                <div className="flex flex-wrap items-baseline gap-2">
                  <b className="font-mono text-[13px] font-semibold text-(--brand)">{c.name}</b>
                  {c.args && <span className="font-mono text-[10.5px] text-muted-foreground/60">{c.args}</span>}
                </div>
                <p className="mt-1 text-xs leading-relaxed text-muted-foreground">{c.desc || "(sin descripción en el frontmatter)"}</p>
              </CardContent></Card>
            ))}
          </div>
        </>
      )}

      {tb.make.length > 0 && (
        <>
          <H2 sub="la interfaz humana — corren desde la terminal, sin agente">Targets del Makefile</H2>
          <div className="overflow-x-auto rounded-xl border">
            <Table>
              <TableHeader><TableRow><TableHead className="w-[140px]">make …</TableHead><TableHead>Qué hace</TableHead></TableRow></TableHeader>
              <TableBody>
                {tb.make.map((m) => (
                  <TableRow key={m.target}>
                    <TableCell className="font-mono text-xs font-semibold text-(--brand)">{m.target}</TableCell>
                    <TableCell className="text-xs text-muted-foreground">{m.desc}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </>
      )}

      {(tb.gates.length > 0 || tb.hooks.length > 0) && (
        <>
          <H2 sub="las leyes con dientes — deterministas, sin juicio de modelo">Gates y hooks</H2>
          <Lede>Los gates viven en <Code>ship.sh</Code>: la única puerta a main. Los hooks corren dentro de Claude Code; los fail-closed bloquean, los observadores jamás.</Lede>
          <div className="grid gap-2.5 md:grid-cols-2">
            {tb.gates.map((g) => (
              <Card key={g} className="py-0"><CardContent className="flex items-start gap-3 p-3.5">
                <Badge variant="outline" className="mt-0.5 shrink-0 rounded-full font-mono text-[9px] text-(--ok)">gate</Badge>
                <div><b className="font-mono text-xs font-semibold">{g}</b>
                  <p className="text-[11.5px] leading-relaxed text-muted-foreground">{GATE_DOCS[g] || "gate de esta instancia (ver ship.sh)"}</p></div>
              </CardContent></Card>
            ))}
            {tb.hooks.map((h) => (
              <Card key={h} className="py-0"><CardContent className="flex items-start gap-3 p-3.5">
                <Badge variant="outline" className="mt-0.5 shrink-0 rounded-full font-mono text-[9px] text-(--brand)">hook</Badge>
                <div><b className="font-mono text-xs font-semibold">{h}</b>
                  <p className="text-[11.5px] leading-relaxed text-muted-foreground">{HOOK_DOCS[h] || "hook registrado en settings.json"}</p></div>
              </CardContent></Card>
            ))}
          </div>
        </>
      )}

      {tb.agents.length > 0 && (
        <>
          <H2 sub=".claude/agents/ — cada uno con su constitución">Agentes</H2>
          <Lede>Los abogados (<Code>svc-*</Code>) defienden el ownership de su servicio; los de rol (architect, reviewer, implementer, qa) ejecutan el pipeline.</Lede>
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {tb.agents.map((a) => (
              <Card key={a.name} className="py-0"><CardContent className="p-3.5">
                <b className="font-mono text-xs font-semibold">{a.name}</b>
                <p className="mt-0.5 line-clamp-3 text-[11.5px] leading-relaxed text-muted-foreground">{a.desc || "(sin descripción)"}</p>
              </CardContent></Card>
            ))}
          </div>
        </>
      )}
    </>
  )
}
