import { Link } from "@inertiajs/react"
import type { PropsWithChildren } from "react"
import {
  Activity,
  BellRing,
  Check,
  ChevronsUpDown,
  FlaskConical,
  KeyRound,
  LogOut,
  LayoutDashboard,
  Settings2,
  ShieldCheck,
  UserRound,
} from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip"
import { cn } from "@/lib/utils"

type ProductShellProps = PropsWithChildren<{
  currentSection?: "overview" | "credentials" | "monitors" | "alerts"
  releaseStage: string
  userEmail: string
  workspace: { name: string; slug: string }
  membershipRole: "owner" | "member"
  availableWorkspaces?: Array<{
    id: string
    name: string
    slug: string
    role: "owner" | "member"
    current: boolean
  }>
}>

export function ProductShell({
  children,
  availableWorkspaces = [],
  currentSection = "overview",
  membershipRole,
  releaseStage,
  userEmail,
  workspace,
}: ProductShellProps) {
  const navigation = [
    {
      label: "Overview",
      icon: LayoutDashboard,
      href: `/app/${workspace.slug}`,
      current: currentSection === "overview",
    },
    {
      label: "Credentials",
      icon: KeyRound,
      href: `/app/${workspace.slug}/credentials`,
      current: currentSection === "credentials",
    },
    {
      label: "Monitors",
      icon: Activity,
      href: `/app/${workspace.slug}/monitors`,
      current: currentSection === "monitors",
    },
    {
      label: "Alerts",
      icon: BellRing,
      href: `/app/${workspace.slug}/alerts`,
      current: currentSection === "alerts",
    },
  ]

  return (
    <TooltipProvider>
      <div className="min-h-screen bg-background text-foreground">
        <div className="mx-auto flex min-h-screen max-w-[1600px]">
          <aside className="hidden w-64 shrink-0 flex-col border-r border-sidebar-border bg-sidebar px-4 py-5 lg:flex">
            <Link
              id="product-brand"
              href={`/app/${workspace.slug}`}
              className="flex items-center gap-3 rounded-xl px-2 py-1.5 transition-colors hover:bg-sidebar-accent"
            >
              <span className="grid size-9 place-items-center rounded-xl bg-sidebar-primary text-sidebar-primary-foreground shadow-sm">
                <span className="size-2.5 rounded-full bg-current" />
              </span>
              <span>
                <span className="block text-sm font-semibold tracking-tight text-sidebar-foreground">
                  Silent Regression
                </span>
                <span className="block text-xs text-sidebar-foreground/60">
                  Deterministic monitoring
                </span>
              </span>
            </Link>

            <WorkspaceSwitcher
              availableWorkspaces={availableWorkspaces}
              workspace={workspace}
            />

            <nav id="product-navigation" className="mt-5 space-y-1" aria-label="Product">
              {navigation.map(item => {
                const Icon = item.icon

                return (
                  <Tooltip key={item.label}>
                    <TooltipTrigger asChild>
                      {item.href ? (
                        <Button
                          asChild
                          variant="ghost"
                          className={cn(
                            "h-10 w-full justify-start rounded-lg px-3 text-sidebar-foreground",
                            item.current &&
                              "bg-sidebar-accent text-sidebar-accent-foreground shadow-xs",
                          )}
                        >
                          <Link
                            href={item.href}
                            aria-current={item.current ? "page" : undefined}
                          >
                            <Icon />
                            {item.label}
                          </Link>
                        </Button>
                      ) : (
                        <Button
                          type="button"
                          variant="ghost"
                          disabled
                          className="h-10 w-full justify-start rounded-lg px-3 text-sidebar-foreground"
                        >
                          <Icon />
                          {item.label}
                        </Button>
                      )}
                    </TooltipTrigger>
                    {!item.href && (
                      <TooltipContent side="right">Available in a later task</TooltipContent>
                    )}
                  </Tooltip>
                )
              })}
            </nav>

            <div className="mt-8 rounded-xl border border-sidebar-border bg-sidebar-accent/60 p-4">
              <div className="flex items-center gap-2 text-sm font-medium text-sidebar-foreground">
                <ShieldCheck className="size-4 text-primary" />
                Private by design
              </div>
              <p className="mt-2 text-xs leading-5 text-sidebar-foreground/65">
                Provider credentials and captured outputs stay inside each workspace boundary.
              </p>
            </div>

            <div className="mt-auto border-t border-sidebar-border pt-5">
              <p className="truncate px-2 text-xs font-medium text-sidebar-foreground">
                {userEmail}
              </p>
              <p className="mt-1 px-2 text-xs capitalize text-sidebar-foreground/55">
                {membershipRole}
              </p>
              <div className="mt-3 grid gap-1">
                <Button asChild variant="ghost" className="h-9 justify-start px-2 text-sidebar-foreground">
                  <Link href="/users/settings">
                    <Settings2 /> Account settings
                  </Link>
                </Button>
                <Button asChild variant="ghost" className="h-9 justify-start px-2 text-sidebar-foreground">
                  <Link href="/users/log-out" method="delete" as="button">
                    <LogOut /> Log out
                  </Link>
                </Button>
              </div>
            </div>
          </aside>

          <div className="min-w-0 flex-1">
            <header className="sticky top-0 z-20 border-b border-border/80 bg-background/90 backdrop-blur-xl">
              <div className="flex h-16 items-center justify-between px-4 sm:px-6 lg:px-8">
                <div className="flex items-center gap-3 lg:hidden">
                  <span className="grid size-9 place-items-center rounded-xl bg-primary text-primary-foreground">
                    <FlaskConical className="size-4" />
                  </span>
                  <span className="min-w-0">
                    <span className="block truncate text-sm font-semibold">{workspace.name}</span>
                    <span className="block truncate text-xs text-muted-foreground">{userEmail}</span>
                  </span>
                </div>
                <div className="hidden items-center gap-2 text-sm text-muted-foreground lg:flex">
                  <Activity className="size-4 text-primary" />
                  {workspace.name}
                </div>
                <div className="flex items-center gap-2">
                  <Badge variant="secondary" className="rounded-full px-3 py-1">
                    {releaseStage}
                  </Badge>
                  <MobileAccountMenu
                    availableWorkspaces={availableWorkspaces}
                    userEmail={userEmail}
                    workspace={workspace}
                  />
                </div>
              </div>
              <nav
                id="mobile-product-navigation"
                className="flex gap-1 overflow-x-auto border-t border-border/70 px-3 py-2 lg:hidden"
                aria-label="Product"
              >
                {navigation
                  .filter(item => item.href)
                  .map(item => {
                    const Icon = item.icon

                    return (
                      <Button
                        key={item.label}
                        asChild
                        size="sm"
                        variant="ghost"
                        className={cn(
                          "shrink-0",
                          item.current && "bg-accent text-accent-foreground",
                        )}
                      >
                        <Link
                          href={item.href!}
                          aria-current={item.current ? "page" : undefined}
                        >
                          <Icon /> {item.label}
                        </Link>
                      </Button>
                    )
                  })}
              </nav>
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

function MobileAccountMenu({
  availableWorkspaces,
  userEmail,
  workspace,
}: {
  availableWorkspaces: ProductShellProps["availableWorkspaces"]
  userEmail: string
  workspace: { name: string; slug: string }
}) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          id="mobile-account-menu"
          type="button"
          size="icon"
          variant="outline"
          className="lg:hidden"
          aria-label="Open account menu"
        >
          <UserRound />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-64">
        <div className="px-2 py-2">
          <p className="truncate text-sm font-medium">{userEmail}</p>
          <p className="mt-0.5 truncate text-xs text-muted-foreground">{workspace.name}</p>
        </div>
        {availableWorkspaces && availableWorkspaces.length > 1 && (
          <>
            <DropdownMenuSeparator />
            {availableWorkspaces.map(item => (
              <DropdownMenuItem key={item.id} asChild>
                <Link href={`/app/${item.slug}`} className="flex justify-between">
                  <span className="truncate">{item.name}</span>
                  {item.current && <Check className="size-4 text-primary" />}
                </Link>
              </DropdownMenuItem>
            ))}
          </>
        )}
        <DropdownMenuSeparator />
        <DropdownMenuItem asChild>
          <Link href="/users/settings"><Settings2 /> Account settings</Link>
        </DropdownMenuItem>
        <DropdownMenuItem asChild>
          <Link href="/users/log-out" method="delete" as="button"><LogOut /> Log out</Link>
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

function WorkspaceSwitcher({
  availableWorkspaces,
  workspace,
}: {
  availableWorkspaces: Array<{
    id: string
    name: string
    slug: string
    role: "owner" | "member"
    current: boolean
  }>
  workspace: { name: string; slug: string }
}) {
  if (availableWorkspaces.length <= 1) {
    return (
      <div className="mt-5 rounded-lg border border-sidebar-border bg-sidebar-accent/40 px-3 py-2.5">
        <p className="truncate text-sm font-medium text-sidebar-foreground">{workspace.name}</p>
        <p className="mt-0.5 text-xs text-sidebar-foreground/55">Current workspace</p>
      </div>
    )
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          id="workspace-switcher"
          variant="outline"
          className="mt-5 h-auto w-full justify-between border-sidebar-border bg-sidebar-accent/40 px-3 py-2.5 text-sidebar-foreground"
        >
          <span className="min-w-0 text-left">
            <span className="block truncate text-sm font-medium">{workspace.name}</span>
            <span className="block text-xs font-normal text-sidebar-foreground/55">
              Switch workspace
            </span>
          </span>
          <ChevronsUpDown className="size-4 shrink-0" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-56">
        {availableWorkspaces.map(item => (
          <DropdownMenuItem key={item.id} asChild>
            <Link
              href={`/app/${item.slug}`}
              className="flex w-full cursor-pointer items-center justify-between gap-3"
            >
              <span className="min-w-0">
                <span className="block truncate">{item.name}</span>
                <span className="block text-xs capitalize text-muted-foreground">{item.role}</span>
              </span>
              {item.current && <Check className="size-4 shrink-0 text-primary" />}
            </Link>
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
