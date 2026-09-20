import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { DashboardView } from "@/pages/Dashboard"

const auth = {
  user: { id: "user-id", email: "owner@acme.example" },
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

describe("DashboardView", () => {
  it("shows the derived activation path without presenting stored checklist state", () => {
    render(
      <DashboardView
        activation={{
          completedCount: 2,
          totalCount: 6,
          percent: 33,
          complete: false,
          monitorId: "monitor-id",
          monitorName: "Citation guard",
          steps: [
            { key: "credential", label: "Connect a provider credential", complete: true, href: "/app/acme-ai/credentials" },
            { key: "workflow", label: "Define the workflow", complete: true, href: "/app/acme-ai/monitors/monitor-id/setup" },
            { key: "cases", label: "Add representative cases", complete: false, href: "/app/acme-ai/monitors/monitor-id/setup/cases" },
            { key: "contract", label: "Approve the deterministic contract", complete: false, href: "/app/acme-ai/monitors/monitor-id/contract" },
            { key: "baseline", label: "Approve the baseline", complete: false, href: "/app/acme-ai/monitors/monitor-id/baseline" },
            { key: "schedule", label: "Activate monitoring", complete: false, href: "/app/acme-ai/monitors/monitor-id/operations" },
          ],
        }}
        releaseStage="Private alpha"
        currentSection="overview"
        monitors={[]}
        workspace={{ name: "Acme AI", slug: "acme-ai" }}
        auth={auth}
      />,
    )

    expect(screen.getByRole("progressbar", { name: "Private-alpha activation progress" })).toHaveAttribute(
      "aria-valuenow",
      "33",
    )
    expect(screen.getByText("Next for Citation guard: Add representative cases")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /continue activation/i })).toHaveAttribute(
      "href",
      "/app/acme-ai/monitors/monitor-id/setup/cases",
    )
  })

  it("gives an empty workspace one clear path into monitor setup", () => {
    render(
      <DashboardView
        releaseStage="Private alpha"
        currentSection="overview"
        monitors={[]}
        workspace={{ name: "Acme AI", slug: "acme-ai" }}
        auth={auth}
      />,
    )

    expect(screen.getByRole("heading", { level: 1, name: "Your monitoring workspace" })).toBeInTheDocument()
    expect(screen.getByText("Start with one critical workflow")).toBeInTheDocument()

    const createLinks = screen.getAllByRole("link", { name: /create your first monitor/i })
    expect(createLinks).toHaveLength(2)
    expect(createLinks[0]).toHaveAttribute("href", "/app/acme-ai/monitors/new")
    expect(screen.getByText(/Setup does not call your provider\./)).toBeInTheDocument()
  })

  it("shows persisted progress and a resume action for draft monitors", () => {
    render(
      <DashboardView
        releaseStage="Private alpha"
        currentSection="monitors"
        monitors={[
          {
            id: "monitor-id",
            name: "Citation guard",
            description: "Keep source citations attached to supported answers.",
            state: "draft",
            setupStatus: "in_progress",
            completedSteps: 2,
            totalSteps: 4,
            progressPercent: 50,
            nextStep: "prompt",
            updatedAt: "2026-09-15T03:00:00Z",
          },
        ]}
        workspace={{ name: "Acme AI", slug: "acme-ai" }}
        auth={auth}
      />,
    )

    expect(screen.getByRole("heading", { level: 1, name: "Monitors" })).toBeInTheDocument()
    expect(screen.getByRole("progressbar", { name: "Citation guard setup progress" })).toHaveAttribute(
      "aria-valuenow",
      "50",
    )
    expect(screen.getByText("Next: Prompt and configuration")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /resume setup/i })).toHaveAttribute(
      "href",
      "/app/acme-ai/monitors/monitor-id/setup",
    )
  })

  it("takes a completed setup directly into contract authoring", () => {
    render(
      <DashboardView
        releaseStage="Private alpha"
        currentSection="monitors"
        monitors={[
          {
            id: "monitor-id",
            name: "Citation guard",
            description: "Keep source citations attached to supported answers.",
            state: "draft",
            setupStatus: "completed",
            completedSteps: 4,
            totalSteps: 4,
            progressPercent: 100,
            nextStep: "review",
            updatedAt: "2026-09-15T03:00:00Z",
          },
        ]}
        workspace={{ name: "Acme AI", slug: "acme-ai" }}
        auth={auth}
      />,
    )

    expect(screen.getByRole("link", { name: /define contract/i })).toHaveAttribute(
      "href",
      "/app/acme-ai/monitors/monitor-id/contract",
    )
  })

  it("takes a baseline-pending monitor back to durable capture review", () => {
    render(
      <DashboardView
        releaseStage="Private alpha"
        currentSection="monitors"
        monitors={[
          {
            id: "monitor-id",
            name: "Citation guard",
            description: "Keep source citations attached to supported answers.",
            state: "baseline_pending",
            setupStatus: "completed",
            completedSteps: 4,
            totalSteps: 4,
            progressPercent: 100,
            nextStep: "review",
            updatedAt: "2026-09-15T03:00:00Z",
          },
        ]}
        workspace={{ name: "Acme AI", slug: "acme-ai" }}
        auth={auth}
      />,
    )

    expect(screen.getByText("Reviewed reference capture and approval")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /review reference/i })).toHaveAttribute(
      "href",
      "/app/acme-ai/monitors/monitor-id/baseline",
    )
  })

  it("takes an approved baseline to activation and active monitors to operations", () => {
    render(
      <DashboardView
        releaseStage="Private alpha"
        currentSection="monitors"
        monitors={[
          {
            id: "monitor-id",
            name: "Citation guard",
            description: "Keep source citations attached to supported answers.",
            state: "baseline_pending",
            readyToActivate: true,
            setupStatus: "completed",
            completedSteps: 4,
            totalSteps: 4,
            progressPercent: 100,
            nextStep: "review",
            updatedAt: "2026-09-15T03:00:00Z",
          },
        ]}
        workspace={{ name: "Acme AI", slug: "acme-ai" }}
        auth={auth}
      />,
    )

    expect(screen.getByText("Ready to activate")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /activate monitor/i })).toHaveAttribute(
      "href",
      "/app/acme-ai/monitors/monitor-id/operations",
    )
  })

  it("links active monitor cards directly to formal results", () => {
    render(
      <DashboardView
        releaseStage="Private alpha"
        currentSection="monitors"
        monitors={[
          {
            id: "monitor-id",
            name: "Citation guard",
            description: "Keep source citations attached to supported answers.",
            state: "active",
            setupStatus: "completed",
            completedSteps: 4,
            totalSteps: 4,
            progressPercent: 100,
            nextStep: "review",
            updatedAt: "2026-09-15T03:00:00Z",
          },
        ]}
        workspace={{ name: "Acme AI", slug: "acme-ai" }}
        auth={auth}
      />,
    )

    expect(screen.getByRole("link", { name: "Results" })).toHaveAttribute(
      "href",
      "/app/acme-ai/monitors/monitor-id/results",
    )
    expect(screen.getByRole("link", { name: /manage monitor/i })).toHaveAttribute(
      "href",
      "/app/acme-ai/monitors/monitor-id/operations",
    )
  })
})
