import { Head, Link, usePage } from "@inertiajs/react"
import {
  ArrowRight,
  CheckCircle2,
  Circle,
  Fingerprint,
  FlaskConical,
  LockKeyhole,
  Route,
  ShieldAlert,
  Sparkles,
  TestTubeDiagonal,
  TriangleAlert,
  WalletCards,
} from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Progress } from "@/components/ui/progress"
import type { SharedPageProps } from "@/types/page"

type Result = {
  checkId?: string
  ruleId?: string
  status: string
  code: string
  explanation: string
}

type Evidence = {
  observationId: string
  output: string
  contractStatus: string
  contractResults: Result[]
  caseExpectationStatus: string
  caseExpectationResults: Result[]
  overallStatus: string
  evaluatorEngineVersion: string
  evaluatedAt: string
  role: string
}

type Scenario = {
  scenarioVersion: string
  sealedFingerprint: string
  providerCalls: number
  request: {
    provider: string
    requestedModel: string
    body: Record<string, unknown>
  }
  contract: {
    fingerprint: string
    root: Record<string, unknown>
    explanation: string
  }
  caseExpectation: {
    schemaVersion: string
    fingerprint: string
    payload: Record<string, unknown>
    explanation: string
  }
  reference: Evidence
  recurring: Evidence
  incident: {
    severity: string
    signature: string
    explanation: string
  }
}

type DemoProgress = {
  status: "not_started" | "in_progress" | "completed"
  scenarioVersion: string
  completedSteps: string[]
  completedCount: number
  totalCount: number
  currentStep: "request" | "expectation" | "reference" | "incident" | null
  startedAt: string | null
  expectationProvenAt: string | null
  completedAt: string | null
  secondsToExpectation: number | null
  secondsToCompletion: number | null
}

export type GuidedDemoProps = {
  auth: SharedPageProps["auth"]
  progress: DemoProgress
  releaseStage: string
  scenario: Scenario
  workspace: { name: string; slug: string }
}

const steps = [
  { key: "request", label: "Exact request", description: "See the frozen input and zero-call boundary." },
  { key: "expectation", label: "Expected behavior", description: "Separate broad validity from the right answer." },
  { key: "reference", label: "Reviewed reference", description: "Inspect one sealed passing execution." },
  { key: "incident", label: "Silent regression", description: "Catch a valid-looking but wrong outcome." },
]

export function GuidedDemoView({ auth, flash = {}, progress, releaseStage, scenario, workspace }: GuidedDemoProps & { flash?: SharedPageProps["flash"] }) {
  const demoPath = `/app/${workspace.slug}/demo`
  const percent = Math.round((progress.completedCount / progress.totalCount) * 100)

  return (
    <ProductShell
      availableWorkspaces={auth.workspaces}
      currentSection="demo"
      membershipRole={auth.membership?.role || "member"}
      releaseStage={releaseStage}
      userEmail={auth.user?.email || "Invited user"}
      workspace={workspace}
    >
      <div className="mx-auto max-w-6xl space-y-8">
        <section className="flex flex-col justify-between gap-5 lg:flex-row lg:items-end">
          <div>
            <div className="mb-3 flex flex-wrap gap-2">
              <Badge variant="outline" className="rounded-full border-primary/25 text-primary"><Sparkles /> Guided product demo</Badge>
              <Badge variant="secondary" className="rounded-full">0 provider calls</Badge>
            </div>
            <h1 className="max-w-4xl text-3xl font-semibold tracking-tight sm:text-4xl">See a silent regression before sharing a credential</h1>
            <p className="mt-3 max-w-3xl text-base leading-7 text-muted-foreground">
              Walk through one sealed routing case evaluated by the same deterministic engines used for real monitors. The fixture is read-only, creates no monitor, and never contacts OpenAI or Anthropic.
            </p>
          </div>
          <div className="rounded-xl border bg-card px-4 py-3 text-sm shadow-xs">
            <p className="font-medium">Sealed scenario</p>
            <p className="mt-1 font-mono text-xs text-muted-foreground">{shortFingerprint(scenario.sealedFingerprint)}</p>
          </div>
        </section>

        {flash.info && <Alert id="demo-flash" className="border-success/25 bg-success/5"><CheckCircle2 /><AlertTitle>Demo progress saved</AlertTitle><AlertDescription>{flash.info}</AlertDescription></Alert>}
        {flash.error && <Alert id="demo-error" variant="destructive"><TriangleAlert /><AlertTitle>Demo unchanged</AlertTitle><AlertDescription>{flash.error}</AlertDescription></Alert>}

        <section className="grid gap-4 sm:grid-cols-3" aria-label="Demo guarantees">
          <Metric icon={WalletCards} label="Provider calls" value="0" detail="No credential or spend" />
          <Metric icon={LockKeyhole} label="Scenario" value="Sealed" detail={scenario.scenarioVersion} />
          <Metric icon={TestTubeDiagonal} label="Evaluator" value="Production" detail={scenario.reference.evaluatorEngineVersion} />
        </section>

        {progress.status === "not_started" ? (
          <StartCard path={`${demoPath}/start`} />
        ) : (
          <>
            <DemoProgress progress={progress} percent={percent} />
            {progress.status === "completed" ? (
              <CompletedDemo progress={progress} scenario={scenario} workspaceSlug={workspace.slug} />
            ) : (
              <CurrentStep path={`${demoPath}/steps/${progress.currentStep}`} progress={progress} scenario={scenario} />
            )}
          </>
        )}

        <Alert id="demo-import-boundary">
          <FlaskConical />
          <AlertTitle>Import support is intentionally narrow</AlertTitle>
          <AlertDescription>
            Real setup accepts manual cases or Silent Regression&apos;s versioned JSON schema. No vendor-specific eval adapter is claimed yet; the first adapter will be chosen only after inspecting an actual design partner&apos;s source format.
          </AlertDescription>
        </Alert>
      </div>
    </ProductShell>
  )
}

