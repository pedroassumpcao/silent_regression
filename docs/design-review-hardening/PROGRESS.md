# Design-review hardening progress

## Current status

- Program: in progress
- Current gate: Gate A — Product truth
- Current task: Task 18 — contract proof coverage, severity, and bounded rescore (not started)
- Local-data policy: preserve and migrate; no wipe authorized or required
- External pilot: blocked until Gates A–D are complete

## Task status

| Task | Deliverable | Status |
| --- | --- | --- |
| 15 | Review program and truthful public evidence | Complete (`d49b997`) |
| 16 | Provider-native request artifacts | Complete |
| 17 | Case-specific expectations | Complete |
| 18 | Contract proof coverage, severity, and bounded rescore | Not started |
| 19 | Credential successor rebinding | Not started |
| 20 | Authentication breaker recovery | Not started |
| 21 | Temporary capacity and coverage state | Not started |
| 22 | Successor workflow configuration | Not started |
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
