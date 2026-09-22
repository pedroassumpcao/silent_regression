import { render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, describe, expect, it, vi } from "vitest"
import { router } from "@inertiajs/react"
import { GuidedSetupView, type GuidedSetupProps, type RoutingRaw } from "@/pages/Monitors/GuidedSetup"
import GuidedSetupStart from "@/pages/Monitors/GuidedSetupStart"
import { reconcileJsonValues } from "@/components/guided-recipe-editors"

vi.mock("@inertiajs/react", async importOriginal => ({ ...await importOriginal<typeof import("@inertiajs/react")>(), Head: () => null }))
afterEach(() => vi.restoreAllMocks())
const raw: RoutingRaw = { name: "Routing", description: "", provider: "openai", model: "gpt-5.6-luna", credentialId: "credential", mode: "messages", instruction: "Route {{action}}.", messages: [{ role: "user", content: "{{action}}" }, { role: "assistant", content: "approved" }], nativeJson: "{", generationJson: '{"max_output_tokens":512}', labelsText: "approved\nrejected", cases: [{ key: "allow", name: "Allowed action", variables: { action: "allow" }, context: "", expected: "approved" }] }
const props: GuidedSetupProps = {
  auth: { user: { id: "user", email: "owner@example.com" }, workspace: { id: "ws", name: "Workspace", slug: "acme" }, membership: { id: "member", role: "owner" }, workspaces: [] },
  step: "request", draft: { id: "draft", revision: 2, rawJson: JSON.stringify(raw), reviewedIds: [] },
  credentials: [{ id: "credential", label: "OpenAI", provider: "openai" }], models: { openai: ["gpt-5.6-luna"], anthropic: ["claude-haiku-4-5-20251001"] },
  journey: { stage: "checks", variables: ["action"], blockers: [], reviewed: false, requests: [], proof: [
    { id: "proof1", fingerprint: "proof1", caseKey: "allow", name: "Allowed action", inputJson: '{"action":"allow"}', context: "", expected: "approved", output: "rejected", proposedShared: "pass", proposedCase: "fail", shared: "pass", specific: "fail", reason: "The case-specific label did not match." },
    { id: "proof2", fingerprint: "proof2", caseKey: "allow", name: "Allowed action", inputJson: '{"action":"allow"}', context: "", expected: "approved", output: "approved", proposedShared: "pass", proposedCase: "pass", shared: "pass", specific: "pass", reason: "The case-specific label matched." },
  ] },
}

