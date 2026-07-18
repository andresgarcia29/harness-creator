// Paso 3 — Repositorios: elegir org → marcar repos (ref opcional) → clonar
// con progreso en vivo. Idempotente: reintentar no repite lo ya clonado.
import { useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { toast } from "sonner"
import { Fld, Empty } from "@/components/bits"
import { CircleCheck, CircleDashed, CircleX, DownloadCloud, Loader2 } from "lucide-react"
import type { InitState } from "@/lib/harness"
import { StepShell } from "../step-shell"
import { initOp, stepOf } from "../use-init"

type ApiRepo = { full_name: string; name: string; default_branch: string; private: boolean; language?: string }
type Sel = Record<string, { checked: boolean; ref: string }>

const RICON = { ok: CircleCheck, fail: CircleX, running: Loader2, pending: CircleDashed, skipped: CircleDashed } as const
const RCOLOR = { ok: "text-(--ok)", fail: "text-(--bad)", running: "text-(--wait)", pending: "text-muted-foreground/40", skipped: "text-muted-foreground/40" } as const

export function CloneStep({ init }: { init: InitState }) {
  const [orgs, setOrgs] = useState<string[]>([])
  const [org, setOrg] = useState("")
  const [repos, setRepos] = useState<ApiRepo[]>([])
  const [page, setPage] = useState(1)
  const [hasMore, setHasMore] = useState(false)
  const [sel, setSel] = useState<Sel>(() => {
    // arranca desde la selección ya guardada (resume): los checks no se pierden
    const out: Sel = {}
    for (const r of init.repos || []) out[r.full_name] = { checked: true, ref: r.ref || "" }
    return out
  })
  const [q, setQ] = useState("")
  const [busy, setBusy] = useState(false)
  const cloneStep = stepOf(init, "clone")
  const cloning = cloneStep?.status === "running"
  const shown = q.trim()
    ? repos.filter((r) => r.full_name.toLowerCase().includes(q.trim().toLowerCase()))
    : repos

  useEffect(() => {
    if (!init.github) return
    initOp("github-orgs").then((r) => {
      if (r.ok) { setOrgs(r.orgs); if (!org) setOrg(r.orgs[0] || "") }
      else toast.error(r.error)
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [init.github?.user])

  useEffect(() => {
    if (!org) return
    initOp("github-repos", { org, page }).then((r) => {
      if (r.ok) { setRepos((prev) => (page === 1 ? r.repos : prev.concat(r.repos))); setHasMore(r.has_more) }
      else toast.error(r.error)
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [org, page])

  if (!init.github) {
    return (
      <StepShell title="Repositorios" steps={[cloneStep]}>
        <Empty title="Primero GitHub">Completa el paso anterior para poder listar tus repos.</Empty>
      </StepShell>
    )
  }

  const marked = Object.entries(sel).filter(([, v]) => v.checked)
  const clonar = async () => {
    setBusy(true)
    const list = marked.map(([fn, v]) => ({ full_name: fn, ref: v.ref.trim() || undefined }))
    const r = await initOp("repos", { repos: list })
    if (!r.ok) { setBusy(false); toast.error(r.error); return }
    const r2 = await initOp("step", { step: "clone", action: "run" })
    setBusy(false)
    if (!r2.ok) toast.error(r2.error)
  }

  return (
    <StepShell
      title="Elige tus repositorios"
      lede={<>Se clonan a <span className="font-mono">repos/</span> dentro del workspace. Puedes
        pinear un tag o branch por repo (opcional). El discovery los escaneará después.</>}
      steps={[cloneStep]}
      actions={
        <Button disabled={busy || cloning || (marked.length === 0 && !(init.repos?.length))} onClick={clonar} className="gap-1.5">
          {busy || cloning ? <Loader2 className="size-3.5 animate-spin" /> : <DownloadCloud className="size-3.5" />}
          {cloning ? "Clonando…" : marked.length ? `Clonar ${marked.length} repo(s)` : "Reintentar clonado"}
        </Button>
      }
    >
      {(init.repos?.length || 0) > 0 && (
        <div className="space-y-1.5 rounded-2xl border p-3.5">
          <p className="mb-1 text-[10.5px] font-semibold uppercase tracking-wider text-muted-foreground">
            Selección actual · {init.repos!.filter((r) => r.status === "ok").length}/{init.repos!.length} clonados
          </p>
          {init.repos!.map((r) => {
            const I = RICON[r.status]
            return (
              <div key={r.full_name} className="flex items-center gap-2 text-[12.5px]">
                <I className={`size-3.5 shrink-0 ${RCOLOR[r.status]} ${r.status === "running" ? "animate-spin" : ""}`} />
                <span className="font-mono">{r.full_name}</span>
                {r.ref && <Badge variant="outline" className="font-mono text-[10px]">{r.ref}</Badge>}
                {r.error && <span className="truncate text-[11px] text-(--bad)">{r.error}</span>}
              </div>
            )
          })}
        </div>
      )}
      <Fld label="Organización">
        <Select value={org} onValueChange={(v) => { if (v) { setOrg(v); setPage(1) } }}>
          <SelectTrigger className="w-full"><SelectValue>{org || "…"}</SelectValue></SelectTrigger>
          <SelectContent>
            {orgs.map((o) => <SelectItem key={o} value={o}>{o}</SelectItem>)}
          </SelectContent>
        </Select>
      </Fld>
      <Fld label="Filtrar" hint={`${shown.length} de ${repos.length} cargados${hasMore ? " (hay más páginas)" : ""}`}>
        <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="escribe para filtrar por nombre…" spellCheck={false} />
      </Fld>
      <div className="max-h-80 overflow-y-auto rounded-2xl border">
        {shown.map((r) => {
          const s = sel[r.full_name] || { checked: false, ref: "" }
          return (
            <div key={r.full_name} className="flex items-center gap-2.5 border-b px-3.5 py-2 last:border-b-0">
              <Checkbox checked={s.checked}
                onCheckedChange={(v) => setSel({ ...sel, [r.full_name]: { ...s, checked: v === true } })} />
              <div className="min-w-0 flex-1">
                <span className="font-mono text-[12.5px]">{r.full_name}</span>
                {r.language && <span className="ml-2 text-[10.5px] text-muted-foreground/60">{r.language}</span>}
                {r.private && <Badge variant="outline" className="ml-2 text-[9.5px]">privado</Badge>}
              </div>
              {s.checked && (
                <Input value={s.ref} placeholder={r.default_branch}
                  onChange={(e) => setSel({ ...sel, [r.full_name]: { ...s, ref: e.target.value } })}
                  className="h-7 w-32 font-mono text-[11px]" spellCheck={false} />
              )}
            </div>
          )
        })}
        {shown.length === 0 && (
          <p className="p-4 text-[12px] text-muted-foreground/60">
            {repos.length === 0 ? "sin repos (¿scopes del token?)" : "nada coincide con el filtro" + (hasMore ? " — carga más páginas abajo" : "")}
          </p>
        )}
      </div>
      {hasMore && (
        <Button variant="ghost" size="sm" onClick={() => setPage(page + 1)}>cargar más…</Button>
      )}
    </StepShell>
  )
}
