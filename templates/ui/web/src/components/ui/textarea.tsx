import * as React from "react"

import { cn } from "@/lib/utils"

function Textarea({ className, ...props }: React.ComponentProps<"textarea">) {
  return (
    <textarea
      data-slot="textarea"
      className={cn(
        "flex field-sizing-content min-h-20 w-full rounded-xl border border-input bg-background/35 px-3 py-2.5 text-base shadow-[inset_0_1px_0_var(--glass-highlight)] transition-colors outline-none placeholder:text-muted-foreground/55 focus-visible:border-(--brand)/60 focus-visible:bg-background/55 focus-visible:ring-3 focus-visible:ring-(--brand)/12 disabled:cursor-not-allowed disabled:bg-input/50 disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-3 aria-invalid:ring-destructive/20 md:text-sm dark:bg-white/[0.035] dark:disabled:bg-input/80 dark:aria-invalid:border-destructive/50 dark:aria-invalid:ring-destructive/40",
        className
      )}
      {...props}
    />
  )
}

export { Textarea }
