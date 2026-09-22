# Stage 2 — guided setup prototype and review script

Status: implemented and technically verified; founder review in progress. No unfamiliar-user study
has been performed. This document records the design, boundaries, evidence, and next decisions.

## Open the preview

With the local Phoenix server running, sign in to your existing workspace and open:

`http://localhost:4000/app/local-design-partner-20260920/setup-preview`

Other workspaces use `/app/:workspace_slug/setup-preview`. The GET is in the existing `:browser`,
`:authenticated`, `:workspace_scope` pipeline. Both members and owners may inspect it. Cross-workspace
requests still return 404. There is no preview mutation endpoint or permission escalation.

The production New monitor journey is unchanged. We deliberately did not add another prominent
button to that journey while testing this separate design.

## What this prototype does—and does not do

- Step 0 chooses the simulation before the five connected stages: request → examples → reviewed proof → bounded authorization → result/manual
  completion. One primary next action per stage, with Back and Save and exit kept secondary.
- Fictional allow/deny inputs, a fixed mock request/model, editable monitor name and expected answers.
  Credentials, arbitrary prompts, real provider/model choice, import, and new case creation are NOT
  implemented here. Those remain production Stage 3 work; never paste confidential content here.
- Routing and a structured JSON `decision` field use the same interaction layout. Output evidence is
  computed by a tiny local simulation, NOT the production deterministic engines or provider APIs.
- The reviewed examples are fixed, proposed human judgments for the stated sample policy. A reviewer
  must confirm all four. Disagreement between an expectation and the proposed proof blocks progression;
  the prototype does not invent a new ground truth to make the checks pass.
- All authoring text (including blank/invalid expectations) and partial proof confirmations can be
  explicitly saved to `sessionStorage`, scoped by user/workspace. Saves survive reload in this tab.
  This is not encrypted server storage, cross-device collaboration, or durable product saving. Closing
  the tab normally ends its storage session; browser restore behavior may retain it. Do not rely on
  tab closure as secure deletion. Other tabs/devices are not synchronized.
- Continue/Back also save the draft. Failed storage writes keep the current screen and edits, report
  an error, and do not claim success. Unknown/corrupt versions are ignored; stale proof is reopened.
  Inertia/unload guards warn about unsaved edits; browser Back is not a durable-save mechanism.
- Authorization and final result confirmation deliberately reset on leaving/returning or reloading
  their stage. Saved authoring/review evidence does not authorize another execution automatically.
- No provider call, credential access, real monitor creation, baseline approval, invitation, owner
  notification, activation, schedule, or product analytics event occurs. The UI's role switch is a
  simulated handoff, not a change to the signed-in user's permissions.
- The last five mock attempts retain their own expected/actual values. This limited, replaceable
  tab-local history is NOT a substitute for the real append-only execution records.

## Default routing walkthrough

0. **Choose simulation:** select Classification / routing and Passing outputs, then Start simulation.
   Output shape and scenario are chosen together before starting; neither control appears during
   Steps 1–5. These choices are for this prototype only, not how real monitor outcomes are determined.
1. **Connect request:** read the mock policy and optionally change the name. Expand rendered requests
   to see message order, exact input interpolation, and the output-token cap. Continue to examples.
2. **Add examples:** `action=allow` expects `approved`; `action=deny` expects `rejected`. The latter is
   a correct business decision, not a failed quality check. These are user-known answers.
3. **Confirm checks:** distinguish the allowed label set (shared) from the right answer for an input
   (case-specific). Inspect the expected and actual columns, then confirm all four proposed judgments:

   | Input | Proposed output | Shared | Case | Proposed overall judgment |
   | --- | --- | --- | --- | --- |
   | allow | approved | Pass | Pass | Pass |
   | deny | rejected | Pass | Pass | Pass |
   | allow | maybe | Fail | Fail | Fail |
   | allow | rejected | Pass | Fail | Fail |

4. **Run once:** inspect 2 inputs × 1 sample, 2 planned calls and a proposed 4-call maximum (one retry
   per input). Metadata validation would be separate. The real cost is unknown until a real provider
   is chosen; the preview always costs $0. Explicitly authorize the simulation, then run it.
5. **Review & finish:** inspect both expected/actual/reason rows. Confirm review, then choose **Finish setup**. In the real flow this means on-demand
   mode. Scheduling stays off. Another run must go through fresh authorization. In production, checks
   approval, capture authorization, reference approval and manual activation retain separate audits.

## Exercise the failure and return paths

