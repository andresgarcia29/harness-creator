// Bitácora en vivo de un paso: el tail que viaja en el snapshot (≤40 líneas).
// Autoscroll al fondo salvo que el usuario haya subido a leer.
import { useEffect, useRef } from "react"

export function LogTail({ lines }: { lines?: string[] }) {
  const ref = useRef<HTMLDivElement>(null)
  const stick = useRef(true)
  useEffect(() => {
    const el = ref.current
    if (el && stick.current) el.scrollTop = el.scrollHeight
  }, [lines])
  if (!lines?.length) return null
  return (
    <div
      ref={ref}
      onScroll={(e) => {
        const el = e.currentTarget
        stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 24
      }}
      className="mt-3 max-h-48 overflow-y-auto rounded-xl border bg-muted/30 p-3 font-mono text-[11px] leading-relaxed text-muted-foreground"
    >
      {lines.map((l, i) => (
        <div key={i} className="whitespace-pre-wrap break-all">{l}</div>
      ))}
    </div>
  )
}
