import { FormEvent, useState } from "react"
import { Head, Link, router, useForm, usePage } from "@inertiajs/react"
import {
  AlertTriangle,
  ArrowLeft,
  ArrowRight,
  Braces,
  Check,
  CheckCircle2,
  Database,
  FileJson2,
  KeyRound,
  LoaderCircle,
  LockKeyhole,
  Plus,
  Save,
  Send,
  ShieldCheck,
  Trash2,
} from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Progress } from "@/components/ui/progress"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Textarea } from "@/components/ui/textarea"
import type { SharedPageProps } from "@/types/page"

type Step = "purpose" | "connection" | "prompt" | "cases" | "review"
type Provider = "openai" | "anthropic"
type RequestMode = "legacy_wrapped_v1" | "provider_native_v1"

type Credential = {
  id: string
  provider: Provider
  label: string
  secretSuffix: string
  status: "pending_validation" | "valid" | "invalid" | "revoked" | "superseded"
  lastReturnedModel: string | null
}

type SetupCase = {
  caseKey: string
  name: string
  position: number
  status: "active" | "disabled"
  inputVariables: Record<string, unknown>
  inputVariablesJson: string
  frozenContext: string
  expectationSchemaVersion: "no_case_expectation" | "case_expectation_v1"
  expectation: Record<string, unknown>
  expectationJson: string
  expectationFingerprint: string
}

type Setup = {
  id: string
  status: "in_progress" | "completed"
  monitor: { id: string; name: string; description: string | null; state: string }
  providerCredentialId: string | null
  provider: Provider | null
  requestedModel: string | null
  requestMode: RequestMode
  requestSchemaVersion: number
  requestTemplate: Record<string, unknown>
  requestTemplateJson: string
  systemPrompt: string
  userPromptTemplate: string
  responseFormat: {
    type: "text" | "json_object" | "json_schema"
    name?: string
    schema?: Record<string, unknown>
    strict?: boolean
  }
  generationConfig: {
    maxOutputTokens?: number
    temperature?: number
    topP?: number
    reasoningEffort?: string
  }
  cases: SetupCase[]
  completedMonitorVersionId: string | null
  isSuccessor: boolean
  sourceMonitorVersionId: string | null
  completedAt: string | null
  updatedAt: string
}

type SetupProgress = {
  completed: Record<Exclude<Step, "review">, boolean>
  completedCount: number
  totalCount: number
  percent: number
  nextStep: Step
  ready: boolean
}

type Limits = {
  maxActiveCases: number
  maxTotalCases: number
  maxPromptBytes: number
  maxRequestMessages: number
  maxRequestTemplateBytes: number
  maxContextBytes: number
  maxVariablesBytes: number
  maxExpectationBytes: number
  maxExpectationChecks: number
  maxImportBytes: number
  maxOutputTokens: number
}

type GenerationCapability = {
  parameters: string[]
  reasoningEfforts: string[]
}

type GenerationCapabilities = Record<Provider, Record<string, GenerationCapability>>

type RequestPreview = {
  caseKey: string
  caseName: string
  requestFingerprint: string
  artifactJson: string
}

export type MonitorSetupProps = {
  activeCaseCount: number
  auth: SharedPageProps["auth"]
  credentials: Credential[]
  generationCapabilities: GenerationCapabilities
  limits: Limits
  modelOptions: Record<Provider, string[]>
  progress: SetupProgress
  releaseStage: string
  requestPreviews: RequestPreview[]
  setup: Setup
  step: Step
}

const steps: Array<{ id: Step; label: string; shortLabel: string }> = [
  { id: "purpose", label: "Purpose", shortLabel: "Purpose" },
  { id: "connection", label: "Provider and model", shortLabel: "Connection" },
  { id: "prompt", label: "Provider request", shortLabel: "Request" },
  { id: "cases", label: "Representative cases", shortLabel: "Cases" },
  { id: "review", label: "Review and finish", shortLabel: "Review" },
]

export function MonitorSetupView({
  errors,
  flash,
  ...props
}: MonitorSetupProps & Pick<SharedPageProps, "errors" | "flash">) {
  const workspace = props.auth.workspace

  if (!workspace) return null

  const basePath = `/app/${workspace.slug}/monitors/${props.setup.monitor.id}/setup`

  return (
    <ProductShell
        availableWorkspaces={props.auth.workspaces}
        currentSection="monitors"
        releaseStage={props.releaseStage}
        userEmail={props.auth.user?.email || "Invited user"}
        workspace={workspace}
        membershipRole={props.auth.membership?.role || "member"}
      >
        <div className="mx-auto max-w-6xl space-y-7">
          <header className="space-y-5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <Button asChild variant="ghost" className="-ml-3">
                <Link href={`/app/${workspace.slug}/monitors`}>
                  <ArrowLeft /> Back to monitors
                </Link>
              </Button>
              <Badge
                variant="outline"
                className={
                  props.setup.status === "completed"
                    ? "border-success/25 bg-success/5 text-success"
                    : "border-primary/25 text-primary"
                }
              >
                {props.setup.status === "completed" ? <CheckCircle2 /> : <Save />}
                {props.setup.status === "completed" ? "Setup complete" : "Draft saved automatically per step"}
              </Badge>
            </div>

            <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-end">
              <div>
                <p className="text-sm font-medium text-primary">{props.setup.monitor.name}</p>
                <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
                  {stepLabel(props.step)}
                </h1>
              </div>
              <div className="w-full sm:max-w-xs">
                <div className="mb-2 flex justify-between text-xs text-muted-foreground">
                  <span>{props.progress.completedCount} of {props.progress.totalCount} setup steps</span>
                  <span>{props.progress.percent}%</span>
                </div>
                <Progress value={props.progress.percent} aria-label="Monitor setup progress" />
              </div>
            </div>

            <StepNavigation
              basePath={basePath}
              current={props.step}
              progress={props.progress}
              setupStatus={props.setup.status}
            />
          </header>

          {flash.info && (
            <Alert id="setup-success" className="border-success/25 bg-success/5">
              <CheckCircle2 />
              <AlertTitle>Progress saved</AlertTitle>
              <AlertDescription>{flash.info}</AlertDescription>
            </Alert>
          )}

          {flash.error && (
            <Alert id="setup-error" variant="destructive">
              <AlertTriangle />
              <AlertTitle>Setup needs attention</AlertTitle>
              <AlertDescription>{flash.error}</AlertDescription>
            </Alert>
          )}

          {props.step === "purpose" && (
            <PurposeStep basePath={basePath} errors={errors} setup={props.setup} />
          )}
          {props.step === "connection" && (
            <ConnectionStep
              basePath={basePath}
              credentials={props.credentials}
              errors={errors}
              modelOptions={props.modelOptions}
              setup={props.setup}
              workspaceSlug={workspace.slug}
            />
          )}
          {props.step === "prompt" && (
            <PromptStep
              basePath={basePath}
              errors={errors}
              generationCapabilities={props.generationCapabilities}
              limits={props.limits}
              setup={props.setup}
            />
          )}
          {props.step === "cases" && (
            <CasesStep basePath={basePath} errors={errors} limits={props.limits} setup={props.setup} />
          )}
          {props.step === "review" && (
            <ReviewStep
              activeCaseCount={props.activeCaseCount}
              basePath={basePath}
              credential={props.credentials.find(item => item.id === props.setup.providerCredentialId)}
              requestPreviews={props.requestPreviews}
              setup={props.setup}
              workspaceSlug={workspace.slug}
            />
          )}
        </div>
    </ProductShell>
  )
}

