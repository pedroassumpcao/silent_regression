# Design-review hardening progress

## Current status

- Program: in progress
- Current gate: Gate B — Recoverable monitoring
- Current task: Task 23 — incident-centered alerting (next)
- Local-data policy: preserve and migrate; no wipe authorized or required
- External pilot: blocked until Gates A–D are complete

## Task status

| Task | Deliverable | Status |
| --- | --- | --- |
| 15 | Review program and truthful public evidence | Complete (`d49b997`) |
| 16 | Provider-native request artifacts | Complete |
| 17 | Case-specific expectations | Complete |
| 18 | Contract proof coverage, severity, and bounded rescore | Complete |
| 19 | Credential successor rebinding | Complete (`b5ae9f5`, `eaf97fd`) |
| 20 | Authentication breaker recovery | Complete (`e639ce6`, `5d42d0a`, `6403357`) |
| 21 | Temporary capacity and coverage state | Complete (`0b06ca8`) |
| 22 | Successor workflow configuration | Complete (`20367c0`) |
| 23 | Incident-centered alerting | Not started |
| 24 | Reviewed reference capture language | Not started |
| 25 | Credential-free demo and focused imports | Not started |
| 26 | Reproducible verification and toolchain | Not started |
| 27 | Hosted security and operations | Not started |

## Task 15 log

- [x] Archive and assess both design reviews.
- [x] Record the accepted decisions and four pre-pilot gates.
- [x] Map expected schema changes and choose additive migration over a local reset.
- [x] Replace the unsupported public citation example.
- [x] Add a public-page regression assertion for the supported claim.
- [x] Run focused verification and `mix precommit` (3 focused tests; 598 full tests).
- [x] Record completion in the authoritative plan.

Task 15 implementation commit: `d49b997`.

## Task 16 log

- [x] Reconfirm the accepted provider-native request decision and first-pilot boundary.
- [x] Inspect existing monitor/setup schemas, immutable triggers, capture planning, provider adapters,
  frontend authoring, and execution evidence.
- [x] Confirm current OpenAI Responses and Anthropic Messages request structures from official docs.
- [x] Finalize and document the provider-native request schema and migration behavior.
- [x] Implement additive persistence and frozen `legacy_wrapped_v1` behavior.
- [x] Implement strict rendering, exact preview/fingerprinting, and direct product provider transport.
- [x] Update setup and review UX.
- [x] Add migration, payload, capture-receipt, controller, and frontend tests.
- [x] Run all local gates and record focused commits.
- [x] Run the separately authorized OpenAI live smoke call.
- [x] Run the separately authorized Anthropic live smoke call.

Local implementation commits:

- `ffb1675` — version provider request artifacts and additive legacy-preserving schema
- `7123ea7` — direct provider transport and immutable pre-call receipts
- `a6b909f` — provider-native setup authoring and exact per-case previews
- `d26177a` — request receipt identity in run evidence
- `1805ee7` — local-gate evidence and task-plan checkpoint
- `38eec36` — separately authorized OpenAI live-smoke evidence

Local gates passed on 2026-09-19 (America/Chicago): 608 Elixir tests, 46 frontend tests,
TypeScript checking, and `mix assets.build`. The separately authorized OpenAI `gpt-5.6-luna`
smoke passed in one call and one attempt with exact model provenance, a complete response, a passing
contract, 32 input tokens, 5 output tokens, and 2,342 ms latency. The separately authorized
Anthropic `claude-haiku-4-5-20251001` smoke also passed in one call and one attempt with exact model
provenance, a complete response, a passing contract, 30 input tokens, 4 output tokens, and 800 ms
latency. Task 16 is complete.

## Task 17 log

- [x] Reconfirm the accepted case-specific correctness boundary and inspect case, capture,
  evaluator, rescore, setup/import, result, and alert paths.
- [x] Finalize the bounded expectation schema and legacy/import compatibility policy.
- [x] Implement expectation parsing, evaluation, fingerprints, and fixtures.
- [x] Add additive immutable persistence and legacy backfills.
- [x] Bind capture and historical-rescore evaluation to exact case expectations.
- [x] Extend setup/import and review authoring.
- [x] Present expectation evidence separately in baseline review, run history, run detail, and alerts.
- [x] Prove expectation-only failures end to end while the shared contract passes.
- [x] Run all verification gates and record focused commits.