Use **Start a different simulation** to return to Step 0. Choose output shape/scenario, review the
reset warning, then explicitly press **Start new simulation**. This resets the current tab's name,
expected answers, proof, progress and mock history, and starts Step 1. Merely selecting an option
changes nothing in the current draft. **Keep current simulation** cancels and returns to the same
screen with edits intact. If saving the replacement fails, the old draft remains available.
Existing saved journeys from before this revision resume without being reset.

Retrying after a simulated upstream fix is different: it retains the chosen scenario and history,
and requires fresh authorization. It no longer silently relabels Wrong allowed label as Passing outputs.
These controls are for reviewers, not proposed customer UI.

| Scenario | Try | Expected behavior |
| --- | --- | --- |
| Wrong allowed label | Keep the correct expectations; complete the proof/run | Shared pass, case fail for allow. Finish is unavailable. Choose output wrong to simulate an upstream fix, then explicitly authorize retry; old failed evidence remains. The product does not repair the model. |
| Wrong expectation | Review the prefilled wrong expectation for allow | Proof conflicts before any authorization. Correct to approved, review all four examples again, then continue. |
| Wrong expectation discovered at results | From a wrong-output result choose “My expectation is wrong” | Return to the examples unchanged (never auto-copy the model's answer), clear prior proof, and require new review. A knowingly wrong expectation still cannot pass the fixed scenario's proof. |
| Provider failure | Complete proof and authorize | No output/quality judgment/reference. Resolve the simulated provider issue, review a new authorization, and retry. Next mock attempt succeeds; the failure remains in history. |
| Member → owner | Complete examples and proof | No run control on the simulated member screen. Preview owner review, inspect the summary, explicitly authorize. No email/message is sent and the real role does not change. |
| Save/return | Clear one expected answer; Save and exit; reload | Empty value survives. Continue explains the allowed values until corrected. Also save partway through proof and verify checked judgments survive. |
| Revise after review | Go back and edit an expected value | Clear proof confirmations/identity and final readiness; retain historical attempts. Re-review before a new run. |

## Structured JSON architecture check

Select **Structured JSON** in Step 0, start the simulation, then repeat the journey. The example expects
`{"decision":"approved"}` for allow and `{"decision":"rejected"}` for deny. Invalid type
`{"decision":42}` fails shared and case checks. A well-formed but wrong decision passes shared
checks and fails the input-specific value expectation. Whitespace/key order are not full-string
equality checks; the simulation reads the declared field. Extra fields are not prohibited here.

This confirms that the layout can describe shape and per-input correctness separately. It does NOT
validate general JSON Schema, nested extraction workflows, ranges, arrays, or semantic factuality.
Do not promote the prototype's string-only `Example.expected` to the production draft schema.

| Concern | Routing recipe | Structured JSON recipe | Production implication |
| --- | --- | --- | --- |
| Exact request | Label-only instruction | JSON-object instruction | Recipe must not rewrite a supplied prompt; keep ordered provider-native request data separate from check authoring. |
| Shared validity | Allowed exact labels | Required paths, types and allowed values | Recipe-versioned typed editor compiles to existing supported deterministic rules. |
| Expected behavior | One label per input | Values/ranges at declared JSON paths | Bounded typed case expectations, not one universal text field or whole-output equality. |
| Proof | Case-linked proposed output | Case-linked JSON output | Both evaluator results plus independent user judgment, bound to exact case/check/output identities. |
| Correction | Change label or request intentionally | Change shape/path/value intentionally | Invalidate affected review; preserve the historical execution's old semantics. |
| Completion | Reviewed result + manual readiness | Same | Shared server orchestration; do not duplicate capture/approval logic by recipe. |

A non-enum stress case for Stage 3/5 design is invoice extraction: required numeric `total`, string
`currency`, and per-input `total=129.99`, `currency=USD`. The same expected/actual/reason layout fits,
but the editor needs typed paths, numeric comparison/tolerance rules, and field-level errors. Array
selection, optional/null semantics and unsupported schema keywords must be surfaced explicitly.
They cannot be hidden behind this prototype's simple decision field. This is a design check, not
implemented extraction coverage.

No database migration/reset is required for Stage 2. Stage 3 still needs bounded raw draft data,
recipe/version, concurrency/revision identity, case-linked proof and authoritative server-derived
progress; Stage 4 still needs real owner authorization, idempotent capture, result recovery, and
transactional reference/manual readiness integration. Prefer additive schema changes; reset local
data only if a concrete migration requires it.

## Founder review and unfamiliar-user script

### Founder feedback — 2026-09-21

- **Observation:** the staged navigation is easier to understand, but changing the scenario from a
  later step causes a confusing restart.
- **Request/decision:** scenario and output-shape selection belong in a distinct Step 0. Implemented
  a separate selection screen plus an explicit, cancellable restart, preserving current work until
  replacement succeeds. This applies onboarding guidance by separating the reviewer's scenario choice
  from the monitor-setup journey itself.
- **Verification:** added coverage for initial selection, multi-choice start, cancellation with unsaved
  edits, history reset only on explicit confirmation, failed-save preservation and old-draft recovery.
  Simulated retries preserve the scenario identity. Full checks passed 679 backend tests (2 existing
  exclusions), 99 frontend tests, TypeScript, audit and build. Browser checks confirmed cancellation
  returns to the previous step and explicit restart begins at Step 1; Step 0 has no horizontal overflow
  at 390px. The temporary viewport override was reset.
- **Still pending:** founder confirmation of the revised interaction; unfamiliar-user comprehension
  research remains separate. Positive feedback on navigation is not approval of every other criterion.

Record further comments here with date, scenario, stage, observed confusion, proposed adjustment and
decision; do not silently change the historical UX assessment.

For the first review, do the default routing journey without consulting the detailed instructions
above, then try Wrong allowed label and Structured JSON. Answer:

1. At each step, is the next action obvious? Which wording required interpretation?
2. Can you explain why deny → rejected passes, but allow → rejected fails?
3. Before running, do you know what is authorized, the maximum call count, and what remains optional?
4. On failure, can you distinguish a wrong output from a wrong expectation and a provider failure?
5. At the end, would you know how to run manually without setting a schedule?

When an unfamiliar technical participant is available, give only this task:

> Protect a workflow that approves allow actions and rejects deny actions. Set up two example
> checks, review a first result, and leave it ready to run manually without a recurring schedule.
> Use fictional data; this is a zero-call simulation.

Ask them to think aloud. Do not teach the rules first. Observe time per stage, backtracking, first
hesitation, requests for help, interpretation of pass/fail, call-ceiling comprehension, and perceived
completion. Then give the wrong-output scenario and ask them to recover. Repeat with JSON only after
the routing attempt. Record assistance separately from unaided success; simulated runtime is instant
and cannot establish real time-to-value. Ask for consent before recording any session.

Use findings to decide whether to simplify proof presentation, change labels, or adjust the stage
boundaries before Stage 3. Larger independent validation remains Stage 6. Automated tests and founder
familiarity do not count as evidence that unfamiliar customers can onboard successfully.

## Technical verification — 2026-09-21

- Component/model tests cover both recipes, all recovery scenarios, zero fetch/XHR, partial saves,
  failed storage, reload, stale review, bounded history, role simulation and namespace isolation.
- Controller tests cover authentication, tenant isolation, member read access and no monitor creation.
- Isolated in-app browser: normal login to existing local test workspace using the development-only
  mailbox; routing from start through manual completion; edited and blank-input save/reload; JSON
  wrong-label failure → fresh authorization → corrected mock result → completion and retained history.
- Desktop (1280px) and mobile (390px) checked; no horizontal overflow at the inspected proof/result/
  completion screens, focus moved to the new stage heading, viewport override reset afterward.
- Browser log caveat: one MutationObserver error occurred during the sign-in/navigation portion
  (source unconfirmed). It did not recur during the complete prototype journeys or final reload;
  no MutationObserver is defined in the application JS source. Do not report a universally clean
  browser console based on this run.
- No live provider calls, credential validation, database reset, real monitor changes, external mail,
  deployment, or invitations. Local sign-in generated its normal session/audit records.

## Design references

- [W3C multi-page forms](https://www.w3.org/WAI/tutorials/forms/multi-page/) supports logical step
  grouping, clear progress and optional-stage labeling. Applied as design guidance, not conversion data.
- [shadcn Button](https://ui.shadcn.com/docs/components/radix/button) and
  [Card](https://ui.shadcn.com/docs/components/radix/card) references informed composition using the
  repository's existing Radix-based primitives; no library install or upgrade was needed.
- Internal inputs: [UX assessment](UX_ASSESSMENT.md), [approved roadmap](IMPLEMENTATION.md),
  [progress/history](PROGRESS.md). Onboarding guidance prioritizes an understood first result and one
  next action, without claims of measured activation improvement.
