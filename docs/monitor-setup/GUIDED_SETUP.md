# Saved monitor setup — Stages 3–5

## What changed

The practice preview and real saved setup are separate. Preview data never transfers automatically.
"Finish setup" replaces confusing preview "manual mode" wording. On-demand means a real monitor
runs when its owner selects Run now; it is not a simulated or free execution mode.

Create monitor now opens `/app/:workspace_slug/setup-drafts/new`. Step 0 selects classification/routing,
structured JSON, answers with source IDs, or required/prohibited text. Each uses a workspace-saved
draft and the same request → examples → proof → first run → review/finish flow.
Advanced setup remains available for supported rules beyond these deliberately bounded editors.
Existing monitors and successor configuration flows remain available. Run history now also includes
initial and replacement reference captures; they are not mislabeled as comparisons to an earlier reference.

## Local walkthrough

For an unfamiliar-user session without live calls, use the separate
[Stage 6 study kit](usability/README.md). It runs this saved journey against fake providers in its
own test database; do not substitute the historical practice preview for current-product evidence.

1. Restart your existing Phoenix server (`mix phx.server`) after this change. The migration has already
   been applied locally; no data wipe is necessary. Restart is needed for raw-draft request-log filtering.
2. Open Monitors → Create monitor → select an output shape in **Step 0** → **Start saved setup**.
   This starts an empty real draft. Changing recipes later starts a separate draft; it never converts
   or deletes this one, and never transfers review. The practice preview is separate and zero-call.
3. Enter a name, model and existing validated connection. Add your own instruction and ordered
   text messages. Use `{{variable_name}}` where examples supply values. No hidden prompt is appended.
   This screen makes no provider calls. New credential validation remains a separate owner action.
4. Save and continue. Configure shared rules and 1–20 representative examples using the recipe
   instructions below. Inputs come from request placeholders. Independently declare each expected
   answer; illustrative help text is not automatically inserted as your requirements.
5. Save and continue to local proof. Routing has three **synthetic proposals** per input: its expected
   label, another allowed label, and an output outside the set. Other recipes include positive and
   case-negative outputs, plus missing/wrong fields, citations, attribution or prohibited text.
   Inspect the listed expected shared-rule failures and shared/case results
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
    Shared-rule validity and per-input expectations are separate. Inspect completion/provider errors,
    usage and the full evidence link when needed. A deterministic pass is not universal semantic assurance.
13. Confirm result review and select **Finish setup** when the capture is normally approvable. This
    atomically approves that exact capture as the reference and enables on-demand monitoring. It makes
    no additional provider call and scheduling remains off. No redundant run is needed to finish.
14. **Run again** leads to operations, where you review current limits before authorizing more calls.
    **Schedule checks (optional)** is secondary. History already contains the first capture.

Members can inspect and explicitly record result review, but must share the page URL with an owner
for approvals, provider authorization and finish. The app does not automatically contact the owner.
Opening the page or finishing capture does not count as a human review.

### What to enter for each recipe

| Recipe | Shared declarations | Per-example expectation | Important limit |
| --- | --- | --- | --- |
| Routing | 2–8 allowed labels | One correct label | Normalized whole-output match, not classification reasoning |
| JSON | 1–4 required top-level scalar fields and their types | Each field's known value; numeric target ± tolerance | Extra keys allowed; not JSON Schema or factual verification |
| Sources | 1–8 allowed IDs; optional required IDs and one literal attribution group | Exact non-empty source-ID set | Bracket syntax and placement only; not truth or entailment |
| Text | Required alternatives and/or prohibited alternatives | Literal answer alternatives for this input | Normalized literal presence; not paraphrase or contradiction detection |

#### Structured JSON example

Use your own request that asks for raw JSON, for example an invoice extraction request with
`{{invoice}}`. No JSON-mode or hidden instruction is added by the recipe.

1. Add required field `total`, type `number`, and `paid`, type `boolean`.
2. Add an example with known invoice input. Enter target `12.5`, tolerance `0.01`, and explicitly
   select `false` for `paid`. This permits totals 12.49–12.51 inclusive, not a string `"12.5"`.
3. Review the proof: a correctly typed wrong total passes shared checks but fails this case; a missing
   field or wrong type fails shared checks too. Every configured shared rule has passing/failing proof.
4. In the first result, read the declared paths/targets and actual JSON side by side—not only badges.

