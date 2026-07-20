import { useEffect, useState } from "react"
import { Card, CardContent } from "@/components/ui/card"
import { H2, Lede } from "@/components/bits"
import { cn } from "@/lib/utils"
import { fecha, type TaskGit } from "@/lib/harness"
import { withTarget } from "@/lib/target"
import { GitBranch, GitCommit, GitPullRequest, BookOpen, ArrowUpRight, CircleDot, FolderGit2 } from "lucide-react"

// Metadata de git de una tarea: qué repos toca vs lee, branch, commits, y si
// hubo PR o se fue directo a main. Se lee de /api/task-git (git + gh reales).
export function TaskGitPanel({ id }: { id: string }) {
  const [g, setG] = useState<TaskGit | null>(null)
  useEffect(() => {
    let live = true
    fetch(withTarget(`/api/task-git?task=${encodeURIComponent(id)}`))
      .then((r) => r.json()).then((d) => { if (live) setG(d) }).catch(() => {})
    return () => { live = false }
  }, [id])
  if (!g || (!(g.repos || []).length && !(g.read || []).length)) return null
  return (
    <>
      <H2 sub="git en vivo — qué se tocó, qué se leyó">Repos y cambios</H2>
      <Lede>Los repos con <b>worktree</b> son los que la tarea modifica; los <b>leídos</b> los consultó sin tocarlos.</Lede>
      <div className={cn("grid gap-3", (g.repos || []).length > 1 && "xl:grid-cols-2")}>
        {(g.repos || []).map((r) => (
          <Card key={r.repo} className="repo-card group overflow-hidden py-0"><CardContent className="p-0">
            <div className="flex items-start gap-3 p-4 sm:p-5">
              <span className="grid size-10 shrink-0 place-items-center rounded-xl border border-(--brand)/15 bg-(--brand)/8 text-(--brand)"><FolderGit2 className="size-4" /></span>
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-heading text-[15px] font-bold tracking-tight">{r.repo}</span>
                  {r.dirty && <span className="inline-flex items-center gap-1 rounded-full border border-(--wait)/25 bg-(--wait)/8 px-2 py-0.5 text-[9px] font-bold uppercase tracking-wider text-(--wait)"><CircleDot className="size-2.5" />sin commit</span>}
                </div>
                <span className="mt-1.5 flex min-w-0 items-center gap-1.5 font-mono text-[10.5px] text-muted-foreground">
                  <GitBranch className="size-3 shrink-0" /><span className="truncate">{r.branch}</span>
                </span>
              </div>
              <div className="shrink-0">
              {r.ahead > 0 && (
                <span className="flex items-center gap-1 font-mono text-[10.5px] font-semibold text-(--brand)">
                  <GitCommit className="size-3" />{r.ahead} sobre main
                </span>
              )}
              </div>
            </div>
            <div className="flex flex-wrap items-center gap-2 border-t border-border/65 bg-foreground/[0.018] px-4 py-3 sm:px-5">
              {r.pr ? (
                <a href={r.pr.url} target="_blank" rel="noreferrer"
                  className={cn("flex items-center gap-1 rounded-full border px-2.5 py-1 text-[10px] font-semibold",
                    r.pr.state === "merged" ? "border-(--brand)/40 bg-primary/10 text-(--brand)"
                      : r.pr.state === "open" ? "border-(--ok)/40 bg-(--ok)/8 text-(--ok)"
                      : "border-border text-muted-foreground")}>
                  <GitPullRequest className="size-3" />PR #{r.pr.number} · {r.pr.state}<ArrowUpRight className="size-3" />
                </a>
              ) : r.pushed_direct ? (
                <span className="flex items-center gap-1 rounded-full border border-(--wait)/30 bg-(--wait)/8 px-2.5 py-1 text-[10px] font-semibold text-(--wait)">
                  directo a main · sin PR
                </span>
              ) : (
                <span className="inline-flex items-center gap-1.5 text-[10px] font-semibold text-(--brand)"><i className="size-1.5 animate-pulse rounded-full bg-(--brand)" />trabajo en curso</span>
              )}
            {r.last_subject && (
              <p className="flex min-w-0 flex-1 items-center gap-2 text-[11px] text-muted-foreground sm:ml-auto">
                <GitCommit className="size-3 shrink-0 opacity-45" /><span className="truncate">{r.last_subject}</span>
                {r.last_ts > 0 && <span className="ml-auto shrink-0 font-mono text-[10.5px] text-muted-foreground/50">{fecha(r.last_ts)}</span>}
              </p>
            )}
            </div>
          </CardContent></Card>
        ))}
        {g.read.length > 0 && (
          <Card className="border-dashed py-0 xl:col-span-full"><CardContent className="flex flex-wrap items-center gap-2 p-3.5">
            <BookOpen className="size-3.5 text-muted-foreground/60" />
            <span className="text-[11.5px] text-muted-foreground/70">solo leídos:</span>
            {(g.read || []).map((r) => (
              <span key={r} className="rounded-md bg-secondary px-2 py-0.5 font-mono text-[11px] text-muted-foreground">{r}</span>
            ))}
          </CardContent></Card>
        )}
      </div>
    </>
  )
}
