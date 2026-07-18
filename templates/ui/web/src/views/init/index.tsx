// El wizard de onboarding (plano de init, ADR-0011 del daemon). Server-driven:
// el snapshot es LA verdad del paso activo; la UI manda acciones y deriva.
// Refresh, otra pestaña o reinicio del daemon → el wizard reanuda solo.
import { useState } from "react"
import { VHead } from "@/components/bits"
import { Empty } from "@/components/bits"
import type { Snapshot } from "@/lib/harness"
import { Stepper } from "./stepper"
import { screenOf, type ScreenId } from "./use-init"
import { Welcome } from "./steps/welcome"
import { Placeholder } from "./steps/placeholder"

// Marcador para el guard de tests (detecta un dist desactualizado sin Node).
export const INIT_WIZARD = "harness-init-wizard"

export function Init({ s }: { s: Snapshot }) {
  const init = s.init
  const [viewing, setViewing] = useState<ScreenId | null>(null)
  if (!init?.active) {
    return (
      <Empty title="No hay ninguna instalación en curso">
        Este daemon no está en modo instalación. Para crear un harness nuevo corre{" "}
        <span className="font-mono">harness init</span> en una terminal.
      </Empty>
    )
  }
  const current = screenOf(init.step)
  const screen: ScreenId = viewing ?? current
  const body =
    screen === "welcome" ? <Welcome init={init} />
    : <Placeholder init={init} screen={screen} />
  return (
    <div data-marker={INIT_WIZARD}>
      <VHead title="Init" sub="De cero a harness funcionando — repetible, reanudable, sin magia." />
      <div className="flex flex-col gap-6 md:flex-row md:gap-10">
        <Stepper init={init} current={current} viewing={screen}
          onView={(id) => setViewing(id === current ? null : id)} />
        {body}
      </div>
    </div>
  )
}
