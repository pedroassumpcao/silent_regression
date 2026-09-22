import { Head, Link, useForm } from "@inertiajs/react"
import { ArrowRight } from "lucide-react"
import { ProductShell } from "@/components/product-shell"
import { Button } from "@/components/ui/button"
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from "@/components/ui/card"
import type { SharedPageProps } from "@/types/page"
import { recipeNames, recipeGuidance, type Recipe } from "@/components/guided-recipe-editors"

export default function GuidedSetupStart({ auth }: { auth: SharedPageProps["auth"] }) {
  const form = useForm<{ recipe: Recipe }>({ recipe: "routing" })
  if (!auth.workspace) return null
  const base = `/app/${auth.workspace.slug}`
  return <>
    <Head title="Create a real monitor" />
    <ProductShell currentSection="monitors" releaseStage="Private alpha" availableWorkspaces={auth.workspaces} userEmail={auth.user?.email || "Invited user"} workspace={auth.workspace} membershipRole={auth.membership?.role || "member"}>
      <div className="mx-auto max-w-3xl space-y-6">
        <p className="text-sm font-medium text-primary">Step 0 · Choose your output shape</p>
        <h1 className="text-3xl font-semibold tracking-tight">Create a real monitor</h1>
        <p className="leading-7 text-muted-foreground">Start a saved workspace draft with your own request and known answers. No provider calls happen while you prepare it. A real first run needs separate owner approval.</p>
        <fieldset className="grid gap-3 sm:grid-cols-2"><legend className="mb-3 text-sm font-medium">What does your request return?</legend>{(Object.keys(recipeNames) as Recipe[]).map(recipe => <label key={recipe} className={`flex cursor-pointer items-start gap-3 rounded-xl border p-4 transition-colors hover:bg-muted/40 ${form.data.recipe === recipe ? "border-primary bg-primary/5" : "border-border"}`}><input type="radio" name="recipe" value={recipe} checked={form.data.recipe === recipe} onChange={() => form.setData("recipe", recipe)} className="mt-1 accent-primary" /><span><span className="block font-medium">{recipeNames[recipe]}</span><span className="mt-2 block text-sm leading-6 text-muted-foreground">{recipeGuidance[recipe]}</span></span></label>)}</fieldset>
        <Card><CardHeader><CardTitle>{recipeNames[form.data.recipe]}</CardTitle><CardDescription>This starts an empty saved draft—not a demo. You supply the request, examples and correct expectations.</CardDescription></CardHeader><CardContent className="space-y-5">
          <p className="text-sm leading-6">Request → examples → prove the checks → approve and run → review the result. Start without a schedule; on-demand checks are real provider calls, not simulations.</p>
          <p className="text-sm leading-6 text-muted-foreground">You can edit this choice before starting. Changing recipes later requires a separate draft and fresh proof review; your existing draft is kept.</p>
          <Button id="start-guided-setup" disabled={form.processing} onClick={() => form.post(`${base}/setup-drafts`)}>Start saved setup <ArrowRight /></Button>
        </CardContent></Card>
        <p className="text-sm text-muted-foreground">Need supported rules beyond a guided recipe? <Link className="underline underline-offset-4" href={`${base}/monitors/new`}>Use advanced setup</Link>. Existing contracts and versioned changes remain available there.</p>
        <p className="text-sm text-muted-foreground">Just exploring? <Link className="underline underline-offset-4" href={`${base}/setup-preview`}>Open the practice preview</Link>. Its fictional data never transfers to a real monitor.</p>
      </div>
    </ProductShell>
  </>
}
