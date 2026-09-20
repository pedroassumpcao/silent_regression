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
  authenticationRecovery: {
    required: false,
    status: null,
    trippedAt: null,
    epoch: null,
    authorizedAt: null,
    credentialValidatedAt: null,
    captureRunId: null,
    probeStatus: null,
    failureCategory: null,
    validationCallCount: 0,
    maximumCallCount: 0,
    retryLimit: 0,
  },
  canManage: true,
  coverage: {
    status: "manual",
    capacityReason: null,
    retryAt: null,
    intendedAt: null,
    interruptedAt: null,
    lastSuccessfulAt: null,
    overdue: false,
    overdueSince: null,
  },
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
    perRunCallLimit: 200,
    workspaceCallLimit: 200,
    workspaceCommittedCallsToday: 2,
    workspaceRemainingCallsToday: 198,
    workspaceRunLimit: 20,
    workspaceRunsToday: 1,
    workspaceRemainingRunsToday: 19,
    resetsAt: "2026-09-17T00:00:00Z",
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
    expect(screen.getByRole("button", { name: "Revise configuration" })).toBeDisabled()
    expect(screen.getByText("Maximum reserved calls")).toBeInTheDocument()
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

    expect(screen.getByRole("progressbar", { name: "Workspace authorized-run envelope" })).toHaveAttribute("aria-valuenow", "5")
    expect(screen.getByRole("button", { name: "Revise configuration" })).toBeEnabled()
    await user.click(screen.getByRole("button", { name: "Run now" }))

    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Authorize this bounded provider run?" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Authorize up to 2 calls" })).toBeEnabled()
    expect(screen.getAllByText("Maximum reserved calls").length).toBeGreaterThan(0)
    expect(screen.getByText(/currency estimate unavailable/i)).toBeInTheDocument()
    expect(screen.getByText(/19 of 20 runs and 198 of 200 calls remain/i)).toBeInTheDocument()
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

  it("shows overdue capacity recovery without offering a cap bypass", () => {
    render(
      <OperationsView
        {...baseProps}
        coverage={{
          status: "waiting_capacity",
          capacityReason: "workspace_call_limit",
          retryAt: "2026-09-18T00:00:00Z",
          intendedAt: "2026-09-17T15:00:00Z",
          interruptedAt: "2026-09-17T15:00:10Z",
          lastSuccessfulAt: "2026-09-16T15:01:00Z",
          overdue: true,
          overdueSince: "2026-09-17T15:00:00Z",
        }}
        flash={{}}
        monitor={{
          ...baseProps.monitor,
          state: "active",
          cadence: "daily",
          nextRunAt: "2026-09-18T00:00:00Z",
        }}
      />,
    )

    expect(screen.getByRole("heading", { name: "Monitoring is waiting for temporary capacity" })).toBeInTheDocument()
    expect(screen.getAllByText(/daily workspace call limit was reached/i)).toHaveLength(2)
    expect(screen.getByText("Waiting for capacity")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Run now" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Save cadence" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Pause" })).toBeEnabled()
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

  it("blocks resume until an owner reviews the exact recovery call envelope", async () => {
    const user = userEvent.setup()

    render(
      <OperationsView
        {...baseProps}
        authenticationRecovery={{
          ...baseProps.authenticationRecovery,
          required: true,
          status: "ready",
          trippedAt: "2026-09-20T15:00:00Z",
          validationCallCount: 1,
          maximumCallCount: 1,
        }}
        flash={{}}
        monitor={{
          ...baseProps.monitor,
          state: "paused",
          cadence: "daily",
          pauseReason: "repeated_authentication_failures",
        }}
      />,
    )

    expect(screen.getByRole("heading", { name: "Authentication recovery required" })).toBeInTheDocument()
    expect(screen.getByText("1 metadata request")).toBeInTheDocument()
    expect(screen.getByText("1 call maximum")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Resume monitor" })).toBeDisabled()

    await user.click(screen.getByRole("button", { name: "Start recovery" }))

    expect(screen.getByRole("heading", { name: "Authorize bounded authentication recovery?" })).toBeInTheDocument()
    expect(screen.getByText(/one content-free request/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Validate and run one probe" })).toBeEnabled()
  })

  it("shows recovery progress to members without granting authorization", () => {
    render(
      <OperationsView
        {...baseProps}
        auth={{ ...auth, membership: { id: "member-id", role: "member" } }}
        authenticationRecovery={{
          ...baseProps.authenticationRecovery,
          required: true,
          status: "failed",
          trippedAt: "2026-09-20T15:00:00Z",
          failureCategory: "authentication",
          validationCallCount: 1,
          maximumCallCount: 1,
        }}
        canManage={false}
        flash={{}}
        monitor={{
          ...baseProps.monitor,
          state: "paused",
          cadence: "daily",
          pauseReason: "repeated_authentication_failures",
        }}
      />,
    )

    expect(screen.getByRole("heading", { name: "Authentication recovery probe failed" })).toBeInTheDocument()
    expect(screen.getByText(/ended with authentication/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Retry recovery" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Resume monitor" })).toBeDisabled()
  })

  it("unlocks only explicit resume after a successful probe", () => {
    render(
      <OperationsView
        {...baseProps}
        authenticationRecovery={{
          ...baseProps.authenticationRecovery,
          status: "succeeded",
          trippedAt: "2026-09-20T15:00:00Z",
          epoch: 1,
          authorizedAt: "2026-09-20T15:02:00Z",
          credentialValidatedAt: "2026-09-20T15:02:00Z",
          captureRunId: "recovery-run-id",
          probeStatus: "succeeded",
          validationCallCount: 1,
          maximumCallCount: 1,
        }}
        flash={{}}
        monitor={{
          ...baseProps.monitor,
          state: "paused",
          cadence: "daily",
          pauseReason: "repeated_authentication_failures",
        }}
      />,
    )

    expect(screen.getByRole("heading", { name: "Authentication recovery succeeded" })).toBeInTheDocument()
    expect(screen.getByText(/monitoring has not restarted/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Resume monitor" })).toBeEnabled()
  })
})
