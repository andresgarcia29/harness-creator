import { SidebarInset, SidebarProvider, SidebarTrigger } from "@/components/ui/sidebar"
import { Toaster } from "@/components/ui/sonner"
import { Alert, AlertDescription } from "@/components/ui/alert"
import { Skeleton } from "@/components/ui/skeleton"
import { AppSidebar } from "@/components/app-sidebar"
import { useSnapshot } from "@/hooks/use-snapshot"
import { cn } from "@/lib/utils"
import { TriangleAlert } from "lucide-react"
import { ArrowUpRight, Command, Plus, RadioTower } from "lucide-react"
import { Dash } from "@/views/dash"
import { Tasks } from "@/views/tasks"
import { TaskDetail } from "@/views/task-detail"
import { Sessions } from "@/views/sessions"
import { SessionDetail } from "@/views/session-detail"
import { Costs } from "@/views/costs"
import { NewTask } from "@/views/new-task"
import { Connections } from "@/views/connections"
import { Docs } from "@/views/docs"
import { Tools } from "@/views/tools"
import { Terminals } from "@/views/terminals"
import { Init } from "@/views/init"
import { useRoute } from "@/lib/router"
import { useEffect, useRef } from "react"

export type View =
  | { name: "dash" } | { name: "tasks" } | { name: "task"; id: string }
  | { name: "sessions" } | { name: "session"; id: string }
  | { name: "costs" } | { name: "new" } | { name: "connections" }
  | { name: "docs" } | { name: "tools" } | { name: "terminals" }
  | { name: "init" }
export type Go = (v: View) => void

const VIEW_LABEL: Record<View["name"], string> = {
  dash: "Resumen", tasks: "Tareas", task: "Detalle de tarea",
  sessions: "Sesiones", session: "Detalle de sesión", costs: "Gastos",
  new: "Nueva tarea", connections: "Conexiones", docs: "Documentación",
  tools: "Skills & MCP", terminals: "Terminales", init: "Instalación",
}

export default function App() {
  const [view, setView] = useRoute()
  const { snap, live, texts } = useSnapshot()
  const narrow = view.name === "connections"
  // Modo setup con init activo: el ATERRIZAJE es el wizard — UNA vez. Después
  // la navegación es libre (p.ej. observar un VPS con el selector de máquina).
  const landed = useRef(false)
  useEffect(() => {
    if (!landed.current && snap?.mode === "setup" && snap.init?.active && view.name === "dash") {
      landed.current = true
      setView({ name: "init" })
    }
  }, [snap?.mode, snap?.init?.active, view.name, setView])
  return (
    <SidebarProvider>
      <AppSidebar view={view} go={setView} snap={snap} live={live} />
      {/* Command canvas: una superficie operativa, no una página genérica. */}
      <SidebarInset className="app-canvas min-h-svh overflow-hidden md:m-2.5 md:ml-0 md:rounded-[1.75rem] md:border md:shadow-(--shadow-float)">
        <div className="flex items-center gap-2 border-b px-4 py-2.5 md:hidden">
          <SidebarTrigger />
          <span className="font-heading text-sm font-bold">corvux</span>
        </div>
        <header className="command-bar hidden h-14 items-center gap-3 border-b px-7 md:flex">
          <div className="flex min-w-0 items-center gap-2 text-[11px] text-muted-foreground">
            <Command className="size-3.5 text-(--brand)" />
            <span className="font-mono uppercase tracking-[0.16em]">Control</span>
            <span className="text-border">/</span>
            <span className="truncate font-medium text-foreground/80">{VIEW_LABEL[view.name]}</span>
          </div>
          <div className="ml-auto flex items-center gap-2">
            <span className={cn("hidden items-center gap-1.5 rounded-full border px-2.5 py-1 text-[10px] font-semibold sm:flex",
              live ? "border-(--ok)/25 bg-(--ok)/8 text-(--ok)" : "border-(--wait)/25 bg-(--wait)/8 text-(--wait)")}>
              <RadioTower className="size-3" />{live ? "telemetría activa" : "reconectando"}
            </span>
            {snap?.op !== false && view.name !== "new" && (
              <button onClick={() => setView({ name: "new" })} className="command-action">
                <Plus className="size-3.5" /> Nueva tarea <ArrowUpRight className="size-3" />
              </button>
            )}
          </div>
        </header>
        <div className="relative px-5 py-7 pb-[max(1.75rem,env(safe-area-inset-bottom))] sm:px-8 md:px-10 md:py-9 lg:px-12">
          <div className="canvas-orb canvas-orb-a" aria-hidden="true" />
          <div className="canvas-orb canvas-orb-b" aria-hidden="true" />
          <div key={view.name} className={cn("view-enter relative z-10 mx-auto", narrow ? "max-w-[720px]" : "max-w-[1240px]")}>
            {snap?.warning && (
              <Alert className="mb-4 border-(--wait)/45 bg-(--wait)/8">
                <TriangleAlert className="text-(--wait)" />
                <AlertDescription className="text-[12.5px] text-muted-foreground">{snap.warning}</AlertDescription>
              </Alert>
            )}
            {!snap ? (
              <div className="space-y-4">
                <Skeleton className="h-8 w-56" />
                <Skeleton className="h-28 w-full rounded-2xl" />
                <Skeleton className="h-24 w-full rounded-2xl" />
              </div>
            ) : view.name === "tasks" ? <Tasks s={snap} go={setView} />
              : view.name === "task" ? <TaskDetail s={snap} id={view.id} go={setView} />
              : view.name === "sessions" ? <Sessions s={snap} go={setView} />
              : view.name === "session" ? <SessionDetail s={snap} id={view.id} go={setView} texts={texts} />
              : view.name === "costs" ? <Costs s={snap} go={setView} />
              : view.name === "new" ? <NewTask s={snap} go={setView} />
              : view.name === "connections" ? <Connections s={snap} />
              : view.name === "docs" ? <Docs s={snap} />
              : view.name === "tools" ? <Tools s={snap} />
              : view.name === "terminals" ? <Terminals s={snap} go={setView} />
              : view.name === "init" ? <Init s={snap} go={setView} />
              : <Dash s={snap} go={setView} />}
          </div>
        </div>
      </SidebarInset>
      <Toaster position="bottom-right" />
    </SidebarProvider>
  )
}
