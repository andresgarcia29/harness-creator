// Terminales — las terminales de herdr como VENTANAS DE TERMINAL de verdad:
// chrome de ventana (semáforo + título + estado), pantalla negra con ANSI a
// color, cursor de bloque parpadeante, y un prompt ❯ para responderle al
// agente por su PTY. El estado llega por el SSE; el texto de un pane abierto
// se relee cada 1.5 s.
//
// OJO conceptual (y está dicho en pantalla): los "workspaces" de esta vista
// son los de HERDR — el multiplexor organiza TU terminal en workspaces/tabs/
// panes, como tmux. No son los workspaces del harness: son todas las
// terminales de la máquina, tengan harness o no.
import { useEffect, useRef, useState } from "react"
import { toast } from "sonner"
import { VHead, Lede, Code, Empty } from "@/components/bits"
import { Ansi } from "@/lib/ansi"
import { cn } from "@/lib/utils"
import { op, type Snapshot, type HerdrState, type HerdrPane } from "@/lib/harness"
import { FolderGit2, Radio, ChevronDown } from "lucide-react"
import { PaneActions, WorkspaceActions } from "@/components/herdr-actions"

const STATUS: Record<string, { label: string; chip: string; dot: string; pulse?: boolean }> = {
  working: { label: "trabajando", chip: "text-(--ok) border-(--ok)/40 bg-(--ok)/10", dot: "bg-(--ok)", pulse: true },
  blocked: { label: "bloqueado — te necesita", chip: "text-(--bad) border-(--bad)/40 bg-(--bad)/10", dot: "bg-(--bad)", pulse: true },
  done: { label: "hecho", chip: "text-(--brand) border-primary/40 bg-primary/10", dot: "bg-primary" },
  idle: { label: "idle", chip: "text-muted-foreground border-white/10", dot: "bg-muted-foreground/50" },
  unknown: { label: "shell", chip: "text-muted-foreground/60 border-white/10", dot: "bg-muted-foreground/30" },
}
const st = (s: string) => STATUS[s] || STATUS.unknown

function Screen({ paneId, open }: { paneId: string; open: boolean }) {
  const [text, setText] = useState<string | null>(null)
  const boxRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    let live = true
    const load = () => fetch(`/api/herdr/pane?id=${encodeURIComponent(paneId)}&fmt=ansi`)
      .then((r) => r.json()).then((d) => { if (live) setText(d.text ?? "") }).catch(() => {})
    load()
    const iv = setInterval(load, 1500)
    return () => { live = false; clearInterval(iv) }
  }, [paneId, open])
  useEffect(() => {
    const el = boxRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [text])
  if (!open) return null
  return (
    <div ref={boxRef} className="terminal-screen max-h-[340px] min-h-[80px] overflow-auto px-3.5 py-2.5">
      {text == null ? (
        <span className="text-[11.5px] text-white/30">conectando al PTY…</span>
      ) : (
        <pre className="whitespace-pre-wrap break-words font-mono text-[11.5px] leading-[1.5] text-[#c9c9d1]">
          <Ansi text={text.trimEnd()} />
          <span className="term-cursor" />
        </pre>
      )}
    </div>
  )
}

function Prompt({ paneId }: { paneId: string }) {
  const [text, setText] = useState("")
  const [busy, setBusy] = useState(false)
  const send = async () => {
    if (!text.trim() || busy) return
    setBusy(true)
    const r = await op("/api/op/pane-send", { pane: paneId, text: text.trim() })
    setBusy(false)
    if (r.ok) setText("")
    else toast.error(r.error || "no se pudo enviar")
  }
  return (
    <div className="flex items-center gap-2 border-t border-white/8 bg-[#0b0b0f] px-3.5 py-2">
      <span className={cn("font-mono text-[13px] font-bold", busy ? "text-(--wait)" : "text-(--ok)")}>❯</span>
      <input value={text} onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); send() } }}
        placeholder="escríbele al agente — Enter envía directo a su terminal"
        spellCheck={false}
        className="min-w-0 flex-1 bg-transparent font-mono text-[12px] text-[#e8e8ee] caret-(--ok) outline-none placeholder:text-white/25" />
      {busy && <span className="font-mono text-[10px] text-(--wait)">enviando…</span>}
    </div>
  )
}

