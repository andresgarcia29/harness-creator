// Quitar de la lista una sesión o tarea vieja ("basura") — la OCULTA del panel
// sin borrar nada del disco (transcripts, dirs de tarea). Reversible: el toast
// ofrece Deshacer, y como es reversible no pedimos confirmación (instantáneo).
// El colector no lo revierte (su UPSERT no toca `archived`).
import { useState } from "react"
import { toast } from "sonner"
import { op } from "@/lib/harness"
import { Archive } from "lucide-react"

export function ArchiveButton({ kind, id, className }: { kind: "session" | "task"; id: string; className?: string }) {
  const [busy, setBusy] = useState(false)
  const archive = async (archived: boolean) => {
    setBusy(true)
    const r = await op("/api/op/archive", { kind, id, archived, target: "" })
    setBusy(false)
    if (!r.ok) { toast.error(r.error || "no se pudo quitar"); return }
    if (archived) {
      toast.success(kind === "session" ? "Sesión quitada de la lista." : "Tarea quitada de la lista.", {
        action: { label: "Deshacer", onClick: () => archive(false) },
      })
    }
  }
  return (
    <button type="button" disabled={busy} title="quitar de la lista (reversible)"
      onClick={(e) => { e.stopPropagation(); archive(true) }}
      className={className ?? "grid size-6 shrink-0 place-items-center rounded text-muted-foreground/40 opacity-0 transition-colors hover:bg-accent hover:text-(--bad) group-hover:opacity-100 disabled:opacity-30"}>
      <Archive className="size-3.5" />
    </button>
  )
}
