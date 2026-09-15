import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"

import { MonitorSetupView, type MonitorSetupProps } from "@/pages/Monitors/Setup"

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

const baseProps: MonitorSetupProps = {
  activeCaseCount: 1,
  auth,
  credentials: [
    {
      id: "credential-id",
      provider: "openai",
      label: "Production OpenAI",
      secretSuffix: "9xYz",
      status: "valid",
      lastReturnedModel: "gpt-5.6-luna",
    },
  ],
  limits: {
    maxActiveCases: 20,
    maxTotalCases: 50,
    maxPromptBytes: 40_000,
    maxContextBytes: 100_000,
    maxVariablesBytes: 50_000,
    maxImportBytes: 2_000_000,
    maxOutputTokens: 8_192,
  },
  modelOptions: {
    openai: ["gpt-5.6-luna", "gpt-5.6-sol"],
    anthropic: ["claude-haiku-4-5-20251001", "claude-sonnet-5"],
  },
  progress: {
    completed: { purpose: true, connection: true, prompt: true, cases: true },
    completedCount: 4,
    totalCount: 4,
    percent: 100,
    nextStep: "review",
    ready: true,
  },
  releaseStage: "Private alpha",
  setup: {
    id: "setup-id",
    status: "in_progress",
    monitor: {
      id: "monitor-id",
      name: "Citation guard",
      description: "Keep source citations attached to supported answers.",
      state: "draft",
    },
    providerCredentialId: "credential-id",
    provider: "openai",
    requestedModel: "gpt-5.6-luna",
    systemPrompt: "Use only the supplied context.",
    userPromptTemplate: "Question: {{question}}",
    responseFormat: { type: "text" },
    generationConfig: { maxOutputTokens: 512 },
    cases: [
      {
        caseKey: "citation-required",
        name: "Citation required",
        position: 0,
        status: "active",
        inputVariables: { question: "Which plan includes SSO?" },
        inputVariablesJson: '{"question":"Which plan includes SSO?"}',
        frozenContext: "Enterprise includes SSO.",
      },
    ],
    completedMonitorVersionId: null,
    completedAt: null,
    updatedAt: "2026-09-15T03:00:00Z",
  },
  step: "review",
}

describe("MonitorSetupView", () => {
  it("states the exact zero-call boundary before setup is locked", () => {
    render(<MonitorSetupView {...baseProps} errors={{}} flash={{}} />)

    expect(screen.getByRole("heading", { level: 1, name: "Review and finish" })).toBeInTheDocument()
    expect(screen.getByText("Setup and completion:")).toBeInTheDocument()
    expect(screen.getByText(/future single-sample capture would make 1 provider call/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /finish and lock setup/i })).toBeInTheDocument()
    expect(screen.getAllByText(/0 calls during setup/i).length).toBeGreaterThan(0)
  })

  it("keeps only the named review step navigable after immutable completion", () => {
    render(
      <MonitorSetupView
        {...baseProps}
        errors={{}}
        flash={{}}
        setup={{
          ...baseProps.setup,
          status: "completed",
          completedMonitorVersionId: "version-id",
          completedAt: "2026-09-15T04:00:00Z",
        }}
      />,
    )

    const setupNavigation = within(screen.getByRole("navigation", { name: "Setup steps" }))
    expect(setupNavigation.getByRole("link", { name: "Review" })).toBeInTheDocument()
    expect(setupNavigation.queryByRole("link", { name: "Purpose" })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: /define deterministic contract/i })).toHaveAttribute(
      "href",
      "/app/acme-ai/monitors/monitor-id/contract",
    )
  })

  it("offers a credential recovery path without allowing an invalid connection to continue", () => {
    render(
      <MonitorSetupView
        {...baseProps}
        activeCaseCount={0}
        credentials={[]}
        errors={{}}
        flash={{}}
        progress={{
          ...baseProps.progress,
          completed: { purpose: true, connection: false, prompt: false, cases: false },
          completedCount: 1,
          percent: 25,
          nextStep: "connection",
          ready: false,
        }}
        setup={{
          ...baseProps.setup,
          providerCredentialId: null,
          provider: null,
          requestedModel: null,
          cases: [],
        }}
        step="connection"
      />,
    )

    expect(screen.getByText("No validated OpenAI credential")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Manage credentials" })).toHaveAttribute(
      "href",
      "/app/acme-ai/credentials",
    )
    expect(screen.getByRole("button", { name: /save and continue/i })).toBeDisabled()
  })

  it("requires an explicit credential choice even when valid credentials exist", () => {
    render(
      <MonitorSetupView
        {...baseProps}
        errors={{}}
        flash={{}}
        progress={{
          ...baseProps.progress,
          completed: { purpose: true, connection: false, prompt: false, cases: false },
          completedCount: 1,
          percent: 25,
          nextStep: "connection",
          ready: false,
        }}
        setup={{ ...baseProps.setup, providerCredentialId: null }}
        step="connection"
      />,
    )

    expect(screen.getByRole("button", { name: /save and continue/i })).toBeDisabled()
  })

  it("adds and removes manual cases while keeping the configured limits visible", async () => {
    const user = userEvent.setup()
    render(<MonitorSetupView {...baseProps} errors={{}} flash={{}} step="cases" />)

    expect(screen.getByText("1 of 50 stored cases")).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: "Add another case" }))
    expect(screen.getByText("2 of 50 stored cases")).toBeInTheDocument()
    expect(screen.getByLabelText("Remove case 2")).toBeEnabled()

    await user.click(screen.getByLabelText("Remove case 2"))
    expect(screen.getByText("1 of 50 stored cases")).toBeInTheDocument()
  })
})
