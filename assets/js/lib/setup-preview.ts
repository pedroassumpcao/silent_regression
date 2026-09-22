// Stage 2 interaction model, NOT a production evaluator, request compiler or authorization system.
export type Recipe = "routing" | "json"
export type Scenario = "passing" | "wrong_output" | "wrong_expectation" | "provider_failure" | "member"
export type Outcome = "pass" | "fail"
export type Example = { input: "allow" | "deny"; expected: string }
export type Evidence = { input: string; expected: string; actual: string; shared: Outcome; specific: Outcome; reason: string }
export type Attempt = { revision: string; number: number; failed: boolean; evidence: Evidence[] }
export type PreviewDraft = {
  version: 1
  recipe: Recipe
  scenario: Scenario
  step: number
  name: string
  examples: Example[]
  proof: string | null
  judgments: number[]
  attempts: Attempt[]
  finished: boolean
  handedOff: boolean
}

export const steps = ["Connect request", "Add examples", "Confirm checks", "Run once", "Review & finish"]
export const scenarios: { value: Scenario; label: string }[] = [
  { value: "passing", label: "Passing outputs" },
  { value: "wrong_output", label: "Wrong allowed label" },
  { value: "wrong_expectation", label: "Wrong expectation" },
  { value: "provider_failure", label: "Provider failure" },
  { value: "member", label: "Member → owner handoff" },
]
export const labels = ["approved", "rejected"]

export function newDraft(recipe: Recipe = "routing", scenario: Scenario = "passing"): PreviewDraft {
  return {
    version: 1, recipe, scenario, step: 0,
    name: recipe === "routing" ? "Approval routing guard" : "Decision JSON guard",
    examples: [{ input: "allow", expected: scenario === "wrong_expectation" ? "rejected" : "approved" }, { input: "deny", expected: "rejected" }],
    proof: null, judgments: [], attempts: [], finished: false, handedOff: false,
  }
}

export function outputFor(recipe: Recipe, value: string) {
  return recipe === "json" ? JSON.stringify({ decision: value }) : value
}

export function requestFor(draft: PreviewDraft, input: string) {
  return {
    model: "mock-model (not a provider model)",
    messages: [
      { role: "system", content: `For action=allow return approved; for action=deny return rejected. ${draft.recipe === "json" ? 'Return only a JSON object with a string field "decision".' : "Return only the label."}` },
      { role: "user", content: `action=${input}` },
    ],
    max_output_tokens: 128,
  }
}

export function revisionFor(draft: PreviewDraft) {
  // Exact local identity, not a cryptographic production fingerprint.
  return JSON.stringify({ recipe: draft.recipe, examples: draft.examples, request: requestFor(draft, "{{action}}") })
}

export function evaluateExample(recipe: Recipe, example: Example, actual: string): Evidence {
  let value: unknown = actual
  if (recipe === "json") {
    try { value = (JSON.parse(actual) as { decision?: unknown } | null)?.decision } catch { value = null }
  }
  const shared = typeof value === "string" && labels.includes(value)
  const specific = value === example.expected
  return {
    input: example.input, expected: outputFor(recipe, example.expected), actual,
    shared: shared ? "pass" : "fail", specific: specific ? "pass" : "fail",
    reason: !shared ? (recipe === "json" ? "The decision field must be a string with an allowed label." : "The output is not an allowed label.")
      : !specific ? `Allowed format, wrong answer for action=${example.input}: expected ${example.expected}, got ${String(value)}.`
      : `Matches the expected answer for action=${example.input}.${value === "rejected" ? " A correct business rejection is a passing check." : ""}`,
  }
}

export function proofExamples(draft: PreviewDraft) {
  const [allow, deny] = draft.examples
  return [
    { example: allow, actual: outputFor(draft.recipe, "approved"), intended: "pass" },
    { example: deny, actual: outputFor(draft.recipe, "rejected"), intended: "pass" },
    { example: allow, actual: draft.recipe === "json" ? '{"decision":42}' : "maybe", intended: "fail" },
    { example: allow, actual: outputFor(draft.recipe, "rejected"), intended: "fail" },
  ].map(({ example, actual, intended }, index) => ({
    ...evaluateExample(draft.recipe, example, actual), id: index, intended,
  }))
}

