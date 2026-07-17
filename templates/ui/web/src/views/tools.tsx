// Skills & MCP: inventario con ESTADO REAL. "Funciona" no se declara: la sonda
// lanza cada MCP y le habla el protocolo (JSON-RPC initialize) — la única
// prueba honesta. "Autenticado" = arrancó con sus credenciales y contestó.
import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { toast } from "sonner"
import { VHead, H2, Lede, Code, Empty, StatusBadge } from "@/components/bits"
import { cn } from "@/lib/utils"
import { op, type McpServer, type Snapshot } from "@/lib/harness"
import { CircleCheck, CircleX, CircleDashed, KeyRound, Terminal } from "lucide-react"

function McpCard({ m }: { m: McpServer }) {
  const p = m.probe
  const estado = p == null ? "sin probar" : p.ok ? "funciona" : "falló"
  const auth: [string, string] =
    p == null
      ? ["—", "text-muted-foreground/60"]
      : p.ok
        ? [m.wrapped || m.env.length ? "autenticado" : "no requiere auth", "text-(--ok)"]
        : p.auth_hint
          ? ["parece problema de credenciales", "text-(--bad)"]
          : ["—", "text-muted-foreground/60"]
  return (
    <Card className="py-0"><CardContent className="p-4">
      <div className="flex flex-wrap items-center gap-2.5">
        {p == null
          ? <CircleDashed className="size-4 shrink-0 text-muted-foreground/50" />
          : p.ok
            ? <CircleCheck className="size-4 shrink-0 text-(--ok)" />
            : <CircleX className="size-4 shrink-0 text-(--bad)" />}
        <b className="font-mono text-[13px] font-semibold">{m.name}</b>
        <StatusBadge on={p?.ok}>{estado}</StatusBadge>
        {m.wrapped && (
          <Badge variant="outline" className="rounded-full text-[9px] uppercase tracking-wider text-muted-foreground">
            <KeyRound className="size-2.5" /> with-secrets
          </Badge>
        )}
        {p?.ok && p.server && (
          <span className="font-mono text-[10.5px] text-muted-foreground/60">
            {p.server} {p.version} · {p.ms} ms
          </span>
        )}
      </div>
      <div className="mt-1.5 flex items-center gap-2 font-mono text-[10.5px] text-muted-foreground/60">
        <Terminal className="size-3 shrink-0" />
        <span className="truncate">{m.command} {m.args.join(" ")}</span>
      </div>
      <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11.5px]">
        <span className={m.bin_ok ? "text-muted-foreground" : "text-(--bad)"}>
          binario: {m.bin_ok ? "en PATH ✓" : "NO encontrado"}
        </span>
        {m.secrets_ok != null && (
          <span className={m.secrets_ok ? "text-muted-foreground" : "text-(--wait)"}>
            secretos: {m.secrets_ok ? ".secrets presente ✓" : "falta .secrets — corre make secrets"}
          </span>
        )}
        {m.env.length > 0 && <span className="text-muted-foreground">env: {m.env.join(", ")}</span>}
        <span className={cn("font-medium", auth[1])}>{auth[0]}</span>
      </div>
      {p && !p.ok && p.error && (
        <p className="mt-2 rounded-lg border border-(--bad)/30 bg-(--bad)/8 px-3 py-1.5 font-mono text-[11px] text-muted-foreground">
          {p.error}
        </p>
      )}
      {p?.at && <p className="mt-1.5 text-[10px] text-muted-foreground/50">probado {p.at.slice(11, 16)} UTC</p>}
    </CardContent></Card>
  )
}

export function Tools({ s }: { s: Snapshot }) {
  const mcp = s.mcp || []
  const skills = s.toolbox?.skills || []
  const [busy, setBusy] = useState(false)
  const probar = async () => {
    setBusy(true)
    toast.info("Sondeando todos los MCPs — el handshake real puede tardar unos segundos…")
    const r = await op("/api/op/probe-mcp", {})
    setBusy(false)
    if (!r.ok && r.error) { toast.error(r.error); return }
    const res = r.probed || {}
    const ok = Object.values(res).filter((x: any) => x.ok).length
    toast.success(`Sonda completa: ${ok}/${Object.keys(res).length} contestaron el protocolo.`)
  }
  return (
    <>
      <VHead title="Skills & MCP" sub="inventario real de esta instancia — el estado no se declara, se sondea" />

      <H2 sub=".mcp.json — los servidores que Claude Code levanta en este workspace">MCPs</H2>
      <Lede>
        La sonda lanza cada servidor y le habla <Code>initialize</Code> (JSON-RPC) — la única prueba honesta de
        "funciona". Un MCP envuelto en <Code>with-secrets.sh</Code> que contesta, contesta <b>autenticado</b>.
        Ojo: <Code>npx</Code>/<Code>uvx</Code> pueden tardar la primera vez (descargan); reintenta si hay timeout.
      </Lede>
      {mcp.length ? (
        <>
          <Button onClick={probar} disabled={busy} className="mb-3">{busy ? "sondeando…" : "Probar todos ahora"}</Button>
          <div className="grid gap-2.5">{mcp.map((m) => <McpCard key={m.name} m={m} />)}</div>
        </>
      ) : (
        <Empty><p>Este workspace no tiene <Code>.mcp.json</Code> (o está vacío). Los MCPs se eligen en la entrevista de <Code>/harness-init</Code>.</p></Empty>
      )}

      <H2 sub=".claude/skills/ — instrucciones empaquetadas que un agente puede invocar">Skills</H2>
      {skills.length ? (
        <div className="grid gap-2 md:grid-cols-2">
          {skills.map((sk) => (
            <Card key={sk.name} className="py-0"><CardContent className="p-3.5">
              <div className="flex items-center gap-2">
                {sk.ok ? <CircleCheck className="size-3.5 text-(--ok)" /> : <CircleX className="size-3.5 text-(--bad)" />}
                <b className="font-mono text-xs font-semibold">{sk.name}</b>
              </div>
              <p className="mt-0.5 text-[11.5px] leading-relaxed text-muted-foreground">{sk.desc}</p>
            </CardContent></Card>
          ))}
        </div>
      ) : (
        <Empty>
          <p>Esta instancia no tiene skills propias en <Code>.claude/skills/</Code>.</p>
          <p>Las del plugin (harness-init, harness-update, harness-doctor) viven en el plugin y se invocan como comandos — están documentadas en <b className="text-foreground/80">Docs</b>.</p>
          <p>Una skill no se puede "probar" sin ejecutarla: aquí verificamos que exista y que su <Code>SKILL.md</Code> parsee.</p>
        </Empty>
      )}
    </>
  )
}
