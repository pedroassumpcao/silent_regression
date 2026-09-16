import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { AlertsView } from "@/pages/Alerts/Index"
import { alert } from "@/test/fixtures/results"

const auth = {
  user: { id: "member-id", email: "member@acme.example" },
  workspace: { id: "workspace-id", name: "Acme AI", slug: "acme-ai" },
  membership: { id: "membership-id", role: "member" as const },
  workspaces: [{ id: "workspace-id", name: "Acme AI", slug: "acme-ai", role: "member" as const, current: true }],
}

describe("AlertsView", () => {
  it("presents the workspace action queue without granting member resolution", () => {
    render(<AlertsView alerts={[alert]} auth={auth} canResolve={false} releaseStage="Private alpha" />)

    expect(screen.getByRole("heading", { name: "Alerts tied to immutable run evidence" })).toBeInTheDocument()
    expect(screen.getByText("Member acknowledgement access")).toBeInTheDocument()
    expect(screen.getByText("Contract failure")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /inspect evidence/i })).toHaveAttribute("href", "/app/acme-ai/monitors/monitor-id/runs/run-id")
  })

  it("has a clear first-run empty state", () => {
    render(<AlertsView alerts={[]} auth={auth} canResolve={false} releaseStage="Private alpha" />)

    expect(screen.getByText("No alerts have been opened")).toBeInTheDocument()
    expect(screen.getByText(/terminal state/i)).toBeInTheDocument()
  })
})
