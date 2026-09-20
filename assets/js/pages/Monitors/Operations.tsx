import { useState, type ReactNode } from "react"
import { Head, Link, router, usePage } from "@inertiajs/react"
import {
  Activity,
  AlertTriangle,
  ArrowLeft,
  CalendarClock,
  CheckCircle2,
  CirclePause,
  Clock3,
  Gauge,
  KeyRound,
  LoaderCircle,
  Play,
  RefreshCw,
  ShieldAlert,
  ShieldCheck,
  Sparkles,
} from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog"
import { Progress } from "@/components/ui/progress"
import type { SharedPageProps } from "@/types/page"

type Cadence = "manual" | "daily" | "weekly"
type MonitorState = "baseline_pending" | "active" | "paused"
type AuthenticationRecoveryStatus = "ready" | "in_progress" | "succeeded" | "failed"

type AuthenticationRecovery = {
  required: boolean
  status: AuthenticationRecoveryStatus | null
  trippedAt: string | null
  epoch: number | null
  authorizedAt: string | null
  credentialValidatedAt: string | null
  captureRunId: string | null
  probeStatus: string | null
  failureCategory: string | null
  validationCallCount: number
  maximumCallCount: number
  retryLimit: number
}

type LastRun = {
  id: string
  kind: "manual" | "scheduled"
  status: string
  plannedCallCount: number
  maximumCallCount: number
  startedAt: string | null
  completedAt: string | null
  insertedAt: string
}

export type OperationsProps = {
  auth: SharedPageProps["auth"]
  approvedBaseline: boolean
  authenticationRecovery: AuthenticationRecovery
  canManage: boolean
  lastRun: LastRun | null
  monitor: {
    id: string
    name: string
    description: string | null
    state: MonitorState
    cadence: Cadence
    nextRunAt: string | null
    lastScheduledAt: string | null
    scheduleUpdatedAt: string | null
    scheduleUpdatedBy: string | null
    pauseReason: string | null
    provider: "openai" | "anthropic" | null
    requestedModel: string | null
    version: number | null
  }
  releaseStage: string
  unresolvedAlerts: number
  spend: {
    caseCount: number
    maximumCallCount: number
    perRunCallLimit: number
    workspaceCallLimit: number
    workspaceCommittedCallsToday: number
    workspaceRemainingCallsToday: number
    workspaceRunLimit: number
    workspaceRunsToday: number
    workspaceRemainingRunsToday: number
    resetsAt: string
  }
}

