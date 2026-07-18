// Target activo del panel: qué MÁQUINA ves en Terminales — local o un VPS por
// SSH. Es un estado global chico (pub/sub) porque lo consumen tres sitios: el
// stream SSE (reconecta al cambiar), `op()` (lo mete en cada acción) y el fetch
// de la terminal de un pane. El nombre "" = local. Persiste en localStorage.
import { useEffect, useReducer } from "react"

const KEY = "harness-target"
let current = (typeof localStorage !== "undefined" && localStorage.getItem(KEY)) || ""
const subs = new Set<() => void>()

export const getTarget = () => current

export function setTarget(t: string) {
  if (t === current) return
  current = t
  try { localStorage.setItem(KEY, t) } catch { /* modo privado */ }
  subs.forEach((f) => f())
}

// Hook: devuelve [target, setTarget] y re-renderiza al cambiar en cualquier lado.
export function useTarget(): [string, (t: string) => void] {
  const [, bump] = useReducer((x: number) => x + 1, 0)
  useEffect(() => {
    const f = () => bump()
    subs.add(f)
    return () => { subs.delete(f) }
  }, [])
  return [current, setTarget]
}

// Añade ?target= a una URL si hay target remoto (local no necesita el param).
export function withTarget(url: string): string {
  const t = getTarget()
  if (!t) return url
  return url + (url.includes("?") ? "&" : "?") + "target=" + encodeURIComponent(t)
}
