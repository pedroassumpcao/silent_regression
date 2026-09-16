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
  LoaderCircle,
  LockKeyhole,
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
import type { SharedPageProps } from "@/types/page"
import type { Evaluation, Observation, Provenance, ResultAlert, ResultMonitor, RunDetail } from "@/types/results"

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
  if (!workspace) return null

  const summary = result.summary
  const resultsPath = `/app/${workspace.slug}/monitors/${monitor.id}/results`
  const alertsPath = `/app/${workspace.slug}/alerts`
  const runPath = `/app/${workspace.slug}/monitors/${monitor.id}/runs/${summary.id}`
  const terminal = !["planned", "queued", "running"].includes(summary.status)
  const contractFailures = summary.evaluationCounts.fail || 0
  const complete = summary.completionCounts.complete || 0

  const mutateAlert = (alert: ResultAlert, action: "acknowledge" | "resolve") => {
    setProcessingAlert(alert.id)
    router.post(`/app/${workspace.slug}/alerts/${alert.id}/${action}`, {}, {
      preserveScroll: true,
      onSuccess: () => setResolveAlert(null),
      onFinish: () => setProcessingAlert(null),
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
              <p className="mt-3 text-base leading-7 text-muted-foreground">Review completion, deterministic contract outcomes, operational anomalies, and each captured response. The product does not collapse these distinct facts into one quality number.</p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Button asChild variant="outline"><Link href={alertsPath}>Workspace alerts</Link></Button>
              <Button asChild variant="outline"><a href={`${runPath}/diagnostic`}><Download /> Redacted diagnostic</a></Button>
            </div>
          </div>
        </header>

        {flash.info && <Alert id="run-success" className="border-success/25 bg-success/5"><CheckCircle2 /><AlertTitle>Alert lifecycle updated</AlertTitle><AlertDescription>{flash.info}</AlertDescription></Alert>}
        {flash.error && <Alert id="run-error" variant="destructive"><AlertTriangle /><AlertTitle>Alert lifecycle unchanged</AlertTitle><AlertDescription>{flash.error}</AlertDescription></Alert>}

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
            <AlertTitle>Baseline provenance does not match this run</AlertTitle>
            <AlertDescription>
              Baseline-relative latency and usage findings were deliberately skipped. Mismatches: {result.provenance.mismatches.map(label).join(", ") || "baseline unavailable"}.
            </AlertDescription>
          </Alert>
        )}

        <section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4" aria-label="Run summary">
          <Metric label="Provider calls" value={`${summary.actualCallCount}/${summary.maximumCallCount}`} detail={`${summary.plannedCallCount} planned; retry ceiling included`} />
          <Metric label="Complete responses" value={`${complete}/${summary.plannedCallCount}`} detail={`${summary.providerFailureCount} provider failure${summary.providerFailureCount === 1 ? "" : "s"}`} tone={complete === summary.plannedCallCount ? "success" : "warning"} />
          <Metric label="Contract failures" value={contractFailures} detail={`${summary.evaluationCounts.evaluator_error || 0} evaluator errors`} tone={contractFailures > 0 ? "danger" : "success"} />
          <Metric label="Run alerts" value={summary.criticalAlertCount + summary.warningAlertCount} detail={`${summary.criticalAlertCount} critical · ${summary.warningAlertCount} warning`} tone={summary.criticalAlertCount > 0 ? "danger" : summary.warningAlertCount > 0 ? "warning" : "success"} />
        </section>

        <section id="run-alerts" className="space-y-4" aria-labelledby="run-alerts-heading">
          <div className="flex flex-wrap items-end justify-between gap-3">
            <div><p className="text-sm font-medium text-primary">Action queue</p><h2 id="run-alerts-heading" className="mt-1 text-2xl font-semibold tracking-tight">Alerts from this run</h2></div>
            <p className="max-w-lg text-right text-xs leading-5 text-muted-foreground">Any member can acknowledge. Only owners can resolve, and only after acknowledgement. Evidence is immutable in every state.</p>
          </div>

          {result.alerts.length === 0 ? (
            <Card id="run-alerts-empty" className="border-success/20 bg-success/5"><CardContent className="flex gap-3 py-6"><CheckCircle2 className="mt-0.5 size-5 text-success" /><div><p className="font-medium">No alerts derived from this run</p><p className="mt-1 text-sm leading-6 text-muted-foreground">The absence of alerts does not hide the underlying output and rule-level evidence below.</p></div></CardContent></Card>
          ) : (
            <div className="grid gap-4 lg:grid-cols-2">
              {result.alerts.map(alert => (
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
                    <div className="flex flex-wrap items-center justify-between gap-3">
                      <p className="text-xs text-muted-foreground">{alert.status === "resolved" ? `Resolved ${formatUtc(alert.resolvedAt)}` : alert.status === "acknowledged" ? `Acknowledged ${formatUtc(alert.acknowledgedAt)}` : `Opened ${formatUtc(alert.openedAt)}`}</p>
                      <div className="flex flex-wrap gap-2">
                        {alert.status === "open" && <Button id={`acknowledge-alert-${alert.id}`} size="sm" disabled={processingAlert !== null} onClick={() => mutateAlert(alert, "acknowledge")}>{processingAlert === alert.id ? <LoaderCircle className="animate-spin" /> : <FileCheck2 />} Acknowledge</Button>}
                        {alert.status === "acknowledged" && canResolve && <Button id={`resolve-alert-${alert.id}`} size="sm" disabled={processingAlert !== null} onClick={() => setResolveAlert(alert)}><LockKeyhole /> Resolve</Button>}
                        {alert.status === "acknowledged" && !canResolve && <Badge variant="outline">Owner resolution required</Badge>}
                      </div>
                    </div>
                  </CardContent>
                </Card>
              ))}
            </div>
          )}
        </section>

        <Card id="run-operational-evidence">
          <CardHeader><CardTitle className="flex items-center gap-2"><Gauge className="size-5 text-primary" /> Operational evidence</CardTitle><CardDescription>Provider identity, completion, usage, and latency remain separate from deterministic contract judgments.</CardDescription></CardHeader>
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
          <div><p className="text-sm font-medium text-primary">Captured samples</p><h2 id="observation-heading" className="mt-1 text-2xl font-semibold tracking-tight">Observation and rule-level evidence</h2><p className="mt-2 text-sm leading-6 text-muted-foreground">Each response is shown as inert text, never interpreted as HTML. Provider attempts and deterministic evaluations remain attributable to the individual case.</p></div>
          {result.observations.length === 0 ? (
            <Card id="observations-empty"><CardContent className="py-8 text-center text-sm text-muted-foreground">No observations have been captured yet.</CardContent></Card>
          ) : result.observations.map(observation => <ObservationCard key={observation.id} observation={observation} />)}
        </section>

        <div className="rounded-2xl border bg-muted/20 p-4 text-xs leading-6 text-muted-foreground">
          Alert policy: latency requires more than {result.alertPolicy.latencyMultiplier}× baseline and +{formatNumber(result.alertPolicy.latencyMinimumDeltaMs)} ms; usage requires more than {result.alertPolicy.usageMultiplier}× baseline and +{formatNumber(result.alertPolicy.usageMinimumDeltaTokens)} tokens. Thresholds are shown for auditability, not presented as a composite score.
        </div>
      </div>

      <Dialog open={Boolean(resolveAlert)} onOpenChange={open => !open && setResolveAlert(null)}>
        <DialogContent>
          <DialogHeader><DialogTitle>Resolve this acknowledged alert?</DialogTitle><DialogDescription>Resolution records an owner decision. The alert, timestamps, derived evidence, and underlying run evidence remain stored and visible.</DialogDescription></DialogHeader>
          {resolveAlert && <Alert><ShieldAlert /><AlertTitle>{resolveAlert.title}</AlertTitle><AlertDescription>{resolveAlert.explanation}</AlertDescription></Alert>}
          <DialogFooter><DialogClose asChild><Button variant="outline">Cancel</Button></DialogClose><Button id="confirm-resolve-alert" disabled={!resolveAlert || processingAlert !== null} onClick={() => resolveAlert && mutateAlert(resolveAlert, "resolve")}>{processingAlert ? <LoaderCircle className="animate-spin" /> : <LockKeyhole />} Record resolution</Button></DialogFooter>
        </DialogContent>
      </Dialog>
    </ProductShell>
  )
}

