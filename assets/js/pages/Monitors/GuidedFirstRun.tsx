import { Head, Link, useForm, usePage, usePoll } from "@inertiajs/react"
import { useEffect, useRef, useState, type ReactNode } from "react"
import { ArrowRight, CheckCircle2, LoaderCircle } from "lucide-react"
import { ProductShell } from "@/components/product-shell"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import type { SharedPageProps } from "@/types/page"

type Blocker = { code: string; message: string }
export type GuidedFirstRunProps = {
  auth: SharedPageProps["auth"]
  monitor: { id: string; name: string; state: string; cadence: string }
  original: boolean; completed: boolean; canFinish: boolean; reviewed: boolean
  reviewFingerprint: string | null; authorizationKey: string
  checks: {
    approved: boolean; ready: boolean
    identity: { contractId: string; fingerprint: string; coverageFingerprint: string }
    rootJson: string
    proof: Array<{ id: string; name: string; inputJson: string; context: string; expected: string; output: string; shared: string; specific: string; reason: string }>
    fixtures: Array<{ name: string; outputText: string; expectedStatus: string }>
  }
  preflight: {
    ready: boolean; blockers: Blocker[]; plannedCallCount: number; maximumCallCount: number
    retryLimit: number; maxOutputTokensPerCall: number; maximumOutputTokens: number
    previewFingerprint: string | null; provider: string; model: string; credentialLabel: string | null
  }
  requests: Array<{ caseKey: string; name: string; artifactJson: string; fingerprint: string }>
  snapshot: null | {
    id: string; status: string; runId: string; runStatus: string; terminal: boolean
    compatible: boolean; actualCalls: number; inputTokens: number; outputTokens: number; blockers: Blocker[]
    observations: Array<{
      id: string; name: string; inputJson: string; context: string; expected: string
      output: string | null; status: string; completion: string | null
      shared: string | null; specific: string | null; reasons: string[]; failure: string | null
      requestFingerprint: string
    }>
  }
}

export default function GuidedFirstRun(props: GuidedFirstRunProps) {
  const { flash } = usePage<SharedPageProps>().props
  return <GuidedFirstRunView {...props} flash={flash} />
}

