import { FormEvent } from "react"
import { Head, useForm } from "@inertiajs/react"
import { ArrowRight, Building2, Clock3, ShieldCheck } from "lucide-react"

import { AuthShell } from "@/components/auth-shell"
import { Button } from "@/components/ui/button"

type AcceptInvitationProps = {
  email: string
  expiresAt: string
  role: "owner" | "member"
  token: string
  workspaceName: string
}

export default function AcceptInvitation({
  email,
  expiresAt,
  role,
  token,
  workspaceName,
}: AcceptInvitationProps) {
  const form = useForm({})

  function accept(event: FormEvent) {
    event.preventDefault()
    form.post(`/invitations/${token}`)
  }

  return (
    <>
      <Head title="Accept workspace invitation" />
      <AuthShell
        eyebrow="Single-use invitation"
        title={`Join ${workspaceName}.`}
        description="Accepting creates or connects your confirmed identity, grants only the invited workspace role, and signs you in."
      >
        <div className="space-y-5">
          <div className="rounded-xl border border-border bg-muted/35 p-5">
            <div className="flex items-start gap-3">
              <Building2 className="mt-0.5 size-5 text-primary" />
              <div>
                <p className="font-medium">{workspaceName}</p>
                <p className="mt-1 text-sm text-muted-foreground">{email}</p>
              </div>
            </div>
            <div className="mt-5 grid gap-3 border-t border-border pt-5 text-sm sm:grid-cols-2">
              <div>
                <p className="text-xs uppercase tracking-wide text-muted-foreground">Role</p>
                <p className="mt-1 font-medium capitalize">{role}</p>
              </div>
              <div>
                <p className="flex items-center gap-1.5 text-xs uppercase tracking-wide text-muted-foreground">
                  <Clock3 className="size-3.5" /> Expires
                </p>
                <p className="mt-1 font-medium">{new Date(expiresAt).toLocaleString()}</p>
              </div>
            </div>
          </div>

          <div className="flex gap-3 rounded-xl border border-success/20 bg-success/5 p-4 text-sm leading-6 text-muted-foreground">
            <ShieldCheck className="mt-0.5 size-5 shrink-0 text-success" />
            The token is stored only as a one-way hash and becomes unusable immediately after acceptance.
          </div>

          <form id="accept-invitation-form" onSubmit={accept}>
            <Button type="submit" className="h-11 w-full" disabled={form.processing}>
              {form.processing ? "Accepting invitation…" : "Accept invitation"}
              {!form.processing && <ArrowRight />}
            </Button>
          </form>
        </div>
      </AuthShell>
    </>
  )
}
