import { FormEvent, useState } from "react"
import { Head, Link, router, useForm, usePage } from "@inertiajs/react"
import {
  AlertTriangle,
  ArrowLeft,
  Check,
  CheckCircle2,
  ChevronRight,
  CircleDashed,
  Code2,
  FlaskConical,
  Info,
  LoaderCircle,
  LockKeyhole,
  Pencil,
  Plus,
  Save,
  ShieldCheck,
  Sparkles,
  Trash2,
  XCircle,
} from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Textarea } from "@/components/ui/textarea"
import type { SharedPageProps } from "@/types/page"

type AssistanceMode = "self_serve" | "founder_assisted" | "codex_assisted"
type ContractStatus = "draft" | "approved"
type RuleStatus = "pass" | "fail" | "evaluator_error"
type JsonScalar = string | number | boolean | null
type Rule = {
  id: string
  type: RuleType
  path?: string
  expected_type?: string
  expected?: JsonScalar
  numeric_comparison?: string
  allowed_values?: JsonScalar[]
  minimum?: number
  maximum?: number
  target?: number
  tolerance?: number
  alternatives?: string[]
  source_ids?: string[]
  require_at_least_one?: boolean
  fact_alternatives?: string[]
  max_distance_characters?: number
  unit?: string
}
type RuleFieldValue = JsonScalar | JsonScalar[] | string[] | number | boolean
type RuleType = (typeof ruleTypes)[number]["value"]
type Root = { id: "contract"; type: "all"; rules: Rule[] }

type Template = {
  key: string
  title: string
  description: string
  bestFor: string
  limitation: string
  root: Root
}

type ContractVersion = {
  id: string
  version: number
  status: ContractStatus
  predecessorId: string | null
  approvedAt: string | null
  approvedByUserId: string | null
  fingerprint: string
  contractFingerprint: string
  fixtureSetFingerprint: string
  templateKey: string
  templateUsage: {
    templateKey: string
    rules: Array<{
      suggestionId: string | null
      ruleId: string | null
      ruleType: string
      action: "accepted" | "edited" | "removed" | "added"
    }>
  }
  assistanceMode: AssistanceMode
  root: Root
  rootJson?: string
}

type RuleResult = {
  ruleId: string
  ruleType: string
  status: RuleStatus
  code: string
  explanation: string
  evidence: Record<string, unknown>
  childRuleIds: string[]
}

type Fixture = {
  id: string
  name: string
  position: number
  outputText: string
  expectedStatus: "pass" | "fail"
  expectedRuleStatuses: Record<string, "pass" | "fail">
  expectedFailedRuleIds: string[]
  fingerprint: string
  judgmentComplete: boolean
  matches: boolean
  actual: {
    status: RuleStatus
    error: Record<string, unknown> | null
    ruleResults: RuleResult[]
  }
}

type Blocker = { code: string; message: string; fixtureId: string | null }

export type ContractAuthoringProps = {
  approvedContract: Pick<ContractVersion, "id" | "version" | "status" | "fingerprint" | "approvedAt"> | null
  auth: SharedPageProps["auth"]
  canApprove: boolean
  contract: ContractVersion | null
  fixtures: Fixture[]
  limits: { maxFixtures: number; maxOutputBytes: number }
  monitor: { id: string; name: string; description: string; state: string; version: number }
  readiness: { ready: boolean; blockers: Blocker[] }
  releaseStage: string
  templates: Template[]
}

type ServerTemplate = Omit<Template, "root"> & { rootJson: string }
type ServerContract = Omit<ContractVersion, "root"> & { rootJson: string }
type ServerFixture = Omit<Fixture, "expectedRuleStatuses"> & { expectedRuleStatusesJson: string }
type ServerContractAuthoringProps = Omit<ContractAuthoringProps, "contract" | "fixtures" | "templates"> & {
  contract: ServerContract | null
  fixtures: ServerFixture[]
  templates: ServerTemplate[]
}

const ruleTypes = [
  { value: "json_valid", label: "Valid JSON" },
  { value: "json_path_exists", label: "JSON path exists" },
  { value: "json_path_type", label: "JSON path type" },
  { value: "json_path_equals", label: "JSON path equals" },
  { value: "json_path_allowed_values", label: "JSON path allowed values" },
  { value: "json_path_number", label: "JSON numeric bounds" },
  { value: "classification", label: "Allowed classification" },
  { value: "required_text", label: "Required text" },
  { value: "forbidden_text", label: "Prohibited text" },
  { value: "required_source_ids", label: "Required source IDs" },
  { value: "allowed_source_ids", label: "Allowed source IDs" },
  { value: "fact_citation", label: "Fact citation" },
  { value: "required_abstention", label: "Required abstention" },
  { value: "length", label: "Length bounds" },
] as const

