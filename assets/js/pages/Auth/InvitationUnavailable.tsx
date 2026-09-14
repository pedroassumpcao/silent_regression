import { Head, Link } from "@inertiajs/react"
import { CircleSlash2 } from "lucide-react"

import { AuthShell } from "@/components/auth-shell"
import { Button } from "@/components/ui/button"

export default function InvitationUnavailable({ message }: { message: string }) {
  return (
    <>
      <Head title="Invitation unavailable" />
      <AuthShell
        eyebrow="Invitation unavailable"
        title="This link cannot be accepted."
        description={message}
      >
        <div className="text-center">
          <span className="mx-auto grid size-14 place-items-center rounded-2xl bg-destructive/10 text-destructive">
            <CircleSlash2 className="size-7" />
          </span>
          <p className="mt-5 text-sm leading-6 text-muted-foreground">
            Ask the workspace owner or operator for a new invitation if you still need access.
          </p>
          <Button asChild variant="outline" className="mt-7 h-11 w-full">
            <Link href="/users/log-in">Go to login</Link>
          </Button>
        </div>
      </AuthShell>
    </>
  )
}
