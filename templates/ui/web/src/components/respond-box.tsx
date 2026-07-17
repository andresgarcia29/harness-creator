import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Textarea } from "@/components/ui/textarea"
import { toast } from "sonner"
import { H2, Lede, Code } from "@/components/bits"
import { op } from "@/lib/harness"

// Reanuda una sesión real con `claude --resume` (ADR-0010: pasar contexto
// es crear trabajo — la respuesta del agente pasa por los mismos gates).
export function RespondBox({ session, label, placeholder }: { session: string; label: string; placeholder: string }) {
  const [text, setText] = useState("")
  const [busy, setBusy] = useState(false)
  const send = async () => {
    if (!text.trim()) { toast.error("Escribe algo primero."); return }
    setBusy(true)
    const r = await op("/api/op/respond", { session, text: text.trim() })
    setBusy(false)
    if (r.ok) { toast.success("Enviado — el agente retoma. Su respuesta llega por turno."); setText("") }
    else toast.error(r.error)
  }
  return (
    <div>
      <H2>{label}</H2>
      <Lede>Reanuda esa sesión con tu texto (<Code>claude --resume</Code>). El agente responde por turno; lo verás llegar aquí y en el bus.</Lede>
      <Textarea value={text} onChange={(e) => setText(e.target.value)} placeholder={placeholder} className="min-h-24" />
      <Button onClick={send} disabled={busy} className="mt-3">{busy ? "…" : "Enviar"}</Button>
    </div>
  )
}
