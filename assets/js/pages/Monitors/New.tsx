import { FormEvent } from "react"
import { Head, Link, useForm, usePage } from "@inertiajs/react"
import { ArrowLeft, ArrowRight, Database, LoaderCircle, ShieldCheck } from "lucide-react"

import { ProductShell } from "@/components/product-shell"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import type { SharedPageProps } from "@/types/page"

type NewMonitorProps = {
  auth: SharedPageProps["auth"]
  releaseStage: string
}

export default function NewMonitor({ auth, releaseStage }: NewMonitorProps) {
  const { errors, flash } = usePage<SharedPageProps>().props
  const workspace = auth.workspace
  const form = useForm({ monitor: { name: "", description: "" } })

  if (!workspace) return null

  function submit(event: FormEvent) {
    event.preventDefault()
    form.post(`/app/${workspace!.slug}/monitors`)
  }

  return (
    <>
      <Head title="Create monitor" />
      <ProductShell
        availableWorkspaces={auth.workspaces}
        currentSection="monitors"
        releaseStage={releaseStage}
        userEmail={auth.user?.email || "Invited user"}
        workspace={workspace}
        membershipRole={auth.membership?.role || "member"}
      >
        <div className="mx-auto max-w-5xl space-y-7">
          <Button asChild variant="ghost" className="-ml-3">
            <Link href={`/app/${workspace.slug}/monitors`}>
              <ArrowLeft /> Back to monitors
            </Link>
          </Button>

          <section>
            <Badge variant="outline" className="rounded-full border-primary/25 text-primary">
              Step 1 of 5
            </Badge>
            <h1 className="mt-4 text-3xl font-semibold tracking-tight sm:text-4xl">
              What must keep working?
            </h1>
            <p className="mt-3 max-w-2xl text-base leading-7 text-muted-foreground">
              Give this monitor a clear purpose. You can save the rest of the setup one step at a
              time and return whenever you need to.
            </p>
          </section>

          {flash.error && (
            <Alert variant="destructive">
              <AlertTitle>Monitor could not be created</AlertTitle>
              <AlertDescription>{flash.error}</AlertDescription>
            </Alert>
          )}

          <div className="grid gap-6 lg:grid-cols-[1fr_0.42fr]">
            <Card className="border-primary/15">
              <CardHeader>
                <CardTitle>Monitor purpose</CardTitle>
                <CardDescription>
                  These are descriptive fields. They do not alter the future provider request.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <form id="create-monitor-form" className="space-y-6" onSubmit={submit}>
                  <div className="space-y-2">
                    <Label htmlFor="monitor-name">Name</Label>
                    <Input
                      id="monitor-name"
                      name="monitor[name]"
                      autoFocus
                      required
                      maxLength={120}
                      placeholder="Support answer citation guard"
                      aria-invalid={Boolean(errors.name)}
                      value={form.data.monitor.name}
                      onChange={event => form.setData("monitor.name", event.target.value)}
                    />
                    {errors.name && <FieldError message={errors.name} />}
                  </div>

                  <div className="space-y-2">
                    <Label htmlFor="monitor-description">What regression would matter?</Label>
                    <Textarea
                      id="monitor-description"
                      name="monitor[description]"
                      maxLength={500}
                      className="min-h-32"
                      placeholder="Alert when a supported answer stops including its required source citation."
                      aria-invalid={Boolean(errors.description)}
                      value={form.data.monitor.description}
                      onChange={event => form.setData("monitor.description", event.target.value)}
                    />
                    {errors.description && <FieldError message={errors.description} />}
                    <p className="text-xs text-muted-foreground">
                      Keep this concrete enough that a teammate can understand why the monitor exists.
                    </p>
                  </div>

                  <div className="flex flex-col-reverse gap-3 border-t pt-6 sm:flex-row sm:items-center sm:justify-between">
                    <Button asChild variant="ghost">
                      <Link href={`/app/${workspace.slug}/monitors`}>Cancel</Link>
                    </Button>
                    <Button id="continue-monitor-setup" type="submit" disabled={form.processing}>
                      {form.processing ? <LoaderCircle className="animate-spin" /> : <ArrowRight />}
                      Save and continue
                    </Button>
                  </div>
                </form>
              </CardContent>
            </Card>

            <aside className="space-y-4">
              <InfoCard
                icon={Database}
                title="Stored now"
                body="The name, description, and setup progress stay inside this workspace."
              />
              <InfoCard
                icon={ShieldCheck}
                title="Zero provider calls"
                body="Creating this draft does not contact OpenAI or Anthropic."
              />
            </aside>
          </div>
        </div>
      </ProductShell>
    </>
  )
}

function FieldError({ message }: { message: string }) {
  return <p className="text-sm text-destructive">{message}</p>
}

function InfoCard({
  body,
  icon: Icon,
  title,
}: {
  body: string
  icon: typeof Database
  title: string
}) {
  return (
    <Card>
      <CardContent className="p-5">
        <Icon className="size-5 text-primary" />
        <p className="mt-3 text-sm font-medium">{title}</p>
        <p className="mt-1 text-sm leading-6 text-muted-foreground">{body}</p>
      </CardContent>
    </Card>
  )
}
