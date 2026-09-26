"use client"

import * as React from "react"
import * as CheckboxPrimitive from "@radix-ui/react-checkbox"
import { Check } from "lucide-react"
import { cn } from "@/lib/utils"

const Checkbox = React.forwardRef<
  React.ElementRef<typeof CheckboxPrimitive.Root>,
  React.ComponentPropsWithoutRef<typeof CheckboxPrimitive.Root>
>(({ className, ...props }, ref) => (
  // The checked state pairs `bg-primary` with `text-primary-foreground`, never
  // `text-foreground`: in the dark token set (globals.css `.dark`) both
  // --primary and --foreground are `210 40% 98%`, so `text-foreground` would
  // paint the tick near-white on a near-white box. The Indicator inherits this
  // colour through `text-current`. jsdom cannot compute the Tailwind cascade,
  // so this pairing is documented here rather than unit-tested; the visual
  // assertion is a computed-style check in a real browser
  // (`[data-state="checked"]` colour must differ from its background).
  <CheckboxPrimitive.Root
    ref={ref}
    className={cn(
      "peer h-4 w-4 shrink-0 rounded-sm border border-primary ring-offset-background focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 data-[state=checked]:bg-primary data-[state=checked]:text-primary-foreground",
      className
    )}
    {...props}
  >
    <CheckboxPrimitive.Indicator className={cn("flex items-center justify-center text-current")}>
      <Check className="h-4 w-4" />
    </CheckboxPrimitive.Indicator>
  </CheckboxPrimitive.Root>
))
Checkbox.displayName = CheckboxPrimitive.Root.displayName

export { Checkbox }
