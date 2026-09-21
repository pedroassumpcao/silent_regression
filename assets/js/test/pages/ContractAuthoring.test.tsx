import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it, vi } from "vitest"
import { router } from "@inertiajs/react"

import { ContractAuthoringView, type ContractAuthoringProps } from "@/pages/Monitors/Contract"

afterEach(() => vi.restoreAllMocks())

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

const templates: ContractAuthoringProps["templates"] = [
  {
    key: "classification",
    title: "Classification or routing",
    description: "Require the output to be one approved label.",
    bestFor: "Triage and finite decisions",
    limitation: "Does not judge semantic correctness.",
    root: {
      id: "contract",
      type: "all",
      rules: [
        { id: "allowed_label", type: "classification", allowed_values: ["approved", "rejected"] },
        { id: "label_length", type: "length", unit: "words", minimum: 1, maximum: 2 },
      ],
    },
  },
]

const contract: NonNullable<ContractAuthoringProps["contract"]> = {
  id: "contract-id",
  version: 1,
  status: "draft",
  predecessorId: null,
  approvedAt: null,
  approvedByUserId: null,
  fingerprint: "a".repeat(64),
  contractFingerprint: "b".repeat(64),
  fixtureSetFingerprint: "c".repeat(64),
  proofFingerprint: null,
  proofSchemaVersion: null,
  templateKey: "classification",
  templateUsage: {
    templateKey: "classification",
    rules: [
      { suggestionId: "allowed_label", ruleId: "allowed_label", ruleType: "classification", action: "accepted" },
      { suggestionId: "label_length", ruleId: "label_length", ruleType: "length", action: "accepted" },
    ],
  },
  assistanceMode: "self_serve",
  root: templates[0].root,
}

const fixtures: ContractAuthoringProps["fixtures"] = [
  {
    id: "valid-fixture",
    name: "Known valid",
    position: 0,
    outputText: "approved",
    expectedStatus: "pass",
    expectedRuleStatuses: { contract: "pass", allowed_label: "pass", label_length: "pass" },
    expectedFailedRuleIds: [],
    fingerprint: "d".repeat(64),
    judgmentComplete: true,
    matches: true,
    actual: {
      status: "pass",
      error: null,
      ruleResults: [
        { ruleId: "allowed_label", ruleType: "classification", severity: "critical", status: "pass", code: "allowed_classification", explanation: "The normalized output matches an allowed classification label.", evidence: {}, childRuleIds: [] },
        { ruleId: "label_length", ruleType: "length", severity: "warning", status: "pass", code: "within_bounds", explanation: "The output length is within the configured bounds.", evidence: {}, childRuleIds: [] },
        { ruleId: "contract", ruleType: "all", severity: "critical", status: "pass", code: "all_children_passed", explanation: "Every rule passed.", evidence: {}, childRuleIds: ["allowed_label", "label_length"] },
      ],
    },
  },
  {
    id: "invalid-fixture",
    name: "Known invalid",
    position: 1,
    outputText: "maybe",
    expectedStatus: "fail",
    expectedRuleStatuses: { contract: "fail", allowed_label: "fail", label_length: "pass" },
    expectedFailedRuleIds: ["allowed_label"],
    fingerprint: "e".repeat(64),
    judgmentComplete: true,
    matches: true,
    actual: {
      status: "fail",
      error: null,
      ruleResults: [
        { ruleId: "allowed_label", ruleType: "classification", severity: "critical", status: "fail", code: "classification_not_allowed", explanation: "The normalized output is not an allowed classification label.", evidence: {}, childRuleIds: [] },
        { ruleId: "label_length", ruleType: "length", severity: "warning", status: "pass", code: "within_bounds", explanation: "The output length is within the configured bounds.", evidence: {}, childRuleIds: [] },
        { ruleId: "contract", ruleType: "all", severity: "critical", status: "fail", code: "child_failed", explanation: "One rule failed.", evidence: {}, childRuleIds: ["allowed_label", "label_length"] },
      ],
    },
  },
]

