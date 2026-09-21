# Monitor setup UX assessment

Date: 2026-09-21. Status: assessment and proposed roadmap; implementation not started.

## Recommendation

Replace the fragmented setup journey with a guided flow organized around the first useful result:
**connect a request → add inputs and expected answers → confirm checks with examples → run once →
review and finish**. Offer recurring monitoring afterward. Retain the existing deterministic
engines, immutable execution evidence, owner permissions, and bounded provider authorization.

The current journey exposes the application's internal entities and approval mechanisms before
the user experiences its value. Selecting a template changes starter rules, but does not provide
a workflow-specific authoring experience. More documentation would help temporarily, but would
leave this central problem in place.

This is an assessment of the implemented workflow, informed by the founder's local walkthrough.
It is not a measured conversion study. The recommendation is a product hypothesis to validate with
technical users who did not build the application.

## Evidence and boundaries

- Read the current private-alpha implementation plan, setup research, React pages, controllers,
  domain state transitions, proof evaluation, and activation analytics.
- Inspected the existing local monitor list, operations, approved contract, and reviewed reference
  pages in the user's browser. The monitor had two cases, three proof examples, an approved reference,
  and a successful manual run. No provider calls, new monitors, approvals, or data edits were made.
- Inspected the initial and editable setup states in source. Findings about those states are
  source-based, rather than claims of a newly completed browser walkthrough.
- Checked primary design guidance on multi-step forms, action hierarchy, and task lists.
- The previously fixed empty-context promotion bug is evidence that validation inconsistency can
  become an unexplained setup blocker; it is not reported here as still open.

## Current journey

| Stage | What the user actually has to work out | Assessment |
| --- | --- | --- |
| Create monitor | Name the workflow and describe the regression | Reasonable start; the description does not configure a check, which needs to be clear |
| Connect | Leave setup if necessary, store and validate a key, select it, select the exact model | Context switch and repeated access concepts |
| Request | Enter provider-specific JSON, variables, response format, and generation settings | Too much low-level authoring for the default path |
| Cases | Create keys and names, variables JSON, optional frozen context, expectation JSON, and status | The hardest correctness input is a JSON box before the template is chosen |
| Lock configuration | Review fingerprints and request artifacts, then create an immutable version | A technical boundary presented as finishing setup, before first value |
| Contract | Pick one of four templates, configure a generic rule editor, record assistance mode | The template supplies defaults but leaves most of the reasoning to the user |
| Proof | Invent outputs, label overall and per-rule results, interpret branch coverage and possible waivers | Requires understanding how the evaluator is implemented |
| Approve checks | Seal the contract, then navigate elsewhere | Another finish action, with a different meaning |
| First capture | Read method explanations, verify model access if necessary, select samples, authorize calls | The first real result is described primarily in operational terminology |
| Review reference | Inspect outputs and evaluation layers, approve or reject | Necessary human decision; the presentation is much denser than the decision |
| Operations | Activate even for manual use, choose/save cadence, run, find results | First use and recurring operations share competing controls |

There are several different progress systems: creation says “Step 1 of 5”; setup counts four
persisted steps plus a review screen; contract authoring starts another four-step process; reference
capture starts another four; the workspace shows a six-item activation checklist. These numbers
have internal explanations, but do not give the customer one reliable answer to “How far am I from
seeing a result?”

## Findings and priorities

P1 means address before expecting independent design-partner onboarding. P2 means include in the
guided redesign or its immediate follow-up. These are product priorities, not security severity.