Supported types: string, number, integer, boolean. String values are exact, without text normalization;
use **Use empty string** when that is the known value. Numeric tolerance 0 uses mathematical numeric
equality; `integer` additionally requires an integer representation. Numeric targets/tolerances have
magnitude ≤1,000,000; tolerance cannot be negative. Strings ≤120 bytes. Field names are ≤40 characters,
letters/digits/underscores beginning with a letter/underscore. Required means a field must exist.

This editor does **not** accept JSON Schema, nested paths, arrays/objects/null, optional fields, enum
declarations, regex/formats or extra-key rejection. Some additional deterministic rules exist in advanced
authoring, but that is not a full JSON Schema implementation either. Unsupported settings fail closed.
Renaming/removing/changing a field type clears the affected example values, not unrelated fields;
adding a field never silently assigns a known answer. Save and exit retains partial numbers such as `12.`.

#### Sources example

Use a request with your own question and frozen context, such as `{{question}}` and
`{{frozen_context}}`. The monitor does not retrieve documents or verify that context labels exist.

1. Allow IDs `billing` and `refunds` (one per line, no brackets).
2. For a refund question, enter the exact expected set `refunds`. Every listed ID is required and
   any additional detected ID fails this case—even if it is globally allowed.
3. If all answers must include the same declaration, optionally add phrase `Refunds within 30 days`,
   attribution source `refunds`, and window `100`. Every case must then include that source.
4. Review `Refunds within 30 days [refunds]` versus `[refunds] Refunds within 30 days`: the second
   has the right ID set but fails trailing attribution. These are synthetic syntax examples, not
   evidence that the policy is true. A globally allowed but wrong case-specific ID also fails the case.

IDs are case-sensitive, ≤40 characters, letters/digits plus `. _ : -`, starting with a letter/digit.
Outputs use `[refunds]`; Markdown links are excluded by the existing extractor. The complete literal
attribution phrase must fit before the citation within 1–500 characters, without `. ! ?` or a newline
separating it. Attribution alternatives are normalized literals (≤8, ≤120 bytes each). Attribution is
shared across every case, not an inferred per-claim verifier. Empty citation sets, arbitrary citation
formats, multiple attribution groups and semantic grounding are outside this guided recipe.

#### Text example

1. Shared required alternatives: `Consult a professional` and `Seek professional advice`.
2. Shared prohibited alternative: `guaranteed outcome`.
3. For an input with insufficient evidence, case alternatives: `cannot determine` and
   `insufficient information`.
4. Review the combined passing output, disclosure-only output (shared pass/case fail), prohibited
   text (shared fail, possibly case pass), and missing language. Confirm only your intended judgments.

Each required list means **any one** alternative, not all lines. Any prohibited match fails.
At least one shared list is required. Each case requires a nonempty list. Up to 8 alternatives/list,
120 bytes/alternative; blank lines ignored and normalized duplicates rejected. Unicode NFKC, case,
punctuation/whitespace normalization and word boundaries apply. `CANNOT—DETERMINE` can match;
`I do not know` is not inferred as equivalent. Negating a phrase does not make its literal occurrence
disappear. This is intentionally not general answer correctness.

### Recovery after sealing

- Wrong checks: use advanced contract authoring/revision; new semantics require compatible reference
  evidence. The original guided proof cannot approve an advanced, changed configuration silently.
- Wrong request/input/expected answer: **Create corrected setup draft** preserves the recipe and copies only the raw authoring
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

Stage 5 expands only the draft recipe allowlist constraint. Routing v1's raw shape, compiled requests,
contract semantics and existing proof fingerprints are unchanged. New JSON/source/text v1 recipes compile
to existing shared rules. A bounded `required_text` case-expectation type was added to `case_expectation_v1`
using the existing literal matcher; all previous case types/fingerprints and historical evaluations remain
unchanged. Advanced imports may declare `{id, type: "required_text", alternatives: [...]}` in a case's
checks; this is not the abstention detector. Rolling application code back cannot interpret that new type.

New recipe proposals are capped at 60 with an 85 KB estimated review-evidence budget. Shared fixtures
store a reviewed representative for each distinct shared-rule result, at most 20; full per-case review
stays in the immutable draft. Every critical shared rule needs both branches; no automatic coverage
waiver. Proposals are not exhaustive semantic or alternative-combination tests. Conflicting declarations
or an unprovable bounded combination block progression with guidance instead of changing the requirement.

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
