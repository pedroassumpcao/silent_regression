import { Head, Link } from "@inertiajs/react"
import { useEffect, useRef, useState, type ReactNode } from "react"
import { ArrowLeft, ArrowRight, Check, FlaskConical, ShieldCheck } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useUnsavedChanges } from "@/hooks/use-unsaved-changes"
import { cn } from "@/lib/utils"
import {
  canFinish, changeExpectation, labels, newDraft, outputFor, proofAgrees, proofExamples,
  readDraft, requestFor, revisionFor, runSimulation, scenarios, steps,
  type Evidence, type PreviewDraft, type Recipe, type Scenario,
} from "@/lib/setup-preview"
import type { SharedPageProps } from "@/types/page"

type Props = { auth: SharedPageProps["auth"] }

export default function SetupPreview({ auth }: Props) {
  if (!auth.workspace || !auth.user) return null
  return <SetupPreviewView key={`${auth.workspace.id}:${auth.user.id}`} storageKey={`setup-preview:v1:${auth.workspace.id}:${auth.user.id}`} workspaceSlug={auth.workspace.slug} workspaceName={auth.workspace.name} />
}

export function SetupPreviewView({ storageKey, workspaceSlug, workspaceName }: { storageKey: string; workspaceSlug: string; workspaceName: string }) {
  const [initial] = useState(() => {
    try {
      const raw = sessionStorage.getItem(storageKey)
      const restored = readDraft(raw)
      return { draft: restored ?? newDraft(), restored: Boolean(restored), warning: raw && !restored ? "An old or unreadable preview was ignored. Start a new simulation below." : "" }
    } catch { return { draft: newDraft(), restored: false, warning: "Tab storage is unavailable. This preview cannot save until browser storage is enabled." } }
  })
  const [draft, setDraft] = useState(initial.draft)
  const [selecting, setSelecting] = useState(initial.draft.step === -1)
  const [selection, setSelection] = useState({ recipe: initial.draft.recipe, scenario: initial.draft.scenario })
  const [saved, setSaved] = useState(initial.restored ? JSON.stringify(initial.draft) : "")
  const [paused, setPaused] = useState(false)
  const [error, setError] = useState(initial.warning)
  const [authorized, setAuthorized] = useState(false)
  const [reviewed, setReviewed] = useState(false)
  const [recovery, setRecovery] = useState<"output" | "expectation">("output")
  const heading = useRef<HTMLHeadingElement>(null)
  const currentRevision = revisionFor(draft)
  const dirty = draft.step >= 0 && JSON.stringify(draft) !== saved
  useUnsavedChanges(dirty)

  useEffect(() => {
    setAuthorized(false)
    setReviewed(false)
    heading.current?.focus()
  }, [draft.step, draft.recipe, draft.scenario, draft.finished, draft.handedOff, paused, selecting])

  useEffect(() => { setAuthorized(false); setReviewed(false) }, [currentRevision])

  function persist(next: PreviewDraft) {
    try {
      sessionStorage.setItem(storageKey, JSON.stringify(next))
      setSaved(JSON.stringify(next))
      setDraft(next)
      setError("")
      return true
    } catch {
      setError("Could not save in this tab. Your edits are still here. Enable browser storage and try again before leaving.")
      return false
    }
  }

  function navigate(step: number) {
    persist({ ...draft, step, finished: false })
  }

  function chooseSimulation() {
    setSelection({ recipe: draft.recipe, scenario: draft.scenario })
    setError("")
    setSelecting(true)
  }

  function startSimulation() {
    if (persist({ ...newDraft(selection.recipe, selection.scenario), step: 0 })) {
      setPaused(false)
      setSelecting(false)
    }
  }

  function advance() {
    if (!draft.name.trim()) { setError("Give this example monitor a name before continuing."); return }
    if (draft.step === 1 && draft.examples.some(example => !labels.includes(example.expected))) {
      setError("Each expected answer must be approved or rejected. You can still save an incomplete preview and return.")
      return
    }
    if (draft.step === 2) {
      if (draft.judgments.length !== 4 || !proofAgrees(draft)) return
      persist({ ...draft, step: 3, proof: currentRevision })
    } else navigate(draft.step + 1)
  }

  function run() {
    if (!authorized) return
    persist(runSimulation(draft))
  }

  const attempt = draft.attempts.at(-1)
  const passing = canFinish(draft)
  const member = draft.scenario === "member" && !draft.handedOff
  const displayStep = selecting ? -1 : draft.step
  const replacing = draft.step >= 0
  const title = selecting ? "Choose the simulation you want to explore" : paused ? "Your preview is saved in this tab" : draft.finished ? "Practice walkthrough complete" : [
    "Connect the request you want to protect", "What should each input produce?", "Do these checks catch the mistakes you care about?",
    member ? "An owner needs to approve this run" : "Review the first run before authorizing it", "Understand the result, then finish",
  ][draft.step]

  return (
    <div className="min-h-screen bg-background text-foreground">
      <Head title={`${selecting ? "Step 0: Choose simulation" : draft.finished ? "Complete" : `Step ${draft.step + 1} of 5`}: setup design preview`} />
      <header className="border-b bg-card">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-3 px-5 py-4 sm:px-8">
          <div className="flex items-center gap-3"><ShieldCheck className="size-6 text-primary" /><span className="font-semibold tracking-tight">Silent Regression</span><Badge variant="secondary">Design preview</Badge></div>
          <span className="text-sm text-muted-foreground">{workspaceName}</span>
        </div>
      </header>
      <main className="mx-auto max-w-6xl space-y-6 px-5 py-7 sm:px-8 sm:py-10">
        <div className="flex items-start gap-3 rounded-xl border border-primary/20 bg-primary/5 p-4 text-sm leading-6">
          <FlaskConical className="mt-1 size-5 shrink-0 text-primary" />
          <p><strong>Practice preview · 0 provider calls.</strong> Learn and review the proposed flow with fictional data. This simulation does not create or become a real monitor. Saves stay in this browser tab, not your workspace.</p>
        </div>

        {!selecting && <div className="flex flex-col gap-3 rounded-xl border bg-card p-4 text-sm sm:flex-row sm:items-center sm:justify-between">
          <p><span className="font-medium">{draft.recipe === "routing" ? "Routing" : "Structured JSON"}</span><span className="text-muted-foreground"> · {scenarios.find(scenario => scenario.value === draft.scenario)?.label}</span></p>
          <Button variant="outline" onClick={chooseSimulation}>Start a different simulation</Button>
        </div>}

        <nav aria-label="Setup progress"><ol className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-6">
          {["Choose simulation", ...steps].map((label, index) => <li key={label} aria-current={(selecting || (!paused && !draft.finished)) && displayStep + 1 === index ? "step" : undefined} className={cn("flex items-center gap-2 rounded-lg px-3 py-3 text-xs sm:text-sm", index === displayStep + 1 ? "bg-primary/10 font-medium text-primary" : "text-muted-foreground")}>
            <span className={cn("flex size-6 shrink-0 items-center justify-center rounded-full border", index < displayStep + 1 || (!selecting && draft.finished) ? "border-primary/20 bg-primary/10 text-primary" : "border-current/20")}>{index < displayStep + 1 || (!selecting && draft.finished) ? <Check className="size-3.5" aria-label="Completed" /> : index}</span>{label}
          </li>)}
        </ol></nav>

        <section className="space-y-2">
          <p className="text-xs font-medium uppercase tracking-widest text-primary">{selecting ? "Step 0 · Choose simulation" : paused ? "Paused" : draft.finished ? "Simulation complete · no real monitor created" : `Step ${draft.step + 1} of 5 · ${draft.recipe === "routing" ? "Routing" : "Structured JSON"}`}</p>
          <h1 ref={heading} tabIndex={-1} className="max-w-3xl text-3xl font-semibold leading-tight tracking-tight outline-none sm:text-4xl">{title}</h1>
          <p role="status" className="text-sm text-muted-foreground">{selecting ? replacing ? "Your current simulation stays intact until you start its replacement." : "Choose a scenario first, then follow the five setup steps. Nothing has started yet." : `${dirty ? "Unsaved preview changes" : initial.restored && saved === JSON.stringify(initial.draft) ? "Restored from this tab" : "Saved in this tab only"}. Tab-session preview only; another device cannot resume it.`}</p>
        </section>

        {error && <div role="alert" className="rounded-xl border border-destructive/30 bg-destructive/5 p-4 text-sm text-destructive">{error}</div>}

        {selecting ? <Panel title="Set the scene before you begin" description="Choose the output shape and the situation you want to walk through. These choices control fictional results for this design review—not the outcome of a real monitor.">
          <div className="grid gap-6 md:grid-cols-2">
            <fieldset className="space-y-3"><legend className="mb-3 font-medium">Output shape</legend>
              {([['routing', 'Classification / routing'], ['json', 'Structured JSON']] as const).map(([value, label]) => <Choice key={value} type="radio" name="recipe" checked={selection.recipe === value} onChange={() => setSelection({ ...selection, recipe: value as Recipe })}>{label}</Choice>)}
            </fieldset>
            <fieldset className="space-y-3"><legend className="mb-3 font-medium">Scenario to explore</legend>
              {scenarios.map(scenario => <Choice key={scenario.value} type="radio" name="scenario" checked={selection.scenario === scenario.value} onChange={() => setSelection({ ...selection, scenario: scenario.value as Scenario })}>{scenario.label}</Choice>)}
            </fieldset>
          </div>
          <p className="mt-5 text-sm leading-6 text-muted-foreground">Start with Passing outputs to learn the journey. Other scenarios let you explore a failure or owner handoff. Your real workspace role never changes.</p>
          {replacing && <div className="mt-5 rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm leading-6"><p className="font-medium">Starting over resets this preview</p><p>The new simulation starts at Step 1. It replaces the current name, expected answers, proof review, progress, and mock attempt history in this tab. Real monitors are unaffected. Cancel below to keep your current work.</p></div>}
          <div className="mt-6 flex flex-col-reverse gap-3 border-t pt-5 sm:flex-row sm:items-center sm:justify-between">
            {replacing ? <Button variant="outline" onClick={() => { setError(""); setSelecting(false) }}>Keep current simulation</Button> : <p className="text-xs text-muted-foreground">Prototype only · no provider calls</p>}
            <Button id="preview-primary" onClick={startSimulation}>{replacing ? "Start new simulation" : "Start simulation"} <ArrowRight /></Button>
          </div>
        </Panel> : paused ? <Panel title="Pick up where you left off" description={`Next: ${steps[draft.step]}. This is not a real monitor draft.`}>
          <Button onClick={() => setPaused(false)}>Resume preview <ArrowRight /></Button>
          <p className="mt-4 text-sm"><Link className="underline underline-offset-4" href={`/app/${workspaceSlug}/monitors`}>Leave preview and open real monitors</Link></p>
        </Panel> : draft.finished ? <Panel title="You practiced reviewing a first result" description="This walkthrough is complete. Its fictional inputs, checks and results are not copied into a real monitor.">
          <dl className="grid gap-4 sm:grid-cols-3"><Summary label="Inputs checked" value="2 of 2 passing (simulated)" /><Summary label="Reference" value="Reviewed (simulated)" /><Summary label="Schedule" value="Off · on-demand only (simulated)" /></dl>
          <p className="my-5 text-sm text-muted-foreground">For a real monitor, you will configure your own request and examples, authorize provider calls, and review the actual results. Finishing that setup makes it ready for on-demand checks; it does not enable a schedule. Nothing was approved or activated here.</p>
          <Button onClick={() => persist({ ...draft, step: 3, finished: false })}>Review another simulated run <ArrowRight /></Button>
          <details className="mt-5 border-t pt-4 text-sm"><summary className="cursor-pointer font-medium">Optional: schedule checks later</summary><p className="mt-3 text-muted-foreground">The real product supports daily or weekly checks, with a separate owner authorization and call budget. This preview leaves scheduling off.</p></details>
        </Panel> : <>
          {draft.step === 0 && <Panel title="Start with the request, not a rule editor" description="This fixed example keeps the first design review focused. Real provider selection, encrypted keys, editable messages and native request import come in later stages.">
            <div className="space-y-5">
              <div className="space-y-2"><Label htmlFor="preview-name">Monitor name</Label><Input id="preview-name" maxLength={120} value={draft.name} onChange={event => setDraft({ ...draft, name: event.target.value })} /></div>
              <dl className="grid gap-4 sm:grid-cols-3"><Summary label="Connection" value="Mock provider · no key" /><Summary label="Model" value="mock-model" /><Summary label="Output" value={draft.recipe === "routing" ? "One exact label" : "A JSON decision object"} /></dl>
              <div className="rounded-lg bg-muted/50 p-4 text-sm leading-6"><p className="font-medium">Your request’s instruction</p><p className="mt-1">For action=allow return approved; for action=deny return rejected. {draft.recipe === "json" ? 'Return only a JSON object with a string field "decision".' : "Return only the label."}</p></div>
              <p className="text-sm text-muted-foreground">This example uses one input variable: <code className="text-foreground">action</code>. Next, review its representative values and tell us the answer you expect for each.</p>
              <RequestPreview draft={draft} />
            </div>
          </Panel>}

          {draft.step === 1 && <Panel title="Two examples, two explicit expectations" description="These are answers you know should be correct—not answers inferred from the model. The sample inputs are fixed in this prototype.">
            <div className="space-y-4">{draft.examples.map((example, index) => <div key={example.input} className="grid items-start gap-4 rounded-xl border p-4 sm:grid-cols-2">
              <div><p className="text-xs uppercase tracking-wide text-muted-foreground">Example {index + 1} · input</p><p className="mt-2 font-mono">action={example.input}</p><p className="mt-2 text-sm text-muted-foreground">{example.input === "allow" ? "This action should be approved." : "This action should be rejected. Rejection is correct behavior here."}</p></div>
              <div className="space-y-2"><Label htmlFor={`expected-${index}`}>{draft.recipe === "json" ? "Expected decision field" : "Expected label"} for {example.input}</Label><Input id={`expected-${index}`} aria-describedby={`expected-help-${index}`} value={example.expected} maxLength={80} onChange={event => setDraft(changeExpectation(draft, index, event.target.value))} /><p id={`expected-help-${index}`} className="text-xs text-muted-foreground">Choose approved or rejected. Exact match; no paraphrase judgment.</p>{draft.recipe === "json" && <code className="block break-all text-xs">{outputFor(draft.recipe, example.expected)}</code>}</div>
            </div>)}</div>
            <p className="mt-4 text-sm text-muted-foreground">Both outputs are allowed in general. Only one is correct for each input. Later recipes can explicitly declare format-only coverage; this routing example requires known answers.</p>
          </Panel>}

          {draft.step === 2 && <Panel title="Review examples of good and bad output" description="The proposed judgments below come from this fixed scenario. Confirm them yourself; agreeing with a check is not proof of general model quality.">
            <dl className="mb-5 grid gap-3 sm:grid-cols-2"><Summary label="Shared check · every input" value={draft.recipe === "routing" ? "Output is approved or rejected" : "JSON object; decision is a string: approved or rejected"} /><Summary label="Case check · this input" value={draft.recipe === "routing" ? "Output equals its expected label" : "decision equals this input’s expected value"} /></dl>
            {!proofAgrees(draft) && <div role="alert" className="mb-5 rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm">Your expected answers disagree with the proposed examples. Check the request and correct the expectation—or reject this suggested proof. You cannot approve conflicting judgments.</div>}
            <div className="space-y-4">{proofExamples(draft).map(row => <article key={row.id} className="rounded-xl border p-4" aria-label={`Proof example ${row.id + 1}`}>
              <EvidenceRow evidence={row} />
              <Choice checked={draft.judgments.includes(row.id)} onChange={() => setDraft({ ...draft, proof: null, judgments: draft.judgments.includes(row.id) ? draft.judgments.filter(id => id !== row.id) : [...draft.judgments, row.id] })}>I judge example {row.id + 1} should {row.intended}.</Choice>
            </article>)}</div>
            <p className="mt-4 text-xs text-muted-foreground">Local simulation logic only, not production evaluator evidence. Any expectation change clears this review. Structured JSON checks here cover this one field, not arbitrary JSON Schema or factual truth.</p>
          </Panel>}

          {draft.step === 3 && <Panel title={member ? "Share the reviewed setup with an owner" : "A small, explicit first capture"} description={member ? "Members can prepare examples and checks. Owners approve provider spend. Nothing is sent by this preview." : "The production action would approve these checks and authorize one bounded first capture, with separate audit records."}>
            {draft.scenario === "member" && draft.handedOff && <p role="status" className="mb-5 rounded-lg bg-primary/5 p-3 text-sm">Now viewing the simulated owner review. Your actual role has not changed; no handoff message was sent.</p>}
            <dl className="grid gap-4 sm:grid-cols-3"><Summary label="Capture size" value="2 inputs × 1 sample" /><Summary label="Call ceiling (proposed)" value="2 planned · 4 maximum" /><Summary label="Actual cost here" value="0 calls · $0" /></dl>
            <p className="mt-4 text-sm leading-6 text-muted-foreground">The real ceiling includes at most one retry per input. Metadata validation is separate. Real cost depends on your provider and token usage; no currency estimate is available in this mock connection.</p>
            <RequestPreview draft={draft} />
            {!member && <div className="mt-5"><Choice checked={authorized} onChange={() => setAuthorized(value => !value)}>I understand the proposed 4-call maximum and authorize this simulation only.</Choice></div>}
          </Panel>}

          {draft.step === 4 && attempt && <Panel title={attempt.failed ? "The provider did not return a usable result" : passing ? "Both inputs matched their expected behavior" : "An allowed output was wrong for its input"} description={`Simulated attempt ${attempt.number}. Inspect the input, expected answer, actual output, and reason before deciding what to do.`}>
            {attempt.failed ? <div className="rounded-xl border border-destructive/25 bg-destructive/5 p-4 text-sm leading-6"><p className="font-medium">Provider unavailable (simulated)</p><p>No quality judgment or reference can be made from this attempt. Keep the reviewed checks, resolve the provider issue, and explicitly authorize a new attempt. The next mock attempt simulates recovery.</p></div> : <div className="space-y-4">{attempt.evidence.map(row => <article key={row.input} aria-label={`Result for ${row.input}`} className="rounded-xl border p-4"><EvidenceRow evidence={row} /></article>)}</div>}
            {passing && <div className="mt-5 space-y-3"><Choice checked={reviewed} onChange={() => setReviewed(value => !value)}>I reviewed both outputs and want this result as the reference in this simulation.</Choice><p className="text-sm leading-6 text-muted-foreground">Finish setup completes this practice walkthrough only. In a real monitor, on-demand means checks run when you select Run now, using your provider and potentially incurring cost. Scheduled checks are optional and need separate authorization.</p></div>}
            {!passing && !attempt.failed && <fieldset className="mt-5 space-y-3 rounded-lg bg-muted/40 p-4"><legend className="px-1 text-sm font-medium">What needs to change?</legend>
              <Choice type="radio" name="recovery" checked={recovery === "output"} onChange={() => setRecovery("output")}>The output is wrong. Keep my expectations.</Choice>
              <Choice type="radio" name="recovery" checked={recovery === "expectation"} onChange={() => setRecovery("expectation")}>My expectation is wrong. Edit it and review the proof again.</Choice>
              <p className="text-xs leading-5 text-muted-foreground">The first option simulates an upstream fix before retrying; this app does not repair model output. The second never silently copies an observed answer into your expectations.</p>
            </fieldset>}
          </Panel>}

          <footer className="flex flex-col-reverse gap-3 border-t pt-5 sm:flex-row sm:items-center sm:justify-between">
            <div className="flex flex-wrap gap-2">
              {draft.step > 0 && <Button variant="ghost" onClick={() => navigate(draft.step - 1)}><ArrowLeft /> Back</Button>}
              <Button variant="outline" onClick={() => { if (persist(draft)) setPaused(true) }}>Save and exit preview</Button>
            </div>
            {draft.step < 2 && <Button id="preview-primary" onClick={advance}>{draft.step === 0 ? "Continue to examples" : "Continue to checks"} <ArrowRight /></Button>}
            {draft.step === 2 && (proofAgrees(draft) ? <Button id="preview-primary" disabled={draft.judgments.length !== 4} onClick={advance}>Confirm checks and continue <ArrowRight /></Button> : <Button id="preview-primary" onClick={() => navigate(1)}>Correct expected answers <ArrowLeft /></Button>)}
            {draft.step === 3 && (member ? <Button id="preview-primary" onClick={() => persist({ ...draft, handedOff: true })}>Preview owner review <ArrowRight /></Button> : <Button id="preview-primary" disabled={!authorized} onClick={run}>Run simulation · 0 calls <ArrowRight /></Button>)}
            {draft.step === 4 && (passing ? <Button id="preview-primary" disabled={!reviewed} onClick={() => { if (reviewed && canFinish(draft)) persist({ ...draft, finished: true }) }}>Finish setup <Check /></Button> : <Button id="preview-primary" onClick={() => {
              if (!attempt?.failed && recovery === "expectation") persist({ ...draft, step: 1, proof: null, judgments: [], finished: false, handedOff: false })
              else persist({ ...draft, step: 3, outputRecovered: draft.outputRecovered || draft.scenario === "wrong_output", finished: false })
            }}>{attempt?.failed ? "Review retry authorization" : recovery === "expectation" ? "Correct expected answers" : "Review retry after upstream fix"} <ArrowRight /></Button>)}
          </footer>
          {draft.step === 2 && proofAgrees(draft) && <p className="text-right text-xs text-muted-foreground">Confirm all four judgments to continue ({draft.judgments.length}/4).</p>}
        </>}

        {!selecting && !paused && draft.attempts.length > 0 && <details className="rounded-xl border p-4 text-sm"><summary className="cursor-pointer font-medium">Simulation history · {draft.attempts.length} retained attempts</summary><p className="mt-3 text-xs text-muted-foreground">Last five attempts only, kept in this tab. Real immutable history is unchanged.</p><div className="mt-4 space-y-4">{draft.attempts.map(item => <div key={item.number} className="rounded-lg bg-muted/40 p-3"><p className="font-medium">Attempt {item.number} · {item.failed ? "provider failure" : item.evidence.every(row => row.shared === "pass" && row.specific === "pass") ? "checks passed" : "checks failed"}</p>{item.evidence.map(row => <p key={row.input} className="mt-2 break-all font-mono text-xs">{row.input}: expected {row.expected} → actual {row.actual}</p>)}</div>)}</div></details>}
      </main>
    </div>
  )
}

