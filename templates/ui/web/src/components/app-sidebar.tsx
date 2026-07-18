import {
  Sidebar, SidebarContent, SidebarFooter, SidebarGroup, SidebarGroupContent,
  SidebarGroupLabel, SidebarHeader, SidebarMenu, SidebarMenuBadge,
  SidebarMenuButton, SidebarMenuItem, useSidebar,
} from "@/components/ui/sidebar"
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import { usd, type Snapshot } from "@/lib/harness"
import { LayoutDashboard, ListTodo, Radio, ChartNoAxesColumn, Plus, Cable, Sun, Moon, Monitor, BookOpen, Blocks, SquareTerminal } from "lucide-react"
import { useTheme, type Theme } from "@/hooks/use-theme"
import type { View } from "@/App"

const OBSERVE = [
  { v: "dash", label: "Resumen", icon: LayoutDashboard },
  { v: "tasks", label: "Tareas", icon: ListTodo },
  { v: "sessions", label: "Sesiones", icon: Radio },
  { v: "terminals", label: "Terminales", icon: SquareTerminal },
  { v: "costs", label: "Gastos", icon: ChartNoAxesColumn },
] as const
const OPERATE = [
  { v: "new", label: "Nueva tarea", icon: Plus },
  { v: "connections", label: "Conexiones", icon: Cable },
] as const
const GUIDE = [
  { v: "docs", label: "Docs", icon: BookOpen },
  { v: "tools", label: "Skills & MCP", icon: Blocks },
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
  const badges: Record<string, string> = {
    tasks: String(snap?.tasks.length || ""),
    sessions: String(snap?.sessions.length || ""),
    costs: snap?.cost != null ? usd(snap.cost) : "",
  }
  return (
    <Sidebar collapsible="offcanvas">
      <SidebarHeader className="px-4 pb-2 pt-5">
        <div className="flex items-center gap-2.5">
          <span className="grid size-7 shrink-0 place-items-center rounded-lg bg-gradient-to-br from-primary to-(--brand) font-heading text-sm font-bold text-white shadow-[0_0_10px_rgba(99,102,241,.35)]">c</span>
          <b className="font-heading text-[15px] font-bold tracking-tight">corvux</b>
          <Badge variant="outline" className="rounded-full border-primary/35 bg-primary/10 text-[8.5px] font-bold uppercase tracking-wider text-(--brand)">
            {snap?.mode || "local"}
          </Badge>
        </div>
      </SidebarHeader>
      <SidebarContent>
        {/* Operar se esconde cuando el backend es solo-lectura (op:false) —
            p.ej. servido por el daemon, que aún no ejecuta (ADR-0010). */}
        {([["Observar", OBSERVE] as const,
           ...(snap?.op === false ? [] : [["Operar", OPERATE] as const]),
           ["Guía", GUIDE] as const]).map(([label, items]) => (
          <SidebarGroup key={label}>
            <SidebarGroupLabel className="text-[10px] font-bold uppercase tracking-[0.16em] text-muted-foreground/60">{label}</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {items.map((it) => (
                  <SidebarMenuItem key={it.v}>
                    <SidebarMenuButton
                      isActive={active(it.v)}
                      onClick={() => nav({ name: it.v } as View)}
                      className="rounded-xl data-[active=true]:bg-primary/15 data-[active=true]:text-(--brand) data-[active=true]:shadow-[inset_0_0_0_1px_rgba(99,102,241,.18)]"
                    >
                      <it.icon className={cn("transition-transform", active(it.v) && "scale-110")} />
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
      <SidebarFooter className="border-t border-sidebar-border px-4 py-3.5">
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
        <p className="text-[10px] leading-relaxed text-muted-foreground/50">
          Operar crea trabajo, jamás merges: todo lo que lances desde aquí pasa por
          los mismos gates. A main solo se llega por <span className="font-mono">ship.sh</span>.
        </p>
      </SidebarFooter>
    </Sidebar>
  )
}
