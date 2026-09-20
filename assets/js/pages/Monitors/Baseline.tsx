import { useEffect } from "react"
import { Head, Link, router, useForm, usePage, usePoll } from "@inertiajs/react"
import {
  AlertTriangle,
  ArrowLeft,
  CheckCircle2,
  CircleDashed,
  Clock3,
  Coins,
  ExternalLink,
  FlaskConical,
  Gauge,
  KeyRound,
  LoaderCircle,
  LockKeyhole,
  RefreshCw,
  ShieldAlert,
  ShieldCheck,
  XCircle,
} from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { Progress } from "@/components/ui/progress"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Textarea } from "@/components/ui/textarea"
import type { SharedPageProps } from "@/types/page"

type Blocker = { code: string; message: string }
type EvaluationStatus = "pass" | "fail" | "evaluator_error"
type RunStatus = "planned" | "queued" | "running" | "succeeded" | "partial_failed" | "failed" | "cancelled" | "needs_review"

type RuleResult = {
  ruleId: string
  ruleType: string
  status: EvaluationStatus
  code: string
  explanation: string
  evidence: Record<string, unknown>
}

type Observation = {
  id: string
  caseKey: string
  caseName: string
  sampleIndex: number
  status: "planned" | "queued" | "running" | "retrying" | "succeeded" | "failed" | "unknown" | "cancelled"
  completionState: "complete" | "incomplete" | "unknown" | null
  requestedModel: string | null
  returnedModel: string | null
  outputText: string | null
  failureCategory: string | null
  failureMessage: string | null
  providerMetadata: Record<string, string | number | boolean>
  inputTokens: number | null
  outputTokens: number | null
  latencyMs: number | null
  attemptCount: number
  evaluation: {
    status: EvaluationStatus
    contractStatus: EvaluationStatus
    caseExpectationSchemaVersion: "no_case_expectation" | "case_expectation_v1"
    caseExpectationFingerprint: string
    caseExpectationStatus: EvaluationStatus | "not_configured"
    caseExpectationResults: {
      checks: Array<{
        checkId: string
        checkType: string
        status: EvaluationStatus
        code: string
        explanation: string
        evidence: Record<string, unknown>
      }>
    }
    caseExpectationError: Record<string, unknown> | null
    error: Record<string, unknown> | null
    ruleResults: RuleResult[]
  } | null
}

type Health = {
  terminal: boolean
  runStatus: RunStatus
  plannedCallCount: number
  maximumCallCount: number
  actualCallCount: number
  observationCount: number
  missingObservationCount: number
  statusCounts: Record<string, number>
  completionCounts: Record<string, number>
  evaluationCounts: Record<string, number>
  contractEvaluationCounts: Record<string, number>
  caseExpectationCounts: Record<string, number>
  deterministicFailureCount: number
  modelMismatchCount: number
  inputTokens: number
  outputTokens: number
  latencyMs: number
  operationalBlockers: Blocker[]
  normalApprovable: boolean
  exceptionalApprovable: boolean
}

type Preflight = {
  ready: boolean
  blockers: Blocker[]
  replacement: boolean
  caseCount: number
  cases: Array<{ id: string; key: string; name: string }>
  samplesPerCase: number
  maximumSamples: number
  retryLimit: number
  plannedCallCount: number
  maximumCallCount: number
  callCap: number
  remainingCallCapacity: number
  maxOutputTokensPerCall: number
  maximumOutputTokens: number
  previewFingerprint: string | null
  provider: "openai" | "anthropic" | null
  requestedModel: string | null
  credential: {
    id: string
    label: string
    secretSuffix: string
    status: string
    modelAccessVerified: boolean
  } | null
}

type Snapshot = {
  id: string
  status: "pending" | "approved" | "superseded" | "rejected"
  approvalMode: "normal" | "exceptional" | null
  approvalRationale: string | null
  authorizedAt: string
  approvedAt: string | null
  rejectedAt: string | null
  provider: "openai" | "anthropic"
  requestedModel: string
  samplesPerCase: number
  retryLimit: number
  plannedCallCount: number
  maximumCallCount: number
  previewFingerprint: string
  memberCount: number
  run: {
    id: string
    status: RunStatus
    startedAt: string | null
    completedAt: string | null
    actualCallCount: number
    observations: Observation[]
  }
}

export type BaselineProps = {
  auth: SharedPageProps["auth"]
  authorizationKey: string
  canDecide: boolean
  compatibility: { compatible: boolean; mismatches: string[] }
  health: Health | null
  monitor: { id: string; name: string; description: string; state: string; version: number | null }
  polling: boolean
  preflight: Preflight
  releaseStage: string
  snapshot: Snapshot | null
}