export function ContractAuthoringView({ errors, flash, ...props }: ContractAuthoringProps & Pick<SharedPageProps, "errors" | "flash">) {
  const workspace = props.auth.workspace
  if (!workspace) return null

  const path = `/app/${workspace.slug}/monitors/${props.monitor.id}/contract`
  const sealed = props.contract?.status === "approved"

  return (
    <ProductShell
      availableWorkspaces={props.auth.workspaces}
      currentSection="monitors"
      membershipRole={props.auth.membership?.role || "member"}
      releaseStage={props.releaseStage}
      userEmail={props.auth.user?.email || "Invited user"}
      workspace={workspace}
    >
      <div className="mx-auto max-w-7xl space-y-7">
        <header className="space-y-5">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <Button asChild variant="ghost" className="-ml-3">
              <Link href={`/app/${workspace.slug}/monitors`}>
                <ArrowLeft /> Back to monitors
              </Link>
            </Button>
            <div className="flex flex-wrap items-center gap-2">
              <Badge variant="outline">Monitor configuration v{props.monitor.version}</Badge>
              <Badge className="border-success/20 bg-success/10 text-success" variant="outline">
                <ShieldCheck /> Local evaluation · 0 provider calls
              </Badge>
            </div>
          </div>

          <div className="flex flex-col justify-between gap-5 lg:flex-row lg:items-end">
            <div className="max-w-3xl">
              <p className="text-sm font-medium text-primary">{props.monitor.name}</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
                Define what must remain true
              </h1>
              <p className="mt-3 text-base leading-7 text-muted-foreground">
                Turn observable output requirements into deterministic rules, then prove the contract with one output that should pass and one that should fail.
              </p>
            </div>
            {props.contract && <ContractStatusBadge contract={props.contract} />}
          </div>

          <WorkflowSteps contract={props.contract} fixtureCount={props.fixtures.length} ready={props.readiness.ready} />
        </header>

        {flash.info && (
          <Alert id="contract-success" className="border-success/25 bg-success/5">
            <CheckCircle2 />
            <AlertTitle>Contract progress saved</AlertTitle>
            <AlertDescription>{flash.info}</AlertDescription>
          </Alert>
        )}

        {flash.error && (
          <Alert id="contract-error" variant="destructive">
            <AlertTriangle />
            <AlertTitle>Contract needs attention</AlertTitle>
            <AlertDescription>{flash.error}</AlertDescription>
          </Alert>
        )}

        {props.approvedContract && props.contract?.status === "draft" && (
          <Alert className="border-primary/20 bg-primary/5">
            <LockKeyhole />
            <AlertTitle>Approved version {props.approvedContract.version} remains sealed</AlertTitle>
            <AlertDescription>
              You are editing successor draft {props.contract.version}. Nothing changes in production history until an owner approves this exact draft and fixture set.
            </AlertDescription>
          </Alert>
        )}

        {!sealed && (
          <ContractEditor
            contract={props.contract}
            errors={errors}
            fixturesExist={props.fixtures.length > 0}
            path={path}
            templates={props.templates}
          />
        )}

        {props.contract && (
          <>
            <FixtureSection
              contract={props.contract}
              errors={errors}
              fixtures={props.fixtures}
              limits={props.limits}
              path={path}
              readOnly={sealed}
            />
            <ApprovalPanel
              canApprove={props.canApprove}
              contract={props.contract}
              fixtureCount={props.fixtures.length}
              path={path}
              readiness={props.readiness}
            />
          </>
        )}
      </div>
    </ProductShell>
  )
}

function WorkflowSteps({ contract, fixtureCount, ready }: { contract: ContractVersion | null; fixtureCount: number; ready: boolean }) {
  const steps = [
    { label: "Choose a template", complete: Boolean(contract), detail: contract ? "Selected" : "Start here" },
    { label: "Define rules", complete: Boolean(contract), detail: contract ? `${contract!.root.rules.length} rules` : "Not started" },
    { label: "Prove examples", complete: ready, detail: fixtureCount ? `${fixtureCount} fixture${fixtureCount === 1 ? "" : "s"}` : "Need pass + fail" },
    { label: "Owner approval", complete: contract?.status === "approved", detail: contract?.status === "approved" ? "Sealed" : "Pending" },
  ]

  return (
    <ol aria-label="Contract authoring progress" className="grid overflow-hidden rounded-xl border bg-card sm:grid-cols-4">
      {steps.map((step, index) => (
        <li key={step.label} className="flex items-center gap-3 border-b p-4 last:border-b-0 sm:border-r sm:border-b-0 sm:last:border-r-0">
          <span className={`grid size-8 shrink-0 place-items-center rounded-full text-xs font-semibold ${step.complete ? "bg-success text-success-foreground" : "bg-muted text-muted-foreground"}`}>
            {step.complete ? <Check className="size-4" /> : index + 1}
          </span>
          <span className="min-w-0">
            <span className="block truncate text-sm font-medium">{step.label}</span>
            <span className="block truncate text-xs text-muted-foreground">{step.detail}</span>
          </span>
        </li>
      ))}
    </ol>
  )
}

