import { FormEvent } from "react"
import { Head, useForm } from "@inertiajs/react"
import { ArrowRight, MailCheck } from "lucide-react"

import { AuthShell } from "@/components/auth-shell"
import { Button } from "@/components/ui/button"

type ConfirmLoginProps = { email: string; token: string }

export default function ConfirmLogin({ email, token }: ConfirmLoginProps) {
  const form = useForm({ user: { token, remember_me: true } })

  function submit(event: FormEvent) {
    event.preventDefault()
    form.post("/users/log-in")
  }

  return (
    <>
      <Head title="Confirm login" />
      <AuthShell
        eyebrow="Secure login"
        title="Confirm this sign-in."
        description={`The magic link was issued for ${email}. It is single-use and expires after fifteen minutes.`}
      >
        <div className="text-center">
          <span className="mx-auto grid size-14 place-items-center rounded-2xl bg-success/10 text-success">
            <MailCheck className="size-7" />
          </span>
          <h2 className="mt-5 text-xl font-semibold">Continue to Silent Regression</h2>
          <p className="mt-2 text-sm leading-6 text-muted-foreground">
            Only continue if you requested this login on this device.
          </p>
          <form id="confirm-login-form" className="mt-7" onSubmit={submit}>
            <Button type="submit" className="h-11 w-full" disabled={form.processing}>
              {form.processing ? "Confirming…" : "Confirm and log in"}
              {!form.processing && <ArrowRight />}
            </Button>
          </form>
        </div>
      </AuthShell>
    </>
  )
}
