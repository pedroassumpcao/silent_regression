import { Head, Link, usePage } from "@inertiajs/react"
import {
  ArrowRight,
  CheckCircle2,
  Circle,
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
  readyToActivate?: boolean
  guidedSetup?: boolean
}

export type ActivationChecklist = {
  completedCount: number
  totalCount: number
  percent: number
  complete: boolean
  monitorId: string | null
  monitorName: string | null
  steps: Array<{
    key: "credential" | "workflow" | "cases" | "contract" | "baseline" | "schedule"
    label: string
    complete: boolean
    href: string
  }>
}

type DashboardProps = {
  activation?: ActivationChecklist
  auth: SharedPageProps["auth"]
  currentSection: "overview" | "monitors"
  monitors: MonitorSummary[]
  guidedDrafts?: Array<{ id: string; name: string; updatedAt: string }>
  releaseStage: string
  workspace: { name: string; slug: string }
}

export function DashboardView({
  activation,
  auth,
  currentSection,
  flash = {},
  monitors,
  guidedDrafts = [],
  releaseStage,
  workspace,
}: DashboardProps & { flash?: SharedPageProps["flash"] }) {
  const completedCount = monitors.filter(monitor => monitor.setupStatus === "completed").length
  const inProgressCount = monitors.length - completedCount + guidedDrafts.length
  const createPath = `/app/${workspace.slug}/setup-drafts/new`
  const demoPath = `/app/${workspace.slug}/demo`

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

          <div className="flex flex-wrap gap-3">
            <Button id="open-guided-demo-button" asChild variant="outline" className="shrink-0">
              <Link href={demoPath}><FlaskConical /> Try the zero-call demo</Link>
            </Button>
            <Button id="create-monitor-button" asChild className="shrink-0">
              <Link href={createPath}>
                <Plus />
                {monitors.length === 0 ? "Create your first monitor" : "Create monitor"}
              </Link>
            </Button>
          </div>
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

        {activation && <ActivationCard activation={activation} />}

        {guidedDrafts.length > 0 && <section aria-label="Saved monitor drafts" className="space-y-3"><h2 className="text-lg font-semibold">Continue a saved setup</h2>{guidedDrafts.map(draft => <Card key={draft.id}><CardContent className="flex flex-wrap items-center justify-between gap-3 pt-5"><div><p className="font-medium">{draft.name || "Untitled monitor"}</p><p className="text-sm text-muted-foreground">Workspace draft · no provider calls yet</p></div><Button asChild variant="outline"><Link href={`/app/${workspace.slug}/setup-drafts/${draft.id}`}>Resume setup <ArrowRight /></Link></Button></CardContent></Card>)}</section>}

        {monitors.length === 0 ? (
          <EmptyMonitors createPath={createPath} demoPath={demoPath} />
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

function ActivationCard({ activation }: { activation: ActivationChecklist }) {
  const nextStep = activation.steps.find(step => !step.complete)

  return (
    <Card id="activation-checklist" className="overflow-hidden border-primary/15 bg-card/80">
      <CardHeader className="gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <Badge variant="outline" className="mb-3 rounded-full border-primary/25 text-primary">
            Private-alpha activation
          </Badge>
          <CardTitle>
            {activation.complete ? "Your monitoring loop is active" : "Complete the monitoring loop"}
          </CardTitle>
          <CardDescription className="mt-2 max-w-2xl leading-6">
            This checklist is derived from durable workspace evidence. It updates automatically if
            a credential is revoked, a reviewed reference becomes incompatible, or monitoring is paused.
          </CardDescription>
        </div>
        <div className="min-w-40">
          <div className="mb-2 flex justify-between text-xs text-muted-foreground">
            <span>{activation.completedCount} of {activation.totalCount}</span>
            <span>{activation.percent}%</span>
          </div>
          <Progress value={activation.percent} aria-label="Private-alpha activation progress" />
        </div>
      </CardHeader>
      <CardContent>
        <ol className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {activation.steps.map((step, index) => (
            <li key={step.key}>
              <Link
                href={step.href}
                className="flex min-h-20 items-center gap-3 rounded-xl border bg-background/70 p-4 transition-colors hover:border-primary/30 hover:bg-primary/[0.03]"
              >
                <span className={step.complete ? "text-success" : "text-muted-foreground"}>
                  {step.complete ? <CheckCircle2 className="size-5" /> : <Circle className="size-5" />}
                </span>
                <span className="min-w-0">
                  <span className="block text-xs font-medium uppercase tracking-wide text-muted-foreground">
                    Step {index + 1}
                  </span>
                  <span className="mt-1 block text-sm font-medium">{step.label}</span>
                </span>
              </Link>
            </li>
          ))}
        </ol>

        {nextStep && (
          <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t pt-5">
            <p className="text-sm text-muted-foreground">
              Next for {activation.monitorName || "this workspace"}: {nextStep.label}
            </p>
            <Button asChild size="sm">
              <Link href={nextStep.href}>Continue activation <ArrowRight /></Link>
            </Button>
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function EmptyMonitors({ createPath, demoPath }: { createPath: string; demoPath: string }) {
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
          <div className="mt-6 flex flex-wrap gap-3">
            <Button id="empty-demo-button" asChild variant="outline"><Link href={demoPath}>Try the zero-call demo</Link></Button>
            <Button id="empty-create-monitor-button" asChild><Link href={createPath}>Create your first monitor <ArrowRight /></Link></Button>
          </div>
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
  const operational = monitor.state === "active" || monitor.state === "paused" || monitor.readyToActivate
  const guidedPending = monitor.guidedSetup && monitor.state !== "active" && monitor.state !== "paused"
  const resultsAvailable = monitor.state === "active" || monitor.state === "paused" || baselinePending
  const resultsPath = `/app/${workspaceSlug}/monitors/${monitor.id}/results`
  const nextPath = complete
    ? `/app/${workspaceSlug}/monitors/${monitor.id}/${guidedPending ? "first-run" : operational ? "operations" : baselinePending ? "baseline" : "contract"}`
    : `/app/${workspaceSlug}/monitors/${monitor.id}/setup`
  const operationalLabel = monitor.state === "active" ? "Active monitoring" : monitor.state === "paused" ? "Monitoring paused" : "Ready to activate"
  const completeDetail = guidedPending ? "Continue to your first reviewed result" : operational ? operationalLabel : baselinePending ? "Reviewed reference capture and approval" : "Ready for contract authoring"
  const completeAction = guidedPending ? "Continue setup" : operational ? monitor.state === "baseline_pending" ? "Activate monitor" : "Manage monitor" : baselinePending ? "Review reference" : "Define contract"

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
            {complete ? guidedPending ? "First run pending" : "Setup complete" : "Draft"}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="space-y-5">
        {guidedPending ? <p className="text-sm text-muted-foreground">Configuration saved. Review your first capture and finish setup to enable on-demand checks.</p> : <div>
          <div className="mb-2 flex items-center justify-between gap-3 text-xs text-muted-foreground">
            <span>
              {monitor.completedSteps} of {monitor.totalSteps} setup steps complete
            </span>
            <span>{monitor.progressPercent}%</span>
          </div>
          <Progress value={monitor.progressPercent} aria-label={`${monitor.name} setup progress`} />
        </div>}

        <div className="flex flex-wrap items-center justify-between gap-3 border-t pt-4">
          <span className="flex items-center gap-2 text-xs text-muted-foreground">
            <CircleDashed className="size-3.5" />
            {complete ? completeDetail : `Next: ${stepLabel(monitor.nextStep)}`}
          </span>
          <div className="flex flex-wrap gap-2">
            {resultsAvailable && <Button asChild variant="ghost" size="sm"><Link href={resultsPath}>Results</Link></Button>}
            <Button asChild variant={complete ? "outline" : "default"} size="sm">
              <Link href={nextPath}>
                {complete ? completeAction : "Resume setup"} <ArrowRight />
              </Link>
            </Button>
          </div>
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