function ProvenanceCard({ baseline, current, compatible, mismatches }: { baseline: Provenance | null; current: Provenance; compatible: boolean; mismatches: string[] }) {
  return (
    <Card id="run-provenance" className={compatible ? "border-success/20" : "border-destructive/30"}>
      <CardHeader><CardTitle className="flex items-center gap-2"><Fingerprint className="size-5 text-primary" /> Baseline provenance</CardTitle><CardDescription>{compatible ? "The pinned baseline and this run share every comparison-critical identity." : "Comparison-critical identity differs; relative alert policies were skipped."}</CardDescription></CardHeader>
      <CardContent className="space-y-4">
        <div className="flex flex-wrap gap-2">{compatible ? <Badge variant="outline" className="border-success/30 text-success">Compatible</Badge> : mismatches.map(value => <Badge key={value} variant="destructive">{label(value)}</Badge>)}</div>
        <div className="grid gap-4 lg:grid-cols-2">
          <ProvenanceColumn title="Pinned baseline" value={baseline} />
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
        <FingerprintRow name="Contract" value={value.contractFingerprint} />
        <FingerprintRow name="Evaluator" value={value.evaluatorEngineVersion} />
        <FingerprintRow name="Credential ID" value={value.providerCredentialId} />
      </dl>
    </div>
  )
}

