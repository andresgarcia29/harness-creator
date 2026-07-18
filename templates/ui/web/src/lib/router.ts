// Router mínimo por hash (#/tasks/COR-11). Sin librería: son ~40 líneas y el
// panel debe viajar sin dependencias de runtime. Elegimos hash y no URLs
// limpias a propósito — el panel lo sirven DOS backends (el daemon Go con
// go:embed y server.py), y el hash no toca a ninguno: refrescar, back/forward
// e historial del navegador funcionan sin fallback de servidor. Sigue siendo
// una URL real, compartible y que sobrevive al refresh.
import { useCallback, useEffect, useState } from "react"
import type { View } from "@/App"

// Vistas simples (sin id) — el resto se maneja a mano por tener parámetro.
const SIMPLE = ["dash", "tasks", "sessions", "costs", "new", "connections", "docs", "tools", "terminals"] as const

export function viewToPath(v: View): string {
  if (v.name === "task") return `/tasks/${encodeURIComponent(v.id)}`
  if (v.name === "session") return `/sessions/${encodeURIComponent(v.id)}`
  if (v.name === "dash") return "/"
  return `/${v.name}`
}

export function pathToView(hash: string): View {
  const path = hash.replace(/^#/, "")
  const seg = path.split("/").filter(Boolean)
  if (seg.length === 0) return { name: "dash" }
  const [a, b] = seg
  if (a === "tasks") return b ? { name: "task", id: decodeURIComponent(b) } : { name: "tasks" }
  if (a === "sessions") return b ? { name: "session", id: decodeURIComponent(b) } : { name: "sessions" }
  if ((SIMPLE as readonly string[]).includes(a)) return { name: a } as View
  return { name: "dash" }
}

// Estado de navegación sincronizado con la URL. La URL es la fuente de verdad:
// go() escribe el hash y el listener de hashchange (incluye back/forward del
// navegador) actualiza la vista. setView optimista para que sea instantáneo.
export function useRoute(): [View, (v: View) => void] {
  const [view, setView] = useState<View>(() => pathToView(window.location.hash))
  useEffect(() => {
    const onHash = () => setView(pathToView(window.location.hash))
    window.addEventListener("hashchange", onHash)
    // normaliza la URL inicial si venía sin hash (deja "#/" explícito)
    if (!window.location.hash) window.history.replaceState(null, "", "#" + viewToPath(pathToView("")))
    return () => window.removeEventListener("hashchange", onHash)
  }, [])
  const go = useCallback((v: View) => {
    const next = "#" + viewToPath(v)
    if (next !== window.location.hash) window.location.hash = viewToPath(v)
    setView(v)
    // subir al inicio al cambiar de vista, como una navegación de verdad
    window.scrollTo({ top: 0 })
  }, [])
  return [view, go]
}
