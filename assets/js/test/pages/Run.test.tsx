import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"

import { RunView, type RunProps } from "@/pages/Monitors/Run"
import { alert, run } from "@/test/fixtures/results"

const auth = {
  user: { id: "owner-id", email: "owner@acme.example" },
  workspace: { id: "workspace-id", name: "Acme AI", slug: "acme-ai" },
  membership: { id: "membership-id", role: "owner" as const },
  workspaces: [{ id: "workspace-id", name: "Acme AI", slug: "acme-ai", role: "owner" as const, current: true }],
}

const maliciousOutput = '<img src=x onerror="window.__unsafe = true">'

const props: RunProps = {
  auth,
  canResolve: true,
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
  result: {
    summary: run,
    identityKey: "run-key",
    samplesPerCase: 1,
    retryLimit: 1,
    provenance: {
      compatible: true,
      mismatches: [],
      baseline: {
        id: "baseline-id",
        status: "approved",
        approvalMode: "normal",
        approvedAt: "2026-09-15T18:00:00Z",
        provider: "openai",
        requestedModel: "gpt-5.6-luna",
        monitorVersionId: "monitor-version-id",
        contractVersionId: "contract-version-id",
        providerCredentialId: "credential-id",
        monitorFingerprint: "m".repeat(64),
        caseSetFingerprint: "c".repeat(64),
        contractFingerprint: "r".repeat(64),
        contractSemanticsFingerprint: "s".repeat(64),
        evaluatorEngineVersion: "1",
      },
      current: {
        id: "run-id",
        provider: "openai",
        requestedModel: "gpt-5.6-luna",
        monitorVersionId: "monitor-version-id",
        contractVersionId: "contract-version-id",
        providerCredentialId: "credential-id",
        monitorFingerprint: "m".repeat(64),
        caseSetFingerprint: "c".repeat(64),
        contractFingerprint: "r".repeat(64),
        contractSemanticsFingerprint: "s".repeat(64),
        evaluatorEngineVersion: "1",
      },
    },
    configuration: {
      monitorVersion: 1,
      systemPrompt: { text: "Be concise.", truncated: false, originalBytes: 11 },
      userPromptTemplate: { text: "{{question}}", truncated: false, originalBytes: 12 },
      responseFormat: {},
      generationConfig: { temperature: 0 },
    },
    alertPolicy: {
      latencyMultiplier: 3,
      latencyMinimumDeltaMs: 2000,
      usageMultiplier: 2,
      usageMinimumDeltaTokens: 100,
    },
    alerts: [alert],
    reviews: [],
    reviewSummary: {
      currentCount: 0,
      classificationCounts: {},
      actionCounts: {},
      changedJudgmentCount: 0,
      supersededCount: 0,
    },
    observations: [{
      id: "observation-id",
      sampleIndex: 0,
      status: "succeeded",
      completionState: "complete",
      requestedModel: "gpt-5.6-luna",
      returnedModel: "gpt-5.6-luna",
      finishReason: "stop",
      inputTokens: 12,
      outputTokens: 2,
      latencyMs: 88,
      providerRequestId: "provider-request-id",
      failureCategory: null,
      failureMessage: null,
      providerMetadata: { apiVersion: "v1" },
      capturedAt: "2026-09-16T18:00:00Z",
      terminalAt: "2026-09-16T18:00:00Z",
      case: {
        id: "case-id",
        key: "billing-answer",
        name: "Billing answer",
        inputVariables: { question: "Can I cancel?" },
        context: { text: "Plan facts", truncated: false, originalBytes: 10 },
        fingerprint: "case-fingerprint",
        expectationSchemaVersion: "no_case_expectation",
        expectationFingerprint: "e".repeat(64),
      },
      output: { text: maliciousOutput, truncated: false, originalBytes: maliciousOutput.length },
      attempts: [{
        id: "attempt-id",
        attemptNumber: 1,
        status: "succeeded",
        requestMode: "provider_native_v1",
        requestSchemaVersion: 1,
        requestFingerprint: "q".repeat(64),
        providerRequestId: "provider-request-id",
        retryable: null,
        failureCategory: null,
        failureMessage: null,
        latencyMs: 88,
        startedAt: "2026-09-16T17:59:59Z",
        finishedAt: "2026-09-16T18:00:00Z",
      }],
      evaluations: [{
        id: "evaluation-id",
        status: "fail",
        contractStatus: "fail",
        rootRuleId: "contract",
        contractFingerprint: "r".repeat(64),
        caseExpectationSchemaVersion: "no_case_expectation",
        caseExpectationFingerprint: "e".repeat(64),
        caseExpectationStatus: "not_configured",
        caseExpectationResults: { checks: [] },
        caseExpectationError: null,
        evaluatorEngineVersion: "1",
        evaluatedAt: "2026-09-16T18:00:00Z",
        error: null,
        ruleResults: [{
          id: "rule-result-id",
          position: 0,
          ruleId: "allowed_label",
          ruleType: "classification",
          severity: "critical",
          status: "fail",
          code: "unexpected_classification",
          explanation: "The output did not match an allowed label.",
          evidence: { normalizedOutput: maliciousOutput },
          childRuleIds: [],
        }],
      }],
    }],
  },
}

