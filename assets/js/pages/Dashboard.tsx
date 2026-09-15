import { Head, Link, usePage } from "@inertiajs/react"
import {
  ArrowRight,
  CheckCircle2,
  CircleDashed,
  Clock3,
  FlaskConical,
  Plus,
} from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
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

export type MonitorSummary = {
  id: string
  name: string
  description: string | null
  state: string
  setupStatus: "in_progress" | "completed"
  completedSteps: number
  totalSteps: number
  progressPercent: number
  nextStep: "purpose" | "connection" | "prompt" | "cases" | "review"
  updatedAt: string
}

type DashboardProps = {
  auth: SharedPageProps["auth"]
  currentSection: "overview" | "monitors"
  monitors: MonitorSummary[]
  releaseStage: string
  workspace: { name: string; slug: string }
}

export function DashboardView({
  auth,
  currentSection,
  flash = {},
  monitors,
  releaseStage,
  workspace,
}: DashboardProps & { flash?: SharedPageProps["flash"] }) {
  const completedCount = monitors.filter(monitor => monitor.setupStatus === "completed").length
  const inProgressCount = monitors.length - completedCount
  const createPath = `/app/${workspace.slug}/monitors/new`

  return (
    <ProductShell
      availableWorkspaces={auth.workspaces}
      currentSection={currentSection}
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
                Deterministic monitoring
              </Badge>
            </div>
            <h1 className="max-w-3xl text-3xl font-semibold tracking-tight sm:text-4xl">
              {currentSection === "monitors" ? "Monitors" : "Your monitoring workspace"}
            </h1>
            <p className="mt-3 max-w-2xl text-base leading-7 text-muted-foreground">
              Define the prompt, provider configuration, and representative cases that will become
              an immutable monitoring contract. Setup does not call your provider.
            </p>
          </div>

          <Button id="create-monitor-button" asChild className="shrink-0">
            <Link href={createPath}>
              <Plus />
              {monitors.length === 0 ? "Create your first monitor" : "Create monitor"}
            </Link>
          </Button>
        </section>

        {flash.info && (
          <Alert id="monitor-flash" className="border-success/25 bg-success/5">
            <CheckCircle2 />
            <AlertTitle>Monitor updated</AlertTitle>
            <AlertDescription>{flash.info}</AlertDescription>
          </Alert>
        )}

        {flash.error && (
          <Alert id="monitor-error" variant="destructive">
            <AlertTitle>Monitor needs attention</AlertTitle>
            <AlertDescription>{flash.error}</AlertDescription>
          </Alert>
        )}

        {monitors.length === 0 ? (
          <EmptyMonitors createPath={createPath} />
        ) : (
          <>
            <section className="grid gap-4 sm:grid-cols-3" aria-label="Monitor summary">
              <Metric label="Total monitors" value={monitors.length} />
              <Metric label="Setup complete" value={completedCount} />
              <Metric label="Drafts to finish" value={inProgressCount} />
            </section>

            <section id="monitor-list" className="grid gap-5 lg:grid-cols-2">
              {monitors.map(monitor => (
                <MonitorCard key={monitor.id} monitor={monitor} workspaceSlug={workspace.slug} />
              ))}
            </section>
          </>
        )}
      </div>
    </ProductShell>
  )
}