function ContractEditor({ contract, errors, fixturesExist, path, templates }: {
  contract: ContractVersion | null
  errors: SharedPageProps["errors"]
  fixturesExist: boolean
  path: string
  templates: Template[]
}) {
  const initialTemplate = contract ? templates.find(template => template.key === contract.templateKey) || templates[0] : null
  const [selectedTemplate, setSelectedTemplate] = useState<Template | null>(initialTemplate)
  const form = useForm({
    contract: {
      template_key: contract?.templateKey || initialTemplate?.key || "",
      assistance_mode: contract?.assistanceMode || ("self_serve" as AssistanceMode),
      root: contract?.root || initialTemplate?.root || null,
    },
  })

  function chooseTemplate(template: Template) {
    setSelectedTemplate(template)
    form.setData("contract", {
      ...form.data.contract,
      template_key: template.key,
      root: structuredClone(template.root),
    })
  }

  function setRules(rules: Rule[]) {
    if (!form.data.contract.root) return
    form.setData("contract", { ...form.data.contract, root: { ...form.data.contract.root, rules } })
  }

  function submit(event: FormEvent) {
    event.preventDefault()
    form.put(path, { preserveScroll: true })
  }

  const rules = form.data.contract.root?.rules || []

  return (
    <section aria-labelledby="contract-definition-heading" className="space-y-6">
      <div>
        <p className="text-sm font-medium text-primary">Steps 1–2</p>
        <h2 id="contract-definition-heading" className="mt-1 text-2xl font-semibold tracking-tight">Choose a workflow shape, then make every rule yours</h2>
        <p className="mt-2 text-sm leading-6 text-muted-foreground">Templates are explicit starting points. Silent Regression records which suggestions you accept, edit, remove, or add.</p>
      </div>

      <div className="grid gap-4 lg:grid-cols-4">
        {templates.map(template => {
          const active = selectedTemplate?.key === template.key
          return (
            <Card key={template.key} className={`transition-all hover:-translate-y-0.5 hover:shadow-md ${active ? "border-primary ring-2 ring-primary/10" : ""}`}>
              <CardHeader className="pb-3">
                <div className="flex items-start justify-between gap-3">
                  <span className={`grid size-10 place-items-center rounded-xl ${active ? "bg-primary text-primary-foreground" : "bg-muted text-muted-foreground"}`}><Sparkles className="size-5" /></span>
                  {active && <Badge className="bg-primary/10 text-primary" variant="secondary"><Check /> Selected</Badge>}
                </div>
                <CardTitle className="pt-2 text-base">{template.title}</CardTitle>
                <CardDescription className="leading-5">{template.description}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="space-y-2 text-xs leading-5 text-muted-foreground">
                  <p><span className="font-medium text-foreground">Best for:</span> {template.bestFor}</p>
                  <p><span className="font-medium text-foreground">Boundary:</span> {template.limitation}</p>
                </div>
                <Button type="button" className="w-full" variant={active ? "secondary" : "outline"} onClick={() => chooseTemplate(template)}>
                  {active ? "Template selected" : "Use this template"}
                </Button>
              </CardContent>
            </Card>
          )
        })}
      </div>

      {selectedTemplate && form.data.contract.root && (
        <form id="contract-definition-form" className="space-y-6" onSubmit={submit}>
          {fixturesExist && (
            <Alert>
              <Info />
              <AlertTitle>Rule edits require renewed judgments</AlertTitle>
              <AlertDescription>Saving changed rules keeps fixture outputs, but clears their expected per-rule judgments until you review them again.</AlertDescription>
            </Alert>
          )}

          <Card className="border-primary/15">
            <CardHeader className="flex-row items-start justify-between gap-4">
              <div>
                <CardTitle>Deterministic rules</CardTitle>
                <CardDescription className="mt-1">Every rule uses a stable ID so results remain explainable across versions.</CardDescription>
              </div>
              <ContractJsonDialog root={form.data.contract.root} />
            </CardHeader>
            <CardContent className="space-y-4">
              {errors.rules && <FieldError message={errors.rules} />}
              {rules.map((rule, index) => (
                <RuleEditor
                  key={`${rule.id}-${index}`}
                  index={index}
                  rule={rule}
                  canRemove={rules.length > 1}
                  onChange={next => setRules(rules.map((item, itemIndex) => itemIndex === index ? next : item))}
                  onRemove={() => setRules(rules.filter((_, itemIndex) => itemIndex !== index))}
                />
              ))}
              <Button type="button" variant="outline" onClick={() => setRules([...rules, defaultRule("required_text", nextRuleId(rules))])}>
                <Plus /> Add rule
              </Button>
            </CardContent>
          </Card>

          <Card>
            <CardContent className="grid gap-5 p-5 sm:grid-cols-[1fr_auto] sm:items-end">
              <div className="space-y-2">
                <Label htmlFor="assistance-mode">How was this contract authored?</Label>
                <Select
                  value={form.data.contract.assistance_mode}
                  onValueChange={value => form.setData("contract", { ...form.data.contract, assistance_mode: value as AssistanceMode })}
                >
                  <SelectTrigger id="assistance-mode" className="w-full sm:max-w-sm"><SelectValue /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="self_serve">Self-serve</SelectItem>
                    <SelectItem value="founder_assisted">Founder-assisted</SelectItem>
                    <SelectItem value="codex_assisted">Codex-assisted draft</SelectItem>
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">This records private-alpha assistance honestly; it does not change evaluation.</p>
              </div>
              <Button id="save-contract-draft" type="submit" disabled={form.processing || rules.length === 0}>
                {form.processing ? <LoaderCircle className="animate-spin" /> : <Save />}
                Save and validate rules
              </Button>
            </CardContent>
          </Card>
        </form>
      )}
    </section>
  )
}

function RuleEditor({ rule, index, canRemove, onChange, onRemove }: {
  rule: Rule
  index: number
  canRemove: boolean
  onChange: (rule: Rule) => void
  onRemove: () => void
}) {
  function changeType(type: RuleType) {
    onChange(defaultRule(type, rule.id))
  }

  return (
    <div className="rounded-xl border bg-muted/20 p-4">
      <div className="grid gap-4 lg:grid-cols-[0.7fr_1fr_auto] lg:items-end">
        <div className="space-y-2">
          <Label htmlFor={`rule-${index}-id`}>Stable rule ID</Label>
          <Input id={`rule-${index}-id`} value={rule.id} pattern="[a-z][a-z0-9_\\-]*" required onChange={event => onChange({ ...rule, id: event.target.value })} />
        </div>
        <div className="space-y-2">
          <Label htmlFor={`rule-${index}-type`}>Check</Label>
          <Select value={rule.type} onValueChange={value => changeType(value as RuleType)}>
            <SelectTrigger id={`rule-${index}-type`} className="w-full"><SelectValue /></SelectTrigger>
            <SelectContent>{ruleTypes.map(type => <SelectItem key={type.value} value={type.value}>{type.label}</SelectItem>)}</SelectContent>
          </Select>
        </div>
        <Button aria-label={`Remove rule ${index + 1}`} type="button" size="icon" variant="ghost" disabled={!canRemove} onClick={onRemove}><Trash2 /></Button>
      </div>
      <div className="mt-4 border-t pt-4"><RuleFields index={index} rule={rule} onChange={onChange} /></div>
    </div>
  )
}