export default function MonitorSetup(props: MonitorSetupProps) {
  const { errors, flash } = usePage<SharedPageProps>().props

  return (
    <>
      <Head title={`${stepLabel(props.step)} · ${props.setup.monitor.name}`} />
      <MonitorSetupView {...props} errors={errors} flash={flash} />
    </>
  )
}

function StepNavigation({
  basePath,
  current,
  progress,
  setupStatus,
}: {
  basePath: string
  current: Step
  progress: SetupProgress
  setupStatus: Setup["status"]
}) {
  const availableThrough = stepIndex(progress.nextStep)

  return (
    <nav aria-label="Setup steps" className="overflow-x-auto rounded-xl border bg-card p-2">
      <ol className="flex min-w-max gap-1">
        {steps.map((item, index) => {
          const completed = item.id === "review" ? setupStatus === "completed" : progress.completed[item.id]
          const available =
            setupStatus === "completed" ? item.id === "review" : index <= availableThrough
          const active = current === item.id
          const content = (
            <>
              <span
                className={`grid size-6 shrink-0 place-items-center rounded-full text-xs ${
                  completed
                    ? "bg-success text-success-foreground"
                    : active
                      ? "bg-primary text-primary-foreground"
                      : "bg-muted text-muted-foreground"
                }`}
              >
                {completed ? <Check className="size-3.5" /> : index + 1}
              </span>
              <span className="sr-only sm:not-sr-only">{item.shortLabel}</span>
            </>
          )

          return (
            <li key={item.id}>
              {available ? (
                <Link
                  href={`${basePath}/${item.id}`}
                  aria-current={active ? "step" : undefined}
                  className={`flex items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition-colors ${
                    active ? "bg-accent text-accent-foreground" : "text-muted-foreground hover:bg-muted"
                  }`}
                >
                  {content}
                </Link>
              ) : (
                <span className="flex cursor-not-allowed items-center gap-2 rounded-lg px-3 py-2 text-sm text-muted-foreground/55">
                  {content}
                </span>
              )}
            </li>
          )
        })}
      </ol>
    </nav>
  )
}

function PurposeStep({ basePath, errors, setup }: StepProps) {
  const form = useForm({
    monitor: { name: setup.monitor.name, description: setup.monitor.description || "" },
  })

  function submit(event: FormEvent) {
    event.preventDefault()
    form.patch(`${basePath}/purpose`)
  }

  return (
    <StepLayout
      aside={<StoredNotSent />}
      description="Keep the workflow goal specific enough that another teammate can recognize a meaningful regression."
      title="Define the workflow"
    >
      <form id="monitor-purpose-form" className="space-y-6" onSubmit={submit}>
        <div className="space-y-2">
          <Label htmlFor="setup-monitor-name">Name</Label>
          <Input
            id="setup-monitor-name"
            name="monitor[name]"
            required
            maxLength={120}
            value={form.data.monitor.name}
            aria-invalid={Boolean(errors.name)}
            onChange={event => form.setData("monitor.name", event.target.value)}
          />
          {errors.name && <FieldError message={errors.name} />}
        </div>
        <div className="space-y-2">
          <Label htmlFor="setup-monitor-description">Regression to guard against</Label>
          <Textarea
            id="setup-monitor-description"
            name="monitor[description]"
            maxLength={500}
            className="min-h-32"
            value={form.data.monitor.description}
            aria-invalid={Boolean(errors.description)}
            onChange={event => form.setData("monitor.description", event.target.value)}
          />
          {errors.description && <FieldError message={errors.description} />}
        </div>
        <FormActions basePath={basePath} processing={form.processing} step="purpose" />
      </form>
    </StepLayout>
  )
}

