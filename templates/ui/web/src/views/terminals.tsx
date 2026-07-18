// Terminales — herdr como terminales de verdad, Y cada una reflejando su
// harness. La idea del usuario: ves herdr corriendo Claude Code / Kimi / Codex,
// y en la misma ventana ves cómo avanza el harness que esa terminal trabaja
// (workspace, tarea, fase). El puente es el cwd del pane: si está dentro del
// workspace del harness (o en worktrees/<tarea>/…), enlazamos su pipeline.
//
// Los "workspaces" de esta vista son los de HERDR (multiplexor, como tmux) —
// todas las terminales de la máquina, tengan harness o no.
import { useEffect, useRef, useState, type ReactNode } from "react"
import { toast } from "sonner"
import { VHead, Lede, Code, Empty } from "@/components/bits"
import { Ansi } from "@/lib/ansi"
import { parsePrompt, type Prompt } from "@/lib/prompt-parse"
import { cn } from "@/lib/utils"
import { op, taskRollup, PHASES, type Snapshot, type HerdrState, type HerdrPane, type TaskRollup } from "@/lib/harness"
import { FolderGit2, Radio, ChevronDown, Check, X, Bot, Boxes, ArrowRight,
  ArrowUp, ArrowDown, ArrowLeft, ArrowRight as ArrowRightIcon, CornerDownLeft, Delete, OctagonX } from "lucide-react"
import { PaneActions, WorkspaceActions, SessionStop } from "@/components/herdr-actions"
import { NewWorkspace, SplitItems, NewTerminalItem } from "@/components/herdr-open"
import type { Go } from "@/App"

const STATUS: Record<string, { label: string; chip: string; dot: string; pulse?: boolean }> = {
  working: { label: "trabajando", chip: "text-(--ok) border-(--ok)/40 bg-(--ok)/10", dot: "bg-(--ok)", pulse: true },
  blocked: { label: "bloqueado — te necesita", chip: "text-(--bad) border-(--bad)/40 bg-(--bad)/10", dot: "bg-(--bad)", pulse: true },
  done: { label: "hecho", chip: "text-(--brand) border-primary/40 bg-primary/10", dot: "bg-primary" },
  idle: { label: "idle", chip: "text-muted-foreground border-white/10", dot: "bg-muted-foreground/50" },
  unknown: { label: "shell", chip: "text-muted-foreground/60 border-white/10", dot: "bg-muted-foreground/30" },
}
const st = (s: string) => STATUS[s] || STATUS.unknown

const PHASE_STATUS: Record<TaskRollup["status"], string> = {
  wait: "text-(--wait)", block: "text-(--bad)", ship: "text-(--ok)", work: "text-(--brand)",
}

// La tira de harness: qué proyecto/tarea/fase trabaja esta terminal. Clic → tarea.
function HarnessStrip({ wsName, task, go }: { wsName: string; task?: TaskRollup; go: Go }) {
  const phases = PHASES.map(([k]) => k)
  const nowIdx = task ? phases.indexOf(task.phase) : -1
  return (
    <button onClick={() => task && go({ name: "task", id: task.id })}
      className={cn("flex w-full items-center gap-2.5 border-b border-white/8 bg-(--brand)/[0.07] px-4 py-1.5 text-left",
        task && "transition-colors hover:bg-(--brand)/[0.12]")}>
      <Boxes className="size-3.5 shrink-0 text-(--brand)" />
      <span className="shrink-0 text-[11px] font-semibold text-(--brand)">{wsName}</span>
      {task ? (
        <>
          <span className="shrink-0 font-mono text-[11px] text-white/70">{task.id}</span>
          <span className="hidden items-center gap-0.5 sm:flex">
            {phases.map((ph, i) => (
              <span key={ph} className={cn("size-1.5 rounded-full",
                i < nowIdx ? "bg-(--brand)/70" : i === nowIdx ? "bg-(--brand) ring-2 ring-(--brand)/25" : "bg-white/15")} />
            ))}
          </span>
          <span className={cn("shrink-0 text-[10.5px] font-semibold uppercase tracking-wide", PHASE_STATUS[task.status])}>
            {task.phase || "—"} · {task.statusLabel}
          </span>
          <span className="ml-auto flex shrink-0 items-center gap-1 text-[10px] text-(--brand) opacity-0 transition-opacity group-hover:opacity-100">
            ver tarea <ArrowRight className="size-3" />
          </span>
        </>
      ) : (
        <span className="text-[10.5px] text-muted-foreground/60">terminal en el harness · sin tarea con worktree aquí</span>
      )}
    </button>
  )
}

