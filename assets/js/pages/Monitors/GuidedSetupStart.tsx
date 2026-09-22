import { Head, Link, useForm } from "@inertiajs/react"
import { ArrowRight } from "lucide-react"
import { ProductShell } from "@/components/product-shell"
import { Button } from "@/components/ui/button"
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from "@/components/ui/card"
import type { SharedPageProps } from "@/types/page"

export default function GuidedSetupStart({ auth }: { auth: SharedPageProps["auth"] }) {
  const form = useForm({})
  if (!auth.workspace) return null
  const base = `/app/${auth.workspace.slug}`
  return <>
    <Head title="Create a real monitor" />
    <ProductShell currentSection="monitors" releaseStage="Private alpha" availableWorkspaces={auth.workspaces} userEmail={auth.user?.email || "Invited user"} workspace={auth.workspace} membershipRole={auth.membership?.role || "member"}>
      <div className="mx-auto max-w-3xl space-y-6">
        <h1 className="text-3xl font-semibold tracking-tight">Create a real monitor</h1>
        <p className="leading-7 text-muted-foreground">Start a saved workspace draft with your own request and known answers. No provider calls happen while you prepare it. A real first run needs separate owner approval.</p>
        <Card><CardHeader><CardTitle>Classification / routing</CardTitle><CardDescription>Protect outputs that must be one of a small set of labels, with a known correct label for each example.</CardDescription></CardHeader><CardContent className="space-y-5">
          <p className="text-sm leading-6">Request → examples → prove the checks → approve and run → review the result. Start without a schedule; on-demand checks are real provider calls, not simulations.</p>
          <Button id="start-guided-setup" disabled={form.processing} onClick={() => form.post(`${base}/setup-drafts`)}>Start saved routing setup <ArrowRight /></Button>
        </CardContent></Card>
        <p className="text-sm text-muted-foreground">Need JSON fields, source IDs or text rules? <Link className="underline underline-offset-4" href={`${base}/monitors/new`}>Use the existing advanced setup</Link>. Guided editors for those workflows are still being built.</p>
        <p className="text-sm text-muted-foreground">Just exploring? <Link className="underline underline-offset-4" href={`${base}/setup-preview`}>Open the practice preview</Link>. Its fictional data never transfers to a real monitor.</p>
      </div>
    </ProductShell>
  </>
}
