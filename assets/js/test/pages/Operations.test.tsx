import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"

import { OperationsView, type OperationsProps } from "@/pages/Monitors/Operations"

const auth = {
  user: { id: "owner-id", email: "owner@acme.example" },
  workspace: { id: "workspace-id", name: "Acme AI", slug: "acme-ai" },
  membership: { id: "membership-id", role: "owner" as const },
  workspaces: [
    {
      id: "workspace-id",
      name: "Acme AI",
      slug: "acme-ai",
      role: "owner" as const,
      current: true,
    },
  ],
}

const baseProps: OperationsProps = {
  auth,
  approvedBaseline: true,
  canManage: true,
  lastRun: null,
  monitor: {
    id: "monitor-id",
    name: "Billing answer guard",
    description: "Keep plan answers deterministic.",
    state: "baseline_pending",
    cadence: "manual",
    nextRunAt: null,
    lastScheduledAt: null,
    scheduleUpdatedAt: null,
    scheduleUpdatedBy: null,
    pauseReason: null,
    provider: "openai",
    requestedModel: "gpt-5.6-luna",
    version: 1,
  },
  releaseStage: "Private alpha",
  unresolvedAlerts: 0,
  spend: {
    caseCount: 1,
    maximumCallCount: 2,
    workspaceCallLimit: 200,
    workspaceCommittedCallsToday: 2,
    workspaceRemainingCallsToday: 198,
  },
}

describe("OperationsView", () => {
  it("makes activation cadence and provider-call ownership explicit", () => {
    render(<OperationsView {...baseProps} flash={{}} />)

    expect(screen.getByRole("heading", { name: "Operate the monitor without hidden spend" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /manual/i })).toHaveAttribute("aria-pressed", "true")
    expect(screen.getByRole("button", { name: /daily/i })).toBeEnabled()
    expect(screen.getByRole("button", { name: "Activate monitor" })).toBeEnabled()
    expect(screen.getByRole("button", { name: "Run now" })).toBeDisabled()
    expect(screen.getByText(/only owners can authorize schedule changes and provider spend/i)).toBeInTheDocument()
  })

  it("shows the exact on-demand call ceiling before an active owner can authorize", async () => {
    const user = userEvent.setup()

    render(
      <OperationsView
        {...baseProps}
        flash={{}}
        monitor={{ ...baseProps.monitor, state: "active", cadence: "daily", nextRunAt: "2026-09-17T15:00:00Z" }}
      />,
    )

    await user.click(screen.getByRole("button", { name: "Run now" }))

    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Authorize this bounded provider run?" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Authorize up to 2 calls" })).toBeEnabled()
    expect(screen.getByText(/198 of 200 authorized calls remain/i)).toBeInTheDocument()
  })

  it("keeps members read-only while preserving operational visibility", () => {
    render(
      <OperationsView
        {...baseProps}
        auth={{ ...auth, membership: { id: "member-id", role: "member" } }}
        canManage={false}
        flash={{}}
        monitor={{ ...baseProps.monitor, state: "active", cadence: "weekly", nextRunAt: "2026-09-23T15:00:00Z" }}
      />,
    )

    expect(screen.getAllByText("Every 7 days").length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: "Save cadence" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Pause" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Run now" })).toBeDisabled()
    expect(screen.getByText(/you can inspect operations; a workspace owner controls spend/i)).toBeInTheDocument()
  })

  it("explains automatic pause causes before offering resume", () => {
    render(
      <OperationsView
        {...baseProps}
        flash={{}}
        monitor={{
          ...baseProps.monitor,
          state: "paused",
          cadence: "daily",
          pauseReason: "credential_unavailable",
        }}
      />,
    )

    expect(screen.getByText("Provider calls are paused")).toBeInTheDocument()
    expect(screen.getAllByText(/exact provider credential is unavailable/i).length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: "Resume monitor" })).toBeEnabled()
  })
})