| ID | Finding and evidence | Impact | Recommendation | Priority |
| --- | --- | --- | --- | --- |
| U1 | The default case editor requires input and expectation JSON, stable IDs, and knowledge of five expectation types. [Setup.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Setup.tsx:905) | Technical users must learn a proprietary authoring format before testing their workflow | Derive variable fields from the request; provide typed expected-answer controls; generate IDs; retain an advanced JSON editor | P1 |
| U2 | All four templates lead into the same 14-type rule editor. [Contract.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Contract.tsx:216) | Choosing a workflow does not resolve what to do next | Build guided recipes that ask questions specific to the output shape | P1 |
| U3 | Cases, case expectations, shared rules, and proof outputs live in separate surfaces. Contract fixtures have no case association. [contract_fixture.ex](/Users/pedro/projects/silent_regression/lib/silent_regression/contract_authoring/contract_fixture.ex:17) | Users cannot see how an output relates to an input; rule proof can be mistaken for proof of correct routing | Present one example workspace with input, expected answer, example output, and applicable checks; preserve their distinct domain roles | P1 |
| U4 | Draft contract pages can show rule saving, example saving, coverage waivers, and approval together. [Contract.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Contract.tsx:330) | Several legitimate actions compete; users must infer the order | One primary next action per stage; put edits in local secondary actions and exceptions in advanced controls | P1 |
| U5 | “Save and exit” posts only the step name. The handler records leaving and redirects with “Setup saved.” [Setup.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Setup.tsx:1271), [controller](/Users/pedro/projects/silent_regression/lib/silent_regression_web/controllers/monitor_setup_controller.ex:114) | Newly entered values are not submitted by that button; recovery promises are inaccurate | Persist the current form before leaving; distinguish saved, saving, and unsaved states; protect navigation and surface validation failures | P1 defect |
| U6 | Rule edits are local to ContractEditor, while fixture evaluation and approval use saved contract props; approval does not receive editor dirty state. [Contract.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Contract.tsx:411), [approval](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Contract.tsx:1012) | Users can reason about visible edits while evaluating or approving the saved revision | Gate evaluation/approval on saved state and pass the exact reviewed revision fingerprint; reproduce this source-supported interaction risk in an isolated browser test | P1 risk |
| U7 | The live list showed an active manual monitor with a successful run, but activation stayed at 5/6. The predicate accepts daily/weekly only. [pilot_readiness.ex](/Users/pedro/projects/silent_regression/lib/silent_regression/pilot_readiness.ex:196) | Users who choose manual operation are told they have not finished | Count manual readiness as valid completion; measure recurring enablement separately | P1 defect |
| U8 | “Finish and lock setup” precedes contract authoring, proof, capture, and approval. [Setup.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Setup.tsx:1189) | False finish lines and costly backtracking when the first example reveals a mistake | Use one journey indicator; keep authoring editable until the execution snapshot is prepared | P1 |
| U9 | “Pass” describes conformity, while “approved/rejected” describes the business decision. Fixture and proof terminology dominates the page. [Contract.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Contract.tsx:701) | A correct rejection looks like something the user should mark as failure | Use “Meets these checks” and “Violates these checks”; explain business outcome separately | P1 |
| U10 | The reference screen leads with a four-layer method explanation and provenance terminology before results and actions. [Baseline.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Baseline.tsx:319) | Users spend effort interpreting machinery before making a concrete decision | Lead with input → expected → actual → reason; put method and provenance behind clear disclosure | P2 |
| U11 | Approved contract page showed “New reviewed reference required” from a historical rescore, although a reference was already approved. [Contract.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Contract.tsx:963) | A historical outcome appears to be an unresolved current action | Label it as history or derive the current action from present reference compatibility | P2 |
| U12 | Operations still displays “Run evidence and alert review arrive in Task 12.” [Operations.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Operations.tsx:548) | Development notes undermine confidence and obscure available functionality | Remove task-number copy; link directly to the latest result | P2 defect |
| U13 | “Inspect” is marked complete when capture ends, not when inspection occurs. [Baseline.tsx](/Users/pedro/projects/silent_regression/assets/js/pages/Monitors/Baseline.tsx:298) | Progress confuses evidence availability with a human decision | Say “Ready to review”; reserve reviewed state for explicit acknowledgment/approval | P2 |
| U14 | Analytics call explicit save-and-exit events “abandonment,” and activation timing is based on schedule activation. [product_analytics.ex](/Users/pedro/projects/silent_regression/lib/silent_regression/product_analytics.ex:222) | The metrics cannot reliably tell whether the redesigned flow produces faster first value | Separate saves, stalled sessions, first completed run, reviewed result, manual readiness, and recurring enablement | P2 |