export function GuidedFirstRunView(props: GuidedFirstRunProps & { flash?: SharedPageProps["flash"] }) {
  const { auth, monitor, checks, preflight, snapshot, completed, original, canFinish, flash = {} } = props
  const form = useForm({})
  const [confirmation, setConfirmation] = useState<string | null>(null)
  const heading = useRef<HTMLHeadingElement>(null)
  const running = Boolean(snapshot && !snapshot.terminal)
  const { start, stop } = usePoll(2500, {}, { autoStart: false })
  useEffect(() => { if (running) start(); else stop(); return stop }, [running, start, stop])
  const phase = completed ? "done" : snapshot?.terminal ? "result" : running ? "running" : !checks.approved ? "checks" : "authorize"
  const identity = phase === "checks" ? JSON.stringify(checks.identity) : phase === "result" ? props.reviewFingerprint : preflight.previewFingerprint
  const confirmed = identity !== null && confirmation === identity
  useEffect(() => { heading.current?.focus() }, [phase])
  if (!auth.workspace) return null
  const base = `/app/${auth.workspace.slug}/monitors/${monitor.id}`
  const path = `${base}/first-run`
  const owner = auth.membership?.role === "owner"
  const modelVerification = preflight.blockers.some(blocker => blocker.code === "model_access_unverified")
  const title = completed ? monitor.state === "paused" ? "Setup complete — monitoring paused" : "Setup complete — ready when you are" : snapshot ? snapshot.terminal ? "Review your first real result" : "Your first run is in progress" : "Approve your checks, then run once"

  function submit(action: string, data: Record<string, unknown> = {}) {
    form.transform(() => data)
    form.post(`${path}/${action}`, { preserveScroll: true })
  }
  const resultIdentity = { snapshot_id: snapshot?.id, review_fingerprint: props.reviewFingerprint, confirmed }

  return <>
    <Head title={`First result · ${monitor.name}`} />
    <ProductShell currentSection="monitors" releaseStage="Private alpha" availableWorkspaces={auth.workspaces} userEmail={auth.user?.email || "Invited user"} workspace={auth.workspace} membershipRole={auth.membership?.role || "member"}>
      <div className="mx-auto max-w-4xl space-y-6">
        <header className="space-y-3">
          <div className="flex flex-wrap gap-2"><Badge variant="outline">Real monitor</Badge><Badge variant="secondary">{completed ? "Setup complete" : snapshot?.terminal ? "Step 5 · Review and finish" : "Step 4 · Run once"}</Badge></div>
          <h1 ref={heading} tabIndex={-1} className="text-3xl font-semibold tracking-tight outline-none">{title}</h1>
          <p className="text-muted-foreground">{monitor.name} · {preflight.provider} / {preflight.model}</p>
        </header>
        <ol aria-label="Setup progress" className="grid grid-cols-2 gap-2 text-xs sm:grid-cols-5">{["Request", "Examples", "Prove checks", "Run once", "Review and finish"].map((label, index) => <li key={label} aria-current={!completed && index === (snapshot?.terminal ? 4 : 3) ? "step" : undefined} className={`rounded-lg border px-3 py-2 ${completed || index < (snapshot?.terminal ? 4 : 3) ? "bg-muted/40 text-muted-foreground" : index === (snapshot?.terminal ? 4 : 3) ? "border-primary bg-primary/5 font-medium" : "text-muted-foreground"}`}>{index + 1}. {label}</li>)}</ol>
        {flash.info && <Alert><AlertTitle>Progress saved</AlertTitle><AlertDescription>{flash.info}</AlertDescription></Alert>}
        {flash.error && <Alert variant="destructive"><AlertTitle>Action needs attention</AlertTitle><AlertDescription>{flash.error}</AlertDescription></Alert>}
        {!owner && <Alert><AlertTitle>Ready for your workspace owner</AlertTitle><AlertDescription>You can inspect and record result review. An owner must approve checks, authorize provider calls and finish setup. Share this page’s URL with them; nothing is sent automatically.</AlertDescription></Alert>}
        {!original && <Alert variant="destructive"><AlertTitle>Configuration changed outside this guided flow</AlertTitle><AlertDescription>The original proof no longer describes this configuration. Continue through <Link className="underline" href={`${base}/contract`}>advanced checks</Link> and <Link className="underline" href={`${base}/baseline`}>reference review</Link>.</AlertDescription></Alert>}

        {!snapshot && !checks.approved && <Panel title="Approve the checks you reviewed" description="This is owner approval of the exact saved rules and proof. It makes no provider calls. The next action separately authorizes a bounded real capture.">
          <p className="text-sm leading-6">The shared check allows only your routing labels. Each input must also return its independently chosen correct label. These synthetic examples test the checks; they are not model outputs.</p>
          <details><summary className="cursor-pointer text-sm font-medium">Review synthetic proof and exact shared rules</summary><div className="mt-4 space-y-3">{checks.proof.map(row => <article key={row.id} className="space-y-2 rounded-lg border p-3"><h2 className="font-medium">{row.name}</h2><Code>{row.inputJson}</Code>{row.context && <Code>{row.context}</Code>}<p className="text-sm">Expected: {row.expected} · Synthetic output: {row.output}</p><p className="text-sm">Shared: {row.shared} · Case: {row.specific}</p><p className="text-xs text-muted-foreground">{row.reason}</p></article>)}<Code>{checks.rootJson}</Code><h2 className="text-sm font-medium">Current shared proof fixtures</h2>{checks.fixtures.map((fixture, index) => <p key={index} className="break-all text-sm">{fixture.name}: {fixture.outputText} → {fixture.expectedStatus}</p>)}</div></details>
          <Confirmation checked={confirmed} onChange={value => setConfirmation(value ? identity : null)}>I reviewed and approve these saved checks and proof.</Confirmation>
          <Button id="guided-approve-checks" disabled={!owner || !original || !checks.ready || !confirmed || form.processing} onClick={() => submit("approve-checks", { identity: { contract_id: checks.identity.contractId, fingerprint: checks.identity.fingerprint, coverage_fingerprint: checks.identity.coverageFingerprint } })}>Approve checks and continue <ArrowRight /></Button>
        </Panel>}

        {!snapshot && checks.approved && <Panel title="Authorize one real capture" description="One sample per input. This is your first result and, if you approve it, your reference for future checks. You do not need another run to finish setup.">
          <dl className="grid gap-4 sm:grid-cols-3"><Metric label="Planned calls" value={preflight.plannedCallCount} /><Metric label="Maximum calls including retries" value={preflight.maximumCallCount} /><Metric label="Maximum output tokens" value={preflight.maximumOutputTokens} /></dl>
          <p className="text-sm leading-6">Connection: {preflight.credentialLabel || "Unavailable"}. Up to {preflight.retryLimit} retry per input; {preflight.maxOutputTokensPerCall} output tokens per call. Input tokens are also billed by your provider. These are call/token limits, not a guaranteed dollar price. Your saved requests and frozen context will be sent to the provider. Scheduling stays off.</p>
          {preflight.blockers.length > 0 && <Alert><AlertTitle>Before the first run</AlertTitle><AlertDescription><ul className="list-disc space-y-1 pl-4">{preflight.blockers.map(blocker => <li key={blocker.code}>{blocker.message}</li>)}</ul></AlertDescription></Alert>}
          {modelVerification ? <><p className="text-sm text-muted-foreground">Verify access to this exact model first. This contacts the provider’s metadata endpoint but makes no completion call.</p><Button disabled={!owner || form.processing} onClick={() => submit("validate-model")}>Verify exact model access</Button></> : <><Confirmation checked={confirmed} onChange={value => setConfirmation(value ? identity : null)}>I authorize this real capture within the displayed limits; provider charges may apply.</Confirmation><Button id="guided-authorize-run" disabled={!owner || !original || !preflight.ready || !confirmed || form.processing} onClick={() => submit("authorize", { authorization_key: props.authorizationKey, preview_fingerprint: preflight.previewFingerprint, confirmed })}>Authorize first run <ArrowRight /></Button></>}
        </Panel>}

        {running && <Panel title="You can leave and return safely" description="Progress refreshes automatically. Refreshing or reopening this page resumes the same authorized capture; it does not spend again."><div className="flex items-center gap-3 text-sm" role="status"><LoaderCircle className="size-4 animate-spin" />Capture {snapshot?.runStatus} · {snapshot?.actualCalls} calls so far</div></Panel>}

        {snapshot?.terminal && <Panel title={completed ? "Your first reviewed result" : "Input → expected → actual → reason"} description="Check every input, not only the green badges. Passing means these deterministic checks passed; it is not a claim of general semantic correctness.">
          {!snapshot.compatible && <Alert variant="destructive"><AlertTitle>Configuration compatibility changed</AlertTitle><AlertDescription>This capture cannot be approved against the current configuration. Use advanced review to prepare a compatible replacement.</AlertDescription></Alert>}
          {snapshot.observations.map((row, index) => <article key={row.id} aria-label={`Result ${index + 1}`} className="space-y-4 rounded-xl border p-4">
            <h2 className="font-medium">{row.name}</h2>
            <div><p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">Input</p><Code>{row.inputJson}</Code>{row.context && <Code>{row.context}</Code>}</div>
            <dl className="grid gap-4 sm:grid-cols-2"><div><dt className="text-xs text-muted-foreground">Expected label</dt><dd className="break-all font-mono">{row.expected}</dd></div><div><dt className="text-xs text-muted-foreground">Actual provider output</dt><dd className="whitespace-pre-wrap break-all font-mono">{row.output ?? "No output captured"}</dd></div></dl>
            <div className="flex flex-wrap gap-2"><Badge variant={row.shared === "pass" ? "secondary" : "destructive"}>Shared: {row.shared || "not evaluated"}</Badge><Badge variant={row.specific === "pass" ? "secondary" : "destructive"}>Case: {row.specific || "not evaluated"}</Badge><Badge variant="outline">Completion: {row.completion || row.status}</Badge></div>
            <div className="space-y-1 text-sm leading-6 text-muted-foreground"><p className="font-medium text-foreground">Why this result?</p>{row.failure && <p>{row.failure}</p>}{row.reasons.map((reason, i) => <p key={i}>{reason}</p>)}</div>
          </article>)}
          {snapshot.blockers.map(blocker => <p key={blocker.code} className="text-sm text-destructive">{blocker.message}</p>)}
          {!completed && <>
            <Confirmation checked={confirmed} onChange={value => setConfirmation(value ? identity : null)}>I reviewed every input, expected answer, actual output and explanation shown above.</Confirmation>
            {canFinish && owner ? <><p className="text-sm leading-6">Finish setup approves this exact capture as your reference and enables on-demand checks. It makes no new provider call and does not enable a schedule.</p><Button id="guided-finish" disabled={!confirmed || form.processing} onClick={() => submit("finish", resultIdentity)}>Finish setup <CheckCircle2 /></Button></> : <><p className="text-sm leading-6">{owner ? "This capture cannot be your normal reference. Review the recovery options below; do not change an expected answer just to match a failed output." : "After your review, ask the owner to finish setup from this same page."}</p><Button disabled={!confirmed || form.processing || props.reviewed} onClick={() => submit("review", resultIdentity)}>{props.reviewed ? "Result review recorded" : "Mark results reviewed"}</Button></>}
          </>}
          <details className="text-sm"><summary className="cursor-pointer font-medium">Usage, provenance and complete run evidence</summary><p className="mt-3">{snapshot.actualCalls} actual calls · {snapshot.inputTokens} input tokens · {snapshot.outputTokens} output tokens</p><Link className="mt-3 inline-block underline" href={`${base}/runs/${snapshot.runId}`}>Inspect full run evidence</Link></details>
        </Panel>}

        {completed && <Panel title={monitor.state === "paused" ? "Your setup is preserved" : "On-demand monitoring is ready"} description={monitor.state === "paused" ? "Monitoring is paused. Review the cause in operations before resuming; reopening setup does not resume it." : monitor.cadence === "manual" ? "Scheduling is off. Run again whenever you choose; each run can make real provider calls." : `Your current cadence is ${monitor.cadence}. Finishing again does not change it.`}>
          <Button asChild id="guided-run-again"><Link href={`${base}/operations`}>{monitor.state === "paused" ? "Review paused monitor" : "Run again"} <ArrowRight /></Link></Button><p className="text-xs text-muted-foreground">Review current limits on the next screen before authorizing another run.</p>
          <div className="flex flex-wrap gap-4 text-sm"><Link className="underline" href={`${base}/results`}>View history, including this first capture</Link><Link className="underline" href={`${base}/operations#schedule-card`}>Schedule checks (optional)</Link></div>
        </Panel>}

        {!completed && <details className="rounded-xl border p-4 text-sm"><summary className="cursor-pointer font-medium">Need to correct something?</summary><div className="mt-4 space-y-4 leading-6">
          <p><Link className="underline" href={`${base}/contract`}>The checks are wrong</Link> — revise the shared rules and proof in advanced authoring. Existing evidence is preserved; changed semantics need a compatible reference.</p>
          <p>The input, expected answer or request is wrong — copy it into a new guided draft, then correct the source of truth and review the proof again. This creates a separate monitor; the original monitor and all its evidence remain unchanged. It does not stop an active capture or schedule.</p>
          <Button variant="outline" disabled={form.processing} onClick={() => submit("correct")}>Create corrected setup draft</Button>
          <p>The output is wrong — fix your upstream behavior, then reject this capture and authorize a new attempt. A provider error is not a quality regression; inspect connection/model access before retrying.</p>
          {snapshot?.terminal && snapshot.status === "pending" && owner && <><Button variant="outline" disabled={!confirmed || form.processing} onClick={() => submit("reject", resultIdentity)}>Reject this capture and prepare a retry</Button><p className="text-xs text-muted-foreground">Confirm result review above first. This retains evidence and makes no provider call. The next run requires fresh authorization.</p></>}
          <Link className="block underline" href={`${base}/baseline`}>Advanced reference review and exceptional acceptance</Link>
        </div></details>}
        {original && <details className="rounded-xl border p-4 text-sm"><summary className="cursor-pointer font-medium">Inspect saved request artifacts</summary><div className="mt-4 space-y-4">{props.requests.map(request => <section key={request.caseKey}><h2 className="mb-2 font-medium">{request.name}</h2><Code>{request.artifactJson}</Code><p className="mt-2 break-all text-xs">{request.fingerprint}</p></section>)}</div></details>}
        <footer className="border-t pt-4"><Button variant="ghost" asChild><Link href={`/app/${auth.workspace.slug}/monitors`}>Exit to monitors · progress is saved</Link></Button></footer>
      </div>
    </ProductShell>
  </>
}

function Confirmation({ checked, onChange, children }: { checked: boolean; onChange: (value: boolean) => void; children: ReactNode }) {
  return <label className="flex cursor-pointer items-start gap-3 text-sm leading-6"><input type="checkbox" className="mt-1 size-4 shrink-0 accent-primary" checked={checked} onChange={event => onChange(event.target.checked)} />{children}</label>
}
function Code({ children }: { children: string }) { return <pre className="max-h-72 overflow-auto rounded-lg bg-muted/50 p-3 text-xs">{children}</pre> }
function Metric({ label, value }: { label: string; value: number }) { return <div><dt className="text-xs text-muted-foreground">{label}</dt><dd className="mt-1 text-2xl font-semibold">{value}</dd></div> }
function Panel({ title, description, children }: { title: string; description: string; children: ReactNode }) { return <Card><CardHeader><CardTitle>{title}</CardTitle><CardDescription className="leading-6">{description}</CardDescription></CardHeader><CardContent className="space-y-5">{children}</CardContent></Card> }
