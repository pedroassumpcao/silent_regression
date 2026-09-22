# Stage 3 — saved routing setup

## What changed

The practice preview and real saved setup are separate. Preview data never transfers automatically.
"Finish setup" replaces confusing preview "manual mode" wording. On-demand means a real monitor
runs when its owner selects Run now; it is not a simulated or free execution mode.

Create monitor now opens `/app/:workspace_slug/setup-drafts/new`. Classification/routing uses a
workspace-saved authoring draft. Other workflows retain the advanced setup until Stage 5.
Existing monitors, approvals, results and successor configuration flows are unchanged.

## Local walkthrough

1. Restart your existing Phoenix server (`mix phx.server`) after this change. The migration has already
   been applied locally; no data wipe is necessary. Restart is needed for raw-draft request-log filtering.
2. Open Monitors → Create monitor → **Start saved routing setup**.
3. Enter a name, model and existing validated connection. Add your own instruction and ordered
   text messages. Use `{{variable_name}}` where examples supply values. No hidden prompt is appended.
   This screen makes no provider calls. New credential validation remains a separate owner action.
4. Save and continue. Enter 2–8 distinct labels and 1–20 representative examples. Input fields are
   derived from the request placeholders. Explicitly choose the known correct label for each input.
5. Save and continue to local proof. Each input has three **synthetic proposals**: its expected label,
   another allowed label, and an output outside the label set. Inspect shared and case results
   independently, then explicitly confirm only judgments you agree with. Reject by going back to
   correct the configuration; never confirm solely because the evaluator agrees.
6. Inspect the exact, secret-free provider request for each saved example. This uses the production
   request builder, including its existing provider/model limits and supported-field restrictions.
7. **Prepare first-run review** atomically creates the immutable monitor/case version and a shared
   contract draft with reviewed fixtures. This is a configuration boundary, **not Finish setup** and
   **not authorization to spend**. The saved authoring/review record becomes immutable.
8. For now, continue on the existing check-approval and baseline screens. Owner check approval,
   explicit bounded provider authorization, actual result review, reference approval, and on-demand
   activation are still required. Stage 4 will integrate those actions into this guided journey.

Save and exit preserves incomplete fields, invalid native JSON, blank examples and partial proof
review. Resume from the Monitors dashboard. Saves are explicit, not background autosave. Another
tab/teammate changing the draft produces a conflict: copy needed edits, reload the latest saved
version, then reapply them. The UI never silently retries your old edit against a new revision.

Changing draft content clears proof review. Request/native editors preserve separate content;
switching editors does not convert or delete either, and only the selected editor is executed.

## Boundaries and data model

- `guided_setup_drafts`: schema/recipe version, bounded raw input, monotonic revision, explicit
  reviewer identities/timestamps and fingerprints, optional sealed monitor ID/time.
- Saves accept incomplete authoring, but progression and sealing use the existing request, version,
  case and deterministic validators. Both production evaluation engines produce the proof results.
- Requests support the existing bounded text-message native format, not arbitrary provider APIs.
  Typed variables are text values; advanced legacy authoring remains available for other workflows.
- Whole-label matching uses the existing Unicode NFKC, case-folding and punctuation/whitespace
  normalization. It does not perform semantic classification or infer factual correctness.
- Synthetic proof is explicitly reviewed evidence about configured checks, not observed model quality
  or independent human-ground-truth research. Confirmations retain the exact synthetic output and
  input/expectation/configuration fingerprints; audit metadata excludes customer content.
- Rows are scoped by workspace, revision-checked under lock, and immutable after sealing. Duplicate
  handoffs return the same monitor. The transaction rechecks the selected credential and rolls back
  every monitor/version/contract write on failure. No job is enqueued by authoring or handoff.
- Workspace deletion includes drafts; the raw request payload is filtered from Phoenix parameter logs.
- No existing data was deleted or rewritten. No dependencies or permission changes were needed.

## Verification (2026-09-21 local time)

`mix precommit`: 694 backend tests passed (2 existing private-artifact exclusions), 104 frontend
tests passed, TypeScript/formatting/dependency advisory audit/assets passed.

An isolated port-4001 browser server with Oban queues/plugins disabled verified incomplete save/resume,
typed examples, shared-vs-case proof, partial review recovery, full review and first-run handoff screen.
The exact allow/deny request artifacts were inspected; heading focus and a 390px viewport were checked
without horizontal page overflow. The server was stopped afterward. No live call was made and no
existing monitor was mutated. Actual sealing/rollback/owner boundaries are covered by HTTP/context tests.

One clearly named local draft, `Stage 3 browser check — no calls`, remains unsealed for inspection.
Its review activity was performed as an implementation test, not as independent founder/partner review.

Console caveat: navigation-time `MutationObserver.observe` errors recurred, without a source URL in
the captured logs. Application JS has no matching observer usage; origin is unconfirmed. The tested
interactions succeeded, but this is not a clean-console claim. Unfamiliar-user research remains Stage 6.

Architecture reference: [Ecto changesets and concurrency](https://ecto.hexdocs.pm/Ecto.Changeset.html#optimistic_lock/3).
This context uses an explicit expected revision under a transaction row lock to coordinate saves,
proof review and multi-record sealing; it does not depend on browser state as the authority.
