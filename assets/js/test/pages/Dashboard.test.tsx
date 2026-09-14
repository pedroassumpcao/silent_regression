import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { DashboardView } from "@/pages/Dashboard"

describe("DashboardView", () => {
  it("renders the private-alpha foundation state without exposing unfinished actions", () => {
    render(
      <DashboardView
        releaseStage="Private alpha"
        foundationStatus="Workspace access is isolated"
        workspace={{ name: "Acme AI", slug: "acme-ai" }}
        auth={{
          user: { id: "user-id", email: "owner@acme.example" },
          workspace: { id: "workspace-id", name: "Acme AI", slug: "acme-ai" },
          membership: { id: "membership-id", role: "owner" },
        }}
      />,
    )

    expect(screen.getByRole("heading", { level: 1 })).toBeInTheDocument()
    expect(screen.getByText("Workspace access is isolated")).toBeInTheDocument()
    expect(screen.getByRole("progressbar", { name: "Foundation progress" })).toHaveAttribute(
      "aria-valuenow",
      "100",
    )
    expect(screen.getByRole("button", { name: "Create monitor" })).toBeDisabled()
    expect(screen.getByText("No monitors yet")).toBeInTheDocument()
  })
})
