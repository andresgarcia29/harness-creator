// Docs: TODO leído de la instancia real (.claude/commands, agents, Makefile,
// ship.sh, settings.json) — nada de prosa que se pudra. Si un comando no
// existe aquí, no aparece aquí.
import { useState } from "react"
import { Card, CardContent } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { toast } from "sonner"
import { Eye, Gavel, Loader2, Pickaxe } from "lucide-react"
import { VHead, H2, Lede, Code, Empty } from "@/components/bits"
import { op, type Snapshot } from "@/lib/harness"
import { withTarget } from "@/lib/target"

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

// La Ley — TODOS los documentos (DRAFT y ratificados) con visor permanente:
// firmar no te quita poder leerlos, y cada cluster se puede re-excavar
// (arqueología dirigida) cuando su realidad cambie. El panel como
// controlador del harness, no solo espejo.
function LawPanel({ s }: { s: Snapshot }) {
  const [busy, setBusy] = useState("")
  const [viewing, setViewing] = useState("")
  const [content, setContent] = useState<Record<string, string>>({})
  const law = s.law || []
  if (!law.length || s.op === false) return null
  const drafts = law.filter((d) => d.status === "draft")
  const ratify = async (path?: string) => {
    setBusy(path || "@all")
    const r = await op("/api/op/ratify", path ? { path } : { all: true })
    setBusy("")
    if (!r.ok && r.failed?.length) toast.error(`Fallaron: ${r.failed.join(" · ")}`)
    else toast.success(path ? `Ratificado: ${path}` : `${r.ratified?.length || 0} documentos ratificados`)
  }
  const excavate = async (agent: string) => {
    setBusy("exc:" + agent)
    toast.info(`Re-excavando ${agent} — el modelo lee README/migraciones/protos (puede tardar 1-3 min)…`)
    const r = await op("/api/op/excavate", { agent })
    setBusy("")
    setContent({}) // el contenido cambió: invalida el cache del visor
    if (!r.ok) toast.error(r.error || "la arqueología falló")
    else toast.success(`${agent} re-excavado — queda en DRAFT esperando tu firma`)
  }
  const ver = async (path: string) => {
    if (viewing === path) { setViewing(""); return }
    setViewing(path)
    if (!content[path]) {
      const r = await fetch(withTarget(`/api/doc?path=${encodeURIComponent(path)}`)).then((x) => x.json()).catch(() => null)
      setContent((c) => ({ ...c, [path]: r?.ok ? r.content : `(no pude leerlo: ${r?.error || "error"})` }))
    }
  }
  return (
    <div className={cnLaw(drafts.length > 0)}>
      <div className="mb-1 flex items-center gap-2">
        <Gavel className={drafts.length ? "size-4 text-(--wait)" : "size-4 text-(--ok)"} />
        <span className="text-[13.5px] font-medium">
          La ley · {law.length} documento(s){drafts.length ? ` — ${drafts.length} en DRAFT esperando tu firma` : " — toda ratificada"}
        </span>
        {drafts.length > 0 && (
          <Button size="sm" className="ml-auto gap-1.5" disabled={busy !== ""} onClick={() => ratify()}>
            {busy === "@all" && <Loader2 className="size-3.5 animate-spin" />} Ratificar todos
          </Button>
        )}
      </div>
      <p className="mb-3 text-[11.5px] text-muted-foreground">
        La arqueología propone; los humanos ratifican. <b>«Ver» abre cualquier documento</b> (firmado
        o no). <b>«Re-excavar»</b> vuelve a correr la arqueología de ese cluster (queda en DRAFT
        hasta que firmes de nuevo) — útil cuando el servicio cambió de verdad.
      </p>
      <div className="divide-y rounded-xl border bg-card">
        {law.map((d) => (
          <div key={d.path}>
            <div className="flex items-center gap-2.5 px-3 py-1.5">
              <Badge variant="outline" className="text-[9.5px]">{d.kind}</Badge>
              {d.status === "draft"
                ? <Badge variant="outline" className="border-(--wait)/50 text-[9.5px] text-(--wait)">DRAFT</Badge>
                : d.status === "ratified"
                  ? <Badge variant="outline" className="border-(--ok)/50 text-[9.5px] text-(--ok)">RATIFICADA</Badge>
                  : null}
              <span className="text-[12.5px]">{d.title}</span>
              <span className="truncate font-mono text-[10.5px] text-muted-foreground/60">{d.path}</span>
              <Button size="sm" variant="ghost" className="ml-auto h-6 shrink-0 gap-1 text-[11px]"
                onClick={() => ver(d.path)}>
                <Eye className="size-3" /> {viewing === d.path ? "Cerrar" : "Ver"}
              </Button>
              {d.agent && (
                <Button size="sm" variant="ghost" className="h-6 shrink-0 gap-1 text-[11px] text-muted-foreground"
                  disabled={busy !== ""} onClick={() => excavate(d.agent!)}>
                  {busy === "exc:" + d.agent ? <Loader2 className="size-3 animate-spin" /> : <Pickaxe className="size-3" />}
                  Re-excavar
                </Button>
              )}
              {d.status === "draft" && (
                <Button size="sm" variant="outline" className="h-6 shrink-0 text-[11px]"
                  disabled={busy !== ""} onClick={() => ratify(d.path)}>
                  {busy === d.path ? <Loader2 className="size-3 animate-spin" /> : "Ratificar"}
                </Button>
              )}
            </div>
            {viewing === d.path && (
              <pre className="max-h-80 overflow-auto border-t bg-muted/30 p-3 font-mono text-[11px] leading-relaxed whitespace-pre-wrap">
                {content[d.path] ?? "cargando…"}
              </pre>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}

function cnLaw(hasDrafts: boolean): string {
  return hasDrafts
    ? "mb-6 rounded-2xl border border-(--wait)/45 bg-(--wait)/8 p-4"
    : "mb-6 rounded-2xl border p-4"
}

export function Docs({ s }: { s: Snapshot }) {
  const tb = s.toolbox
  if (!tb) return <Empty><p>El server todavía no reporta el inventario.</p></Empty>
  const empty = !tb.commands.length && !tb.make.length && !tb.agents.length
  return (
    <>
      <VHead title="Docs" sub={<>leído de esta instancia en vivo{tb.version ? <> · harness <b className="font-mono">v{tb.version}</b></> : null}</>} />
      <LawPanel s={s} />
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
