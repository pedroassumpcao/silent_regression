import { Head, Link } from "@inertiajs/react"
import { ArrowRight, Check, CircleDashed, FlaskConical, Plus } from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Progress } from "@/components/ui/progress"
import type { SharedPageProps } from "@/types/page"

type DashboardProps = {
  releaseStage: string
  foundationStatus: string
  workspace: { name: string; slug: string }
  auth: SharedPageProps["auth"]
}

const foundationChecks = [
  "Phoenix and Inertia request boundary",
  "React and TypeScript application entrypoint",
  "Tailwind v4 tokens and shadcn component system",
]

export function DashboardView({ auth, foundationStatus, releaseStage, workspace }: DashboardProps) {
  return (
    <ProductShell
      releaseStage={releaseStage}
      userEmail={auth.user?.email || "Invited user"}
      workspace={workspace}
      membershipRole={auth.membership?.role || "member"}
    >
      <div className="mx-auto max-w-6xl space-y-8">
        <section className="flex flex-col justify-between gap-5 sm:flex-row sm:items-end">
          <div>
            <div className="mb-3 flex items-center gap-2">
              <Badge variant="outline" className="rounded-full border-primary/25 text-primary">
                Foundation smoke page
              </Badge>
            </div>
            <h1 className="max-w-3xl text-3xl font-semibold tracking-tight sm:text-4xl">
              Catch silent LLM regressions before your users do.
            </h1>
            <p className="mt-3 max-w-2xl text-base leading-7 text-muted-foreground">
              The product shell is ready. Monitor creation, baseline capture, and scheduled
              deterministic checks will arrive in the numbered tasks that follow.
            </p>
          </div>

          <Button id="create-monitor-button" type="button" disabled className="shrink-0">
            <Plus />
            Create monitor
          </Button>
        </section>

        <section className="grid gap-5 lg:grid-cols-[1.35fr_0.65fr]">
          <Card id="foundation-status-card" className="overflow-hidden border-primary/15">
            <CardHeader className="border-b bg-muted/35">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <CardTitle className="flex items-center gap-2">
                    <span className="grid size-8 place-items-center rounded-lg bg-success/10 text-success">
                      <Check className="size-4" />
                    </span>
                    {foundationStatus}
                  </CardTitle>
                  <CardDescription className="mt-2">
                    The shared web foundation is connected end to end.
                  </CardDescription>
                </div>
                <Badge className="bg-success text-success-foreground hover:bg-success">
                  Healthy
                </Badge>
              </div>
            </CardHeader>
            <CardContent className="space-y-5 pt-6">
              <Progress value={100} aria-label="Foundation progress" />
              <ul className="space-y-3" aria-label="Completed foundation checks">
                {foundationChecks.map(check => (
                  <li key={check} className="flex items-center gap-3 text-sm">
                    <span className="grid size-6 place-items-center rounded-full bg-success/10 text-success">
                      <Check className="size-3.5" />
                    </span>
                    {check}
                  </li>
                ))}
              </ul>
            </CardContent>
          </Card>

          <Card id="next-task-card">
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <CircleDashed className="size-5 text-primary" />
                Up next
              </CardTitle>
              <CardDescription>Task 4 of the private-alpha plan</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="rounded-xl border border-dashed border-border bg-muted/35 p-4">
                <FlaskConical className="size-5 text-primary" />
                <p className="mt-3 text-sm font-medium">Encrypted provider credentials</p>
                <p className="mt-1 text-sm leading-6 text-muted-foreground">
                  Securely store and validate OpenAI or Anthropic credentials inside this workspace.
                </p>
              </div>
              <Link
                href="/security"
                className="mt-4 inline-flex items-center gap-2 text-sm font-medium text-primary transition-colors hover:text-primary/80"
              >
                Review the security boundary
                <ArrowRight className="size-4" />
              </Link>
            </CardContent>
          </Card>
        </section>

        <Card id="empty-monitors-card" className="border-dashed bg-card/60">
          <CardContent className="flex flex-col items-center px-6 py-12 text-center">
            <span className="grid size-12 place-items-center rounded-2xl bg-primary/10 text-primary">
              <FlaskConical className="size-6" />
            </span>
            <h2 className="mt-4 text-lg font-semibold">No monitors yet</h2>
            <p className="mt-2 max-w-md text-sm leading-6 text-muted-foreground">
              This is intentionally an honest empty state. The persisted cold-start workflow is
              scheduled for Task 6 after accounts, credentials, and the monitor domain exist.
            </p>
          </CardContent>
        </Card>
      </div>
    </ProductShell>
  )
}

export default function Dashboard(props: DashboardProps) {
  return (
    <>
      <Head title="Product foundation" />
      <DashboardView {...props} />
    </>
  )
}
