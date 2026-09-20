import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { ResultsView, type ResultsProps } from "@/pages/Monitors/Results"
import { alert, run } from "@/test/fixtures/results"

const auth = {
  user: { id: "owner-id", email: "owner@acme.example" },
  workspace: { id: "workspace-id", name: "Acme AI", slug: "acme-ai" },
  membership: { id: "membership-id", role: "owner" as const },
  workspaces: [{ id: "workspace-id", name: "Acme AI", slug: "acme-ai", role: "owner" as const, current: true }],
}

const props: ResultsProps = {
  auth,
  alerts: [alert],
  canResolve: true,
  currentBaseline: {
    id: "baseline-id",
    status: "approved",
    approvalMode: "normal",
    approvedAt: "2026-09-15T18:00:00Z",
    provider: "openai",
    requestedModel: "gpt-5.6-luna",
    monitorFingerprint: "monitor-fingerprint",
    contractFingerprint: "contract-fingerprint",
  },
  monitor: {
    id: "monitor-id",
    name: "Billing answer guard",
    description: "Protect billing answers.",
    state: "active",
    cadence: "daily",
    provider: "openai",
    requestedModel: "gpt-5.6-luna",
    version: 1,
  },
  releaseStage: "Private alpha",
  runs: [run],
}

describe("ResultsView", () => {
  it("separates unresolved alerts from factual run history", () => {
    const { container } = render(<ResultsView {...props} flash={{}} />)

    expect(screen.getByRole("heading", { name: "Runs, evidence, and actionable alerts" })).toBeInTheDocument()
    expect(screen.getByText("Deterministic contract failed")).toBeInTheDocument()
    expect(screen.getAllByText("1 critical").length).toBeGreaterThan(0)
    expect(screen.getByRole("columnheader", { name: "Shared contract" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Case expectation" })).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: /inspect evidence/i })).toEqual(
      expect.arrayContaining([expect.objectContaining({ href: expect.stringContaining("/app/acme-ai/monitors/monitor-id/runs/run-id") })]),
    )
    expect(container.querySelector("#run-history .hidden.md\\:block")).toBeInTheDocument()
    expect(container.querySelector("#run-history .md\\:hidden")).toBeInTheDocument()
  })

  it("makes missing baseline compatibility an explicit blocking state", () => {
    render(<ResultsView {...props} currentBaseline={null} flash={{}} />)

    expect(screen.getByText("No current approved baseline")).toBeInTheDocument()
    expect(screen.getByText("Unavailable")).toBeInTheDocument()
  })
})
