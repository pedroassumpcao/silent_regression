import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { AlertsView } from "@/pages/Alerts/Index"
import { IncidentView } from "@/pages/Alerts/Show"
import { alert, incident } from "@/test/fixtures/results"

const auth = {
  user: { id: "member-id", email: "member@acme.example" },
  workspace: { id: "workspace-id", name: "Acme AI", slug: "acme-ai" },
  membership: { id: "membership-id", role: "member" as const },
  workspaces: [{ id: "workspace-id", name: "Acme AI", slug: "acme-ai", role: "member" as const, current: true }],
}

describe("AlertsView", () => {
  it("presents the workspace action queue without granting member resolution", () => {
    render(<AlertsView incidents={[incident]} counts={{ open: 1 }} pagination={{ page: 1, pageSize: 20, total: 1, totalPages: 1, hasPrevious: false, hasNext: false }} auth={auth} canResolve={false} releaseStage="Private alpha" />)

    expect(screen.getByRole("heading", { name: "Incidents, with every exact occurrence attached" })).toBeInTheDocument()
    expect(screen.getByText("Member acknowledgement access")).toBeInTheDocument()
    expect(screen.getByText("Contract failure")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /review incident/i })).toHaveAttribute("href", "/app/acme-ai/incidents/incident-id")
  })

  it("has a clear first-run empty state", () => {
    render(<AlertsView incidents={[]} counts={{}} pagination={{ page: 1, pageSize: 20, total: 0, totalPages: 1, hasPrevious: false, hasNext: false }} auth={auth} canResolve={false} releaseStage="Private alpha" />)

    expect(screen.getByText("No incidents have been opened")).toBeInTheDocument()
    expect(screen.getByText(/explicit deterministic or operational finding/i)).toBeInTheDocument()
  })
})

describe("IncidentView", () => {
  it("presents immutable occurrence history and the member lifecycle boundary", () => {
    render(<IncidentView
      auth={auth}
      canResolve={false}
      releaseStage="Private alpha"
      detail={{
        incident: { ...incident, status: "acknowledged", acknowledgedAt: "2026-09-16T18:05:00Z", exceptionalReference: true },
        signatureSchemaVersion: "incident_signature_v1",
        occurrences: [{
          id: "occurrence-id",
          ordinal: 3,
          occurredAt: "2026-09-16T18:00:00Z",
          caseCount: 1,
          exceptionalReference: true,
          alert,
          run: incident.latestRun,
        }],
        pagination: { page: 1, pageSize: 25, total: 3, totalPages: 1, hasPrevious: false, hasNext: false },
      }}
      flash={{}}
    />)

    expect(screen.getByRole("heading", { name: "Deterministic contract failed" })).toBeInTheDocument()
    expect(screen.getByText("Owner resolution required")).toBeInTheDocument()
    expect(screen.getByText("Exceptional reviewed reference")).toBeInTheDocument()
    expect(screen.getByText(/does not make this later finding acceptable/i)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /inspect exact run/i })).toHaveAttribute(
      "href",
      "/app/acme-ai/monitors/monitor-id/runs/run-id",
    )
  })
})