export function OperationsView({
  approvedBaseline,
  authenticationRecovery,
  auth,
  canManage,
  flash = {},
  lastRun,
  monitor,
  releaseStage,
  unresolvedAlerts,
  spend,
}: OperationsProps & { flash?: SharedPageProps["flash"] }) {
  const workspace = auth.workspace
  const [cadence, setCadence] = useState<Cadence>(monitor.cadence)
  const [processing, setProcessing] = useState<string | null>(null)
  const [runDialogOpen, setRunDialogOpen] = useState(false)
  const [recoveryDialogOpen, setRecoveryDialogOpen] = useState(false)

  if (!workspace) return null

  const path = `/app/${workspace.slug}/monitors/${monitor.id}/operations`
  const baselinePath = `/app/${workspace.slug}/monitors/${monitor.id}/baseline`
  const credentialsPath = `/app/${workspace.slug}/credentials`
  const dashboardPath = `/app/${workspace.slug}/monitors`
  const resultsPath = `/app/${workspace.slug}/monitors/${monitor.id}/results`
  const active = monitor.state === "active"
  const paused = monitor.state === "paused"
  const pendingActivation = monitor.state === "baseline_pending"
  const authenticationPause = paused && monitor.pauseReason === "repeated_authentication_failures"
  const recoveryBlocksResume = authenticationPause && authenticationRecovery.status !== "succeeded"

  const mutate = (name: string, url: string) => {
    setProcessing(name)
    router.post(url, {}, { preserveScroll: true, onFinish: () => setProcessing(null) })
  }

  const saveSchedule = () => {
    setProcessing("schedule")
    router.patch(
      `${path}/schedule`,
      { schedule: { cadence } },
      { preserveScroll: true, onFinish: () => setProcessing(null) },
    )
  }

  const runNow = () => {
    setProcessing("run")
    router.post(`${path}/run-now`, {}, {
      preserveScroll: true,
      onSuccess: () => setRunDialogOpen(false),
      onFinish: () => setProcessing(null),
    })
  }

  const authorizeRecovery = () => {
    setProcessing("authentication-recovery")
    router.post(`${path}/authentication-recovery`, {}, {
      preserveScroll: true,
      onSuccess: () => setRecoveryDialogOpen(false),
      onFinish: () => setProcessing(null),
    })
  }

  const refreshRecovery = () => {
    setProcessing("authentication-recovery-refresh")
    router.reload({
      only: ["authenticationRecovery", "monitor"],
      onFinish: () => setProcessing(null),
    })
  }

  return (
    <ProductShell
      availableWorkspaces={auth.workspaces}
      currentSection="monitors"
      membershipRole={auth.membership?.role || "member"}
      releaseStage={releaseStage}
      userEmail={auth.user?.email || "Invited user"}
      workspace={workspace}
    >
      <div className="mx-auto max-w-7xl space-y-7">
        <header className="space-y-5">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <Button asChild variant="ghost" className="-ml-3">
              <Link href={dashboardPath}><ArrowLeft /> Back to monitors</Link>
            </Button>
            <div className="flex flex-wrap items-center gap-2">
              <Badge variant="outline">Configuration v{monitor.version || "—"}</Badge>
              <StateBadge state={monitor.state} />
            </div>
          </div>

          <div className="grid gap-5 lg:grid-cols-[1fr_auto] lg:items-end">
            <div className="max-w-3xl">
              <p className="text-sm font-medium text-primary">{monitor.name}</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
                Operate the monitor without hidden spend
              </h1>
              <p className="mt-3 text-base leading-7 text-muted-foreground">
                Run the approved behavior on demand or on a small UTC cadence. Every window uses the
                same frozen capture path, exact model, and provider-call ceiling.
              </p>
            </div>
            <div className="flex flex-col gap-3 rounded-2xl border bg-card/70 px-5 py-4 text-sm shadow-xs sm:flex-row sm:items-center">
              <div>
                <p className="text-xs text-muted-foreground">Protected target</p>
                <p className="mt-1 font-medium capitalize">{monitor.provider || "Provider"} · {monitor.requestedModel || "Model unavailable"}</p>
              </div>
              <Button asChild variant="outline" size="sm">
                <Link href={resultsPath}>View results</Link>
              </Button>
            </div>
          </div>
        </header>

        {flash.info && (
          <Alert id="operations-success" className="border-success/25 bg-success/5">
            <CheckCircle2 />
            <AlertTitle>Operations updated</AlertTitle>
            <AlertDescription>{flash.info}</AlertDescription>
          </Alert>
        )}

        {flash.error && (
          <Alert id="operations-error" variant="destructive">
            <AlertTriangle />
            <AlertTitle>Monitor needs attention</AlertTitle>
            <AlertDescription>{flash.error}</AlertDescription>
          </Alert>
        )}

        {!approvedBaseline && (
          <Alert id="operations-baseline-required" variant="destructive">
            <ShieldCheck />
            <AlertTitle>A compatible approved baseline is required</AlertTitle>
            <AlertDescription>
              The behavior changed or approval is incomplete. <Link className="font-medium underline underline-offset-4" href={baselinePath}>Review the baseline</Link> before authorizing runs.
            </AlertDescription>
          </Alert>
        )}

        {authenticationRecovery.status && (
          <Card
            id="authentication-recovery-card"
            className={authenticationRecovery.status === "succeeded" ? "border-success/30 bg-success/5" : "border-amber-500/30 bg-amber-500/5"}
          >
            <CardHeader>
              <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                <div className="flex gap-3">
                  <span className={`mt-0.5 flex size-10 shrink-0 items-center justify-center rounded-xl ${authenticationRecovery.status === "succeeded" ? "bg-success/10 text-success" : "bg-amber-500/10 text-amber-700"}`}>
                    {authenticationRecovery.status === "succeeded" ? <ShieldCheck className="size-5" /> : <ShieldAlert className="size-5" />}
                  </span>
                  <div>
                    <CardTitle role="heading" aria-level={2} className="text-xl">{recoveryTitle(authenticationRecovery.status)}</CardTitle>
                    <CardDescription className="mt-2 max-w-3xl leading-6">
                      {recoveryDescription(authenticationRecovery.status, authenticationRecovery.failureCategory)}
                    </CardDescription>
                  </div>
                </div>
                <Badge variant="outline" className="w-fit bg-background/70">
                  {authenticationRecovery.status === "succeeded" ? "Recovery verified" : "Provider calls paused"}
                </Badge>
              </div>
            </CardHeader>
            <CardContent className="space-y-5">
              <div className="grid gap-3 sm:grid-cols-3">
                <RecoveryLimit label="Access validation" value={`${authenticationRecovery.validationCallCount} metadata request`} />
                <RecoveryLimit label="Completion probe" value={`${authenticationRecovery.maximumCallCount} call maximum`} />
                <RecoveryLimit label="Automatic retries" value={String(authenticationRecovery.retryLimit)} />
              </div>

              {authenticationRecovery.status === "in_progress" && (
                <div className="flex flex-col gap-3 rounded-xl border bg-background/70 p-4 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <p className="font-medium">The single probe is queued or running</p>
                    <p className="mt-1 text-sm text-muted-foreground">The monitor stays paused. Refresh after the worker finishes; no additional completion call will be retried automatically.</p>
                  </div>
                  <Button id="refresh-authentication-recovery" variant="outline" disabled={processing !== null} onClick={refreshRecovery}>
                    {processing === "authentication-recovery-refresh" ? <LoaderCircle className="animate-spin" /> : <RefreshCw />} Refresh status
                  </Button>
                </div>
              )}

              {authenticationRecovery.status === "succeeded" && (
                <Alert className="border-success/25 bg-background/70">
                  <CheckCircle2 className="text-success" />
                  <AlertTitle>Exact-model access and one completion succeeded</AlertTitle>
                  <AlertDescription>The breaker is cleared, but monitoring has not restarted. Review the evidence, then use Resume monitor below when you are ready to restore the schedule.</AlertDescription>
                </Alert>
              )}

              {(authenticationRecovery.status === "ready" || authenticationRecovery.status === "failed") && (
                <div className="flex flex-col gap-3 rounded-xl border bg-background/70 p-4 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <p className="font-medium">{canManage ? "Owner authorization required" : "A workspace owner must authorize recovery"}</p>
                    <p className="mt-1 text-sm text-muted-foreground">Validation sends no prompt or case content. A completion probe is queued only when the credential can access {monitor.requestedModel || "the exact configured model"}.</p>
                  </div>
                  <Dialog open={recoveryDialogOpen} onOpenChange={setRecoveryDialogOpen}>
                    <DialogTrigger asChild>
                      <Button id="authorize-authentication-recovery" disabled={!canManage || processing !== null || !approvedBaseline}>
                        <ShieldCheck /> {authenticationRecovery.status === "failed" ? "Retry recovery" : "Start recovery"}
                      </Button>
                    </DialogTrigger>
                    <DialogContent>
                      <DialogHeader>
                        <DialogTitle>Authorize bounded authentication recovery?</DialogTitle>
                        <DialogDescription>
                          First, Silent Regression makes one content-free request to verify this credential can access the exact configured model. Only after that succeeds will it queue one completion probe.
                        </DialogDescription>
                      </DialogHeader>
                      <div className="grid gap-3 py-2 sm:grid-cols-3">
                        <RecoveryLimit label="Validation" value="1 request" />
                        <RecoveryLimit label="Completion" value="1 maximum" />
                        <RecoveryLimit label="Retries" value="0" />
                      </div>
                      <Alert>
                        <CirclePause />
                        <AlertTitle>Resume remains manual</AlertTitle>
                        <AlertDescription>Even a successful probe leaves the monitor paused until an owner explicitly resumes it.</AlertDescription>
                      </Alert>
                      <DialogFooter>
                        <DialogClose asChild><Button variant="outline">Cancel</Button></DialogClose>
                        <Button id="confirm-authentication-recovery" disabled={processing !== null} onClick={authorizeRecovery}>
                          {processing === "authentication-recovery" ? <LoaderCircle className="animate-spin" /> : <ShieldCheck />} Validate and run one probe
                        </Button>
                      </DialogFooter>
                    </DialogContent>
                  </Dialog>
                </div>
              )}

              {authenticationRecovery.trippedAt && (
                <p className="text-xs text-muted-foreground">Breaker opened {formatUtc(authenticationRecovery.trippedAt)}. Recovery evidence is stored as a new immutable epoch; earlier failures remain in history.</p>
              )}
            </CardContent>
          </Card>
        )}

        <section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4" aria-label="Monitor status">
          <MetricCard icon={Activity} label="Monitor state" value={stateLabel(monitor.state)} detail={paused ? pauseReason(monitor.pauseReason) : cadenceLabel(monitor.cadence)} />
          <MetricCard icon={Clock3} label="Last run" value={lastRun ? statusLabel(lastRun.status) : "No managed run"} detail={lastRun ? formatUtc(lastRun.completedAt || lastRun.insertedAt) : "Activate or run on demand"} />
          <MetricCard icon={CalendarClock} label="Next UTC run" value={monitor.nextRunAt ? formatUtc(monitor.nextRunAt) : "Not scheduled"} detail={monitor.cadence === "manual" ? "Run now only" : cadenceLabel(monitor.cadence)} />
          <MetricCard icon={unresolvedAlerts > 0 ? AlertTriangle : ShieldCheck} label="Unresolved alerts" value={unresolvedAlerts} detail={unresolvedAlerts > 0 ? <Link className="underline underline-offset-4" href={resultsPath}>Inspect the evidence and alert lifecycle</Link> : "No open or acknowledged alerts"} tone={unresolvedAlerts > 0 ? "warning" : "success"} />
        </section>

        <div className="grid gap-6 lg:grid-cols-[1.15fr_0.85fr]">
          <Card id="schedule-card" className={active ? "border-primary/25 shadow-sm" : ""}>
            <CardHeader>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <p className="text-sm font-medium text-primary">Continuous monitoring</p>
                  <CardTitle className="mt-1 text-2xl">Choose the smallest useful cadence</CardTitle>
                  <CardDescription className="mt-2 max-w-2xl leading-6">
                    Daily and weekly are anchored in UTC when saved. If the dispatcher is delayed, it runs one window and advances past missed slots without a catch-up burst.
                  </CardDescription>
                </div>
                {monitor.scheduleUpdatedBy && <Badge variant="outline"><KeyRound /> Owner authorized</Badge>}
              </div>
            </CardHeader>
            <CardContent className="space-y-6">
              {paused && (
                <Alert className="border-amber-500/25 bg-amber-500/5">
                  <CirclePause className="text-amber-600" />
                  <AlertTitle>Provider calls are paused</AlertTitle>
                  <AlertDescription>{pauseReason(monitor.pauseReason)} Resume only after the cause is understood.</AlertDescription>
                </Alert>
              )}

              <div className="grid gap-3 sm:grid-cols-3">
                {(["manual", "daily", "weekly"] as Cadence[]).map(option => (
                  <button
                    key={option}
                    type="button"
                    disabled={!canManage || paused}
                    onClick={() => setCadence(option)}
                    className={`rounded-2xl border p-4 text-left transition-all disabled:cursor-not-allowed disabled:opacity-60 ${cadence === option ? "border-primary bg-primary/5 shadow-sm ring-1 ring-primary/20" : "bg-background hover:border-primary/35 hover:bg-muted/30"}`}
                    aria-pressed={cadence === option}
                  >
                    <span className="flex items-center justify-between gap-3 font-medium capitalize">
                      {option}
                      {cadence === option && <CheckCircle2 className="size-4 text-primary" />}
                    </span>
                    <span className="mt-2 block text-xs leading-5 text-muted-foreground">{cadenceDescription(option)}</span>
                  </button>
                ))}
              </div>

              <div className="flex flex-col gap-4 border-t pt-5 sm:flex-row sm:items-center sm:justify-between">
                <div className="text-sm text-muted-foreground">
                  <p>{canManage ? "Only owners can authorize schedule changes and provider spend." : "You can inspect operations; a workspace owner controls spend."}</p>
                  {monitor.scheduleUpdatedAt && <p className="mt-1 text-xs">Last schedule decision {formatUtc(monitor.scheduleUpdatedAt)}{monitor.scheduleUpdatedBy ? ` by ${monitor.scheduleUpdatedBy}` : ""}.</p>}
                </div>
                <div className="flex flex-col gap-2 sm:flex-row">
                  {paused ? (
                    <Button id="resume-monitor" disabled={!canManage || processing !== null || !approvedBaseline || recoveryBlocksResume} onClick={() => mutate("resume", `${path}/resume`)}>
                      {processing === "resume" ? <LoaderCircle className="animate-spin" /> : <RefreshCw />} Resume monitor
                    </Button>
                  ) : (
                    <>
                      {active && (
                        <Button id="pause-monitor" variant="outline" disabled={!canManage || processing !== null} onClick={() => mutate("pause", `${path}/pause`)}>
                          {processing === "pause" ? <LoaderCircle className="animate-spin" /> : <CirclePause />} Pause
                        </Button>
                      )}
                      <Button id="save-schedule" disabled={!canManage || processing !== null || !approvedBaseline} onClick={saveSchedule}>
                        {processing === "schedule" ? <LoaderCircle className="animate-spin" /> : pendingActivation ? <Sparkles /> : <CalendarClock />}
                        {pendingActivation ? "Activate monitor" : "Save cadence"}
                      </Button>
                    </>
                  )}
                </div>
              </div>
              {recoveryBlocksResume && <p className="text-xs text-amber-700">Resume unlocks only after the bounded authentication probe succeeds.</p>}
            </CardContent>
          </Card>

          <div className="space-y-6">
            <Card id="run-now-card">
              <CardHeader>
                <p className="text-sm font-medium text-primary">On-demand verification</p>
                <CardTitle className="mt-1 text-2xl">Run the approved cases now</CardTitle>
                <CardDescription className="leading-6">One sample per active case, with one bounded retry. The exact maximum is confirmed before queueing.</CardDescription>
              </CardHeader>
              <CardContent className="space-y-5">
                <div className="grid grid-cols-2 gap-3">
                  <SpendMetric label="Active cases" value={spend.caseCount} />
                  <SpendMetric label="Maximum calls" value={spend.maximumCallCount} />
                </div>
                <Dialog open={runDialogOpen} onOpenChange={setRunDialogOpen}>
                  <DialogTrigger asChild>
                    <Button id="run-now" className="w-full" disabled={!canManage || !active || processing !== null || !approvedBaseline}>
                      <Play /> Run now
                    </Button>
                  </DialogTrigger>
                  <DialogContent>
                    <DialogHeader>
                      <DialogTitle>Authorize this bounded provider run?</DialogTitle>
                      <DialogDescription>
                        Silent Regression will enqueue {spend.caseCount} case{spend.caseCount === 1 ? "" : "s"} against {monitor.requestedModel}. Retries cannot exceed the displayed ceiling.
                      </DialogDescription>
                    </DialogHeader>
                    <div className="grid grid-cols-2 gap-3 py-2">
                      <SpendMetric label="Planned calls" value={spend.caseCount} />
                      <SpendMetric label="Absolute maximum" value={spend.maximumCallCount} />
                    </div>
                    <Alert>
                      <Gauge />
                      <AlertTitle>Workspace guardrail</AlertTitle>
                      <AlertDescription>{spend.workspaceRemainingRunsToday} of {spend.workspaceRunLimit} runs and {spend.workspaceRemainingCallsToday} of {spend.workspaceCallLimit} calls remain in today&apos;s UTC envelope.</AlertDescription>
                    </Alert>
                    <DialogFooter>
                      <DialogClose asChild><Button variant="outline">Cancel</Button></DialogClose>
                      <Button id="confirm-run-now" disabled={processing !== null} onClick={runNow}>
                        {processing === "run" ? <LoaderCircle className="animate-spin" /> : <Play />} Authorize up to {spend.maximumCallCount} calls
                      </Button>
                    </DialogFooter>
                  </DialogContent>
                </Dialog>
                {!active && <p className="text-center text-xs text-muted-foreground">Activate or resume the monitor before running it.</p>}
              </CardContent>
            </Card>

            <Card id="workspace-guardrail-card">
              <CardHeader>
                <CardTitle className="text-lg">Today&apos;s workspace envelope</CardTitle>
                <CardDescription>Conservative maximum calls committed in UTC, including retry capacity.</CardDescription>
              </CardHeader>
              <CardContent>
                <div className="mb-2 flex items-center justify-between text-sm"><span>{spend.workspaceCommittedCallsToday} calls committed</span><span className="text-muted-foreground">{spend.workspaceCallLimit} limit</span></div>
                <Progress value={Math.min((spend.workspaceCommittedCallsToday / spend.workspaceCallLimit) * 100, 100)} aria-label="Workspace provider-call envelope" />
                <div className="mt-4 flex items-center justify-between border-t pt-4 text-sm"><span>{spend.workspaceRunsToday} runs authorized</span><span className="text-muted-foreground">{spend.workspaceRunLimit} limit</span></div>
                <Progress value={Math.min((spend.workspaceRunsToday / spend.workspaceRunLimit) * 100, 100)} aria-label="Workspace authorized-run envelope" className="mt-2" />
                <p className="mt-3 text-xs leading-5 text-muted-foreground">Each run is capped at {spend.perRunCallLimit} calls. Limits reset {formatUtc(spend.resetsAt)}. A monitor auto-pauses before a new run could exceed this envelope. Credential problems can be resolved from <Link className="font-medium text-foreground underline underline-offset-4" href={credentialsPath}>Provider credentials</Link>.</p>
              </CardContent>
            </Card>
          </div>
        </div>

        <Card id="last-run-card">
          <CardHeader>
            <CardTitle>Latest managed run</CardTitle>
            <CardDescription>Run evidence and alert review arrive in Task 12. This operational summary is already durable.</CardDescription>
          </CardHeader>
          <CardContent>
            {lastRun ? (
              <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
                <RunFact label="Type" value={lastRun.kind} />
                <RunFact label="Status" value={statusLabel(lastRun.status)} />
                <RunFact label="Started" value={formatUtc(lastRun.startedAt || lastRun.insertedAt)} />
                <RunFact label="Completed" value={formatUtc(lastRun.completedAt)} />
                <RunFact label="Call envelope" value={`${lastRun.plannedCallCount} planned · ${lastRun.maximumCallCount} max`} />
              </div>
            ) : (
              <div className="rounded-2xl border border-dashed bg-muted/20 px-6 py-8 text-center">
                <Clock3 className="mx-auto size-6 text-muted-foreground" />
                <p className="mt-3 font-medium">No manual or scheduled run yet</p>
                <p className="mt-1 text-sm text-muted-foreground">Your approved baseline remains the reference; it is not counted as a monitoring run.</p>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </ProductShell>
  )
}

function MetricCard({ icon: Icon, label, value, detail, tone }: { icon: typeof Activity; label: string; value: string | number; detail: ReactNode; tone?: "success" | "warning" }) {
  return <Card><CardContent className="p-5"><span className="flex items-center gap-2 text-xs text-muted-foreground"><Icon className={tone === "warning" ? "size-4 text-amber-600" : tone === "success" ? "size-4 text-success" : "size-4"} />{label}</span><p className="mt-3 text-xl font-semibold tracking-tight">{value}</p><p className="mt-1 text-xs leading-5 text-muted-foreground">{detail}</p></CardContent></Card>
}

function SpendMetric({ label, value }: { label: string; value: number }) {
  return <div className="rounded-xl border bg-muted/20 p-4"><p className="text-xs text-muted-foreground">{label}</p><p className="mt-2 text-2xl font-semibold tracking-tight">{value}</p></div>
}

function RecoveryLimit({ label, value }: { label: string; value: string }) {
  return <div className="rounded-xl border bg-background/70 p-4"><p className="text-xs text-muted-foreground">{label}</p><p className="mt-2 text-sm font-semibold tracking-tight">{value}</p></div>
}

function RunFact({ label, value }: { label: string; value: string }) {
  return <div className="rounded-xl border bg-background p-4"><p className="text-xs text-muted-foreground">{label}</p><p className="mt-2 break-words text-sm font-medium capitalize">{value}</p></div>
}

function StateBadge({ state }: { state: MonitorState }) {
  if (state === "active") return <Badge variant="outline" className="border-success/25 bg-success/10 text-success"><Activity /> Active</Badge>
  if (state === "paused") return <Badge variant="outline" className="border-amber-500/25 bg-amber-500/10 text-amber-700"><CirclePause /> Paused</Badge>
  return <Badge variant="outline" className="border-primary/25 text-primary"><Sparkles /> Ready to activate</Badge>
}

function stateLabel(state: MonitorState) {
  return state === "baseline_pending" ? "Ready to activate" : state === "active" ? "Active" : "Paused"
}

function cadenceLabel(cadence: Cadence) {
  return cadence === "manual" ? "Run now only" : cadence === "daily" ? "Every 24 hours" : "Every 7 days"
}

function cadenceDescription(cadence: Cadence) {
  return cadence === "manual" ? "No automatic calls. An owner starts each run." : cadence === "daily" ? "One managed window every 24 hours from activation." : "One managed window every seven days from activation."
}

function pauseReason(reason: string | null) {
  return ({
    owner_paused: "Paused by a workspace owner.",
    credential_unavailable: "The exact provider credential is unavailable.",
    incompatible_configuration: "The active behavior no longer matches its baseline.",
    repeated_authentication_failures: "The provider rejected two consecutive runs.",
    workspace_call_limit: "Today’s workspace call envelope is exhausted.",
    schedule_owner_unavailable: "The owner who authorized this schedule is no longer available.",
  } as Record<string, string>)[reason || ""] || "Monitoring is paused."
}

function recoveryTitle(status: AuthenticationRecoveryStatus) {
  if (status === "ready") return "Authentication recovery required"
  if (status === "in_progress") return "Authentication recovery is in progress"
  if (status === "succeeded") return "Authentication recovery succeeded"
  return "Authentication recovery probe failed"
}

function recoveryDescription(status: AuthenticationRecoveryStatus, failureCategory: string | null) {
  if (status === "ready") return "Two consecutive managed runs were rejected by the provider. The schedule is stopped until an owner proves exact-model access with a tightly bounded recovery attempt."
  if (status === "in_progress") return "Fresh exact-model access was verified. One completion probe with zero retries is now the only provider work allowed for this monitor."
  if (status === "succeeded") return "The fresh credential validation and single completion probe both succeeded. Earlier failure evidence is unchanged and the schedule still requires an explicit resume."
  return `The single completion probe ended with ${failureLabel(failureCategory)}. The monitor remains paused; retrying creates a new recovery epoch with fresh validation.`
}

function failureLabel(category: string | null) {
  if (!category) return "a failed or unknown outcome"
  return category.replaceAll("_", " ")
}

function statusLabel(status: string) {
  return status.replaceAll("_", " ")
}

function formatUtc(value: string | null) {
  if (!value) return "—"
  return new Intl.DateTimeFormat("en-US", { year: "numeric", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: "UTC", timeZoneName: "short" }).format(new Date(value))
}

export default function Operations(props: OperationsProps) {
  const { flash } = usePage<SharedPageProps>().props
  return <><Head title={`Operations · ${props.monitor.name}`} /><OperationsView {...props} flash={flash} /></>
}