describe("saved guided routing setup", () => {
  it("chooses the recipe in Step 0 before creating any draft", async () => {
    const post = vi.spyOn(router, "post").mockImplementation(() => {})
    render(<GuidedSetupStart auth={props.auth} />)
    expect(screen.getByText(/Step 0/)).toBeInTheDocument()
    await userEvent.click(screen.getByRole("radio", { name: /Structured JSON/ }))
    expect(post).not.toHaveBeenCalled()
    await userEvent.click(screen.getByRole("button", { name: "Start saved setup" }))
    expect(post).toHaveBeenCalledWith("/app/acme/setup-drafts", { recipe: "json" }, expect.anything())
    expect(screen.getByText(/Changing recipes later requires a separate draft/)).toBeInTheDocument()
  })

  it("does not ask for later proof review while still editing examples", () => {
    render(<GuidedSetupView {...props} step="examples" journey={{ ...props.journey, stage: "checks", blockers: ["Review each proposed judgment."] }} />)
    expect(screen.queryByText("Review each proposed judgment.")).not.toBeInTheDocument()
  })

  it("edits typed JSON targets, retains unfinished numbers, and discloses unsupported schema features", async () => {
    const put = vi.spyOn(router, "put").mockImplementation(() => {})
    const { labelsText: _, ...common } = raw
    const jsonRaw = { ...common, settings: { fields: [{ key: "total", type: "number" }] }, cases: [{ ...raw.cases[0], expected: JSON.stringify({ total: { value: "12.5", tolerance: "0.01" } }) }] }
    render(<GuidedSetupView {...props} step="examples" draft={{ ...props.draft, recipe: "json", rawJson: JSON.stringify(jsonRaw) }} />)
    expect(screen.getByText(/Not a JSON Schema editor/)).toBeInTheDocument()
    expect(screen.queryByLabelText("Allowed labels — one per line")).not.toBeInTheDocument()
    await userEvent.clear(screen.getByLabelText("total expected target for example 1"))
    await userEvent.type(screen.getByLabelText("total expected target for example 1"), "12.")
    await userEvent.click(screen.getByRole("button", { name: "Save and exit" }))
    const saved = put.mock.calls[0][1] as { raw: { cases: Array<{ expected: string }> } }
    expect(JSON.parse(saved.raw.cases[0].expected).total).toEqual({ value: "12.", tolerance: "0.01" })
  })

  it("only clears affected JSON values and never implicitly chooses values for new fields", () => {
    const expected = JSON.stringify({ total: { value: "12.5", tolerance: "0" }, label: { value: "known", tolerance: "" } })
    const before = [{ key: "total", type: "number" }, { key: "label", type: "string" }]
    expect(JSON.parse(reconcileJsonValues(expected, before, [{ key: "total", type: "string" }, { key: "label", type: "string" }, { key: "new", type: "string" }]))).toEqual({ label: { value: "known", tolerance: "" } })
    expect(reconcileJsonValues("{", before, [])).toBe("{")
    expect(reconcileJsonValues("{}", [{ key: "constructor", type: "string" }], [{ key: "constructor", type: "string" }])).toBe("{}")
  })

  it("requires an explicit empty string choice rather than prefilling a known answer", async () => {
    const put = vi.spyOn(router, "put").mockImplementation(() => {})
    const { labelsText: _, ...common } = raw
    const jsonRaw = { ...common, settings: { fields: [{ key: "label", type: "string" }] }, cases: [{ ...raw.cases[0], expected: "" }] }
    render(<GuidedSetupView {...props} step="examples" draft={{ ...props.draft, recipe: "json", rawJson: JSON.stringify(jsonRaw) }} />)
    await userEvent.click(screen.getByRole("button", { name: "Use empty string for label" }))
    await userEvent.click(screen.getByRole("button", { name: "Save and exit" }))
    const saved = put.mock.calls[0][1] as { raw: { cases: Array<{ expected: string }> } }
    expect(JSON.parse(saved.raw.cases[0].expected)).toEqual({ label: { value: "", tolerance: "" } })
  })

  it("presents source syntax, optional attribution and explicit per-case sets", async () => {
    const put = vi.spyOn(router, "put").mockImplementation(() => {})
    const { labelsText: _, ...common } = raw
    const sourceRaw = { ...common, settings: { allowedText: "billing\nrefunds", requiredText: "", factText: "", factSourceId: "", distance: "100" }, cases: [{ ...raw.cases[0], expected: "refunds" }] }
    render(<GuidedSetupView {...props} step="examples" draft={{ ...props.draft, recipe: "sources", rawJson: JSON.stringify(sourceRaw) }} />)
    expect(screen.getByText(/syntactic checks—not source retrieval/)).toBeInTheDocument()
    await userEvent.click(screen.getByText("Optional: attach a declared phrase to one source"))
    await userEvent.type(screen.getByLabelText("Declared phrase alternatives — one per line"), "Refunds within 30 days")
    await userEvent.type(screen.getByLabelText("Source ID that must follow the phrase"), "refunds")
    await userEvent.click(screen.getByRole("button", { name: "Save and exit" }))
    expect(put.mock.calls[0][1]).toMatchObject({ raw: { settings: { factText: "Refunds within 30 days", factSourceId: "refunds" }, cases: [{ expected: "refunds" }] } })
  })

  it("separates shared text alternatives from the case answer and explains semantic blind spots", async () => {
    const put = vi.spyOn(router, "put").mockImplementation(() => {})
    const { labelsText: _, ...common } = raw
    const textRaw = { ...common, settings: { requiredText: "Disclosure", prohibitedText: "Guarantee" }, cases: [{ ...raw.cases[0], expected: "cannot determine" }] }
    render(<GuidedSetupView {...props} step="examples" draft={{ ...props.draft, recipe: "text", rawJson: JSON.stringify(textRaw) }} />)
    expect(screen.getByText(/paraphrases and contradictions are not understood/)).toBeInTheDocument()
    await userEvent.type(screen.getByLabelText("Literal answer alternatives for example 1 — one per line"), "\ninsufficient evidence")
    await userEvent.click(screen.getByRole("button", { name: "Save and exit" }))
    expect(put.mock.calls[0][1]).toMatchObject({ raw: { settings: { requiredText: "Disclosure", prohibitedText: "Guarantee" }, cases: [{ expected: "cannot determine\ninsufficient evidence" }] } })
  })

  it("saves incomplete inputs with the exact displayed revision", async () => {
    const put = vi.spyOn(router, "put").mockImplementation(() => {})
    render(<GuidedSetupView {...props} />)
    await userEvent.clear(screen.getByLabelText("Monitor name"))
    await userEvent.click(screen.getByRole("button", { name: "Save and exit" }))
    expect(put).toHaveBeenCalledWith("/app/acme/setup-drafts/draft", expect.objectContaining({ revision: 2, intent: "exit", raw: expect.objectContaining({ name: "", nativeJson: "{" }) }), expect.anything())
  })

  it("keeps ordered messages editable and derives typed input fields without guessing the expected label", async () => {
    const put = vi.spyOn(router, "put").mockImplementation(() => {})
    const view = render(<GuidedSetupView {...props} />)
    await userEvent.click(screen.getByRole("button", { name: "Move message 2 up" }))
    await userEvent.click(screen.getByRole("button", { name: "Save and continue" }))
    expect(put.mock.calls[0][1]).toMatchObject({ raw: { messages: [{ role: "assistant", content: "approved" }, { role: "user", content: "{{action}}" }] } })
    view.unmount()
    render(<GuidedSetupView {...props} step="examples" />)
    expect(screen.getByLabelText("action for example 1")).toHaveValue("allow")
    await userEvent.click(screen.getByRole("button", { name: "Add example" }))
    expect(screen.getByRole("combobox", { name: "Correct label for example 2" })).toHaveTextContent("Choose…")
  })

  it("shows independent results and requires explicit judgments, with partial review save", async () => {
    const post = vi.spyOn(router, "post").mockImplementation(() => {})
    render(<GuidedSetupView {...props} step="checks" />)
    const wrong = within(screen.getByRole("article", { name: "Proof 1" }))
    expect(wrong.getByText("Shared: pass")).toBeInTheDocument()
    expect(wrong.getByText("Case: fail")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Confirm checks and continue" })).toBeDisabled()
    await userEvent.click(wrong.getByRole("checkbox"))
    await userEvent.click(screen.getByRole("button", { name: "Save and exit" }))
    expect(post).toHaveBeenCalledWith("/app/acme/setup-drafts/draft/review", { revision: 2, intent: "exit", judgments: [{ fingerprint: "proof1", shared: "pass", specific: "fail" }] }, expect.anything())
    await userEvent.click(within(screen.getByRole("article", { name: "Proof 2" })).getByRole("checkbox"))
    expect(screen.getByRole("button", { name: "Confirm checks and continue" })).toBeEnabled()
  })

  it("retains local text and old revision on a stale-tab conflict, instead of silently overwriting", async () => {
    const put = vi.spyOn(router, "put").mockImplementation(() => {})
    const view = render(<GuidedSetupView {...props} />)
    await userEvent.type(screen.getByLabelText("Monitor name"), " local edit")
    view.rerender(<GuidedSetupView {...props} draft={{ ...props.draft, revision: 3, rawJson: JSON.stringify({ ...raw, name: "Teammate edit" }) }} errors={{ draft: "Another tab saved a newer revision." }} />)
    expect(screen.getByLabelText("Monitor name")).toHaveValue("Routing local edit")
    await userEvent.click(screen.getByRole("button", { name: "Save and exit" }))
    expect(put.mock.calls[0][1]).toMatchObject({ revision: 2, raw: { name: "Routing local edit" } })
    expect(screen.getByRole("button", { name: "Reload latest saved draft" })).toBeInTheDocument()
  })

  it("hands off a reviewed configuration without authorizing provider spend or scheduling", async () => {
    const post = vi.spyOn(router, "post").mockImplementation(() => {})
    render(<GuidedSetupView {...props} step="review" draft={{ ...props.draft, reviewedIds: ["proof1", "proof2"] }} journey={{ ...props.journey, reviewed: true, stage: "review" }} />)
    expect(screen.getByText(/No provider call or schedule is authorized/)).toBeInTheDocument()
    await userEvent.click(screen.getByRole("button", { name: "Prepare first-run review" }))
    expect(post).toHaveBeenCalledWith("/app/acme/setup-drafts/draft/seal", { revision: 2 }, expect.anything())
  })
})
