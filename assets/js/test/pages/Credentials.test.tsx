import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { CredentialsView } from "@/pages/Credentials/Index"

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

const credential = {
  id: "credential-id",
  provider: "openai" as const,
  label: "Production OpenAI",
  secretSuffix: "9xYz",
  status: "valid" as const,
  lastValidationStatus: "succeeded" as const,
  lastFailureCategory: null,
  lastValidatedAt: "2026-09-14T20:00:00Z",
  lastRequestedModel: null,
  lastReturnedModel: "gpt-test",
  lastProviderRequestId: "req_safe",
  lastValidationAttempts: 1,
  supersedesId: null,
  insertedAt: "2026-09-14T19:00:00Z",
}

describe("CredentialsView", () => {
  it("gives owners write-only lifecycle actions and renders only safe metadata", () => {
    const { container } = render(
      <CredentialsView
        auth={auth}
        canManage
        credentials={[credential]}
        errors={{}}
        flash={{}}
        releaseStage="Private alpha"
      />,
    )

    expect(screen.getByRole("heading", { level: 1, name: "Provider credentials" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save credential" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Validate" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Rotate" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Revoke" })).toBeInTheDocument()
    expect(screen.getByText("•••• 9xYz")).toBeInTheDocument()
    expect(screen.getByText("req_safe")).toBeInTheDocument()
    expect(container).not.toHaveTextContent("sk-test-secret-must-never-render")
  })

  it("keeps members read-only while explaining their future execution access", () => {
    render(
      <CredentialsView
        auth={{ ...auth, membership: { ...auth.membership, role: "member" } }}
        canManage={false}
        credentials={[credential]}
        errors={{}}
        flash={{}}
        releaseStage="Private alpha"
      />,
    )

    expect(screen.getByText("Safe workspace access")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Save credential" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Validate" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Rotate" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Revoke" })).not.toBeInTheDocument()
    expect(screen.getByText("Production OpenAI")).toBeInTheDocument()
  })
})