function StartCard({ path }: { path: string }) {
  return (
    <Card id="demo-start" className="overflow-hidden border-primary/20 bg-primary/[0.03]">
      <CardContent className="grid gap-8 p-6 md:grid-cols-[1fr_0.75fr] md:items-center md:p-10">
        <div>
          <p className="text-sm font-medium text-primary">Four short evidence steps</p>
          <h2 className="mt-2 text-2xl font-semibold tracking-tight">Find the failure that a broad contract misses</h2>
          <p className="mt-3 max-w-2xl text-sm leading-6 text-muted-foreground">The output remains a valid routing label, yet changes from the correct case-specific answer. You will inspect the exact request, expectation, passing reference, and resulting incident.</p>
          <Button id="start-guided-demo" asChild className="mt-6">
            <Link href={path} method="post" as="button">Start credential-free demo <ArrowRight /></Link>
          </Button>
        </div>
        <ol className="space-y-3">
          {steps.map((step, index) => <li key={step.key} className="flex gap-3 rounded-xl border bg-background/80 p-4"><span className="grid size-7 shrink-0 place-items-center rounded-full bg-primary/10 text-xs font-semibold text-primary">{index + 1}</span><span><span className="block text-sm font-medium">{step.label}</span><span className="mt-1 block text-xs leading-5 text-muted-foreground">{step.description}</span></span></li>)}
        </ol>
      </CardContent>
    </Card>
  )
}

function DemoProgress({ progress, percent }: { progress: DemoProgress; percent: number }) {
  return (
    <Card id="demo-progress">
      <CardHeader>
        <div className="flex items-center justify-between gap-4"><div><CardTitle>Evidence walkthrough</CardTitle><CardDescription className="mt-1">Progress is saved for your account without storing prompt or output content in analytics.</CardDescription></div><span className="text-sm font-medium">{progress.completedCount} of {progress.totalCount}</span></div>
        <Progress value={percent} aria-label="Credential-free demo progress" />
      </CardHeader>
      <CardContent><ol className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">{steps.map((step, index) => { const complete = progress.completedSteps.includes(step.key); const current = progress.currentStep === step.key; return <li key={step.key} className={`rounded-xl border p-4 ${current ? "border-primary/35 bg-primary/5" : "bg-muted/15"}`}><span className={complete ? "text-success" : current ? "text-primary" : "text-muted-foreground"}>{complete ? <CheckCircle2 className="size-5" /> : <Circle className="size-5" />}</span><p className="mt-3 text-sm font-medium">{index + 1}. {step.label}</p><p className="mt-1 text-xs leading-5 text-muted-foreground">{step.description}</p></li> })}</ol></CardContent>
    </Card>
  )
}

function CurrentStep({ path, progress, scenario }: { path: string; progress: DemoProgress; scenario: Scenario }) {
  if (progress.currentStep === "request") return <RequestStep path={path} scenario={scenario} />
  if (progress.currentStep === "expectation") return <ExpectationStep path={path} scenario={scenario} />
  if (progress.currentStep === "reference") return <ReferenceStep path={path} scenario={scenario} />
  return <IncidentStep path={path} scenario={scenario} />
}