const baseProps: ContractAuthoringProps = {
  approvedContract: null,
  auth,
  canApprove: true,
  contract: null,
  coverage: null,
  fixtures: [],
  limits: { maxFixtures: 20, maxOutputBytes: 1_000_000 },
  monitor: {
    id: "monitor-id",
    name: "Routing guard",
    description: "Keep routing labels finite.",
    state: "draft",
    version: 1,
  },
  readiness: {
    ready: false,
    blockers: [{ code: "contract_missing", message: "Save a valid contract draft first.", fixtureId: null }],
  },
  releaseStage: "Private alpha",
  rescoreRun: null,
  rescoreSummary: null,
  revisionOrigins: [],
  templates,
}

const coverage: NonNullable<ContractAuthoringProps["coverage"]> = {
  schemaVersion: "rule_coverage_v1",
  fingerprint: "f".repeat(64),
  ready: true,
  rules: [
    {
      ruleId: "allowed_label",
      ruleType: "classification",
      ruleFingerprint: "1".repeat(64),
      severity: "critical",
      positiveFixtureIds: ["valid-fixture"],
      negativeFixtureIds: ["invalid-fixture"],
      positiveProven: true,
      negativeProven: true,
      missingBranches: [],
      blocking: false,
      waiver: null,
    },
    {
      ruleId: "label_length",
      ruleType: "length",
      ruleFingerprint: "2".repeat(64),
      severity: "warning",
      positiveFixtureIds: ["valid-fixture", "invalid-fixture"],
      negativeFixtureIds: [],
      positiveProven: true,
      negativeProven: false,
      missingBranches: ["negative"],
      blocking: false,
      waiver: null,
    },
  ],
}

const rescoreRun: NonNullable<ContractAuthoringProps["rescoreRun"]> = {
  id: "rescore-run-id",
  status: "running",
  batchSize: 50,
  totalCount: 80,
  processedCount: 50,
  passCount: 48,
  failCount: 2,
  evaluatorErrorCount: 0,
  errorCode: null,
  requestedAt: "2026-09-16T18:00:00Z",
  startedAt: "2026-09-16T18:00:01Z",
  completedAt: null,
  predecessorContractVersionId: "previous-contract-id",
}