Local implementation commits:

- `8308389` — Task 17 research, schema decision, and execution checklist
- `d19d9e9` — bounded parser/evaluator and conformance/held-out fixtures
- `736c64f` — additive immutable persistence, capture evaluation, rescore, and import compatibility
- `c0e081a` — manual/import authoring and exact setup review
- `3ccee78` — separate result evidence and case-expectation alert category

The two additive migrations preserved all local history. The backfill audit found 4/4 existing case
versions in explicit `no_case_expectation`, 14/14 existing evaluations with their original status
preserved as `contract_status`, and the immutable-evaluation trigger still installed. Case import v1
remains accepted and produces the explicit no-expectation state; import v2 carries optional bounded
expectations.

Local gates passed on 2026-09-19 (America/Chicago): 619 Elixir tests, 48 frontend tests,
TypeScript checking, and `mix assets.build`. End-to-end coverage proves that `rejected` can pass the
shared allowed-label contract while failing a case that expects `approved`, producing only a
distinct `case_expectation_failure` alert. Task 17 is complete.

## Task 18 log

- [x] Reconfirm the review findings and inspect current fixture readiness, severity support,
  synchronous rescore, lifecycle triggers, Oban configuration, and authoring surfaces.
- [x] Define rule-level proof, critical/warning policy, exact-rule waiver binding, and the bounded
  flat-composite boundary.
- [x] Define a pinned durable rescore/activation lifecycle that keeps the prior contract active.
- [x] Implement coverage analysis, owner waivers, and proof fingerprints.
- [x] Expose severity and coverage in authoring/review.
- [x] Implement durable bounded rescore state, workers, progress, failure, and atomic activation.
- [x] Run migration audits and all verification gates; record focused commits.

Decisions:

- Only evaluator-confirmed, fully matching fixtures count as proof.
- Critical leaf rules require positive and negative proof; warning gaps remain visible but do not
  block approval. Missing severity continues to mean critical.
- Waivers require an owner, a rationale, and the exact rule fingerprint; semantic changes make them
  stale rather than silently carrying them forward.
- Initial contracts with no history still approve synchronously. A successor with history is sealed
  and activated only after its exact materialized observation set is rescored in bounded batches.
- Oban Basic is sufficient; no Pro workflow/batch feature or new dependency is required.

Local implementation commits:

- `fd2194d` — research decisions and Task 18 execution plan
- `67e20fb` — rule-level proof coverage, severity controls, exact-rule waivers, and proof identity
- `9d1cda5` — pinned durable rescore batches, safe candidate lifecycle, progress UI, and atomic activation

The additive migration audit preserved all nine local contract versions: 4 approved, 4 retired, and
1 draft. Their proof fields remain `NULL` as explicit legacy evidence rather than being inferred.
Both history guards are installed, and the new waiver/run/item tables began empty. New approvals
must carry `rule_coverage_v1` proof. No local data wipe was needed.

Verification passed on 2026-09-19 (America/Chicago): `mix precommit` with 625 Elixir tests, 50
frontend tests with TypeScript checking, and `mix assets.build`. Focused coverage includes an exact
51-item snapshot split into 50/1 batches, exclusion of a later observation, continued use of the old
approved contract while pending, evaluator-error failure without partial activation, and retry-draft
recovery. Task 18 and Gate A are complete.

## Task 19 log

- [x] Reconfirm the accepted credential-recovery finding and inspect credential rotation,
  monitor/setup attachment, exact-model validation, capture planning, reviewed-reference
  compatibility, scheduling, routes, and the current credential UI.
- [x] Define staged successor activation, durable per-model validation, atomic impact locking,
  in-flight-work blockers, historical provenance preservation, and conservative reference
  invalidation.
- [x] Add the per-model validation schema/backfill and route readiness through it.
- [x] Implement staged rotation and transactional successor activation.
- [x] Expose impact and recovery guidance through authenticated workspace product flows.
- [x] Prove rotation, multi-model validation, rebinding, replacement reference capture, schedule
  activation, and bounded fake-provider execution.
- [x] Run migration audits and all verification gates; record focused commits.

Decisions:

- A newly created successor does not supersede a still-usable predecessor. Supersession and monitor
  rebinding happen together only after successful validation and owner activation.
- Exact model access is durable per credential/model. The existing last-validation fields remain a
  safe summary but are no longer the authorization proof for every monitor.