function EmptyMonitors({ createPath }: { createPath: string }) {
  return (
    <Card id="empty-monitors-card" className="overflow-hidden border-dashed bg-card/70">
      <CardContent className="grid gap-8 px-6 py-10 md:grid-cols-[1fr_0.8fr] md:items-center md:px-10 md:py-14">
        <div>
          <span className="grid size-12 place-items-center rounded-2xl bg-primary/10 text-primary">
            <FlaskConical className="size-6" />
          </span>
          <h2 className="mt-5 text-2xl font-semibold tracking-tight">
            Start with one critical workflow
          </h2>
          <p className="mt-3 max-w-xl text-sm leading-6 text-muted-foreground">
            Choose an output your product must keep producing correctly. We will guide you through
            the exact provider, prompt, and frozen cases needed to define it safely.
          </p>
          <Button id="empty-create-monitor-button" asChild className="mt-6">
            <Link href={createPath}>
              Create your first monitor <ArrowRight />
            </Link>
          </Button>
        </div>

        <div className="rounded-2xl border bg-muted/35 p-5">
          <p className="text-sm font-medium">What you will prepare</p>
          <ol className="mt-4 space-y-4 text-sm text-muted-foreground">
            {[
              "A validated provider credential and exact model",
              "The production prompt and configuration",
              "One to twenty representative cases",
            ].map((item, index) => (
              <li key={item} className="flex gap-3">
                <span className="grid size-6 shrink-0 place-items-center rounded-full bg-background text-xs font-semibold text-foreground shadow-xs">
                  {index + 1}
                </span>
                <span className="pt-0.5 leading-5">{item}</span>
              </li>
            ))}
          </ol>
        </div>
      </CardContent>
    </Card>
  )
}

function Metric({ label, value }: { label: string; value: number }) {
  return (
    <Card>
      <CardContent className="p-5">
        <p className="text-sm text-muted-foreground">{label}</p>
        <p className="mt-2 text-3xl font-semibold tracking-tight">{value}</p>
      </CardContent>
    </Card>
  )
}

function MonitorCard({ monitor, workspaceSlug }: { monitor: MonitorSummary; workspaceSlug: string }) {
  const complete = monitor.setupStatus === "completed"
  const baselinePending = monitor.state === "baseline_pending"
  const nextPath = complete
    ? `/app/${workspaceSlug}/monitors/${monitor.id}/${baselinePending ? "baseline" : "contract"}`
    : `/app/${workspaceSlug}/monitors/${monitor.id}/setup`

  return (
    <Card id={`monitor-${monitor.id}`} className="group transition-shadow hover:shadow-md">
      <CardHeader>
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0">
            <CardTitle className="truncate">{monitor.name}</CardTitle>
            <CardDescription className="mt-2 line-clamp-2 min-h-10">
              {monitor.description || "No description added yet."}
            </CardDescription>
          </div>
          <Badge
            variant={complete ? "secondary" : "outline"}
            className={complete ? "bg-success/10 text-success" : "text-primary"}
          >
            {complete ? <CheckCircle2 /> : <Clock3 />}
            {complete ? "Setup complete" : "Draft"}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="space-y-5">
        <div>
          <div className="mb-2 flex items-center justify-between gap-3 text-xs text-muted-foreground">
            <span>
              {monitor.completedSteps} of {monitor.totalSteps} setup steps complete
            </span>
            <span>{monitor.progressPercent}%</span>
          </div>
          <Progress value={monitor.progressPercent} aria-label={`${monitor.name} setup progress`} />
        </div>

        <div className="flex flex-wrap items-center justify-between gap-3 border-t pt-4">
          <span className="flex items-center gap-2 text-xs text-muted-foreground">
            <CircleDashed className="size-3.5" />
            {complete ? baselinePending ? "Baseline capture and approval" : "Ready for contract authoring" : `Next: ${stepLabel(monitor.nextStep)}`}
          </span>
          <Button asChild variant={complete ? "outline" : "default"} size="sm">
            <Link href={nextPath}>
              {complete ? baselinePending ? "Review baseline" : "Define contract" : "Resume setup"} <ArrowRight />
            </Link>
          </Button>
        </div>
      </CardContent>
    </Card>
  )
}

function stepLabel(step: MonitorSummary["nextStep"]) {
  return {
    purpose: "Purpose",
    connection: "Provider and model",
    prompt: "Prompt and configuration",
    cases: "Representative cases",
    review: "Review",
  }[step]
}

export default function Dashboard(props: DashboardProps) {
  const { flash } = usePage<SharedPageProps>().props

  return (
    <>
      <Head title={props.currentSection === "monitors" ? "Monitors" : "Overview"} />
      <DashboardView {...props} flash={flash} />
    </>
  )
}
