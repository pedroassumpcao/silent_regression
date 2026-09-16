import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { BaselineView, type BaselineProps } from "@/pages/Monitors/Baseline"

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

const preflight: BaselineProps["preflight"] = {
  ready: true,
  blockers: [],
  caseCount: 1,
  cases: [{ id: "case-id", key: "supported-answer", name: "Supported answer" }],
  samplesPerCase: 1,
  maximumSamples: 5,
  retryLimit: 1,
  plannedCallCount: 1,
  maximumCallCount: 2,
  callCap: 200,
  remainingCallCapacity: 198,
  maxOutputTokensPerCall: 256,
  maximumOutputTokens: 512,
  previewFingerprint: "a".repeat(64),
  provider: "openai",
  requestedModel: "gpt-5.6-luna",
  credential: {
    id: "credential-id",
    label: "Production key",
    secretSuffix: "test",
    status: "valid",
    modelAccessVerified: true,
  },
}

const observation = {
  id: "observation-id",
  caseKey: "supported-answer",
  caseName: "Supported answer",
  sampleIndex: 0,
  status: "succeeded" as const,
  completionState: "complete" as const,
  requestedModel: "gpt-5.6-luna",
  returnedModel: "gpt-5.6-luna",
  outputText: "approved",
  failureCategory: null,
  failureMessage: null,
  providerMetadata: {},
  inputTokens: 10,
  outputTokens: 1,
  latencyMs: 42,
  attemptCount: 1,
  evaluation: {
    status: "pass" as const,
    error: null,
    ruleResults: [
      {
        ruleId: "allowed_label",
        ruleType: "classification",
        status: "pass" as const,
        code: "allowed_classification",
        explanation: "The normalized output matches an allowed label.",
        evidence: {},
      },
    ],
  },
}

const snapshot: NonNullable<BaselineProps["snapshot"]> = {
  id: "snapshot-id",
  status: "pending",
  approvalMode: null,
  approvalRationale: null,
  authorizedAt: "2026-09-15T18:00:00Z",
  approvedAt: null,
  rejectedAt: null,
  provider: "openai",
  requestedModel: "gpt-5.6-luna",
  samplesPerCase: 1,
  retryLimit: 1,
  plannedCallCount: 1,
  maximumCallCount: 2,
  previewFingerprint: "a".repeat(64),
  memberCount: 0,
  run: {
    id: "run-id",
    status: "succeeded",
    startedAt: "2026-09-15T18:00:01Z",
    completedAt: "2026-09-15T18:00:02Z",
    actualCallCount: 1,
    observations: [observation],
  },
}

const health: NonNullable<BaselineProps["health"]> = {
  terminal: true,
  runStatus: "succeeded",
  plannedCallCount: 1,
  maximumCallCount: 2,
  actualCallCount: 1,
  observationCount: 1,
  missingObservationCount: 0,
  statusCounts: { succeeded: 1 },
  completionCounts: { complete: 1 },
  evaluationCounts: { pass: 1 },
  deterministicFailureCount: 0,
  modelMismatchCount: 0,
  inputTokens: 10,
  outputTokens: 1,
  latencyMs: 42,
  operationalBlockers: [],
  normalApprovable: true,
  exceptionalApprovable: false,
}

const baseProps: BaselineProps = {
  auth,
  authorizationKey: "33333333-3333-4333-8333-333333333333",
  canDecide: true,
  compatibility: { compatible: true, mismatches: [] },
  health: null,
  monitor: {
    id: "monitor-id",
    name: "Routing guard",
    description: "Keep routing labels finite.",
    state: "ready",
    version: 1,
  },
  polling: false,
  preflight,
  releaseStage: "Private alpha",
  snapshot: null,
}

