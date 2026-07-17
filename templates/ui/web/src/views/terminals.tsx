// Terminales (herdr) — el estado vivo de TODOS los agentes en la máquina, no
// solo lo que este daemon lanzó. herdr es OPCIONAL: si no está, la vista enseña
// qué es y qué desbloquea. Cross-workspace a propósito: ves corvux, latam, el
// pod… todo en un vidrio. Lee /api/herdr (solo lo sirve el daemon).
import { useEffect, useState } from "react"
import { Card, CardContent } from "@/components/ui/card"
import { ScrollArea } from "@/components/ui/scroll-area"
import { VHead, H2, Lede, Code, Empty } from "@/components/bits"
import { cn } from "@/lib/utils"
import type { HerdrState, HerdrPane } from "@/lib/harness"
import { Terminal, FolderGit2, ChevronRight } from "lucide-react"

const STATUS: Record<string, { label: string; cls: string; pulse?: boolean }> = {
  working: { label: "trabajando", cls: "text-(--ok) border-(--ok)/40 bg-(--ok)/8", pulse: true },
  blocked: { label: "bloqueado", cls: "text-(--bad) border-(--bad)/40 bg-(--bad)/8" },
  done: { label: "hecho", cls: "text-(--brand) border-primary/40 bg-primary/8" },
  idle: { label: "idle", cls: "text-muted-foreground border-border" },
  unknown: { label: "—", cls: "text-muted-foreground/50 border-border" },
}
const st = (s: string) => STATUS[s] || STATUS.unknown

function LiveTerminal({ paneId }: { paneId: string }) {
  const [text, setText] = useState<string | null>(null)
  useEffect(() => {
    let live = true
    const load = () => fetch(`/api/herdr/pane?id=${encodeURIComponent(paneId)}`)
      .then((r) => r.json()).then((d) => { if (live) setText(d.text ?? "") }).catch(() => {})
    load()
    const iv = setInterval(load, 2500) // en vivo: relee el terminal cada 2.5 s
    return () => { live = false; clearInterval(iv) }
  }, [paneId])
  if (text == null) return <div className="px-3 py-2 text-[11px] text-muted-foreground/50">leyendo…</div>
  return (
    <ScrollArea className="max-h-[280px] overflow-auto bg-black/40">
      <pre className="whitespace-pre-wrap px-3 py-2 font-mono text-[11px] leading-relaxed text-muted-foreground">
        {text.trimEnd() || "(pantalla vacía)"}
      </pre>
    </ScrollArea>
  )
}

function PaneRow({ p, tabLabel }: { p: HerdrPane; tabLabel?: string }) {
  const [open, setOpen] = useState(p.agent_status === "working" || p.agent_status === "blocked")
  const s = st(p.agent_status)
  return (
    <div className="border-b border-border last:border-b-0">
      <button onClick={() => setOpen((o) => !o)} className="flex w-full items-center gap-3 px-3.5 py-2.5 text-left transition-colors hover:bg-secondary/40">
        <ChevronRight className={cn("size-3.5 shrink-0 text-muted-foreground/50 transition-transform", open && "rotate-90")} />
        <span className={cn("size-2 shrink-0 rounded-full", s.pulse && "animate-pulse", p.agent_status === "working" ? "bg-(--ok)" : p.agent_status === "blocked" ? "bg-(--bad)" : p.agent_status === "done" ? "bg-primary" : "bg-muted-foreground/30")} />
        <Terminal className="size-3.5 shrink-0 text-muted-foreground/60" />
        <span className="font-mono text-[12px] font-medium">{tabLabel || p.pane_id}</span>
        <span className="min-w-0 flex-1 truncate font-mono text-[10.5px] text-muted-foreground/50">{p.foreground_cwd || p.cwd}</span>
        <span className={cn("shrink-0 rounded-full border px-2 py-0.5 text-[9.5px] font-semibold uppercase tracking-wider", s.cls)}>{s.label}</span>
      </button>
      {open && <LiveTerminal paneId={p.pane_id} />}
    </div>
  )
}

