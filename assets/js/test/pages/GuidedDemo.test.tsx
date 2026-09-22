import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { GuidedDemoView, type GuidedDemoProps } from "@/pages/Demo/Show"

const auth = {
  user: { id: "user-id", email: "owner@acme.example" },
  workspace: { id: "workspace-id", name: "Acme AI", slug: "acme-ai" },
  membership: { id: "membership-id", role: "owner" as const },
  workspaces: [{ id: "workspace-id", name: "Acme AI", slug: "acme-ai", role: "owner" as const, current: true }],
}

const evidence = {
  observationId: "observation-id",
  output: "billing",
  contractStatus: "pass",
  contractResults: [],
  caseExpectationStatus: "pass",
  caseExpectationResults: [{ checkId: "expected_route", status: "pass", code: "expected_label_matched", explanation: "The case-specific label matched." }],
  overallStatus: "pass",
  evaluatorEngineVersion: "deterministic-v1",
  evaluatedAt: "2026-09-20T00:00:00Z",
  role: "reviewed_reference",
}

const scenario = {
  scenarioVersion: "credential-free-demo-v1",
  sealedFingerprint: "a".repeat(64),
  providerCalls: 0,
  request: { provider: "local_demo", requestedModel: "sealed-fixture-v1", body: { messages: [{ role: "user", content: "I was charged twice." }] } },
  contract: { fingerprint: "b".repeat(64), root: { id: "routing_contract", type: "all" }, explanation: "Both supported labels are allowed." },
  caseExpectation: { schemaVersion: "case_expectation_v1", fingerprint: "c".repeat(64), payload: { checks: [] }, explanation: "This case must route to billing." },
  reference: evidence,
  recurring: { ...evidence, observationId: "recurring-id", output: "technical", caseExpectationStatus: "fail", overallStatus: "fail", role: "recurring_sample", caseExpectationResults: [{ checkId: "expected_route", status: "fail", code: "expected_label_mismatch", explanation: "The case-specific label did not match." }] },
  incident: { severity: "critical", signature: "case_expectation_failure:expected_route:duplicate_charge", explanation: "The allowed output is wrong for this case." },
}

const baseProps: GuidedDemoProps = {
  auth,
  releaseStage: "Private alpha",
  scenario,
  workspace: { name: "Acme AI", slug: "acme-ai" },
  progress: {
    status: "not_started",
    scenarioVersion: "credential-free-demo-v1",
    completedSteps: [],
    completedCount: 0,
    totalCount: 4,
    currentStep: "request",
    startedAt: null,
    expectationProvenAt: null,
    completedAt: null,
    secondsToExpectation: null,
    secondsToCompletion: null,
  },
}

describe("GuidedDemoView", () => {
  it("hands off completed practice to the real Step 0 recipe chooser", () => {
    render(<GuidedDemoView {...baseProps} flash={{}} progress={{ ...baseProps.progress, status: "completed", completedSteps: ["request", "expectation", "reference", "incident"], completedCount: 4 }} />)
    expect(screen.getByRole("link", { name: "Build a real monitor" })).toHaveAttribute("href", "/app/acme-ai/setup-drafts/new")
  })

  it("offers a sealed zero-call walkthrough before credential setup", () => {
    render(<GuidedDemoView {...baseProps} flash={{}} />)

    expect(screen.getByRole("heading", { name: "See a silent regression before sharing a credential" })).toBeInTheDocument()
    expect(screen.getAllByText("0 provider calls").length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: /start credential-free demo/i })).toBeInTheDocument()
    expect(screen.getByText(/no vendor-specific eval adapter is claimed yet/i)).toBeInTheDocument()
  })

  it("teaches the difference between a shared contract and case expectation", () => {
    render(<GuidedDemoView {...baseProps} flash={{}} progress={{ ...baseProps.progress, status: "in_progress", completedSteps: ["request"], completedCount: 1, currentStep: "expectation", startedAt: "2026-09-20T00:00:00Z" }} />)

    expect(screen.getByText("A valid label is not necessarily the right label")).toBeInTheDocument()
    expect(screen.getByText("Shared contract")).toBeInTheDocument()
    expect(screen.getByText("Case-specific expectation")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /prove the case expectation/i })).toBeInTheDocument()
  })

  it("shows the valid-looking regression and durable incident outcome", () => {
    render(<GuidedDemoView {...baseProps} flash={{}} progress={{ ...baseProps.progress, status: "in_progress", completedSteps: ["request", "expectation", "reference"], completedCount: 3, currentStep: "incident", startedAt: "2026-09-20T00:00:00Z", expectationProvenAt: "2026-09-20T00:00:05Z", secondsToExpectation: 5 }} />)

    expect(screen.getByText("The output is allowed—but wrong for this case")).toBeInTheDocument()
    expect(screen.getAllByText("pass").length).toBeGreaterThan(0)
    expect(screen.getAllByText("fail").length).toBeGreaterThan(0)
    expect(screen.getByText(/case_expectation_failure:expected_route/)).toBeInTheDocument()
  })
})
