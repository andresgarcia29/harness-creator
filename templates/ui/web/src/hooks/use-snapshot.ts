import { useEffect, useRef, useState } from "react"
import type { Snapshot } from "@/lib/harness"
import { useTarget, withTarget } from "@/lib/target"

export type StreamText = { agent: string; session: string; text: string; ts: number; who?: string }

export type DaemonVersion = { name: string; version: string; api_version: string }

// Major del CONTRATO HTTP que esta UI sabe hablar. Debe coincidir con el
// APIVersion del daemon (ADR-0003): al conectarse a un daemon de la fleet, si
// su major no coincide — o si ni expone /api/version (daemon viejo) — se marca
// incompatible en vez de renderizar datos que quizá ya no cuadran. Sin auth que
// gatee versiones (transporte SSH), este handshake es la única red contra skew.
export const EXPECTED_API_MAJOR = 1

function majorOf(apiVersion: string): number {
  return parseInt(apiVersion.split(".")[0], 10)
}

// SSE con reconexión: snapshot completo por evento (el server manda el estado
// entero — sin diffs que puedan divergir) + textos por turno. El stream lleva
// el target activo: al cambiar de máquina (local↔VPS), reconecta con el nuevo.
export function useSnapshot() {
  const [snap, setSnap] = useState<Snapshot | null>(null)
  const [live, setLive] = useState(false)
  const [texts, setTexts] = useState<StreamText[]>([])
  const [apiVersion, setApiVersion] = useState<DaemonVersion | null>(null)
  const [apiMismatch, setApiMismatch] = useState(false)
  const [target] = useTarget()
  const lastData = useRef(0)

  // Handshake de contrato: al (re)apuntar a un target, pregunta su versión
  // antes de confiar en el stream. Un 404 (daemon viejo sin el endpoint) o un
  // major distinto ⇒ incompatible.
  useEffect(() => {
    const ac = new AbortController()
    setApiVersion(null)
    setApiMismatch(false)
    fetch(withTarget("/api/version"), { signal: ac.signal })
      .then((r) => (r.ok ? (r.json() as Promise<DaemonVersion>) : Promise.reject(new Error("no-version"))))
      .then((v) => {
        setApiVersion(v)
        setApiMismatch(majorOf(v.api_version) !== EXPECTED_API_MAJOR)
      })
      .catch((e) => {
        if (e?.name === "AbortError") return
        // Sin /api/version ⇒ daemon anterior al handshake: trátalo como incompatible.
        setApiVersion(null)
        setApiMismatch(true)
      })
    return () => ac.abort()
  }, [target])

  useEffect(() => {
    let es: EventSource | null = null
    let retry: ReturnType<typeof setTimeout>
    const connect = () => {
      es = new EventSource(withTarget("/api/stream"))
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
  }, [target])

  return { snap, live, texts, apiVersion, apiMismatch }
}
