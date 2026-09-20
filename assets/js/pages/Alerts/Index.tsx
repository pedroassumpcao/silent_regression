import { Head, Link, usePage } from "@inertiajs/react"
import { BellRing, CheckCircle2, ExternalLink, History, ShieldAlert } from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { AlertStatusBadge, CategoryBadge, formatNumber, formatUtc, SeverityBadge } from "@/components/result-evidence"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import type { SharedPageProps } from "@/types/page"
import type { IncidentSummary, Pagination } from "@/types/results"

export type AlertsProps = {
  auth: SharedPageProps["auth"]
  incidents: IncidentSummary[]
  counts: Partial<Record<"open" | "acknowledged" | "resolved" | "recovered", number>>
  pagination: Pagination
  canResolve: boolean
  releaseStage: string
}

export function AlertsView({ auth, canResolve, counts, incidents, pagination, releaseStage }: AlertsProps) {
  const workspace = auth.workspace
  if (!workspace) return null

  const unresolved = (counts.open || 0) + (counts.acknowledged || 0)
  const critical = incidents.filter(incident => ["open", "acknowledged"].includes(incident.status) && incident.severity === "critical").length

  return (
    <ProductShell availableWorkspaces={auth.workspaces} currentSection="alerts" membershipRole={auth.membership?.role || "member"} releaseStage={releaseStage} userEmail={auth.user?.email || "Invited user"} workspace={workspace}>
      <div className="mx-auto max-w-6xl space-y-7">
        <header className="grid gap-5 lg:grid-cols-[1fr_auto] lg:items-end">
          <div className="max-w-3xl"><p className="text-sm font-medium text-primary">Workspace action queue</p><h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Incidents, with every exact occurrence attached</h1><p className="mt-3 text-base leading-7 text-muted-foreground">Repeated failures stay one bounded action item for the same configuration and failure signature. Every run alert remains immutable and inspectable; materially different signatures open separate incidents.</p></div>
          <Badge variant="outline" className="w-fit">{canResolve ? "Owner lifecycle access" : "Member acknowledgement access"}</Badge>
        </header>

        <section className="grid gap-4 sm:grid-cols-3" aria-label="Incident summary">
          <SummaryCard label="Unresolved" value={unresolved} detail="Open and acknowledged" tone={unresolved > 0 ? "warning" : "success"} />
          <SummaryCard label="Critical on page" value={critical} detail="Current page only" tone={critical > 0 ? "danger" : "success"} />
          <SummaryCard label="Recovered" value={counts.recovered || 0} detail="Clean exact-provenance run" tone="success" />
        </section>

        {incidents.length === 0 ? (
          <Card id="incidents-empty" className="border-success/20 bg-success/5"><CardContent className="flex flex-col items-center px-6 py-12 text-center"><span className="grid size-12 place-items-center rounded-2xl bg-success/10 text-success"><CheckCircle2 /></span><h2 className="mt-4 text-xl font-semibold">No incidents have been opened</h2><p className="mt-2 max-w-lg text-sm leading-6 text-muted-foreground">A completed monitoring run can open an incident only from an explicit deterministic or operational finding.</p></CardContent></Card>
        ) : (
          <section id="workspace-incidents" className="space-y-4" aria-labelledby="workspace-incidents-heading">
            <div className="flex flex-wrap items-center justify-between gap-3"><h2 id="workspace-incidents-heading" className="text-2xl font-semibold tracking-tight">Incident queue</h2><p className="text-xs text-muted-foreground">{formatNumber(pagination.total)} total · page {pagination.page} of {pagination.totalPages}</p></div>
            <div className="grid gap-4 lg:grid-cols-2">
              {incidents.map(incident => <IncidentCard key={incident.id} incident={incident} workspaceSlug={workspace.slug} />)}
            </div>
            <PaginationControls workspaceSlug={workspace.slug} pagination={pagination} />
          </section>
        )}

        <div className="flex items-start gap-3 rounded-2xl border bg-muted/20 p-4 text-sm text-muted-foreground"><ShieldAlert className="mt-0.5 size-4 shrink-0 text-primary" /><p>Opening, recurrence counts 5, 20, and 50 are the only email points for an incident episode. Worker retries cannot create duplicate occurrence or delivery rows.</p></div>
      </div>
    </ProductShell>
  )
}