function ConnectionStep({
  basePath,
  credentials,
  errors,
  modelOptions,
  setup,
  workspaceSlug,
}: StepProps & {
  credentials: Credential[]
  modelOptions: Record<Provider, string[]>
  workspaceSlug: string
}) {
  const initialProvider = setup.provider || credentials.find(item => item.status === "valid")?.provider || "openai"
  const form = useForm({
    connection: {
      provider: initialProvider,
      provider_credential_id: setup.providerCredentialId || "",
      requested_model: setup.requestedModel || modelOptions[initialProvider][0] || "",
    },
  })
  const validCredentials = credentials.filter(
    credential => credential.status === "valid" && credential.provider === form.data.connection.provider,
  )

  function selectProvider(provider: Provider) {
    form.setData(data => ({
      ...data,
      connection: {
        provider,
        provider_credential_id: "",
        requested_model: modelOptions[provider][0] || "",
      },
    }))
  }

  function submit(event: FormEvent) {
    event.preventDefault()
    form.patch(`${basePath}/connection`)
  }

  return (
    <StepLayout
      aside={
        <CallBoundary
          stored="Credential reference, provider, and exact requested model. The API key remains encrypted and write-only."
          sent="Nothing during setup. Later captures send the configured prompt and cases through this credential."
        />
      }
      description="Choose the exact provider and model used by the production workflow. Silent Regression never substitutes another model."
      title="Connect the execution target"
    >
      <form id="monitor-connection-form" className="space-y-6" onSubmit={submit}>
        <div className="space-y-2">
          <Label htmlFor="setup-provider">Provider</Label>
          <Select value={form.data.connection.provider} onValueChange={value => selectProvider(value as Provider)}>
            <SelectTrigger id="setup-provider" className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="openai">OpenAI</SelectItem>
              <SelectItem value="anthropic">Anthropic</SelectItem>
            </SelectContent>
          </Select>
          {errors.provider && <FieldError message={errors.provider} />}
        </div>

        {validCredentials.length === 0 ? (
          <Alert id="no-valid-credentials" className="border-warning/35 bg-warning/5">
            <KeyRound />
            <AlertTitle>No validated {providerLabel(form.data.connection.provider)} credential</AlertTitle>
            <AlertDescription className="space-y-3">
              <p>Add and validate a credential before this setup step can be completed.</p>
              <Button asChild size="sm" variant="outline">
                <Link href={`/app/${workspaceSlug}/credentials`}>Manage credentials</Link>
              </Button>
            </AlertDescription>
          </Alert>
        ) : (
          <div className="space-y-2">
            <Label htmlFor="setup-credential">Validated credential</Label>
            <Select
              value={form.data.connection.provider_credential_id}
              onValueChange={value => form.setData("connection.provider_credential_id", value)}
            >
              <SelectTrigger id="setup-credential" className="w-full">
                <SelectValue placeholder="Select a credential" />
              </SelectTrigger>
              <SelectContent>
                {validCredentials.map(credential => (
                  <SelectItem key={credential.id} value={credential.id}>
                    {credential.label} · •••• {credential.secretSuffix}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {errors.providerCredentialId && <FieldError message={errors.providerCredentialId} />}
          </div>
        )}

        <div className="space-y-2">
          <Label htmlFor="setup-model">Exact requested model</Label>
          <Select
            value={form.data.connection.requested_model}
            onValueChange={value => form.setData("connection.requested_model", value)}
          >
            <SelectTrigger id="setup-model" className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {modelOptions[form.data.connection.provider].map(model => (
                <SelectItem key={model} value={model}>{model}</SelectItem>
              ))}
            </SelectContent>
          </Select>
          {errors.requestedModel && <FieldError message={errors.requestedModel} />}
          <p className="text-xs text-muted-foreground">
            Availability was established when the credential was validated; later captures still record the model returned by the provider.
          </p>
        </div>

        <FormActions
          basePath={basePath}
          disabled={
            validCredentials.length === 0 ||
            form.data.connection.provider_credential_id === ""
          }
          processing={form.processing}
          step="connection"
        />
      </form>
    </StepLayout>
  )
}

function PromptStep({
  basePath,
  errors,
  generationCapabilities,
  limits,
  setup,
}: StepProps & { generationCapabilities: GenerationCapabilities; limits: Limits }) {
  const capabilities = setup.provider && setup.requestedModel
    ? generationCapabilities[setup.provider]?.[setup.requestedModel]
    : undefined
  const supportsTemperature = capabilities?.parameters.includes("temperature") ?? false
  const supportsTopP = capabilities?.parameters.includes("top_p") ?? false
  const reasoningEfforts = capabilities?.reasoningEfforts || []

  const form = useForm({
    prompt: {
      request_template_json: setup.requestTemplateJson,
      system_prompt: setup.systemPrompt || "",
      user_prompt_template: setup.userPromptTemplate || "",
      response_format: {
        type: setup.responseFormat?.type || "text",
        name: setup.responseFormat?.name || "response",
        schema_json: JSON.stringify(setup.responseFormat?.schema || {
          type: "object",
          properties: {},
          required: [],
          additionalProperties: false,
        }, null, 2),
        strict: setup.responseFormat?.strict ?? true,
      },
      generation_config: {
        max_output_tokens: String(setup.generationConfig?.maxOutputTokens || 512),
        temperature: supportsTemperature ? setup.generationConfig?.temperature?.toString() || "" : "",
        top_p: supportsTopP ? setup.generationConfig?.topP?.toString() || "" : "",
        reasoning_effort: reasoningEfforts.includes(setup.generationConfig?.reasoningEffort || "")
          ? setup.generationConfig?.reasoningEffort || ""
          : "",
      },
    },
  })

  function submit(event: FormEvent) {
    event.preventDefault()

    form.transform(data => {
      const responseFormat = data.prompt.response_format.type === "json_schema"
        ? data.prompt.response_format
        : { type: data.prompt.response_format.type }

      return {
        ...data,
        prompt: { ...data.prompt, response_format: responseFormat },
      }
    })
    form.patch(`${basePath}/prompt`)
  }

  return (
    <StepLayout
      aside={
        <CallBoundary
          stored="The provider-native message template, response format, and generation settings in this workspace."
          sent="During later captures, exactly the reviewed per-case request body is sent to the selected provider."
        />
      }
      description="Copy the production message structure and behavior-affecting settings. The review step shows the exact provider-visible request for every active case."
      title="Freeze the provider request"
    >
      <form id="monitor-prompt-form" className="space-y-6" onSubmit={submit}>
        {setup.requestMode === "provider_native_v1" ? (
          <>
            <Alert id="provider-native-request-notice" className="border-primary/20 bg-primary/5">
              <ShieldCheck />
              <AlertTitle>Provider-native request · schema v{setup.requestSchemaVersion}</AlertTitle>
              <AlertDescription>
                {setup.provider === "anthropic"
                  ? "Use an optional system string and an alternating messages array that starts and ends with user."
                  : "Use optional instructions and an input array with user, assistant, system, or developer roles."}
                {" "}Silent Regression adds no prompt wrapper. Frozen context is sent only where you place <code>{"{{frozen_context}}"}</code>.
              </AlertDescription>
            </Alert>

            <div className="space-y-2">
              <Label htmlFor="provider-request-template">
                {setup.provider === "anthropic" ? "Anthropic Messages template" : "OpenAI Responses template"}
              </Label>
              <Textarea
                id="provider-request-template"
                name="prompt[request_template_json]"
                required
                className="min-h-80 font-mono text-xs leading-5"
                maxLength={limits.maxRequestTemplateBytes}
                value={form.data.prompt.request_template_json}
                aria-invalid={Boolean(errors.requestTemplate)}
                onChange={event => form.setData("prompt.request_template_json", event.target.value)}
              />
              {errors.requestTemplate && <FieldError message={errors.requestTemplate} />}
              <p className="text-xs leading-5 text-muted-foreground">
                Up to {limits.maxRequestMessages} ordered text messages. Template variables must exist in every active case; <code>{"{{frozen_context}}"}</code> is reserved.
              </p>
            </div>
          </>
        ) : (
          <>
            <Alert id="legacy-request-notice" className="border-warning/35 bg-warning/5">
              <AlertTriangle />
              <AlertTitle>Legacy wrapped request</AlertTitle>
              <AlertDescription>
                This migrated setup preserves the original wrapper exactly. Finish it without converting its behavior; create a new monitor to use provider-native messages.
              </AlertDescription>
            </Alert>

            <div className="space-y-2">
              <Label htmlFor="system-prompt">Legacy system prompt</Label>
              <Textarea
                id="system-prompt"
                name="prompt[system_prompt]"
                className="min-h-32 font-mono text-xs leading-5"
                maxLength={limits.maxPromptBytes}
                value={form.data.prompt.system_prompt}
                aria-invalid={Boolean(errors.systemPrompt)}
                onChange={event => form.setData("prompt.system_prompt", event.target.value)}
              />
              {errors.systemPrompt && <FieldError message={errors.systemPrompt} />}
            </div>

            <div className="space-y-2">
              <Label htmlFor="user-prompt-template">Legacy user prompt template</Label>
              <Textarea
                id="user-prompt-template"
                name="prompt[user_prompt_template]"
                required
                className="min-h-44 font-mono text-xs leading-5"
                maxLength={limits.maxPromptBytes}
                value={form.data.prompt.user_prompt_template}
                aria-invalid={Boolean(errors.userPromptTemplate)}
                onChange={event => form.setData("prompt.user_prompt_template", event.target.value)}
              />
              {errors.userPromptTemplate && <FieldError message={errors.userPromptTemplate} />}
            </div>
          </>
        )}

        <div className="grid gap-5 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="response-format">Response format</Label>
            <Select
              value={form.data.prompt.response_format.type}
              onValueChange={value => form.setData(
                "prompt.response_format.type",
                value as Setup["responseFormat"]["type"],
              )}
            >
              <SelectTrigger id="response-format" className="w-full"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="text">Text</SelectItem>
                {(setup.provider === "openai" || setup.requestMode === "legacy_wrapped_v1") && (
                  <SelectItem value="json_object">JSON object</SelectItem>
                )}
                <SelectItem value="json_schema">JSON schema</SelectItem>
              </SelectContent>
            </Select>
            {errors.responseFormat && <FieldError message={errors.responseFormat} />}
          </div>

          <div className="space-y-2">
            <Label htmlFor="max-output-tokens">Maximum output tokens</Label>
            <Input
              id="max-output-tokens"
              name="prompt[generation_config][max_output_tokens]"
              type="number"
              min={1}
              max={limits.maxOutputTokens}
              required
              value={form.data.prompt.generation_config.max_output_tokens}
              onChange={event => form.setData("prompt.generation_config.max_output_tokens", event.target.value)}
            />
          </div>
        </div>

        {form.data.prompt.response_format.type === "json_schema" && (
          <div className="space-y-5 rounded-xl border bg-muted/20 p-4">
            {setup.provider === "openai" && (
              <div className="space-y-2">
                <Label htmlFor="response-schema-name">Schema name</Label>
                <Input
                  id="response-schema-name"
                  name="prompt[response_format][name]"
                  required
                  maxLength={80}
                  value={form.data.prompt.response_format.name}
                  onChange={event => form.setData("prompt.response_format.name", event.target.value)}
                />
              </div>
            )}
            <div className="space-y-2">
              <Label htmlFor="response-schema-json">JSON schema</Label>
              <Textarea
                id="response-schema-json"
                name="prompt[response_format][schema_json]"
                required
                className="min-h-56 font-mono text-xs leading-5"
                value={form.data.prompt.response_format.schema_json}
                onChange={event => form.setData("prompt.response_format.schema_json", event.target.value)}
              />
            </div>
            {setup.provider === "openai" && (
              <div className="space-y-2">
                <Label htmlFor="response-schema-strict">Strict schema enforcement</Label>
                <Select
                  value={form.data.prompt.response_format.strict ? "true" : "false"}
                  onValueChange={value => form.setData("prompt.response_format.strict", value === "true")}
                >
                  <SelectTrigger id="response-schema-strict" className="w-full"><SelectValue /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="true">Enabled</SelectItem>
                    <SelectItem value="false">Disabled</SelectItem>
                  </SelectContent>
                </Select>
              </div>
            )}
          </div>
        )}

        {(supportsTemperature || supportsTopP) && (
          <div className="grid gap-5 sm:grid-cols-2">
            {supportsTemperature && (
              <OptionalNumber
                id="temperature"
                label="Temperature"
                max={2}
                value={form.data.prompt.generation_config.temperature}
                onChange={value => form.setData("prompt.generation_config.temperature", value)}
              />
            )}
            {supportsTopP && (
              <OptionalNumber
                id="top-p"
                label="Top P"
                max={1}
                value={form.data.prompt.generation_config.top_p}
                onChange={value => form.setData("prompt.generation_config.top_p", value)}
              />
            )}
          </div>
        )}

        {!supportsTemperature && !supportsTopP && (
          <Alert>
            <ShieldCheck />
            <AlertTitle>Provider-default sampling</AlertTitle>
            <AlertDescription>
              Silent Regression does not send Temperature or Top P for {setup.requestedModel}. This avoids unsupported requests, and the frozen configuration records that provider defaults are used.
            </AlertDescription>
          </Alert>
        )}

        {reasoningEfforts.length > 0 && (
          <div className="space-y-2">
            <Label htmlFor="reasoning-effort">Reasoning effort</Label>
            <Select
              value={form.data.prompt.generation_config.reasoning_effort || "default"}
              onValueChange={value => form.setData("prompt.generation_config.reasoning_effort", value === "default" ? "" : value)}
            >
              <SelectTrigger id="reasoning-effort" className="w-full"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="default">Provider default</SelectItem>
                {reasoningEfforts.map(value => (
                  <SelectItem key={value} value={value}>{value}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}
        {errors.generationConfig && <FieldError message={errors.generationConfig} />}

        <FormActions basePath={basePath} processing={form.processing} step="prompt" />
      </form>
    </StepLayout>
  )
}

function CasesStep({ basePath, errors, limits, setup }: StepProps & { limits: Limits }) {
  const [mode, setMode] = useState<"manual" | "import">("manual")
  const form = useForm({ cases: setup.cases.length > 0 ? setup.cases.map(caseForForm) : [emptyCase()] })
  const importForm = useForm({ case_import: "" })

  function submitManual(event: FormEvent) {
    event.preventDefault()
    form.patch(`${basePath}/cases`)
  }

  function submitImport(event: FormEvent) {
    event.preventDefault()
    importForm.patch(`${basePath}/cases`)
  }

  function updateCase(index: number, field: keyof ReturnType<typeof emptyCase>, value: string) {
    form.setData(data => ({
      ...data,
      cases: data.cases.map((item, itemIndex) => itemIndex === index ? { ...item, [field]: value } : item),
    }))
  }

  function addCase() {
    if (form.data.cases.length < limits.maxTotalCases) {
      form.setData(data => ({ ...data, cases: [...data.cases, emptyCase()] }))
    }
  }

  function removeCase(index: number) {
    if (form.data.cases.length > 1) {
      form.setData(data => ({ ...data, cases: data.cases.filter((_item, itemIndex) => itemIndex !== index) }))
    }
  }

  const activeCount = form.data.cases.filter(item => item.status === "active").length

  return (
    <StepLayout
      aside={
        <CallBoundary
          stored="Frozen context and input variables for every active or disabled case."
          sent="During a later capture, only values referenced by the request template are rendered into each active case's provider body."
        />
      }
      description="Use real-shaped but safe examples. Remove personal data and secrets before storing representative inputs."
      title="Add representative cases"
    >
      <div className="mb-6 flex flex-wrap gap-2" role="group" aria-label="Case entry method">
        <Button type="button" variant={mode === "manual" ? "default" : "outline"} onClick={() => setMode("manual")}>
          <Braces /> Manual entry
        </Button>
        <Button type="button" variant={mode === "import" ? "default" : "outline"} onClick={() => setMode("import")}>
          <FileJson2 /> JSON import
        </Button>
      </div>

      <Alert id="case-expectation-guidance" className="mb-6 border-primary/20 bg-primary/5">
        <ShieldCheck />
        <AlertTitle>Prove the right answer for each case</AlertTitle>
        <AlertDescription>
          A shared contract can prove that an output is well formed or uses an allowed label. An optional case expectation proves which label, JSON value, number, source IDs, or abstention behavior is correct for this specific input. Leave it blank only when the case intentionally has no exact expected outcome.
        </AlertDescription>
      </Alert>

      {mode === "manual" ? (
        <form id="monitor-cases-form" className="space-y-6" onSubmit={submitManual}>
          <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border bg-muted/30 px-4 py-3 text-sm">
            <span>{form.data.cases.length} of {limits.maxTotalCases} stored cases</span>
            <span className={activeCount > limits.maxActiveCases ? "text-destructive" : "text-muted-foreground"}>
              {activeCount} of {limits.maxActiveCases} active
            </span>
          </div>

          {form.data.cases.map((item, index) => (
            <Card key={index} id={`setup-case-${index + 1}`} className="bg-muted/15">
              <CardHeader className="pb-4">
                <div className="flex items-center justify-between gap-3">
                  <CardTitle className="text-base">Case {index + 1}</CardTitle>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    disabled={form.data.cases.length === 1}
                    aria-label={`Remove case ${index + 1}`}
                    onClick={() => removeCase(index)}
                  >
                    <Trash2 />
                  </Button>
                </div>
              </CardHeader>
              <CardContent className="grid gap-5 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor={`case-${index}-key`}>Stable case key</Label>
                  <Input
                    id={`case-${index}-key`}
                    name={`cases[${index}][case_key]`}
                    required
                    pattern="[a-z0-9]+(?:(?:_|-)[a-z0-9]+)*"
                    placeholder="citation-required"
                    value={item.case_key}
                    onChange={event => updateCase(index, "case_key", event.target.value)}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor={`case-${index}-name`}>Name</Label>
                  <Input
                    id={`case-${index}-name`}
                    name={`cases[${index}][name]`}
                    required
                    maxLength={160}
                    placeholder="Supported answer cites its source"
                    value={item.name}
                    onChange={event => updateCase(index, "name", event.target.value)}
                  />
                </div>
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor={`case-${index}-variables`}>Input variables (JSON object)</Label>
                  <Textarea
                    id={`case-${index}-variables`}
                    name={`cases[${index}][input_variables_json]`}
                    required
                    className="min-h-28 font-mono text-xs leading-5"
                    maxLength={limits.maxVariablesBytes}
                    value={item.input_variables_json}
                    onChange={event => updateCase(index, "input_variables_json", event.target.value)}
                  />
                </div>
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor={`case-${index}-context`}>Frozen context variable</Label>
                  <Textarea
                    id={`case-${index}-context`}
                    name={`cases[${index}][frozen_context]`}
                    className="min-h-36 text-sm leading-6"
                    maxLength={limits.maxContextBytes}
                    placeholder="Available as {{frozen_context}}; omitted from the provider request unless the template references it."
                    value={item.frozen_context}
                    onChange={event => updateCase(index, "frozen_context", event.target.value)}
                  />
                </div>
                <div className="space-y-3 rounded-xl border border-primary/15 bg-background p-4 sm:col-span-2">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div>
                      <Label htmlFor={`case-${index}-expectation`}>Case-specific expectation (JSON)</Label>
                      <p className="mt-1 text-xs leading-5 text-muted-foreground">
                        Up to {limits.maxExpectationChecks} deterministic checks. Blank means an explicit no-expectation state.
                      </p>
                    </div>
                    <Badge variant={item.expectation_json.trim() ? "default" : "outline"}>
                      {item.expectation_json.trim() ? "Expectation configured" : "No expectation"}
                    </Badge>
                  </div>
                  <Textarea
                    id={`case-${index}-expectation`}
                    name={`cases[${index}][expectation_json]`}
                    className="min-h-48 font-mono text-xs leading-5"
                    maxLength={limits.maxExpectationBytes}
                    placeholder={'{"checks":[{"id":"route","type":"label","allowed_values":["billing"]}]}' }
                    value={item.expectation_json}
                    onChange={event => updateCase(index, "expectation_json", event.target.value)}
                  />
                  <p className="text-xs leading-5 text-muted-foreground">
                    Supported types: <code>label</code>, <code>json_value</code>, <code>json_number</code>, <code>source_ids</code>, and <code>abstention</code>. Check IDs must be stable and unique within this case.
                  </p>
                </div>
                <div className="space-y-2">
                  <Label htmlFor={`case-${index}-status`}>Status</Label>
                  <Select value={item.status} onValueChange={value => updateCase(index, "status", value)}>
                    <SelectTrigger id={`case-${index}-status`} className="w-full"><SelectValue /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="active">Active</SelectItem>
                      <SelectItem value="disabled">Disabled</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              </CardContent>
            </Card>
          ))}

          {errors.cases && <FieldError message={errors.cases} />}

          <Button type="button" variant="outline" disabled={form.data.cases.length >= limits.maxTotalCases} onClick={addCase}>
            <Plus /> Add another case
          </Button>

          <FormActions
            basePath={basePath}
            disabled={activeCount < 1 || activeCount > limits.maxActiveCases}
            processing={form.processing}
            step="cases"
          />
        </form>
      ) : (
        <form id="monitor-case-import-form" className="space-y-6" onSubmit={submitImport}>
          <Alert>
            <FileJson2 />
            <AlertTitle>Versioned import schema</AlertTitle>
            <AlertDescription>
              Import one JSON object with <code className="rounded bg-muted px-1">schema_version: 2</code> and a <code className="rounded bg-muted px-1">cases</code> array. Each case may include an <code className="rounded bg-muted px-1">expectation</code>. Schema v1 remains accepted and creates explicit no-expectation cases. A valid import replaces the current draft case list.
            </AlertDescription>
          </Alert>
          <div className="space-y-2">
            <Label htmlFor="case-import">Case JSON</Label>
            <Textarea
              id="case-import"
              name="case_import"
              required
              className="min-h-80 font-mono text-xs leading-5"
              maxLength={limits.maxImportBytes}
              placeholder={'{"schema_version":2,"cases":[{"case_key":"example","name":"Example","status":"active","input_variables":{},"frozen_context":"...","expectation":{"checks":[{"id":"route","type":"label","allowed_values":["billing"]}]}}]}' }
              value={importForm.data.case_import}
              aria-invalid={Boolean(errors.cases)}
              onChange={event => importForm.setData("case_import", event.target.value)}
            />
            {errors.cases && <FieldError message={errors.cases} />}
          </div>
          <FormActions basePath={basePath} processing={importForm.processing} step="cases" submitLabel="Import and continue" />
        </form>
      )}
    </StepLayout>
  )
}

function ReviewStep({
  activeCaseCount,
  basePath,
  credential,
  requestPreviews,
  setup,
  workspaceSlug,
}: {
  activeCaseCount: number
  basePath: string
  credential?: Credential
  requestPreviews: RequestPreview[]
  setup: Setup
  workspaceSlug: string
}) {
  const form = useForm({})
  const complete = setup.status === "completed"
  const configuredExpectationCount = setup.cases.filter(item => item.expectationSchemaVersion === "case_expectation_v1").length

  function submit(event: FormEvent) {
    event.preventDefault()
    form.post(`${basePath}/complete`)
  }

  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_0.42fr]">
      <Card id="monitor-review-card" className="border-primary/15">
        <CardHeader>
          <CardTitle>{complete ? "Setup snapshot is locked" : setup.isSuccessor ? "Review the successor draft" : "Review before finishing"}</CardTitle>
          <CardDescription>
            {complete
              ? "This complete configuration was promoted into immutable monitor history."
              : setup.isSuccessor
                ? "Finishing creates an immutable candidate without changing active execution."
                : "Finishing creates an immutable configuration version. It still does not call the provider."}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-6">
          <ReviewRow label="Purpose" value={setup.monitor.name} detail={setup.monitor.description} />
          <ReviewRow
            label="Connection"
            value={`${providerLabel(setup.provider || "openai")} · ${setup.requestedModel}`}
            detail={credential ? `${credential.label} · •••• ${credential.secretSuffix}` : "Credential unavailable"}
          />
          <ReviewRow
            label="Provider request"
            value={`${setup.requestMode === "provider_native_v1" ? "Provider native" : "Legacy wrapped"} · schema v${setup.requestSchemaVersion}`}
            detail={`${responseFormatLabel(setup.responseFormat.type)} · up to ${setup.generationConfig.maxOutputTokens || 512} output tokens`}
          />
          <ReviewRow
            label="Representative cases"
            value={`${activeCaseCount} active case${activeCaseCount === 1 ? "" : "s"}`}
            detail={`${configuredExpectationCount} with exact expectations; ${setup.cases.length - configuredExpectationCount} explicitly without; ${setup.cases.length} stored total`}
          />

          <section id="case-expectation-review" className="space-y-3" aria-labelledby="case-expectation-review-title">
            <div>
              <h2 id="case-expectation-review-title" className="text-base font-semibold">Case-specific expected outcomes</h2>
              <p className="mt-1 text-sm leading-6 text-muted-foreground">
                These immutable checks are evaluated separately from the shared contract and are fingerprinted with each case.
              </p>
            </div>
            {setup.cases.map((item, index) => (
              <div key={item.caseKey} id={`expectation-review-${index + 1}`} className="rounded-xl border bg-muted/15 p-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p className="text-sm font-medium">{item.name}</p>
                    <p className="text-xs text-muted-foreground">{item.caseKey} · {item.status}</p>
                  </div>
                  <Badge variant={item.expectationSchemaVersion === "case_expectation_v1" ? "default" : "outline"}>
                    {item.expectationSchemaVersion === "case_expectation_v1" ? "Exact expectation" : "No case expectation"}
                  </Badge>
                </div>
                {item.expectationSchemaVersion === "case_expectation_v1" && (
                  <div className="mt-3 space-y-2">
                    <pre className="max-h-72 overflow-auto rounded-lg border bg-background p-3 text-xs leading-5"><code>{item.expectationJson}</code></pre>
                    <code className="block break-all text-[11px] text-muted-foreground">Fingerprint: {item.expectationFingerprint}</code>
                  </div>
                )}
              </div>
            ))}
          </section>

          <Alert id="provider-call-preview" className="border-primary/20 bg-primary/5">
            <Send />
            <AlertTitle>Provider-call preview</AlertTitle>
            <AlertDescription className="space-y-2">
              <p><strong>Setup and completion:</strong> 0 provider calls.</p>
              <p>
                A one-sample reviewed reference would plan {activeCaseCount} provider call{activeCaseCount === 1 ? "" : "s"}: one per active case. Its capture page shows the selected sample count, maximum reserved calls including retries, and unavailable currency estimate before execution.
              </p>
            </AlertDescription>
          </Alert>

          {setup.requestMode === "legacy_wrapped_v1" && (
            <Alert id="legacy-review-warning" className="border-warning/35 bg-warning/5">
              <AlertTriangle />
              <AlertTitle>Legacy request wrapper preserved</AlertTitle>
              <AlertDescription>
                These previews include the historical Context, Question, and Response requirements wrapper. No conversion was applied.
              </AlertDescription>
            </Alert>
          )}

          <section id="provider-request-previews" className="space-y-3" aria-labelledby="provider-request-previews-title">
            <div>
              <h2 id="provider-request-previews-title" className="text-base font-semibold">Exact provider-visible requests</h2>
              <p className="mt-1 text-sm leading-6 text-muted-foreground">
                Secret-free method, endpoint, API version, and body after case-variable substitution. This artifact is fingerprinted again before every call.
              </p>
            </div>
            {requestPreviews.map((preview, index) => (
              <details
                key={preview.caseKey}
                id={`request-preview-${index + 1}`}
                className="group overflow-hidden rounded-xl border bg-muted/15"
              >
                <summary className="flex cursor-pointer list-none flex-col gap-2 px-4 py-3 transition-colors hover:bg-muted/40 sm:flex-row sm:items-center sm:justify-between">
                  <span>
                    <span className="block text-sm font-medium">{preview.caseName}</span>
                    <span className="block text-xs text-muted-foreground">{preview.caseKey}</span>
                  </span>
                  <code className="break-all text-[11px] text-muted-foreground">{preview.requestFingerprint}</code>
                </summary>
                <pre className="max-h-[32rem] overflow-auto border-t bg-background p-4 text-xs leading-5"><code>{preview.artifactJson}</code></pre>
              </details>
            ))}
          </section>

          {complete ? (
            <div className="space-y-4">
              <Alert id="setup-complete-state" className="border-success/25 bg-success/5">
                <CheckCircle2 />
                <AlertTitle>{setup.isSuccessor ? "Successor ready for activation review" : "Configuration ready for contract authoring"}</AlertTitle>
                <AlertDescription>
                  {setup.isSuccessor
                    ? "The active configuration is still unchanged. Review exact-model proof, changed areas, and replacement-reference impact before activation."
                    : "Define and validate the deterministic rules this exact monitor version must enforce. Authoring and fixture evaluation make zero provider calls."}
                </AlertDescription>
              </Alert>
              <div className="flex justify-end">
                <Button id={setup.isSuccessor ? "review-successor-activation" : "start-contract-authoring"} asChild>
                  <Link href={setup.isSuccessor ? `/app/${workspaceSlug}/monitors/${setup.monitor.id}/successor` : `/app/${workspaceSlug}/monitors/${setup.monitor.id}/contract`}>
                    {setup.isSuccessor ? "Review successor activation" : "Define deterministic contract"} <ArrowRight />
                  </Link>
                </Button>
              </div>
            </div>
          ) : (
            <form id="complete-monitor-setup-form" onSubmit={submit}>
              <div className="flex flex-col-reverse gap-3 border-t pt-6 sm:flex-row sm:items-center sm:justify-between">
                <SaveAndExit basePath={basePath} step="review" />
                <Button id="complete-monitor-setup" type="submit" disabled={form.processing}>
                  {form.processing ? <LoaderCircle className="animate-spin" /> : <LockKeyhole />}
                  {setup.isSuccessor ? "Lock successor candidate" : "Finish and lock setup"}
                </Button>
              </div>
            </form>
          )}
        </CardContent>
      </Card>

      <aside className="space-y-4">
        <CallBoundary
          stored="Provider/model, versioned request template, generation settings, frozen cases, exact previews, and immutable fingerprints."
          sent="Nothing now. Future runs send the exact reviewed body for each active case to the selected provider endpoint."
        />
        <Card>
          <CardContent className="p-5">
            <ShieldCheck className="size-5 text-success" />
            <p className="mt-3 text-sm font-medium">No silent substitutions</p>
            <p className="mt-1 text-sm leading-6 text-muted-foreground">
              The exact provider, requested model, effective request body, configuration, and case fingerprints remain part of the version provenance.
            </p>
          </CardContent>
        </Card>
      </aside>
    </div>
  )
}

type StepProps = {
  basePath: string
  errors: SharedPageProps["errors"]
  setup: Setup
}

function StepLayout({
  aside,
  children,
  description,
  title,
}: {
  aside: React.ReactNode
  children: React.ReactNode
  description: string
  title: string
}) {
  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_0.42fr]">
      <Card className="border-primary/15">
        <CardHeader>
          <CardTitle>{title}</CardTitle>
          <CardDescription>{description}</CardDescription>
        </CardHeader>
        <CardContent>{children}</CardContent>
      </Card>
      <aside>{aside}</aside>
    </div>
  )
}

function FormActions({
  basePath,
  disabled = false,
  processing,
  step,
  submitLabel = "Save and continue",
}: {
  basePath: string
  disabled?: boolean
  processing: boolean
  step: Step
  submitLabel?: string
}) {
  return (
    <div className="flex flex-col-reverse gap-3 border-t pt-6 sm:flex-row sm:items-center sm:justify-between">
      <SaveAndExit basePath={basePath} step={step} />
      <Button id={`save-${step}-step`} type="submit" disabled={disabled || processing}>
        {processing ? <LoaderCircle className="animate-spin" /> : <ArrowRight />}
        {submitLabel}
      </Button>
    </div>
  )
}

function SaveAndExit({ basePath, step }: { basePath: string; step: Step }) {
  const [leaving, setLeaving] = useState(false)

  return (
    <Button
      type="button"
      variant="ghost"
      disabled={leaving}
      onClick={() => {
        setLeaving(true)
        router.post(`${basePath}/leave`, { step }, { onFinish: () => setLeaving(false) })
      }}
    >
      {leaving ? <LoaderCircle className="animate-spin" /> : <Save />}
      Save and exit
    </Button>
  )
}

function StoredNotSent() {
  return (
    <CallBoundary
      stored="The monitor name, description, and setup progress inside this workspace."
      sent="Nothing. Purpose is internal metadata and never becomes provider prompt content."
    />
  )
}

function CallBoundary({ stored, sent }: { stored: string; sent: string }) {
  return (
    <Card className="sticky top-24">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base"><Database className="size-4 text-primary" /> Data boundary</CardTitle>
        <CardDescription>Know what happens before you continue.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        <div>
          <p className="flex items-center gap-2 text-sm font-medium"><Database className="size-4 text-primary" /> Stored by Silent Regression</p>
          <p className="mt-2 text-sm leading-6 text-muted-foreground">{stored}</p>
        </div>
        <div className="border-t pt-5">
          <p className="flex items-center gap-2 text-sm font-medium"><Send className="size-4 text-primary" /> Sent to the provider</p>
          <p className="mt-2 text-sm leading-6 text-muted-foreground">{sent}</p>
        </div>
        <Badge variant="secondary" className="bg-success/10 text-success"><ShieldCheck /> 0 calls during setup</Badge>
      </CardContent>
    </Card>
  )
}

function OptionalNumber({
  id,
  label,
  max,
  onChange,
  value,
}: {
  id: string
  label: string
  max: number
  onChange: (value: string) => void
  value: string
}) {
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <Input
        id={id}
        type="number"
        min={0}
        max={max}
        step="0.01"
        placeholder="Provider default"
        value={value}
        onChange={event => onChange(event.target.value)}
      />
    </div>
  )
}

function ReviewRow({ detail, label, value }: { detail?: string | null; label: string; value: string }) {
  return (
    <div className="grid gap-2 border-b pb-5 last:border-b-0 sm:grid-cols-[0.32fr_1fr]">
      <p className="text-sm text-muted-foreground">{label}</p>
      <div>
        <p className="text-sm font-medium">{value}</p>
        {detail && <p className="mt-1 text-sm leading-6 text-muted-foreground">{detail}</p>}
      </div>
    </div>
  )
}

function FieldError({ message }: { message: string }) {
  return <p className="text-sm text-destructive">{message}</p>
}

function emptyCase() {
  return {
    case_key: "",
    name: "",
    status: "active",
    input_variables_json: "{}",
    frozen_context: "",
    expectation_json: "",
  }
}

function caseForForm(item: SetupCase) {
  return {
    case_key: item.caseKey,
    name: item.name,
    status: item.status,
    input_variables_json: item.inputVariablesJson,
    frozen_context: item.frozenContext,
    expectation_json: item.expectationJson,
  }
}

function stepIndex(step: Step) {
  return steps.findIndex(item => item.id === step)
}

function stepLabel(step: Step) {
  return steps.find(item => item.id === step)?.label || "Monitor setup"
}

function providerLabel(provider: Provider) {
  return provider === "openai" ? "OpenAI" : "Anthropic"
}

function responseFormatLabel(format: Setup["responseFormat"]["type"]) {
  if (format === "json_object") return "JSON object"
  if (format === "json_schema") return "JSON schema"
  return "Text"
}