- Credential identity remains part of reviewed-reference compatibility. Rebinding never blesses an
  old reference captured with different secret material.
- Pending captures block activation; Task 19 will not silently cancel already-authorized work.
- Existing already-superseded rotation lineages remain eligible for recovery without a data reset.
- Neither side of a staged rotation is offered to new monitor setup before activation. Revoking an
  unactivated successor releases the predecessor so an owner can retry with a fresh identity.

Local implementation commits:

- `640cb8a` — Task 19 research decisions and execution plan
- `b5ae9f5` — per-model proof, staged rotation, atomic activation, compatibility, and lifecycle tests
- `eaf97fd` — affected-monitor review, activation confirmation, and reference-recovery guidance

The additive migration audit found all 4 existing credential model summaries represented by 4
per-model rows, including 3 exact successful proofs. All 7 reviewed references and 11 capture runs
retain a credential identity, and there are zero duplicate live successors. No data wipe was needed.

Verification passed on 2026-09-20 (America/Chicago): `mix precommit` with 633 Elixir tests, 51
frontend tests with TypeScript checking, and `mix assets.build`. Focused lifecycle coverage proves
multi-model validation, no-call blocking for active runs and pending reference decisions, atomic
future-only rebinding, historical provenance retention, replacement-reference approval, schedule
reactivation, one-attempt bounded execution, staged-setup exclusion, revoked-successor retry, and
legacy-lineage recovery. Task 19 is complete; Task 20 is next.

## Task 20 log

- [x] Reconfirm the accepted breaker finding and inspect failure counting, capture planning and
  finalization, exact-model validation, scheduling locks, rate limits, authenticated routes, and the
  Operations UI.
- [x] Define immutable recovery epochs, fresh post-trip validation, a one-call/zero-retry probe,
  explicit resume after success, and post-success failure windows.
- [x] Add the additive recovery schema, probe capture kind, and purge compatibility.
- [x] Implement owner authorization, fresh validation, bounded planning, execution guards, and
  epoch-aware failure counting.
- [x] Expose recovery state and next actions through the authenticated Operations flow.
- [x] Prove trip, repair, probe, resume, failed-probe retry, and retrip through context/controller
  operations.
- [x] Run migration audits and all verification gates; record focused commits.

Decisions:

- Recovery is an owner-authorized half-open probe, not an automatic timeout and not a deletion of
  old failures.
- Each attempt validates the exact credential/model after the latest breaker trip, then authorizes
  one stable active case, one sample, zero retries, and one completion call.
- Probe success establishes the next failure-counting epoch but does not silently restart scheduled
  spend; the owner uses the existing Resume action.
- Recovery probes remain operational evidence and do not enter normal result history or alert
  generation.

Local implementation commits:

- `b2e6d80` — Task 20 research decisions and execution plan
- `e639ce6` — immutable epochs, fresh exact-model proof, bounded probe, breaker semantics, and API
- `5d42d0a` — owner/member recovery states, exact call disclosure, and explicit-resume UI
- `6403357` — recovery-epoch workspace-purge coverage

The additive migration audit preserved all 11 local capture runs (7 baseline, 3 manual, and 1
scheduled) and all 4 exact-model validation rows. The recovery table correctly began empty, the
immutable update trigger is installed, model-validation time now retains six-digit precision, and
the capture-kind constraint admits the new probe kind. No local data wipe was needed.

Verification passed on 2026-09-20 (America/Chicago): `mix precommit` with 638 Elixir tests, 54
frontend tests with TypeScript checking, and `mix assets.build`. Focused coverage proves trip,
same-credential repair, a single-case/single-call/zero-retry probe, no-call rejection without a
recovery record, explicit resume, preserved failures, later retrip, failed-probe retry through a new
epoch, owner/member authorization, controller state, and purge compatibility. Task 20 is complete;
Task 21 is next.

## Task 21 log

- [x] Reconfirm the accepted capacity finding and inspect policy accounting, eligibility sweeps,
  dispatch locking, cadence identity, notification outbox, authenticated Operations state, and
  legacy pause data.
- [x] Define explicit wait fields, original-slot preservation, UTC-boundary retry, exact capacity
  classification, one owner notification, and conservative legacy behavior.
