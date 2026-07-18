// La lógica del panel, portada 1:1 del app.html anterior — las derivaciones
// son REALES y se explican en pantalla (leyes de honestidad intactas).
import { getTarget } from "@/lib/target"

export const PHASES: [string, string][] = [
  ["intake", "Intake"], ["rfc", "RFC"], ["implement", "Implement"],
  ["review", "Review"], ["ship", "Ship"], ["deploy", "Deploy"], ["archive", "Archive"],
]

export const BUSKINDS = ["gate", "stop", "assumption", "decision", "phase", "ship", "deploy"]

const nf = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 })
export const n = (x?: number) => nf.format(x || 0)
export const usd = (x?: number | null) => (x == null ? "—" : "$" + x.toFixed(2))
export const hhmm = (ts: number) =>
  new Date(ts * 1000).toLocaleTimeString("es", { hour12: false, hour: "2-digit", minute: "2-digit" })
export const dur = (s: number) =>
  s < 60 ? Math.max(0, Math.round(s)) + " s" : s < 3600 ? Math.round(s / 60) + " min" : (s / 3600).toFixed(1) + " h"

// Toda hora del panel acepta epoch (sesiones/agentes) o ISO (bus) → epoch seg.
export const toEpoch = (ts: number | string): number => {
  if (typeof ts === "number") return ts
  const t = Date.parse(ts)
  return isNaN(t) ? 0 : t / 1000
}
const MESES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]
const dayKey = (d: Date) => `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`
// Fecha absoluta corta y humana: "hoy 14:02", "ayer 19:30", "17 jul 14:02".
export function fecha(ts: number | string): string {
  const e = toEpoch(ts); if (!e) return "—"
  const d = new Date(e * 1000), now = new Date()
  const hm = hhmm(e)
  const yst = new Date(now); yst.setDate(now.getDate() - 1)
  if (dayKey(d) === dayKey(now)) return `hoy ${hm}`
  if (dayKey(d) === dayKey(yst)) return `ayer ${hm}`
  const y = d.getFullYear() === now.getFullYear() ? "" : ` ${d.getFullYear()}`
  return `${d.getDate()} ${MESES[d.getMonth()]}${y} ${hm}`
}
// Tiempo relativo: "ahora", "hace 20 min", "hace 3 h", "hace 2 días".
export function rel(ts: number | string): string {
  const e = toEpoch(ts); if (!e) return ""
  const s = Date.now() / 1000 - e
  if (s < 60) return "ahora"
  if (s < 3600) return `hace ${Math.round(s / 60)} min`
  if (s < 86400) return `hace ${Math.round(s / 3600)} h`
  return `hace ${Math.round(s / 86400)} días`
}
// Etiqueta de día para agrupar la historia: "Hoy", "Ayer", "mié 17 jul".
export function diaLabel(ts: number | string): string {
  const e = toEpoch(ts); if (!e) return ""
  const d = new Date(e * 1000), now = new Date()
  const yst = new Date(now); yst.setDate(now.getDate() - 1)
  if (dayKey(d) === dayKey(now)) return "Hoy"
  if (dayKey(d) === dayKey(yst)) return "Ayer"
  const dow = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"][d.getDay()]
  return `${dow} ${d.getDate()} ${MESES[d.getMonth()]}`
}

