# Saved routing setup — Stages 3 and 4

## What changed

The practice preview and real saved setup are separate. Preview data never transfers automatically.
"Finish setup" replaces confusing preview "manual mode" wording. On-demand means a real monitor
runs when its owner selects Run now; it is not a simulated or free execution mode.

Create monitor now opens `/app/:workspace_slug/setup-drafts/new`. Classification/routing uses a
workspace-saved authoring draft. Other workflows retain the advanced setup until Stage 5.
Existing monitors and successor configuration flows remain available. Run history now also includes
initial and replacement reference captures; they are not mislabeled as comparisons to an earlier reference.

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
8. Stay in the guided first-run page. The owner reviews the exact saved checks/proof, checks the
   confirmation and selects **Approve checks and continue**. This makes no provider calls.
9. If needed, select **Verify exact model access**. This explicitly contacts the metadata endpoint;
   it is separate from completion authorization and requires recent authentication.
10. Read the provider/model, connection, planned/maximum calls, retry allowance and token ceilings.
    Inspect saved request artifacts if needed. Check explicit spending consent and select
    **Authorize first run**. One sample is captured per input. Input tokens are also billed; the token
    ceilings are not a guaranteed dollar price. This is a real call when using normal providers.
11. Wait for the same page to show results. Refreshing, leaving or submitting authorization twice
    resumes the same pending capture. It does not silently authorize a second capture.
12. Read **input → expected → actual → reason** for every example, including correct rejections.
    Shared-label validity and per-input correctness are separate. Inspect completion/provider errors,
    usage and the full evidence link when needed. A deterministic pass is not universal semantic assurance.
13. Confirm result review and select **Finish setup** when the capture is normally approvable. This
    atomically approves that exact capture as the reference and enables on-demand monitoring. It makes
    no additional provider call and scheduling remains off. No redundant run is needed to finish.
14. **Run again** leads to operations, where you review current limits before authorizing more calls.
    **Schedule checks (optional)** is secondary. History already contains the first capture.

Members can inspect and explicitly record result review, but must share the page URL with an owner
for approvals, provider authorization and finish. The app does not automatically contact the owner.
Opening the page or finishing capture does not count as a human review.

### Recovery after sealing

- Wrong checks: use advanced contract authoring/revision; new semantics require compatible reference
  evidence. The original guided proof cannot approve an advanced, changed configuration silently.
- Wrong request/input/expected label: **Create corrected setup draft** copies only the raw authoring
  values to a new unsealed draft and clears all proof review. It will create a **separate monitor**;
  original history is untouched, and any existing capture/schedule is not stopped. For in-place
  successor versions of an existing monitor, the established advanced workflow remains available.
- Wrong output/provider failure: inspect the cause, confirm review, then **Reject this capture and
  prepare a retry**. Rejection preserves history and makes no call. A new preview and spending consent
  are required before a new capture. Unknown/incomplete results cannot become a normal reference.
- Exceptional acceptance remains an explicit advanced-reference decision with its existing rationale
  requirements. The guided Finish button never quietly accepts known deterministic failures.

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

Stage 4 adds no capture/completion table. Existing baseline snapshots and jobs are authoritative.
An additive event-name migration permits `guided_setup.results_reviewed`; its properties contain
only snapshot ID and review fingerprint. Context locks follow workspace → monitor → snapshots,
then reuse the existing baseline/operations APIs and their separate audit entries. Finish/reject
require the exact displayed terminal snapshot and evidence fingerprint plus explicit confirmation.
Duplicate finish cannot reset a subsequently enabled schedule. GET and polling have no write effects.

Authoring, review and correction routes are under `/app/:workspace_slug` with `:browser`,
`:authenticated`, `:workspace_scope`. Model verification, capture authorization and finish also use
`:recent_authentication`. Owner checks are enforced in contexts, not only button visibility.

### First-value measurement

| Evidence | Meaning / source |
| --- | --- |
| `first_capture_completed_at` | Earliest terminal baseline capture, successful or failed; capture timestamps |
| `first_guided_result_reviewed_at` | First explicit fingerprint-bound guided review event; deduplicated per evidence identity |
| `first_monitor_activated_at` | Existing `monitor.activated` event, including on-demand/manual readiness |
| `first_later_run_completed_at` | Earliest completed manual or scheduled monitoring run |
| `first_recurring_enabled_at` | Existing recurring-only `schedule.activated` event |

These are operational/product-learning milestones, not retention or accuracy claims. A setup-review
confirmation is distinct from a structured per-observation correctness judgment. Advanced-path reviews
are not fabricated into the guided event, and historical page views are not backfilled as review.

## Stage 4 verification (2026-09-21 local / 2026-09-22 UTC)

`mix precommit`: 708 backend tests passed (2 existing exclusions), 111 frontend tests passed;
TypeScript, formatting, dependency advisory audit and asset build passed.

Browser smoke used `MIX_ENV=test`, a separate `silent_regression_test_guided_stage4` database and
port 4002, with only fake OpenAI/Anthropic adapters, capture workers, and no scheduler/notification
queues. Verified approval → model verification → bounded authorization → refresh/resume → two
passing outputs → finish → one capture in history. The narrow 390px page had no horizontal overflow
and the heading received focus. Browser logs contained no errors/warnings during this isolated run.
This is implementation verification, **not** independent user research or provider compatibility evidence.
No real provider calls, real-key usage, changes to existing development monitors or database wipe.

HTTP/context tests also cover rejected retries and stale result IDs, failed/incomplete outputs,
member/cross-workspace boundaries, recent authentication, changed rules, credential-revocation rollback,
duplicate finish and scheduling preservation. Frontend tests bind consent to displayed identities.

Implementation references: [Inertia polling](https://inertiajs.com/docs/v2/polling),
[Ecto transactions](https://ecto.hexdocs.pm/Ecto.Repo.html#c:transaction/2),
[shadcn buttons](https://ui.shadcn.com/docs/components/radix/button). The installed Inertia v2 polling
API is reused; no dependency upgrade is part of this stage.

## Historical Stage 3 verification (2026-09-21 local time)

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