function RuleFields({ index, rule, onChange }: { index: number; rule: Rule; onChange: (rule: Rule) => void }) {
  const field = (key: string, value: RuleFieldValue) => onChange({ ...rule, [key]: value } as Rule)
  const removeField = (key: string) => {
    const next = { ...rule }
    Reflect.deleteProperty(next, key)
    onChange(next)
  }

  if (rule.type === "json_valid") return <p className="text-sm text-muted-foreground">Passes only when the entire output is valid JSON.</p>

  if (["json_path_exists", "json_path_type", "json_path_equals", "json_path_allowed_values", "json_path_number"].includes(rule.type)) {
    return (
      <div className="grid gap-4 sm:grid-cols-2">
        <TextField id={`rule-${index}-path`} label="JSON Pointer path" value={String(rule.path || "")} placeholder="/customer/id" onChange={value => field("path", value)} />
        {rule.type === "json_path_type" && (
          <SelectField id={`rule-${index}-expected-type`} label="Expected JSON type" value={String(rule.expected_type)} options={["object", "array", "string", "number", "integer", "boolean", "null"]} onChange={value => field("expected_type", value)} />
        )}
        {rule.type === "json_path_equals" && (
          <>
            <JsonValueField id={`rule-${index}-expected`} label="Expected JSON value" value={rule.expected} onChange={value => field("expected", value)} />
            <SelectField id={`rule-${index}-numeric-comparison`} label="Number comparison" value={String(rule.numeric_comparison)} options={["strict", "mathematical"]} onChange={value => field("numeric_comparison", value)} />
          </>
        )}
        {rule.type === "json_path_allowed_values" && (
          <>
            <JsonValueField id={`rule-${index}-allowed-values`} label="Allowed values (JSON array)" value={rule.allowed_values} requireArray onChange={value => field("allowed_values", value)} />
            <SelectField id={`rule-${index}-numeric-comparison`} label="Number comparison" value={String(rule.numeric_comparison)} options={["strict", "mathematical"]} onChange={value => field("numeric_comparison", value)} />
          </>
        )}
        {rule.type === "json_path_number" && (
          <>
            <OptionalNumberField id={`rule-${index}-minimum`} label="Minimum" value={rule.minimum} onChange={value => value === undefined ? removeField("minimum") : field("minimum", value)} />
            <OptionalNumberField id={`rule-${index}-maximum`} label="Maximum" value={rule.maximum} onChange={value => value === undefined ? removeField("maximum") : field("maximum", value)} />
            <OptionalNumberField id={`rule-${index}-target`} label="Target (optional)" value={rule.target} onChange={value => value === undefined ? removeField("target") : field("target", value)} />
            <OptionalNumberField id={`rule-${index}-tolerance`} label="Tolerance (optional)" value={rule.tolerance} min={0} onChange={value => value === undefined ? removeField("tolerance") : field("tolerance", value)} />
          </>
        )}
      </div>
    )
  }

  if (["classification", "required_text", "forbidden_text", "required_abstention"].includes(rule.type)) {
    const key = rule.type === "classification" ? "allowed_values" : "alternatives"
    return <LinesField id={`rule-${index}-values`} label={rule.type === "classification" ? "Allowed labels" : "Accepted phrase alternatives"} value={(rule[key] as string[]) || []} onChange={value => field(key, value)} />
  }

  if (["required_source_ids", "allowed_source_ids"].includes(rule.type)) {
    return (
      <div className="grid gap-4 sm:grid-cols-2">
        <LinesField id={`rule-${index}-sources`} label={rule.type === "required_source_ids" ? "Required source IDs" : "Allowed source IDs"} value={(rule.source_ids as string[]) || []} onChange={value => field("source_ids", value)} />
        {rule.type === "allowed_source_ids" && (
          <BooleanField id={`rule-${index}-require-one`} label="Require at least one citation" checked={Boolean(rule.require_at_least_one)} onChange={value => field("require_at_least_one", value)} />
        )}
      </div>
    )
  }

  if (rule.type === "fact_citation") {
    return (
      <div className="grid gap-4 sm:grid-cols-2">
        <LinesField id={`rule-${index}-facts`} label="Fact alternatives" value={(rule.fact_alternatives as string[]) || []} onChange={value => field("fact_alternatives", value)} />
        <LinesField id={`rule-${index}-sources`} label="Supporting source IDs" value={(rule.source_ids as string[]) || []} onChange={value => field("source_ids", value)} />
        <OptionalNumberField id={`rule-${index}-distance`} label="Maximum characters between fact and citation" min={0} value={rule.max_distance_characters} onChange={value => field("max_distance_characters", value ?? 0)} />
      </div>
    )
  }

  return (
    <div className="grid gap-4 sm:grid-cols-3">
      <SelectField id={`rule-${index}-unit`} label="Unit" value={String(rule.unit)} options={["words", "graphemes"]} onChange={value => field("unit", value)} />
      <OptionalNumberField id={`rule-${index}-minimum`} label="Minimum (optional)" min={0} value={rule.minimum} onChange={value => value === undefined ? removeField("minimum") : field("minimum", value)} />
      <OptionalNumberField id={`rule-${index}-maximum`} label="Maximum (optional)" min={0} value={rule.maximum} onChange={value => value === undefined ? removeField("maximum") : field("maximum", value)} />
    </div>
  )
}