// Limpia el volcado del PTY para que se vea como una terminal de verdad y no
// como un TUI "quebrado": quita las líneas en blanco de arriba/abajo y colapsa
// los huecos de 3+ líneas vacías (el área de transcript vacía de Claude Code)
// a una sola. No toca columnas — sólo filas vacías — así las cajas siguen
// alineadas. La "vacuidad" de un renglón se mide sin ANSI.
// eslint-disable-next-line no-control-regex
const ANSI_RE = /\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Z0-9]/g
function tidyScreen(raw: string): string {
  const lines = raw.replace(/\r\n?/g, "\n").split("\n")
  const blank = (l: string) => l.replace(ANSI_RE, "").trim() === ""
  let start = 0, end = lines.length
  while (start < end && blank(lines[start])) start++
  while (end > start && blank(lines[end - 1])) end--
  const out: string[] = []
  let run = 0
  for (let i = start; i < end; i++) {
    if (blank(lines[i])) { run++; if (run <= 1) out.push("") }
    else { run = 0; out.push(lines[i]) }
  }
  return out.join("\n")
}

function Screen({ paneId, open, onText }: { paneId: string; open: boolean; onText?: (t: string) => void }) {
  const [text, setText] = useState<string | null>(null)
  const boxRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    let live = true
    const load = () => fetch(`/api/herdr/pane?id=${encodeURIComponent(paneId)}&fmt=ansi`)
      .then((r) => r.json()).then((d) => { if (live) { setText(d.text ?? ""); onText?.(d.text ?? "") } }).catch(() => {})
    load()
    const iv = setInterval(load, 1200)
    return () => { live = false; clearInterval(iv) }
  }, [paneId, open])
  useEffect(() => { const el = boxRef.current; if (el) el.scrollTop = el.scrollHeight }, [text])
  if (!open) return null
  return (
    <div ref={boxRef} className="terminal-screen max-h-[420px] min-h-[84px] overflow-auto px-4 py-3">
      {text == null ? (
        <span className="text-[11.5px] text-white/30">conectando al PTY…</span>
      ) : (
        <pre className="term-pre whitespace-pre font-mono text-[12.5px] text-[#d4d4dc]">
          <Ansi text={tidyScreen(text)} />
          <span className="term-cursor" />
        </pre>
      )}
    </div>
  )
}

async function sendKeys(paneId: string, keys: string[]) {
  const r = await op("/api/op/herdr-key", { pane: paneId, keys })
  if (!r.ok) toast.error(r.error || "no se pudo")
}

// Un keycap de la barra de control. Manda una tecla cruda al TUI.
function Keycap({ paneId, k, title, children, tone = "normal" }: {
  paneId: string; k: string; title: string; children: ReactNode; tone?: "normal" | "escape" | "danger"
}) {
  return (
    <button onClick={() => sendKeys(paneId, [k])} title={title}
      className={cn("grid h-7 min-w-7 place-items-center rounded-md border px-1.5 font-mono text-[11px] transition-colors",
        tone === "escape" && "border-(--wait)/40 bg-(--wait)/10 text-(--wait) hover:bg-(--wait)/20",
        tone === "danger" && "border-(--bad)/40 bg-(--bad)/10 text-(--bad) hover:bg-(--bad)/20",
        tone === "normal" && "border-white/12 bg-white/[0.05] text-white/70 hover:border-(--brand)/40 hover:bg-(--brand)/10 hover:text-white/90")}>
      {children}
    </button>
  )
}