function IncidentCard({ incident, workspaceSlug }: { incident: IncidentSummary; workspaceSlug: string }) {
  const closed = ["resolved", "recovered"].includes(incident.status)
  return <Card id={`incident-${incident.id}`} className={closed ? "opacity-75" : incident.severity === "critical" ? "border-destructive/30" : "border-amber-500/30"}>
    <CardHeader><div className="flex flex-wrap gap-2"><SeverityBadge severity={incident.severity} /><CategoryBadge category={incident.category} /><AlertStatusBadge status={incident.status} /><Badge variant="outline">Episode {incident.episode}</Badge></div><CardTitle className="pt-2 text-xl">{incident.title}</CardTitle><CardDescription className="leading-6">{incident.explanation}</CardDescription></CardHeader>
    <CardContent className="space-y-4">
      {incident.exceptionalReference && <div className="rounded-lg border border-amber-500/25 bg-amber-500/5 p-3 text-xs text-amber-800 dark:text-amber-200">Latest occurrence used an exceptionally approved reviewed reference. It remains a finding; the exception does not suppress it.</div>}
      <div className="grid gap-3 rounded-xl border bg-muted/20 p-4 text-xs sm:grid-cols-2"><Fact label="Monitor" value={incident.monitor?.name || "Unavailable"} /><Fact label="Occurrences" value={`${formatNumber(incident.occurrenceCount)} across ${formatNumber(incident.runCount)} runs`} /><Fact label="First seen" value={formatUtc(incident.firstSeenAt)} /><Fact label="Last seen" value={formatUtc(incident.lastSeenAt)} /></div>
      <div className="flex flex-wrap items-center justify-between gap-3"><p className="text-xs text-muted-foreground"><History className="mr-1 inline size-3.5" />{incident.affectedCaseCount} distinct affected case{incident.affectedCaseCount === 1 ? "" : "s"}</p><Button asChild size="sm"><Link href={`/app/${workspaceSlug}/incidents/${incident.id}`}>Review incident <ExternalLink /></Link></Button></div>
    </CardContent>
  </Card>
}

function Fact({ label, value }: { label: string; value: string }) { return <div><p className="text-muted-foreground">{label}</p><p className="mt-1 font-medium">{value}</p></div> }

function PaginationControls({ workspaceSlug, pagination }: { workspaceSlug: string; pagination: Pagination }) {
  if (pagination.totalPages <= 1) return null
  return <nav className="flex items-center justify-between" aria-label="Incident pages"><Button asChild variant="outline" size="sm" className={!pagination.hasPrevious ? "pointer-events-none opacity-50" : ""}><Link href={`/app/${workspaceSlug}/alerts?page=${Math.max(1, pagination.page - 1)}`}>Previous</Link></Button><Button asChild variant="outline" size="sm" className={!pagination.hasNext ? "pointer-events-none opacity-50" : ""}><Link href={`/app/${workspaceSlug}/alerts?page=${pagination.page + 1}`}>Next</Link></Button></nav>
}

function SummaryCard({ label, value, detail, tone = "default" }: { label: string; value: number; detail: string; tone?: "default" | "success" | "warning" | "danger" }) {
  const Icon = tone === "success" ? CheckCircle2 : tone === "default" ? BellRing : ShieldAlert
  const color = tone === "success" ? "text-success" : tone === "warning" ? "text-amber-700 dark:text-amber-300" : tone === "danger" ? "text-destructive" : "text-foreground"
  return <Card><CardContent className="flex items-start justify-between gap-4 p-5"><div><p className="text-xs uppercase tracking-[0.14em] text-muted-foreground">{label}</p><p className={`mt-2 text-3xl font-semibold ${color}`}>{value}</p><p className="mt-1 text-xs text-muted-foreground">{detail}</p></div><span className="grid size-10 place-items-center rounded-xl bg-muted text-muted-foreground"><Icon className="size-5" /></span></CardContent></Card>
}

export default function AlertsPage() { const { props } = usePage<AlertsProps & SharedPageProps>(); return <><Head title="Incidents" /><AlertsView {...props} /></> }
