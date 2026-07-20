import {
  Sidebar, SidebarContent, SidebarFooter, SidebarGroup, SidebarGroupContent,
  SidebarGroupLabel, SidebarHeader, SidebarMenu, SidebarMenuBadge,
  SidebarMenuButton, SidebarMenuItem, useSidebar,
} from "@/components/ui/sidebar"
import { cn } from "@/lib/utils"
import { taskRollup, usd, type Snapshot } from "@/lib/harness"
import { TargetSwitcher } from "@/components/target-switcher"
import { LayoutDashboard, ListTodo, Radio, ChartNoAxesColumn, Plus, Cable, Sun, Moon, Monitor, BookOpen, Blocks, SquareTerminal, Rocket, Orbit, ArrowUpRight, Activity } from "lucide-react"
import { useTheme, type Theme } from "@/hooks/use-theme"
import type { View } from "@/App"

const OBSERVE = [
  { v: "dash", label: "Resumen", icon: LayoutDashboard },
  { v: "tasks", label: "Tareas", icon: ListTodo },
  { v: "sessions", label: "Sesiones", icon: Radio },
  { v: "terminals", label: "Terminales", icon: SquareTerminal },
  { v: "costs", label: "Gastos", icon: ChartNoAxesColumn },
] as const
const OPERATE = [{ v: "connections", label: "Conexiones", icon: Cable }] as const
const GUIDE = [
  { v: "docs", label: "Docs", icon: BookOpen },
  { v: "tools", label: "Skills & MCP", icon: Blocks },
] as const
const INSTALL = [
  { v: "init", label: "Init", icon: Rocket },
] as const