// Barra de teclas de control — lo que te deja MANEJAR un TUI de pantalla
// completa (el picker de Claude Code, listas, editores): Escape para salir,
// flechas para navegar, Enter/Tab/Backspace y Ctrl-C. Sin esto quedabas
// atrapado en cuanto un agente mostraba algo que no fuera un sí/no simple.
function KeyBar({ paneId }: { paneId: string }) {
  return (
    <div className="flex flex-wrap items-center gap-1.5 border-t border-white/8 bg-[#0b0b0f] px-4 py-1.5">
      <span className="mr-1 text-[9.5px] font-semibold uppercase tracking-wide text-white/25">teclas</span>
      <Keycap paneId={paneId} k="Escape" title="Escape — salir de un menú / picker" tone="escape">esc</Keycap>
      <span className="mx-0.5 h-4 w-px bg-white/10" />
      <Keycap paneId={paneId} k="Up" title="flecha arriba"><ArrowUp className="size-3" /></Keycap>
      <Keycap paneId={paneId} k="Down" title="flecha abajo"><ArrowDown className="size-3" /></Keycap>
      <Keycap paneId={paneId} k="Left" title="flecha izquierda"><ArrowLeft className="size-3" /></Keycap>
      <Keycap paneId={paneId} k="Right" title="flecha derecha"><ArrowRightIcon className="size-3" /></Keycap>
      <span className="mx-0.5 h-4 w-px bg-white/10" />
      <Keycap paneId={paneId} k="Enter" title="Enter — confirmar / seleccionar"><CornerDownLeft className="size-3" /></Keycap>
      <Keycap paneId={paneId} k="Tab" title="Tab — autocompletar / siguiente">tab</Keycap>
      <Keycap paneId={paneId} k="Backspace" title="Backspace — borrar"><Delete className="size-3" /></Keycap>
      <span className="mx-0.5 h-4 w-px bg-white/10" />
      <Keycap paneId={paneId} k="C-c" title="Ctrl-C — interrumpir el proceso" tone="danger"><OctagonX className="size-3" /> ^C</Keycap>
    </div>
  )
}

function InteractiveAnswer({ paneId, prompt }: { paneId: string; prompt: Prompt }) {
  if (!prompt) return null
  return (
    <div className="border-t border-(--wait)/25 bg-(--wait)/[0.06] px-4 py-2.5">
      <div className="mb-1.5 text-[10.5px] font-semibold uppercase tracking-wide text-(--wait)">te está preguntando</div>
      {prompt.question && <p className="mb-2 font-mono text-[11.5px] text-white/80">{prompt.question}</p>}
      <div className="flex flex-wrap gap-2">
        {prompt.kind === "yesno" ? (
          <>
            <button onClick={() => sendKeys(paneId, ["y", "Enter"])}
              className="flex items-center gap-1.5 rounded-md border border-(--ok)/40 bg-(--ok)/10 px-3 py-1.5 text-[12px] font-semibold text-(--ok) transition-colors hover:bg-(--ok)/20">
              <Check className="size-3.5" /> Sí
            </button>
            <button onClick={() => sendKeys(paneId, ["n", "Enter"])}
              className="flex items-center gap-1.5 rounded-md border border-(--bad)/40 bg-(--bad)/10 px-3 py-1.5 text-[12px] font-semibold text-(--bad) transition-colors hover:bg-(--bad)/20">
              <X className="size-3.5" /> No
            </button>
          </>
        ) : (
          prompt.options.map((o) => (
            <button key={o.key} onClick={() => sendKeys(paneId, [o.key])}
              className="flex items-center gap-2 rounded-md border border-white/12 bg-white/[0.04] px-3 py-1.5 text-[12px] text-white/85 transition-colors hover:border-(--brand)/50 hover:bg-(--brand)/10">
              <span className="grid size-4 place-items-center rounded bg-white/10 font-mono text-[10px] text-(--brand)">{o.key}</span>
              {o.label}
            </button>
          ))
        )}
      </div>
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
    if (r.ok) setText(""); else toast.error(r.error || "no se pudo enviar")
  }
  return (
    <div className="flex items-center gap-2 border-t border-white/8 bg-[#0b0b0f] px-4 py-2">
      <span className={cn("font-mono text-[13px] font-bold", busy ? "text-(--wait)" : "text-(--ok)")}>❯</span>
      <input value={text} onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); send() } }}
        placeholder="escríbele al agente — Enter envía directo a su terminal" spellCheck={false}
        className="min-w-0 flex-1 bg-transparent font-mono text-[12px] text-[#e8e8ee] caret-(--ok) outline-none placeholder:text-white/25" />
      {busy && <span className="font-mono text-[10px] text-(--wait)">enviando…</span>}
    </div>
  )
}

