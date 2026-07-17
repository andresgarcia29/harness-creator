import { useEffect, useState } from "react"
import { Card, CardContent } from "@/components/ui/card"
import { H2, Lede } from "@/components/bits"
import { cn } from "@/lib/utils"
import { fecha, type TaskGit } from "@/lib/harness"
import { GitBranch, GitCommit, GitPullRequest, BookOpen, ArrowUpRight, CircleDot } from "lucide-react"

// Metadata de git de una tarea: qué repos toca vs lee, branch, commits, y si
// hubo PR o se fue directo a main. Se lee de /api/task-git (git + gh reales).
export function TaskGitPanel({ id }: { id: string }) {
  const [g, setG] = useState<TaskGit | null>(null)
  useEffect(() => {
    let live = true
    fetch(`/api/task-git?task=${encodeURIComponent(id)}`)
      .then((r) => r.json()).then((d) => { if (live) setG(d) }).catch(() => {})
    return () => { live = false }
  }, [id])
  if (!g || (!g.repos.length && !g.read.length)) return null
  return (
    <>
      <H2 sub="git en vivo — qué se tocó, qué se leyó">Repos y cambios</H2>
      <Lede>Los repos con <b>worktree</b> son los que la tarea modifica; los <b>leídos</b> los consultó sin tocarlos.</Lede>
      <div className="grid gap-2.5">
        {g.repos.map((r) => (
          <Card key={r.repo} className="py-0"><CardContent className="p-4">
            <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
              <span className="font-mono text-[13px] font-semibold">{r.repo}</span>
              <span className="flex items-center gap-1 font-mono text-[11.5px] text-muted-foreground">
                <GitBranch className="size-3" />{r.branch}
              </span>
              {r.ahead > 0 && (
                <span className="flex items-center gap-1 font-mono text-[11.5px] text-(--brand)">
                  <GitCommit className="size-3" />{r.ahead} sobre main
                </span>
              )}
              {r.dirty && (
                <span className="flex items-center gap-1 text-[11px] text-(--wait)">
                  <CircleDot className="size-3" />cambios sin commit
                </span>
              )}
              {r.pr ? (
                <a href={r.pr.url} target="_blank" rel="noreferrer"
                  className={cn("ml-auto flex items-center gap-1 rounded-full border px-2.5 py-1 text-[11px] font-semibold",
                    r.pr.state === "merged" ? "border-(--brand)/40 bg-primary/10 text-(--brand)"
                      : r.pr.state === "open" ? "border-(--ok)/40 bg-(--ok)/8 text-(--ok)"
                      : "border-border text-muted-foreground")}>
                  <GitPullRequest className="size-3" />PR #{r.pr.number} · {r.pr.state}<ArrowUpRight className="size-3" />
                </a>
              ) : r.pushed_direct ? (
                <span className="ml-auto flex items-center gap-1 rounded-full border border-(--wait)/40 bg-(--wait)/8 px-2.5 py-1 text-[11px] font-semibold text-(--wait)">
                  directo a main · sin PR
                </span>
              ) : (
                <span className="ml-auto text-[11px] text-muted-foreground/60">trabajo en curso</span>
              )}
            </div>
            {r.last_subject && (
              <p className="mt-2 flex items-baseline gap-2 text-[12px] text-muted-foreground">
                <span className="truncate">{r.last_subject}</span>
                {r.last_ts > 0 && <span className="ml-auto shrink-0 font-mono text-[10.5px] text-muted-foreground/50">{fecha(r.last_ts)}</span>}
              </p>
            )}
          </CardContent></Card>
        ))}
        {g.read.length > 0 && (
          <Card className="border-dashed py-0"><CardContent className="flex flex-wrap items-center gap-2 p-3.5">
            <BookOpen className="size-3.5 text-muted-foreground/60" />
            <span className="text-[11.5px] text-muted-foreground/70">solo leídos:</span>
            {g.read.map((r) => (
              <span key={r} className="rounded-md bg-secondary px-2 py-0.5 font-mono text-[11px] text-muted-foreground">{r}</span>
            ))}
          </CardContent></Card>
        )}
      </div>
    </>
  )
}
