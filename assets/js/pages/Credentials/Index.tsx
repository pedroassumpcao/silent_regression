import { FormEvent, useState } from "react"
import { Head, router, useForm, usePage } from "@inertiajs/react"
import {
  CheckCircle2,
  Clock3,
  KeyRound,
  LoaderCircle,
  LockKeyhole,
  MoreHorizontal,
  RefreshCw,
  ShieldCheck,
  Trash2,
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
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import type { SharedPageProps } from "@/types/page"

type Provider = "openai" | "anthropic"
type CredentialStatus = "pending_validation" | "valid" | "invalid" | "revoked" | "superseded"

type Credential = {
  id: string
  provider: Provider
  label: string
  secretSuffix: string
  status: CredentialStatus
  lastValidationStatus: "succeeded" | "failed" | null
  lastFailureCategory: string | null
  lastValidatedAt: string | null
  lastRequestedModel: string | null
  lastReturnedModel: string | null
  lastProviderRequestId: string | null
  lastValidationAttempts: number | null
  supersedesId: string | null
  insertedAt: string
}

type CredentialsPageProps = {
  auth: SharedPageProps["auth"]
  canManage: boolean
  credentials: Credential[]
  releaseStage: string
}

const activeStatuses: CredentialStatus[] = ["pending_validation", "valid", "invalid"]

export default function CredentialsIndex(props: CredentialsPageProps) {
  const { errors, flash } = usePage<SharedPageProps>().props

  return (
    <>
      <Head title="Provider credentials" />
      <CredentialsView {...props} errors={errors} flash={flash} />
    </>
  )
}

export function CredentialsView({
  auth,
  canManage,
  credentials,
  errors,
  flash,
  releaseStage,
}: CredentialsPageProps & Pick<SharedPageProps, "errors" | "flash">) {
  const workspace = auth.workspace
  const user = auth.user
  const createForm = useForm({
    provider_credential: {
      provider: "openai" as Provider,
      label: "",
      secret: "",
    },
  })

  if (!workspace) return null
  const workspaceSlug = workspace.slug

  function createCredential(event: FormEvent) {
    event.preventDefault()

    createForm.post(`/app/${workspaceSlug}/credentials`, {
      preserveScroll: true,
      onSuccess: () => createForm.reset(),
      onFinish: () => createForm.setData("provider_credential.secret", ""),
    })
  }

  return (
      <ProductShell
        availableWorkspaces={auth.workspaces}
        currentSection="credentials"
        releaseStage={releaseStage}
        userEmail={user?.email || "Invited user"}
        workspace={workspace}
        membershipRole={auth.membership?.role || "member"}
      >
        <div className="mx-auto max-w-6xl space-y-8">
          <section className="flex flex-col justify-between gap-5 sm:flex-row sm:items-end">
            <div>
              <div className="mb-3 flex items-center gap-2">
                <Badge variant="outline" className="rounded-full border-primary/25 text-primary">
                  <LockKeyhole /> Encrypted at rest
                </Badge>
              </div>
              <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">
                Provider credentials
              </h1>
              <p className="mt-3 max-w-2xl text-base leading-7 text-muted-foreground">
                Store the OpenAI or Anthropic key used for managed replay. Secrets are write-only;
                after submission, only the final four characters remain visible.
              </p>
            </div>
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <ShieldCheck className="size-4 text-success" />
              Workspace isolated
            </div>
          </section>

          {flash.info && (
            <Alert id="credential-success" className="border-success/25 bg-success/5">
              <CheckCircle2 />
              <AlertTitle>Credential updated</AlertTitle>
              <AlertDescription>{flash.info}</AlertDescription>
            </Alert>
          )}

          {flash.error && (
            <Alert id="credential-error" variant="destructive">
              <AlertTitle>Credential action needs attention</AlertTitle>
              <AlertDescription>{flash.error}</AlertDescription>
            </Alert>
          )}

          {canManage ? (
            <Card id="add-credential-card" className="border-primary/15">
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <KeyRound className="size-5 text-primary" /> Add a credential
                </CardTitle>
                <CardDescription>
                  Saving does not call the provider. Validate explicitly after the encrypted record
                  is created.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <form
                  id="create-provider-credential-form"
                  className="grid gap-5 lg:grid-cols-[0.7fr_1fr_1.5fr_auto] lg:items-end"
                  onSubmit={createCredential}
                >
                  <div className="space-y-2">
                    <Label htmlFor="credential-provider">Provider</Label>
                    <Select
                      value={createForm.data.provider_credential.provider}
                      onValueChange={provider =>
                        createForm.setData("provider_credential.provider", provider as Provider)
                      }
                    >
                      <SelectTrigger id="credential-provider" className="w-full">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="openai">OpenAI</SelectItem>
                        <SelectItem value="anthropic">Anthropic</SelectItem>
                      </SelectContent>
                    </Select>
                    {errors.provider && <FieldError message={errors.provider} />}
                  </div>

                  <div className="space-y-2">
                    <Label htmlFor="credential-label">Label</Label>
                    <Input
                      id="credential-label"
                      name="provider_credential[label]"
                      maxLength={80}
                      placeholder="Production key"
                      required
                      value={createForm.data.provider_credential.label}
                      aria-invalid={Boolean(errors.label)}
                      onChange={event =>
                        createForm.setData("provider_credential.label", event.target.value)
                      }
                    />
                    {errors.label && <FieldError message={errors.label} />}
                  </div>

                  <div className="space-y-2">
                    <Label htmlFor="credential-secret">API key</Label>
                    <Input
                      id="credential-secret"
                      name="provider_credential[secret]"
                      type="password"
                      autoComplete="off"
                      minLength={8}
                      maxLength={512}
                      placeholder="Paste once; it will not be shown again"
                      required
                      value={createForm.data.provider_credential.secret}
                      aria-invalid={Boolean(errors.secret)}
                      onChange={event =>
                        createForm.setData("provider_credential.secret", event.target.value)
                      }
                    />
                    {errors.secret && <FieldError message={errors.secret} />}
                  </div>

                  <Button id="save-credential-button" type="submit" disabled={createForm.processing}>
                    {createForm.processing ? <LoaderCircle className="animate-spin" /> : <KeyRound />}
                    {createForm.processing ? "Encrypting…" : "Save credential"}
                  </Button>
                </form>
              </CardContent>
            </Card>
          ) : (
            <Alert id="member-credential-access" className="border-primary/20 bg-primary/5">
              <ShieldCheck />
              <AlertTitle>Safe workspace access</AlertTitle>
              <AlertDescription>
                Members can see credential status and use valid credentials in monitors. Only owners
                can add, validate, rotate, or revoke them.
              </AlertDescription>
            </Alert>
          )}

          <Card id="credential-list-card">
            <CardHeader>
              <CardTitle>Workspace credentials</CardTitle>
              <CardDescription>
                Validation checks provider access through the Models API and does not generate
                content or consume output tokens.
              </CardDescription>
            </CardHeader>
            <CardContent>
              {credentials.length === 0 ? (
                <div id="credentials-empty-state" className="rounded-2xl border border-dashed p-10 text-center">
                  <KeyRound className="mx-auto size-6 text-primary" />
                  <h2 className="mt-4 font-semibold">No provider credentials yet</h2>
                  <p className="mx-auto mt-2 max-w-md text-sm leading-6 text-muted-foreground">
                    {canManage
                      ? "Add the first write-only credential above, then validate it before monitor setup."
                      : "A workspace owner must add and validate a provider credential before monitor setup."}
                  </p>
                </div>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Credential</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Last validation</TableHead>
                      <TableHead>Safe provenance</TableHead>
                      {canManage && <TableHead className="text-right">Actions</TableHead>}
                    </TableRow>
                  </TableHeader>
                  <TableBody id="provider-credentials">
                    {credentials.map(credential => (
                      <CredentialRow
                        key={credential.id}
                        credential={credential}
                        canManage={canManage}
                        secretError={errors.secret}
                        workspaceSlug={workspace.slug}
                      />
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>
        </div>
    </ProductShell>
  )
}

function CredentialRow({
  canManage,
  credential,
  secretError,
  workspaceSlug,
}: {
  canManage: boolean
  credential: Credential
  secretError?: string
  workspaceSlug: string
}) {
  const active = activeStatuses.includes(credential.status)
  const [validating, setValidating] = useState(false)

  function validateCredential() {
    router.post(
      `/app/${workspaceSlug}/credentials/${credential.id}/validate`,
      {},
      {
        preserveScroll: true,
        onStart: () => setValidating(true),
        onFinish: () => setValidating(false),
      },
    )
  }

  return (
    <TableRow id={`credential-${credential.id}`}>
      <TableCell>
        <div className="font-medium">{credential.label}</div>
        <div className="mt-1 flex items-center gap-2 text-xs text-muted-foreground">
          <span className="capitalize">{credential.provider}</span>
          <span aria-hidden="true">·</span>
          <code className="font-mono">•••• {credential.secretSuffix}</code>
          {credential.supersedesId && (
            <Badge variant="outline" className="px-1.5 py-0 text-[10px]">
              Rotated
            </Badge>
          )}
        </div>
      </TableCell>
      <TableCell>
        <StatusBadge status={credential.status} />
      </TableCell>
      <TableCell>
        <div className="text-sm">{validationLabel(credential)}</div>
        <div className="mt-1 text-xs text-muted-foreground">
          {formatTimestamp(credential.lastValidatedAt)}
        </div>
      </TableCell>
      <TableCell>
        <div className="max-w-52 truncate text-sm">
          {credential.lastReturnedModel || "No model returned"}
        </div>
        <div className="mt-1 max-w-52 truncate font-mono text-xs text-muted-foreground">
          {credential.lastProviderRequestId || "No request ID"}
        </div>
      </TableCell>
      {canManage && (
        <TableCell className="text-right">
          {active ? (
            <div className="flex justify-end gap-2">
              <Button
                id={`validate-credential-${credential.id}`}
                type="button"
                size="sm"
                variant="outline"
                disabled={validating}
                onClick={validateCredential}
              >
                {validating ? <LoaderCircle className="animate-spin" /> : <RefreshCw />}
                {validating ? "Validating…" : "Validate"}
              </Button>
              <RotateCredentialDialog
                credential={credential}
                secretError={secretError}
                workspaceSlug={workspaceSlug}
              />
              <RevokeCredentialDialog credential={credential} workspaceSlug={workspaceSlug} />
            </div>
          ) : (
            <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
              <MoreHorizontal className="size-4" /> No actions
            </span>
          )}
        </TableCell>
      )}
    </TableRow>
  )
}

function RotateCredentialDialog({
  credential,
  secretError,
  workspaceSlug,
}: {
  credential: Credential
  secretError?: string
  workspaceSlug: string
}) {
  const [open, setOpen] = useState(false)
  const form = useForm({provider_credential: {secret: ""}})

  function rotateCredential(event: FormEvent) {
    event.preventDefault()

    form.post(`/app/${workspaceSlug}/credentials/${credential.id}/rotate`, {
      preserveScroll: true,
      onSuccess: () => setOpen(false),
      onFinish: () => form.setData("provider_credential.secret", ""),
    })
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button id={`rotate-credential-${credential.id}`} type="button" size="sm" variant="ghost">
          <RefreshCw /> Rotate
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Rotate {credential.label}</DialogTitle>
          <DialogDescription>
            The replacement gets a new identity. Historical runs keep referencing this credential,
            which becomes superseded.
          </DialogDescription>
        </DialogHeader>
        <form id={`rotate-credential-form-${credential.id}`} className="space-y-4" onSubmit={rotateCredential}>
          <div className="space-y-2">
            <Label htmlFor={`rotated-secret-${credential.id}`}>New API key</Label>
            <Input
              id={`rotated-secret-${credential.id}`}
              type="password"
              autoComplete="off"
              minLength={8}
              maxLength={512}
              required
              value={form.data.provider_credential.secret}
              aria-invalid={Boolean(secretError)}
              onChange={event => form.setData("provider_credential.secret", event.target.value)}
            />
            {secretError && <FieldError message={secretError} />}
          </div>
          <DialogFooter>
            <DialogClose asChild>
              <Button type="button" variant="outline">Cancel</Button>
            </DialogClose>
            <Button type="submit" disabled={form.processing}>
              {form.processing && <LoaderCircle className="animate-spin" />}
              Create replacement
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

function RevokeCredentialDialog({
  credential,
  workspaceSlug,
}: {
  credential: Credential
  workspaceSlug: string
}) {
  const [open, setOpen] = useState(false)
  const form = useForm({})

  function revokeCredential() {
    form.delete(`/app/${workspaceSlug}/credentials/${credential.id}`, {
      preserveScroll: true,
      onSuccess: () => setOpen(false),
    })
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button id={`revoke-credential-${credential.id}`} type="button" size="sm" variant="ghost">
          <Trash2 /> Revoke
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Revoke {credential.label}?</DialogTitle>
          <DialogDescription>
            New executions will no longer be allowed to use this credential. Historical identity and
            safe provenance remain available for auditability.
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline">Cancel</Button>
          </DialogClose>
          <Button type="button" variant="destructive" disabled={form.processing} onClick={revokeCredential}>
            {form.processing && <LoaderCircle className="animate-spin" />}
            Revoke credential
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function StatusBadge({ status }: { status: CredentialStatus }) {
  const details = {
    pending_validation: { label: "Pending validation", className: "border-warning/30 bg-warning/10 text-warning" },
    valid: { label: "Valid", className: "border-success/30 bg-success/10 text-success" },
    invalid: { label: "Invalid", className: "border-destructive/30 bg-destructive/10 text-destructive" },
    revoked: { label: "Revoked", className: "border-border bg-muted text-muted-foreground" },
    superseded: { label: "Superseded", className: "border-border bg-muted text-muted-foreground" },
  }[status]

  return (
    <Badge variant="outline" className={details.className}>
      {status === "pending_validation" && <Clock3 />}
      {status === "valid" && <CheckCircle2 />}
      {details.label}
    </Badge>
  )
}

function validationLabel(credential: Credential) {
  if (credential.lastValidationStatus === "succeeded") return "Access confirmed"
  if (credential.lastFailureCategory) return credential.lastFailureCategory.replaceAll("_", " ")
  return "Not validated"
}

function formatTimestamp(value: string | null) {
  if (!value) return "—"

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value))
}

function FieldError({ message }: { message: string }) {
  return <p className="text-sm text-destructive">{message}</p>
}