// cwd → tarea del harness si está en worktrees/<tarea>/
function taskOfPane(cwd: string): string | null {
  const m = cwd.match(/\/worktrees\/([^/]+)/)
  return m ? m[1] : null
}

function TerminalWindow({ p, tabLabel, canOp, snap, go }: {
  p: HerdrPane; tabLabel?: string; canOp: boolean; snap: Snapshot; go: Go
}) {
  const busy = p.agent_status === "working" || p.agent_status === "blocked"
  const [open, setOpen] = useState(busy)
  const [prompt, setPrompt] = useState<Prompt>(null)
  const s = st(p.agent_status)
  const cwdFull = p.foreground_cwd || p.cwd || ""
  const cwd = cwdFull.replace(/^\/Users\/[^/]+/, "~")
  const wsPath = snap.workspace?.path || ""
  const inHarness = !!wsPath && cwdFull.startsWith(wsPath)
  const taskId = inHarness ? taskOfPane(cwdFull) : null
  const task = taskId ? taskRollup(snap).find((r) => r.id === taskId) : undefined

  return (
    <div className={cn("group overflow-hidden rounded-xl border bg-[#0e0e13] shadow-[0_10px_30px_rgba(0,0,0,.5)] transition-all",
      p.agent_status === "working" ? "border-(--ok)/30" : p.agent_status === "blocked" ? "border-(--bad)/35" : "border-white/10")}>
      <button onClick={() => setOpen((o) => !o)}
        className="flex w-full items-center gap-2.5 border-b border-white/8 bg-gradient-to-b from-white/[0.07] to-transparent px-4 py-2.5 text-left">
        <span className="flex gap-1.5">
          <i className="size-3 rounded-full bg-[#ff5f57]/90" />
          <i className="size-3 rounded-full bg-[#febc2e]/90" />
          <i className={cn("size-3 rounded-full", p.agent_status === "working" ? "bg-[#28c840] animate-pulse" : "bg-[#28c840]/60")} />
        </span>
        {p.program && (
          <span className="ml-1 flex shrink-0 items-center gap-1 rounded-md border border-(--brand)/40 bg-(--brand)/10 px-1.5 py-0.5 text-[10px] font-semibold text-(--brand)">
            <Bot className="size-3" /> {p.program}
          </span>
        )}
        <span className="truncate font-mono text-[12px] font-semibold text-white/85">{tabLabel || p.pane_id}</span>
        <span className="hidden truncate font-mono text-[10.5px] text-white/30 md:inline">{cwd}</span>
        <span className="flex-1" />
        <span className={cn("flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[9px] font-bold uppercase tracking-wider", s.chip)}>
          <i className={cn("size-1.5 rounded-full", s.dot, s.pulse && "animate-pulse")} />{s.label}
        </span>
        {canOp && <span onClick={(e) => e.stopPropagation()}>
          <PaneActions paneId={p.pane_id} tabId={p.tab_id} label={tabLabel || p.pane_id} running={busy} extra={<SplitItems paneId={p.pane_id} />} />
        </span>}
        <ChevronDown className={cn("size-3.5 text-white/30 transition-transform duration-200", !open && "-rotate-90")} />
      </button>
      {inHarness && <HarnessStrip wsName={snap.workspace?.name || "harness"} task={task} go={go} />}
      <Screen paneId={p.pane_id} open={open} onText={(t) => setPrompt(parsePrompt(t))} />
      {open && canOp && prompt && <InteractiveAnswer paneId={p.pane_id} prompt={prompt} />}
      {open && canOp && <KeyBar paneId={p.pane_id} />}
      {open && canOp && <Prompt paneId={p.pane_id} />}
    </div>
  )
}

