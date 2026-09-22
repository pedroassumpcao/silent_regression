import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it, vi } from "vitest"
import { router } from "@inertiajs/react"
import { GuidedFirstRunView, type GuidedFirstRunProps } from "@/pages/Monitors/GuidedFirstRun"

const polling = vi.hoisted(() => ({ start: vi.fn(), stop: vi.fn() }))
vi.mock("@inertiajs/react", async importOriginal => ({ ...await importOriginal<typeof import("@inertiajs/react")>(), Head: () => null, usePoll: () => polling }))
afterEach(() => vi.restoreAllMocks())
const props: GuidedFirstRunProps = {
  auth: { user: { id: "user", email: "owner@example.com" }, workspace: { id: "ws", name: "Workspace", slug: "acme" }, membership: { id: "member", role: "owner" }, workspaces: [] },
  monitor: { id: "monitor", name: "Routing", state: "ready", cadence: "manual" },
  original: true, completed: false, canFinish: false, reviewed: false, reviewFingerprint: null, authorizationKey: "key",
  checks: { approved: false, ready: true, identity: { contractId: "contract", fingerprint: "rules", coverageFingerprint: "proof" }, rootJson: "{}", fixtures: [], proof: [] },
  preflight: { ready: true, blockers: [], plannedCallCount: 2, maximumCallCount: 4, retryLimit: 1, maxOutputTokensPerCall: 512, maximumOutputTokens: 2048, previewFingerprint: "preview", provider: "openai", model: "model", credentialLabel: "Key" },
  requests: [], snapshot: null,
}
const resultProps: GuidedFirstRunProps = {
  ...props, checks: { ...props.checks, approved: true }, canFinish: true, reviewFingerprint: "result",
  snapshot: { id: "snapshot", status: "pending", runId: "run", runStatus: "succeeded", terminal: true, compatible: true, actualCalls: 2, inputTokens: 30, outputTokens: 10, blockers: [], observations: [
    { id: "observation", name: "Denied action", inputJson: '{"action":"deny"}', context: "", expected: "rejected", output: "rejected", status: "succeeded", completion: "complete", shared: "pass", specific: "pass", reasons: ["The output matched the correct label for this input."], failure: null, requestFingerprint: "request" },
  ] },
}

