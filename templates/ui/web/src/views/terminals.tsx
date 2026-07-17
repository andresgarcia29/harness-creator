// Terminales (herdr) — TODAS las terminales de agentes de la máquina, en vivo.
// El estado llega por el SSE del snapshot (tiempo real, sin polling extra);
// el TEXTO del terminal de un pane abierto se relee cada 1.5 s. Con op:true
// puedes RESPONDERLE a cualquier agente (herdr pane run → texto + Enter):
// Claude Code, OpenCode, Codex, Kimi — uniforme, porque es el PTY.
import { useEffect, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { ScrollArea } from "@/components/ui/scroll-area"
import { toast } from "sonner"
import { VHead, H2, Lede, Code, Empty } from "@/components/bits"
import { cn } from "@/lib/utils"
import { op, type Snapshot, type HerdrState, type HerdrPane } from "@/lib/harness"
import { Terminal, FolderGit2, ChevronRight, SendHorizontal, Radio } from "lucide-react"

const STATUS: Record<string, { label: string; cls: string; dot: string; pulse?: boolean }> = {
  working: { label: "trabajando", cls: "text-(--ok) border-(--ok)/40 bg-(--ok)/8", dot: "bg-(--ok)", pulse: true },
  blocked: { label: "bloqueado", cls: "text-(--bad) border-(--bad)/40 bg-(--bad)/8", dot: "bg-(--bad)", pulse: true },
  done: { label: "hecho", cls: "text-(--brand) border-primary/40 bg-primary/8", dot: "bg-primary" },
  idle: { label: "idle", cls: "text-muted-foreground border-border", dot: "bg-muted-foreground/40" },
  unknown: { label: "—", cls: "text-muted-foreground/50 border-border", dot: "bg-muted-foreground/25" },
}
const st = (s: string) => STATUS[s] || STATUS.unknown

function LiveTerminal({ paneId }: { paneId: string }) {
  const [text, setText] = useState<string | null>(null)
  const boxRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    let live = true
    const load = () => fetch(`/api/herdr/pane?id=${encodeURIComponent(paneId)}`)
      .then((r) => r.json()).then((d) => { if (live) setText(d.text ?? "") }).catch(() => {})
    load()
    const iv = setInterval(load, 1500)
    return () => { live = false; clearInterval(iv) }
  }, [paneId])
  useEffect(() => {
    const el = boxRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [text])
  if (text == null) return <div className="px-3 py-2 text-[11px] text-muted-foreground/50">leyendo…</div>
  return (
    <ScrollArea ref={boxRef as any} className="max-h-[300px] overflow-auto bg-black/40">
      <pre className="whitespace-pre-wrap px-3.5 py-2.5 font-mono text-[11px] leading-relaxed text-muted-foreground">
        {text.trimEnd() || "(pantalla vacía)"}
      </pre>
    </ScrollArea>
  )
}

// Responder a un agente por su PTY — texto + Enter, como si tecleara el humano.
function PaneRespond({ paneId }: { paneId: string }) {
  const [text, setText] = useState("")
  const [busy, setBusy] = useState(false)
  const send = async () => {
    if (!text.trim()) return
    setBusy(true)
    const r = await op("/api/op/pane-send", { pane: paneId, text: text.trim() })
    setBusy(false)
    if (r.ok) { toast.success("Enviado al agente — lo verás en su terminal."); setText("") }
    else toast.error(r.error || "no se pudo enviar")
  }
  return (
    <div className="flex items-center gap-2 border-t border-border bg-secondary/30 px-3 py-2">
      <SendHorizontal className="size-3.5 shrink-0 text-muted-foreground/50" />
      <Input value={text} onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send() } }}
        placeholder="responder al agente — texto + Enter directo a su terminal"
        className="h-8 border-0 bg-transparent font-mono text-[12px] shadow-none focus-visible:ring-0" />
      <Button size="sm" variant="ghost" onClick={send} disabled={busy || !text.trim()} className="h-7 px-2.5 text-[11.5px] text-(--brand)">
        {busy ? "…" : "Enviar"}
      </Button>
    </div>
  )
}