export function BaselineView({
  errors,
  flash,
  ...props
}: BaselineProps & Pick<SharedPageProps, "errors" | "flash">) {
  const workspace = props.auth.workspace
  if (!workspace) return null

  const path = `/app/${workspace.slug}/monitors/${props.monitor.id}/baseline`
  const contractPath = `/app/${workspace.slug}/monitors/${props.monitor.id}/contract`
  const credentialsPath = `/app/${workspace.slug}/credentials`
  const hasSnapshot = Boolean(props.snapshot)
  const replacementNeeded = props.snapshot?.status === "approved" && props.preflight.replacement
  const approved = props.snapshot?.status === "approved" && !replacementNeeded
  const operationsPath = `/app/${workspace.slug}/monitors/${props.monitor.id}/operations`

  return (
    <ProductShell
      availableWorkspaces={props.auth.workspaces}
      currentSection="monitors"
      membershipRole={props.auth.membership?.role || "member"}
      releaseStage={props.releaseStage}
      userEmail={props.auth.user?.email || "Invited user"}
      workspace={workspace}
    >
      <div className="mx-auto max-w-7xl space-y-7">
        <header className="space-y-5">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <Button asChild variant="ghost" className="-ml-3">
              <Link href={contractPath}>
                <ArrowLeft /> Back to contract
              </Link>
            </Button>
            <div className="flex flex-wrap items-center gap-2">
              <Badge variant="outline">Configuration v{props.monitor.version || "—"}</Badge>
              <BaselineStatusBadge compatibility={props.compatibility} snapshot={props.snapshot} polling={props.polling} />
            </div>
          </div>

          <div className="max-w-3xl">
            <p className="text-sm font-medium text-primary">{props.monitor.name}</p>
            <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
              {replacementNeeded ? "Restore a compatible reference" : "Capture the reference you will monitor"}
            </h1>
            <p className="mt-3 text-base leading-7 text-muted-foreground">
              {replacementNeeded
                ? "Current contract semantics changed. Preserve the historical evidence, authorize a fresh managed replay, and approve it before monitoring resumes."
                : "Preview the exact provider-call envelope, authorize the first managed replay, then inspect every output and deterministic judgment before sealing the baseline."}
            </p>
          </div>

          <WorkflowSteps approved={approved} hasSnapshot={hasSnapshot} polling={props.polling} replacement={replacementNeeded} />
        </header>

        {flash.info && (
          <Alert id="baseline-success" className="border-success/25 bg-success/5">
            <CheckCircle2 />
            <AlertTitle>Baseline updated</AlertTitle>
            <AlertDescription>{flash.info}</AlertDescription>
          </Alert>
        )}

        {flash.error && (
          <Alert id="baseline-error" variant="destructive">
            <AlertTriangle />
            <AlertTitle>Baseline needs attention</AlertTitle>
            <AlertDescription>{flash.error}</AlertDescription>
          </Alert>
        )}

        {replacementNeeded && (
          <Alert id="replacement-baseline-required" className="border-amber-500/25 bg-amber-500/5">
            <ShieldAlert className="text-amber-600" />
            <AlertTitle>Replacement baseline required</AlertTitle>
            <AlertDescription>
              The approved reference below remains sealed as historical evidence. It will be superseded only after you capture, inspect, and approve a compatible replacement.
            </AlertDescription>
          </Alert>
        )}

        {(!props.snapshot || replacementNeeded) && (
          <PreflightPanel
            authorizationKey={props.authorizationKey}
            canDecide={props.canDecide}
            contractPath={contractPath}
            credentialsPath={credentialsPath}
            path={path}
            preflight={props.preflight}
            replacement={replacementNeeded}
          />
        )}

        {props.snapshot && (
          <>
            <CaptureSummary
              compatibility={props.compatibility}
              health={props.health}
              polling={props.polling}
              snapshot={props.snapshot}
            />
            <ObservationReview observations={props.snapshot.run.observations} />
            <ApprovalPanel
              canDecide={props.canDecide}
              compatibility={props.compatibility}
              errors={errors}
              health={props.health}
              path={path}
              operationsPath={operationsPath}
              snapshot={props.snapshot}
            />
          </>
        )}
      </div>
    </ProductShell>
  )
}