export function Terminals() {
  const [h, setH] = useState<HerdrState | null>(null)
  useEffect(() => {
    let live = true
    const load = () => fetch("/api/herdr").then((r) => r.json()).then((d) => { if (live) setH(d) }).catch(() => { if (live) setH({ available: false } as HerdrState) })
    load()
    const iv = setInterval(load, 3000)
    return () => { live = false; clearInterval(iv) }
  }, [])

  const head = <VHead title="Terminales" sub="todas las terminales de agentes de la máquina — en vivo, cross-workspace"
    right={h?.available ? <span className="rounded-full border border-(--ok)/40 bg-(--ok)/8 px-2.5 py-1 text-[10px] font-semibold text-(--ok)">herdr {h.version}</span> : undefined} />

  if (!h) return <>{head}</>
  if (!h.available)
    return (
      <>
        {head}
        <Empty title="herdr no está conectado">
          <p>{h.reason || "El panel no encontró herdr en esta máquina."}</p>
          <p className="pt-1"><b className="text-foreground/80">herdr</b> es un multiplexor de terminales para agentes (opcional). Si corres tus agentes — Claude Code, OpenCode, Codex, Kimi — dentro de herdr, esta vista te muestra <b>todos</b> en vivo: su estado (trabajando/bloqueado/hecho), su terminal, y desde dónde: tu máquina, un VPS o un pod.</p>
          <p className="pt-1 text-muted-foreground/60">Instálalo (<Code>brew install herdr</Code> o su web), lanza <Code>herdr</Code>, y corre tus agentes dentro. Esta vista aparece sola. El resto del panel funciona sin herdr.</p>
        </Empty>
      </>
    )

  const byWs = h.workspaces.map((w) => ({
    w,
    panes: h.panes.filter((p) => p.workspace_id === w.workspace_id),
  }))
  const anyAgent = h.agents.length > 0 || h.panes.some((p) => p.agent_status === "working" || p.agent_status === "blocked")

  return (
    <>
      {head}
      <Lede>
        Cada workspace de herdr y sus panes, con el estado del agente en vivo. Clic para ver su terminal
        (se relee cada 2.5 s). {!anyAgent && <>Ahora mismo no hay ningún agente <b>trabajando</b>: lanza Claude Code dentro de un pane de herdr y lo verás aquí con su estado y su salida.</>}
      </Lede>
      <div className="mb-3 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-muted-foreground/70">
        {(["working", "blocked", "done", "idle"] as const).map((k) => (
          <span key={k} className="flex items-center gap-1.5">
            <i className={cn("size-2 rounded-full", k === "working" ? "bg-(--ok)" : k === "blocked" ? "bg-(--bad)" : k === "done" ? "bg-primary" : "bg-muted-foreground/30")} />
            {st(k).label}
          </span>
        ))}
      </div>
      <div className="grid gap-3">
        {byWs.map(({ w, panes }) => (
          <div key={w.workspace_id}>
            <H2 sub={`${w.pane_count} pane${w.pane_count !== 1 ? "s" : ""} · ${w.tab_count} tab${w.tab_count !== 1 ? "s" : ""}`}>
              <span className="flex items-center gap-2 normal-case tracking-normal">
                <FolderGit2 className="size-3.5 text-muted-foreground/60" />{w.label}
              </span>
            </H2>
            <Card className="overflow-hidden py-0">
              <CardContent className="p-0">
                {panes.length ? panes.map((p) => {
                  const tab = h.tabs.find((t) => t.tab_id === p.tab_id)
                  return <PaneRow key={p.pane_id} p={p} tabLabel={tab?.label} />
                }) : <div className="px-3.5 py-3 text-[12px] text-muted-foreground/50">sin panes</div>}
              </CardContent>
            </Card>
          </div>
        ))}
      </div>
    </>
  )
}
