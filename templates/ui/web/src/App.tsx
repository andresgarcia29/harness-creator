import { SidebarInset, SidebarProvider, SidebarTrigger } from "@/components/ui/sidebar"
import { Toaster } from "@/components/ui/sonner"
import { Alert, AlertDescription } from "@/components/ui/alert"
import { Skeleton } from "@/components/ui/skeleton"
import { AppSidebar } from "@/components/app-sidebar"
import { useSnapshot } from "@/hooks/use-snapshot"
import { cn } from "@/lib/utils"
import { TriangleAlert } from "lucide-react"
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
import { useEffect } from "react"

export type View =
  | { name: "dash" } | { name: "tasks" } | { name: "task"; id: string }
  | { name: "sessions" } | { name: "session"; id: string }
  | { name: "costs" } | { name: "new" } | { name: "connections" }
  | { name: "docs" } | { name: "tools" } | { name: "terminals" }
  | { name: "init" }
export type Go = (v: View) => void

export default function App() {
  const [view, setView] = useRoute()
  const { snap, live, texts } = useSnapshot()
  const narrow = view.name === "new" || view.name === "connections"
  // Modo setup (daemon sin workspace): el wizard es lo único útil — aterriza
  // ahí sí o sí (Docs se permite: es la guía).
  useEffect(() => {
    if (snap?.mode === "setup" && snap.init?.active && view.name !== "init" && view.name !== "docs") {
      setView({ name: "init" })
    }
  }, [snap?.mode, snap?.init?.active, view.name, setView])
  return (
    <SidebarProvider>
      <AppSidebar view={view} go={setView} snap={snap} live={live} />
      {/* Raised Canvas (Agora AppShell): el contenido flota sobre el sidebar */}
      <SidebarInset className="min-h-svh bg-card md:mt-2.5 md:rounded-tl-[2rem] md:border-l md:border-t">
        <div className="flex items-center gap-2 border-b px-4 py-2.5 md:hidden">
          <SidebarTrigger />
          <span className="font-heading text-sm font-bold">corvux</span>
        </div>
        <div className="px-5 py-7 sm:px-8 md:px-11 md:py-9">
          <div className={cn("mx-auto", narrow ? "max-w-[680px]" : "max-w-[1160px]")}>
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
              : view.name === "init" ? <Init s={snap} />
              : <Dash s={snap} go={setView} />}
          </div>
        </div>
      </SidebarInset>
      <Toaster position="bottom-right" />
    </SidebarProvider>
  )
}
