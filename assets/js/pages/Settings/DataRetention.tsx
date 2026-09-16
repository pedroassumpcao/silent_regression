import { FormEvent, useState } from "react"
import { Head, useForm, usePage } from "@inertiajs/react"
import { ArchiveRestore, Database, LoaderCircle, ShieldAlert, Trash2 } from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import type { SharedPageProps } from "@/types/page"

type DataRetentionProps = {
  auth: SharedPageProps["auth"]
  canManage: boolean
  policy: {
    activeWorkspace: string
    closedWorkspace: string
    explicitDeletion: string
    backups: string
  }
  releaseStage: string
}

export default function DataRetention(props: DataRetentionProps) {
  const { flash } = usePage<SharedPageProps>().props

  return (
    <>
      <Head title="Data and retention" />
      <DataRetentionView {...props} flash={flash} />
    </>
  )
}

export function DataRetentionView(
  props: DataRetentionProps & { flash: SharedPageProps["flash"] },
) {
  const workspace = props.auth.workspace

  if (!workspace) return null

  return (
    <>
      <ProductShell
        availableWorkspaces={props.auth.workspaces}
        currentSection="data"
        membershipRole={props.auth.membership?.role || "member"}
        releaseStage={props.releaseStage}
        userEmail={props.auth.user?.email || "Invited user"}
        workspace={workspace}
      >
        <div className="mx-auto max-w-4xl space-y-8">
          <section>
            <Badge variant="outline" className="mb-3 rounded-full border-primary/25 text-primary">
              <Database /> Workspace controls
            </Badge>
            <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">
              Data and retention
            </h1>
            <p className="mt-3 max-w-2xl text-base leading-7 text-muted-foreground">
              Understand how monitoring evidence is retained and control the lifecycle of {workspace.name}.
            </p>
          </section>

          {props.flash.error && (
            <Alert id="workspace-data-error" variant="destructive">
              <ShieldAlert />
              <AlertTitle>Action not completed</AlertTitle>
              <AlertDescription>{props.flash.error}</AlertDescription>
            </Alert>
          )}

          <Card id="retention-policy-card" className="border-primary/15">
            <CardHeader>
              <CardTitle>Retention policy</CardTitle>
              <CardDescription>Plain-language rules for customer evidence and deletion.</CardDescription>
            </CardHeader>
            <CardContent>
              <dl className="grid gap-4 sm:grid-cols-2">
                {Object.entries(props.policy).map(([key, value]) => (
                  <div key={key} className="rounded-2xl border bg-muted/25 p-4">
                    <dt className="text-sm font-medium capitalize">{key.replace(/([A-Z])/g, " $1")}</dt>
                    <dd className="mt-1.5 text-sm leading-6 text-muted-foreground">{value}</dd>
                  </div>
                ))}
              </dl>
            </CardContent>
          </Card>

          <div className="grid gap-5 md:grid-cols-2">
            <LifecycleCard
              id="close-workspace-card"
              title="Close workspace"
              description="Immediately stops runs and revokes provider credentials. An operator can recover the workspace for 30 days; schedules and credentials stay disabled until you reconfigure them."
              actionLabel="Close workspace"
              endpoint={`/app/${workspace.slug}/settings/data/close`}
              icon={ArchiveRestore}
              slug={workspace.slug}
              canManage={props.canManage}
            />
            <LifecycleCard
              id="delete-workspace-card"
              title="Request deletion"
              description="Immediately stops all activity and makes the workspace due for irreversible purge. This cannot be recovered after the operator processes it."
              actionLabel="Request deletion"
              endpoint={`/app/${workspace.slug}/settings/data/delete`}
              icon={Trash2}
              slug={workspace.slug}
              canManage={props.canManage}
              destructive
            />
          </div>

          {!props.canManage && (
            <p id="owner-required-note" className="text-sm text-muted-foreground">
              You can review this policy, but only a workspace owner can close or delete the workspace.
            </p>
          )}
        </div>
      </ProductShell>
    </>
  )
}

function LifecycleCard({
  actionLabel,
  canManage,
  description,
  destructive = false,
  endpoint,
  icon: Icon,
  id,
  slug,
  title,
}: {
  actionLabel: string
  canManage: boolean
  description: string
  destructive?: boolean
  endpoint: string
  icon: typeof ArchiveRestore
  id: string
  slug: string
  title: string
}) {
  const [open, setOpen] = useState(false)
  const form = useForm({ confirmation: "" })

  function submit(event: FormEvent) {
    event.preventDefault()
    form.post(endpoint, { onSuccess: () => setOpen(false) })
  }

  return (
    <Card id={id} className={destructive ? "border-destructive/25" : undefined}>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <Icon className={destructive ? "size-5 text-destructive" : "size-5 text-primary"} />
          {title}
        </CardTitle>
        <CardDescription className="leading-6">{description}</CardDescription>
      </CardHeader>
      <CardContent>
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild>
            <Button
              id={`${id}-trigger`}
              variant={destructive ? "destructive" : "outline"}
              disabled={!canManage}
            >
              {actionLabel}
            </Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>{actionLabel}?</DialogTitle>
              <DialogDescription>
                Provider access and scheduled execution stop immediately. Type the exact workspace slug to confirm.
              </DialogDescription>
            </DialogHeader>
            <form id={`${id}-form`} onSubmit={submit} className="space-y-5">
              <div className="space-y-2">
                <Label htmlFor={`${id}-confirmation`}>
                  Workspace slug <span className="font-mono text-foreground">{slug}</span>
                </Label>
                <Input
                  id={`${id}-confirmation`}
                  value={form.data.confirmation}
                  onChange={event => form.setData("confirmation", event.target.value)}
                  autoComplete="off"
                />
              </div>
              <DialogFooter>
                <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
                  Cancel
                </Button>
                <Button
                  id={`${id}-submit`}
                  type="submit"
                  variant={destructive ? "destructive" : "default"}
                  disabled={form.processing || form.data.confirmation !== slug}
                >
                  {form.processing && <LoaderCircle className="animate-spin" />}
                  {form.processing ? "Submitting…" : actionLabel}
                </Button>
              </DialogFooter>
            </form>
          </DialogContent>
        </Dialog>
      </CardContent>
    </Card>
  )
}