function RequestStep({ path, scenario }: { path: string; scenario: Scenario }) {
  return (
    <Card id="demo-step-request">
      <CardHeader><p className="text-sm font-medium text-primary">Step 1 · exact request</p><CardTitle className="text-2xl">Know what would be sent before any call</CardTitle><CardDescription>This sealed artifact is representative, not customer data. The demo evaluates stored fixture outputs locally, so this body is shown but never transmitted.</CardDescription></CardHeader>
      <CardContent className="space-y-5"><pre className="overflow-x-auto rounded-xl border bg-muted/35 p-5 text-xs leading-6"><code>{JSON.stringify(scenario.request.body, null, 2)}</code></pre><Alert><LockKeyhole /><AlertTitle>Credential boundary</AlertTitle><AlertDescription>Provider target: local demo fixture · requested model: sealed-fixture-v1 · provider calls: 0.</AlertDescription></Alert><StepButton path={path} label="Continue to expected behavior" /></CardContent>
    </Card>
  )
}

function ExpectationStep({ path, scenario }: { path: string; scenario: Scenario }) {
  return (
    <Card id="demo-step-expectation">
      <CardHeader><p className="text-sm font-medium text-primary">Step 2 · expected behavior</p><CardTitle className="text-2xl">A valid label is not necessarily the right label</CardTitle><CardDescription>The shared contract and case-specific expectation answer different questions and keep separate fingerprints.</CardDescription></CardHeader>
      <CardContent className="space-y-5"><div className="grid gap-4 md:grid-cols-2"><EvidenceDefinition icon={Route} title="Shared contract" fingerprint={scenario.contract.fingerprint} description={scenario.contract.explanation} json={scenario.contract.root} /><EvidenceDefinition icon={Fingerprint} title="Case-specific expectation" fingerprint={scenario.caseExpectation.fingerprint} description={scenario.caseExpectation.explanation} json={scenario.caseExpectation.payload} /></div><Alert className="border-primary/20 bg-primary/5"><Sparkles /><AlertTitle>This is the wedge</AlertTitle><AlertDescription>A broad rule can say both <code>billing</code> and <code>technical</code> are structurally allowed. Only the frozen case expectation proves which one is correct for this exact input.</AlertDescription></Alert><StepButton path={path} label="Prove the case expectation" /></CardContent>
    </Card>
  )
}

function ReferenceStep({ path, scenario }: { path: string; scenario: Scenario }) {
  return (
    <Card id="demo-step-reference">
      <CardHeader><p className="text-sm font-medium text-primary">Step 3 · reviewed reference</p><CardTitle className="text-2xl">Inspect one exact passing execution</CardTitle><CardDescription>This output passes both evidence layers. It becomes reviewed provenance for comparison—not proof that every future output will be healthy.</CardDescription></CardHeader>
      <CardContent className="space-y-5"><EvidenceOutcome title="Reviewed output" evidence={scenario.reference} /><Alert><Fingerprint /><AlertTitle>Bounded claim</AlertTitle><AlertDescription>This proves only that <code>billing</code> passed these exact rules for this sealed execution. It is not a measured failure rate or a universal model-health claim.</AlertDescription></Alert><StepButton path={path} label="Compare the next sample" /></CardContent>
    </Card>
  )
}

function IncidentStep({ path, scenario }: { path: string; scenario: Scenario }) {
  return (
    <Card id="demo-step-incident" className="border-destructive/20">
      <CardHeader><p className="text-sm font-medium text-destructive">Step 4 · silent regression</p><CardTitle className="text-2xl">The output is allowed—but wrong for this case</CardTitle><CardDescription>The recurring output still passes the shared contract while failing the exact case expectation, producing a durable incident signature.</CardDescription></CardHeader>
      <CardContent className="space-y-5"><div className="grid gap-4 md:grid-cols-2"><EvidenceOutcome title="Reviewed reference" evidence={scenario.reference} /><EvidenceOutcome title="Recurring sample" evidence={scenario.recurring} /></div><Alert variant="destructive"><ShieldAlert /><AlertTitle>Critical case-expectation incident</AlertTitle><AlertDescription>{scenario.incident.explanation}<span className="mt-2 block font-mono text-xs">{scenario.incident.signature}</span></AlertDescription></Alert><StepButton path={path} label="Complete the demo" /></CardContent>
    </Card>
  )
}

