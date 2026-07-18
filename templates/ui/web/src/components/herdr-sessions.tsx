// Sesiones de herdr — el ciclo de vida REAL de tus terminales. herdr es lo que
// las mantiene vivas (persisten al detach); una sesión "parada" queda como
// registro histórico hasta que la borras (por eso "nunca se borraban": nadie
// llamaba `session delete`). Aquí las ves, las paras y las borras. Y si el
// server no corre, lo activas headless ("por debajo", sin abrir un TUI).
import { useState } from "react"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"
import { op, type HerdrSession } from "@/lib/harness"
import { toast } from "sonner"
import { Power, Square, Trash2, Loader2, Server } from "lucide-react"

async function herdrOp(body: Record<string, unknown>, ok: string) {
  const r = await op("/api/op/herdr", body)
  if (r.ok) toast.success(ok)
  else toast.error(r.error || "no se pudo")
  return r.ok
}

// Botón para ARRANCAR el server de herdr headless (sin TUI). Aparece cuando
// herdr está instalado pero el server no corre.
export function ActivateHerdr() {
  const [busy, setBusy] = useState(false)
  const go = async () => {
    setBusy(true)
    await herdrOp({ action: "start-server" }, "herdr activado — arrancando el server…")
    // el server tarda ~1s en levantar; el snapshot en vivo lo reflejará solo
    setTimeout(() => setBusy(false), 1500)
  }
  return (
    <Button size="sm" onClick={go} disabled={busy} className="h-8 gap-1.5">
      {busy ? <Loader2 className="size-3.5 animate-spin" /> : <Power className="size-3.5" />}
      {busy ? "activando…" : "Activar herdr"}
    </Button>
  )
}

// Diálogo de confirmación reutilizable para parar/borrar.
function useAsk() {
  const [p, setP] = useState<{ title: string; body: string; danger?: boolean; run: () => Promise<void> } | null>(null)
  const [busy, setBusy] = useState(false)
  const dialog = (
    <AlertDialog open={!!p} onOpenChange={(o) => !o && setP(null)}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{p?.title}</AlertDialogTitle>
          <AlertDialogDescription>{p?.body}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={busy}>Cancelar</AlertDialogCancel>
          <AlertDialogAction disabled={busy} onClick={async (e) => { e.preventDefault(); setBusy(true); await p?.run(); setBusy(false); setP(null) }}
            className={cn(p?.danger && "bg-(--bad) text-white hover:bg-(--bad)/90")}>
            {busy ? "…" : p?.title}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
  return { ask: (a: NonNullable<typeof p>) => setP(a), dialog }
}

// Lista de sesiones de herdr con acciones (parar / borrar).
export function HerdrSessions({ sessions, canOp }: { sessions: HerdrSession[]; canOp: boolean }) {
  const { ask, dialog } = useAsk()
  if (!sessions.length) return null
  return (
    <div className="mb-5 overflow-hidden rounded-xl border bg-card/40">
      <div className="flex items-center gap-2 border-b bg-muted/30 px-3.5 py-2">
        <Server className="size-3.5 text-muted-foreground/70" />
        <span className="font-heading text-[12.5px] font-semibold">Sesiones de herdr</span>
        <span className="text-[11px] text-muted-foreground/60">lo que mantiene vivas tus terminales</span>
      </div>
      <div className="divide-y divide-border/60">
        {sessions.map((se) => (
          <div key={se.name} className="flex items-center gap-2.5 px-3.5 py-2">
            <i className={cn("size-2 shrink-0 rounded-full", se.running ? "bg-(--ok) animate-pulse" : "bg-muted-foreground/35")} />
            <span className="font-mono text-[12px] font-medium">{se.name}</span>
            {se.default && <span className="rounded border border-border px-1.5 py-0.5 text-[9px] uppercase tracking-wide text-muted-foreground/70">default</span>}
            <span className={cn("text-[10.5px] font-semibold uppercase tracking-wide", se.running ? "text-(--ok)" : "text-muted-foreground/50")}>
              {se.running ? "corriendo" : "parada"}
            </span>
            {se.dir && <span className="hidden truncate font-mono text-[10.5px] text-muted-foreground/40 md:inline">{se.dir.replace(/^\/Users\/[^/]+/, "~")}</span>}
            <span className="flex-1" />
            {canOp && se.running && (
              <Button size="sm" variant="ghost" className="h-7 gap-1 px-2 text-[11px] text-(--wait) hover:text-(--wait)"
                onClick={() => ask({
                  title: "Parar sesión", danger: true,
                  body: `Detiene la sesión «${se.name}» y cierra TODAS sus terminales (workspaces, tabs y panes). El server sigue vivo para otras sesiones.`,
                  run: async () => { await herdrOp({ action: "stop-session", id: se.name }, "sesión parada.") },
                })}>
                <Square className="size-3" /> Parar
              </Button>
            )}
            {canOp && (
              <Button size="sm" variant="ghost" disabled={se.running || se.default}
                title={se.default ? "la sesión default no se puede borrar, sólo parar" : se.running ? "párala antes de borrarla" : "borrar el registro de esta sesión"}
                className="h-7 gap-1 px-2 text-[11px] text-(--bad) hover:text-(--bad) disabled:opacity-30"
                onClick={() => ask({
                  title: "Borrar sesión", danger: true,
                  body: `Borra el registro de la sesión «${se.name}» de herdr. Sólo se puede borrar una sesión parada. No se puede deshacer.`,
                  run: async () => { await herdrOp({ action: "delete-session", id: se.name }, "sesión borrada.") },
                })}>
                <Trash2 className="size-3" /> Borrar
              </Button>
            )}
          </div>
        ))}
      </div>
      {dialog}
    </div>
  )
}