- [x] Add the additive capacity-wait and delivery schema.
- [x] Implement due-only capacity checks, automatic bounded retry, coverage state, and notification.
- [x] Expose waiting, retry, last-success, and overdue state in Operations UI.
- [x] Prove run/call exhaustion, no premature stop, boundary recovery, no cap bypass, delivery
  deduplication, and legacy/purge compatibility.
- [x] Run migration audits and all verification gates; record focused commits.

Decisions:

- Daily run/call exhaustion keeps a scheduled monitor active with explicit waiting metadata; it is
  not stored as a safety pause.
- The original intended slot remains the scheduled-run identity while `next_run_at` temporarily
  points at the exact UTC reset boundary.
- Per-run limit failures remain persistent and receive their own pause reason.
- The first capacity interruption creates one content-free, preference-aware email delivery for
  each owner. Repeated dispatcher wakes do not create notification storms.
- Existing capacity-paused monitors are not auto-reclassified because their missed slot and
  interruption boundary were never persisted.

Local implementation commit: `0b06ca8`.

The additive migration preserved all 11 local capture runs and all 4 exact-model validation rows.
No local monitor was waiting during migration, and the three existing notification deliveries were
retained. Focused coverage proves future schedules are not stopped by today's usage, both daily
capacity reasons are explicit, per-run overflow remains a safety pause, the original slot is retried
at the UTC boundary through the atomic cap check, owner email is content-free and deduplicated, and
workspace closure/purge handles the new state.

Verification passed on 2026-09-20 (America/Chicago): `mix precommit` with 640 Elixir tests,
frontend TypeScript and 55 tests, and `mix assets.build`. Task 21 and Gate B's temporary-capacity
half are complete; Task 22 is next.

## Task 22 log

- [x] Inspect immutable monitor versions, mutable setup drafts, contract/reference compatibility,
  review actions, credential proof, active-run locks, and current setup routes.
- [x] Define a copied successor setup that does not affect active execution while it is edited.
- [x] Define atomic activation, exact-model proof, contract carry-forward, and mandatory replacement
  reference behavior.
- [x] Add additive setup origin/motivation schema and partial in-progress uniqueness.
- [x] Implement start/edit/complete/preview/activate operations and review linkage.
- [x] Add authenticated successor UI and entry points.
- [x] Prove a missed-regression case addition through replacement reference and restored service.
- [x] Run migration audits and all verification gates; record focused commits.

Decisions:

- A successor starts as a full copy of the active provider request, credential selection, generation
  settings, cases, and expectations. Editing the mutable setup never changes the active version,
  credential, approved contract, schedule, or reviewed reference.
- Completed setup creates an immutable draft `MonitorVersion`; it still has no execution authority.
- The currently approved deterministic contract is carried forward unchanged and rebound to the
  successor only inside the activation transaction. Contract semantic/proof evidence is preserved;
  contract editing remains the separate contract-revision workflow.
- Activation is owner-only and locks the monitor, source/candidate versions, setup, credential, and
  active-run state. It requires fresh exact-model proof, retires/approves contract versions, changes
  future monitor references, and moves the monitor to replacement-reference capture atomically.
- Every executable successor requires a new reviewed reference because the active immutable version
  identity changes. The preview says this before activation and old captures remain unchanged.
- Only one in-progress setup is allowed per monitor, while completed cold-start and successor setups
  remain durable history through a partial unique index.

Local implementation commits:

- `3383065` — Task 22 research decisions and execution plan
- `20367c0` — copied successor authoring, governed activation, review linkage, and recovery proof

The additive migrations preserved all four existing completed setups, produced zero inferred
successor rows, and left zero duplicate in-progress rows. The partial unique index, immutable-origin
trigger, provenance-preserving foreign keys, and expanded product-event constraint are installed.
No local data wipe was needed.

Verification passed on 2026-09-20 (America/Chicago): `mix precommit` with 644 Elixir tests, 59
frontend tests with TypeScript checking, and `mix assets.build`. End-to-end coverage proves a
reviewed missed regression can seed a case change, active monitoring and its reference remain valid
through mutable and immutable draft preparation, stale activation rolls back, exact-model and
active-run guards fail closed, activation carries forward exact contract proof, a replacement
reviewed reference is required, and explicit schedule activation restores service. Workspace purge
also removes the full successor-origin graph. Task 22 and Gate B are complete; Task 23 is next.