function CompletedDemo({ progress, scenario, workspaceSlug }: { progress: DemoProgress; scenario: Scenario; workspaceSlug: string }) {
  return (
    <Card id="demo-complete" className="border-success/25 bg-success/[0.04]">
      <CardContent className="grid gap-7 p-6 md:grid-cols-[1fr_auto] md:items-center md:p-9"><div><span className="grid size-11 place-items-center rounded-2xl bg-success/10 text-success"><CheckCircle2 /></span><h2 className="mt-4 text-2xl font-semibold">You found the silent regression</h2><p className="mt-2 max-w-2xl text-sm leading-6 text-muted-foreground">The shared contract passed; the case-specific expectation failed; the exact evidence remained inspectable; and zero provider calls were made. {progress.secondsToCompletion === null ? "" : `Walkthrough time: ${progress.secondsToCompletion} seconds.`}</p></div><div className="flex flex-wrap gap-3"><Button asChild variant="outline"><Link href={`/app/${workspaceSlug}/credentials`}>Add a credential</Link></Button><Button asChild><Link href={`/app/${workspaceSlug}/monitors/new`}>Build a real monitor <ArrowRight /></Link></Button></div></CardContent>
    </Card>
  )
}

function EvidenceDefinition({ description, fingerprint, icon: Icon, json, title }: { description: string; fingerprint: string; icon: typeof Route; json: Record<string, unknown>; title: string }) {
  return <div className="rounded-xl border bg-muted/15 p-5"><Icon className="size-5 text-primary" /><h3 className="mt-3 font-medium">{title}</h3><p className="mt-2 text-sm leading-6 text-muted-foreground">{description}</p><p className="mt-3 font-mono text-[11px] text-muted-foreground">{shortFingerprint(fingerprint)}</p><details className="mt-4"><summary className="cursor-pointer text-xs font-medium text-primary">Inspect exact JSON</summary><pre className="mt-3 overflow-x-auto rounded-lg border bg-background p-3 text-[11px] leading-5"><code>{JSON.stringify(json, null, 2)}</code></pre></details></div>
}

function EvidenceOutcome({ evidence, title }: { evidence: Evidence; title: string }) {
  const passed = evidence.overallStatus === "pass"
  return <div className={`rounded-xl border p-5 ${passed ? "border-success/25 bg-success/[0.04]" : "border-destructive/25 bg-destructive/[0.03]"}`}><div className="flex items-start justify-between gap-3"><div><p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{title}</p><p className="mt-2 font-mono text-xl font-semibold">{evidence.output}</p></div><Badge variant={passed ? "secondary" : "destructive"}>{passed ? "Pass" : "Fail"}</Badge></div><dl className="mt-5 grid gap-3 text-sm"><StatusRow label="Shared contract" value={evidence.contractStatus} /><StatusRow label="Case expectation" value={evidence.caseExpectationStatus} /></dl><div className="mt-4 space-y-2 border-t pt-4">{evidence.caseExpectationResults.map(result => <p key={result.code} className="text-xs leading-5 text-muted-foreground"><span className={result.status === "pass" ? "text-success" : "text-destructive"}>{result.status}</span> · {result.explanation}</p>)}</div></div>
}

function StatusRow({ label, value }: { label: string; value: string }) { return <div className="flex items-center justify-between gap-3"><dt className="text-muted-foreground">{label}</dt><dd className={value === "pass" ? "font-medium text-success" : "font-medium text-destructive"}>{value}</dd></div> }
function StepButton({ label, path }: { label: string; path: string }) { return <div className="flex justify-end"><Button id="complete-demo-step" asChild><Link href={path} method="post" as="button">{label} <ArrowRight /></Link></Button></div> }
function Metric({ detail, icon: Icon, label, value }: { detail: string; icon: typeof WalletCards; label: string; value: string }) { return <Card><CardContent className="flex items-center gap-4 p-5"><span className="grid size-10 place-items-center rounded-xl bg-primary/10 text-primary"><Icon className="size-5" /></span><div><p className="text-xs text-muted-foreground">{label}</p><p className="mt-1 text-lg font-semibold">{value}</p><p className="text-xs text-muted-foreground">{detail}</p></div></CardContent></Card> }
function shortFingerprint(value: string) { return `${value.slice(0, 12)}…${value.slice(-8)}` }

export default function GuidedDemo(props: GuidedDemoProps) {
  const { flash } = usePage<SharedPageProps>().props
  return <><Head title="Credential-free demo" /><GuidedDemoView {...props} flash={flash} /></>
}
