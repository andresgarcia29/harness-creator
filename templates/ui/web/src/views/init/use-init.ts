// Helpers del wizard de init. El servidor es la verdad del estado (snapshot
// `init` por SSE); aquí solo van las acciones y las derivaciones puras.
import { op, type InitState, type InitStatus } from "@/lib/harness"

// Las acciones de init SIEMPRE van a la máquina del daemon (target "" = local):
// el TargetSwitcher global no debe rutear un set-workspace a un VPS por
// accidente. La instalación remota (F11) viaja como `init.target` del estado,
// no como target del transporte.
export function initOp(action: string, body: Record<string, unknown> = {}) {
  return op(`/api/op/init/${action}`, { ...body, target: "" })
}

// Pantallas de la UI ↔ pasos del backend (11 pasos, 9 pantallas).
export const SCREENS = [
  { id: "welcome", label: "Bienvenida", steps: ["workspace"] },
  { id: "github", label: "GitHub", steps: ["github"] },
  { id: "clone", label: "Repositorios", steps: ["clone"] },
  { id: "requirements", label: "Requisitos", steps: ["requirements"] },
  { id: "discover", label: "Auto-discover", steps: ["discover", "enrich"] },
  { id: "agents", label: "Agentes", steps: ["generate", "archaeology"] },
  { id: "mcps", label: "MCPs", steps: ["mcps"] },
  { id: "sessions", label: "Sesiones", steps: ["first-task"] },
  { id: "done", label: "Fin", steps: ["finish"] },
] as const
export type ScreenId = (typeof SCREENS)[number]["id"]

export function screenOf(stepId: string): ScreenId {
  for (const sc of SCREENS) if ((sc.steps as readonly string[]).includes(stepId)) return sc.id
  return "welcome"
}

// Estado agregado de una pantalla a partir de sus pasos backend.
export function screenStatus(init: InitState, screen: ScreenId): InitStatus {
  const ids = (SCREENS.find((s) => s.id === screen)?.steps || []) as readonly string[]
  const sts = init.steps.filter((s) => ids.includes(s.id)).map((s) => s.status)
  if (sts.some((s) => s === "fail")) return "fail"
  if (sts.some((s) => s === "running")) return "running"
  if (sts.every((s) => s === "ok" || s === "skipped")) return sts.every((s) => s === "skipped") ? "skipped" : "ok"
  return "pending"
}

export function progressPct(init: InitState): number {
  const done = init.steps.filter((s) => s.status === "ok" || s.status === "skipped").length
  return Math.round((done / init.steps.length) * 100)
}

export function stepOf(init: InitState, id: string) {
  return init.steps.find((s) => s.id === id)
}
