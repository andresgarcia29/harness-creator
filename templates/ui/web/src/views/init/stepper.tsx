// El riel del wizard: pantallas con su estado, clicables solo hacia atrás
// (revisar lo hecho); el futuro no existe hasta que el servidor lo diga.
import { cn } from "@/lib/utils"
import { Progress } from "@/components/ui/progress"
import { CircleCheck, CircleX, Loader2, CircleDashed, MinusCircle } from "lucide-react"
import type { InitState } from "@/lib/harness"
import { SCREENS, screenStatus, progressPct, type ScreenId } from "./use-init"

const ICON = {
  ok: CircleCheck, fail: CircleX, running: Loader2, pending: CircleDashed, skipped: MinusCircle,
} as const
const COLOR = {
  ok: "text-(--ok)", fail: "text-(--bad)", running: "text-(--wait)",
  pending: "text-muted-foreground/40", skipped: "text-muted-foreground/50",
} as const

export function Stepper({ init, current, viewing, onView }: {
  init: InitState; current: ScreenId; viewing: ScreenId; onView: (s: ScreenId) => void
}) {
  const pct = progressPct(init)
  const currentIdx = SCREENS.findIndex((s) => s.id === current)
  return (
    <div className="md:w-52 md:shrink-0">
      <div className="mb-4">
        <div className="mb-1.5 flex items-baseline justify-between">
          <span className="text-[10.5px] font-semibold uppercase tracking-wider text-muted-foreground">Progreso</span>
          <span className="font-mono text-[11px] text-muted-foreground/70">{pct}%</span>
        </div>
        <Progress value={pct} />
      </div>
      <ol className="flex gap-1 overflow-x-auto md:flex-col md:gap-0.5">
        {SCREENS.map((sc, i) => {
          const st = screenStatus(init, sc.id)
          const Icon = ICON[st]
          const reachable = i <= currentIdx || st !== "pending"
          const active = viewing === sc.id
          return (
            <li key={sc.id}>
              <button
                disabled={!reachable}
                onClick={() => reachable && onView(sc.id)}
                className={cn(
                  "flex w-full items-center gap-2 rounded-xl px-2.5 py-1.5 text-left text-[12.5px] transition-colors",
                  active ? "bg-primary/15 text-(--brand) shadow-[inset_0_0_0_1px_rgba(99,102,241,.18)]"
                    : reachable ? "text-foreground/80 hover:bg-accent" : "cursor-default text-muted-foreground/40",
                )}
              >
                <Icon className={cn("size-3.5 shrink-0", COLOR[st], st === "running" && "animate-spin")} />
                <span className="whitespace-nowrap">{sc.label}</span>
              </button>
            </li>
          )
        })}
      </ol>
    </div>
  )
}
