// ansi.tsx — render de ANSI SGR a React. herdr normaliza el color a 38;5;N
// (256 colores) + bold/dim + reset; el resto de secuencias CSI/OSC se
// descartan. Sin dependencias: es un autómata de ~80 líneas, no una lib.
import type { ReactNode } from "react"

// Paleta xterm-256: 0-15 básicos (afinados al tema del panel), 16-231 cubo
// 6x6x6, 232-255 grises.
const BASE16 = [
  "#3d3d43", "#ff6b7f", "#4ade80", "#facc15", "#7c9bff", "#d98bff", "#5eead4", "#d6d6dc",
  "#71717a", "#ff8a9a", "#86efac", "#fde047", "#a5b4fc", "#e9a8ff", "#99f6e4", "#ffffff",
]
function xterm256(n: number): string {
  if (n < 16) return BASE16[n]
  if (n < 232) {
    const c = n - 16
    const v = (x: number) => (x === 0 ? 0 : 55 + x * 40)
    const r = v(Math.floor(c / 36)), g = v(Math.floor((c % 36) / 6)), b = v(c % 6)
    return `rgb(${r},${g},${b})`
  }
  const g = 8 + (n - 232) * 10
  return `rgb(${g},${g},${g})`
}

type Style = { fg?: string; bg?: string; bold?: boolean; dim?: boolean; italic?: boolean; underline?: boolean }

function applySGR(st: Style, params: number[]): Style {
  const s = { ...st }
  for (let i = 0; i < params.length; i++) {
    const p = params[i]
    if (p === 0) return {}
    else if (p === 1) s.bold = true
    else if (p === 2) s.dim = true
    else if (p === 3) s.italic = true
    else if (p === 4) s.underline = true
    else if (p === 22) { s.bold = false; s.dim = false }
    else if (p >= 30 && p <= 37) s.fg = BASE16[p - 30]
    else if (p >= 90 && p <= 97) s.fg = BASE16[p - 90 + 8]
    else if (p === 39) s.fg = undefined
    else if (p >= 40 && p <= 47) s.bg = BASE16[p - 40]
    else if (p >= 100 && p <= 107) s.bg = BASE16[p - 100 + 8]
    else if (p === 49) s.bg = undefined
    else if (p === 38 && params[i + 1] === 5) { s.fg = xterm256(params[i + 2] ?? 7); i += 2 }
    else if (p === 48 && params[i + 1] === 5) { s.bg = xterm256(params[i + 2] ?? 0); i += 2 }
    else if (p === 38 && params[i + 1] === 2) { s.fg = `rgb(${params[i + 2]},${params[i + 3]},${params[i + 4]})`; i += 4 }
    else if (p === 48 && params[i + 1] === 2) { s.bg = `rgb(${params[i + 2]},${params[i + 3]},${params[i + 4]})`; i += 4 }
  }
  return s
}

// eslint-disable-next-line no-control-regex
const TOKEN = /\x1b\[([0-9;]*)m|\x1b\[[0-9;?]*[A-Za-ln-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Z0-9]/g

export function Ansi({ text }: { text: string }) {
  const clean = text.replace(/\r\n?/g, "\n")
  const out: ReactNode[] = []
  let st: Style = {}
  let last = 0, key = 0
  const push = (chunk: string) => {
    if (!chunk) return
    const css: React.CSSProperties = {}
    if (st.fg) css.color = st.fg
    if (st.bg) css.backgroundColor = st.bg
    if (st.bold) css.fontWeight = 700
    if (st.dim) css.opacity = 0.6
    if (st.italic) css.fontStyle = "italic"
    if (st.underline) css.textDecoration = "underline"
    out.push(Object.keys(css).length ? <span key={key++} style={css}>{chunk}</span> : chunk)
  }
  for (const m of clean.matchAll(TOKEN)) {
    push(clean.slice(last, m.index))
    last = (m.index ?? 0) + m[0].length
    if (m[1] !== undefined) {
      const params = m[1] === "" ? [0] : m[1].split(";").map((x) => parseInt(x || "0", 10))
      st = applySGR(st, params)
    } // las demás secuencias (cursor/OSC) se descartan
  }
  push(clean.slice(last))
  return <>{out}</>
}
