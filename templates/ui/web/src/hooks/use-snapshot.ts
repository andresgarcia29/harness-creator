import { useEffect, useRef, useState } from "react"
import type { Snapshot } from "@/lib/harness"

export type StreamText = { agent: string; session: string; text: string; ts: number; who?: string }

// SSE con reconexión: snapshot completo por evento (el server manda el estado
// entero — sin diffs que puedan divergir) + textos por turno.
export function useSnapshot() {
  const [snap, setSnap] = useState<Snapshot | null>(null)
  const [live, setLive] = useState(false)
  const [texts, setTexts] = useState<StreamText[]>([])
  const lastData = useRef(0)

  useEffect(() => {
    let es: EventSource | null = null
    let retry: ReturnType<typeof setTimeout>
    const connect = () => {
      es = new EventSource("/api/stream")
      es.addEventListener("snapshot", (e) => {
        lastData.current = Date.now()
        setLive(true)
        try { setSnap(JSON.parse((e as MessageEvent).data)) } catch { /* snapshot roto: esperar el siguiente */ }
      })
      es.addEventListener("text", (e) => {
        try {
          const t = JSON.parse((e as MessageEvent).data) as StreamText
          setTexts((old) => [...old, t].slice(-60))
        } catch { /* ídem */ }
      })
      es.onerror = () => {
        setLive(false)
        es?.close()
        retry = setTimeout(connect, 2000)
      }
    }
    connect()
    const watchdog = setInterval(() => {
      if (Date.now() - lastData.current > 15000) setLive(false)
    }, 5000)
    return () => { es?.close(); clearTimeout(retry); clearInterval(watchdog) }
  }, [])

  return { snap, live, texts }
}