describe("guided first real result", () => {
  it("approves exact displayed checks without authorizing a call and resets confirmation on changed identity", async () => {
    const post = vi.spyOn(router, "post").mockImplementation(() => {})
    const view = render(<GuidedFirstRunView {...props} />)
    expect(screen.getByRole("button", { name: "Approve checks and continue" })).toBeDisabled()
    await userEvent.click(screen.getByRole("checkbox"))
    await userEvent.click(screen.getByRole("button", { name: "Approve checks and continue" }))
    expect(post).toHaveBeenCalledWith("/app/acme/monitors/monitor/first-run/approve-checks", { identity: { contract_id: "contract", fingerprint: "rules", coverage_fingerprint: "proof" } }, expect.anything())
    view.rerender(<GuidedFirstRunView {...props} checks={{ ...props.checks, identity: { ...props.checks.identity, fingerprint: "new-rules" } }} />)
    expect(screen.getByRole("checkbox")).not.toBeChecked()
    expect(screen.getByRole("button", { name: "Approve checks and continue" })).toBeDisabled()
  })

  it("requires explicit bounded spend consent with the current preview identity", async () => {
    const post = vi.spyOn(router, "post").mockImplementation(() => {})
    render(<GuidedFirstRunView {...props} checks={{ ...props.checks, approved: true }} />)
    expect(screen.getByText("Maximum calls including retries")).toBeInTheDocument()
    expect(screen.getByText(/Input tokens are also billed/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Authorize first run" })).toBeDisabled()
    await userEvent.click(screen.getByRole("checkbox"))
    await userEvent.click(screen.getByRole("button", { name: "Authorize first run" }))
    expect(post).toHaveBeenCalledWith("/app/acme/monitors/monitor/first-run/authorize", { authorization_key: "key", preview_fingerprint: "preview", confirmed: true }, expect.anything())
  })

  it("separates exact-model metadata verification from completion authorization", async () => {
    const post = vi.spyOn(router, "post").mockImplementation(() => {})
    render(<GuidedFirstRunView {...props} checks={{ ...props.checks, approved: true }} preflight={{ ...props.preflight, ready: false, blockers: [{ code: "model_access_unverified", message: "Verify this exact model." }] }} />)
    expect(screen.queryByRole("button", { name: "Authorize first run" })).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole("button", { name: "Verify exact model access" }))
    expect(post).toHaveBeenCalledWith("/app/acme/monitors/monitor/first-run/validate-model", {}, expect.anything())
  })

  it("shows input, expected, actual and explanation; finishing submits only the reviewed snapshot", async () => {
    const post = vi.spyOn(router, "post").mockImplementation(() => {})
    const view = render(<GuidedFirstRunView {...resultProps} />)
    const evidence = within(screen.getByRole("article", { name: "Result 1" }))
    expect(evidence.getByText('{"action":"deny"}')).toBeInTheDocument()
    expect(evidence.getAllByText("rejected")).toHaveLength(2)
    expect(evidence.getByText("The output matched the correct label for this input.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Finish setup" })).toBeDisabled()
    await userEvent.click(screen.getByRole("checkbox"))
    await userEvent.click(screen.getByRole("button", { name: "Finish setup" }))
    expect(post).toHaveBeenCalledWith("/app/acme/monitors/monitor/first-run/finish", { snapshot_id: "snapshot", review_fingerprint: "result", confirmed: true }, expect.anything())
    view.rerender(<GuidedFirstRunView {...resultProps} reviewFingerprint="changed-result" />)
    expect(screen.getByRole("button", { name: "Finish setup" })).toBeDisabled()
  })

  it("keeps failed outputs out of normal approval and offers review and explicit retry preparation", async () => {
    const post = vi.spyOn(router, "post").mockImplementation(() => {})
    render(<GuidedFirstRunView {...resultProps} canFinish={false} />)
    expect(screen.queryByRole("button", { name: "Finish setup" })).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole("checkbox"))
    await userEvent.click(screen.getByRole("button", { name: "Mark results reviewed" }))
    expect(post.mock.calls[0][0]).toMatch(/\/review$/)
    await userEvent.click(screen.getByText("Need to correct something?"))
    await userEvent.click(screen.getByRole("button", { name: "Reject this capture and prepare a retry" }))
    expect(post.mock.calls[1][0]).toMatch(/\/reject$/)
    expect(post.mock.calls.flat().join(" ")).not.toContain("/authorize")
  })

  it("offers member-to-owner handoff without paid or activation controls", () => {
    render(<GuidedFirstRunView {...resultProps} auth={{ ...props.auth, membership: { id: "member", role: "member" } }} />)
    expect(screen.getByText("Ready for your workspace owner")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Finish setup" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Mark results reviewed" })).toBeInTheDocument()
  })

  it("stops polling at terminal state and makes Run again primary with scheduling optional", () => {
    const view = render(<GuidedFirstRunView {...resultProps} snapshot={{ ...resultProps.snapshot!, terminal: false, runStatus: "queued" }} />)
    expect(polling.start).toHaveBeenCalled()
    expect(screen.getByRole("status")).toHaveTextContent("Capture queued")
    view.rerender(<GuidedFirstRunView {...resultProps} completed monitor={{ ...props.monitor, state: "active" }} />)
    expect(polling.stop).toHaveBeenCalled()
    expect(screen.getByRole("link", { name: "Run again" })).toHaveAttribute("href", "/app/acme/monitors/monitor/operations")
    expect(screen.getByRole("link", { name: "Schedule checks (optional)" })).toHaveAttribute("href", "/app/acme/monitors/monitor/operations#schedule-card")
    expect(screen.queryByRole("button", { name: "Finish setup" })).not.toBeInTheDocument()
  })
})
