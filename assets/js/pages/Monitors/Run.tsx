import { useState, type ReactNode } from "react"
import { Head, Link, router, usePage } from "@inertiajs/react"
import {
  AlertTriangle,
  ArrowLeft,
  Braces,
  CheckCircle2,
  ChevronDown,
  CircleX,
  Download,
  FileCheck2,
  Fingerprint,
  Gauge,
  GitBranch,
  History,
  LoaderCircle,
  LockKeyhole,
  MessageSquare,
  ShieldAlert,
} from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import {
  AlertStatusBadge,
  BoundedTextBlock,
  CategoryBadge,
  formatNumber,
  formatUtc,
  label,
  Metric,
  RunStatusBadge,
  SeverityBadge,
  shortId,
  StructuredEvidence,
} from "@/components/result-evidence"
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
} from "@/components/ui/dialog"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Textarea } from "@/components/ui/textarea"
import type { SharedPageProps } from "@/types/page"
import type {
  Evaluation,
  Observation,
  Provenance,
  ResultAlert,
  ResultMonitor,
  ReviewAction,
  ReviewClassification,
  ReviewDecision,
  RunDetail,
} from "@/types/results"

type ReviewSubject = {
  kind: "alert" | "observation"
  id: string
  title: string
  current: ReviewDecision | null
}

const classifications: Array<{ value: ReviewClassification; label: string; description: string }> = [
  { value: "correct_pass", label: "Correct pass", description: "The output passed and that judgment is correct." },
  { value: "confirmed_regression", label: "Confirmed regression", description: "The alert identifies a real output regression." },
  { value: "acceptable_variation", label: "Acceptable variation / false alert", description: "The output is acceptable; the alert is too strict." },
  { value: "contract_needs_revision", label: "Contract needs revision", description: "The rules do not express the intended requirement." },
  { value: "test_case_or_baseline_problem", label: "Test case or reviewed reference problem", description: "The case or pinned comparison evidence needs correction." },
  { value: "passed_but_should_have_failed", label: "Passed but should have failed", description: "A missed regression was not caught by the contract." },
  { value: "unsure", label: "Unsure / requires review", description: "More domain judgment is required." },
  { value: "operational_anomaly", label: "Operational / provider anomaly", description: "This concerns execution, not output quality." },
]

const actions: Array<{ value: ReviewAction; label: string }> = [
  { value: "none", label: "No follow-up yet" },
  { value: "prompt_change", label: "Prompt change" },
  { value: "case_change", label: "Test case change" },
  { value: "contract_revision", label: "Contract revision" },
  { value: "provider_change", label: "Provider or model change" },
  { value: "operational_follow_up", label: "Operational follow-up" },
]

export type RunProps = {
  auth: SharedPageProps["auth"]
  canResolve: boolean
  monitor: ResultMonitor
  releaseStage: string
  result: RunDetail
}

