# Design-review hardening implementation

## Goal

Close the accepted Sol and Astra review gaps before the first external pilot without widening the
deterministic product wedge. The authoritative task status remains in
[`plans/private_alpha_implementation_plan.md`](../../plans/private_alpha_implementation_plan.md).

## Gate A — Product truth

### Task 15: review program and truthful public evidence

- Record the accepted reviews, decisions, roadmap, data-model impact, and no-wipe migration policy.
- Replace the unsupported homepage wildcard/every-claim citation example with a capability the
  current `fact_citation` evaluator actually implements.
- Add a regression test that rejects the old overclaim.

### Task 16: provider-native request artifacts

1. Add request mode/schema/template fields to setup and immutable monitor versions; backfill existing
   rows as `legacy_wrapped_v1` and default only newly created setups to `provider_native_v1`.
2. Add a strict renderer for OpenAI Responses and Anthropic Messages text templates, including
   bounded case-variable substitution, provider-owned fields, exact artifacts, and fingerprints.
3. Add request artifact/fingerprint fields to the pre-call provider-attempt ledger and verify the
   planned observation fingerprint before reserving the attempt.
4. Replace product completion delegation to `SilentRegression.Spike` with direct single-attempt Req
   transports while leaving the feasibility spike untouched.
5. Replace new-setup prompt fields with provider-native JSON authoring and render exact per-case
   secret-free previews on review; retain a clearly labeled legacy view for old setup rows.
6. Add migration, normalization, payload, capture-receipt, controller, and frontend tests.
7. Prove OpenAI and Anthropic parity with separate, explicitly authorized live smoke calls only
   after fake-provider and transport tests pass. Live calls remain a user-authorized follow-up, not
   implicit verification.

### Task 17: case-specific expectations

1. Add the bounded `case_expectation_v1` parser/evaluator, explicit `no_case_expectation` state,
   stable fingerprints, and conformance/held-out fixtures for every supported check type.
2. Add expectation schema, payload, and fingerprint to immutable case versions; add separate
   contract and expectation provenance/results to immutable capture evaluations; preserve legacy
   case fingerprints and historical rows through additive backfills.
3. Thread expectations through case normalization, version creation, capture evaluation, and
   historical contract rescoring. Make the top-level deterministic status reflect both layers while
   retaining distinct evidence and alert findings.
4. Keep case import v1 compatible and add v2 expectation imports. Add validated manual expectation
   authoring, explicit no-expectation labels, and exact review summaries beside each case.
5. Expose shared-contract and case-expectation outcomes separately in run evidence, with focused
   controller/frontend coverage and an end-to-end classifier/extraction regression proof.
6. Run migration checks against existing local history, all backend/frontend/build gates, update the
   authoritative plan, and commit focused checkpoints.

### Task 18: contract proof coverage, severity, and bounded rescore

1. Add a pure coverage analyzer for the bounded flat authoring shape. Report positive and negative
   matching fixtures for the root and every leaf, effective severity, proof status, and blockers.
2. Add owner-attributed coverage waivers tied to exact rule fingerprints. Allow upsert/removal only
   while the contract is a draft, invalidate stale waivers on semantic edits, and include the exact
   proof snapshot in approval evidence without changing behavior compatibility fingerprints.
3. Expose `critical` and `warning` severity in the structured rule editor, rule/fixture results,
   coverage matrix, readiness blockers, and sealed review. Keep nested composite authoring rejected.
4. Add durable rescore runs and pinned observation items. Seal a successor as `pending_rescore`,
   enqueue one unique serial worker, process bounded batches idempotently, and persist progress or a
   safe failure reason.
5. Activate atomically only after every pinned item succeeds: retire the prior approved contract,
   approve the candidate, and write the immutable rescore summary. Keep the prior contract active
   throughout pending or failed rescoring.
6. Add context, constraint, controller, worker/manual-mode, migration/backfill, alert-severity, and
   frontend tests. Run `mix precommit`, frontend checks, and the production asset build.

Completion: implemented in `67e20fb` and `9d1cda5`; all verification gates passed. Gate A is
complete.

## Gate B — Recoverable monitoring

### Task 19: credential successor rebinding

1. Add workspace-scoped, per-credential/model validation state and backfill exact successful legacy
   validations. Route baseline and operations readiness through that state while retaining the
   credential's last-validation fields as a safe human-readable summary.
2. Change rotation into a staged successor: preserve the predecessor until activation, reject
   duplicate pending successors, and keep legacy already-superseded predecessors recoverable.
3. Present directly attached monitors, active/draft requested models, successor lineage, and the
   reviewed-reference consequence on the credential page.