function Panel({ title, description, children }: { title: string; description: string; children: ReactNode }) {
  return <Card className="border-primary/15 shadow-sm"><CardHeader><CardTitle className="text-xl">{title}</CardTitle><CardDescription className="max-w-3xl leading-6">{description}</CardDescription></CardHeader><CardContent>{children}</CardContent></Card>
}

function Summary({ label, value }: { label: string; value: string }) {
  return <div className="min-w-0 rounded-lg border bg-muted/20 p-3"><dt className="text-xs text-muted-foreground">{label}</dt><dd className="mt-1 text-sm font-medium wrap-anywhere">{value}</dd></div>
}

function Choice({ checked, onChange, children, type = "checkbox", name }: { checked: boolean; onChange: () => void; children: ReactNode; type?: "radio" | "checkbox"; name?: string }) {
  return <label className="flex cursor-pointer items-start gap-3 rounded-md py-1 text-sm leading-6"><input type={type} name={name} checked={checked} onChange={onChange} className="mt-1 size-4 shrink-0 accent-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary" /><span>{children}</span></label>
}

function EvidenceRow({ evidence }: { evidence: Evidence }) {
  return <div className="mb-3 space-y-3"><dl className="grid gap-3 sm:grid-cols-3"><Summary label="Input" value={`action=${evidence.input}`} /><Summary label="Expected" value={evidence.expected} /><Summary label="Actual (simulated)" value={evidence.actual} /></dl><div className="flex flex-wrap gap-2"><Badge variant={evidence.shared === "pass" ? "secondary" : "destructive"}>Shared: {evidence.shared}</Badge><Badge variant={evidence.specific === "pass" ? "secondary" : "destructive"}>Case: {evidence.specific}</Badge></div><p className="text-sm leading-6 text-muted-foreground">{evidence.reason}</p></div>
}

function RequestPreview({ draft }: { draft: PreviewDraft }) {
  return <details className="mt-5 rounded-lg border p-4 text-sm"><summary className="cursor-pointer font-medium">Inspect rendered requests · ordered messages and settings</summary><p className="mt-3 text-xs text-muted-foreground">Mock wire shape only. Production will show the exact provider-native artifact without rewriting your prompt. No hidden instructions are added here.</p><div className="mt-4 grid min-w-0 gap-4 md:grid-cols-2">{draft.examples.map(example => <div key={example.input} className="min-w-0"><p className="mb-2 font-medium">action={example.input}</p><pre className="overflow-x-auto rounded-md bg-muted p-3 text-xs leading-5">{JSON.stringify(requestFor(draft, example.input), null, 2)}</pre></div>)}</div></details>
}