export function Terminals({ s: snap, go }: { s: Snapshot; go: Go }) {
  const h = (snap.herdr || null) as HerdrState | null
  const canOp = snap.op !== false

  const head = <VHead title="Terminales" sub="lo que corre en TU terminal, y el harness que cada una avanza"
    right={h?.available ? (
      <span className="flex items-center gap-2">
        {canOp && <NewWorkspace />}
        {canOp && <SessionStop />}
        <span className="flex items-center gap-1.5 rounded-full border border-(--ok)/40 bg-(--ok)/8 px-2.5 py-1 text-[10px] font-semibold text-(--ok)">
          <Radio className="size-3 animate-pulse" /> herdr {h.version} · en vivo
        </span>
      </span>
    ) : undefined} />

  if (!h || !h.available)
    return (
      <>
        {head}
        <Empty title="herdr no está conectado">
          <p>{h?.reason || "Este backend no reporta herdr (la vista vive en el daemon)."}</p>
          <p className="pt-1"><b className="text-foreground/80">herdr</b> es un multiplexor de terminales para agentes (opcional, como tmux pero con consciencia de agentes). Corre tus agentes — Claude Code, Kimi, Codex, Vertex — dentro de herdr y esta vista te los muestra <b>todos</b> en vivo, con el harness que cada uno avanza reflejado en su ventana.</p>
          <p className="pt-1 text-muted-foreground/60">Instala herdr, lánzalo con <Code>herdr</Code>, y corre tus agentes dentro. El resto del panel funciona sin él.</p>
        </Empty>
      </>
    )

  const byWs = h.workspaces.map((w) => ({ w, panes: h.panes.filter((p) => p.workspace_id === w.workspace_id) }))
  const working = h.panes.filter((p) => p.agent_status === "working").length
  const blocked = h.panes.filter((p) => p.agent_status === "blocked").length
  const agents = h.panes.filter((p) => p.program).length

  return (
    <>
      {head}
      <Lede>
        Cada ventana es un PTY real de herdr — su programa, su terminal a color, su estado en vivo. La banda
        <span className="mx-1 rounded bg-(--brand)/15 px-1 text-(--brand)">◈ harness</span> aparece cuando la
        terminal trabaja dentro de un workspace del harness: te dice qué tarea avanza y en qué fase va.
        {canOp && <> El prompt <span className="font-mono text-(--ok)">❯</span> y los botones le responden directo.</>}
      </Lede>
      {(working > 0 || blocked > 0 || agents > 0) && (
        <div className="mb-4 flex flex-wrap gap-x-4 gap-y-1 text-[11.5px]">
          {agents > 0 && <span className="flex items-center gap-1.5 text-(--brand)"><Bot className="size-3.5" />{agents} agente{agents > 1 ? "s" : ""}</span>}
          {working > 0 && <span className="flex items-center gap-1.5 font-semibold text-(--ok)"><i className="size-2 animate-pulse rounded-full bg-(--ok)" />{working} trabajando</span>}
          {blocked > 0 && <span className="flex items-center gap-1.5 font-semibold text-(--bad)"><i className="size-2 animate-pulse rounded-full bg-(--bad)" />{blocked} esperándote</span>}
        </div>
      )}
      <div className="grid gap-6">
        {byWs.map(({ w, panes }) => (
          <section key={w.workspace_id}>
            <div className="mb-2 flex items-center gap-2">
              <FolderGit2 className="size-3.5 text-muted-foreground/60" />
              <span className="font-heading text-[13px] font-semibold">{w.label}</span>
              <span className="text-[11.5px] text-muted-foreground/60">workspace de herdr · {w.pane_count} pane{w.pane_count !== 1 ? "s" : ""} · {w.tab_count} tab{w.tab_count !== 1 ? "s" : ""}</span>
              {canOp && <WorkspaceActions wsId={w.workspace_id} label={w.label} wsExtra={<NewTerminalItem wsId={w.workspace_id} />} />}
            </div>
            <div className="grid gap-3.5">
              {panes.length ? panes.map((p) => {
                const tab = h.tabs.find((t) => t.tab_id === p.tab_id)
                return <TerminalWindow key={p.pane_id} p={p} tabLabel={tab?.label} canOp={canOp} snap={snap} go={go} />
              }) : <p className="text-[12px] text-muted-foreground/50">sin panes</p>}
            </div>
          </section>
        ))}
      </div>
    </>
  )
}
