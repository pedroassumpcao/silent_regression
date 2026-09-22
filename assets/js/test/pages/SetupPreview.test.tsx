import { fireEvent, render, screen, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { SetupPreviewView } from "@/pages/Monitors/SetupPreview"
import { newDraft, readDraft, type Recipe, type Scenario } from "@/lib/setup-preview"

vi.mock("@inertiajs/react", async importOriginal => ({ ...await importOriginal<object>(), Head: () => null }))

const props = { storageKey: "preview-test", workspaceSlug: "acme", workspaceName: "Acme" }
beforeEach(() => sessionStorage.clear())
afterEach(() => vi.restoreAllMocks())
const click = async (name: string | RegExp) => userEvent.click(screen.getByRole("button", { name }))

function show(recipe: Recipe = "routing", scenario: Scenario = "passing") {
  sessionStorage.setItem(props.storageKey, JSON.stringify(newDraft(recipe, scenario)))
  return render(<SetupPreviewView {...props} />)
}

async function toChecks() {
  await click("Start simulation")
  await click("Continue to examples")
  await click("Continue to checks")
}

async function toRun() {
  await toChecks()
  for (const checkbox of screen.getAllByRole("checkbox")) await userEvent.click(checkbox)
  await click("Confirm checks and continue")
}

async function authorize() {
  expect(screen.getByRole("button", { name: /Run simulation/ })).toBeDisabled()
  await userEvent.click(screen.getByRole("checkbox", { name: /4-call maximum/ }))
  await click(/Run simulation/)
}

describe("SetupPreviewView", () => {
  it.each(["routing", "json"] as const)("completes %s with explicit proof, authorization and result review, without network calls", async recipe => {
    const network = vi.spyOn(globalThis, "fetch")
    const xhr = vi.spyOn(XMLHttpRequest.prototype, "open")
    show(recipe)
    expect(screen.getByRole("heading", { level: 1 })).toHaveFocus()
    await toChecks()
    expect(screen.getByRole("button", { name: "Confirm checks and continue" })).toBeDisabled()
    const wrong = screen.getByRole("article", { name: "Proof example 4" })
    expect(within(wrong).getByText("Shared: pass")).toBeInTheDocument()
    expect(within(wrong).getByText("Case: fail")).toBeInTheDocument()
    for (const checkbox of screen.getAllByRole("checkbox")) await userEvent.click(checkbox)
    await click("Confirm checks and continue")
    await authorize()
    expect(screen.getByRole("button", { name: "Finish setup" })).toBeDisabled()
    expect(screen.getByText(/on-demand means checks run when you select Run now/)).toBeInTheDocument()
    await userEvent.click(screen.getByRole("checkbox", { name: /reviewed both outputs/ }))
    await click("Finish setup")
    expect(screen.getByRole("heading", { name: "Practice walkthrough complete" })).toBeInTheDocument()
    expect(screen.getByText("Off · on-demand only (simulated)")).toBeInTheDocument()
    expect(screen.getByText(/fictional inputs, checks and results are not copied/)).toBeInTheDocument()
    expect(network).not.toHaveBeenCalled()
    expect(xhr).not.toHaveBeenCalled()
    expect(readDraft(sessionStorage.getItem(props.storageKey))?.finished).toBe(true)
  })

  it("saves incomplete inputs and partial judgments, resumes, and invalidates review on edits", async () => {
    let view = show()
    await click("Start simulation")
    await click("Continue to examples")
    fireEvent.change(screen.getByLabelText("Expected label for allow"), { target: { value: "" } })
    await click("Continue to checks")
    expect(screen.getByRole("alert")).toHaveTextContent("Each expected answer")
    await click("Save and exit preview")
    view.unmount()
    view = render(<SetupPreviewView {...props} />)
    expect(screen.getByLabelText("Expected label for allow")).toHaveValue("")
    fireEvent.change(screen.getByLabelText("Expected label for allow"), { target: { value: "approved" } })
    await click("Continue to checks")
    await userEvent.click(screen.getByRole("checkbox", { name: "I judge example 1 should pass." }))
    await click("Save and exit preview")
    await click("Resume preview")
    expect(screen.getByRole("checkbox", { name: "I judge example 1 should pass." })).toBeChecked()
    await click("Back")
    fireEvent.change(screen.getByLabelText("Expected label for allow"), { target: { value: "rejected" } })
    await click("Continue to checks")
    expect(screen.getByRole("checkbox", { name: "I judge example 1 should pass." })).not.toBeChecked()
    expect(screen.getByRole("button", { name: "Correct expected answers" })).toBeInTheDocument()
  })

  it("retains edits and does not claim saved when browser storage fails", async () => {
    show()
    await click("Start simulation")
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new Error("storage disabled") })
    fireEvent.change(screen.getByLabelText("Monitor name"), { target: { value: "My edited name" } })
    await click("Save and exit preview")
    expect(screen.getByRole("alert")).toHaveTextContent("Could not save")
    expect(screen.getByLabelText("Monitor name")).toHaveValue("My edited name")
    expect(screen.queryByRole("button", { name: "Resume preview" })).not.toBeInTheDocument()
  })

  it("catches a wrong expectation before spend and allows a reviewed correction", async () => {
    show("routing", "wrong_expectation")
    await toChecks()
    expect(screen.getByRole("alert")).toHaveTextContent("disagree")
    await click("Correct expected answers")
    fireEvent.change(screen.getByLabelText("Expected label for allow"), { target: { value: "approved" } })
    await click("Continue to checks")
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Confirm checks and continue" })).toBeDisabled()
  })

  it("shows member handoff without sending anything or granting real permissions", async () => {
    show("routing", "member")
    await toRun()
    expect(screen.getByRole("heading", { name: "An owner needs to approve this run" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Run simulation/ })).not.toBeInTheDocument()
    await click("Preview owner review")
    expect(screen.getByText(/actual role has not changed/)).toBeInTheDocument()
    await authorize()
  })

  it("keeps provider failure separate from quality and requires fresh retry authorization", async () => {
    show("routing", "provider_failure")
    await toRun()
    await authorize()
    expect(screen.getByText("Provider unavailable (simulated)")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Finish setup" })).not.toBeInTheDocument()
    await click("Review retry authorization")
    await authorize()
    expect(screen.getByText("Both inputs matched their expected behavior")).toBeInTheDocument()
    expect(readDraft(sessionStorage.getItem(props.storageKey))?.attempts).toHaveLength(2)
  })

  it("recovers from a wrong output without changing expectations or erasing failed evidence", async () => {
    show("json", "wrong_output")
    await toRun()
    await authorize()
    expect(screen.getByText("An allowed output was wrong for its input")).toBeInTheDocument()
    await click("Review retry after upstream fix")
    await authorize()
    const draft = readDraft(sessionStorage.getItem(props.storageKey))!
    expect(draft.examples[0].expected).toBe("approved")
    expect(draft.scenario).toBe("wrong_output")
    expect(draft.attempts[0].evidence[0].specific).toBe("fail")
    expect(draft.attempts[1].evidence[0].specific).toBe("pass")
  })

  it("routes mistaken expectations back to independent proof rather than approving failures", async () => {
    show("routing", "wrong_output")
    await toRun()
    await authorize()
    await userEvent.click(screen.getByRole("radio", { name: /My expectation is wrong/ }))
    await click("Correct expected answers")
    expect(screen.getByLabelText("Expected label for allow")).toHaveValue("approved")
    expect(readDraft(sessionStorage.getItem(props.storageKey))?.proof).toBeNull()
    await click("Continue to checks")
    expect(screen.getByRole("button", { name: "Confirm checks and continue" })).toBeDisabled()
  })

  it("does not restore a different user/workspace preview", async () => {
    const view = show()
    await toChecks()
    view.unmount()
    render(<SetupPreviewView {...props} storageKey="different-workspace-user" />)
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("Choose the simulation")
  })

  it("offers Step 0 before setup and commits both choices only when starting", async () => {
    render(<SetupPreviewView {...props} />)
    expect(screen.getByText("Step 0 · Choose simulation")).toBeInTheDocument()
    expect(within(screen.getByRole("navigation")).getAllByRole("listitem")).toHaveLength(6)
    expect(screen.queryByLabelText("Monitor name")).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole("radio", { name: "Structured JSON" }))
    await userEvent.click(screen.getByRole("radio", { name: "Wrong expectation" }))
    expect(sessionStorage.getItem(props.storageKey)).toBeNull()
    await click("Start simulation")
    const saved = readDraft(sessionStorage.getItem(props.storageKey))!
    expect(saved).toMatchObject({ step: 0, recipe: "json", scenario: "wrong_expectation" })
    expect(screen.getByLabelText("Monitor name")).toHaveValue("Decision JSON guard")
    expect(screen.queryByRole("radio", { name: "Structured JSON" })).not.toBeInTheDocument()
  })

  it("canceling Step 0 preserves unsaved authoring text and prior progress", async () => {
    show()
    await click("Start simulation")
    fireEvent.change(screen.getByLabelText("Monitor name"), { target: { value: "My custom draft" } })
    const saved = sessionStorage.getItem(props.storageKey)
    await click("Start a different simulation")
    await userEvent.click(screen.getByRole("radio", { name: "Structured JSON" }))
    expect(screen.getByText("Starting over resets this preview")).toBeInTheDocument()
    expect(sessionStorage.getItem(props.storageKey)).toBe(saved)
    await click("Keep current simulation")
    expect(screen.getByLabelText("Monitor name")).toHaveValue("My custom draft")
    expect(screen.getByRole("heading", { level: 1 })).toHaveFocus()
  })

  it("replaces progress, review and attempts only after explicit restart confirmation", async () => {
    show("routing", "wrong_output")
    await toRun()
    await authorize()
    const saved = sessionStorage.getItem(props.storageKey)
    await click("Start a different simulation")
    await userEvent.click(screen.getByRole("radio", { name: "Structured JSON" }))
    await userEvent.click(screen.getByRole("radio", { name: "Member → owner handoff" }))
    expect(sessionStorage.getItem(props.storageKey)).toBe(saved)
    await click("Keep current simulation")
    expect(screen.getByText("An allowed output was wrong for its input")).toBeInTheDocument()
    await click("Start a different simulation")
    await userEvent.click(screen.getByRole("radio", { name: "Structured JSON" }))
    await userEvent.click(screen.getByRole("radio", { name: "Member → owner handoff" }))
    await click("Start new simulation")
    expect(readDraft(sessionStorage.getItem(props.storageKey))).toMatchObject({ step: 0, recipe: "json", scenario: "member", attempts: [], judgments: [], proof: null, handedOff: false, outputRecovered: false })
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("Connect the request")
  })

  it("a failed replacement save cannot overwrite the existing draft or trap the user", async () => {
    show()
    await toChecks()
    const saved = sessionStorage.getItem(props.storageKey)
    await click("Start a different simulation")
    await userEvent.click(screen.getByRole("radio", { name: "Structured JSON" }))
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new Error("storage disabled") })
    await click("Start new simulation")
    expect(screen.getByRole("alert")).toHaveTextContent("Could not save")
    expect(sessionStorage.getItem(props.storageKey)).toBe(saved)
    await click("Keep current simulation")
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("Do these checks")
  })

  it("restores pre-Step-0 saved journeys without resetting them", () => {
    const { outputRecovered: _oldMissing, ...legacyDraft } = newDraft()
    sessionStorage.setItem(props.storageKey, JSON.stringify({ ...legacyDraft, step: 1, name: "Existing draft" }))
    render(<SetupPreviewView {...props} />)
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("What should each input")
    expect(screen.queryByRole("button", { name: "Start simulation" })).not.toBeInTheDocument()
  })
})
