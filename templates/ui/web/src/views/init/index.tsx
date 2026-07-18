// El wizard de onboarding (plano de init, ADR-0011 del daemon). Server-driven:
// el snapshot es LA verdad del paso activo; la UI manda acciones y deriva.
// Refresh, otra pestaña o reinicio del daemon → el wizard reanuda solo.
import { useState } from "react"
import { VHead } from "@/components/bits"
import { Empty } from "@/components/bits"
import type { Go } from "@/App"
import type { Snapshot } from "@/lib/harness"
import { Stepper } from "./stepper"
import { screenOf, type ScreenId } from "./use-init"
import { Welcome } from "./steps/welcome"
import { GithubStep } from "./steps/github"
import { CloneStep } from "./steps/clone"
import { RequirementsStep } from "./steps/requirements"
import { DiscoverStep } from "./steps/discover"
import { AgentsStep } from "./steps/agents"
import { McpsStep } from "./steps/mcps"
import { SessionsStep } from "./steps/sessions"
import { DoneStep } from "./steps/done"
import { Placeholder } from "./steps/placeholder"

// Marcador para el guard de tests (detecta un dist desactualizado sin Node).
export const INIT_WIZARD = "harness-init-wizard"

export function Init({ s, go }: { s: Snapshot; go: Go }) {
  const init = s.init
  const [viewing, setViewing] = useState<ScreenId | null>(null)
  if (!init) {
    return (
      <Empty title="No hay ninguna instalación en curso">
        Este daemon no está en modo instalación. Para crear un harness nuevo corre{" "}
        <span className="font-mono">harness init</span> en una terminal.
      </Empty>
    )
  }
  // terminado: la pantalla final queda visible (resumen + ir al panel)
  const finished = !init.active && !!init.completed_at
  const current = finished ? "done" : screenOf(init.step)
  const screen: ScreenId = finished ? "done" : (viewing ?? current)
  const body =
    screen === "welcome" ? <Welcome init={init} targets={s.targets || []} />
    : screen === "github" ? <GithubStep init={init} />
    : screen === "clone" ? <CloneStep init={init} />
    : screen === "requirements" ? <RequirementsStep init={init} />
    : screen === "discover" ? <DiscoverStep init={init} />
    : screen === "agents" ? <AgentsStep init={init} />
    : screen === "mcps" ? <McpsStep init={init} />
    : screen === "sessions" ? <SessionsStep init={init} />
    : screen === "done" ? <DoneStep init={init} go={go} />
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
