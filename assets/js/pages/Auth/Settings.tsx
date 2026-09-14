import { FormEvent } from "react"
import { Head, Link, useForm, usePage } from "@inertiajs/react"
import { ArrowLeft, KeyRound, Mail } from "lucide-react"

import { Alert, AlertDescription } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import type { SharedPageProps } from "@/types/page"

export default function Settings({ email }: { email: string }) {
  const { errors, flash } = usePage<SharedPageProps>().props
  const emailForm = useForm({ user: { email } })
  const passwordForm = useForm({
    user: { password: "", password_confirmation: "" },
  })

  function updateEmail(event: FormEvent) {
    event.preventDefault()
    emailForm.put("/users/settings/email", { preserveScroll: true })
  }

  function updatePassword(event: FormEvent) {
    event.preventDefault()
    passwordForm.put("/users/settings/password", {
      preserveScroll: true,
      onFinish: () => passwordForm.reset(),
    })
  }

  return (
    <>
      <Head title="Account settings" />
      <div className="min-h-screen bg-muted/30 px-4 py-10 text-foreground sm:px-6">
        <div className="mx-auto max-w-3xl">
          <Button asChild variant="ghost" className="mb-6 -ml-3">
            <Link href="/app">
              <ArrowLeft /> Back to workspace
            </Link>
          </Button>

          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.18em] text-primary">Identity</p>
            <h1 className="mt-2 text-3xl font-semibold tracking-tight">Account settings</h1>
            <p className="mt-2 text-sm leading-6 text-muted-foreground">
              Manage the login identity shared across your invited workspaces.
            </p>
          </div>

          {flash.info && (
            <Alert className="mt-6 border-success/25 bg-success/5">
              <AlertDescription>{flash.info}</AlertDescription>
            </Alert>
          )}
          {flash.error && (
            <Alert variant="destructive" className="mt-6">
              <AlertDescription>{flash.error}</AlertDescription>
            </Alert>
          )}

          <div className="mt-8 grid gap-6">
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <Mail className="size-5 text-primary" /> Work email
                </CardTitle>
                <CardDescription>A confirmation link is sent before the address changes.</CardDescription>
              </CardHeader>
              <CardContent>
                <form id="update-email-form" className="space-y-4" onSubmit={updateEmail}>
                  <div className="space-y-2">
                    <Label htmlFor="settings-email">Email</Label>
                    <Input
                      id="settings-email"
                      type="email"
                      autoComplete="email"
                      required
                      aria-invalid={Boolean(errors.email)}
                      aria-describedby={errors.email ? "settings-email-error" : undefined}
                      value={emailForm.data.user.email}
                      onChange={event => emailForm.setData("user.email", event.target.value)}
                    />
                    {errors.email && (
                      <p id="settings-email-error" className="text-sm text-destructive">
                        {errors.email}
                      </p>
                    )}
                  </div>
                  <Button type="submit" disabled={emailForm.processing}>
                    {emailForm.processing ? "Sending confirmation…" : "Update email"}
                  </Button>
                </form>
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <KeyRound className="size-5 text-primary" /> Password
                </CardTitle>
                <CardDescription>Use at least 12 characters. Magic-link login remains available.</CardDescription>
              </CardHeader>
              <CardContent>
                <form id="update-password-form" className="space-y-4" onSubmit={updatePassword}>
                  <div className="space-y-2">
                    <Label htmlFor="settings-password">New password</Label>
                    <Input
                      id="settings-password"
                      type="password"
                      autoComplete="new-password"
                      minLength={12}
                      maxLength={72}
                      required
                      aria-invalid={Boolean(errors.password)}
                      value={passwordForm.data.user.password}
                      onChange={event =>
                        passwordForm.setData("user.password", event.target.value)
                      }
                    />
                    {errors.password && <p className="text-sm text-destructive">{errors.password}</p>}
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="settings-password-confirmation">Confirm new password</Label>
                    <Input
                      id="settings-password-confirmation"
                      type="password"
                      autoComplete="new-password"
                      minLength={12}
                      maxLength={72}
                      required
                      aria-invalid={Boolean(errors.passwordConfirmation)}
                      value={passwordForm.data.user.password_confirmation}
                      onChange={event =>
                        passwordForm.setData("user.password_confirmation", event.target.value)
                      }
                    />
                    {errors.passwordConfirmation && (
                      <p className="text-sm text-destructive">{errors.passwordConfirmation}</p>
                    )}
                  </div>
                  <Button type="submit" disabled={passwordForm.processing}>
                    {passwordForm.processing ? "Updating password…" : "Update password"}
                  </Button>
                </form>
              </CardContent>
            </Card>
          </div>
        </div>
      </div>
    </>
  )
}
