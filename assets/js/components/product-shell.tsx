import type { PropsWithChildren } from "react"
import {
  Activity,
  BellRing,
  FlaskConical,
  LayoutDashboard,
  Settings2,
  ShieldCheck,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip"
import { cn } from "@/lib/utils"

const navigation = [
  { label: "Overview", icon: LayoutDashboard, current: true },
  { label: "Monitors", icon: Activity, current: false },
  { label: "Alerts", icon: BellRing, current: false },
  { label: "Settings", icon: Settings2, current: false },
]

type ProductShellProps = PropsWithChildren<{
  releaseStage: string
}>

export function ProductShell({ children, releaseStage }: ProductShellProps) {
  return (
    <TooltipProvider>
      <div className="min-h-screen bg-background text-foreground">
        <div className="mx-auto flex min-h-screen max-w-[1600px]">
          <aside className="hidden w-64 shrink-0 border-r border-sidebar-border bg-sidebar px-4 py-5 lg:block">
            <a
              id="product-brand"
              href="/app"
              className="flex items-center gap-3 rounded-xl px-2 py-1.5 transition-colors hover:bg-sidebar-accent"
            >
              <span className="grid size-9 place-items-center rounded-xl bg-sidebar-primary text-sidebar-primary-foreground shadow-sm">
                <span className="size-2.5 rounded-full bg-current" />
              </span>
              <span>
                <span className="block text-sm font-semibold tracking-tight">
                  Silent Regression
                </span>
                <span className="block text-xs text-sidebar-foreground/60">
                  Deterministic monitoring
                </span>
              </span>
            </a>

            <nav id="product-navigation" className="mt-8 space-y-1" aria-label="Product">
              {navigation.map(item => {
                const Icon = item.icon

                return (
                  <Tooltip key={item.label}>
                    <TooltipTrigger asChild>
                      <Button
                        type="button"
                        variant="ghost"
                        disabled={!item.current}
                        aria-current={item.current ? "page" : undefined}
                        className={cn(
                          "h-10 w-full justify-start rounded-lg px-3 text-sidebar-foreground",
                          item.current &&
                            "bg-sidebar-accent text-sidebar-accent-foreground shadow-xs",
                        )}
                      >
                        <Icon />
                        {item.label}
                      </Button>
                    </TooltipTrigger>
                    {!item.current && (
                      <TooltipContent side="right">Available in a later task</TooltipContent>
                    )}
                  </Tooltip>
                )
              })}
            </nav>

            <div className="mt-8 rounded-xl border border-sidebar-border bg-sidebar-accent/60 p-4">
              <div className="flex items-center gap-2 text-sm font-medium">
                <ShieldCheck className="size-4 text-primary" />
                Private by design
              </div>
              <p className="mt-2 text-xs leading-5 text-sidebar-foreground/65">
                Provider credentials and captured outputs stay inside each workspace boundary.
              </p>
            </div>
          </aside>

          <div className="min-w-0 flex-1">
            <header className="sticky top-0 z-20 border-b border-border/80 bg-background/90 backdrop-blur-xl">
              <div className="flex h-16 items-center justify-between px-4 sm:px-6 lg:px-8">
                <div className="flex items-center gap-3 lg:hidden">
                  <span className="grid size-9 place-items-center rounded-xl bg-primary text-primary-foreground">
                    <FlaskConical className="size-4" />
                  </span>
                  <span className="text-sm font-semibold">Silent Regression</span>
                </div>
                <div className="hidden items-center gap-2 text-sm text-muted-foreground lg:flex">
                  <Activity className="size-4 text-primary" />
                  Product foundation
                </div>
                <Badge variant="secondary" className="rounded-full px-3 py-1">
                  {releaseStage}
                </Badge>
              </div>
            </header>

            <main id="product-content" className="px-4 py-8 sm:px-6 lg:px-8 lg:py-10">
              {children}
            </main>
          </div>
        </div>
      </div>
    </TooltipProvider>
  )
}