describe("ContractAuthoringView", () => {
  it("blocks saved-rule proof and approval while visible rule edits are unsaved", async () => {
    const user = userEvent.setup()
    render(<ContractAuthoringView {...baseProps} contract={contract} coverage={coverage} fixtures={fixtures} readiness={{ ready: true, blockers: [] }} errors={{}} flash={{}} />)
    expect(screen.getByRole("button", { name: "Approve and seal contract" })).toBeEnabled()
    await user.type(screen.getByLabelText("Allowed labels"), "-changed")
    expect(screen.getByRole("button", { name: "Approve and seal contract" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Save and evaluate locally" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Delete Known valid" })).toBeDisabled()
    expect(screen.getByText("Unsaved changes — approval is paused")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save and validate rules" })).toBeEnabled()
  })

  it("blocks approval and rule changes while a new example is unsaved", async () => {
    const user = userEvent.setup()
    render(<ContractAuthoringView {...baseProps} contract={contract} coverage={coverage} fixtures={fixtures} readiness={{ ready: true, blockers: [] }} errors={{}} flash={{}} />)
    await user.type(screen.getByLabelText("Fixture name"), "New example")
    expect(screen.getByRole("button", { name: "Approve and seal contract" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Save and validate rules" })).toBeDisabled()
    await user.clear(screen.getByLabelText("Fixture name"))
    expect(screen.getByRole("button", { name: "Approve and seal contract" })).toBeEnabled()
  })

  it("does not approve a saved JSON value while its visible replacement is invalid", async () => {
    const user = userEvent.setup()
    const jsonContract: NonNullable<ContractAuthoringProps["contract"]> = {
      ...contract,
      root: { ...contract.root, rules: [{ id: "amount", type: "json_path_equals", path: "/amount", expected: 12, numeric_comparison: "strict" }] },
    }
    render(<ContractAuthoringView {...baseProps} contract={jsonContract} coverage={coverage} readiness={{ ready: true, blockers: [] }} errors={{}} flash={{}} />)
    await user.clear(screen.getByLabelText("Expected JSON value"))
    expect(screen.getByRole("button", { name: "Approve and seal contract" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Save and validate rules" })).toBeDisabled()
    await user.type(screen.getByLabelText("Expected JSON value"), "12")
    expect(screen.getByRole("button", { name: "Approve and seal contract" })).toBeEnabled()
  })

  it("cancels an edited example without treating discarded text as reviewed proof", async () => {
    const user = userEvent.setup()
    render(<ContractAuthoringView {...baseProps} contract={contract} coverage={coverage} fixtures={fixtures} readiness={{ ready: true, blockers: [] }} errors={{}} flash={{}} />)
    await user.click(screen.getAllByRole("button", { name: "Edit" })[0])
    await user.type(screen.getByLabelText("Fixture name", { selector: "#fixture-valid-fixture-name" }), " changed")
    expect(screen.getByRole("button", { name: "Approve and seal contract" })).toBeDisabled()
    await user.click(screen.getByRole("button", { name: "Cancel" }))
    expect(screen.getByRole("button", { name: "Approve and seal contract" })).toBeEnabled()
    await user.click(screen.getAllByRole("button", { name: "Edit" })[0])
    expect(screen.getByLabelText("Fixture name", { selector: "#fixture-valid-fixture-name" })).toHaveValue("Known valid")
  })

  it("sends the exact currently reviewed contract and proof identity on approval", async () => {
    const user = userEvent.setup()
    const post = vi.spyOn(router, "post").mockImplementation(() => {})
    render(<ContractAuthoringView {...baseProps} contract={contract} coverage={coverage} fixtures={fixtures} readiness={{ ready: true, blockers: [] }} errors={{}} flash={{}} />)
    await user.click(screen.getByRole("button", { name: "Approve and seal contract" }))
    expect(post).toHaveBeenCalledWith("/app/acme-ai/monitors/monitor-id/contract/approve", {
      approval: { contract_id: contract.id, fingerprint: contract.fingerprint, coverage_fingerprint: coverage.fingerprint },
    }, expect.any(Object))
  })

  it("refreshes visible rule fields when a server response brings a different saved revision", () => {
    const props = { ...baseProps, contract, coverage, fixtures, readiness: { ready: true, blockers: [] }, errors: {}, flash: {} }
    const { rerender } = render(<ContractAuthoringView {...props} />)
    rerender(<ContractAuthoringView {...props} contract={{
      ...contract, contractFingerprint: "e".repeat(64),
      root: { ...contract.root, rules: [{ id: "allowed_label", type: "classification", allowed_values: ["billing", "technical"] }] },
    }} />)
    expect(screen.getByLabelText("Allowed labels")).toHaveValue("billing\ntechnical")
    expect(screen.queryByDisplayValue("approved\nrejected")).not.toBeInTheDocument()
  })

  it("starts with workflow templates and reveals structured rule fields without raw JSON", async () => {
    const user = userEvent.setup()
    render(<ContractAuthoringView {...baseProps} errors={{}} flash={{}} />)

    expect(screen.getByRole("heading", { level: 1, name: "Define what must remain true" })).toBeInTheDocument()
    expect(screen.getByText("Local evaluation · 0 provider calls")).toBeInTheDocument()
    expect(screen.queryByLabelText("Stable rule ID")).not.toBeInTheDocument()

    await user.click(screen.getByRole("button", { name: "Use this template" }))

    expect(screen.getAllByText("Stable rule ID")).toHaveLength(2)
    expect(screen.getByDisplayValue("allowed_label")).toBeInTheDocument()
    expect(screen.getAllByLabelText("Stable rule ID")[0]).toHaveAttribute("pattern", "[a-z](?:[a-z0-9_]|-)*")
    expect(screen.getByRole("button", { name: "Advanced JSON" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save and validate rules" })).toBeEnabled()
  })

  it("shows exact expected-versus-actual rule judgments and enables owner approval", () => {
    render(
      <ContractAuthoringView
        {...baseProps}
        contract={contract}
        coverage={coverage}
        errors={{}}
        fixtures={fixtures}
        flash={{}}
        readiness={{ ready: true, blockers: [] }}
      />,
    )

    expect(screen.getAllByText("Judgment confirmed")).toHaveLength(2)
    expect(screen.getByText("The normalized output is not an allowed classification label.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Approve and seal contract" })).toBeEnabled()
    expect(screen.getByText("Your approval will be attributable to your account.")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Coverage by rule and branch" })).toBeInTheDocument()
    expect(screen.getByText("Coverage is incomplete, but warning rules report evidence without blocking approval.")).toBeInTheDocument()
  })

  it("keeps final approval owner-only while allowing a member to inspect results", () => {
    render(
      <ContractAuthoringView
        {...baseProps}
        auth={{ ...auth, membership: { id: "member-id", role: "member" } }}
        canApprove={false}
        contract={contract}
        coverage={coverage}
        errors={{}}
        fixtures={fixtures}
        flash={{}}
        readiness={{ ready: true, blockers: [] }}
      />,
    )

    expect(screen.getByRole("button", { name: "Approve and seal contract" })).toBeDisabled()
    expect(screen.getByText("A workspace owner must perform final approval.")).toBeInTheDocument()
  })

  it("renders an approved snapshot as read-only and offers an explicit successor draft", () => {
    render(
      <ContractAuthoringView
        {...baseProps}
        canApprove
        contract={{ ...contract, status: "approved", approvedAt: "2026-09-15T18:00:00Z", approvedByUserId: "owner-id", proofFingerprint: "f".repeat(64), proofSchemaVersion: "rule_coverage_v1" }}
        coverage={coverage}
        rescoreSummary={{ observationCount: 12, passCount: 10, failCount: 2, evaluatorErrorCount: 0, interpretationChanged: true, rescoredAt: "2026-09-16T18:00:00Z", predecessorContractVersionId: "previous-contract-id" }}
        errors={{}}
        fixtures={fixtures}
        flash={{}}
        readiness={{ ready: true, blockers: [] }}
      />,
    )

    expect(screen.queryByRole("button", { name: "Save and validate rules" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Create successor draft" })).toBeEnabled()
    expect(screen.getByRole("link", { name: "Preview reviewed reference capture" })).toHaveAttribute(
      "href",
      "/app/acme-ai/monitors/monitor-id/baseline",
    )
    expect(screen.getByText("Contract version 1 is sealed")).toBeInTheDocument()
    expect(screen.getByText("Historical outputs rescored before activation")).toBeInTheDocument()
    expect(screen.getByText("Semantics changed at activation")).toBeInTheDocument()
    expect(screen.queryByText("New reviewed reference required")).not.toBeInTheDocument()
  })

  it("keeps a pending candidate read-only and shows durable rescore progress", () => {
    render(
      <ContractAuthoringView
        {...baseProps}
        approvedContract={{ id: "previous-contract-id", version: 1, status: "approved", fingerprint: "9".repeat(64), approvedAt: "2026-09-15T18:00:00Z" }}
        contract={{ ...contract, version: 2, status: "pending_rescore", predecessorId: "previous-contract-id", proofFingerprint: "f".repeat(64), proofSchemaVersion: "rule_coverage_v1" }}
        coverage={coverage}
        errors={{}}
        fixtures={fixtures}
        flash={{}}
        readiness={{ ready: true, blockers: [] }}
        rescoreRun={rescoreRun}
      />,
    )

    expect(screen.getByText("Approved version 1 remains active")).toBeInTheDocument()
    expect(screen.getByText("50 of 80 stored outputs processed · batches of 50 · 0 provider calls")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Save and validate rules" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Approve and seal contract" })).not.toBeInTheDocument()
    expect(screen.getByText("Rescore in progress")).toBeInTheDocument()
  })

  it("shows safe failure and offers a retry draft without claiming activation", () => {
    render(
      <ContractAuthoringView
        {...baseProps}
        approvedContract={{ id: "previous-contract-id", version: 1, status: "approved", fingerprint: "9".repeat(64), approvedAt: "2026-09-15T18:00:00Z" }}
        contract={{ ...contract, version: 2, status: "rescore_failed", predecessorId: "previous-contract-id", proofFingerprint: "f".repeat(64), proofSchemaVersion: "rule_coverage_v1" }}
        coverage={coverage}
        errors={{}}
        fixtures={fixtures}
        flash={{}}
        readiness={{ ready: true, blockers: [] }}
        rescoreRun={{ ...rescoreRun, status: "failed", errorCode: "historical_evaluator_error", completedAt: "2026-09-16T18:05:00Z" }}
      />,
    )

    expect(screen.getByText("Candidate version 2 did not activate")).toBeInTheDocument()
    expect(screen.getByText("The predecessor stayed active; no monitor or reviewed reference was silently switched.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Create retry draft" })).toBeEnabled()
  })
})
