import { Head, Link, router, useForm, usePage } from "@inertiajs/react"
import { useEffect, useRef, useState, type ReactNode } from "react"
import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, Plus, Trash2 } from "lucide-react"
import { ProductShell } from "@/components/product-shell"
import { Alert, AlertTitle, AlertDescription } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useUnsavedChanges } from "@/hooks/use-unsaved-changes"
import type { SharedPageProps } from "@/types/page"
import { RecipeSettingsEditor, RecipeExpectationEditor, recipeNames, recipeGuidance, reconcileJsonValues, type Recipe, type RecipeSettings } from "@/components/guided-recipe-editors"

export type RoutingRaw = {
  name: string; description: string; provider: string; model: string; credentialId: string;
  mode: string; instruction: string; messages: Array<{ role: string; content: string }>;
  nativeJson: string; generationJson: string; labelsText: string;
  cases: Array<{ key: string; name: string; variables: Record<string, string>; context: string; expected: string }>;
}
type Step = "request" | "examples" | "checks" | "review"
type GuidedRaw = Omit<RoutingRaw, "labelsText"> & { labelsText?: string; settings?: RecipeSettings }
type Proof = { id: string; fingerprint: string; caseKey: string; name: string; inputJson: string; context: string; expected: string; output: string; proposedShared: string; proposedCase: string; shared: string; specific: string; reason: string; failedRuleIds?: string[] }
export type GuidedSetupProps = {
  auth: SharedPageProps["auth"]; step: Step;
  draft: { id: string; recipe?: Recipe; revision: number; rawJson: string; reviewedIds: string[] };
  journey: { stage: Step; variables: string[]; blockers: string[]; proof: Proof[]; reviewed: boolean; requests: Array<{ caseKey: string; name: string; artifactJson: string; fingerprint: string }> };
  models: Record<string, string[]>; credentials: Array<{ id: string; provider: string; label: string }>;
}
const steps: Step[] = ["request", "examples", "checks", "review"]
const titles = ["Connect the request you want to protect", "What should each input produce?", "Do these checks catch the mistakes you care about?", "Review the configuration before your first run"]

export default function GuidedSetup(props: GuidedSetupProps) {
  const { errors, flash } = usePage<SharedPageProps>().props
  return <GuidedSetupView {...props} errors={errors} flash={flash} />
}

