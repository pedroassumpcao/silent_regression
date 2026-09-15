import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"

import { ContractAuthoringView, type ContractAuthoringProps } from "@/pages/Monitors/Contract"

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
        { ruleId: "allowed_label", ruleType: "classification", status: "pass", code: "allowed_classification", explanation: "The normalized output matches an allowed classification label.", evidence: {}, childRuleIds: [] },
        { ruleId: "label_length", ruleType: "length", status: "pass", code: "within_bounds", explanation: "The output length is within the configured bounds.", evidence: {}, childRuleIds: [] },
        { ruleId: "contract", ruleType: "all", status: "pass", code: "all_children_passed", explanation: "Every rule passed.", evidence: {}, childRuleIds: ["allowed_label", "label_length"] },
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
        { ruleId: "allowed_label", ruleType: "classification", status: "fail", code: "classification_not_allowed", explanation: "The normalized output is not an allowed classification label.", evidence: {}, childRuleIds: [] },
        { ruleId: "label_length", ruleType: "length", status: "pass", code: "within_bounds", explanation: "The output length is within the configured bounds.", evidence: {}, childRuleIds: [] },
        { ruleId: "contract", ruleType: "all", status: "fail", code: "child_failed", explanation: "One rule failed.", evidence: {}, childRuleIds: ["allowed_label", "label_length"] },
      ],
    },
  },
]

const baseProps: ContractAuthoringProps = {
  approvedContract: null,
  auth,
  canApprove: true,
  contract: null,
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
  templates,
}

describe("ContractAuthoringView", () => {
  it("starts with workflow templates and reveals structured rule fields without raw JSON", async () => {
    const user = userEvent.setup()
    render(<ContractAuthoringView {...baseProps} errors={{}} flash={{}} />)

    expect(screen.getByRole("heading", { level: 1, name: "Define what must remain true" })).toBeInTheDocument()
    expect(screen.getByText("Local evaluation · 0 provider calls")).toBeInTheDocument()
    expect(screen.queryByLabelText("Stable rule ID")).not.toBeInTheDocument()

    await user.click(screen.getByRole("button", { name: "Use this template" }))

    expect(screen.getAllByText("Stable rule ID")).toHaveLength(2)
    expect(screen.getByDisplayValue("allowed_label")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Advanced JSON" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save and validate rules" })).toBeEnabled()
  })

  it("shows exact expected-versus-actual rule judgments and enables owner approval", () => {
    render(
      <ContractAuthoringView
        {...baseProps}
        contract={contract}
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
  })

  it("keeps final approval owner-only while allowing a member to inspect results", () => {
    render(
      <ContractAuthoringView
        {...baseProps}
        auth={{ ...auth, membership: { id: "member-id", role: "member" } }}
        canApprove={false}
        contract={contract}
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
        contract={{ ...contract, status: "approved", approvedAt: "2026-09-15T18:00:00Z", approvedByUserId: "owner-id" }}
        errors={{}}
        fixtures={fixtures}
        flash={{}}
        readiness={{ ready: true, blockers: [] }}
      />,
    )

    expect(screen.queryByRole("button", { name: "Save and validate rules" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Create successor draft" })).toBeEnabled()
    expect(screen.getByText("Contract version 1 is sealed")).toBeInTheDocument()
  })
})
