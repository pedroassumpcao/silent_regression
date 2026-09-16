import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"

import { NotificationSettingsView } from "@/pages/Settings/Notifications"

const auth = {
  user: { id: "member-id", email: "member@acme.example" },
  workspace: { id: "workspace-id", name: "Acme AI", slug: "acme-ai" },
  membership: { id: "membership-id", role: "member" as const },
  workspaces: [
    {
      id: "workspace-id",
      name: "Acme AI",
      slug: "acme-ai",
      role: "member" as const,
      current: true,
    },
  ],
}

describe("NotificationSettingsView", () => {
  it("explains the content boundary and lets a member change the personal toggle", async () => {
    const user = userEvent.setup()

    render(
      <NotificationSettingsView
        auth={auth}
        flash={{}}
        preference={{ actionableAlertEmailEnabled: true }}
        releaseStage="Private alpha"
      />,
    )

    const toggle = screen.getByRole("switch", {
      name: "Email me when an alert needs review",
    })

    expect(toggle).toBeChecked()
    expect(screen.getByText(/Prompts, contexts, outputs, and rule evidence are never included/)).toBeInTheDocument()

    await user.click(toggle)
    expect(toggle).not.toBeChecked()
    expect(screen.getByRole("button", { name: "Save preference" })).toBeEnabled()
  })
})
