import path from "path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

// El build se vendorea en ../dist y lo sirve server.py (stdlib): el usuario
// final jamás necesita Node — Node es herramienta de build, no de runtime.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
  build: { outDir: "../dist", emptyOutDir: true },
  base: "./",
})