The current system has valuable foundations: durable cases, independent case expectations,
explainable checks, proof coverage, exact requests, bounded calls, and immutable history. The UX
should make their meaning easier to understand while preserving their behavior.

## Options

| Option | Benefits | Costs and limitations | Judgment |
| --- | --- | --- | --- |
| A. Copy, documentation, and a short contextual walkthrough | Fastest relief; can address labels, instructions, and button hierarchy with little domain change | Users still construct JSON, proof examples, and links between concepts themselves | Useful immediate patch, insufficient as the final design |
| B. Guided recipes and one setup journey | Reduces decisions and repetition; supports an advanced path; reuses most backend work | Needs a draft orchestration layer, typed editors, proof assistance, and coordinated saving | Recommended |
| C. Run a request first, then define expectations from its output | Fastest route to seeing the user's own model output; useful for unknown output shapes | Requires a distinct exploratory capture mode, draft provenance, authorization, retention, and explicit review before any promotion; risks accepting whatever the model happened to say | Consider later if users still stall before first output |
| D. Conversational assistant builds the monitor | Can help users express intent and propose checks | Introduces additional model calls, ambiguity, and confirmation work; a conversation can hide omissions and is harder to inspect | Optional assistance later; do not make it the only interface |
| E. Fully concierge setup | Supports learning with the earliest partners and exposes real workflows | Founder time scales with each monitor; does not establish independent usability | Complement B for difficult cases |

The recommended order is A's correctness fixes, then B. Avoid a rewrite of the execution engine.
The effort should go into a new authoring experience and a small coordination layer around existing
contexts. A short tour is appropriate for an optional feature; it cannot resolve a fundamentally
ambiguous dependency chain.

## Proposed guided journey

Use one persistent five-stage indicator. Each stage may have focused subviews; do not obtain a
smaller step count by packing several forms into another long page. Returning users resume at the
next unfinished decision with saved work visible.

### 1. Connect your request

Ask for a name, provider/model, credential, and the messages/settings the application actually uses.
Create or select a credential inline with a return path. Describe and authorize access validation
where it happens; keep completion authorization later.

Default to a message editor that preserves roles and order. Keep supported provider JSON as an
advanced import/edit route. Detect variables and offer fields for them. Show unsupported fields
explicitly rather than dropping them. A structured editor must round-trip the supported exact request
artifact; it must not add prose, infer production settings, or rewrite the customer's prompt.

Ask the output-shape question here, so it can guide the next stage: “A label,” “JSON,” “An answer with
sources,” or “Text with required/prohibited phrases.” These are starting recipes, and can be combined
through advanced checks. Request response format and evaluation requirements remain distinct.

Primary action: **Add an example input**.

### 2. Add inputs and expected answers

Show one example at a time. For the walkthrough, the user sees an `action` field containing `allow`
and “Expected label” containing `approved`; the second example is `deny` → `rejected`. IDs are generated
and only shown in advanced details. Show context when relevant to the request, with an option to add
it when needed.

Ask which checks apply to every output and which depend on this input, using ordinary controls.
Allow an explicit “I can check the format but do not know the exact answer” choice, and disclose the
resulting coverage limit. Do not treat a missing expected answer as equivalent to a verified answer.

Start with a small useful set; one case can demonstrate the flow, while routing generally benefits
from examples of different decisions. Additional cases can be added through the existing revision
workflow later. Example count is coverage guidance, not a claim of adequate production sampling.

Primary action: **Review the checks**. Secondary action: **Add another input**.

### 3. Confirm the checks and prove them

Present readable statements: “Return only approved or rejected,” “For the allow input, return approved,”
and “For the deny input, return rejected.” Advanced details reveal the exact underlying rules.

Propose valid and deliberately invalid example outputs using the declared criteria. The user must
confirm the intended behavior before those proposals count as proof. A candidate generated by the
same evaluator must not become independent ground truth merely because that evaluator agrees with it.

For this routing monitor:

| Example | Shared check | Input-specific expectation | Meaning |
| --- | --- | --- | --- |
| `approved` for `allow` | Meets checks | Correct for this input | Valid example |
| `rejected` for `deny` | Meets checks | Correct for this input | Valid example |
| `maybe` for `allow` | Violates allowed-label check | Incorrect for this input | Detect an unknown label |
| `rejected` for `allow` | Meets shared check | Incorrect for this input | Detect a wrong route despite a valid label |

The fourth row is especially useful: it demonstrates the product's case-specific protection instead
of teaching users that membership in a label list establishes correctness. The current contract
fixture screen evaluates shared rules only, so presenting this combined proof requires a preview
service that invokes both existing engines with an explicit case association.

For new classification recipes, omit the redundant default word-count warning unless requested.
Whole-output membership in the confirmed label set already rejects extra explanation. Preserve all
existing approved checks; this is a new-authoring default, not a migration of historical semantics.

Show a focused question for missing proof: “Add an output that should violate this check.” The app
can propose a mutation and explain every affected rule. If a mutation violates several rules, show
all of them. Do not silently select expected outcomes from the evaluator result. Owner waivers remain
an advanced, explicit exception, not the normal next action.

Primary action after proof is complete: **Review first run**.

### 4. Run once

Summarize the request, cases, confirmed checks, provider, model, and call envelope. The owner confirms
the checks and authorizes the precise execution. These can be presented together, but must retain
separate auditable meanings and clear role handling. A member can finish preparation and hand off
the same saved state to an owner.

For two cases and one sample each: “Run these 2 cases. Up to 4 completion calls including retries.”
Disclose any separate model-access request and the lack of a reliable currency estimate. A retry
ceiling is not an exact price quote.

Use the existing baseline/reference capture path for this first live run. It already runs without
an approved baseline once the configuration and contract prerequisites are satisfied. This avoids
introducing exploratory execution in the initial redesign.

Primary action: **Confirm checks and run 2 cases**. Show queued/running states and automatically lead
to the result when ready. Repeated clicks, reloads, and interrupted requests must resume the same
authorized attempt rather than dispatching duplicate work.

### 5. Review the result and finish

Show a compact row for each input: expected answer, actual output, outcome, and reason. Put token use,
request IDs, fingerprints, evaluation internals, and full artifacts in expandable evidence details.

Let the user distinguish “The output is wrong” from “My expectation/check is wrong.” Link the latter
directly into an editable revision with the prior failure preserved. Apply compatibility checks
before reusing any captured evidence; do not quietly rescore history and call the request unchanged.

For compatible acceptable results, primary action: **Use these outputs as my reference and finish**.
Make the resulting mode explicit: manual runs available, automatic runs off. This action should
coordinate existing approval and manual activation without an extra navigation to save “Manual.”
Failures keep the correction path prominent; exceptional acceptance stays available as an advanced
owner decision with its existing meaning.

The monitor then opens with **Run again** as its primary action and **Schedule checks** as secondary.
Its first capture is labeled “Initial run / reviewed reference,” while subsequent runs retain their
actual kinds. The first result must be visible in history; no redundant provider call is needed just
to make the application look activated. Daily/weekly scheduling remains an explicit later decision.

## What each recipe should ask

| Recipe | Guided questions | Useful local proof candidates | Important boundary |
| --- | --- | --- | --- |
| Classification/routing | What labels are allowed? Which label is right for this input? | Valid label, unknown label, wrong allowed label for a linked case, extra explanation | Shared label validity and case correctness are separate |
| Structured JSON | Which fields must exist? Their types? Exact values or numeric ranges for this input? | Missing field, wrong type, out-of-range value, malformed JSON | Shape does not prove truth; observed fields are proposals, not requirements |
| Answer with sources | Which sources are allowed/required? Which declared statements require which source? | Missing source, unknown source, incorrect configured attribution | Citation matching is syntactic; it does not establish general factuality |
| Required/prohibited text | Which phrases must appear or must not appear? Are exact alternatives acceptable? | Remove required phrase, insert prohibited phrase | Literal matching does not understand all paraphrases or contradictions |

