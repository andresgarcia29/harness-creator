import { useEffect, useState } from "react"

export type Theme = "light" | "dark" | "system"
const KEY = "corvux-theme"

function apply(t: Theme) {
  const dark = t === "dark" || (t === "system" && matchMedia("(prefers-color-scheme: dark)").matches)
  document.documentElement.classList.toggle("dark", dark)
}

// Light/Dark/System, como el toggle de Agora. Persiste en localStorage y
// sigue al sistema cuando está en "system".
export function useTheme() {
  const [theme, setTheme] = useState<Theme>(() => (localStorage.getItem(KEY) as Theme) || "dark")
  useEffect(() => {
    apply(theme)
    localStorage.setItem(KEY, theme)
    if (theme !== "system") return
    const mq = matchMedia("(prefers-color-scheme: dark)")
    const fn = () => apply("system")
    mq.addEventListener("change", fn)
    return () => mq.removeEventListener("change", fn)
  }, [theme])
  return { theme, setTheme }
}