function WorkflowSteps({ approved, hasSnapshot, polling, replacement }: { approved: boolean; hasSnapshot: boolean; polling: boolean; replacement: boolean }) {
  const steps = [
    { label: "Preview", complete: hasSnapshot && !replacement, detail: replacement ? "Review replacement" : hasSnapshot ? "Authorized" : "Review limits" },
    { label: "Capture", complete: hasSnapshot && !polling && !replacement, detail: replacement ? "Not started" : polling ? "In progress" : hasSnapshot ? "Terminal" : "Not started" },
    { label: "Inspect", complete: hasSnapshot && !polling && !replacement, detail: replacement ? "Historical only" : hasSnapshot && !polling ? "Evidence ready" : "Waiting" },
    { label: "Approve", complete: approved, detail: replacement ? "Replacement required" : approved ? "Sealed" : "Owner decision" },
  ]

  return (
    <ol aria-label="Baseline progress" className="grid overflow-hidden rounded-xl border bg-card sm:grid-cols-4">
      {steps.map((step, index) => (
        <li key={step.label} className="flex items-center gap-3 border-b p-4 last:border-b-0 sm:border-r sm:border-b-0 sm:last:border-r-0">
          <span className={`grid size-8 shrink-0 place-items-center rounded-full text-xs font-semibold ${step.complete ? "bg-success text-success-foreground" : "bg-muted text-muted-foreground"}`}>
            {step.complete ? <CheckCircle2 className="size-4" /> : index + 1}
          </span>
          <span className="min-w-0">
            <span className="block truncate text-sm font-medium">{step.label}</span>
            <span className="block truncate text-xs text-muted-foreground">{step.detail}</span>
          </span>
        </li>
      ))}
    </ol>
  )
}

