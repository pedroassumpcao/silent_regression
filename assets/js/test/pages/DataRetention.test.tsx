import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"

import { DataRetentionView } from "@/pages/Settings/DataRetention"

const policy = {
  activeWorkspace: "Raw evidence is retained while the workspace is active.",
  closedWorkspace: "A closed workspace is retained for 30 days before deletion.",
  explicitDeletion: "An explicit deletion request is due immediately.",
  backups: "Disaster-recovery backups expire within 30 days.",
}

const workspace = { id: "workspace-id", name: "Acme AI", slug: "acme-ai" }

function auth(role: "owner" | "member") {
  return {
    user: { id: "user-id", email: "owner@acme.example" },
    workspace,
    membership: { id: "membership-id", role },
    workspaces: [{ ...workspace, role, current: true }],
  }
}

describe("DataRetentionView", () => {
  it("requires an exact slug before enabling an owner's closure action", async () => {
    const user = userEvent.setup()

    render(
      <DataRetentionView
        auth={auth("owner")}
        canManage
        flash={{}}
        policy={policy}
        releaseStage="Private alpha"
      />,
    )

    await user.click(screen.getByRole("button", { name: "Close workspace" }))
    const confirmation = screen.getByLabelText(/Workspace slug/)
    const submit = screen.getAllByRole("button", { name: "Close workspace" }).at(-1)!

    expect(submit).toBeDisabled()
    await user.type(confirmation, "acme-ai")
    expect(submit).toBeEnabled()
    expect(screen.getByText(/30 days before deletion/)).toBeInTheDocument()
  })

  it("keeps lifecycle actions unavailable to members", () => {
    render(
      <DataRetentionView
        auth={auth("member")}
        canManage={false}
        flash={{}}
        policy={policy}
        releaseStage="Private alpha"
      />,
    )

    expect(screen.getByRole("button", { name: "Close workspace" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Request deletion" })).toBeDisabled()
    expect(screen.getByText(/only a workspace owner/)).toBeInTheDocument()
  })
})