describe("BaselineView", () => {
  it("makes the first paid-call boundary and exact maximum visible", () => {
    render(<BaselineView {...baseProps} errors={{}} flash={{}} />)

    expect(screen.getByRole("heading", { level: 1, name: "Capture the reference you will monitor" })).toBeInTheDocument()
    expect(screen.getByText("Planned calls")).toBeInTheDocument()
    expect(screen.getByText("Output-token ceiling")).toBeInTheDocument()
    expect(screen.getByText("512")).toBeInTheDocument()
    expect(screen.getByText("Exact model access verified")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Authorize up to 2 calls" })).toBeEnabled()
    expect(screen.getByText(/does not approve the resulting outputs/i)).toBeInTheDocument()
  })

  it("keeps provider spend owner-only while members can inspect the preview", () => {
    render(
      <BaselineView
        {...baseProps}
        auth={{ ...auth, membership: { id: "member-id", role: "member" } }}
        canDecide={false}
        errors={{}}
        flash={{}}
      />,
    )

    expect(screen.getByText("Supported answer")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Authorize up to 2 calls" })).toBeDisabled()
    expect(screen.getByText(/workspace owner must verify model access and authorize provider spend/i)).toBeInTheDocument()
  })

  it("shows every output, model, usage fact, and deterministic judgment before approval", () => {
    render(
      <BaselineView
        {...baseProps}
        errors={{}}
        flash={{}}
        health={health}
        snapshot={snapshot}
      />,
    )

    expect(screen.getByRole("heading", { name: "Provider evidence and deterministic results" })).toBeInTheDocument()
    expect(screen.getByText("approved")).toBeInTheDocument()
    expect(screen.getByText("allowed_label")).toBeInTheDocument()
    expect(screen.getByText("The normalized output matches an allowed label.")).toBeInTheDocument()
    expect(screen.getByText("10 in · 1 out")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Approve and seal baseline" })).toBeEnabled()
  })

  it("separates model anomalies from quality and blocks exceptional approval", () => {
    const mismatchObservation = {
      ...observation,
      returnedModel: "unexpected-model",
    }

    render(
      <BaselineView
        {...baseProps}
        errors={{}}
        flash={{}}
        health={{
          ...health,
          modelMismatchCount: 1,
          operationalBlockers: [{ code: "returned_model_mismatch", message: "The returned model must match." }],
          normalApprovable: false,
        }}
        snapshot={{ ...snapshot, run: { ...snapshot.run, observations: [mismatchObservation] } }}
      />,
    )

    expect(screen.getByText("Returned-model mismatch")).toBeInTheDocument()
    expect(screen.getByText(/operational evidence blocks approval/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Approve and seal baseline" })).toBeDisabled()
    expect(screen.queryByRole("button", { name: "Approve with recorded exception" })).not.toBeInTheDocument()
  })

  it("shows bounded provider diagnostics for an operational failure", () => {
    const failedObservation = {
      ...observation,
      status: "failed" as const,
      completionState: null,
      outputText: null,
      failureCategory: "invalid_request",
      failureMessage: "The provider rejected the completion request.",
      providerMetadata: {
        status: 400,
        provider_code: "unsupported_value",
        provider_param: "temperature",
      },
      evaluation: null,
    }

    render(
      <BaselineView
        {...baseProps}
        errors={{}}
        flash={{}}
        health={{
          ...health,
          runStatus: "failed",
          statusCounts: { failed: 1 },
          completionCounts: {},
          evaluationCounts: {},
          operationalBlockers: [{ code: "provider_failure", message: "The provider request failed." }],
          normalApprovable: false,
        }}
        snapshot={{ ...snapshot, run: { ...snapshot.run, status: "failed", observations: [failedObservation] } }}
      />,
    )

    expect(screen.getByText("Provider outcome: invalid request")).toBeInTheDocument()
    expect(screen.getByText("The provider rejected the completion request.")).toBeInTheDocument()
    expect(screen.getByText("unsupported_value")).toBeInTheDocument()
    expect(screen.getByText("temperature")).toBeInTheDocument()
  })

  it("records a rationale only for deterministic exceptional acceptance", () => {
    render(
      <BaselineView
        {...baseProps}
        errors={{ approvalRationale: "should be at least 20 character(s)" }}
        flash={{}}
        health={{
          ...health,
          deterministicFailureCount: 1,
          evaluationCounts: { fail: 1 },
          normalApprovable: false,
          exceptionalApprovable: true,
        }}
        snapshot={{
          ...snapshot,
          run: {
            ...snapshot.run,
            observations: [
              {
                ...observation,
                outputText: "maybe",
                evaluation: { ...observation.evaluation!, status: "fail", ruleResults: [{ ...observation.evaluation!.ruleResults[0], status: "fail" }] },
              },
            ],
          },
        }}
      />,
    )

    expect(screen.getByLabelText("Exceptional approval rationale")).toBeInTheDocument()
    expect(screen.getByText("should be at least 20 character(s)")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Approve with recorded exception" })).toBeEnabled()
    expect(screen.getByRole("button", { name: "Approve and seal baseline" })).toBeDisabled()
  })
})
