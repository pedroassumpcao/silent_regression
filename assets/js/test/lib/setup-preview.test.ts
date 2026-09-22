import { describe, expect, it } from "vitest"
import { canFinish, changeExpectation, evaluateExample, newDraft, proofAgrees, proofExamples, readDraft, requestFor, revisionFor, runSimulation, type Recipe, type Scenario } from "@/lib/setup-preview"

function ready(recipe: Recipe = "routing", scenario: Scenario = "passing") {
  const draft = { ...newDraft(recipe, scenario), step: 3, judgments: [0, 1, 2, 3] }
  return { ...draft, proof: revisionFor(draft) }
}

describe("isolated setup simulation", () => {
  it.each(["routing", "json"] as const)("separates shared validity from correctness for %s", recipe => {
    const rows = proofExamples(newDraft(recipe))
    expect(rows.map(row => [row.shared, row.specific])).toEqual([["pass", "pass"], ["pass", "pass"], ["fail", "fail"], ["pass", "fail"]])
    expect(rows[1].reason).toContain("correct business rejection")
    expect(canFinish(runSimulation(ready(recipe)))).toBe(true)
  })

  it("rejects malformed JSON and wrong field types without crashing", () => {
    for (const actual of ["{", "null", "42", '"approved"', '{"decision":42}', "[]"]) {
      expect(evaluateExample("json", { input: "allow", expected: "approved" }, actual).shared).toBe("fail")
    }
  })

  it("requires matching review identity and blocks the member run", () => {
    const draft = ready()
    expect(runSimulation({ ...draft, proof: null })).toEqual({ ...draft, proof: null })
    expect(runSimulation(ready("routing", "member")).attempts).toHaveLength(0)
    expect(runSimulation({ ...ready("routing", "member"), handedOff: true }).attempts).toHaveLength(1)
    const changed = changeExpectation(draft, 0, "rejected")
    expect(changed.proof).toBeNull()
    expect(changed.judgments).toEqual([])
    expect(proofAgrees(changed)).toBe(false)
    expect(runSimulation(changed).attempts).toHaveLength(0)
  })

  it("cannot finish failures and retains old expected/actual evidence after correction", () => {
    const failed = runSimulation(ready("routing", "wrong_output"))
    expect(canFinish(failed)).toBe(false)
    const retried = runSimulation({ ...failed, step: 3, outputRecovered: true })
    expect(retried.scenario).toBe("wrong_output")
    expect(canFinish(retried)).toBe(true)
    expect(retried.attempts[0].evidence[0].actual).toBe("rejected")
    expect(retried.attempts[1].evidence[0].actual).toBe("approved")
    expect(canFinish(changeExpectation(retried, 0, "rejected"))).toBe(false)
  })

  it("keeps provider failure distinct from quality and bounds tab history", () => {
    let draft = runSimulation(ready("json", "provider_failure"))
    expect(draft.attempts[0].failed).toBe(true)
    expect(draft.attempts[0].evidence).toEqual([])
    expect(canFinish(draft)).toBe(false)
    for (let i = 0; i < 7; i++) draft = runSimulation({ ...draft, step: 3 })
    expect(draft.attempts).toHaveLength(5)
    expect(draft.attempts.at(-1)?.number).toBe(8)
    expect(canFinish(draft)).toBe(true)
  })

  it("renders the two ordered sample requests without silently changing expectations", () => {
    const draft = newDraft()
    const request = requestFor(draft, "deny")
    expect(request.messages.map(message => message.role)).toEqual(["system", "user"])
    expect(request.messages[1].content).toBe("action=deny")
    expect(request.max_output_tokens).toBe(128)
    expect(request).toEqual(requestFor(changeExpectation(draft, 0, "rejected"), "deny"))
  })

  it("restores bounded drafts, ignores corruption and reopens stale proof for review", () => {
    const draft = ready()
    expect(readDraft(JSON.stringify(draft))).toEqual(draft)
    expect(readDraft(JSON.stringify(newDraft()))?.step).toBe(-1)
    expect(readDraft("{")).toBeNull()
    expect(readDraft("x".repeat(40_001))).toBeNull()
    expect(readDraft(JSON.stringify({ ...draft, step: 12 }))).toBeNull()
    expect(readDraft(JSON.stringify({ ...draft, judgments: [0, 0, 0, 0] }))).toBeNull()
    expect(readDraft(JSON.stringify({ ...draft, attempts: [{ evidence: [null] }] }))).toBeNull()
    expect(readDraft(JSON.stringify({ ...draft, proof: "old" }))?.step).toBe(2)
    expect(readDraft(JSON.stringify({ ...draft, step: 4, finished: true }))?.finished).toBe(false)
  })
})