When a JSON schema is already supplied, propose the subset expressible by the existing engine and
identify unsupported requirements. For grounded answers, reuse entered source IDs and context; do
not generate additional semantic requirements automatically. Neither operation should require an
LLM in the first implementation.

## UI and guidance rules

- One visually dominant next action per stage. Back, save for later, add input, and advanced settings
  remain available with appropriate emphasis. Multiple controls are acceptable when their roles
  are clear; several equal finish actions are not.
- Show successful saves explicitly. Navigation must preserve current work, including partially
  entered JSON and lists; validation failure should retain entered text and focus the affected field.
- Keep examples next to the corresponding question. Never ask users to translate developer fixture
  terminology or a separate document into form options.
- Use “checks” in the primary UI, “test examples” for proof outputs, and “reviewed reference” for the
  accepted first capture. Retain precise domain terminology in advanced details.
- Give a blocked action one actionable explanation and a direct route to fix it. A generic error or
  a disabled button without an explanation is insufficient.
- Use one completion definition per monitor. Show optional recurring setup separately and distinguish
  a temporary operational pause from a user who never finished setup.
- Show current state separately from historical transitions. A completed reference replacement
  must not remain an apparent action item on an old rescore card.
- Preserve keyboard operation, explicit labels, focus after validation/navigation, and readable
  progress announcements; do not rely on color to explain expected failures.

Keep a short contextual guide for each recipe, with a working example and a “What this detects”
section. The existing zero-call demo is useful as an optional orientation and incident example.
Making every new user complete a long tour would add another prerequisite to first value.

This action hierarchy follows the GOV.UK recommendation to avoid competing primary buttons.
Logical stages with saved navigation follow W3C's multi-page form guidance. A free-order task list
is a poor primary model for this dependency-heavy sequence; GOV.UK explicitly distinguishes that
case. These sources inform the design, not a claimed conversion uplift.

