# Design-review hardening progress

## Current status

- Program: in progress
- Current gate: Gate A — Product truth
- Current task: Task 16 — provider-native request artifacts (in progress)
- Local-data policy: preserve and migrate; no wipe authorized or required
- External pilot: blocked until Gates A–D are complete

## Task status

| Task | Deliverable | Status |
| --- | --- | --- |
| 15 | Review program and truthful public evidence | Complete (`d49b997`) |
| 16 | Provider-native request artifacts | In progress |
| 17 | Case-specific expectations | Not started |
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
- [ ] Implement strict rendering, exact preview/fingerprinting, and direct product provider transport
  (renderer, fingerprint verification, attempt receipts, and direct transport complete; setup preview
  remains).
- [ ] Update setup and review UX.
- [ ] Add migration, payload, capture-receipt, controller, and frontend tests.
- [ ] Run all local gates and record focused commits.