4. Add an owner-only activation operation. Validate each distinct affected model without completion
   calls, then lock the credential pair and affected monitors, reject in-progress run/reference work,
   recheck the impact snapshot, and atomically update future monitor references.
5. Preserve all historical capture/reference credential IDs. Treat credential identity as a
   conservative reviewed-reference compatibility field, pause active monitors as incompatible, and
   direct owners through replacement reference capture and ordinary schedule activation.
6. Add context, controller, frontend, migration/backfill, concurrency/blocker, and full fake-provider
   lifecycle tests. Run frontend checks, `mix precommit`, and the production asset build.

Completion: implemented in `b5ae9f5` and `eaf97fd`; all verification gates passed. Staged
successors are unavailable to new monitor setup until activation, and revoking an unactivated
successor releases the predecessor for a safe retry.

### Task 20: authentication breaker recovery

1. Add immutable, workspace-scoped authentication recovery epochs linked to the monitor,
   credential, owner, exact model-validation snapshot, and one probe capture. Preserve all existing
   capture evidence and protect epoch history from updates.
2. Add an `authentication_probe` capture kind that selects the first stable active case, permits one
   sample, zero retries, and one maximum provider call, retains compatible reference provenance, and
   is excluded from normal monitoring history and alert generation.
3. Derive breaker state from consecutive terminal manual/scheduled runs after the most recent
   successful probe. Require the monitor to be paused, the reviewed reference to remain compatible,
   no unfinished work, and a fresh exact-model validation after the latest trip before authorizing
   an epoch and enqueueing its probe.
4. Add an owner-only authenticated workspace operation with the existing run-authorization rate
   limit. Show validation/probe call boundaries, progress, success, failure category, and the exact
   next action on the monitor Operations page; members remain read-only.
5. Prove trip, same-credential repair, bounded probe, explicit resume, preserved old failures, retrip
   in a later epoch, failed-probe retry, tenancy, authorization, and purge compatibility. Run
   frontend checks, `mix precommit`, the production asset build, and additive migration audits.

Completion: implemented in `e639ce6`, `5d42d0a`, and `6403357`; all verification gates passed.
Recovery now requires fresh owner-authorized proof, performs at most one non-generative validation
request and one zero-retry completion probe, preserves every earlier failure, and never resumes
scheduled spend implicitly.

### Task 21: temporary capacity and coverage state

1. Persist a due schedule's daily-capacity reason, original intended slot, interruption time, and
   UTC retry boundary while keeping the monitor active. Leave legacy pauses unchanged.
2. Restrict periodic eligibility sweeps to persistent safety conditions. At dispatch, route daily
   run/call exhaustion into waiting and per-run overflow into an accurately labeled pause.
3. Retry the original slot through the ordinary locked run authorization, clear waiting only on
   successful schedule advancement, and retain the original slot in the run identity.
4. Add durable owner-only, preference-aware, content-free delivery evidence with per-episode
   deduplication.
5. Expose retry, original due time, last successful check, and overdue coverage in Operations;
   prevent schedule edits or manual runs from implying a cap bypass while still allowing pause.
6. Verify both daily capacity reasons, per-run overflow, UTC-boundary recovery, exact identity,
   notification behavior, closure, purge, frontend behavior, and additive migration preservation.

Completion: implemented in `0b06ca8`; all verification gates passed. Daily quota exhaustion now
recovers automatically without becoming a permanent pause or weakening the workspace limits.

### Task 22: successor workflow configuration

1. Make setup history append-only by replacing global monitor uniqueness with one partial unique
   `in_progress` row. Add immutable source-version and optional motivating-review links.
2. Start an owner-authorized successor by copying the active request mode/template, model,
   credential selection, response/generation configuration, cases, and exact expectations into a
   resumable setup; keep every active execution reference unchanged.
3. Reuse the existing setup editor and immutable completion boundary. Successor completion creates
   only a draft monitor version and never rebinds the active credential.
4. Add a successor review surface that compares source and candidate, discloses exact changed
   areas, model-proof readiness, absence of active work, contract carry-forward, and mandatory
   replacement-reference impact.
5. Activate only for an owner inside one locked transaction: verify source/candidate/setup identity,
   exact-model access, no unfinished run, and unchanged approved contract proof; clone and approve
   the contract for the candidate, retire predecessor contract/version, attach the selected
   credential, and enter `baseline_pending` with all schedule/wait fields cleared.
6. Support an optional current review decision whose action is prompt, case, or provider change;
   preserve the link through completed setup history and show it in activation review.
7. Prove leave/resume editing, active-service isolation, cross-workspace/role guards, stale preview
   rejection, atomic activation, immutable history, case-addition motivation, replacement reference,
   and schedule restoration.