export function RunView({ auth, canResolve, flash = {}, monitor, releaseStage, result }: RunProps & { flash?: SharedPageProps["flash"] }) {
  const workspace = auth.workspace
  const [processingAlert, setProcessingAlert] = useState<string | null>(null)
  const [resolveAlert, setResolveAlert] = useState<ResultAlert | null>(null)
  const [reviewSubject, setReviewSubject] = useState<ReviewSubject | null>(null)
  const [reviewClassification, setReviewClassification] = useState<ReviewClassification>("unsure")
  const [reviewAction, setReviewAction] = useState<ReviewAction>("none")
  const [reviewRationale, setReviewRationale] = useState("")
  const [processingReview, setProcessingReview] = useState(false)
  if (!workspace) return null

  const summary = result.summary
  const monitorPath = `/app/${workspace.slug}/monitors/${monitor.id}`
  const resultsPath = `${monitorPath}/results`
  const alertsPath = `/app/${workspace.slug}/alerts`
  const runPath = `${monitorPath}/runs/${summary.id}`
  const terminal = !["planned", "queued", "running"].includes(summary.status)
  const contractFailures = summary.contractEvaluationCounts.fail || 0
  const expectationFailures = summary.caseExpectationCounts.fail || 0
  const complete = summary.completionCounts.complete || 0

  const mutateAlert = (alert: ResultAlert, action: "acknowledge" | "resolve") => {
    setProcessingAlert(alert.id)
    const path = alert.incident
      ? `/app/${workspace.slug}/incidents/${alert.incident.id}/${action}`
      : `/app/${workspace.slug}/alerts/${alert.id}/${action}`
    router.post(path, {}, {
      preserveScroll: true,
      onSuccess: () => setResolveAlert(null),
      onFinish: () => setProcessingAlert(null),
    })
  }

  const currentReview = (kind: ReviewSubject["kind"], id: string) =>
    result.reviews.find(review => review.current && (kind === "alert" ? review.resultAlertId === id : review.captureObservationId === id)) || null

  const openReview = (kind: ReviewSubject["kind"], id: string, title: string, fallback: ReviewClassification) => {
    const current = currentReview(kind, id)
    setReviewSubject({ kind, id, title, current })
    setReviewClassification(current?.classification || fallback)
    setReviewAction(current?.action || "none")
    setReviewRationale(current?.rationale?.text || "")
  }

  const submitReview = () => {
    if (!reviewSubject) return
    setProcessingReview(true)
    router.post(`${runPath}/reviews`, {
      review: {
        subject_kind: reviewSubject.kind,
        subject_id: reviewSubject.id,
        expected_current_id: reviewSubject.current?.id || "",
        classification: reviewClassification,
        action: reviewAction,
        rationale: reviewRationale,
      },
    }, {
      preserveScroll: true,
      onSuccess: () => setReviewSubject(null),
      onFinish: () => setProcessingReview(false),
    })
  }

  const startContractRevision = (review: ReviewDecision) => {
    setProcessingReview(true)
    router.post(`${runPath}/reviews/${review.id}/contract-revision`, {}, {
      onFinish: () => setProcessingReview(false),
    })
  }

  const startConfigurationSuccessor = (review: ReviewDecision) => {
    setProcessingReview(true)
    router.post(`${monitorPath}/successor`, { review_id: review.id }, {
      onFinish: () => setProcessingReview(false),
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
            <Button asChild variant="ghost" className="-ml-3"><Link href={resultsPath}><ArrowLeft /> All results</Link></Button>
            <div className="flex flex-wrap gap-2">
              <RunStatusBadge status={summary.status} />
              <Badge variant="outline" className="capitalize">{summary.kind} run</Badge>
              <Badge variant="secondary">{formatUtc(summary.completedAt || summary.insertedAt)}</Badge>
            </div>
          </div>
          <div className="grid gap-5 lg:grid-cols-[1fr_auto] lg:items-end">
            <div className="max-w-3xl">
              <p className="text-sm font-medium text-primary">{monitor.name}</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Run evidence, without a hidden score</h1>
              <p className="mt-3 text-base leading-7 text-muted-foreground">Review completion, shared-contract outcomes, case-specific expectations, operational anomalies, and each captured response. The product does not collapse these distinct facts into one quality number.</p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Button asChild variant="outline"><Link href={alertsPath}>Workspace alerts</Link></Button>
              <Button asChild variant="outline"><a href={`${runPath}/diagnostic`}><Download /> Redacted diagnostic</a></Button>
            </div>
          </div>
        </header>

        {flash.info && <Alert id="run-success" className="border-success/25 bg-success/5"><CheckCircle2 /><AlertTitle>Evidence workflow updated</AlertTitle><AlertDescription>{flash.info}</AlertDescription></Alert>}
        {flash.error && <Alert id="run-error" variant="destructive"><AlertTriangle /><AlertTitle>Evidence workflow unchanged</AlertTitle><AlertDescription>{flash.error}</AlertDescription></Alert>}

        {!terminal && (
          <Alert id="run-in-progress">
            <LoaderCircle className="animate-spin" />
            <AlertTitle>This run is still {label(summary.status).toLowerCase()}</AlertTitle>
            <AlertDescription>Evidence and alerts are finalized only after every planned observation reaches a terminal state. Refresh later for the immutable result.</AlertDescription>
          </Alert>
        )}

        {!result.provenance.compatible && (
          <Alert id="provenance-mismatch" variant="destructive">
            <Fingerprint />
            <AlertTitle>Reviewed-reference provenance does not match this run</AlertTitle>
            <AlertDescription>
              Reference-relative latency and usage findings were deliberately skipped. Mismatches: {result.provenance.mismatches.map(label).join(", ") || "reviewed reference unavailable"}.
            </AlertDescription>
          </Alert>
        )}

        <section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-5" aria-label="Run summary">
          <Metric label="Provider calls" value={`${summary.actualCallCount}/${summary.maximumCallCount}`} detail={`${summary.plannedCallCount} planned; retry ceiling included`} />
          <Metric label="Complete responses" value={`${complete}/${summary.plannedCallCount}`} detail={`${summary.providerFailureCount} provider failure${summary.providerFailureCount === 1 ? "" : "s"}`} tone={complete === summary.plannedCallCount ? "success" : "warning"} />
          <Metric label="Shared-contract failures" value={contractFailures} detail={`${summary.contractEvaluationCounts.evaluatorError || 0} contract evaluator errors`} tone={contractFailures > 0 ? "danger" : "success"} />
          <Metric label="Case mismatches" value={expectationFailures} detail={`${summary.caseExpectationCounts.evaluatorError || 0} expectation evaluator errors`} tone={expectationFailures > 0 ? "danger" : "success"} />
          <Metric label="Run alerts" value={summary.criticalAlertCount + summary.warningAlertCount} detail={`${summary.criticalAlertCount} critical · ${summary.warningAlertCount} warning`} tone={summary.criticalAlertCount > 0 ? "danger" : summary.warningAlertCount > 0 ? "warning" : "success"} />
        </section>

        <Card id="review-evidence" className="border-primary/20 bg-primary/5">
          <CardHeader className="gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <CardTitle className="flex items-center gap-2"><MessageSquare className="size-5 text-primary" /> Human review evidence</CardTitle>
              <CardDescription className="mt-2 max-w-3xl leading-6">These are attributable design-partner judgments, not model-accuracy statistics. Revised judgments remain visible as append-only history.</CardDescription>
            </div>
            <Badge variant="outline">{result.reviewSummary.currentCount} current judgment{result.reviewSummary.currentCount === 1 ? "" : "s"}</Badge>
          </CardHeader>
          <CardContent className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Fact label="Reviewed subjects" value={formatNumber(result.reviewSummary.currentCount)} />
            <Fact label="Revised judgments" value={formatNumber(result.reviewSummary.changedJudgmentCount)} />
            <Fact label="Superseded decisions" value={formatNumber(result.reviewSummary.supersededCount)} />
            <Fact label="Awaiting more review" value={formatNumber(result.reviewSummary.classificationCounts.unsure || 0)} />
          </CardContent>
        </Card>

        <section id="run-alerts" className="space-y-4" aria-labelledby="run-alerts-heading">
          <div className="flex flex-wrap items-end justify-between gap-3">
            <div><p className="text-sm font-medium text-primary">Action queue</p><h2 id="run-alerts-heading" className="mt-1 text-2xl font-semibold tracking-tight">Alerts from this run</h2></div>
            <p className="max-w-lg text-right text-xs leading-5 text-muted-foreground">Any member can acknowledge. Only owners can resolve, and only after acknowledgement. Evidence is immutable in every state.</p>
          </div>

          {result.alerts.length === 0 ? (
            <Card id="run-alerts-empty" className="border-success/20 bg-success/5"><CardContent className="flex gap-3 py-6"><CheckCircle2 className="mt-0.5 size-5 text-success" /><div><p className="font-medium">No alerts derived from this run</p><p className="mt-1 text-sm leading-6 text-muted-foreground">The absence of alerts does not hide the underlying output and rule-level evidence below.</p></div></CardContent></Card>
          ) : (
            <div className="grid gap-4 lg:grid-cols-2">
              {result.alerts.map(alert => {
                const review = currentReview("alert", alert.id)
                const history = result.reviews.filter(item => item.reviewKey === `alert:${alert.id}`)
                return (
                <Card key={alert.id} id={`run-alert-${alert.id}`} className={alert.status === "resolved" ? "opacity-75" : alert.severity === "critical" ? "border-destructive/30" : "border-amber-500/30"}>
                  <CardHeader>
                    <div className="flex flex-wrap gap-2"><SeverityBadge severity={alert.severity} /><CategoryBadge category={alert.category} /><AlertStatusBadge status={alert.status} /></div>
                    <CardTitle className="pt-2 text-xl">{alert.title}</CardTitle>
                    <CardDescription className="leading-6">{alert.explanation}</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <details className="group rounded-xl border bg-muted/20 p-4">
                      <summary className="flex cursor-pointer list-none items-center justify-between gap-3 text-sm font-medium">Derived evidence <ChevronDown className="size-4 transition-transform group-open:rotate-180" /></summary>
                      <div className="mt-4"><StructuredEvidence value={alert.evidence} /></div>
                    </details>
                    <ReviewStatus decision={review} history={history} />
                    <div className="flex flex-wrap items-center justify-between gap-3">
                      <p className="text-xs text-muted-foreground">{alert.status === "resolved" ? `Resolved ${formatUtc(alert.resolvedAt)}` : alert.status === "recovered" ? `Recovered ${formatUtc(alert.incident?.recoveredAt || null)}` : alert.status === "acknowledged" ? `Acknowledged ${formatUtc(alert.acknowledgedAt)}` : `Opened ${formatUtc(alert.openedAt)}`}</p>
                      <div className="flex flex-wrap gap-2">
                        <Button id={`review-alert-${alert.id}`} size="sm" variant="outline" disabled={processingReview} onClick={() => openReview("alert", alert.id, alert.title, alert.category === "operational_anomaly" ? "operational_anomaly" : "confirmed_regression")}><MessageSquare /> {review ? "Revise judgment" : "Record judgment"}</Button>
                        {review?.action === "contract_revision" && <Button id={`start-contract-revision-${review.id}`} size="sm" variant="outline" disabled={processingReview} onClick={() => startContractRevision(review)}><GitBranch /> Start contract revision</Button>}
                        {review && successorAction(review.action) && <Button id={`start-configuration-successor-${review.id}`} size="sm" variant="outline" disabled={processingReview} onClick={() => startConfigurationSuccessor(review)}><GitBranch /> Revise configuration</Button>}
                        {alert.incident && <Button asChild id={`view-incident-${alert.incident.id}`} size="sm" variant="outline"><Link href={`/app/${workspace.slug}/incidents/${alert.incident.id}`}>Incident · {alert.incident.occurrenceCount} occurrence{alert.incident.occurrenceCount === 1 ? "" : "s"}</Link></Button>}
                        {alert.status === "open" && <Button id={`acknowledge-alert-${alert.id}`} size="sm" disabled={processingAlert !== null} onClick={() => mutateAlert(alert, "acknowledge")}>{processingAlert === alert.id ? <LoaderCircle className="animate-spin" /> : <FileCheck2 />} Acknowledge incident</Button>}
                        {alert.status === "acknowledged" && canResolve && <Button id={`resolve-alert-${alert.id}`} size="sm" disabled={processingAlert !== null || !review || (alert.incident?.latestAlertId !== alert.id)} onClick={() => setResolveAlert(alert)}><LockKeyhole /> Resolve incident</Button>}
                        {alert.status === "acknowledged" && !canResolve && <Badge variant="outline">Owner resolution required</Badge>}
                        {alert.status === "acknowledged" && canResolve && !review && <Badge variant="outline">Latest review required to resolve</Badge>}
                      </div>
                    </div>
                  </CardContent>
                </Card>
              )})}
            </div>
          )}
        </section>

        <Card id="run-operational-evidence">
          <CardHeader><CardTitle className="flex items-center gap-2"><Gauge className="size-5 text-primary" /> Operational evidence</CardTitle><CardDescription>Provider identity, completion, usage, and latency remain separate from shared-contract and case-specific judgments.</CardDescription></CardHeader>
          <CardContent className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Fact label="Provider / requested model" value={`${summary.provider} / ${summary.requestedModel}`} />
            <Fact label="Returned-model mismatches" value={formatNumber(summary.modelMismatchCount)} tone={summary.modelMismatchCount > 0 ? "danger" : "default"} />
            <Fact label="Token usage" value={`${formatNumber(summary.inputTokens)} in · ${formatNumber(summary.outputTokens)} out`} />
            <Fact label="Successful-call latency" value={`${formatNumber(summary.latencyMs)} ms cumulative`} />
          </CardContent>
        </Card>

        <ProvenanceCard baseline={result.provenance.baseline} current={result.provenance.current} compatible={result.provenance.compatible} mismatches={result.provenance.mismatches} />

        <Card id="run-configuration">
          <CardHeader><CardTitle className="flex items-center gap-2"><Braces className="size-5 text-primary" /> Frozen configuration</CardTitle><CardDescription>Configuration v{result.configuration.monitorVersion} used for this run. Long values are safely bounded only in the browser preview.</CardDescription></CardHeader>
          <CardContent className="space-y-5">
            <TextSection title="System prompt"><BoundedTextBlock value={result.configuration.systemPrompt} empty="No system prompt" /></TextSection>
            <TextSection title="User prompt template"><BoundedTextBlock value={result.configuration.userPromptTemplate} /></TextSection>
            <div className="grid gap-5 lg:grid-cols-2">
              <TextSection title="Response format"><StructuredEvidence value={result.configuration.responseFormat} /></TextSection>
              <TextSection title="Generation configuration"><StructuredEvidence value={result.configuration.generationConfig} /></TextSection>
            </div>
          </CardContent>
        </Card>

        <section id="observation-evidence" className="space-y-4" aria-labelledby="observation-heading">
          <div><p className="text-sm font-medium text-primary">Captured samples</p><h2 id="observation-heading" className="mt-1 text-2xl font-semibold tracking-tight">Observation and deterministic evidence</h2><p className="mt-2 text-sm leading-6 text-muted-foreground">Each response is shown as inert text, never interpreted as HTML. Shared-contract rules and case-specific expectations remain separately attributable to the individual case.</p></div>
          {result.observations.length === 0 ? (
            <Card id="observations-empty"><CardContent className="py-8 text-center text-sm text-muted-foreground">No observations have been captured yet.</CardContent></Card>
          ) : result.observations.map(observation => {
            const review = currentReview("observation", observation.id)
            return <ObservationCard key={observation.id} observation={observation} review={review} history={result.reviews.filter(item => item.reviewKey === `observation:${observation.id}`)} onReview={() => openReview("observation", observation.id, `${observation.case.name} · sample ${observation.sampleIndex + 1}`, "passed_but_should_have_failed")} onStartContractRevision={startContractRevision} onStartConfigurationSuccessor={startConfigurationSuccessor} processingReview={processingReview} />
          })}
        </section>

        <div className="rounded-2xl border bg-muted/20 p-4 text-xs leading-6 text-muted-foreground">
          Operational alert policy: latency requires more than {result.alertPolicy.latencyMultiplier}× the reviewed-reference maximum and +{formatNumber(result.alertPolicy.latencyMinimumDeltaMs)} ms; usage requires more than {result.alertPolicy.usageMultiplier}× the reviewed-reference maximum and +{formatNumber(result.alertPolicy.usageMinimumDeltaTokens)} tokens. These sampled thresholds are audit evidence, not a composite score or proof that failure probability increased.
        </div>
      </div>

      <Dialog open={Boolean(resolveAlert)} onOpenChange={open => !open && setResolveAlert(null)}>
        <DialogContent>
          <DialogHeader><DialogTitle>Resolve this reviewed alert?</DialogTitle><DialogDescription>Resolution pins the current structured judgment as its owner-approved basis. The alert, review history, and underlying evidence remain stored and visible.</DialogDescription></DialogHeader>
          {resolveAlert && <Alert><ShieldAlert /><AlertTitle>{resolveAlert.title}</AlertTitle><AlertDescription>{resolveAlert.explanation}</AlertDescription></Alert>}
          <DialogFooter><DialogClose asChild><Button variant="outline">Cancel</Button></DialogClose><Button id="confirm-resolve-alert" disabled={!resolveAlert || processingAlert !== null} onClick={() => resolveAlert && mutateAlert(resolveAlert, "resolve")}>{processingAlert ? <LoaderCircle className="animate-spin" /> : <LockKeyhole />} Record resolution</Button></DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(reviewSubject)} onOpenChange={open => !open && setReviewSubject(null)}>
        <DialogContent className="sm:max-w-xl">
          <DialogHeader>
            <DialogTitle>{reviewSubject?.current ? "Revise structured judgment" : "Record structured judgment"}</DialogTitle>
            <DialogDescription>{reviewSubject?.title}. A revision appends a new decision; it never edits the earlier judgment or captured evidence.</DialogDescription>
          </DialogHeader>
          <div className="space-y-5 py-2">
            <div className="space-y-2">
              <Label htmlFor="review-classification">Classification</Label>
              <Select value={reviewClassification} onValueChange={value => setReviewClassification(value as ReviewClassification)}>
                <SelectTrigger id="review-classification" className="w-full"><SelectValue /></SelectTrigger>
                <SelectContent>{classifications.map(option => <SelectItem key={option.value} value={option.value}>{option.label}</SelectItem>)}</SelectContent>
              </Select>
              <p className="text-xs leading-5 text-muted-foreground">{classifications.find(option => option.value === reviewClassification)?.description}</p>
            </div>
            <div className="space-y-2">
              <Label htmlFor="review-action">Resulting action</Label>
              <Select value={reviewAction} onValueChange={value => setReviewAction(value as ReviewAction)}>
                <SelectTrigger id="review-action" className="w-full"><SelectValue /></SelectTrigger>
                <SelectContent>{actions.map(option => <SelectItem key={option.value} value={option.value}>{option.label}</SelectItem>)}</SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="review-rationale">Rationale <span className="font-normal text-muted-foreground">(optional)</span></Label>
              <Textarea id="review-rationale" className="min-h-28" maxLength={2000} value={reviewRationale} onChange={event => setReviewRationale(event.target.value)} placeholder="What did you observe, and why did you choose this classification?" />
              <p className="text-right text-xs text-muted-foreground">{reviewRationale.length}/2,000</p>
            </div>
          </div>
          <DialogFooter>
            <DialogClose asChild><Button variant="outline">Cancel</Button></DialogClose>
            <Button id="submit-review-decision" disabled={!reviewSubject || processingReview} onClick={submitReview}>{processingReview ? <LoaderCircle className="animate-spin" /> : <MessageSquare />} {reviewSubject?.current ? "Append revised judgment" : "Record judgment"}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </ProductShell>
  )
}

function ProvenanceCard({ baseline, current, compatible, mismatches }: { baseline: Provenance | null; current: Provenance; compatible: boolean; mismatches: string[] }) {
  return (
    <Card id="run-provenance" className={compatible ? "border-success/20" : "border-destructive/30"}>
      <CardHeader><CardTitle className="flex items-center gap-2"><Fingerprint className="size-5 text-primary" /> Reviewed-reference provenance</CardTitle><CardDescription>{compatible ? "The pinned reviewed reference and this run share every comparison-critical identity." : "Comparison-critical identity differs; relative operational alert policies were skipped."}</CardDescription></CardHeader>
      <CardContent className="space-y-4">
        <div className="flex flex-wrap gap-2">{compatible ? <Badge variant="outline" className="border-success/30 text-success">Compatible</Badge> : mismatches.map(value => <Badge key={value} variant="destructive">{label(value)}</Badge>)}</div>
        <div className="grid gap-4 lg:grid-cols-2">
          <ProvenanceColumn title="Pinned reviewed reference" value={baseline} />
          <ProvenanceColumn title="Current run" value={current} />
        </div>
      </CardContent>
    </Card>
  )
}

function ProvenanceColumn({ title, value }: { title: string; value: Provenance | null }) {
  if (!value) return <div className="rounded-xl border border-dashed p-4"><p className="font-medium">{title}</p><p className="mt-3 text-sm text-muted-foreground">Unavailable</p></div>
  return (
    <div className="min-w-0 rounded-xl border bg-muted/20 p-4">
      <p className="font-medium">{title}</p>
      <dl className="mt-4 space-y-3 text-xs">
        <FingerprintRow name="Provider" value={`${value.provider} / ${value.requestedModel}`} />
        <FingerprintRow name="Monitor" value={value.monitorFingerprint} />
        <FingerprintRow name="Case set" value={value.caseSetFingerprint} />
        <FingerprintRow name="Contract snapshot" value={value.contractFingerprint} />
        <FingerprintRow name="Contract semantics" value={value.contractSemanticsFingerprint} />
        <FingerprintRow name="Evaluator" value={value.evaluatorEngineVersion} />
        <FingerprintRow name="Credential ID" value={value.providerCredentialId} />
      </dl>
    </div>
  )
}

function FingerprintRow({ name, value }: { name: string; value: string }) {
  return <div className="grid gap-1 sm:grid-cols-[7rem_1fr]"><dt className="text-muted-foreground">{name}</dt><dd className="break-all font-mono text-foreground" title={value}>{value.length > 40 ? shortId(value) : value}</dd></div>
}

function ObservationCard({ observation, review, history, onReview, onStartContractRevision, onStartConfigurationSuccessor, processingReview }: {
  observation: Observation
  review: ReviewDecision | null
  history: ReviewDecision[]
  onReview: () => void
  onStartContractRevision: (review: ReviewDecision) => void
  onStartConfigurationSuccessor: (review: ReviewDecision) => void
  processingReview: boolean
}) {
  const contractFailures = observation.evaluations.flatMap(evaluation => evaluation.ruleResults).filter(result => result.status !== "pass").length
  const expectationFailures = observation.evaluations.flatMap(evaluation => evaluation.caseExpectationResults.checks).filter(result => result.status !== "pass").length
  return (
    <Card id={`observation-${observation.id}`}>
      <CardHeader>
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div><p className="text-xs font-medium uppercase tracking-[0.14em] text-primary">{observation.case.key} · sample {observation.sampleIndex + 1}</p><CardTitle className="mt-2 text-xl">{observation.case.name}</CardTitle><CardDescription className="mt-2">{observation.requestedModel || "Model unavailable"} → {observation.returnedModel || "No returned model"}</CardDescription></div>
          <div className="flex flex-wrap gap-2"><RunStatusBadge status={observation.status} />{observation.completionState && <Badge variant="outline">{label(observation.completionState)}</Badge>}{contractFailures > 0 && <Badge variant="destructive">{contractFailures} contract issue{contractFailures === 1 ? "" : "s"}</Badge>}{expectationFailures > 0 && <Badge variant="destructive">{expectationFailures} expectation issue{expectationFailures === 1 ? "" : "s"}</Badge>}</div>
        </div>
      </CardHeader>
      <CardContent className="space-y-5">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Fact label="Tokens" value={`${formatNumber(observation.inputTokens || 0)} in · ${formatNumber(observation.outputTokens || 0)} out`} />
          <Fact label="Latency" value={observation.latencyMs === null ? "Unavailable" : `${formatNumber(observation.latencyMs)} ms`} />
          <Fact label="Finish reason" value={observation.finishReason || "Unavailable"} />
          <Fact label="Provider request" value={shortId(observation.providerRequestId)} />
        </div>

        {observation.failureMessage && <Alert variant="destructive"><CircleX /><AlertTitle>{label(observation.failureCategory || "provider failure")}</AlertTitle><AlertDescription><BoundedTextBlock value={observation.failureMessage} /></AlertDescription></Alert>}

        <div className="grid gap-5 lg:grid-cols-2">
          <TextSection title="Frozen context"><BoundedTextBlock value={observation.case.context} empty="No context supplied" /></TextSection>
          <TextSection title="Captured output"><BoundedTextBlock value={observation.output} empty="No output captured" /></TextSection>
        </div>
        <TextSection title="Input variables"><StructuredEvidence value={observation.case.inputVariables} /></TextSection>

        <div className="space-y-3">
          <h3 className="font-medium">Deterministic evaluations</h3>
          {observation.evaluations.length === 0 ? <p className="text-sm text-muted-foreground">No evaluation was recorded.</p> : observation.evaluations.map(evaluation => <EvaluationBlock key={evaluation.id} evaluation={evaluation} />)}
        </div>

        <div className="space-y-3 rounded-xl border border-primary/15 bg-primary/5 p-4">
          <ReviewStatus decision={review} history={history} />
          <div className="flex flex-wrap gap-2">
            <Button id={`review-observation-${observation.id}`} type="button" size="sm" variant="outline" disabled={processingReview} onClick={onReview}><MessageSquare /> {review ? "Revise judgment" : "Report missed regression"}</Button>
            {review?.action === "contract_revision" && <Button id={`start-contract-revision-${review.id}`} type="button" size="sm" variant="outline" disabled={processingReview} onClick={() => onStartContractRevision(review)}><GitBranch /> Start contract revision</Button>}
            {review && successorAction(review.action) && <Button id={`start-configuration-successor-${review.id}`} type="button" size="sm" variant="outline" disabled={processingReview} onClick={() => onStartConfigurationSuccessor(review)}><GitBranch /> Revise configuration</Button>}
          </div>
        </div>

        <details className="group rounded-xl border bg-muted/20 p-4">
          <summary className="flex cursor-pointer list-none items-center justify-between gap-3 text-sm font-medium">Provider attempts and allowlisted metadata <ChevronDown className="size-4 transition-transform group-open:rotate-180" /></summary>
          <div className="mt-4 grid gap-4 lg:grid-cols-2">
            <StructuredEvidence value={observation.attempts} />
            <StructuredEvidence value={observation.providerMetadata} />
          </div>
        </details>
      </CardContent>
    </Card>
  )
}

function successorAction(action: ReviewAction) {
  return ["prompt_change", "case_change", "provider_change"].includes(action)
}

function ReviewStatus({ decision, history }: { decision: ReviewDecision | null; history: ReviewDecision[] }) {
  if (!decision) {
    return <div className="flex items-start gap-3 rounded-lg border border-dashed p-3"><MessageSquare className="mt-0.5 size-4 text-muted-foreground" /><div><p className="text-sm font-medium">No structured judgment yet</p><p className="mt-1 text-xs leading-5 text-muted-foreground">Recording one adds attributable review evidence without changing the run.</p></div></div>
  }

  return (
    <div className="rounded-lg border bg-background/80 p-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="secondary">{label(decision.classification)}</Badge>
        <Badge variant="outline">Action: {label(decision.action)}</Badge>
        {history.length > 1 && <Badge variant="outline"><History /> {history.length} decisions</Badge>}
      </div>
      {decision.rationale && <div className="mt-3"><BoundedTextBlock value={decision.rationale} /></div>}
      <p className="mt-2 text-xs text-muted-foreground">Current judgment by {decision.reviewedBy || "workspace reviewer"} · {formatUtc(decision.reviewedAt)}</p>
      {history.length > 1 && (
        <details className="group mt-3 border-t pt-3">
          <summary className="flex cursor-pointer list-none items-center gap-2 text-xs font-medium text-primary"><History className="size-3.5" /> Inspect append-only judgment history</summary>
          <ol className="mt-3 space-y-2">
            {history.map(item => <li key={item.id} className="rounded-md bg-muted/40 p-3 text-xs"><div className="flex flex-wrap gap-2"><span className="font-medium">{label(item.classification)}</span><span className="text-muted-foreground">{label(item.action)}</span>{item.current && <span className="text-primary">Current</span>}</div><p className="mt-1 text-muted-foreground">{item.reviewedBy || "Workspace reviewer"} · {formatUtc(item.reviewedAt)}</p>{item.rationale && <p className="mt-2 whitespace-pre-wrap break-words leading-5">{item.rationale.text}</p>}</li>)}
          </ol>
        </details>
      )}
    </div>
  )
}

function EvaluationBlock({ evaluation }: { evaluation: Evaluation }) {
  return (
    <div className="rounded-xl border p-4">
      <div className="flex flex-wrap items-center justify-between gap-3"><div><p className="font-medium">Deterministic evaluation</p><p className="mt-1 text-xs text-muted-foreground">Engine {evaluation.evaluatorEngineVersion} · {formatUtc(evaluation.evaluatedAt)}</p></div><div className="flex flex-wrap gap-2"><Badge variant="outline">Overall: {label(evaluation.status)}</Badge><Badge variant="outline">Contract: {label(evaluation.contractStatus)}</Badge><Badge variant="outline">Case: {label(evaluation.caseExpectationStatus)}</Badge></div></div>
      {evaluation.error && <div className="mt-4"><StructuredEvidence value={evaluation.error} /></div>}
      <div className="mt-4 grid gap-4 xl:grid-cols-2">
        <section className="space-y-3 rounded-xl border bg-muted/15 p-4">
          <div><h4 className="font-medium">Shared contract</h4><p className="mt-1 text-xs text-muted-foreground">Root <span className="font-mono">{evaluation.rootRuleId}</span> · fingerprint {shortId(evaluation.contractFingerprint)}</p></div>
          {evaluation.ruleResults.map(rule => (
            <div key={rule.id} className="rounded-lg bg-background p-4">
              <div className="flex flex-wrap items-center gap-2"><Badge variant="outline" className="font-mono">{rule.ruleId}</Badge><Badge variant="secondary">{label(rule.ruleType)}</Badge><SeverityBadge severity={rule.severity} /><RunStatusBadge status={rule.status} /></div>
              <p className="mt-3 text-sm leading-6">{rule.explanation}</p>
              {rule.evidence !== null && <details className="group mt-3"><summary className="cursor-pointer text-xs font-medium text-primary">Inspect contract evidence</summary><div className="mt-3"><StructuredEvidence value={rule.evidence} /></div></details>}
            </div>
          ))}
        </section>
        <section className="space-y-3 rounded-xl border border-primary/15 bg-primary/5 p-4">
          <div><h4 className="font-medium">Case-specific expectation</h4><p className="mt-1 break-all text-xs text-muted-foreground">{label(evaluation.caseExpectationSchemaVersion)} · fingerprint {shortId(evaluation.caseExpectationFingerprint)}</p></div>
          {evaluation.caseExpectationStatus === "not_configured" ? (
            <p className="rounded-lg border border-dashed bg-background p-4 text-sm text-muted-foreground">This immutable case explicitly has no case-specific expectation.</p>
          ) : evaluation.caseExpectationResults.checks.map(check => (
            <div key={check.checkId} className="rounded-lg bg-background p-4">
              <div className="flex flex-wrap items-center gap-2"><Badge variant="outline" className="font-mono">{check.checkId}</Badge><Badge variant="secondary">{label(check.checkType)}</Badge><RunStatusBadge status={check.status} /></div>
              <p className="mt-3 text-sm leading-6">{check.explanation}</p>
              {check.evidence !== null && <details className="group mt-3"><summary className="cursor-pointer text-xs font-medium text-primary">Inspect expectation evidence</summary><div className="mt-3"><StructuredEvidence value={check.evidence} /></div></details>}
            </div>
          ))}
          {evaluation.caseExpectationError && <StructuredEvidence value={evaluation.caseExpectationError} />}
        </section>
      </div>
    </div>
  )
}

function TextSection({ title, children }: { title: string; children: ReactNode }) {
  return <section className="min-w-0 space-y-2"><h3 className="text-sm font-medium">{title}</h3>{children}</section>
}

function Fact({ label: factLabel, value, tone = "default" }: { label: string; value: string; tone?: "default" | "danger" }) {
  return <div className="min-w-0 rounded-xl border bg-background/70 p-4"><p className="text-xs text-muted-foreground">{factLabel}</p><p className={`mt-2 break-words text-sm font-medium ${tone === "danger" ? "text-destructive" : ""}`}>{value}</p></div>
}

export default function RunPage() {
  const { props } = usePage<RunProps & SharedPageProps>()
  return <><Head title={`Run evidence · ${props.monitor.name}`} /><RunView {...props} /></>
}