describe("RunView", () => {
  it("renders captured model content as inert text with attributable rule evidence", () => {
    const { container } = render(<RunView {...props} flash={{}} />)

    expect(screen.getByRole("heading", { name: "Run evidence, without a hidden score" })).toBeInTheDocument()
    expect(screen.getByText(maliciousOutput)).toBeInTheDocument()
    expect(container.querySelector("#observation-observation-id img")).not.toBeInTheDocument()
    expect(screen.getByText("The output did not match an allowed label.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /redacted diagnostic/i })).toHaveAttribute("href", "/app/acme-ai/monitors/monitor-id/runs/run-id/diagnostic")
  })

  it("separates a passing shared contract from a failing case expectation", () => {
    const observation = props.result.observations[0]
    const evaluation = observation.evaluations[0]

    render(<RunView {...props} flash={{}} result={{
      ...props.result,
      summary: {
        ...props.result.summary,
        evaluationCounts: { fail: 1 },
        contractEvaluationCounts: { pass: 1 },
        caseExpectationCounts: { fail: 1 },
      },
      alerts: [],
      observations: [{
        ...observation,
        case: { ...observation.case, expectationSchemaVersion: "case_expectation_v1" },
        evaluations: [{
          ...evaluation,
          contractStatus: "pass",
          caseExpectationSchemaVersion: "case_expectation_v1",
          caseExpectationStatus: "fail",
          ruleResults: evaluation.ruleResults.map(rule => ({ ...rule, status: "pass" })),
          caseExpectationResults: {
            checks: [{
              checkId: "route",
              checkType: "label",
              status: "fail",
              code: "expected_label_mismatch",
              explanation: "The case-specific label did not match.",
              evidence: { allowedValues: ["billing"], normalizedOutput: "accounts" },
            }],
          },
        }],
      }],
    }} />)

    expect(screen.getByText("Contract: Pass")).toBeInTheDocument()
    expect(screen.getByText("Case: Fail")).toBeInTheDocument()
    expect(screen.getByText("Case mismatches")).toBeInTheDocument()
    expect(screen.getByText("The case-specific label did not match.")).toBeInTheDocument()
  })

  it("lets members acknowledge open alerts but never offers owner resolution", () => {
    render(<RunView {...props} auth={{ ...auth, membership: { id: "member-id", role: "member" } }} canResolve={false} flash={{}} />)

    expect(screen.getByRole("button", { name: "Acknowledge" })).toBeEnabled()
    expect(screen.queryByRole("button", { name: "Resolve" })).not.toBeInTheDocument()
  })

  it("opens structured review for alerts and exposes missed-regression review on observations", async () => {
    const user = userEvent.setup()
    render(<RunView {...props} flash={{}} />)

    expect(screen.getByRole("button", { name: /report missed regression/i })).toBeEnabled()
    await user.click(screen.getByRole("button", { name: /^record judgment$/i }))

    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Record structured judgment" })).toBeInTheDocument()
    expect(screen.getByText("The alert identifies a real output regression.")).toBeInTheDocument()
    expect(screen.getByLabelText(/rationale/i)).toHaveAttribute("maxlength", "2000")
  })

  it("requires a current judgment before owner resolution", () => {
    render(<RunView {...props} flash={{}} result={{
      ...props.result,
      alerts: [{ ...alert, status: "acknowledged", acknowledgedAt: "2026-09-16T18:05:00Z" }],
    }} />)

    expect(screen.getByRole("button", { name: "Resolve" })).toBeDisabled()
    expect(screen.getByText("Review required to resolve")).toBeInTheDocument()
  })

  it("shows the current append-only judgment and enables governed owner resolution", () => {
    render(<RunView {...props} flash={{}} result={{
      ...props.result,
      alerts: [{ ...alert, status: "acknowledged", acknowledgedAt: "2026-09-16T18:05:00Z" }],
      reviews: [{
        id: "review-id",
        reviewKey: "alert:alert-id",
        subjectKind: "alert",
        classification: "acceptable_variation",
        action: "contract_revision",
        rationale: { text: "The contract is too narrow.", truncated: false, originalBytes: 27 },
        reviewedAt: "2026-09-16T18:06:00Z",
        reviewedBy: "reviewer@acme.example",
        current: true,
        supersedesId: null,
        captureRunId: "run-id",
        resultAlertId: "alert-id",
        captureObservationId: null,
        captureEvaluationId: "evaluation-id",
        captureRuleResultId: null,
        contractVersionId: "contract-version-id",
        baselineSnapshotId: "baseline-id",
      }],
      reviewSummary: { currentCount: 1, classificationCounts: { acceptable_variation: 1 }, actionCounts: { contract_revision: 1 }, changedJudgmentCount: 0, supersededCount: 0 },
    }} />)

    expect(screen.getByText("The contract is too narrow.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Resolve" })).toBeEnabled()
    expect(screen.getByRole("button", { name: /start contract revision/i })).toBeEnabled()
  })

  it("blocks relative interpretation when provenance differs", () => {
    render(<RunView {...props} flash={{}} result={{ ...props.result, provenance: { ...props.result.provenance, compatible: false, mismatches: ["contract_fingerprint"] } }} />)

    expect(screen.getByText("Baseline provenance does not match this run")).toBeInTheDocument()
    expect(screen.getByText(/latency and usage findings were deliberately skipped/i)).toBeInTheDocument()
  })
})
