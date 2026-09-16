import { FormEvent } from "react"
import { Head, useForm, usePage } from "@inertiajs/react"
import { BellRing, CheckCircle2, LoaderCircle, LockKeyhole, Mail } from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { Switch } from "@/components/ui/switch"
import type { SharedPageProps } from "@/types/page"

type NotificationSettingsProps = {
  auth: SharedPageProps["auth"]
  preference: { actionableAlertEmailEnabled: boolean }
  releaseStage: string
}

export default function NotificationSettings(props: NotificationSettingsProps) {
  const { flash } = usePage<SharedPageProps>().props

  return (
    <>
      <Head title="Notification settings" />
      <NotificationSettingsView {...props} flash={flash} />
    </>
  )
}

export function NotificationSettingsView({
  auth,
  flash,
  preference,
  releaseStage,
}: NotificationSettingsProps & { flash: SharedPageProps["flash"] }) {
  const workspace = auth.workspace
  const form = useForm({
    notification_preference: {
      actionable_alert_email_enabled: preference.actionableAlertEmailEnabled,
    },
  })

  if (!workspace) return null

  function savePreference(event: FormEvent) {
    event.preventDefault()
    form.patch(`/app/${workspace!.slug}/settings/notifications`, { preserveScroll: true })
  }

  return (
    <ProductShell
      availableWorkspaces={auth.workspaces}
      currentSection="notifications"
      releaseStage={releaseStage}
      userEmail={auth.user?.email || "Invited user"}
      workspace={workspace}
      membershipRole={auth.membership?.role || "member"}
    >
      <div className="mx-auto max-w-4xl space-y-8">
        <section>
          <Badge variant="outline" className="mb-3 rounded-full border-primary/25 text-primary">
            <BellRing /> Workspace alerts
          </Badge>
          <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">
            Notification settings
          </h1>
          <p className="mt-3 max-w-2xl text-base leading-7 text-muted-foreground">
            Choose whether actionable alerts for {workspace.name} are sent to your account email.
            This preference is personal to you in this workspace.
          </p>
        </section>

        {flash.info && (
          <Alert id="notification-preference-success" className="border-success/25 bg-success/5">
            <CheckCircle2 />
            <AlertTitle>Preference saved</AlertTitle>
            <AlertDescription>{flash.info}</AlertDescription>
          </Alert>
        )}

        <Card id="notification-preference-card" className="border-primary/15">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Mail className="size-5 text-primary" /> Actionable-alert email
            </CardTitle>
            <CardDescription>
              Receive one deduplicated email per alert created while this preference is enabled.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <form id="notification-preference-form" onSubmit={savePreference}>
              <div className="flex flex-col gap-5 rounded-2xl border bg-muted/25 p-5 sm:flex-row sm:items-center sm:justify-between">
                <div className="max-w-xl space-y-1.5">
                  <Label htmlFor="actionable-alert-email" className="text-base">
                    Email me when an alert needs review
                  </Label>
                  <p className="text-sm leading-6 text-muted-foreground">
                    Emails identify the monitor, category, and severity, then link back to
                    authenticated evidence. Prompts, contexts, outputs, and rule evidence are never
                    included.
                  </p>
                </div>
                <Switch
                  id="actionable-alert-email"
                  aria-label="Email me when an alert needs review"
                  checked={form.data.notification_preference.actionable_alert_email_enabled}
                  onCheckedChange={checked =>
                    form.setData(
                      "notification_preference.actionable_alert_email_enabled",
                      checked,
                    )
                  }
                />
              </div>

              <div className="mt-5 flex flex-wrap items-center justify-between gap-4">
                <div className="flex items-center gap-2 text-xs text-muted-foreground">
                  <LockKeyhole className="size-4 text-success" />
                  Delivery records store IDs and bounded status only—not email content.
                </div>
                <Button id="save-notification-preference" type="submit" disabled={form.processing}>
                  {form.processing && <LoaderCircle className="animate-spin" />}
                  {form.processing ? "Saving…" : "Save preference"}
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>
      </div>
    </ProductShell>
  )
}
