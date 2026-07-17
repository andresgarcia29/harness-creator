// La lógica del panel, portada 1:1 del app.html anterior — las derivaciones
// son REALES y se explican en pantalla (leyes de honestidad intactas).

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
  mode?: string; op?: boolean
}

export const who = (a: Agent) => (a.id === "main" ? "orquestador" : a.desc || a.type || a.id.slice(0, 10))

export function estado(x: Session): [string, string, boolean] {
  return x.n_active ? ["●", "Trabajando", true] : x.idle < 600 ? ["◐", "En pausa", false] : ["○", "En reposo", false]
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

// "SUPUESTO: x · PORQUE: y · SI ES FALSO: z" → estructura legible
export function supuesto(a: string) {
  const m = a.match(/SUPUESTO:\s*(.*?)\s*·\s*PORQUE:\s*(.*?)\s*·\s*SI ES FALSO:\s*(.*)/i)
  return m ? { q: m[1], why: m[2], iff: m[3] } : { q: a, why: null, iff: null }
}

declare global { interface Window { __OP: string } }

// POST al plano de operar: token anti-CSRF en header custom (ADR-0010)
export async function op(path: string, body: unknown): Promise<any> {
  try {
    const r = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Corvux-Token": window.__OP },
      body: JSON.stringify(body),
    })
    return await r.json()
  } catch (e) {
    return { ok: false, error: String(e) }
  }
}