// Una VENTANA de terminal: chrome (semáforo + título + cwd + estado) + pantalla.
function TerminalWindow({ p, tabLabel, canOp }: { p: HerdrPane; tabLabel?: string; canOp: boolean }) {
  const busy = p.agent_status === "working" || p.agent_status === "blocked"
  const [open, setOpen] = useState(busy)
  const s = st(p.agent_status)
  const cwd = (p.foreground_cwd || p.cwd || "").replace(/^\/Users\/[^/]+/, "~")
  return (
    <div className={cn(
      "overflow-hidden rounded-xl border bg-[#0e0e13] shadow-[0_8px_28px_rgba(0,0,0,.45)] transition-all",
      p.agent_status === "working" ? "border-(--ok)/30" : p.agent_status === "blocked" ? "border-(--bad)/35" : "border-white/10",
    )}>
      <button onClick={() => setOpen((o) => !o)}
        className="flex w-full items-center gap-2.5 border-b border-white/8 bg-gradient-to-b from-white/6 to-transparent px-3.5 py-2 text-left">
        <span className="flex gap-1.5">
          <i className="size-2.5 rounded-full bg-[#ff5f57]/90" />
          <i className="size-2.5 rounded-full bg-[#febc2e]/90" />
          <i className={cn("size-2.5 rounded-full", p.agent_status === "working" ? "bg-[#28c840] animate-pulse" : "bg-[#28c840]/60")} />
        </span>
        <span className="ml-1 truncate font-mono text-[11.5px] font-semibold text-white/85">
          {tabLabel || p.pane_id}
        </span>
        <span className="hidden truncate font-mono text-[10px] text-white/30 sm:inline">{cwd}</span>
        <span className="flex-1" />
        <span className={cn("flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[9px] font-bold uppercase tracking-wider", s.chip)}>
          <i className={cn("size-1.5 rounded-full", s.dot, s.pulse && "animate-pulse")} />{s.label}
        </span>
        {canOp && <span onClick={(e) => e.stopPropagation()}><PaneActions paneId={p.pane_id} label={tabLabel || p.pane_id} running={busy} /></span>}
        <ChevronDown className={cn("size-3.5 text-white/30 transition-transform duration-200", !open && "-rotate-90")} />
      </button>
      <Screen paneId={p.pane_id} open={open} />
      {open && canOp && <Prompt paneId={p.pane_id} />}
    </div>
  )
}

export function Terminals({ s: snap }: { s: Snapshot }) {
  const h = (snap.herdr || null) as HerdrState | null
  const canOp = snap.op !== false

  const head = <VHead title="Terminales" sub="lo que corre en TU terminal, visto desde el panel"
    right={h?.available ? (
      <span className="flex items-center gap-1.5 rounded-full border border-(--ok)/40 bg-(--ok)/8 px-2.5 py-1 text-[10px] font-semibold text-(--ok)">
        <Radio className="size-3 animate-pulse" /> herdr {h.version} · en vivo
      </span>
    ) : undefined} />

  if (!h || !h.available)
    return (
      <>
        {head}
        <Empty title="herdr no está conectado">
          <p>{h?.reason || "Este backend no reporta herdr (la vista vive en el daemon)."}</p>
          <p className="pt-1"><b className="text-foreground/80">herdr</b> es un multiplexor de terminales para agentes (opcional, como tmux pero con consciencia de agentes). Corre tus agentes — Claude Code, OpenCode, Codex, Kimi — dentro de herdr y esta vista te los muestra <b>todos</b>: su terminal a color, su estado, y les respondes desde aquí.</p>
          <p className="pt-1 text-muted-foreground/60">Instala herdr, lánzalo con <Code>herdr</Code>, y corre tus agentes dentro. El resto del panel funciona sin él.</p>
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
        Estos son los <b>workspaces de herdr</b> — tu multiplexor organiza la terminal en workspaces/tabs/panes
        (como tmux) y aquí ves <b>todas</b> las terminales de la máquina, tengan harness o no. Cada ventana es un
        PTY real: colores reales, estado en vivo{canOp && <>, y el prompt <span className="font-mono text-(--ok)">❯</span> le
        escribe directo al agente</>}. Un shell en reposo se ve como lo que es: un shell.
      </Lede>
      {(working > 0 || blocked > 0) && (
        <div className="mb-4 flex flex-wrap gap-x-4 gap-y-1 text-[11.5px]">
          {working > 0 && <span className="flex items-center gap-1.5 font-semibold text-(--ok)"><i className="size-2 animate-pulse rounded-full bg-(--ok)" />{working} trabajando</span>}
          {blocked > 0 && <span className="flex items-center gap-1.5 font-semibold text-(--bad)"><i className="size-2 animate-pulse rounded-full bg-(--bad)" />{blocked} esperándote</span>}
        </div>
      )}
      <div className="grid gap-6">
        {byWs.map(({ w, panes }) => (
          <section key={w.workspace_id}>
            <div className="mb-1.5 mt-7 flex items-center gap-2 first:mt-0">
              <FolderGit2 className="size-3.5 text-muted-foreground/60" />
              <span className="font-heading text-[13px] font-semibold">{w.label}</span>
              <span className="text-[11.5px] text-muted-foreground/60">workspace de herdr · {w.pane_count} pane{w.pane_count !== 1 ? "s" : ""} · {w.tab_count} tab{w.tab_count !== 1 ? "s" : ""}</span>
              {canOp && <WorkspaceActions wsId={w.workspace_id} label={w.label} />}
            </div>
            <div className="grid gap-3.5">
              {panes.length ? panes.map((p) => {
                const tab = h.tabs.find((t) => t.tab_id === p.tab_id)
                return <TerminalWindow key={p.pane_id} p={p} tabLabel={tab?.label} canOp={canOp} />
              }) : <p className="text-[12px] text-muted-foreground/50">sin panes</p>}
            </div>
          </section>
        ))}
      </div>
    </>
  )
}