function FixtureSection({ contract, errors, fixtures, limits, path, readOnly }: {
  contract: ContractVersion
  errors: SharedPageProps["errors"]
  fixtures: Fixture[]
  limits: ContractAuthoringProps["limits"]
  path: string
  readOnly: boolean
}) {
  return (
    <section aria-labelledby="fixtures-heading" className="space-y-6">
      <div className="flex flex-col justify-between gap-3 sm:flex-row sm:items-end">
        <div>
          <p className="text-sm font-medium text-primary">Step 3</p>
          <h2 id="fixtures-heading" className="mt-1 text-2xl font-semibold tracking-tight">Prove how these rules behave</h2>
          <p className="mt-2 text-sm leading-6 text-muted-foreground">Paste completed outputs, state what should happen, and compare your judgment with the evaluator rule by rule.</p>
        </div>
        <Badge variant="outline"><FlaskConical /> {fixtures.length} of {limits.maxFixtures} fixtures</Badge>
      </div>

      {!readOnly && fixtures.length < limits.maxFixtures && (
        <FixtureForm contract={contract} errors={errors} path={path} />
      )}

      {fixtures.length === 0 ? (
        <Card className="border-dashed"><CardContent className="grid min-h-44 place-items-center p-8 text-center"><div><CircleDashed className="mx-auto size-7 text-muted-foreground" /><p className="mt-3 font-medium">No proof fixtures yet</p><p className="mt-1 text-sm text-muted-foreground">Add a known-valid output and a known-invalid output before approval.</p></div></CardContent></Card>
      ) : (
        <div className="space-y-4">
          {fixtures.map(fixture => <FixtureCard key={fixture.id} contract={contract} fixture={fixture} path={path} readOnly={readOnly} />)}
        </div>
      )}
    </section>
  )
}

function FixtureForm({ contract, errors, path }: { contract: ContractVersion; errors: SharedPageProps["errors"]; path: string }) {
  const form = useForm({ fixture: { name: "", output_text: "", expected_status: "pass" as "pass" | "fail", expected_failed_rule_ids: [] as string[] } })

  function submit(event: FormEvent) {
    event.preventDefault()
    form.post(`${path}/fixtures`, { preserveScroll: true, onSuccess: () => form.reset() })
  }

  return (
    <Card className="border-primary/15">
      <CardHeader><CardTitle>Add a proof fixture</CardTitle><CardDescription>This runs only the local deterministic evaluator. Your output is stored in this workspace and is not sent to OpenAI or Anthropic.</CardDescription></CardHeader>
      <CardContent>
        <form id="contract-fixture-form" className="space-y-5" onSubmit={submit}>
          <div className="grid gap-5 sm:grid-cols-2">
            <TextField id="fixture-name" label="Fixture name" value={form.data.fixture.name} placeholder="Known-valid account extraction" onChange={value => form.setData("fixture", { ...form.data.fixture, name: value })} />
            <div className="space-y-2">
              <Label htmlFor="fixture-expected-status">Expected overall result</Label>
              <Select value={form.data.fixture.expected_status} onValueChange={value => form.setData("fixture", { ...form.data.fixture, expected_status: value as "pass" | "fail", expected_failed_rule_ids: [] })}>
                <SelectTrigger id="fixture-expected-status" className="w-full"><SelectValue /></SelectTrigger>
                <SelectContent><SelectItem value="pass">Should pass every rule</SelectItem><SelectItem value="fail">Should fail one or more rules</SelectItem></SelectContent>
              </Select>
            </div>
          </div>
          <div className="space-y-2">
            <Label htmlFor="fixture-output">Completed model output</Label>
            <Textarea id="fixture-output" className="min-h-36 font-mono text-xs leading-5" value={form.data.fixture.output_text} onChange={event => form.setData("fixture", { ...form.data.fixture, output_text: event.target.value })} />
            {errors.outputText && <FieldError message={errors.outputText} />}
          </div>
          {form.data.fixture.expected_status === "fail" && (
            <FailedRulePicker rules={contract.root.rules} selected={form.data.fixture.expected_failed_rule_ids} onChange={selected => form.setData("fixture", { ...form.data.fixture, expected_failed_rule_ids: selected })} />
          )}
          {(errors.expectedStatus || errors.expectedRuleStatuses || errors.fixtures) && <FieldError message={errors.expectedStatus || errors.expectedRuleStatuses || errors.fixtures} />}
          <div className="flex justify-end"><Button id="evaluate-fixture" type="submit" disabled={form.processing || !form.data.fixture.name || (form.data.fixture.expected_status === "fail" && form.data.fixture.expected_failed_rule_ids.length === 0)}>{form.processing ? <LoaderCircle className="animate-spin" /> : <FlaskConical />} Save and evaluate locally</Button></div>
        </form>
      </CardContent>
    </Card>
  )
}