function PaneRow({ p, tabLabel, canOp }: { p: HerdrPane; tabLabel?: string; canOp: boolean }) {
  const [open, setOpen] = useState(p.agent_status === "working" || p.agent_status === "blocked")
  const s = st(p.agent_status)
  return (
    <div className="border-b border-border last:border-b-0">
      <button onClick={() => setOpen((o) => !o)} className="flex w-full items-center gap-3 px-3.5 py-2.5 text-left transition-colors hover:bg-secondary/40">
        <ChevronRight className={cn("size-3.5 shrink-0 text-muted-foreground/50 transition-transform duration-200", open && "rotate-90")} />
        <span className={cn("size-2 shrink-0 rounded-full transition-colors", s.dot, s.pulse && "animate-pulse")} />
        <Terminal className="size-3.5 shrink-0 text-muted-foreground/60" />
        <span className="font-mono text-[12px] font-medium">{tabLabel || p.pane_id}</span>
        <span className="min-w-0 flex-1 truncate font-mono text-[10.5px] text-muted-foreground/50">{p.foreground_cwd || p.cwd}</span>
        <span className={cn("shrink-0 rounded-full border px-2 py-0.5 text-[9.5px] font-semibold uppercase tracking-wider", s.cls)}>{s.label}</span>
      </button>
      {open && (
        <>
          <LiveTerminal paneId={p.pane_id} />
          {canOp && <PaneRespond paneId={p.pane_id} />}
        </>
      )}
    </div>
  )
}

export function Terminals({ s: snap }: { s: Snapshot }) {
  const h = (snap.herdr || null) as HerdrState | null
  const canOp = snap.op !== false

  const head = <VHead title="Terminales" sub="todas las terminales de agentes de la máquina — en vivo, cross-workspace"
    right={h?.available ? (
      <span className="flex items-center gap-1.5 rounded-full border border-(--ok)/40 bg-(--ok)/8 px-2.5 py-1 text-[10px] font-semibold text-(--ok)">
        <Radio className="size-3 animate-pulse" /> herdr {h.version}
      </span>
    ) : undefined} />

  if (!h || !h.available)
    return (
      <>
        {head}
        <Empty title="herdr no está conectado">
          <p>{h?.reason || "Este backend no reporta herdr (la vista vive en el daemon)."}</p>
          <p className="pt-1"><b className="text-foreground/80">herdr</b> es un multiplexor de terminales para agentes (opcional). Si corres tus agentes — Claude Code, OpenCode, Codex, Kimi — dentro de herdr, esta vista te muestra <b>todos</b> en vivo: su estado, su terminal, y puedes <b>responderles desde aquí</b>. Funciona en tu máquina, un VPS o un pod.</p>
          <p className="pt-1 text-muted-foreground/60">Instala herdr, lánzalo con <Code>herdr</Code>, corre tus agentes dentro, y esta vista aparece sola. El resto del panel funciona sin herdr.</p>
        </Empty>
      </>
    )

  const byWs = h.workspaces.map((w) => ({ w, panes: h.panes.filter((p) => p.workspace_id === w.workspace_id) }))
  const working = h.panes.filter((p) => p.agent_status === "working").length
  const blocked = h.panes.filter((p) => p.agent_status === "blocked").length

  return (
    <>
      {head}
      <Lede>
        El estado llega en tiempo real por el stream; el terminal de un pane abierto se relee cada 1.5 s.
        {canOp && <> Escribe abajo de un terminal para <b>responderle al agente</b> — va directo a su PTY, funciona con cualquier CLI.</>}
      </Lede>
      <div className="mb-4 flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-muted-foreground/70">
        {working > 0 && <span className="flex items-center gap-1.5 font-semibold text-(--ok)"><i className="size-2 animate-pulse rounded-full bg-(--ok)" />{working} trabajando</span>}
        {blocked > 0 && <span className="flex items-center gap-1.5 font-semibold text-(--bad)"><i className="size-2 animate-pulse rounded-full bg-(--bad)" />{blocked} bloqueado{blocked > 1 ? "s" : ""} — te necesita</span>}
        {(["done", "idle"] as const).map((k) => (
          <span key={k} className="flex items-center gap-1.5"><i className={cn("size-2 rounded-full", st(k).dot)} />{st(k).label}</span>
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
                  return <PaneRow key={p.pane_id} p={p} tabLabel={tab?.label} canOp={canOp} />
                }) : <div className="px-3.5 py-3 text-[12px] text-muted-foreground/50">sin panes</div>}
              </CardContent>
            </Card>
          </div>
        ))}
      </div>
    </>
  )
}
