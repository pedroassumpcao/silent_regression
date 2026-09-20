import { useState } from "react"
import { Head, Link, router, usePage } from "@inertiajs/react"
import { AlertTriangle, ArrowLeft, CheckCircle2, ExternalLink, FileCheck2, LoaderCircle, ShieldCheck } from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { AlertStatusBadge, CategoryBadge, formatUtc, SeverityBadge } from "@/components/result-evidence"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import type { SharedPageProps } from "@/types/page"
import type { IncidentDetail } from "@/types/results"

export type IncidentProps = {
  auth: SharedPageProps["auth"]
  canResolve: boolean
  detail: IncidentDetail
  releaseStage: string
}

export function IncidentView({ auth, canResolve, detail, flash = {}, releaseStage }: IncidentProps & { flash?: SharedPageProps["flash"] }) {
  const workspace = auth.workspace
  const [processing, setProcessing] = useState(false)
  if (!workspace) return null

  const incident = detail.incident
  const latest = detail.occurrences[0]
  const mutate = (action: "acknowledge" | "resolve") => {
    setProcessing(true)
    router.post(`/app/${workspace.slug}/incidents/${incident.id}/${action}`, {}, { onFinish: () => setProcessing(false) })
  }

  return (
    <ProductShell availableWorkspaces={auth.workspaces} currentSection="alerts" membershipRole={auth.membership?.role || "member"} releaseStage={releaseStage} userEmail={auth.user?.email || "Invited user"} workspace={workspace}>
      <div className="mx-auto max-w-6xl space-y-7">
        <Button asChild variant="ghost" className="-ml-3"><Link href={`/app/${workspace.slug}/alerts`}><ArrowLeft /> Back to incidents</Link></Button>
        <header className="space-y-4"><div className="flex flex-wrap gap-2"><SeverityBadge severity={incident.severity} /><CategoryBadge category={incident.category} /><AlertStatusBadge status={incident.status} /><Badge variant="outline">Episode {incident.episode}</Badge></div><div><p className="text-sm font-medium text-primary">{incident.monitor?.name || "Monitor incident"}</p><h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">{incident.title}</h1><p className="mt-3 max-w-3xl text-base leading-7 text-muted-foreground">{incident.explanation}</p></div></header>

        {flash.info && <Alert className="border-success/25 bg-success/5"><CheckCircle2 /><AlertTitle>Incident updated</AlertTitle><AlertDescription>{flash.info}</AlertDescription></Alert>}
        {flash.error && <Alert variant="destructive"><AlertTriangle /><AlertTitle>Incident needs attention</AlertTitle><AlertDescription>{flash.error}</AlertDescription></Alert>}

        <section className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4" aria-label="Incident facts"><Fact label="Occurrences" value={String(incident.occurrenceCount)} /><Fact label="Affected cases" value={String(incident.affectedCaseCount)} /><Fact label="First seen" value={formatUtc(incident.firstSeenAt)} /><Fact label="Last seen" value={formatUtc(incident.lastSeenAt)} /></section>

        {latest?.exceptionalReference && <Alert className="border-amber-500/25 bg-amber-500/5"><AlertTriangle /><AlertTitle>Exceptional reviewed reference</AlertTitle><AlertDescription>This occurrence was compared with an exceptionally approved reference. The exception documents the reference decision; it does not make this later finding acceptable or suppress the incident.</AlertDescription></Alert>}

        <Card id="incident-lifecycle"><CardHeader><CardTitle>Action-item lifecycle</CardTitle><CardDescription>Acknowledgement records investigation. Owner resolution requires a current structured judgment on the latest occurrence. A fully clean exact-provenance run can instead mark recovery automatically.</CardDescription></CardHeader><CardContent className="flex flex-wrap gap-3">{incident.status === "open" && <Button id="acknowledge-incident" disabled={processing} onClick={() => mutate("acknowledge")}>{processing ? <LoaderCircle className="animate-spin" /> : <FileCheck2 />} Acknowledge incident</Button>}{incident.status === "acknowledged" && canResolve && <Button id="resolve-incident" disabled={processing || !latest} onClick={() => mutate("resolve")}><ShieldCheck /> Resolve with latest review</Button>}{incident.status === "acknowledged" && !canResolve && <Badge variant="outline">Owner resolution required</Badge>}{["resolved", "recovered"].includes(incident.status) && <p className="text-sm text-muted-foreground">This episode is closed. A later matching finding creates a new linked episode instead of rewriting this history.</p>}</CardContent></Card>

        <section className="space-y-4"><div><p className="text-sm font-medium text-primary">Immutable history</p><h2 className="mt-1 text-2xl font-semibold">Occurrence evidence</h2><p className="mt-2 text-sm text-muted-foreground">{detail.pagination.total} occurrence{detail.pagination.total === 1 ? "" : "s"}; newest first. Signature schema: {detail.signatureSchemaVersion}.</p></div><div className="space-y-3">{detail.occurrences.map(occurrence => <OccurrenceCard key={occurrence.id} incident={incident} occurrence={occurrence} workspaceSlug={workspace.slug} />)}</div></section>
      </div>
    </ProductShell>
  )
}

function OccurrenceCard({ incident, occurrence, workspaceSlug }: { incident: IncidentDetail["incident"]; occurrence: IncidentDetail["occurrences"][number]; workspaceSlug: string }) {
  const runPath = occurrence.run && incident.monitor ? `/app/${workspaceSlug}/monitors/${incident.monitor.id}/runs/${occurrence.run.id}` : null
  return <Card id={`occurrence-${occurrence.id}`}><CardContent className="flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:justify-between"><div><div className="flex flex-wrap gap-2"><Badge variant="outline">Occurrence {occurrence.ordinal}</Badge>{occurrence.exceptionalReference && <Badge variant="outline" className="border-amber-500/30 text-amber-700">Exceptional reference</Badge>}</div><p className="mt-3 text-sm font-medium">{formatUtc(occurrence.occurredAt)}</p><p className="mt-1 text-xs text-muted-foreground">{occurrence.caseCount} affected case fingerprint{occurrence.caseCount === 1 ? "" : "s"} · exact alert {occurrence.alert.code}</p></div>{runPath && <Button asChild size="sm" variant="outline"><Link href={runPath}>Inspect exact run <ExternalLink /></Link></Button>}</CardContent></Card>
}

function Fact({ label, value }: { label: string; value: string }) { return <Card><CardContent className="p-5"><p className="text-xs text-muted-foreground">{label}</p><p className="mt-2 font-semibold">{value}</p></CardContent></Card> }

export default function IncidentPage() { const { props } = usePage<IncidentProps & SharedPageProps>(); return <><Head title={`Incident · ${props.detail.incident.title}`} /><IncidentView {...props} flash={props.flash} /></> }