export type Agent = {
  id: string; type?: string; desc?: string; model?: string; active: boolean
  first_ts: number; last_ts: number; idle: number; elapsed: number
  usage: { in: number; out: number; cache_read: number; cache_creation: number }
  cost: number | null; last_text?: string; depth?: number
}
export type Session = {
  id: string; short: string; model?: string; n_agents: number; n_active: number
  peak: number; idle: number; tokens: { out: number; cache_read: number }
  cost: number | null; last_text?: string; agents: Agent[]
  // live_by: CÓMO sabemos que vive. "herdr"/"live" = corre AHORA (verdad de
  // campo, no mtime); "recent" = activa hace poco, sin confirmar; "" = reposo.
  live_by?: string
  cwd?: string // ancla su TAREA (worktrees/<id>/): una sesión vive en una tarea
}
export type BusEvent = { ts: string; kind: string; task?: string; actor?: string; summary: string; ok?: boolean }
export type Task = {
  id: string; title?: string; origin?: string; phase?: string | null
  done: string[]; verdicts: { pass: number; total: number }; assumptions: string[]
}
export type Snapshot = {
  ts: number; sessions: Session[]; events: BusEvent[]; tasks: Task[]
  tokens: { out: number; cache_read: number }; cost: number | null
  days?: { day: string; cost: number | null; unpriced?: boolean; by_model?: Record<string, number> }[]
  models?: { model: string; in: number; out: number; cache_read: number; cache_creation: number; cost: number | null }[]
  prices?: Record<string, { input: number; output: number }>
  unpriced?: string[]; warning?: string | null
  connections?: Record<string, boolean>; runs?: { task: string; session: string; kind: string }[]
  mode?: string; op?: boolean; workspace?: { name: string; path: string }
  toolbox?: Toolbox; mcp?: McpServer[]; herdr?: HerdrState | null
  targets?: HerdrTarget[]; archived_tasks?: string[]
  init?: InitState | null
}
// ── el wizard de onboarding (plano de init, ADR-0011 del daemon) ──
// El servidor es la verdad del estado: la UI solo manda acciones y deriva.
export type InitStatus = "pending" | "running" | "ok" | "fail" | "skipped"
export type InitStep = {
  id: string; title: string; status: InitStatus
  detail?: string; error?: string; logs_tail?: string[]
}
export type InitRepo = { full_name: string; ref?: string; status: InitStatus; error?: string }
export type InitState = {
  active: boolean; step: string; steps: InitStep[]
  workspace_path?: string; target?: string; completed_at?: number
  github?: { mode: "gh" | "pat"; user: string } | null
  repos?: InitRepo[]
}
export type Toolbox = {
  version: string
  commands: { name: string; desc: string; args: string }[]
  agents: { name: string; desc: string }[]
  make: { target: string; desc: string }[]
  gates: string[]; hooks: string[]
  skills: { name: string; desc: string; ok: boolean }[]
}
export type McpProbe = { ok: boolean; ms: number; server?: string; version?: string; error?: string; auth_hint?: boolean; at?: string; tools?: string[] }
export type McpServer = {
  name: string; command: string; args: string[]; wrapped: boolean
  bin_ok: boolean; secrets_ok: boolean | null; env: string[]; probe?: McpProbe | null
}
// drill-down de razonamiento (on-demand, /api/session)
export type ThreadItem = { k: "text" | "think" | "tool"; ts: number; t: string; inp?: string }
export type AgentDetail = {
  id: string; who: string; type: string; model: string; active: boolean; depth: number
  first_ts: number; last_ts: number; elapsed: number
  usage: { in: number; out: number; cache_read: number; cache_creation: number }
  cost: number | null; thread: ThreadItem[]
}
export type SessionDetail = { id: string; short: string; agents: AgentDetail[] }
// metadata de git por tarea (/api/task-git)
export type RepoGit = {
  repo: string; branch: string; ahead: number; dirty: boolean
  last_subject: string; last_ts: number
  pr: { number: number; state: string; url: string } | null; pushed_direct: boolean
}
export type TaskGit = { repos: RepoGit[]; read: string[] }
// herdr (opcional): terminales de agentes en vivo, cross-workspace (/api/herdr)
export type HerdrPane = {
  pane_id: string; workspace_id: string; tab_id: string
  cwd: string; foreground_cwd: string; agent_status: string; focused: boolean
  program?: string; agent?: string
  // id de la sesión del agente → su transcripción JSONL completa (ruta A del
  // "historial completo"). Si falta, el pane es un shell (ruta B: backlog).
  agent_session?: { value?: string; agent?: string; kind?: string }
}
export type HerdrWorkspace = {
  workspace_id: string; label: string; number: number
  agent_status: string; pane_count: number; tab_count: number; focused: boolean
}
export type HerdrTab = { tab_id: string; workspace_id: string; label: string; agent_status: string; pane_count: number }
export type HerdrAgent = { name: string; pane_id: string; workspace_id: string; agent_status: string; cwd: string }
// Una sesión de herdr (el multiplexor persistente): lo que mantiene VIVAS las
// terminales. running=false → quedó como registro y se puede borrar.
export type HerdrSession = { name: string; running: boolean; default: boolean; dir?: string }
// Un destino remoto (VPS) donde corre herdr, alcanzable por SSH. name = alias
// amigable; ssh = alias de ~/.ssh/config o user@host.
export type HerdrTarget = { name: string; ssh: string }
export type HerdrState = {
  available: boolean; installed?: boolean; stale?: boolean; version: string; reason?: string
  workspaces: HerdrWorkspace[]; tabs: HerdrTab[]; panes: HerdrPane[]; agents: HerdrAgent[]
  sessions?: HerdrSession[]
}
// Estado de conexión de un destino (probe): para los dots del selector.
export type TargetProbe = { name: string; reachable: boolean; ssh_ok: boolean; running: boolean; message: string }