function FixtureCard({ contract, fixture, path, readOnly }: { contract: ContractVersion; fixture: Fixture; path: string; readOnly: boolean }) {
  const [editing, setEditing] = useState(false)
  const form = useForm({ fixture: { name: fixture.name, output_text: fixture.outputText, expected_status: fixture.expectedStatus, expected_failed_rule_ids: fixture.expectedFailedRuleIds } })
  const childResults = fixture.actual.ruleResults.filter(result => result.ruleId !== "contract")

  function submit(event: FormEvent) {
    event.preventDefault()
    form.patch(`${path}/fixtures/${fixture.id}`, { preserveScroll: true, onSuccess: () => setEditing(false) })
  }

  if (editing) {
    return (
      <Card id={`fixture-${fixture.id}`} className="border-primary/20">
        <CardHeader><CardTitle className="text-base">Edit {fixture.name}</CardTitle><CardDescription>Changing the output or judgment immediately re-runs local evaluation.</CardDescription></CardHeader>
        <CardContent><form className="space-y-5" onSubmit={submit}>
          <div className="grid gap-4 sm:grid-cols-2">
            <TextField id={`fixture-${fixture.id}-name`} label="Fixture name" value={form.data.fixture.name} onChange={value => form.setData("fixture", { ...form.data.fixture, name: value })} />
            <SelectField id={`fixture-${fixture.id}-status`} label="Expected overall result" value={form.data.fixture.expected_status} options={["pass", "fail"]} optionLabel={value => value === "pass" ? "Should pass every rule" : "Should fail one or more rules"} onChange={value => form.setData("fixture", { ...form.data.fixture, expected_status: value as "pass" | "fail", expected_failed_rule_ids: [] })} />
          </div>
          <div className="space-y-2"><Label htmlFor={`fixture-${fixture.id}-output`}>Completed model output</Label><Textarea id={`fixture-${fixture.id}-output`} className="min-h-32 font-mono text-xs" value={form.data.fixture.output_text} onChange={event => form.setData("fixture", { ...form.data.fixture, output_text: event.target.value })} /></div>
          {form.data.fixture.expected_status === "fail" && <FailedRulePicker rules={contract.root.rules} selected={form.data.fixture.expected_failed_rule_ids} onChange={selected => form.setData("fixture", { ...form.data.fixture, expected_failed_rule_ids: selected })} />}
          <div className="flex justify-end gap-2"><Button type="button" variant="ghost" onClick={() => setEditing(false)}>Cancel</Button><Button type="submit" disabled={form.processing}><Save /> Save fixture</Button></div>
        </form></CardContent>
      </Card>
    )
  }

  return (
    <Card id={`fixture-${fixture.id}`} className={fixture.matches ? "border-success/20" : "border-destructive/30"}>
      <CardHeader className="gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <CardTitle className="text-base">{fixture.name}</CardTitle>
            <Badge className={fixture.matches ? "bg-success/10 text-success" : "bg-destructive/10 text-destructive"} variant="secondary">{fixture.matches ? <CheckCircle2 /> : <XCircle />}{fixture.matches ? "Judgment confirmed" : "Contradiction"}</Badge>
          </div>
          <CardDescription className="mt-2">Expected {fixture.expectedStatus}; evaluator returned {fixture.actual.status}.</CardDescription>
        </div>
        {!readOnly && <div className="flex gap-1"><Button type="button" size="sm" variant="ghost" onClick={() => setEditing(true)}><Pencil /> Edit</Button><Button aria-label={`Delete ${fixture.name}`} type="button" size="icon-sm" variant="ghost" onClick={() => router.delete(`${path}/fixtures/${fixture.id}`, { preserveScroll: true })}><Trash2 /></Button></div>}
      </CardHeader>
      <CardContent className="space-y-5">
        <pre className="max-h-48 overflow-auto whitespace-pre-wrap rounded-lg bg-muted p-4 text-xs leading-5">{fixture.outputText || "(empty output)"}</pre>
        <div className="overflow-x-auto rounded-lg border">
          <div className="min-w-[44rem]">
            <div className="grid grid-cols-[minmax(8rem,0.7fr)_0.35fr_0.35fr_minmax(12rem,1fr)] gap-3 border-b bg-muted/60 px-4 py-2 text-xs font-medium text-muted-foreground"><span>Rule</span><span>Expected</span><span>Actual</span><span>Why</span></div>
            {childResults.map(result => (
              <div key={result.ruleId} className="grid grid-cols-[minmax(8rem,0.7fr)_0.35fr_0.35fr_minmax(12rem,1fr)] gap-3 border-b px-4 py-3 text-xs last:border-b-0">
                <span><span className="block font-mono font-medium">{result.ruleId}</span><span className="text-muted-foreground">{ruleTypeLabel(result.ruleType)}</span></span>
                <StatusText status={fixture.expectedRuleStatuses[result.ruleId]} />
                <StatusText status={result.status} />
                <span className="leading-5 text-muted-foreground">{result.explanation}</span>
              </div>
            ))}
          </div>
        </div>
      </CardContent>
    </Card>
  )
}

