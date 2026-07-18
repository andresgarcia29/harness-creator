// Pantalla provisional de los pasos que llegan en fases posteriores del
// wizard. Honesta: dice qué paso es, su estado real, y permite saltar los
// saltables. Cada fase de desarrollo la reemplaza por su pantalla real.
import { Button } from "@/components/ui/button"
import { Empty } from "@/components/bits"
import type { InitState } from "@/lib/harness"
import { StepShell } from "../step-shell"
import { initOp, SCREENS, type ScreenId } from "../use-init"

const SKIPPABLE = new Set(["enrich", "archaeology", "mcps", "first-task"])

export function Placeholder({ init, screen }: { init: InitState; screen: ScreenId }) {
  const sc = SCREENS.find((s) => s.id === screen)!
  const steps = init.steps.filter((s) => (sc.steps as readonly string[]).includes(s.id))
  return (
    <StepShell title={sc.label} steps={steps}>
      <Empty title="Este paso aún no está disponible">
        Llega en una versión próxima del wizard. Estado actual:{" "}
        {steps.map((s) => `${s.title}: ${s.status}`).join(" · ")}
      </Empty>
      <div className="flex gap-2">
        {steps.filter((s) => SKIPPABLE.has(s.id) && s.status === "pending").map((s) => (
          <Button key={s.id} size="sm" variant="outline"
            onClick={() => initOp("step", { step: s.id, action: "skip" })}>
            Saltar {s.title}
          </Button>
        ))}
      </div>
    </StepShell>
  )
}