function PreflightPanel({ authorizationKey, canDecide, contractPath, credentialsPath, path, preflight, replacement }: {
  authorizationKey: string
  canDecide: boolean
  contractPath: string
  credentialsPath: string
  path: string
  preflight: Preflight
  replacement: boolean
}) {
  const authorizeForm = useForm({
    baseline: {
      authorization_key: authorizationKey,
      samples_per_case: preflight.samplesPerCase,
      preview_fingerprint: preflight.previewFingerprint || "",
    },
  })

  useEffect(() => {
    authorizeForm.setData("baseline", {
      authorization_key: authorizationKey,
      samples_per_case: preflight.samplesPerCase,
      preview_fingerprint: preflight.previewFingerprint || "",
    })
  }, [authorizationKey, preflight.previewFingerprint, preflight.samplesPerCase])

  const verifyForm = useForm({})
  const modelAccessBlocked = preflight.blockers.some(blocker => blocker.code === "model_access_unverified")

  function selectSamples(value: string) {
    router.get(
      path,
      { baseline: { samples_per_case: Number(value) } },
      { preserveScroll: true, preserveState: true, only: ["preflight"] },
    )
  }

  return (
    <div className="grid gap-6 lg:grid-cols-[1.15fr_0.85fr]">
      <Card id="baseline-preflight" className={preflight.ready ? "border-primary/25" : ""}>
        <CardHeader>
          <p className="text-sm font-medium text-primary">Step 1 · {replacement ? "replacement preview" : "exact preview"}</p>
          <CardTitle className="text-2xl">{replacement ? "Capture a reference for the current contract" : "Know the maximum before any completion call"}</CardTitle>
          <CardDescription className="leading-6">
            {replacement
              ? "This exact provider-call envelope creates new evidence. The historical baseline remains approved until you approve its replacement."
              : "Model-access verification is a provider metadata request. The authorization below is the boundary that permits billable completion calls."}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-6">
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <Metric icon={FlaskConical} label="Active cases" value={preflight.caseCount} />
            <Metric icon={Gauge} label="Planned calls" value={preflight.plannedCallCount} />
            <Metric icon={RefreshCw} label="Maximum calls" value={preflight.maximumCallCount} />
            <Metric icon={Coins} label="Output-token ceiling" value={formatNumber(preflight.maximumOutputTokens)} />
          </div>

          <div className="grid gap-5 rounded-xl border bg-muted/25 p-5 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="baseline-samples">Samples per case</Label>
              <Select value={String(preflight.samplesPerCase)} onValueChange={selectSamples}>
                <SelectTrigger id="baseline-samples" className="w-full" aria-label="Samples per case">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {Array.from({ length: preflight.maximumSamples }, (_, index) => index + 1).map(value => (
                    <SelectItem key={value} value={String(value)}>
                      {value} sample{value === 1 ? "" : "s"} per case
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <p className="text-xs leading-5 text-muted-foreground">
                Private-alpha default: one. Each planned call may retry once after a known retryable failure.
              </p>
            </div>
            <div className="space-y-2 text-sm">
              <p className="font-medium">Provider target</p>
              <p className="capitalize">{preflight.provider || "Not configured"}</p>
              <p className="break-all font-mono text-xs text-muted-foreground">{preflight.requestedModel || "No model selected"}</p>
              <p className="text-xs text-muted-foreground">
                {formatNumber(preflight.maxOutputTokensPerCall)} output tokens/call · {formatNumber(preflight.remainingCallCapacity)} calls remain under the per-run cap after this maximum.
              </p>
            </div>
          </div>

          <div>
            <p className="text-sm font-medium">Included cases</p>
            <Table className="mt-3">
              <TableHeader>
                <TableRow>
                  <TableHead>Case</TableHead>
                  <TableHead>Stable key</TableHead>
                  <TableHead className="text-right">Samples</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {preflight.cases.map(caseItem => (
                  <TableRow key={caseItem.id}>
                    <TableCell className="font-medium">{caseItem.name}</TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground">{caseItem.key}</TableCell>
                    <TableCell className="text-right">{preflight.samplesPerCase}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>

          {preflight.blockers.length > 0 && (
            <Alert id="preflight-blockers" className="border-amber-500/25 bg-amber-500/5">
              <AlertTriangle className="text-amber-600" />
              <AlertTitle>Resolve before authorization</AlertTitle>
              <AlertDescription>
                <ul className="mt-2 space-y-2">
                  {preflight.blockers.map(blocker => <li key={blocker.code}>{blocker.message}</li>)}
                </ul>
              </AlertDescription>
            </Alert>
          )}
        </CardContent>
      </Card>

      <Card className="h-fit">
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-xl"><LockKeyhole className="size-5 text-primary" /> Explicit spend authorization</CardTitle>
          <CardDescription className="leading-6">
            Authorization is attributable to your account and sealed to fingerprint {shortFingerprint(preflight.previewFingerprint)}.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-5">
          <div className="rounded-xl border bg-muted/30 p-4 text-sm">
            <p className="font-medium">Credential</p>
            <p className="mt-2 text-muted-foreground">
              {preflight.credential ? `${preflight.credential.label} · ending ${preflight.credential.secretSuffix}` : "No usable credential"}
            </p>
            <p className="mt-2 flex items-center gap-2 text-xs text-muted-foreground">
              {preflight.credential?.modelAccessVerified ? <ShieldCheck className="size-4 text-success" /> : <KeyRound className="size-4 text-amber-600" />}
              {preflight.credential?.modelAccessVerified ? "Exact model access verified" : "Exact model access not yet verified"}
            </p>
          </div>

          {modelAccessBlocked && (
            <Button
              id="verify-baseline-model"
              className="w-full"
              variant="outline"
              disabled={!canDecide || verifyForm.processing}
              onClick={() => verifyForm.post(`${path}/validate-model`, { preserveScroll: true })}
            >
              {verifyForm.processing ? <LoaderCircle className="animate-spin" /> : <KeyRound />}
              Verify exact model access
            </Button>
          )}

          <Button
            id="authorize-baseline"
            className="w-full"
            disabled={!canDecide || !preflight.ready || authorizeForm.processing}
            onClick={() => authorizeForm.post(`${path}/authorize`)}
          >
            {authorizeForm.processing ? <LoaderCircle className="animate-spin" /> : <Coins />}
            Authorize {replacement ? "replacement " : ""}up to {preflight.maximumCallCount} calls
          </Button>

          <p className="text-xs leading-5 text-muted-foreground">
            {canDecide
              ? `Clicking authorize permits this exact ${replacement ? "replacement " : ""}plan; it does not approve the resulting outputs.`
              : "A workspace owner must verify model access and authorize provider spend."}
          </p>

          <div className="flex flex-wrap gap-2 border-t pt-4">
            <Button asChild size="sm" variant="ghost"><Link href={credentialsPath}>Credentials <ExternalLink /></Link></Button>
            <Button asChild size="sm" variant="ghost"><Link href={contractPath}>Approved contract <ExternalLink /></Link></Button>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}

function CaptureSummary({ compatibility, health, polling, snapshot }: {
  compatibility: BaselineProps["compatibility"]
  health: Health | null
  polling: boolean
  snapshot: Snapshot
}) {
  const terminalCount = snapshot.run.observations.filter(observation => ["succeeded", "failed", "unknown", "cancelled"].includes(observation.status)).length
  const progress = snapshot.plannedCallCount === 0 ? 0 : Math.round((terminalCount / snapshot.plannedCallCount) * 100)

  return (
    <Card id="baseline-capture-summary" className={snapshot.status === "approved" && compatibility.compatible ? "border-success/25 bg-success/5" : ""}>
      <CardHeader className="gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <p className="text-sm font-medium text-primary">Step 2 · durable capture</p>
          <CardTitle className="mt-1 text-2xl">{snapshot.status === "approved" ? (compatibility.compatible ? "Approved reference" : "Historical approved reference") : polling ? "Provider capture in progress" : "Capture ready for review"}</CardTitle>
          <CardDescription className="mt-2 leading-6">
            {polling ? "Progress refreshes from persisted jobs every two seconds; leaving this page does not stop the run." : `Run ${snapshot.run.status.replaceAll("_", " ")} · authorized ${formatDate(snapshot.authorizedAt)}`}
          </CardDescription>
        </div>
        {polling && <Badge variant="outline" className="border-primary/25 text-primary"><LoaderCircle className="animate-spin" /> Polling durable state</Badge>}
      </CardHeader>
      <CardContent className="space-y-5">
        <Progress value={progress} aria-label="Baseline capture progress" />
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-6">
          <ProofMetric label="Terminal samples" value={`${terminalCount}/${snapshot.plannedCallCount}`} />
          <ProofMetric label="Actual calls" value={String(health?.actualCallCount ?? snapshot.run.actualCallCount ?? 0)} />
          <ProofMetric label="Complete" value={String(health?.completionCounts.complete || 0)} tone="success" />
          <ProofMetric label="Incomplete / unknown" value={String((health?.completionCounts.incomplete || 0) + (health?.completionCounts.unknown || 0))} tone="warning" />
          <ProofMetric label="Failed" value={String(health?.statusCounts.failed || 0)} tone="danger" />
          <ProofMetric label="Contract / case failures" value={`${health?.contractEvaluationCounts.fail || 0} / ${health?.caseExpectationCounts.fail || 0}`} tone={(health?.contractEvaluationCounts.fail || 0) + (health?.caseExpectationCounts.fail || 0) > 0 ? "danger" : "success"} />
        </div>

        {health && (
          <div className="grid gap-3 rounded-xl border bg-background/70 p-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
            <EvidenceMetric label="Input tokens" value={formatNumber(health.inputTokens)} />
            <EvidenceMetric label="Output tokens" value={formatNumber(health.outputTokens)} />
            <EvidenceMetric label="Total latency" value={`${formatNumber(health.latencyMs)} ms`} />
            <EvidenceMetric label="Model mismatches" value={String(health.modelMismatchCount)} warning={health.modelMismatchCount > 0} />
          </div>
        )}

        {!compatibility.compatible && (
          <Alert variant="destructive">
            <ShieldAlert />
            <AlertTitle>Configuration compatibility changed</AlertTitle>
            <AlertDescription>
              {snapshot.status === "approved" ? "This historical reference no longer matches current behavior" : "This capture cannot be approved against current behavior"}: {compatibility.mismatches.join(", ").replaceAll("_", " ")}.
            </AlertDescription>
          </Alert>
        )}
      </CardContent>
    </Card>
  )
}

function ObservationReview({ observations }: { observations: Observation[] }) {
  return (
    <section aria-labelledby="observation-review-heading" className="space-y-4">
      <div>
        <p className="text-sm font-medium text-primary">Step 3 · inspect every sample</p>
        <h2 id="observation-review-heading" className="mt-1 text-2xl font-semibold tracking-tight">Provider evidence and deterministic results</h2>
        <p className="mt-2 text-sm leading-6 text-muted-foreground">Operational outcomes, shared-contract judgments, and case-specific expectations stay separate so each failure points to the correct layer.</p>
      </div>

      <div id="baseline-observations" className="space-y-4">
        {observations.map(observation => <ObservationCard key={observation.id} observation={observation} />)}
      </div>
    </section>
  )
}

function ObservationCard({ observation }: { observation: Observation }) {
  const modelMismatch = Boolean(observation.requestedModel && observation.returnedModel && observation.requestedModel !== observation.returnedModel)
  const rules = observation.evaluation?.ruleResults || []

  return (
    <Card id={`baseline-observation-${observation.id}`}>
      <CardHeader className="gap-4 md:flex-row md:items-start md:justify-between">
        <div>
          <CardTitle className="text-lg">{observation.caseName} · sample {observation.sampleIndex + 1}</CardTitle>
          <CardDescription className="mt-2 font-mono text-xs">{observation.caseKey}</CardDescription>
        </div>
        <div className="flex flex-wrap gap-2">
          <StatusBadge status={observation.status} />
          {observation.completionState && <StatusBadge status={observation.completionState} />}
          {observation.evaluation && <span className="flex items-center gap-1 text-xs text-muted-foreground">Overall <StatusBadge status={observation.evaluation.status} /></span>}
          {observation.evaluation && <span className="flex items-center gap-1 text-xs text-muted-foreground">Contract <StatusBadge status={observation.evaluation.contractStatus} /></span>}
          {observation.evaluation && <span className="flex items-center gap-1 text-xs text-muted-foreground">Case <StatusBadge status={observation.evaluation.caseExpectationStatus} /></span>}
        </div>
      </CardHeader>
      <CardContent className="space-y-5">
        {modelMismatch && (
          <Alert variant="destructive">
            <ShieldAlert />
            <AlertTitle>Returned-model mismatch</AlertTitle>
            <AlertDescription>Requested {observation.requestedModel}; provider reported {observation.returnedModel}.</AlertDescription>
          </Alert>
        )}

        {observation.failureCategory && (
          <Alert variant="destructive">
            <XCircle />
            <AlertTitle>Provider outcome: {observation.failureCategory.replaceAll("_", " ")}</AlertTitle>
            <AlertDescription className="space-y-2">
              <p>{observation.failureMessage || "The provider request did not complete successfully."}</p>
              <p>No deterministic quality conclusion is inferred from this operational failure.</p>
              {Object.keys(observation.providerMetadata).length > 0 && (
                <dl className="grid gap-x-4 gap-y-1 rounded-lg border border-destructive/20 bg-background/60 p-3 font-mono text-xs sm:grid-cols-[auto_1fr]">
                  {Object.entries(observation.providerMetadata).map(([key, value]) => (
                    <div className="contents" key={key}>
                      <dt className="font-semibold text-foreground">{key.replaceAll("_", " ")}</dt>
                      <dd className="break-all">{String(value)}</dd>
                    </div>
                  ))}
                </dl>
              )}
            </AlertDescription>
          </Alert>
        )}

        <div>
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Captured output</p>
          <pre className="mt-2 max-h-72 overflow-auto whitespace-pre-wrap break-words rounded-xl bg-muted p-4 text-xs leading-5">{observation.outputText ?? "No output was captured."}</pre>
        </div>

        <div className="grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
          <EvidenceMetric label="Requested model" value={observation.requestedModel || "—"} />
          <EvidenceMetric label="Returned model" value={observation.returnedModel || "—"} warning={modelMismatch} />
          <EvidenceMetric label="Tokens" value={`${observation.inputTokens || 0} in · ${observation.outputTokens || 0} out`} />
          <EvidenceMetric label="Attempts / latency" value={`${observation.attemptCount} · ${observation.latencyMs || 0} ms`} />
        </div>

        {observation.evaluation && (
          <div className="grid gap-4 xl:grid-cols-2">
            <div className="overflow-hidden rounded-xl border">
              <div className="border-b bg-muted/25 px-4 py-3"><p className="text-sm font-medium">Shared contract</p></div>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Rule</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Why</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rules.map(result => (
                  <TableRow key={result.ruleId}>
                    <TableCell><span className="block font-mono text-xs font-medium">{result.ruleId}</span><span className="text-xs text-muted-foreground">{result.ruleType.replaceAll("_", " ")}</span></TableCell>
                    <TableCell><StatusBadge status={result.status} /></TableCell>
                    <TableCell className="min-w-64 whitespace-normal text-xs leading-5 text-muted-foreground">{result.explanation}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            </div>
            <div className="overflow-hidden rounded-xl border border-primary/20">
              <div className="border-b bg-primary/5 px-4 py-3"><p className="text-sm font-medium">Case-specific expectation</p><p className="mt-1 font-mono text-[11px] text-muted-foreground">{shortFingerprint(observation.evaluation.caseExpectationFingerprint)}</p></div>
              {observation.evaluation.caseExpectationStatus === "not_configured" ? (
                <p className="p-4 text-sm text-muted-foreground">This immutable case explicitly has no case-specific expectation.</p>
              ) : (
                <Table>
                  <TableHeader><TableRow><TableHead>Check</TableHead><TableHead>Status</TableHead><TableHead>Why</TableHead></TableRow></TableHeader>
                  <TableBody>
                    {observation.evaluation.caseExpectationResults.checks.map(check => (
                      <TableRow key={check.checkId}>
                        <TableCell><span className="block font-mono text-xs font-medium">{check.checkId}</span><span className="text-xs text-muted-foreground">{check.checkType.replaceAll("_", " ")}</span></TableCell>
                        <TableCell><StatusBadge status={check.status} /></TableCell>
                        <TableCell className="min-w-64 whitespace-normal text-xs leading-5 text-muted-foreground">{check.explanation}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function ApprovalPanel({ canDecide, compatibility, errors, health, operationsPath, path, snapshot }: {
  canDecide: boolean
  compatibility: BaselineProps["compatibility"]
  errors: SharedPageProps["errors"]
  health: Health | null
  path: string
  operationsPath: string
  snapshot: Snapshot
}) {
  const exceptionalForm = useForm({
    baseline: { approval_mode: "exceptional", approval_rationale: "" },
  })
  const decisionForm = useForm({})
  const approved = snapshot.status === "approved"
  const pending = snapshot.status === "pending"

  if (approved && !compatibility.compatible) {
    return (
      <Card id="baseline-historical" className="border-amber-500/25 bg-amber-500/5">
        <CardHeader>
          <p className="text-sm font-medium text-amber-700">Historical evidence</p>
          <CardTitle className="flex items-center gap-2 text-2xl"><ShieldAlert className="size-6" /> Approved baseline retained</CardTitle>
          <CardDescription className="leading-6">
            {snapshot.memberCount} sealed observation{snapshot.memberCount === 1 ? "" : "s"} remain attributable and auditable. This reference will be superseded only when a compatible replacement is approved.
          </CardDescription>
        </CardHeader>
      </Card>
    )
  }

  if (approved) {
    return (
      <Card id="baseline-approved" className="border-success/25 bg-success/5">
        <CardHeader>
          <p className="text-sm font-medium text-success">Step 4 · sealed</p>
          <CardTitle className="flex items-center gap-2 text-2xl"><ShieldCheck className="size-6" /> Approved baseline</CardTitle>
          <CardDescription className="leading-6">{snapshot.memberCount} exact observation{snapshot.memberCount === 1 ? "" : "s"} sealed {formatDate(snapshot.approvedAt)} with {snapshot.approvalMode} approval.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {snapshot.approvalRationale && <p className="rounded-xl border bg-background/70 p-4 text-sm leading-6"><span className="font-medium">Recorded rationale:</span> {snapshot.approvalRationale}</p>}
          <div className="flex flex-col gap-3 border-t pt-4 sm:flex-row sm:items-center sm:justify-between">
            <p className="text-sm text-muted-foreground">The reference is sealed. Choose manual, daily, or weekly operation next.</p>
            <Button asChild id="continue-to-operations"><Link href={operationsPath}>Continue to operations <ExternalLink /></Link></Button>
          </div>
        </CardContent>
      </Card>
    )
  }

  return (
    <Card id="baseline-approval" className={health?.normalApprovable ? "border-primary/25" : ""}>
      <CardHeader>
        <p className="text-sm font-medium text-primary">Step 4 · owner decision</p>
        <CardTitle className="text-2xl">Approve only after reviewing every sample</CardTitle>
        <CardDescription className="leading-6">Approval seals this exact membership and provenance. It does not activate recurring monitoring; schedule selection comes next.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        {health?.operationalBlockers && health.operationalBlockers.length > 0 && (
          <Alert variant="destructive">
            <ShieldAlert />
            <AlertTitle>Operational evidence blocks approval</AlertTitle>
            <AlertDescription><ul className="mt-2 space-y-2">{health.operationalBlockers.map(blocker => <li key={blocker.code}>{blocker.message}</li>)}</ul></AlertDescription>
          </Alert>
        )}

        {health?.deterministicFailureCount ? (
          <Alert className="border-amber-500/25 bg-amber-500/5">
            <AlertTriangle className="text-amber-600" />
            <AlertTitle>{health.deterministicFailureCount} deterministic failure{health.deterministicFailureCount === 1 ? "" : "s"}</AlertTitle>
            <AlertDescription>Normal approval is blocked. Exceptional approval is available only when all provider and evaluator evidence is operationally complete.</AlertDescription>
          </Alert>
        ) : null}

        {health?.exceptionalApprovable && (
          <div className="space-y-3 rounded-xl border border-amber-500/25 bg-amber-500/5 p-5">
            <div>
              <Label htmlFor="approval-rationale">Exceptional approval rationale</Label>
              <p className="mt-1 text-xs leading-5 text-muted-foreground">Explain why these deterministic failures are acceptable for this initial reference. This note becomes immutable approval evidence.</p>
            </div>
            <Textarea
              id="approval-rationale"
              value={exceptionalForm.data.baseline.approval_rationale}
              onChange={event => exceptionalForm.setData("baseline", { ...exceptionalForm.data.baseline, approval_rationale: event.target.value })}
              aria-invalid={Boolean(errors.approvalRationale)}
              placeholder="Describe the reviewed exception (20–2,000 characters)."
              rows={4}
            />
            {errors.approvalRationale && <p className="text-sm text-destructive">{errors.approvalRationale}</p>}
            <Button
              id="approve-baseline-exceptionally"
              variant="outline"
              disabled={!canDecide || !compatibility.compatible || !pending || exceptionalForm.processing}
              onClick={() => exceptionalForm.post(`${path}/approve`)}
            >
              {exceptionalForm.processing ? <LoaderCircle className="animate-spin" /> : <ShieldAlert />}
              Approve with recorded exception
            </Button>
          </div>
        )}

        <div className="flex flex-col gap-3 border-t pt-5 sm:flex-row sm:items-center sm:justify-between">
          <p className="text-sm text-muted-foreground">{canDecide ? "Your decision is attributable to your account." : "A workspace owner must approve or reject the baseline."}</p>
          <div className="flex flex-col gap-2 sm:flex-row">
            <Button
              id="reject-baseline"
              variant="ghost"
              disabled={!canDecide || !pending || decisionForm.processing}
              onClick={() => decisionForm.post(`${path}/reject`)}
            >
              <XCircle /> Reject capture
            </Button>
            <Button
              id="approve-baseline"
              disabled={!canDecide || !compatibility.compatible || !health?.normalApprovable || !pending || decisionForm.processing}
              onClick={() => router.post(`${path}/approve`, { baseline: { approval_mode: "normal" } })}
            >
              <LockKeyhole /> Approve and seal baseline
            </Button>
          </div>
        </div>
      </CardContent>
    </Card>
  )
}

function Metric({ icon: Icon, label, value }: { icon: typeof Gauge; label: string; value: string | number }) {
  return <div className="rounded-xl border bg-background p-4"><span className="flex items-center gap-2 text-xs text-muted-foreground"><Icon className="size-4" />{label}</span><p className="mt-2 text-2xl font-semibold tracking-tight">{value}</p></div>
}

function ProofMetric({ label, value, tone }: { label: string; value: string; tone?: "success" | "warning" | "danger" }) {
  const toneClass = tone === "success" ? "text-success" : tone === "warning" ? "text-amber-600" : tone === "danger" ? "text-destructive" : "text-foreground"
  return <div className="rounded-xl border bg-background/70 p-4"><p className="text-xs text-muted-foreground">{label}</p><p className={`mt-2 text-xl font-semibold ${toneClass}`}>{value}</p></div>
}

function EvidenceMetric({ label, value, warning = false }: { label: string; value: string; warning?: boolean }) {
  return <div className="min-w-0"><p className="text-xs text-muted-foreground">{label}</p><p className={`mt-1 break-all text-xs font-medium ${warning ? "text-destructive" : "text-foreground"}`}>{value}</p></div>
}

function StatusBadge({ status }: { status: string }) {
  const normalized = status.replaceAll("_", " ")
  const success = ["succeeded", "complete", "pass", "approved"].includes(status)
  const danger = ["failed", "unknown", "incomplete", "evaluator_error", "cancelled"].includes(status)
  return <Badge variant="outline" className={success ? "border-success/25 bg-success/10 text-success" : danger ? "border-destructive/25 bg-destructive/5 text-destructive" : "border-primary/25 text-primary"}>{success ? <CheckCircle2 /> : danger ? <AlertTriangle /> : <CircleDashed />}{normalized}</Badge>
}

function BaselineStatusBadge({ compatibility, polling, snapshot }: { compatibility: BaselineProps["compatibility"]; polling: boolean; snapshot: Snapshot | null }) {
  if (!snapshot) return <Badge variant="outline"><CircleDashed /> Not authorized</Badge>
  if (snapshot.status === "approved" && !compatibility.compatible) return <Badge variant="outline" className="border-amber-500/25 text-amber-700"><ShieldAlert /> Replacement required</Badge>
  if (snapshot.status === "approved") return <Badge variant="outline" className="border-success/25 bg-success/10 text-success"><ShieldCheck /> Approved baseline</Badge>
  if (snapshot.status === "rejected") return <Badge variant="outline" className="border-destructive/25 text-destructive"><XCircle /> Rejected</Badge>
  if (polling) return <Badge variant="outline" className="border-primary/25 text-primary"><Clock3 /> Capturing</Badge>
  return <Badge variant="outline" className="border-amber-500/25 text-amber-700"><ShieldAlert /> Awaiting review</Badge>
}

function shortFingerprint(value: string | null) {
  return value ? value.slice(0, 12) : "unavailable"
}

function formatNumber(value: number) {
  return new Intl.NumberFormat("en-US").format(value)
}

function formatDate(value: string | null) {
  if (!value) return "—"
  return new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}

export default function Baseline(props: BaselineProps) {
  const { errors, flash } = usePage<SharedPageProps>().props
  const { start, stop } = usePoll(
    2_000,
    { only: ["snapshot", "health", "compatibility", "polling"] },
    { autoStart: false, keepAlive: false },
  )

  useEffect(() => {
    if (props.polling) start()
    else stop()

    return () => stop()
  }, [props.polling])

  return (
    <>
      <Head title={`Baseline · ${props.monitor.name}`} />
      <BaselineView {...props} errors={errors} flash={flash} />
    </>
  )
}
