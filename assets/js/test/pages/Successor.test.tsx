import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"

import { SuccessorView, type SuccessorProps } from "@/pages/Monitors/Successor"

const auth = {
  user: { id: "owner-id", email: "owner@acme.example" },
  workspace: { id: "workspace-id", name: "Acme AI", slug: "acme-ai" },
  membership: { id: "membership-id", role: "owner" as const },
  workspaces: [{ id: "workspace-id", name: "Acme AI", slug: "acme-ai", role: "owner" as const, current: true }],
}

const props: SuccessorProps = {
  auth,
  canActivate: true,
  monitor: { id: "monitor-id", name: "Billing answer guard", state: "active" },
  motivation: {
    id: "review-id",
    classification: "passed_but_should_have_failed",
    action: "case_change",
    rationale: "Add the missed refund-policy case.",
    reviewer: "reviewer@acme.example",
    reviewedAt: "2026-09-20T18:00:00Z",
  },
  preview: {
    activationReady: true,
    activeRun: false,
    changes: ["cases"],
    contractReady: true,
    draftCurrent: true,
    fingerprint: "f".repeat(64),
    modelVerified: true,
    replacementReferenceRequired: true,
    sourceCurrent: true,
  },
  releaseStage: "Private alpha",
  setup: {
    id: "setup-id",
    status: "completed",
    sourceVersion: 1,
    candidateVersion: 2,
    provider: "openai",
    requestedModel: "gpt-5.6-luna",
    completedAt: "2026-09-20T18:10:00Z",
  },
}

describe("SuccessorView", () => {
  it("keeps a copied draft visibly separate from active execution", () => {
    render(<SuccessorView {...props} flash={{}} setup={{ ...props.setup, status: "in_progress", candidateVersion: null, completedAt: null }} preview={{ ...props.preview, activationReady: false, draftCurrent: false, changes: [] }} />)

    expect(screen.getByRole("heading", { name: "Review the configuration successor" })).toBeInTheDocument()
    expect(screen.getByText("Copied draft is safe to edit")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /continue editing/i })).toHaveAttribute("href", "/app/acme-ai/monitors/monitor-id/setup/review")
    expect(screen.queryByRole("button", { name: /activate successor/i })).not.toBeInTheDocument()
  })

  it("explains changed behavior and requires confirmation before activation", async () => {
    const user = userEvent.setup()
    render(<SuccessorView {...props} flash={{}} />)

    expect(screen.getByText(/linked to a reviewed result/i)).toBeInTheDocument()
    expect(screen.getByText("Cases or expectations")).toBeInTheDocument()
    expect(screen.getByText(/replacement reviewed reference is required/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Activate successor" })).toBeEnabled()

    await user.click(screen.getByRole("button", { name: "Activate successor" }))

    expect(screen.getByRole("heading", { name: "Activate configuration v2?" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /activate and capture new reference/i })).toBeEnabled()
  })

  it("lets members inspect readiness without activating or validating", () => {
    render(<SuccessorView {...props} auth={{ ...auth, membership: { id: "member-id", role: "member" } }} canActivate={false} flash={{}} preview={{ ...props.preview, activationReady: false, modelVerified: false }} />)

    expect(screen.getByRole("button", { name: /verify exact-model access/i })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Activate successor" })).toBeDisabled()
    expect(screen.getByText(/workspace owner must validate and activate/i)).toBeInTheDocument()
  })
})
