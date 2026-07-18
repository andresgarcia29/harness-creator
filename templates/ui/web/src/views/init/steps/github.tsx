// Paso 2 — GitHub: gh ya autenticado (un clic) o PAT pegado (validado
// server-side, guardado write-only 0600, jamás se re-muestra).
import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { toast } from "sonner"
import { Fld, Code } from "@/components/bits"
import { CircleCheck, KeyRound, Loader2, GitBranch } from "lucide-react"
import type { InitState } from "@/lib/harness"
import { StepShell } from "../step-shell"
import { initOp, stepOf } from "../use-init"

export function GithubStep({ init }: { init: InitState }) {
  const [pat, setPat] = useState("")
  const [busy, setBusy] = useState<"" | "gh" | "pat">("")
  const done = !!init.github

  const conectar = async (mode: "gh" | "pat") => {
    setBusy(mode)
    const r = await initOp("github", mode === "gh" ? { mode } : { mode, token: pat })
    setBusy("")
    if (!r.ok) { toast.error(r.error || "no pude conectar GitHub"); return }
    setPat("")
    toast.success(`GitHub conectado como ${r.user}`)
  }

  return (
    <StepShell
      title="Conecta GitHub"
      lede={<>Para listar tus organizaciones y clonar los repos. Dos caminos: el CLI{" "}
        <Code>gh</Code> si ya está autenticado en esta máquina, o un token (PAT) que se
        valida contra la API y se guarda con permisos 0600 — nunca se vuelve a mostrar.</>}
      steps={[stepOf(init, "github")]}
    >
      {done ? (
        <div className="flex items-center gap-2.5 rounded-xl border border-(--ok)/35 bg-(--ok)/8 p-3.5">
          <CircleCheck className="size-4 shrink-0 text-(--ok)" />
          <span className="text-[13px]">
            Conectado como <b>{init.github!.user}</b> vía {init.github!.mode === "gh" ? <Code>gh</Code> : "PAT"} —
            puedes reconectar abajo para rotar.
          </span>
        </div>
      ) : null}
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="rounded-2xl border p-4">
          <div className="mb-2 flex items-center gap-2 text-[13px] font-medium"><GitBranch className="size-4" /> CLI gh</div>
          <p className="mb-3 text-[12px] text-muted-foreground">Si ya corriste <Code>gh auth login</Code> aquí, es un clic.</p>
          <Button variant="outline" disabled={busy !== ""} onClick={() => conectar("gh")} className="gap-1.5">
            {busy === "gh" && <Loader2 className="size-3.5 animate-spin" />} Detectar gh
          </Button>
        </div>
        <div className="rounded-2xl border p-4">
          <div className="mb-2 flex items-center gap-2 text-[13px] font-medium"><KeyRound className="size-4" /> Token (PAT)</div>
          <Fld label="Personal access token" hint="scopes: repo, read:org">
            <Input type="password" value={pat} onChange={(e) => setPat(e.target.value)}
              placeholder={done ? "token guardado — pega uno nuevo para rotarlo" : "ghp_… / github_pat_…"} />
          </Fld>
          <Button disabled={busy !== "" || !pat.trim()} onClick={() => conectar("pat")} className="gap-1.5">
            {busy === "pat" && <Loader2 className="size-3.5 animate-spin" />} Validar y guardar
          </Button>
        </div>
      </div>
    </StepShell>
  )
}
