import { Badge } from "@/components/ui/badge"
import { VHead, Code, PendAlert, Empty, NumCell, StatusBadge } from "@/components/bits"
import { BUSKINDS, pending, type Snapshot, type Task } from "@/lib/harness"
import { ArchiveButton } from "@/components/archive-button"
import type { Go } from "@/App"

const blank = (id: string): Task => ({ id, title: "", origin: "", phase: null, done: [], verdicts: { pass: 0, total: 0 }, assumptions: [] })

export function Tasks({ s, go }: { s: Snapshot; go: Go }) {
  const evs = s.events.filter((e) => BUSKINDS.includes(e.kind))
  // excluye las archivadas: si no, sus eventos del bus las reviven en la lista.
  const archived = new Set(s.archived_tasks || [])
  const ids = [...new Set([...s.tasks.map((t) => t.id), ...evs.map((e) => e.task).filter(Boolean) as string[]])]
    .filter((id) => !archived.has(id))
  if (!ids.length)
    return (
      <>
        <VHead title="Tareas" sub="todo el espacio de trabajo" />
        <Empty title="Sin tareas todavía">
          <p>Aparecen cuando corras <Code>/auto</Code> con un ticket o un prompt, o cuando <Code>ship.sh</Code> registre trabajo. Todo con datos reales: aquí no hay ejemplos.</p>
        </Empty>
      </>
    )
  const pend = pending(s)
  return (
    <>
      <VHead title="Tareas" sub="todo el espacio de trabajo" />
      {pend.slice(-2).map((e) => (
        <PendAlert key={e.task} kind={e._k} onClick={() => go({ name: "task", id: e.task! })}
          title={`${e._k === "block" ? "Un gate bloqueó" : "Te está esperando"} — ${e.task}`}
          summary={e.summary}
          hint="Es lo último que registró esa tarea; nada ha pasado después. Clic para ver su historia." />
      ))}
      <div className="grid gap-2.5">
        {ids.map((id) => {
          const t = s.tasks.find((x) => x.id === id) || blank(id)
          const p = pend.find((e) => e.task === id)
          const tevs = evs.filter((e) => e.task === id)
          const lastTs = tevs.length ? tevs[tevs.length - 1].ts : ""
          return (
            <div key={id} role="button" tabIndex={0} onClick={() => go({ name: "task", id })}
              onKeyDown={(e) => { if (e.key === "Enter") go({ name: "task", id }) }}
              className="group flex w-full min-w-0 cursor-pointer items-center gap-3.5 overflow-hidden rounded-xl border border-border bg-card p-3.5 px-4 text-left transition-all hover:border-primary/45 hover:shadow-[0_0_10px_rgba(99,102,241,.2)]">
              <span className="shrink-0 font-mono text-[12.5px] font-semibold text-(--brand)">{id}</span>
              <span className="min-w-0 flex-1 truncate text-xs text-muted-foreground/80">{t.title || ""}</span>
              {p && <StatusBadge on={false}>{p._k === "block" ? "✕ bloqueada" : "⏸ te espera"}</StatusBadge>}
              {t.origin && <Badge variant="outline" className="hidden rounded-full text-[9px] uppercase tracking-wider text-muted-foreground sm:inline-flex">{t.origin}</Badge>}
              <NumCell v={t.phase || "—"} l="fase" className="hidden md:block" />
              <NumCell v={t.assumptions.length} l="supuestos" className="hidden md:block" />
              <NumCell v={lastTs ? lastTs.slice(11, 16) : "—"} l="últ. evento" />
              <ArchiveButton kind="task" id={id} />
            </div>
          )
        })}
      </div>
    </>
  )
}
