// prompt-parse.ts — detecta cuándo un agente está PREGUNTANDO en su terminal y
// saca las opciones, para ofrecer botones en vez de que teclees a ciegas.
// Tolerante a formatos (Claude Code, Codex, prompts y/n de cualquier CLI);
// si no reconoce nada, no hay menú y se cae al texto libre. El texto ya viene
// sin ANSI para parsear (se limpian las secuencias).

// eslint-disable-next-line no-control-regex
const ANSI = /\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Z0-9]/g

export type MenuOption = { key: string; label: string }
export type Prompt =
  | { kind: "menu"; question: string; options: MenuOption[] }
  | { kind: "yesno"; question: string }
  | null

function strip(s: string): string {
  return s.replace(ANSI, "").replace(/\r/g, "")
}

// Busca un bloque de opciones numeradas en las últimas líneas.
export function parsePrompt(ansiText: string): Prompt {
  const lines = strip(ansiText).split("\n").map((l) => l.replace(/\s+$/g, ""))
  const tail = lines.slice(-24)

  // 1. Opciones numeradas: "❯ 1. Sí", "1) No", " 2. …", "[1] …"
  const opts: MenuOption[] = []
  const optRe = /^\s*[❯>›▶*•\-]?\s*[[(]?\s*(\d+)\s*[.)\]]\s+(.{1,80}?)\s*$/
  for (const l of tail) {
    const m = l.match(optRe)
    if (m) {
      const key = m[1]
      // evita duplicar si el mismo número ya salió
      if (!opts.some((o) => o.key === key)) opts.push({ key, label: m[2].trim() })
    }
  }
  if (opts.length >= 2) {
    // la "pregunta" = la última línea no-opción antes del bloque
    const firstOptIdx = tail.findIndex((l) => optRe.test(l))
    let q = ""
    for (let i = firstOptIdx - 1; i >= 0 && i >= firstOptIdx - 4; i--) {
      const t = tail[i].trim()
      if (t) { q = t; break }
    }
    return { kind: "menu", question: q.slice(0, 160), options: opts.slice(0, 6) }
  }

  // 2. y/n en cualquier idioma: "(y/n)", "[Y/n]", "¿…? (s/n)", "Proceed? (yes/no)"
  for (let i = tail.length - 1; i >= 0 && i >= tail.length - 6; i--) {
    const l = tail[i]
    if (/\(\s*y(es)?\s*\/\s*n(o)?\s*\)|\[\s*y\s*\/\s*n\s*\]|\(\s*s[ií]?\s*\/\s*n(o)?\s*\)/i.test(l)) {
      return { kind: "yesno", question: l.trim().slice(0, 160) }
    }
  }
  return null
}
