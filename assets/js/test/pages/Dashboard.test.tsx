import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { DashboardView } from "@/pages/Dashboard"

describe("DashboardView", () => {
  it("renders the private-alpha foundation state without exposing unfinished actions", () => {
    render(
      <DashboardView
        releaseStage="Private alpha"
        foundationStatus="Ready for product work"
      />,
    )

    expect(screen.getByRole("heading", { level: 1 })).toBeInTheDocument()
    expect(screen.getByText("Ready for product work")).toBeInTheDocument()
    expect(screen.getByRole("progressbar", { name: "Foundation progress" })).toHaveAttribute(
      "aria-valuenow",
      "100",
    )
    expect(screen.getByRole("button", { name: "Create monitor" })).toBeDisabled()
    expect(screen.getByText("No monitors yet")).toBeInTheDocument()
  })
})