Completion: implemented in `20367c0`; all verification gates passed. Active monitoring now remains
authoritative throughout successor editing and immutable candidate review, while owner activation
atomically changes future execution and enters the existing replacement-reference lifecycle.

## Gate C — Pilot usability

### Task 23: incident-centered alerting

1. Add workspace/monitor/configuration-scoped incidents and immutable occurrences. Backfill each
   legacy result alert into its own explicit legacy incident rather than inventing historical
   grouping.
2. Derive `incident_signature_v1` from content-free common identity plus failure-specific
   case/rule/check/root-cause components. Store every exact run finding as the existing immutable
   alert and attach it transactionally as an occurrence.
3. Keep one open/acknowledged episode per signature. Resolved or recovered recurrence creates a
   linked next episode; never rewrite prior lifecycle history.
4. Mark recovery only after a fully successful exact-provenance run with no finding. Record the
   recovery run and preserve every occurrence and human decision.
5. Notify recipients on incident opening and occurrence counts 5, 20, and 50 only, with durable
   content-free deduplication. Preserve personal preferences and the existing outbox/worker path.
6. Make incidents the workspace action queue and lifecycle object, add an occurrence-history page,
   page both queues, expose first/last seen and distinct affected cases/runs, and flag exceptional
   reviewed-reference provenance without suppressing findings.
7. Verify same-signature grouping, material-signature splits, idempotency, episode recurrence,
   conservative recovery, bounded high-volume delivery, tenancy/roles, legacy migration, and purge.

Completion: implemented in `85a99f4`; all verification gates passed. Incidents are now the routed
workspace lifecycle object, while every per-run alert remains exact occurrence evidence. A
50-occurrence proof retained all 50 alerts and occurrences while creating only the four configured
delivery milestones.

### Task 24: reviewed reference capture language

- Rename customer-facing baseline concepts where clarity improves without gratuitously renaming
  stable internal schemas.
- Explain provenance, operational comparison, stochastic sampling limits, and exceptional baseline
  behavior at authorization, approval, and results.
- Keep spend language precise: distinguish maximum reserved calls from actual usage, and say when a
  currency estimate is unavailable.

Completion: implemented in `bf16677`. The customer-facing method now names the four evidence
layers, bounds one-sample claims, preserves stable internal baseline identifiers, and makes
retry-inclusive reservation, actual usage, unavailable currency estimates, and exceptional
approval consequences explicit across the workflow.

### Task 25: credential-free demo and focused imports

- Add a safe deterministic demo before credential entry.
- Select the first external dataset adapter from actual design-partner formats; do not build a
  speculative universal importer.
- Measure authoring assistance and time to a proven case expectation.

Completion: implemented in `89e62d7`. The authenticated workspace demo is sealed and resumable,
uses the production deterministic engines, makes zero provider calls, and exposes the shared-pass /
case-failure wedge with exact fingerprints and evidence. Content-free events and the operator metrics
command measure step completion, time to expectation, time to completion, and demo assistance. The
generic JSON import remains supported and the product explicitly states that no external adapter is
available until a real partner format is inspected.

## Gate D — Hosted-pilot readiness

### Task 26: reproducible verification and toolchain

- Remove ignored runtime artifacts from committed test dependencies.
- Pin supported Elixir/Erlang/Node toolchains.
- Make the repository gate run backend, frontend, and production asset verification.
- Add committed CI and a repeatable browser journey.

Completion: implemented in `53dcfe8`. The repository pins Erlang/OTP 29.0.6, Elixir 1.20.4,
Node 24.4.1, and npm 11.4.2; `mix precommit` now covers backend compilation/tests, formatting,
dependency-lock hygiene, TypeScript, frontend tests, and production assets. Default verification
depends only on tracked manifests and fixtures, while private live-run artifact integrity checks are
explicitly opt-in. Committed CI also executes a disposable invitation-to-demo browser journey. The
complete gate and browser journey passed from a detached clean worktree with no ignored evidence.

### Task 27: hosted security and operations

- Apply recent authentication to sensitive credential, run, and deletion actions; decide whether
  MFA is required for the controlled pilot.
- Automate and observe purge deadlines and post-restore deletion reconciliation.
- Deploy production health, queue, scheduler-overdue, notification, and rollback monitoring.
- Execute restore and rollback drills before invitation authorization.

## Sequencing

Tasks run in numeric order unless a later task is proven independent and explicitly approved. Gate
A protects the truth of the product promise, Gate B keeps monitoring recoverable, Gate C makes the
pilot usable, and Gate D makes external hosting defensible. No first-pilot invitation occurs until
all four gates pass.

Each task follows the repository workflow: research/update the plan, implement with focused tests,
run frontend checks when applicable, run `mix precommit`, update progress, and create a focused
commit.