function ApprovalPanel({ canApprove, contract, fixtureCount, path, readiness }: { canApprove: boolean; contract: ContractVersion; fixtureCount: number; path: string; readiness: ContractAuthoringProps["readiness"] }) {
  const form = useForm({})
  const approved = contract.status === "approved"
  const baselinePath = path.replace(/\/contract$/, "/baseline")

  return (
    <section aria-labelledby="approval-heading">
      <Card className={approved ? "border-success/25 bg-success/5" : readiness.ready ? "border-primary/25" : ""}>
        <CardHeader className="gap-5 lg:flex-row lg:items-start lg:justify-between">
          <div className="max-w-3xl">
            <p className="text-sm font-medium text-primary">Step 4</p>
            <CardTitle id="approval-heading" className="mt-1 text-2xl">{approved ? `Contract version ${contract.version} is sealed` : "Approve the exact behavior snapshot"}</CardTitle>
            <CardDescription className="mt-2 leading-6">{approved ? "Rules, fixture judgments, evaluator version, fingerprints, approver, and timestamp are immutable. Editing begins a successor draft." : "Approval binds these rules to this exact fixture set. Only a workspace owner can make that commitment."}</CardDescription>
          </div>
          <ContractJsonDialog root={contract.root} />
        </CardHeader>
        <CardContent className="space-y-6">
          <div className="grid gap-3 sm:grid-cols-3">
            <ProofMetric label="Rules" value={String(contract.root.rules.length)} />
            <ProofMetric label="Fixtures" value={String(fixtureCount)} />
            <ProofMetric label="Combined fingerprint" value={contract.fingerprint.slice(0, 12)} mono />
          </div>

          {!approved && !readiness.ready && (
            <div className="rounded-xl border border-amber-500/25 bg-amber-500/5 p-4">
              <p className="flex items-center gap-2 text-sm font-medium"><AlertTriangle className="size-4 text-amber-600" /> Resolve before approval</p>
              <ul className="mt-3 space-y-2 text-sm text-muted-foreground">{readiness.blockers.map((blocker, index) => <li key={`${blocker.code}-${index}`} className="flex gap-2"><ChevronRight className="mt-0.5 size-4 shrink-0" />{blocker.message}</li>)}</ul>
            </div>
          )}

          <div className="flex flex-col gap-3 border-t pt-5 sm:flex-row sm:items-center sm:justify-between">
            <p className="text-sm text-muted-foreground">{approved ? `Approved ${formatDate(contract.approvedAt)} · fingerprint ${contract.fingerprint}` : canApprove ? "Your approval will be attributable to your account." : "A workspace owner must perform final approval."}</p>
            {approved ? (
              <div className="flex flex-col gap-2 sm:flex-row">
                <Button id="create-contract-revision" type="button" variant="outline" disabled={form.processing} onClick={() => form.post(`${path}/revise`)}>{form.processing ? <LoaderCircle className="animate-spin" /> : <Pencil />} Create successor draft</Button>
                <Button id="continue-to-baseline" asChild><Link href={baselinePath}><FlaskConical /> Preview baseline capture</Link></Button>
              </div>
            ) : (
              <Button id="approve-contract" type="button" disabled={!canApprove || !readiness.ready || form.processing} onClick={() => form.post(`${path}/approve`)}>{form.processing ? <LoaderCircle className="animate-spin" /> : <LockKeyhole />} Approve and seal contract</Button>
            )}
          </div>
        </CardContent>
      </Card>
    </section>
  )
}

function ContractStatusBadge({ contract }: { contract: ContractVersion }) {
  return <Badge className={contract.status === "approved" ? "border-success/25 bg-success/10 text-success" : "border-primary/25 bg-primary/5 text-primary"} variant="outline">{contract.status === "approved" ? <LockKeyhole /> : <Pencil />}Version {contract.version} · {contract.status}</Badge>
}

function ContractJsonDialog({ root }: { root: Root }) {
  return (
    <Dialog>
      <DialogTrigger asChild><Button type="button" variant="outline" size="sm"><Code2 /> Advanced JSON</Button></DialogTrigger>
      <DialogContent className="max-h-[85vh] overflow-hidden sm:max-w-2xl">
        <DialogHeader><DialogTitle>Validated contract JSON</DialogTitle><DialogDescription>This is a read-only portability and debugging view. Use the structured rule fields to make changes.</DialogDescription></DialogHeader>
        <pre className="max-h-[60vh] overflow-auto rounded-lg bg-slate-950 p-4 text-xs leading-5 text-slate-100">{JSON.stringify({ schema_version: 1, root }, null, 2)}</pre>
      </DialogContent>
    </Dialog>
  )
}

function FailedRulePicker({ rules, selected, onChange }: { rules: Rule[]; selected: string[]; onChange: (ids: string[]) => void }) {
  return (
    <fieldset className="space-y-3 rounded-lg border p-4">
      <legend className="px-1 text-sm font-medium">Which rules should fail?</legend>
      <p className="text-xs text-muted-foreground">Select every failure you intentionally expect. Unselected rules are expected to pass.</p>
      <div className="grid gap-2 sm:grid-cols-2">{rules.map(rule => {
        const checked = selected.includes(rule.id)
        return <label key={rule.id} className="flex cursor-pointer items-start gap-3 rounded-lg border bg-background p-3 text-sm transition-colors hover:bg-muted/50"><input className="mt-0.5 size-4 accent-primary" type="checkbox" checked={checked} onChange={() => onChange(checked ? selected.filter(id => id !== rule.id) : [...selected, rule.id])} /><span><span className="block font-mono text-xs font-medium">{rule.id}</span><span className="text-xs text-muted-foreground">{ruleTypeLabel(rule.type)}</span></span></label>
      })}</div>
    </fieldset>
  )
}

function TextField({ id, label, value, onChange, placeholder }: { id: string; label: string; value: string; onChange: (value: string) => void; placeholder?: string }) {
  return <div className="space-y-2"><Label htmlFor={id}>{label}</Label><Input id={id} value={value} placeholder={placeholder} required onChange={event => onChange(event.target.value)} /></div>
}

function LinesField({ id, label, value, onChange }: { id: string; label: string; value: string[]; onChange: (value: string[]) => void }) {
  return <div className="space-y-2"><Label htmlFor={id}>{label}</Label><Textarea id={id} className="min-h-24" value={value.join("\n")} onChange={event => onChange(event.target.value.split("\n").map(item => item.trim()).filter(Boolean))} /><p className="text-xs text-muted-foreground">One value per line.</p></div>
}

function SelectField({ id, label, value, options, onChange, optionLabel = value => value }: { id: string; label: string; value: string; options: string[]; onChange: (value: string) => void; optionLabel?: (value: string) => string }) {
  return <div className="space-y-2"><Label htmlFor={id}>{label}</Label><Select value={value} onValueChange={onChange}><SelectTrigger id={id} className="w-full"><SelectValue /></SelectTrigger><SelectContent>{options.map(option => <SelectItem key={option} value={option}>{optionLabel(option)}</SelectItem>)}</SelectContent></Select></div>
}