export function GuidedSetupView({ auth, step, draft, journey, models, credentials, errors = {}, flash = {} }: GuidedSetupProps & { errors?: Record<string, string>; flash?: SharedPageProps["flash"] }) {
  const form = useForm({ raw: JSON.parse(draft.rawJson) as GuidedRaw, revision: draft.revision })
  const recipe = draft.recipe || "routing"
  const [confirmed, setConfirmed] = useState(draft.reviewedIds)
  const heading = useRef<HTMLHeadingElement>(null)
  const raw = form.data.raw
  const dirty = JSON.stringify(raw) !== JSON.stringify(JSON.parse(draft.rawJson)) || JSON.stringify([...confirmed].sort()) !== JSON.stringify([...draft.reviewedIds].sort())
  useUnsavedChanges(dirty)
  useEffect(() => {
    // A conflict must retain the old revision and current text; never silently rebase an edit.
    if (!errors.draft) {
      form.setData({ raw: JSON.parse(draft.rawJson), revision: draft.revision })
      setConfirmed(draft.reviewedIds)
    }
  }, [draft.id, draft.revision, draft.rawJson, errors.draft])
  useEffect(() => { heading.current?.focus() }, [step])
  if (!auth.workspace) return null
  const base = `/app/${auth.workspace.slug}`
  const path = `${base}/setup-drafts/${draft.id}`
  const position = steps.indexOf(step)
  const labels = (raw.labelsText || "").split("\n").map(label => label.trim()).filter(Boolean)
  const eligibleCredentials = credentials.filter(credential => credential.provider === raw.provider)
  function update<K extends keyof GuidedRaw>(key: K, value: GuidedRaw[K]) { form.setData("raw", { ...raw, [key]: value }); setConfirmed([]) }
  function updateSettings(settings: RecipeSettings) {
    const cases = recipe === "json" ? raw.cases.map(row => ({ ...row, expected: reconcileJsonValues(row.expected, raw.settings?.fields || [], settings.fields || []) })) : raw.cases
    form.setData("raw", { ...raw, settings, cases }); setConfirmed([])
  }
  function save(intent = "continue") {
    form.transform(data => ({ ...data, step, intent }))
    form.put(path, { preserveScroll: false })
  }
  function review(intent = "continue") {
    const judgments = journey.proof.filter(row => confirmed.includes(row.id)).map(row => ({ fingerprint: row.fingerprint, shared: row.proposedShared, specific: row.proposedCase }))
    form.transform(data => ({ revision: data.revision, judgments, intent }))
    form.post(`${path}/review`)
  }
  function updateCase(index: number, values: Partial<RoutingRaw["cases"][number]>) { update("cases", raw.cases.map((row, i) => i === index ? { ...row, ...values } : row)) }
  function reorder(index: number, direction: number) {
    const messages = [...raw.messages]
    ;[messages[index], messages[index + direction]] = [messages[index + direction], messages[index]]
    update("messages", messages)
  }
  const allConfirmed = journey.proof.length > 0 && journey.proof.every(row => confirmed.includes(row.id))
  return <>
    <Head title={`${titles[position]} · ${recipeNames[recipe]}`} />
    <ProductShell currentSection="monitors" releaseStage="Private alpha" availableWorkspaces={auth.workspaces} userEmail={auth.user?.email || "Invited user"} workspace={auth.workspace} membershipRole={auth.membership?.role || "member"}>
      <div className="mx-auto max-w-4xl space-y-6">
        <div className="flex flex-wrap items-center gap-3"><Badge variant="outline">Real monitor draft</Badge><Badge variant="secondary">{recipeNames[recipe]}</Badge><p className="text-sm text-muted-foreground">Saved in your workspace · no calls while authoring</p></div>
        <details className="text-sm text-muted-foreground"><summary className="cursor-pointer">Need a different output shape?</summary><p className="mt-2 leading-6">The recipe was chosen in Step 0. Save and exit first, then <Link className="underline" href={`${base}/setup-drafts/new`}>start a separate draft</Link>. Nothing transfers automatically; this draft and its review remain unchanged.</p></details>
        <nav aria-label="Setup progress"><ol className="flex flex-wrap gap-2 text-sm">{["Request", "Examples", "Prove checks", "Run once", "Review & finish"].map((label, index) => <li key={label} aria-current={index === position ? "step" : undefined} className={`rounded-md px-3 py-2 ${index === position ? "bg-primary/10 font-medium text-primary" : "bg-muted/30 text-muted-foreground"}`}>{index + 1}. {label}</li>)}</ol></nav>
        <header className="space-y-3"><h1 ref={heading} tabIndex={-1} className="text-3xl font-semibold tracking-tight outline-none">{titles[position]}</h1><p role="status" className="text-sm text-muted-foreground">{dirty ? "Unsaved changes" : `Saved revision ${draft.revision}`}. Save and exit keeps incomplete inputs too.</p></header>
        {errors.draft && <Alert variant="destructive"><AlertTitle>Changes were not saved</AlertTitle><AlertDescription><p>{errors.draft}</p><Button className="mt-3" variant="outline" onClick={() => router.visit(path, { preserveState: false })}>Reload latest saved draft</Button></AlertDescription></Alert>}
        {!errors.draft && !dirty && flash.info && <p role="status" className="text-sm text-muted-foreground">{flash.info}</p>}
        {journey.blockers.length > 0 && steps.indexOf(journey.stage) <= position && <aside className="rounded-xl border bg-muted/30 p-4 text-sm leading-6"><p className="font-medium">{dirty ? "Last saved check — save to validate your edits" : "Before you continue"}</p>{journey.blockers.map(message => <p key={message}>{message}</p>)}</aside>}

        {step === "request" && <Panel title="Your request, unchanged" description="Choose an existing validated connection. Paste your own instructions and ordered messages; the monitor adds no hidden prompt text.">
          <Field id="routing-name" label="Monitor name"><Input id="routing-name" maxLength={120} value={raw.name} onChange={event => update("name", event.target.value)} /></Field>
          <Field id="routing-description" label="What failure would matter? (optional)"><Textarea id="routing-description" maxLength={2000} value={raw.description} onChange={event => update("description", event.target.value)} /></Field>
          <div className="grid gap-4 sm:grid-cols-2"><ChoiceSelect id="routing-provider" label="Provider" value={raw.provider} options={["openai", "anthropic"]} onChange={value => { form.setData("raw", { ...raw, provider: value, model: "", credentialId: "" }); setConfirmed([]) }} /><ChoiceSelect id="routing-model" label="Model" value={raw.model} options={models[raw.provider] || []} onChange={value => update("model", value)} /></div>
          <ChoiceSelect id="routing-connection" label="Validated connection" value={raw.credentialId} options={eligibleCredentials.map(c => ({ value: c.id, label: c.label }))} onChange={value => update("credentialId", value)} />
          {eligibleCredentials.length === 0 && <p className="text-sm text-muted-foreground">No validated connection for this provider. You can save now. An owner can <Link className="underline" href={`${base}/credentials`}>configure a connection</Link> before continuing.</p>}
          <ChoiceSelect id="routing-editor" label="Request editor" value={raw.mode} options={[{ value: "messages", label: "Ordered messages" }, { value: "native", label: "Advanced: native template JSON" }]} onChange={value => update("mode", value)} />
          <p className="text-xs leading-5 text-muted-foreground">The two editors keep separate content; switching never silently converts or deletes it. Only the selected editor is used. Use {"{{variable_name}}"} where examples supply text.</p>
          {raw.mode === "native" ? <Field id="routing-native" label="Provider-native template JSON"><Textarea id="routing-native" className="min-h-48 font-mono text-sm" value={raw.nativeJson} onChange={event => update("nativeJson", event.target.value)} /><p className="text-xs text-muted-foreground">OpenAI: input and optional instructions. Anthropic: messages and optional system. Model and generation settings are configured separately; tools, images and arbitrary API fields remain unsupported.</p></Field> : <>
            <Field id="routing-instruction" label={raw.provider === "openai" ? "Instructions (optional)" : "System instruction (optional)"}><Textarea id="routing-instruction" value={raw.instruction} onChange={event => update("instruction", event.target.value)} /></Field>
            <div className="space-y-4">{raw.messages.map((message, index) => <fieldset key={index} className="space-y-3 rounded-lg border p-4"><legend className="px-1 text-sm font-medium">Message {index + 1}</legend>
              <ChoiceSelect id={`message-role-${index}`} label={`Role for message ${index + 1}`} value={message.role} options={raw.provider === "openai" ? ["user", "assistant", "system", "developer"] : ["user", "assistant"]} onChange={role => update("messages", raw.messages.map((row, i) => i === index ? { ...row, role } : row))} />
              <Field id={`message-content-${index}`} label={`Content for message ${index + 1}`}><Textarea id={`message-content-${index}`} value={message.content} onChange={event => update("messages", raw.messages.map((row, i) => i === index ? { ...row, content: event.target.value } : row))} /></Field>
              <div className="flex gap-2"><Button variant="ghost" size="sm" aria-label={`Move message ${index + 1} up`} disabled={index === 0} onClick={() => reorder(index, -1)}><ArrowUp /></Button><Button variant="ghost" size="sm" aria-label={`Move message ${index + 1} down`} disabled={index === raw.messages.length - 1} onClick={() => reorder(index, 1)}><ArrowDown /></Button><Button variant="ghost" size="sm" onClick={() => update("messages", raw.messages.filter((_, i) => i !== index))}><Trash2 /> Remove message {index + 1}</Button></div>
            </fieldset>)}</div>
            <Button variant="outline" disabled={raw.messages.length >= 20} onClick={() => update("messages", [...raw.messages, { role: raw.provider === "anthropic" && raw.messages.at(-1)?.role === "user" ? "assistant" : "user", content: "" }])}><Plus /> Add message</Button>
          </>}
          <details className="rounded-lg border p-4 text-sm"><summary className="cursor-pointer font-medium">Generation settings</summary><Field id="routing-generation" label="Generation settings JSON"><Textarea id="routing-generation" className="mt-3 font-mono" value={raw.generationJson} onChange={event => update("generationJson", event.target.value)} /><p className="text-xs leading-5 text-muted-foreground">max_output_tokens bounds each response. Provider/model-specific parameters are validated by the server. Unsupported settings are rejected, never ignored.</p></Field></details>
        </Panel>}

        {step === "examples" && <Panel title={recipe === "routing" ? "Labels and known answers" : `${recipeNames[recipe]}: shared rules and known answers`} description="First define what every answer must satisfy, then the known answer for each input. These are your expectations—not answers inferred from a model.">
          <p className="text-sm leading-6">{recipeGuidance[recipe]}</p>
          {recipe === "routing" ? <Field id="routing-labels" label="Allowed labels — one per line"><Textarea id="routing-labels" value={raw.labelsText} onChange={event => update("labelsText", event.target.value)} placeholder={"approved\nrejected"} /><p className="text-xs text-muted-foreground">2–8 labels. Whole-output match after Unicode normalization, case folding, and punctuation/whitespace normalization. No paraphrase matching.</p></Field> : <RecipeSettingsEditor recipe={recipe} settings={raw.settings || {}} onChange={updateSettings} />}
          {raw.cases.map((row, index) => <fieldset key={row.key} className="space-y-4 rounded-xl border p-4"><legend className="px-1 font-medium">Example {index + 1}</legend>
            <Field id={`case-name-${index}`} label={`Name for example ${index + 1}`}><Input id={`case-name-${index}`} value={row.name} onChange={event => updateCase(index, { name: event.target.value })} /></Field>
            {journey.variables.filter(variable => variable !== "frozen_context").map(variable => <Field key={variable} id={`case-${index}-${variable}`} label={`${variable} for example ${index + 1}`}><Textarea id={`case-${index}-${variable}`} value={row.variables[variable] || ""} onChange={event => updateCase(index, { variables: { ...row.variables, [variable]: event.target.value } })} /></Field>)}
            {journey.variables.includes("frozen_context") && <Field id={`case-context-${index}`} label={`Frozen context for example ${index + 1}`}><Textarea id={`case-context-${index}`} value={row.context} onChange={event => updateCase(index, { context: event.target.value })} /></Field>}
            {recipe === "routing" ? <ChoiceSelect id={`case-expected-${index}`} label={`Correct label for example ${index + 1}`} value={row.expected} options={[...new Set(labels)]} onChange={expected => updateCase(index, { expected })} /> : <RecipeExpectationEditor recipe={recipe} settings={raw.settings || {}} expected={row.expected} index={index} onChange={expected => updateCase(index, { expected })} />}
            <Button variant="ghost" size="sm" onClick={() => update("cases", raw.cases.filter((_, i) => i !== index))}><Trash2 /> Remove example {index + 1}</Button>
          </fieldset>)}
          <Button variant="outline" disabled={raw.cases.length >= 20} onClick={() => update("cases", [...raw.cases, { key: `case-${crypto.randomUUID()}`, name: "", variables: Object.fromEntries(journey.variables.filter(v => v !== "frozen_context").map(v => [v, ""])), context: "", expected: "" }])}><Plus /> Add example</Button>
          <p className="text-sm leading-6 text-muted-foreground">Use 1–20 representative inputs where you independently know the expected result. A correct rejection is a passing case. Unknown semantic correctness is outside these deterministic recipes.</p>
        </Panel>}

        {step === "checks" && <Panel title="Review proposed good and bad outputs" description="These synthetic outputs test your checks locally using the production evaluators. They are not provider results. Read each proposal and confirm only judgments you agree with.">
          <p className="text-sm leading-6">{recipeGuidance[recipe]}</p>
          {journey.proof.map((row, index) => <article key={row.id} className="space-y-3 rounded-xl border p-4" aria-label={`Proof ${index + 1}`}>
            <h2 className="font-medium">{row.name}</h2><pre className="overflow-x-auto rounded-md bg-muted/40 p-3 text-xs">{row.inputJson}</pre>{row.context && <pre className="overflow-x-auto text-xs">{row.context}</pre>}
            <dl className="grid gap-3 sm:grid-cols-2"><div><dt className="text-xs text-muted-foreground">Declared expectation</dt><dd className="whitespace-pre-wrap break-all font-mono">{row.expected}</dd></div><div><dt className="text-xs text-muted-foreground">Proposed output</dt><dd className="whitespace-pre-wrap break-all font-mono">{row.output === "" ? "(empty output)" : row.output}</dd></div></dl>
            {row.failedRuleIds && <p className="text-xs text-muted-foreground">Shared rules expected to fail: {row.failedRuleIds.join(", ") || "none"}. All other shared rules should pass.</p>}
            <div className="flex flex-wrap gap-2"><Badge variant={row.shared === "pass" ? "secondary" : "destructive"}>Shared: {row.shared}</Badge><Badge variant={row.specific === "pass" ? "secondary" : "destructive"}>Case: {row.specific}</Badge></div><p className="text-sm text-muted-foreground">{row.reason}</p>
            <label className="flex cursor-pointer items-start gap-3 text-sm leading-6"><input className="mt-1 size-4 shrink-0 accent-primary" type="checkbox" checked={confirmed.includes(row.id)} onChange={() => setConfirmed(confirmed.includes(row.id) ? confirmed.filter(id => id !== row.id) : [...confirmed, row.id])} />I judge proof {index + 1}: shared should {row.proposedShared}; this case should {row.proposedCase}. I agree with the rule failures listed above.</label>
          </article>)}
          <p className="text-sm leading-6 text-muted-foreground">Disagree? Go back and correct the input or expected answer. Do not approve just because the evaluator agrees. Changes invalidate the previous review.</p>
        </Panel>}

        {step === "review" && <Panel title="Ready for first-run review" description="Your request, cases and human-reviewed proof are ready to be saved as a fixed configuration. No provider call or schedule is authorized by this action.">
          <dl className="grid gap-4 sm:grid-cols-3"><div><dt className="text-xs text-muted-foreground">Monitor</dt><dd className="font-medium">{raw.name}</dd></div><div><dt className="text-xs text-muted-foreground">Inputs</dt><dd>{raw.cases.length}</dd></div><div><dt className="text-xs text-muted-foreground">Proof judgments</dt><dd>{draft.reviewedIds.length} confirmed</dd></div></dl>
          <p className="text-sm leading-6">Next, {auth.membership?.role === "owner" ? "you will" : "an owner must"} approve the exact checks and authorize a bounded first capture in this guided flow. Review actual input → expected → actual results, then finish setup for on-demand checks. Scheduling stays optional and off.</p>
          <p className="text-sm text-muted-foreground">Need to change your request or expectations? Go back now. After this handoff the configuration is fixed; later behavior changes use a new version.</p>
        </Panel>}

        {journey.requests.length > 0 && <details className="rounded-xl border p-4 text-sm"><summary className="cursor-pointer font-medium">Inspect exact provider requests · saved revision {draft.revision}</summary><p className="mt-3 text-xs text-muted-foreground">These secret-free artifacts are produced by the same server builder used for capture. Unsaved edits are not reflected here.</p><div className="mt-4 space-y-5">{journey.requests.map(request => <section key={request.caseKey}><h2 className="mb-2 font-medium">{request.name}</h2><pre className="max-h-80 overflow-auto rounded-md bg-muted p-3 text-xs">{request.artifactJson}</pre><p className="mt-2 break-all font-mono text-xs">{request.fingerprint}</p></section>)}</div></details>}
        <footer className="flex flex-col-reverse gap-3 border-t pt-5 sm:flex-row sm:justify-between"><div className="flex flex-wrap gap-2">
          {position > 0 && <Button variant="ghost" asChild><Link href={`${path}/${steps[position - 1]}`}><ArrowLeft /> Back</Link></Button>}
          <Button variant="outline" disabled={form.processing} onClick={() => step === "checks" ? review("exit") : save("exit")}>Save and exit</Button>
        </div>
          {position < 2 ? <Button id="guided-primary" disabled={form.processing} onClick={() => save()}>Save and continue <ArrowRight /></Button> : step === "checks" ? <Button id="guided-primary" disabled={form.processing || !allConfirmed} onClick={() => review()}>Confirm checks and continue <ArrowRight /></Button> : <Button id="guided-primary" disabled={form.processing || !journey.reviewed || dirty} onClick={() => { form.transform(data => ({ revision: data.revision })); form.post(`${path}/seal`) }}>Prepare first-run review <ArrowRight /></Button>}
        </footer>
      </div>
    </ProductShell>
  </>
}

function Panel({ title, description, children }: { title: string; description: string; children: ReactNode }) { return <Card><CardHeader><CardTitle>{title}</CardTitle><CardDescription className="leading-6">{description}</CardDescription></CardHeader><CardContent className="space-y-5">{children}</CardContent></Card> }
function Field({ id, label, children }: { id: string; label: string; children: ReactNode }) { return <div className="space-y-2"><Label htmlFor={id}>{label}</Label>{children}</div> }
function ChoiceSelect({ id, label, value, options, onChange }: { id: string; label: string; value: string; options: Array<string | { value: string; label: string }>; onChange: (value: string) => void }) {
  return <Field id={id} label={label}><Select value={value} onValueChange={onChange}><SelectTrigger id={id} className="w-full"><SelectValue placeholder="Choose…" /></SelectTrigger><SelectContent>{options.map(option => { const item = typeof option === "string" ? { value: option, label: option } : option; return <SelectItem key={item.value} value={item.value}>{item.label}</SelectItem> })}</SelectContent></Select></Field>
}