export const who = (a: Agent) => (a.id === "main" ? "orquestador" : a.desc || a.type || a.id.slice(0, 10))

// Estado HONESTO de una sesión. Prioriza la verdad de campo (live_by, que cruza
// con las terminales vivas de herdr) sobre el mtime del transcript, que mentía
// marcando "Trabajando" algo que ya terminó o que nunca corrió aquí.
//   herdr/live → corre AHORA (verde, pulsa)
//   recent     → activa hace poco, sin confirmar en vivo (ámbar, no pulsa)
//   idle<600   → en pausa    ·   resto → en reposo
export function estado(x: Session): [string, string, boolean] {
  if (x.live_by === "herdr" || x.live_by === "live") return ["●", "Trabajando", true]
  if (x.live_by === "recent") return ["◐", "Activa hace poco", false]
  return x.idle < 600 ? ["◐", "En pausa", false] : ["○", "En reposo", false]
}

// Agentes VIVOS de verdad: n_active sólo cuenta si la sesión está confirmada en
// vivo (herdr, o mtime cuando no hay herdr). Así "agentes vivos" no miente.
export const liveAgents = (x: Session): number =>
  x.live_by === "herdr" || x.live_by === "live" ? x.n_active : 0

// cwd → id de tarea si vive en worktrees/<id>/ (la convención del harness).
export function taskOfCwd(cwd?: string): string | undefined {
  const m = (cwd || "").match(/\/worktrees\/([^/]+)/)
  return m ? m[1] : undefined
}

// Las sesiones que PERTENECEN a una tarea: las que corren en su worktree (por
// cwd) o las que el panel lanzó para ella (snap.runs). Una tarea CONTIENE sus
// sesiones — por eso las mostramos dentro de la tarea, no separadas.
export function sessionsOfTask(s: Snapshot, taskId: string): Session[] {
  const viaRuns = new Set((s.runs || []).filter((r) => r.task === taskId).map((r) => r.session))
  return s.sessions.filter((x) => taskOfCwd(x.cwd) === taskId || viaRuns.has(x.id))
}

// Suma de tokens/costo de un grupo de sesiones (para el rollup de una tarea).
export function rollupSessions(list: Session[]): { out: number; cost: number | null; live: number } {
  let out = 0, cost = 0, known = false, live = 0
  for (const x of list) {
    out += x.tokens.out
    if (x.cost != null) { cost += x.cost; known = true }
    live += liveAgents(x)
  }
  return { out, cost: known ? cost : null, live }
}

// La alerta se DERIVA: el último evento de cada tarea es stop → te espera;
// ok=false → un gate bloqueó. Nada más se considera pendiente.
export function pending(s: Snapshot) {
  const last: Record<string, BusEvent> = {}
  for (const e of s.events) if (e.task) last[e.task] = e
  const out: (BusEvent & { _k: "wait" | "block" })[] = []
  for (const t in last) {
    const e = last[t]
    if (e.kind === "stop") out.push({ ...e, _k: "wait" })
    else if (e.ok === false) out.push({ ...e, _k: "block" })
  }
  return out
}

export type Beat = { k: "hard" | "bad" | "wait" | "soft"; lbl: string; p: string; ts: string }