- [GOV.UK: Buttons](https://design-system.service.gov.uk/components/button/)
- [W3C: Multi-page forms](https://www.w3.org/WAI/tutorials/forms/multi-page/)
- [GOV.UK: Task lists](https://design-system.service.gov.uk/components/task-list/)

## Backend and data model implications

No database wipe or wholesale domain rewrite is warranted.

| Area | Proposed change | Schema implications |
| --- | --- | --- |
| Honest saving and action hierarchy | Coordinate current forms; accurate save status; derive the next action | Most immediate fixes need no migration; persist incomplete editor values if save-for-later promises to retain them |
| Guided request and expectation editors | Compile typed controls into existing request/expectation formats with server validation | Existing executable formats can stay |
| One editable authoring flow | Extend the setup draft, or introduce a small authoring draft containing request, cases, proposed checks, and proposed proof examples | Add bounded versioned draft data, recipe identity/version, optimistic concurrency, and relevant review state |
| Late snapshot creation | Keep authoring editable through proof; prepare immutable monitor/case and contract records at the explicit review/authorization boundary | Context/orchestration work is required: contract authoring currently requires a MonitorVersion; simply moving buttons cannot remove that dependency |
| Combined example preview | Associate a proof example with an optional case draft identity; evaluate shared and case checks separately | Store explicit scope/provenance and resolve case references to exact CaseVersion IDs when sealing; existing shared-only fixtures stay shared-only |
| Suggested proof examples | Store source/manual/generated origin, generator version where relevant, and user-confirmed expected outcomes | Additive proposal/review metadata; bind judgment to exact case/check/example fingerprints |
| Manual completion | Coordinate reference approval with manual readiness; display first capture as first result | Mainly orchestration/presentation; preserve actual CaptureRun kind and history |
| Value-based analytics | Record first completed capture, result review, setup completion, later manual run, and recurring enablement separately | Extend allowlisted first-party events; record IDs/categories/counts, not prompts or outputs |

Implement a server-side journey presenter that derives stage, current blocker, and allowed primary
action from domain state. Keep client navigation preferences separate from authoritative readiness.
Avoid adding a single mutable `onboarding_complete` flag that diverges from actual prerequisites.

For late snapshot creation, promote the coherent draft in a transaction, bind proof to its exact
content, and reserve/enqueue through the existing idempotent authorization boundary. If enqueueing
or authorization fails, resume the same prepared state. Later edits must create new revisions and
invalidate affected proof explicitly; already dispatched requests remain immutable.

An exploratory “run before defining checks” mode is a separate design decision. Current capture
planning requires an active configuration and an approved matching contract
([captures.ex](/Users/pedro/projects/silent_regression/lib/silent_regression/captures.ex:201)). Option C
would need a supported new run mode and explicit promotion rules, not a bypass around those checks.

## Proposed implementation sequence

1. **Correct misleading behavior:** fix save-and-exit, unsaved-rule approval/evaluation risk, manual
   completion, stale reference messaging, and development copy. Add focused behavior checks for the
   saving and state defects.
2. **Design and validate the routing journey:** create a clickable prototype using the actual
   allow/deny example; test next-action comprehension with unfamiliar technical users. Also inspect
   a JSON workflow so routing-specific shortcuts do not become the architecture.
3. **Implement the common journey and routing recipe:** typed cases, coordinated drafts, exact
   request preview, confirmed proof proposals, and one primary action. Preserve advanced access.
4. **Integrate first run, review, and manual readiness:** reuse reference capture; make results the
   destination; handle validation failure, wrong output, wrong expectation, provider error, member
   handoff, refresh, and return-later paths explicitly.
5. **Extend recipes and supporting guidance:** structured JSON next, then grounded answers and text
   constraints, using the same authoring infrastructure with appropriate differences.
6. **Validate independent completion:** address observed confusion before inviting partners to rely
   on this as a self-guided onboarding path.

These are proposed follow-up tasks. This assessment does not change the completed implementation
task statuses or authorize deployment, provider execution, or invitations.

## Acceptance and learning

The activation milestone should be a user inspecting an evaluated result for their own request,
understanding what passed/failed, and finishing with manual execution available. Scheduling is a
separate adoption milestone. A detected failure can deliver value; “all outputs pass” is not a
sufficient or necessary definition of first value.

For a small formative study, recruit roughly five technical users who did not build the product.
Use a supplied routing workflow first to isolate interface problems, then real user workflows to
measure the work needed to define expectations. A tentative target is at least four completing the
supplied flow without facilitator instructions in about ten minutes of active interaction, excluding
credential acquisition and provider wait. This is a proposed usability threshold, not a forecast or
statistically established success rate; increase the sample and revise the target based on results.

Record:

- First-run completion and time to first reviewed result, with user input time separated from waits.
- Requests for help, backtracking, validation retries, and time after choosing a recipe.
- Whether users can explain why `rejected` is a valid output and why it is wrong for the allow case.
- Whether users can identify the next action without reading an external guide.
- Whether they understand which action makes paid provider calls and the retry allowance.
- Whether they can save an unfinished draft, return, correct a wrong check, and find the prior result.
- Whether manual mode is perceived as complete and recurring execution is understood as optional.

Explicit “save for later” is not abandonment. Derive stalling from a defined inactivity window and
later return events, and record assistance honestly. Avoid A/B conversion claims with a tiny pilot.

The onboarding skill informed the focus on first value, one clear next action, contextual guidance,
and observed independent completion. It did not require adding email campaigns, an external analytics
service, or a mandatory tutorial to this product.

## Verification note

Only this assessment document changed. The repository-required `mix precommit` check on 2026-09-21
reported 672 passing backend tests, one failure, and two excluded tests; frontend type checking,
all 64 frontend tests, and the asset build passed. The backend failure reproduced in isolation:
`test/silent_regression/monitor_operations_test.exs:277`, “daily run exhaustion waits until UTC reset
and retries the original slot,” remained waiting at the assertion on line 327 instead of scheduling
one run. This existing scheduling/test issue needs separate diagnosis; the assessment did not change
scheduling code or establish its cause. No live provider requests were part of verification.