export function proofAgrees(draft: PreviewDraft) {
  return proofExamples(draft).every(row => (row.shared === "pass" && row.specific === "pass" ? "pass" : "fail") === row.intended)
}

export function runSimulation(draft: PreviewDraft): PreviewDraft {
  if (draft.step !== 3 || !hasReviewedProof(draft) || (draft.scenario === "member" && !draft.handedOff)) return draft
  const failed = draft.scenario === "provider_failure" && draft.attempts.length === 0
  const attempt: Attempt = {
    revision: revisionFor(draft), number: (draft.attempts.at(-1)?.number ?? 0) + 1, failed,
    evidence: failed ? [] : draft.examples.map(example => evaluateExample(draft.recipe, example,
      outputFor(draft.recipe, draft.scenario === "wrong_output" && example.input === "allow" ? "rejected" : example.input === "allow" ? "approved" : "rejected"))),
  }
  return { ...draft, step: 4, finished: false, attempts: [...draft.attempts, attempt].slice(-5) }
}

export function canFinish(draft: PreviewDraft) {
  const attempt = draft.attempts.at(-1)
  return draft.step === 4 && hasReviewedProof(draft) && Boolean(attempt && !attempt.failed && attempt.revision === revisionFor(draft) && attempt.evidence.length === 2 && attempt.evidence.every(row => row.shared === "pass" && row.specific === "pass"))
}

function hasReviewedProof(draft: PreviewDraft) {
  return draft.proof === revisionFor(draft) && [0, 1, 2, 3].every(id => draft.judgments.includes(id)) && proofAgrees(draft)
}

export function changeExpectation(draft: PreviewDraft, index: number, expected: string): PreviewDraft {
  return { ...draft, examples: draft.examples.map((example, i) => i === index ? { ...example, expected } : example), proof: null, judgments: [], finished: false, handedOff: false }
}

export function readDraft(raw: string | null): PreviewDraft | null {
  // Local storage is untrusted. Ignore corrupt/old previews rather than crashing or claiming recovery.
  if (!raw || raw.length > 40_000) return null
  try {
    const d = JSON.parse(raw) as PreviewDraft
    if (d.version !== 1 || !["routing", "json"].includes(d.recipe) || !scenarios.some(s => s.value === d.scenario)
      || !Number.isInteger(d.step) || d.step < 0 || d.step > 4 || typeof d.name !== "string" || d.name.length > 120
      || !Array.isArray(d.examples) || d.examples.length !== 2 || d.examples.some((e, i) => e?.input !== (i === 0 ? "allow" : "deny") || typeof e.expected !== "string" || e.expected.length > 80)
      || !(d.proof === null || typeof d.proof === "string") || typeof d.finished !== "boolean" || typeof d.handedOff !== "boolean"
      || !Array.isArray(d.judgments) || d.judgments.length > 4 || new Set(d.judgments).size !== d.judgments.length || d.judgments.some(i => ![0, 1, 2, 3].includes(i))
      || !Array.isArray(d.attempts) || d.attempts.length > 5 || d.attempts.some(a => typeof a?.revision !== "string" || !Number.isInteger(a.number) || typeof a.failed !== "boolean" || !Array.isArray(a.evidence)
        || a.evidence.length > 2 || a.evidence.some(e => !e || ![e.input, e.expected, e.actual, e.reason].every(v => typeof v === "string") || !["pass", "fail"].includes(e.shared) || !["pass", "fail"].includes(e.specific)))) return null
    if (d.step > 2 && !hasReviewedProof(d)) return { ...d, step: 2, proof: null, judgments: [], finished: false }
    if (d.finished && !canFinish(d)) return { ...d, step: 2, finished: false, proof: null }
    if (d.step === 4 && !d.attempts.length) return { ...d, step: 3, finished: false }
    return d
  } catch { return null }
}
