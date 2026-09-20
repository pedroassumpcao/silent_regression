import { useState } from "react"
import { Head, Link, router, usePage } from "@inertiajs/react"
import {
  AlertTriangle,
  ArrowLeft,
  CheckCircle2,
  CircleDotDashed,
  FileCheck2,
  GitBranchPlus,
  KeyRound,
  LoaderCircle,
  PlayCircle,
  RefreshCw,
  ShieldCheck,
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
import type { SharedPageProps } from "@/types/page"

type ChangeArea = "provider" | "requested_model" | "provider_request" | "generation_config" | "response_format" | "cases"

export type SuccessorProps = {
  auth: SharedPageProps["auth"]
  canActivate: boolean
  monitor: { id: string; name: string; state: string }
  motivation: {
    id: string
    classification: string
    action: string
    rationale: string
    reviewer: string | null
    reviewedAt: string
  } | null
  preview: {
    activationReady: boolean
    activeRun: boolean
    changes: ChangeArea[]
    contractReady: boolean
    draftCurrent: boolean
    fingerprint: string
    modelVerified: boolean
    replacementReferenceRequired: boolean
    sourceCurrent: boolean
  }
  releaseStage: string
  setup: {
    id: string
    status: "in_progress" | "completed"
    sourceVersion: number
    candidateVersion: number | null
    provider: "openai" | "anthropic"
    requestedModel: string
    completedAt: string | null
  }
}

export function SuccessorView({
  auth,
  canActivate,
  flash = {},
  monitor,
  motivation,
  preview,
  releaseStage,
  setup,
}: SuccessorProps & { flash?: SharedPageProps["flash"] }) {
  const workspace = auth.workspace
  const [processing, setProcessing] = useState<"validate" | "activate" | null>(null)
  const [dialogOpen, setDialogOpen] = useState(false)

  if (!workspace) return null

  const basePath = `/app/${workspace.slug}/monitors/${monitor.id}`
  const blockerCount = [
    !preview.sourceCurrent,
    !preview.draftCurrent,
    !preview.modelVerified,
    preview.activeRun,
    !preview.contractReady,
  ].filter(Boolean).length

  function validateModel() {
    setProcessing("validate")
    router.post(`${basePath}/successor/validate-model`, {}, { preserveScroll: true, onFinish: () => setProcessing(null) })
  }

  function activate() {
    setProcessing("activate")
    router.post(
      `${basePath}/successor/activate`,
      { preview_fingerprint: preview.fingerprint },
      {
        preserveScroll: true,
        onSuccess: () => setDialogOpen(false),
        onFinish: () => setProcessing(null),
      },
    )
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
      <div className="mx-auto max-w-6xl space-y-7">
        <header className="space-y-5">
          <Button asChild variant="ghost" className="-ml-3">
            <Link href={`${basePath}/operations`}><ArrowLeft /> Back to operations</Link>
          </Button>
          <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <div className="max-w-3xl">
              <p className="text-sm font-medium text-primary">{monitor.name}</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Review the configuration successor</h1>
              <p className="mt-3 text-base leading-7 text-muted-foreground">
                The active version stays authoritative until every guard below passes and an owner activates this immutable candidate.
              </p>
            </div>
            <Badge variant="outline" className="w-fit"><GitBranchPlus /> v{setup.sourceVersion} → {setup.candidateVersion ? `v${setup.candidateVersion}` : "draft"}</Badge>
          </div>
        </header>

        {flash.info && <Alert id="successor-success" className="border-success/25 bg-success/5"><CheckCircle2 /><AlertTitle>Successor updated</AlertTitle><AlertDescription>{flash.info}</AlertDescription></Alert>}
        {flash.error && <Alert id="successor-error" variant="destructive"><AlertTriangle /><AlertTitle>Successor needs attention</AlertTitle><AlertDescription>{flash.error}</AlertDescription></Alert>}

        {motivation && (
          <Alert id="successor-motivation" className="border-primary/20 bg-primary/5">
            <CircleDotDashed />
            <AlertTitle>Linked to a reviewed result</AlertTitle>
            <AlertDescription>
              {label(motivation.classification)} · {label(motivation.action)}. {motivation.rationale}
              {motivation.reviewer ? ` — ${motivation.reviewer}` : ""}
            </AlertDescription>
          </Alert>
        )}

        {setup.status === "in_progress" ? (
          <Card id="successor-draft-card" className="border-primary/25">
            <CardHeader>
              <CardTitle>Copied draft is safe to edit</CardTitle>
              <CardDescription>The active version, schedule, reviewed reference, and historical evidence are unchanged.</CardDescription>
            </CardHeader>
            <CardContent className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
              <p className="text-sm text-muted-foreground">Edit request messages, provider/model, generation settings, cases, and exact expectations. Leaving the flow keeps this draft resumable.</p>
              <Button id="edit-successor" asChild><Link href={`${basePath}/setup/review`}>Continue editing <RefreshCw /></Link></Button>
            </CardContent>
          </Card>
        ) : (
          <>
            <section className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4" aria-label="Successor readiness">
              <ReadinessCard icon={GitBranchPlus} label="Immutable candidate" ready={preview.draftCurrent} detail={preview.draftCurrent ? `Configuration v${setup.candidateVersion}` : "Candidate is no longer current"} />
              <ReadinessCard icon={KeyRound} label="Exact-model access" ready={preview.modelVerified} detail={`${setup.provider} · ${setup.requestedModel}`} />
              <ReadinessCard icon={FileCheck2} label="Contract proof" ready={preview.contractReady} detail="Approved semantics carry forward unchanged" />
              <ReadinessCard icon={PlayCircle} label="Unfinished work" ready={!preview.activeRun} detail={preview.activeRun ? "Wait for the active run" : "No run blocks activation"} />
            </section>

            <div className="grid gap-6 lg:grid-cols-[1fr_0.72fr]">
              <Card id="successor-impact-card">
                <CardHeader>
                  <CardTitle>Changed behavior and activation impact</CardTitle>
                  <CardDescription>Only the areas below differ from configuration v{setup.sourceVersion}.</CardDescription>
                </CardHeader>
                <CardContent className="space-y-5">
                  <div className="flex flex-wrap gap-2">
                    {preview.changes.length > 0 ? preview.changes.map(area => <Badge key={area} variant="secondary">{changeLabel(area)}</Badge>) : <Badge variant="outline">No executable change</Badge>}
                  </div>
                  <Alert className="border-amber-500/25 bg-amber-500/5">
                    <AlertTriangle className="text-amber-700" />
                    <AlertTitle>A replacement reviewed reference is required</AlertTitle>
                    <AlertDescription>
                      Activation retires only future execution references and moves this monitor to reference capture. The current reference and every historical run remain unchanged and inspectable. Monitoring resumes only after reference approval and an explicit schedule decision.
                    </AlertDescription>
                  </Alert>
                  <div className="rounded-xl border bg-muted/20 p-4 text-xs leading-5 text-muted-foreground">
                    Preview fingerprint: <code className="break-all text-foreground">{preview.fingerprint}</code>
                  </div>
                </CardContent>
              </Card>

              <Card id="successor-activation-card" className={preview.activationReady ? "border-success/30 bg-success/5" : ""}>
                <CardHeader>
                  <CardTitle>{preview.activationReady ? "Ready for owner activation" : `${blockerCount} activation blocker${blockerCount === 1 ? "" : "s"}`}</CardTitle>
                  <CardDescription>Activation is one transaction. A failed guard leaves the active version untouched.</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4">
                  {!preview.modelVerified && (
                    <Button id="validate-successor-model" variant="outline" className="w-full" disabled={!canActivate || processing !== null} onClick={validateModel}>
                      {processing === "validate" ? <LoaderCircle className="animate-spin" /> : <KeyRound />} Verify exact-model access
                    </Button>
                  )}
                  <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
                    <DialogTrigger asChild>
                      <Button id="activate-successor" className="w-full" disabled={!canActivate || !preview.activationReady || processing !== null}>
                        <ShieldCheck /> Activate successor
                      </Button>
                    </DialogTrigger>
                    <DialogContent>
                      <DialogHeader>
                        <DialogTitle>Activate configuration v{setup.candidateVersion}?</DialogTitle>
                        <DialogDescription>
                          This atomically carries forward the approved deterministic contract, changes future execution to the candidate, and requires a replacement reviewed reference. It makes no provider completion call now.
                        </DialogDescription>
                      </DialogHeader>
                      <Alert className="border-amber-500/25 bg-amber-500/5"><AlertTriangle /><AlertTitle>Monitoring will await reference approval</AlertTitle><AlertDescription>The previous configuration and evidence remain immutable. This action does not resume the old schedule automatically.</AlertDescription></Alert>
                      <DialogFooter>
                        <DialogClose asChild><Button variant="outline">Cancel</Button></DialogClose>
                        <Button id="confirm-successor-activation" disabled={processing !== null} onClick={activate}>{processing === "activate" ? <LoaderCircle className="animate-spin" /> : <ShieldCheck />} Activate and capture new reference</Button>
                      </DialogFooter>
                    </DialogContent>
                  </Dialog>
                  {!canActivate && <p className="text-center text-xs text-muted-foreground">A workspace owner must validate and activate this successor.</p>}
                </CardContent>
              </Card>
            </div>
          </>
        )}
      </div>
    </ProductShell>
  )
}

function ReadinessCard({ icon: Icon, label, ready, detail }: { icon: typeof GitBranchPlus; label: string; ready: boolean; detail: string }) {
  return <Card><CardContent className="p-5"><span className="flex items-center gap-2 text-xs text-muted-foreground"><Icon className={ready ? "size-4 text-success" : "size-4 text-amber-700"} />{label}</span><p className="mt-3 font-semibold">{ready ? "Ready" : "Blocked"}</p><p className="mt-1 text-xs leading-5 text-muted-foreground">{detail}</p></CardContent></Card>
}

function changeLabel(area: ChangeArea) {
  return ({
    provider: "Provider",
    requested_model: "Requested model",
    provider_request: "Provider request",
    generation_config: "Generation settings",
    response_format: "Response format",
    cases: "Cases or expectations",
  } as Record<ChangeArea, string>)[area]
}

function label(value: string) {
  return value.replaceAll("_", " ")
}

export default function Successor(props: SuccessorProps) {
  const { flash } = usePage<SharedPageProps>().props
  return <><Head title={`Successor · ${props.monitor.name}`} /><SuccessorView {...props} flash={flash} /></>
}