// Gates verdes consecutivos se agrupan ("Pasaron N gates"); un bloqueo JAMÁS
// se agrupa — se enseña igual de grande que un éxito.
export function beats(evs: BusEvent[]): Beat[] {
  const out: Beat[] = []
  let run: BusEvent[] = []
  const flush = () => {
    if (!run.length) return
    out.push(
      run.length === 1
        ? { k: "hard", lbl: "Pasó el gate", p: run[0].summary, ts: run[0].ts }
        : { k: "hard", lbl: `Pasaron ${run.length} gates`, p: run.map((e) => e.summary).join(" · "), ts: run[run.length - 1].ts },
    )
    run = []
  }
  for (const e of evs) {
    if (e.kind === "gate" && e.ok === true) { run.push(e); continue }
    flush()
    const M: Record<string, [Beat["k"], string]> = {
      gate: ["bad", "✕ Bloqueé"], stop: ["wait", "Te espero"], assumption: ["soft", "Asumí"],
      decision: ["soft", "Decidí"], phase: ["soft", "Fase"], ship: ["hard", "Shippeé"],
      deploy: e.ok === false ? ["bad", "Deploy rojo"] : ["hard", "Canary verde"],
    }
    const [k, lbl] = M[e.kind] || ["soft", e.kind]
    out.push({ k, lbl, p: e.summary, ts: e.ts })
  }
  flush()
  return out
}

// Estado de UNA tarea, derivado de sus eventos: dónde va, qué la detiene, qué
// decidió por última vez. Es el corazón del mission-control del Resumen.
export type TaskStatus = "wait" | "block" | "ship" | "work"
export type TaskRollup = {
  id: string; title: string; phase: string; status: TaskStatus
  statusLabel: string; waitingOn: string; lastDecision: string
  lastTs: string; nEvents: number
}
const PHASE_KEYS = PHASES.map(([k]) => k)
export function taskRollup(s: Snapshot): TaskRollup[] {
  const byTask: Record<string, BusEvent[]> = {}
  for (const e of s.events) if (e.task && BUSKINDS.includes(e.kind)) (byTask[e.task] ||= []).push(e)
  for (const t of s.tasks) byTask[t.id] ||= []
  const out: TaskRollup[] = []
  for (const id in byTask) {
    const evs = byTask[id]
    const last = evs[evs.length - 1]
    const meta = s.tasks.find((t) => t.id === id)
    let phase = meta?.phase || ""
    for (let i = evs.length - 1; i >= 0; i--) {
      if (evs[i].kind === "phase") {
        const m = evs[i].summary.toLowerCase().match(new RegExp(`\\b(${PHASE_KEYS.join("|")})\\b`))
        if (m) { phase = m[1]; break }
      }
    }
    let status: TaskStatus = "work", label = "trabajando"
    if (last) {
      if (last.kind === "stop") { status = "wait"; label = "te espera" }
      else if (last.ok === false) { status = "block"; label = "bloqueada" }
      else if (last.kind === "ship" || (last.kind === "deploy" && last.ok)) { status = "ship"; label = "en main / deploy" }
    }
    // archive es el cierre del ciclo SDD: si llegó ahí y nada la frena, está lista
    if (phase === "archive" && (status === "work" || status === "ship")) { status = "ship"; label = "listo" }
    const dec = [...evs].reverse().find((e) => e.kind === "decision")
    out.push({
      id, title: meta?.title || "", phase, status, statusLabel: label,
      waitingOn: last?.summary || "", lastDecision: dec?.summary || "",
      lastTs: last?.ts || "", nEvents: evs.length,
    })
  }
  return out.sort((a, b) => toEpoch(b.lastTs) - toEpoch(a.lastTs))
}

// "SUPUESTO: x · PORQUE: y · SI ES FALSO: z" → estructura legible
export function supuesto(a: string) {
  const m = a.match(/SUPUESTO:\s*(.*?)\s*·\s*PORQUE:\s*(.*?)\s*·\s*SI ES FALSO:\s*(.*)/i)
  return m ? { q: m[1], why: m[2], iff: m[3] } : { q: a, why: null, iff: null }
}

declare global { interface Window { __OP: string } }

// POST al plano de operar: token anti-CSRF en header custom (ADR-0010). Mete el
// target activo (máquina local o VPS) en el body, salvo que ya venga uno — así
// toda acción de herdr va a la máquina que estás viendo. Ops no-herdr lo ignoran.
export async function op(path: string, body: unknown): Promise<any> {
  try {
    const b = (body && typeof body === "object") ? body as Record<string, unknown> : {}
    const withTgt = "target" in b ? b : { ...b, target: getTarget() }
    const r = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Corvux-Token": window.__OP },
      body: JSON.stringify(withTgt),
    })
    return await r.json()
  } catch (e) {
    return { ok: false, error: String(e) }
  }
}