function OptionalNumberField({ id, label, value, min, onChange }: { id: string; label: string; value: unknown; min?: number; onChange: (value: number | undefined) => void }) {
  return <div className="space-y-2"><Label htmlFor={id}>{label}</Label><Input id={id} type="number" min={min} value={value === undefined ? "" : String(value)} onChange={event => onChange(event.target.value === "" ? undefined : Number(event.target.value))} /></div>
}

function BooleanField({ id, label, checked, onChange }: { id: string; label: string; checked: boolean; onChange: (value: boolean) => void }) {
  return <label htmlFor={id} className="flex cursor-pointer items-center gap-3 self-end rounded-lg border bg-background p-3 text-sm"><input id={id} type="checkbox" className="size-4 accent-primary" checked={checked} onChange={event => onChange(event.target.checked)} />{label}</label>
}

function JsonValueField({ id, label, value, requireArray = false, onChange }: { id: string; label: string; value: JsonScalar | JsonScalar[] | undefined; requireArray?: boolean; onChange: (value: JsonScalar | JsonScalar[]) => void }) {
  const [encoded, setEncoded] = useState(JSON.stringify(value))
  const [error, setError] = useState("")
  return <div className="space-y-2"><Label htmlFor={id}>{label}</Label><Input id={id} className="font-mono text-xs" value={encoded} onChange={event => { const next = event.target.value; setEncoded(next); try { const decoded = JSON.parse(next) as unknown; const scalar = decoded === null || ["string", "number", "boolean"].includes(typeof decoded); const scalarArray = Array.isArray(decoded) && decoded.every(item => item === null || ["string", "number", "boolean"].includes(typeof item)); if ((requireArray && !scalarArray) || (!requireArray && !scalar)) throw new Error(requireArray ? "Use a JSON array of scalar values" : "Use a JSON string, number, boolean, or null"); setError(""); onChange(decoded as JsonScalar | JsonScalar[]) } catch (reason) { setError(reason instanceof Error ? reason.message : "Enter valid JSON") } }} />{error && <FieldError message={error} />}</div>
}

function FieldError({ message }: { message: string }) {
  return <p className="flex items-start gap-1.5 text-sm text-destructive"><AlertTriangle className="mt-0.5 size-4 shrink-0" />{message}</p>
}

function StatusText({ status }: { status: RuleStatus | "pass" | "fail" | undefined }) {
  if (!status) return <span className="text-muted-foreground">Pending</span>
  return <span className={`flex items-center gap-1.5 font-medium ${status === "pass" ? "text-success" : "text-destructive"}`}>{status === "pass" ? <CheckCircle2 className="size-3.5" /> : <XCircle className="size-3.5" />}{status.replace("_", " ")}</span>
}

function ProofMetric({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return <div className="rounded-lg border bg-background p-4"><p className="text-xs text-muted-foreground">{label}</p><p className={`mt-1 text-lg font-semibold ${mono ? "font-mono" : ""}`}>{value}</p></div>
}

function defaultRule(type: RuleType, id: string): Rule {
  const rules: Record<RuleType, Rule> = {
    json_valid: { id, type },
    json_path_exists: { id, type, path: "/field" },
    json_path_type: { id, type, path: "/field", expected_type: "string" },
    json_path_equals: { id, type, path: "/field", expected: "value", numeric_comparison: "strict" },
    json_path_allowed_values: { id, type, path: "/field", allowed_values: ["value"], numeric_comparison: "strict" },
    json_path_number: { id, type, path: "/value", minimum: 0 },
    classification: { id, type, allowed_values: ["approved", "rejected"] },
    required_text: { id, type, alternatives: ["required phrase"] },
    forbidden_text: { id, type, alternatives: ["forbidden phrase"] },
    required_source_ids: { id, type, source_ids: ["source-1"] },
    allowed_source_ids: { id, type, source_ids: ["source-1"], require_at_least_one: true },
    fact_citation: { id, type, fact_alternatives: ["supported statement"], source_ids: ["source-1"], max_distance_characters: 100 },
    required_abstention: { id, type, alternatives: ["I don't have enough information"] },
    length: { id, type, unit: "words", minimum: 1, maximum: 100 },
  }
  return rules[type]
}

function nextRuleId(rules: Rule[]) {
  let index = rules.length + 1
  while (rules.some(rule => rule.id === `rule_${index}`)) index += 1
  return `rule_${index}`
}

function ruleTypeLabel(type: string) {
  return ruleTypes.find(ruleType => ruleType.value === type)?.label || type.replaceAll("_", " ")
}

function formatDate(value: string | null) {
  if (!value) return ""
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}

export default function ContractAuthoringPage() {
  const props = usePage<ServerContractAuthoringProps & SharedPageProps>().props
  const templates = props.templates.map(template => ({ ...template, root: JSON.parse(template.rootJson) as Root }))
  const contract = props.contract ? { ...props.contract, root: JSON.parse(props.contract.rootJson) as Root } : null
  const fixtures = props.fixtures.map(fixture => ({
    ...fixture,
    expectedRuleStatuses: JSON.parse(fixture.expectedRuleStatusesJson) as Fixture["expectedRuleStatuses"],
  }))

  return <><Head title={`Deterministic contract · ${props.monitor.name}`} /><ContractAuthoringView {...props} contract={contract} fixtures={fixtures} templates={templates} /></>
}
