import { Head, Link, usePage } from "@inertiajs/react"
import { BellRing, CheckCircle2, ExternalLink, ShieldAlert } from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import {
  AlertStatusBadge,
  CategoryBadge,
  formatUtc,
  SeverityBadge,
} from "@/components/result-evidence"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import type { SharedPageProps } from "@/types/page"
import type { ResultAlert } from "@/types/results"

export type AlertsProps = {
  auth: SharedPageProps["auth"]
  alerts: ResultAlert[]
  canResolve: boolean
  releaseStage: string
}

export function AlertsView({ alerts, auth, canResolve, releaseStage }: AlertsProps) {
  const workspace = auth.workspace
  if (!workspace) return null

  const unresolved = alerts.filter(alert => alert.status !== "resolved")
  const critical = unresolved.filter(alert => alert.severity === "critical").length
  const acknowledged = unresolved.filter(alert => alert.status === "acknowledged").length

  return (
    <ProductShell
      availableWorkspaces={auth.workspaces}
      currentSection="alerts"
      membershipRole={auth.membership?.role || "member"}
      releaseStage={releaseStage}
      userEmail={auth.user?.email || "Invited user"}
      workspace={workspace}
    >
      <div className="mx-auto max-w-6xl space-y-7">
        <header className="grid gap-5 lg:grid-cols-[1fr_auto] lg:items-end">
          <div className="max-w-3xl">
            <p className="text-sm font-medium text-primary">Workspace action queue</p>
            <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Alerts tied to immutable run evidence</h1>
            <p className="mt-3 text-base leading-7 text-muted-foreground">
              Contract failures and operational anomalies stay distinct. Acknowledgement records that someone is investigating; resolution is an owner decision and never rewrites the captured evidence.
            </p>
          </div>
          <Badge variant="outline" className="w-fit">{canResolve ? "Owner lifecycle access" : "Member acknowledgement access"}</Badge>
        </header>

        <section className="grid gap-4 sm:grid-cols-3" aria-label="Alert summary">
          <SummaryCard label="Unresolved" value={unresolved.length} detail="Open and acknowledged" tone={unresolved.length > 0 ? "warning" : "success"} />
          <SummaryCard label="Critical" value={critical} detail="Deterministic or blocking" tone={critical > 0 ? "danger" : "success"} />
          <SummaryCard label="Acknowledged" value={acknowledged} detail="Investigation recorded" />
        </section>

        {alerts.length === 0 ? (
          <Card id="alerts-empty" className="border-success/20 bg-success/5">
            <CardContent className="flex flex-col items-center px-6 py-12 text-center">
              <span className="grid size-12 place-items-center rounded-2xl bg-success/10 text-success"><CheckCircle2 /></span>
              <h2 className="mt-4 text-xl font-semibold">No alerts have been opened</h2>
              <p className="mt-2 max-w-lg text-sm leading-6 text-muted-foreground">When a completed monitoring run produces a contract failure or explicit operational anomaly, it will appear here with a direct evidence trail.</p>
            </CardContent>
          </Card>
        ) : (
          <section id="workspace-alerts" className="space-y-4" aria-labelledby="workspace-alerts-heading">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <h2 id="workspace-alerts-heading" className="text-2xl font-semibold tracking-tight">Latest alerts</h2>
              <p className="text-xs text-muted-foreground">Showing up to 100, unresolved first</p>
            </div>
            <div className="grid gap-4 lg:grid-cols-2">
              {alerts.map(alert => {
                const runPath = alert.monitor && alert.run
                  ? `/app/${workspace.slug}/monitors/${alert.monitor.id}/runs/${alert.run.id}`
                  : null

                return (
                  <Card key={alert.id} id={`alert-${alert.id}`} className={alert.status === "resolved" ? "opacity-75" : alert.severity === "critical" ? "border-destructive/30" : "border-amber-500/30"}>
                    <CardHeader>
                      <div className="flex flex-wrap gap-2">
                        <SeverityBadge severity={alert.severity} />
                        <CategoryBadge category={alert.category} />
                        <AlertStatusBadge status={alert.status} />
                      </div>
                      <CardTitle className="pt-2 text-xl">{alert.title}</CardTitle>
                      <CardDescription className="leading-6">{alert.explanation}</CardDescription>
                    </CardHeader>
                    <CardContent className="space-y-4">
                      <div className="grid gap-3 rounded-xl border bg-muted/20 p-4 text-xs sm:grid-cols-2">
                        <div><p className="text-muted-foreground">Monitor</p><p className="mt-1 font-medium">{alert.monitor?.name || "Unavailable"}</p></div>
                        <div><p className="text-muted-foreground">Opened</p><p className="mt-1 font-medium">{formatUtc(alert.openedAt)}</p></div>
                      </div>
                      <div className="flex flex-wrap items-center justify-between gap-3">
                        <p className="text-xs text-muted-foreground">
                          {alert.status === "resolved"
                            ? `Resolved${alert.resolvedBy ? ` by ${alert.resolvedBy}` : ""}`
                            : alert.status === "acknowledged"
                              ? `Acknowledged${alert.acknowledgedBy ? ` by ${alert.acknowledgedBy}` : ""}`
                              : "Awaiting acknowledgement"}
                        </p>
                        {runPath && <Button asChild size="sm"><Link href={runPath}>Inspect evidence <ExternalLink /></Link></Button>}
                      </div>
                    </CardContent>
                  </Card>
                )
              })}
            </div>
          </section>
        )}

        <div className="flex items-start gap-3 rounded-2xl border bg-muted/20 p-4 text-sm text-muted-foreground">
          <ShieldAlert className="mt-0.5 size-4 shrink-0 text-primary" />
          <p>Alerts are derived only after a run reaches a terminal state. They are synchronized idempotently, so worker retries cannot duplicate an action item.</p>
        </div>
      </div>
    </ProductShell>
  )
}

function SummaryCard({ label, value, detail, tone = "default" }: { label: string; value: number; detail: string; tone?: "default" | "success" | "warning" | "danger" }) {
  const Icon = tone === "success" ? CheckCircle2 : tone === "default" ? BellRing : ShieldAlert
  const color = tone === "success" ? "text-success" : tone === "warning" ? "text-amber-700 dark:text-amber-300" : tone === "danger" ? "text-destructive" : "text-foreground"
  return (
    <Card>
      <CardContent className="flex items-start justify-between gap-4 p-5">
        <div><p className="text-xs uppercase tracking-[0.14em] text-muted-foreground">{label}</p><p className={`mt-2 text-3xl font-semibold ${color}`}>{value}</p><p className="mt-1 text-xs text-muted-foreground">{detail}</p></div>
        <span className="grid size-10 place-items-center rounded-xl bg-muted text-muted-foreground"><Icon className="size-5" /></span>
      </CardContent>
    </Card>
  )
}

export default function AlertsPage() {
  const { props } = usePage<AlertsProps & SharedPageProps>()
  return <><Head title="Alerts" /><AlertsView {...props} /></>
}
