import { Head, Link, usePage } from "@inertiajs/react"
import {
  Activity,
  AlertTriangle,
  ArrowLeft,
  BellRing,
  CheckCircle2,
  Clock3,
  ExternalLink,
  History,
  ShieldAlert,
  ShieldCheck,
} from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import {
  AlertStatusBadge,
  CategoryBadge,
  formatNumber,
  formatUtc,
  Metric,
  RunStatusBadge,
  SeverityBadge,
} from "@/components/result-evidence"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import type { SharedPageProps } from "@/types/page"
import type { ResultAlert, ResultMonitor, RunSummary } from "@/types/results"

export type ResultsProps = {
  auth: SharedPageProps["auth"]
  alerts: ResultAlert[]
  canResolve: boolean
  currentBaseline: {
    id: string
    status: string
    approvalMode: string
    approvedAt: string
    provider: "openai" | "anthropic"
    requestedModel: string
    monitorFingerprint: string
    contractFingerprint: string
  } | null
  monitor: ResultMonitor
  releaseStage: string
  runs: RunSummary[]
}

export function ResultsView({
  alerts,
  auth,
  currentBaseline,
  monitor,
  releaseStage,
  runs,
}: ResultsProps & { flash?: SharedPageProps["flash"] }) {
  const workspace = auth.workspace
  if (!workspace) return null

  const monitorPath = `/app/${workspace.slug}/monitors/${monitor.id}`
  const unresolved = alerts.filter(alert => alert.status !== "resolved")
  const critical = unresolved.filter(alert => alert.severity === "critical").length
  const latest = runs[0] || null

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
              <Link href={`${monitorPath}/operations`}><ArrowLeft /> Monitor operations</Link>
            </Button>
            <div className="flex flex-wrap items-center gap-2">
              <Badge variant="outline">Configuration v{monitor.version || "—"}</Badge>
              <Badge variant="secondary" className="capitalize">{monitor.state.replaceAll("_", " ")}</Badge>
            </div>
          </div>
          <div className="grid gap-5 lg:grid-cols-[1fr_auto] lg:items-end">
            <div className="max-w-3xl">
              <p className="text-sm font-medium text-primary">{monitor.name}</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Runs, evidence, and actionable alerts</h1>
              <p className="mt-3 text-base leading-7 text-muted-foreground">
                Inspect sampled outcomes against the pinned reviewed reference. Shared-contract failures, case-specific mismatches, and operational anomalies remain separate; a passing run is evidence for its exact executions, not universal model health.
              </p>
            </div>
            <Button asChild variant="outline">
              <Link href={`/app/${workspace.slug}/alerts`}><BellRing /> Workspace alerts</Link>
            </Button>
          </div>
        </header>

        {!currentBaseline && (
          <Alert id="results-baseline-missing" variant="destructive">
            <ShieldAlert />
            <AlertTitle>No current approved reviewed reference</AlertTitle>
            <AlertDescription>Historical evidence remains visible, but new reference-relative operational comparisons must not run until exact provenance compatibility is restored.</AlertDescription>
          </Alert>
        )}

        <section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4" aria-label="Result summary">
          <Metric label="Monitoring runs" value={runs.length} detail="Latest 25 manual and scheduled runs" />
          <Metric label="Unresolved alerts" value={unresolved.length} detail={critical > 0 ? `${critical} critical` : "No critical alerts"} tone={unresolved.length > 0 ? "warning" : "success"} />
          <Metric label="Latest outcome" value={latest ? latest.status.replaceAll("_", " ") : "No runs"} detail={latest ? formatUtc(latest.completedAt || latest.insertedAt) : "Run the active monitor to begin"} />
          <Metric label="Pinned reviewed reference" value={currentBaseline ? "Available" : "Unavailable"} detail={currentBaseline ? `${currentBaseline.provider} · ${currentBaseline.requestedModel}` : "Operational comparisons are blocked"} tone={currentBaseline ? "success" : "danger"} />
        </section>

        <section aria-labelledby="monitor-alerts-heading" className="space-y-4">
          <div className="flex flex-wrap items-end justify-between gap-3">
            <div>
              <p className="text-sm font-medium text-primary">Action queue</p>
              <h2 id="monitor-alerts-heading" className="mt-1 text-2xl font-semibold tracking-tight">Unresolved monitor alerts</h2>
            </div>
            {unresolved.length === 0 && <Badge variant="outline" className="border-success/30 text-success"><CheckCircle2 /> Clear</Badge>}
          </div>

          {unresolved.length === 0 ? (
            <Card id="monitor-no-alerts" className="border-success/20 bg-success/5">
              <CardContent className="flex gap-3 py-6">
                <ShieldCheck className="mt-0.5 size-5 text-success" />
                <div>
                  <p className="font-medium">No unresolved alerts</p>
                  <p className="mt-1 text-sm leading-6 text-muted-foreground">Completed runs have no open or acknowledged action items.</p>
                </div>
              </CardContent>
            </Card>
          ) : (
            <div id="monitor-alerts" className="grid gap-4 lg:grid-cols-2">
              {unresolved.map(alert => (
                <Card key={alert.id} id={`alert-${alert.id}`} className={alert.severity === "critical" ? "border-destructive/30" : "border-amber-500/30"}>
                  <CardHeader>
                    <div className="flex flex-wrap gap-2">
                      <SeverityBadge severity={alert.severity} />
                      <CategoryBadge category={alert.category} />
                      <AlertStatusBadge status={alert.status} />
                    </div>
                    <CardTitle className="pt-2 text-xl">{alert.title}</CardTitle>
                    <CardDescription className="leading-6">{alert.explanation}</CardDescription>
                  </CardHeader>
                  <CardContent className="flex flex-wrap items-center justify-between gap-3">
                    <p className="text-xs text-muted-foreground">Opened {formatUtc(alert.openedAt)}</p>
                    {alert.run && (
                      <Button asChild size="sm">
                        <Link href={`${monitorPath}/runs/${alert.run.id}`}>Inspect evidence <ExternalLink /></Link>
                      </Button>
                    )}
                  </CardContent>
                </Card>
              ))}
            </div>
          )}
        </section>

        <Card id="run-history">
          <CardHeader>
            <div className="flex items-center gap-3">
              <span className="grid size-10 place-items-center rounded-xl bg-primary/10 text-primary"><History className="size-5" /></span>
              <div>
                <CardTitle>Run history</CardTitle>
                <CardDescription>Explicit calls, completion, deterministic outcomes, and alert counts.</CardDescription>
              </div>
            </div>
          </CardHeader>
          <CardContent>
            {runs.length === 0 ? (
              <div id="run-history-empty" className="rounded-xl border border-dashed p-8 text-center">
                <Activity className="mx-auto size-7 text-muted-foreground" />
                <p className="mt-3 font-medium">No monitoring runs yet</p>
                <p className="mt-1 text-sm text-muted-foreground">Activate the monitor or run it on demand from operations.</p>
              </div>
            ) : (
              <>
                <div className="hidden overflow-x-auto md:block">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Run</TableHead>
                        <TableHead>Outcome</TableHead>
                        <TableHead>Calls</TableHead>
                        <TableHead>Completions</TableHead>
                        <TableHead>Shared contract</TableHead>
                        <TableHead>Case expectation</TableHead>
                        <TableHead>Alerts</TableHead>
                        <TableHead className="text-right">Evidence</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {runs.map(run => (
                        <TableRow key={run.id}>
                          <TableCell>
                            <p className="font-medium capitalize">{run.kind}</p>
                            <p className="mt-1 text-xs text-muted-foreground">{formatUtc(run.completedAt || run.insertedAt)}</p>
                          </TableCell>
                          <TableCell><RunStatusBadge status={run.status} /></TableCell>
                          <TableCell className="tabular-nums">{run.actualCallCount}/{run.maximumCallCount}</TableCell>
                          <TableCell className="tabular-nums">{run.completionCounts.complete || 0}/{run.plannedCallCount}</TableCell>
                          <TableCell className="tabular-nums">{run.contractEvaluationCounts.fail || 0} failed</TableCell>
                          <TableCell className="tabular-nums">{run.caseExpectationCounts.fail || 0} failed</TableCell>
                          <TableCell className="tabular-nums">{run.criticalAlertCount} critical · {run.warningAlertCount} warning</TableCell>
                          <TableCell className="text-right"><Button asChild size="sm" variant="outline"><Link href={`${monitorPath}/runs/${run.id}`}>Open</Link></Button></TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>

                <div className="grid gap-3 md:hidden">
                  {runs.map(run => (
                    <div key={run.id} className="rounded-xl border p-4">
                      <div className="flex items-start justify-between gap-3">
                        <div>
                          <p className="font-medium capitalize">{run.kind} run</p>
                          <p className="mt-1 text-xs text-muted-foreground">{formatUtc(run.completedAt || run.insertedAt)}</p>
                        </div>
                        <RunStatusBadge status={run.status} />
                      </div>
                      <div className="mt-4 grid grid-cols-2 gap-3 text-xs text-muted-foreground">
                        <p>Calls <span className="block text-sm font-medium text-foreground">{run.actualCallCount}/{run.maximumCallCount}</span></p>
                        <p>Complete <span className="block text-sm font-medium text-foreground">{run.completionCounts.complete || 0}/{run.plannedCallCount}</span></p>
                        <p>Shared-contract failures <span className="block text-sm font-medium text-foreground">{run.contractEvaluationCounts.fail || 0}</span></p>
                        <p>Case mismatches <span className="block text-sm font-medium text-foreground">{run.caseExpectationCounts.fail || 0}</span></p>
                        <p>Alerts <span className="block text-sm font-medium text-foreground">{run.criticalAlertCount + run.warningAlertCount}</span></p>
                      </div>
                      <Button asChild className="mt-4 w-full" variant="outline"><Link href={`${monitorPath}/runs/${run.id}`}>Inspect evidence</Link></Button>
                    </div>
                  ))}
                </div>
              </>
            )}
          </CardContent>
        </Card>

        {latest && (
          <p className="text-center text-xs text-muted-foreground">
            Latest run used {formatNumber(latest.inputTokens)} input tokens, {formatNumber(latest.outputTokens)} output tokens, and {formatNumber(latest.latencyMs)} ms cumulative successful-call latency.
          </p>
        )}
      </div>
    </ProductShell>
  )
}

export default function ResultsPage() {
  const { props } = usePage<ResultsProps & SharedPageProps>()
  return <><Head title={`Results · ${props.monitor.name}`} /><ResultsView {...props} /></>
}
