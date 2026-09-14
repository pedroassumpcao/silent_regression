import type { PropsWithChildren, ReactNode } from "react"
import { Link, usePage } from "@inertiajs/react"
import { FlaskConical, ShieldCheck } from "lucide-react"

import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import type { SharedPageProps } from "@/types/page"

type AuthShellProps = PropsWithChildren<{
  eyebrow: string
  title: string
  description: string
  aside?: ReactNode
}>

export function AuthShell({ children, eyebrow, title, description, aside }: AuthShellProps) {
  const { flash } = usePage<SharedPageProps>().props

  return (
    <div className="min-h-screen bg-background text-foreground">
      <header className="border-b border-border/75 bg-background/90">
        <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6 lg:px-8">
          <Link href="/" className="inline-flex items-center gap-3 font-semibold tracking-tight">
            <span className="grid size-9 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm shadow-primary/20">
              <span className="size-2.5 rounded-full bg-current" />
            </span>
            Silent Regression
          </Link>
          <span className="hidden items-center gap-2 text-xs font-medium text-muted-foreground sm:inline-flex">
            <ShieldCheck className="size-4 text-success" /> Invite-only private alpha
          </span>
        </div>
      </header>

      <main className="relative overflow-hidden">
        <div className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[34rem] bg-gradient-to-b from-primary/10 to-transparent" />
        <div className="mx-auto grid min-h-[calc(100vh-4rem)] max-w-6xl gap-12 px-4 py-14 sm:px-6 sm:py-20 lg:grid-cols-[0.9fr_1.1fr] lg:items-center lg:px-8">
          <section>
            <span className="inline-flex items-center gap-2 rounded-full border border-primary/20 bg-primary/5 px-3 py-1.5 text-xs font-semibold text-primary">
              <FlaskConical className="size-4" /> {eyebrow}
            </span>
            <h1 className="mt-6 max-w-xl text-4xl font-semibold tracking-[-0.04em] sm:text-5xl">
              {title}
            </h1>
            <p className="mt-5 max-w-xl text-base leading-7 text-muted-foreground">
              {description}
            </p>
            {aside}
          </section>

          <section className="rounded-2xl border border-border bg-card p-6 shadow-xl shadow-slate-950/5 sm:p-8">
            {flash.info && (
              <Alert className="mb-6 border-success/25 bg-success/5">
                <AlertTitle>Update</AlertTitle>
                <AlertDescription>{flash.info}</AlertDescription>
              </Alert>
            )}
            {flash.error && (
              <Alert variant="destructive" className="mb-6">
                <AlertTitle>Unable to continue</AlertTitle>
                <AlertDescription>{flash.error}</AlertDescription>
              </Alert>
            )}
            {children}
          </section>
        </div>
      </main>
    </div>
  )
}