export function AppSidebar({ view, go, snap, live }: {
  view: View; go: (v: View) => void; snap: Snapshot | null; live: boolean
}) {
  const { isMobile, setOpenMobile } = useSidebar()
  const { theme, setTheme } = useTheme()
  const nextTheme: Record<Theme, Theme> = { dark: "light", light: "system", system: "dark" }
  const ThemeIcon = theme === "dark" ? Moon : theme === "light" ? Sun : Monitor
  const nav = (v: View) => { go(v); if (isMobile) setOpenMobile(false) }
  const active = (v: string) =>
    view.name === v || (view.name === "task" && v === "tasks") || (view.name === "session" && v === "sessions")
  // Badges = señal, no ruido: cuántas tareas/sesiones y el costo. Las conexiones
  // NO llevan un conteo suelto (era la "batería" rara) — su estado vive en su vista.
  // Modo setup: daemon sin workspace local. El wizard va ARRIBA mientras hay
  // init, pero la navegación completa y el selector de máquina se quedan
  // SIEMPRE: sin workspace local aún puedes observar un VPS (?target=) —
  // esconder la nav te dejaba atrapado en un Resumen vacío.
  const initActive = snap?.init?.active === true
  const setup = false
  const initBadge = snap?.init
    ? `${snap.init.steps.filter((s) => s.status === "ok" || s.status === "skipped").length}/${snap.init.steps.length}`
    : ""
  const badges: Record<string, string> = {
    tasks: String(snap?.tasks.length || ""),
    sessions: String(snap?.sessions.length || ""),
    costs: snap?.cost != null ? usd(snap.cost) : "",
    init: initBadge,
    docs: snap?.drafts?.length ? `${snap.drafts.length} DRAFT` : "",
  }
  const activeTasks = snap ? taskRollup(snap).filter((t) => t.status !== "ship").length : 0
  const liveSessions = snap?.sessions.filter((x) => x.live_by === "herdr" || x.live_by === "live").length || 0
  void setup
  const groups = [
    ...(initActive ? [["Instalación", INSTALL] as const] : []),
    ["Observar", OBSERVE] as const,
    ...(snap?.op === false ? [] : [["Operar", OPERATE] as const]),
    ["Guía", GUIDE] as const,
  ]
  return (
    <Sidebar collapsible="offcanvas">
      <SidebarHeader className="gap-3 px-4 pb-3 pt-5">
        <div className="flex items-center gap-3 px-1">
          <span className="brand-glyph" aria-hidden="true"><Orbit className="size-4" /></span>
          <span className="min-w-0">
            <b className="block font-heading text-[16px] font-bold leading-none tracking-[-0.03em]">corvux</b>
            <span className="mt-1 block font-mono text-[8px] uppercase tracking-[0.24em] text-muted-foreground/55">agent observatory</span>
          </span>
        </div>
        {/* Selector de MÁQUINA global: muta TODA la página (tareas, sesiones,
            costo, terminales) hacia la máquina elegida — local o un VPS.
            En modo setup se oculta: el wizard configura ESTA máquina. */}
        <TargetSwitcher targets={snap?.targets || []} full />
        {snap?.op !== false && (
          <button onClick={() => nav({ name: "new" })} className={cn("sidebar-launch group", active("new") && "is-active")}>
            <span className="sidebar-launch-icon"><Plus /></span>
            <span className="min-w-0 flex-1 text-left"><b>Nueva tarea</b><small>Orquestar una misión</small></span>
            <ArrowUpRight className="size-3.5 opacity-55 transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5" />
          </button>
        )}
        <div className="sidebar-pulse">
          <span><Activity /><b>{activeTasks}</b><small>activas</small></span>
          <i />
          <span><Radio /><b>{liveSessions}</b><small>en vivo</small></span>
        </div>
      </SidebarHeader>
      <SidebarContent>
        {/* Operar se esconde cuando el backend es solo-lectura (op:false) —
            p.ej. servido por el daemon, que aún no ejecuta (ADR-0010). */}
        {groups.map(([label, items]) => (
          <SidebarGroup key={label} className="px-3 py-1.5">
            <SidebarGroupLabel className="text-[10px] font-bold uppercase tracking-[0.16em] text-muted-foreground/60">{label}</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {items.map((it) => (
                  <SidebarMenuItem key={it.v}>
                    <SidebarMenuButton
                      isActive={active(it.v)}
                      onClick={() => nav({ name: it.v } as View)}
                      className="nav-item h-9 rounded-xl px-2.5 data-[active=true]:bg-(--brand)/10 data-[active=true]:text-foreground"
                    >
                      <span className={cn("nav-icon-tile", active(it.v) && "is-active")}><it.icon /></span>
                      <span>{it.label}</span>
                    </SidebarMenuButton>
                    {badges[it.v] && <SidebarMenuBadge className="font-mono text-[10.5px] text-muted-foreground/70">{badges[it.v]}</SidebarMenuBadge>}
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        ))}
      </SidebarContent>
      <SidebarFooter className="sidebar-status mx-3 mb-3 rounded-2xl border border-sidebar-border px-3.5 py-3">
        <div className="flex items-center gap-2 text-[11px] text-muted-foreground/80">
          <span className={cn("size-[7px] shrink-0 rounded-full",
            live ? "bg-(--ok) shadow-[0_0_8px_rgba(16,185,129,.6)] animate-pulse" : "bg-muted-foreground/40")} />
          {live ? "en vivo" : "reconectando…"}
          <button
            onClick={() => setTheme(nextTheme[theme])}
            title={`tema: ${theme} — clic para cambiar`}
            className="ml-auto grid size-6 place-items-center rounded-md text-muted-foreground/70 transition-colors hover:bg-accent hover:text-foreground"
          >
            <ThemeIcon className="size-3.5" />
          </button>
        </div>
        <p className="mt-1.5 text-[9.5px] leading-relaxed text-muted-foreground/45">
          Observa todo. Opera con gates. A <span className="font-mono text-muted-foreground/70">main</span> solo se llega por <span className="font-mono text-muted-foreground/70">ship.sh</span>.
        </p>
      </SidebarFooter>
    </Sidebar>
  )
}
