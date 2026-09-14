import { FormEvent } from "react"
import { Head, useForm } from "@inertiajs/react"
import { ArrowRight, KeyRound, Mail } from "lucide-react"

import { AuthShell } from "@/components/auth-shell"
import { Alert, AlertDescription } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"

type LoginProps = {
  email: string
  authError: string | null
}

export default function Login({ email, authError }: LoginProps) {
  const magicLink = useForm({ user: { email } })
  const password = useForm({ user: { email, password: "", remember_me: false } })

  function requestMagicLink(event: FormEvent) {
    event.preventDefault()
    magicLink.post("/users/log-in", { preserveScroll: true })
  }

  function logInWithPassword(event: FormEvent) {
    event.preventDefault()
    password.post("/users/log-in", {
      preserveScroll: true,
      onFinish: () => password.reset("user.password"),
    })
  }

  return (
    <>
      <Head title="Log in" />
      <AuthShell
        eyebrow="Private workspace access"
        title="Return to your monitored workflows."
        description="Only invited design partners can authenticate. There is no public registration path or self-service account creation."
        aside={
          <p className="mt-8 max-w-lg rounded-xl border border-border bg-card/60 p-4 text-sm leading-6 text-muted-foreground">
            Need access? Submit a design-partner application first. Approved teams receive a
            single-use workspace invitation.
          </p>
        }
      >
        <div>
          <div className="flex items-center gap-3">
            <span className="grid size-10 place-items-center rounded-xl bg-primary/10 text-primary">
              <Mail className="size-5" />
            </span>
            <div>
              <h2 className="font-semibold">Email magic link</h2>
              <p className="text-sm text-muted-foreground">Recommended for private-alpha access.</p>
            </div>
          </div>

          <form id="magic-link-login-form" className="mt-6 space-y-4" onSubmit={requestMagicLink}>
            <div className="space-y-2">
              <Label htmlFor="magic-link-email">Work email</Label>
              <Input
                id="magic-link-email"
                type="email"
                autoComplete="email"
                required
                value={magicLink.data.user.email}
                onChange={event => magicLink.setData("user.email", event.target.value)}
              />
            </div>
            <Button type="submit" className="h-11 w-full" disabled={magicLink.processing}>
              {magicLink.processing ? "Requesting link…" : "Email me a login link"}
              {!magicLink.processing && <ArrowRight />}
            </Button>
          </form>
        </div>

        <div className="my-8 flex items-center gap-4 text-xs font-medium uppercase tracking-[0.18em] text-muted-foreground">
          <span className="h-px flex-1 bg-border" /> or use a password <span className="h-px flex-1 bg-border" />
        </div>

        <div>
          <div className="flex items-center gap-3">
            <span className="grid size-10 place-items-center rounded-xl bg-muted text-muted-foreground">
              <KeyRound className="size-5" />
            </span>
            <h2 className="font-semibold">Password</h2>
          </div>

          {authError && (
            <Alert variant="destructive" className="mt-5">
              <AlertDescription>{authError}</AlertDescription>
            </Alert>
          )}

          <form id="password-login-form" className="mt-6 space-y-4" onSubmit={logInWithPassword}>
            <div className="space-y-2">
              <Label htmlFor="password-email">Work email</Label>
              <Input
                id="password-email"
                type="email"
                autoComplete="email"
                required
                value={password.data.user.email}
                onChange={event => password.setData("user.email", event.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="login-password">Password</Label>
              <Input
                id="login-password"
                type="password"
                autoComplete="current-password"
                required
                value={password.data.user.password}
                onChange={event => password.setData("user.password", event.target.value)}
              />
            </div>
            <label className="flex items-center gap-3 text-sm text-muted-foreground">
              <input
                type="checkbox"
                checked={password.data.user.remember_me}
                onChange={event => password.setData("user.remember_me", event.target.checked)}
                className="size-4 rounded border-input accent-primary"
              />
              Keep me logged in on this device
            </label>
            <Button type="submit" variant="outline" className="h-11 w-full" disabled={password.processing}>
              {password.processing ? "Logging in…" : "Log in with password"}
            </Button>
          </form>
        </div>
      </AuthShell>
    </>
  )
}