function FingerprintRow({ name, value }: { name: string; value: string }) {
  return <div className="grid gap-1 sm:grid-cols-[7rem_1fr]"><dt className="text-muted-foreground">{name}</dt><dd className="break-all font-mono text-foreground" title={value}>{value.length > 40 ? shortId(value) : value}</dd></div>
}

function ObservationCard({ observation }: { observation: Observation }) {
  const failures = observation.evaluations.flatMap(evaluation => evaluation.ruleResults).filter(result => result.status !== "pass").length
  return (
    <Card id={`observation-${observation.id}`}>
      <CardHeader>
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div><p className="text-xs font-medium uppercase tracking-[0.14em] text-primary">{observation.case.key} · sample {observation.sampleIndex + 1}</p><CardTitle className="mt-2 text-xl">{observation.case.name}</CardTitle><CardDescription className="mt-2">{observation.requestedModel || "Model unavailable"} → {observation.returnedModel || "No returned model"}</CardDescription></div>
          <div className="flex flex-wrap gap-2"><RunStatusBadge status={observation.status} />{observation.completionState && <Badge variant="outline">{label(observation.completionState)}</Badge>}{failures > 0 && <Badge variant="destructive">{failures} rule issue{failures === 1 ? "" : "s"}</Badge>}</div>
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

function EvaluationBlock({ evaluation }: { evaluation: Evaluation }) {
  return (
    <div className="rounded-xl border p-4">
      <div className="flex flex-wrap items-center justify-between gap-3"><div><p className="font-medium">Root rule: <span className="font-mono text-sm">{evaluation.rootRuleId}</span></p><p className="mt-1 text-xs text-muted-foreground">Engine {evaluation.evaluatorEngineVersion} · {formatUtc(evaluation.evaluatedAt)}</p></div><RunStatusBadge status={evaluation.status} /></div>
      {evaluation.error && <div className="mt-4"><StructuredEvidence value={evaluation.error} /></div>}
      <div className="mt-4 space-y-3">
        {evaluation.ruleResults.map(rule => (
          <div key={rule.id} className="rounded-lg bg-muted/35 p-4">
            <div className="flex flex-wrap items-center gap-2"><Badge variant="outline" className="font-mono">{rule.ruleId}</Badge><Badge variant="secondary">{label(rule.ruleType)}</Badge><SeverityBadge severity={rule.severity} /><RunStatusBadge status={rule.status} /></div>
            <p className="mt-3 text-sm leading-6">{rule.explanation}</p>
            {rule.evidence !== null && <details className="group mt-3"><summary className="cursor-pointer text-xs font-medium text-primary">Inspect rule evidence</summary><div className="mt-3"><StructuredEvidence value={rule.evidence} /></div></details>}
          </div>
        ))}
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
