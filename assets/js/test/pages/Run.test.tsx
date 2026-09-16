import { render, screen } from "@testing-library/react"
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
      },
      output: { text: maliciousOutput, truncated: false, originalBytes: maliciousOutput.length },
      attempts: [{
        id: "attempt-id",
        attemptNumber: 1,
        status: "succeeded",
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
        rootRuleId: "contract",
        contractFingerprint: "r".repeat(64),
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

  it("lets members acknowledge open alerts but never offers owner resolution", () => {
    render(<RunView {...props} auth={{ ...auth, membership: { id: "member-id", role: "member" } }} canResolve={false} flash={{}} />)

    expect(screen.getByRole("button", { name: "Acknowledge" })).toBeEnabled()
    expect(screen.queryByRole("button", { name: "Resolve" })).not.toBeInTheDocument()
  })

  it("blocks relative interpretation when provenance differs", () => {
    render(<RunView {...props} flash={{}} result={{ ...props.result, provenance: { ...props.result.provenance, compatible: false, mismatches: ["contract_fingerprint"] } }} />)

    expect(screen.getByText("Baseline provenance does not match this run")).toBeInTheDocument()
    expect(screen.getByText(/latency and usage findings were deliberately skipped/i)).toBeInTheDocument()
  })
})
