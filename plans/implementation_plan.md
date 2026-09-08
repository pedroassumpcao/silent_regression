# Silent Regression Feasibility Spike — Codex Implementation Plan

> **Status:** Task 5 complete; Task 6 is next
>
> **Last revised:** 2026-09-07
>
> **Purpose:** Persistent product, experiment, and implementation reference for Codex

Before implementing a task, Codex must read this entire document. Work on one numbered task at a time, run the task-specific verification, run `mix precommit` before considering the task complete, and create one focused commit with the message format `feat(spike): <summary>` unless the user asks for a different workflow.

## 1. Product context and agreed direction

Silent Regression is intended to become a hosted SaaS for teams that depend on third-party LLMs. A customer will provide the prompt, frozen representative inputs, evaluation information they already have, and provider credentials. They will not install an SDK or library in their production environment. Silent Regression will call the configured provider itself, establish a historical baseline, periodically repeat the cases, and surface meaningful changes.

The product has two complementary alert modes:

1. **Deterministic degradation:** When a customer supplies machine-checkable expectations, Silent Regression can say that a concrete quality check regressed.
2. **Reviewable behavioral drift:** When correctness cannot be determined automatically, Silent Regression can say that behavior changed unusually and ask the customer to review it. A drift-only signal must not be described as proven quality degradation.

The initial monitoring relationship is strictly:

- same customer case;
- same provider;
- same requested model;
- same prompt and frozen input version;
- same effective generation configuration;
- current run versus that configuration's own historical baseline.

Direct provider/model comparisons and migration simulations may be useful later, but they are not part of this spike.

The first experimental workload is **RAG answer generation**. The spike will use frozen source passages embedded in each case so it tests the model-generation layer in isolation. It does not test retrieval quality, chunking, ranking, vector search, or a customer's live RAG pipeline.

## 2. What this spike must answer

The spike is successful only if it produces an evidence-backed answer to these questions:

1. Can deterministic checks reliably identify well-formed but factually wrong RAG outputs?
2. Can an inexpensive distribution metric distinguish a same-model control run from a seeded, human-verified behavioral regression?
3. Can it avoid flagging harmless nondeterminism and meaning-preserving rewording?
4. Does the result hold for at least one cost-oriented and one more-capable model from both OpenAI and Anthropic?
5. What sample size, latency, and token usage are required to obtain a useful signal?

The spike may support different conclusions for deterministic and open-ended cases. A partial result is valid and preferable to an overstated result.

## 3. Hypotheses and alert semantics

### H1 — deterministic checks

For cases with explicit expectations, a seeded regression should produce a material drop in the pass rate while control and harmless-rewording conditions remain stable.

### H2 — label-free drift

For cases without a single correct output, the distribution of lexical distances should show materially greater separation for a seeded regression than for same-model controls.

### H3 — false-alert control

A threshold calibrated only from baseline/control data should keep review alerts rare on held-out same-model control runs and meaning-preserving fixture batches.

### H4 — RAG relevance

At least one subtle RAG failure—such as an unsupported claim, incorrect attribution, omitted central fact, or failure to abstain—should be detected without relying on output formatting failure.

The implementation exposes four outcomes:

- `:deterministic_regression` — one or more explicit quality checks degraded beyond the configured threshold;
- `:drift_review` — statistically unusual behavior with no automatic claim about quality direction;
- `:no_alert` — neither condition was met;
- `:insufficient_data` — too few successful samples or an incompatible comparison.

## 4. Scope and non-goals

### In scope

- Pure Elixir domain modules inside the existing Phoenix application.
- OpenAI and Anthropic HTTP clients built with the existing `Req` dependency.
- Local, gitignored JSON run artifacts with complete provenance.
- A small, versioned, synthetic RAG case suite.
- Deterministic checks, lexical Jaccard distance, distribution comparison, calibration, and reporting.
- Mocked automated tests and manually authorized live experiment runs.
- Codex-drafted regression fixtures that the user reviews before they become experimental ground truth.

### Out of scope

- Phoenix routes, LiveViews, database schemas, authentication, billing, scheduling, or production key storage.
- External retrieval systems or live customer traffic.
- OpenRouter or other providers.
- Cross-provider/model migration comparisons.
- Embeddings, an LLM judge, a trained classifier, or a customer-authored natural-language rubric.
- Production-grade statistical guarantees from this small experiment.
- Automatic live API calls from tests or from Codex without explicit user authorization.

Phoenix remains the future product shell. All spike code must live under the `SilentRegression.Spike` namespace and must not depend on `SilentRegressionWeb` or `SilentRegression.Repo`.

## 5. Experimental design

### 5.1 Unit of evaluation

A case is more than a prompt. Each `SilentRegression.Spike.Case` contains:

- stable `id` and integer `version`;
- `category`;
- optional system instructions;
- frozen RAG context and user question;
- response-format instructions;
- deterministic checks, if any;
- tags and a human-readable description;
- a fingerprint computed from all behavior-affecting case content.

A baseline belongs to the combination of provider, requested model, returned model, case fingerprint, and effective generation configuration. The comparison command must reject incompatible provenance instead of silently comparing it.

### 5.2 Initial RAG cases

Create four synthetic cases with short, invented source material so no live facts or copyrighted documents are required:

1. `rag_structured_extract` — extract grounded facts and source IDs into JSON; exact deterministic checks.
2. `rag_answer_with_citations` — answer using only the supplied passages and cite the supporting source IDs; required fact and citation checks.
3. `rag_abstain_when_unsupported` — the context does not contain the answer; an abstention is required and invented answers are forbidden.
4. `rag_open_synthesis` — produce a concise synthesis where multiple phrasings are valid; a few grounding invariants exist, but there is no single expected answer.

The open-synthesis case ensures that label-free drift is evaluated on a genuinely open-ended output. Deterministic checks may still provide diagnostic context, but they must be excluded when calculating the label-free drift detection rate.

### 5.3 Conditions

For every participating provider/model/case combination, distinguish these conditions:

- `baseline` — the reference sample pool;
- `control` — independent live samples with identical provenance, preferably captured at different times;
- `harmless_rewording` — reviewed fixtures that preserve meaning while changing wording/style;
- `subtle_regression` — reviewed, well-formed outputs containing a semantic failure;
- `mixed_regression` — batches with seeded failure rates such as 10%, 25%, and 50% to measure sensitivity;
- `obvious_regression` — strongly wrong but still parseable fixtures used as a sanity check.

Do not simulate the initial regression by switching to a different model. That measures model differences, not silent same-model regression.

### 5.4 Cheap distribution statistic

Jaccard word-set distance remains the first representation because the business hypothesis specifically asks whether a cheap method is useful. Raw cross-run similarity is not sufficient on its own.

For baseline samples `X`, candidate samples `Y`, and Jaccard distance `d = 1 - similarity`, calculate:

- mean within-baseline distance `E[d(X, X')]` over distinct pairs;
- mean within-candidate distance `E[d(Y, Y')]` over distinct pairs;
- mean cross distance `E[d(X, Y)]`;
- lexical energy distance: `2E[d(X,Y)] - E[d(X,X')] - E[d(Y,Y')]`.

The population energy statistic is near zero when the two distributions look alike and grows as they separate. Its finite-sample estimate can be slightly negative because of sampling; do not clamp it. Calibrate and interpret it relative to the empirical null distribution, and report all component values so the result remains interpretable.

Use a deterministic seeded permutation test to estimate a p-value and baseline/control resampling to establish the empirical null distribution. Apply Benjamini-Hochberg correction across the cases in a comparison run. A `:drift_review` requires both:

- energy distance above the pre-calibrated empirical threshold; and
- adjusted `p <= 0.05`.

Thresholds must be derived without looking at regression fixtures. Never tune a threshold on the same seeded regressions used to report detection performance.

### 5.5 Provisional feasibility criteria

These are spike gates, not production SLAs:

- deterministic evaluators classify all user-approved unit fixtures correctly;
- empirical review-alert rate is at most 5% over at least 200 seeded null resamples;
- no more than one alert occurs across at least 20 independent live control case-comparisons in the expanded experiment;
- at least 80% of user-approved seeded regression batches trigger either the correct deterministic regression or a drift-review signal;
- at most 10% of user-approved harmless-rewording batches trigger drift review;
- at least one subtle open-synthesis regression triggers drift review;
- reports include successful-call rate, latency, token usage, and total request count so cost/operational feasibility can be judged.

Because resamples are not independent live runs and the live sample is small, passing these gates means **promising enough for another validation stage**, not proven production accuracy.

### 5.6 Staged execution and spend control

Live execution is deliberately gated:

1. Develop and verify everything using local fixtures and mocked HTTP.
2. Pilot one cost-oriented model with a baseline of `n=30` and candidate runs of `n=20`.
3. Run calibration plus several independent controls before testing regression fixtures.
4. Continue to the four-model matrix only if the pilot shows useful separation and an acceptable null alert rate.

Every live Mix task must support `--dry-run`, print the exact planned request count, require an explicit `--max-calls` cap, and stop rather than exceed it. Retries count against the cap. Concurrency defaults to 3 and `Task.async_stream/3` uses `timeout: :infinity`; outputs are restored to stable sample order.

The recommended expansion matrix as of 2026-09-07 is:

| Provider | Cost-oriented | More capable |
| --- | --- | --- |
| OpenAI | `gpt-5.6-luna` | `gpt-5.6-sol` |
| Anthropic | `claude-haiku-4-5-20251001` | `claude-sonnet-5` |

Model availability must be checked immediately before live execution. Model IDs are explicit CLI inputs; the code must not silently substitute a model or rely on a default. If an account lacks access, the user chooses and records a replacement before execution.

## 6. Technical architecture

Suggested module layout:

```text
lib/silent_regression/spike/
  case.ex
  response.ex
  run.ex
  provider.ex
  providers/open_ai.ex
  providers/anthropic.ex
  case_set.ex
  deterministic_checks.ex
  lexical.ex
  statistics.ex
  comparison.ex
  runner.ex
  storage.ex
  report.ex

lib/mix/tasks/
  drift_spike.preflight.ex
  drift_spike.baseline.ex
  drift_spike.control.ex
  drift_spike.compare_fixtures.ex
  drift_spike.report.ex
```

No database is used. Local artifacts live under `results/drift_spike/`, which is gitignored except for an explanatory `.gitkeep` if useful. Reviewed static fixtures live under `test/fixtures/drift_spike/` and are committed.

### 6.1 Provider contract

Define a provider behaviour so the runner does not contain provider-specific parsing. The normalized response includes:

- provider;
- requested and returned model IDs;
- output text;
- provider response/request ID when available;
- normalized input/output token counts;
- latency in milliseconds;
- finish/stop reason;
- capture timestamp;
- raw decoded response for local diagnostic artifacts.

Provider functions return `{:ok, response}` or `{:error, structured_reason}` and do not raise for expected HTTP, decoding, or API failures. API keys come from `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` for the spike and are never persisted or logged.

HTTP behavior must be injectable through `Req` options so `Req.Test` can prove that automated tests make no network calls. Retries are bounded, recorded, and included in the call budget.

### 6.2 Provider-specific API choices

- **OpenAI:** use `POST /v1/responses`, set `store: false`, parse text by walking response output content rather than assuming the first output item, and record the effective model and usage. Do not force `temperature`; persist it only when explicitly supplied and supported by the selected model.
- **Anthropic:** use `POST /v1/messages` with the required API headers and `anthropic-version`, parse all returned text content blocks, and record model/usage/stop reason. Do not force sampling parameters that a selected model does not support.

Each request records the complete behavior-affecting configuration: prompt/case fingerprint, provider, requested/returned model, max output tokens, sampling/reasoning options, API endpoint/version, and any structured-output mode.

### 6.3 Artifact schema

Use one versioned JSON artifact per run rather than one file per prompt. At minimum it contains:

- `schema_version`;
- unique `run_id`, label, condition, and timestamps;
- git revision when available;
- provider and complete request configuration;
- case definitions/fingerprints used by the run;
- ordered successes and structured failures;
- request attempts, latency, and usage totals;
- deterministic scores and distribution statistics where applicable.

Writes must be atomic. Reports read only recognized run artifacts and must ignore unrelated JSON or malformed files with a visible warning.

Raw prompts and outputs are sensitive in the future product. For this local spike they remain gitignored; the report should contain summaries and short, explicitly selected examples rather than duplicating all raw text.

## 7. Scoring contracts and edge cases

Deterministic behavior must be explicit rather than described as “loose matching.” Implement composable checks sufficient for the four cases:

- canonical JSON object equality with a documented policy for extra keys and numeric types;
- required JSON keys and values;
- exact normalized enum/label equality (never substring matching);
- required source IDs;
- required and forbidden normalized phrases/facts;
- abstention predicate.

JSON enclosed in a single Markdown code fence may be normalized before parsing; prose surrounding JSON is invalid when JSON-only output was requested. Empty or whitespace-only responses fail relevant deterministic checks.

Lexical normalization must document Unicode case folding, punctuation handling, whitespace, empty-set behavior, and whether repeated words are ignored. Jaccard intentionally ignores word frequency in this first layer.

Statistical functions must define behavior for empty/undersized samples, use sample standard deviation where reported, avoid division by zero, accept a deterministic random seed, and return `:insufficient_data` instead of misleading zeros.

## 8. Ground rules

1. Never make live provider calls from `mix test`; all provider tests use `Req.Test`.
2. Never make live calls while implementing unless the user explicitly authorizes the exact run after seeing its dry-run request count.
3. Use existing `Req` and `Jason`; add no dependency without discussion.
4. Never fabricate, replace, discard, or silently retry around failed experimental results.
5. Do not tune alert thresholds using regression fixtures.
6. Do not call drift a quality regression unless a deterministic expectation establishes direction.
7. Preserve complete provenance and reject incompatible comparisons.
8. Keep spike code independent from Phoenix web and database modules.
9. Codex may draft semantic fixtures, but only user-approved fixtures count as ground truth.
10. Use targeted tests while developing and `mix precommit` before completing each task.

## 9. Implementation tasks

### Task 1 — Spike foundation and data contracts

**Status:** Complete

**Objective:** Establish the isolated namespace, core structs, provider behaviour, artifact schema version, and directory conventions without adding dependencies.

**Files:** Create the core `case.ex`, `response.ex`, `run.ex`, `provider.ex`, and `storage.ex` modules plus focused tests.

**Requirements:** Validate required fields, make serializable representations explicit, define structured errors, add `results/drift_spike/` to `.gitignore`, and implement atomic JSON read/write with schema-version validation.

**Verify:** Unit tests cover valid round trips, malformed artifacts, unsupported schema versions, and missing required fields; `mix precommit` passes.

### Task 2 — Versioned RAG case suite

**Status:** Complete

**Objective:** Implement the four synthetic RAG cases and stable fingerprints.

**Files:** Create `case_set.ex` and case-set tests.

**Requirements:** Keep source documents invented, short, unambiguous, and frozen. Store deterministic check specifications as data. Fingerprints must change when behavior-affecting case content changes and remain stable across map ordering.

**Human gate:** The user reads and approves the cases and their deterministic expectations before live baselines are captured.

**Verify:** Tests assert unique IDs, valid check specifications, stable known fingerprints, and the intended presence/absence of exact expectations; `mix precommit` passes.

### Task 3 — Deterministic evaluation layer

**Status:** Complete

**Objective:** Implement concrete quality checks for structured, grounded, citation, and abstention cases.

**Files:** Create `deterministic_checks.ex` and tests.

**Requirements:** Follow the normalization and edge-case rules in Section 7. Return per-check results plus an aggregate pass rate; never reduce failures to an unexplained boolean.

**Verify:** Table-driven tests cover correct outputs, well-formed wrong outputs, extra/missing keys, numeric representation, fenced JSON, prose-wrapped JSON, wrong citations, unsupported claims, and empty text; `mix precommit` passes.

### Task 4 — Lexical and statistical layer

**Status:** Complete

**Objective:** Implement Jaccard normalization, within/cross distances, energy distance, permutation testing, null resampling, and Benjamini-Hochberg correction.

**Files:** Create `lexical.ex`, `statistics.ex`, and focused tests.

**Requirements:** Use deterministic seeds, no external statistics dependency, and explicit insufficient-sample errors. Threshold calibration consumes only null data.

**Verify:** Hand-computed small examples, symmetry/property tests, identical-distribution cases, separated-distribution cases, deterministic-repeatability tests, and a test proving regression labels cannot enter calibration; `mix precommit` passes.

### Task 5 — OpenAI Responses API client

**Status:** Complete

**Objective:** Implement and fully mock the first provider integration.

**Files:** Create `providers/open_ai.ex` and tests.

**Requirements:** Require an explicit model, use the Responses API, set `store: false`, normalize all contract fields, support bounded transient retries, expose safe `Req.Test` injection, and return structured errors without raising.

**Verify:** Mock success with multiple output item shapes, usage normalization, returned-model mismatch recording, missing key/no request, 400, 401, 429/retry, 500/retry exhaustion, timeout, and malformed JSON; zero real HTTP; `mix precommit` passes.

### Task 6 — Anthropic Messages API client

**Status:** Complete

**Objective:** Implement and mock the second provider without changing the normalized contract.

**Files:** Create `providers/anthropic.ex` and tests.

**Requirements:** Require an explicit model, set the API version header, join relevant text blocks safely, record usage and stop reason, support bounded retries/call accounting, and omit unsupported generation parameters.

**Verify:** Mirror Task 5's applicable cases, including multi-block content and API error bodies; zero real HTTP; `mix precommit` passes.

### Task 7 — Runner, preflight, and spend guardrails

**Status:** Complete

**Objective:** Execute provider calls consistently while preserving ordering, failures, provenance, and request budgets.

**Files:** Create `runner.ex`, `drift_spike.preflight`, and tests.

**Requirements:** Use `Task.async_stream/3` with bounded concurrency and `timeout: :infinity`; support dry-run planning; enforce `--max-calls`; count retry attempts; validate environment keys and explicit models; print planned cases, samples, calls, and configuration without exposing secrets.

**Verify:** Fake providers prove stable ordering, partial failure handling, budget refusal, retry accounting, and that dry-run makes no calls; `mix precommit` passes.

### Task 8 — Baseline capture

**Status:** Complete

**Objective:** Capture a versioned baseline pool and compute its deterministic/within-run characteristics.

**Files:** Create `drift_spike.baseline` and supporting comparison/storage functions.

**Requirements:** Default to `n=30` but require explicit provider, model, and `--max-calls`; use at least 512 maximum output tokens for the frozen four-case baseline; write a single atomic artifact; distinguish provider failures, incomplete responses, deterministic failures, and combined quality failures; exclude incomplete responses from within-distance statistics; show completion and quality pass rates, deterministic pass rates, within-distance statistics, latency, and usage.

**Verify:** End-to-end tests use a fake provider and temporary directory; `mix precommit` passes.

**Manual gate:** User approves the dry-run and initiates each live baseline. Start with one cost-oriented model only.

### Task 9 — Control runs and null calibration

**Objective:** Establish ordinary same-model variability before looking at regression fixtures.

**Files:** Create `drift_spike.control`, calibration/comparison logic, and tests.

**Requirements:** Reject provenance mismatches; default to `n=20`; compare independent controls to the baseline; construct the seeded resampling null distribution; persist the frozen threshold separately with its source run IDs and seed.

**Verify:** Fixture/fake-provider tests cover compatible and incompatible runs, threshold reproducibility, and alert outcomes; `mix precommit` passes.

**Manual gate:** Capture enough independently authorized controls to judge whether proceeding is worthwhile. Do not change the frozen threshold after opening regression fixtures.

### Task 10 — Codex-drafted semantic fixture candidates

**Objective:** Create candidate batches for obvious regression, subtle regression, mixed regression rates, harmless rewording, and style-only changes across all relevant RAG cases.

**Files:** Add candidates under `test/fixtures/drift_spike/candidates/` with a manifest explaining each mutation and intended label.

**Requirements:** Preserve requested output structure in regression fixtures. Include unsupported claims, wrong attribution, omission, failed abstention, and an open-synthesis semantic regression. Avoid merely producing malformed or wildly unrelated text.

**Human gate:** Stop after drafting. The user reviews every candidate's semantic label, requests corrections if needed, and explicitly approves promotion to `test/fixtures/drift_spike/approved/`. Unapproved candidates cannot be used in reported results.

**Verify:** Schema/shape validation passes and the candidate manifest accounts for every fixture; `mix precommit` passes.

### Task 11 — Fixture comparison and sensitivity analysis

**Objective:** Evaluate approved fixture batches against the frozen baseline/calibration without live API calls.

**Files:** Create `drift_spike.compare_fixtures`, comparison orchestration, and tests.

**Requirements:** Report deterministic outcomes separately from drift outcomes; evaluate mixed failure rates; preserve individual samples and batch labels; refuse candidate/unapproved fixture paths for official reports.

**Verify:** End-to-end local tests exercise all four alert outcomes and prove the calibration artifact is unchanged; `mix precommit` passes.

**Decision gate:** If Jaccard energy distance cannot separate subtle regression from controls/rewording, stop and write a new plan for the next semantic layer. Do not add embeddings opportunistically inside this task.

### Task 12 — Expanded provider/model experiment

**Objective:** Repeat the validated protocol across the approved two-by-two provider/model matrix.

**Requirements:** Check current model availability, get explicit user approval for any matrix change, show every dry-run request count, keep thresholds model/configuration-specific, and never pool providers or models into one baseline.

**Manual gate:** The user authorizes and initiates each live run. Expansion happens only if the pilot decision gate passes.

**Verify:** Every artifact has compatible provenance, planned sample counts or visible failures, and complete usage/latency totals.

### Task 13 — Consolidated report and human verdict

**Objective:** Produce a reproducible evidence summary without overstating what the spike proved.

**Files:** Create `report.ex`, `drift_spike.report`, tests, and generated `results/drift_spike/SUMMARY.md`.

**Requirements:** Report per provider/model/case/condition:

- sample and failure counts;
- deterministic pass-rate changes;
- within, cross, and energy distances;
- raw and adjusted p-values;
- threshold and alert outcome;
- harmless-rewording false alerts;
- seeded-regression detections by failure rate;
- latency, token usage, and request attempts.

Include aggregate results only alongside their denominators and per-case results. Separate deterministic detection from drift-review detection.

**Verify:** Reporter tests ignore unrelated files, warn on malformed/incompatible artifacts, and reproduce the same summary from the same inputs; `mix precommit` passes.

**Final human step:** The user writes one of these scoped conclusions at the top of the summary:

- `PROMISING_FOR_DETERMINISTIC_AND_DRIFT_TRIAGE`
- `PROMISING_FOR_DETERMINISTIC_ONLY`
- `NEEDS_A_SEMANTIC_LAYER`
- `NOT_VIABLE_AS_DESIGNED`

The conclusion must name which hypotheses passed, which failed, and the experiment's limitations.

### Optional Task 14 — ReqLLM adapter evaluation

**Status:** Deferred until after Task 13

**Objective:** Determine whether ReqLLM should replace the hand-written OpenAI and Anthropic transports for the hosted product without changing the completed spike's experimental surface.

**Approach:** Implement ReqLLM behind the existing `SilentRegression.Spike.Provider` behaviour and compare it against the current Req clients. Do not rewrite or invalidate historical spike artifacts. Keep the authenticated account-level model availability check independent from catalog metadata.

**Requirements:**

- pin an explicit ReqLLM version and review its dependency, compatibility, and upgrade policies;
- disable dotenv loading and pass customer credentials per request;
- preserve explicit provider, model, and API selection without silent substitution;
- disable library retries or expose every HTTP attempt so `--max-calls` remains enforceable;
- preserve requested and returned model IDs, request IDs, raw provider metadata, finish reasons, latency, usage, cost estimates, and structured failures;
- prove that OpenAI uses the intended Responses API path and Anthropic uses the intended Messages API path;
- treat ReqLLM model metadata and cost data as advisory rather than a substitute for provider-side access and billing truth.

**Verify:** Run mocked parity tests for successful responses, malformed responses, provider errors, returned-model differences, usage normalization, retry accounting, and secret redaction. `mix test` must make zero real provider calls. Any live parity smoke test requires its own dry-run, exact call count, and user authorization.

**Decision gate:** Adopt ReqLLM only if parity is demonstrated and it materially reduces production integration and maintenance cost without weakening provenance or spend guardrails. Otherwise retain the current Req adapters and revisit when provider breadth becomes a product requirement.

## 10. Escalation path

If lexical energy distance fails the Task 11 gate, preserve the artifacts and discuss a new, separately approved experiment. Candidate next layers, in order of increasing cost/complexity, are:

1. character/token n-gram distances or field-aware structured comparison;
2. embedding cosine/energy distance;
3. lightweight customer-defined assertions or reference examples;
4. an LLM judge for ambiguous semantic direction;
5. supervised calibration from accumulated user review labels.

The product can combine these layers later. User review decisions are valuable learning data, but the spike must not assume a training system or silently retain customer content.

## 11. Known risks and interpretation limits

- Distribution shift is evidence of change, not evidence that the change is worse.
- Provider infrastructure can change even when a model identifier remains the same; that is a legitimate monitoring target but complicates root-cause claims.
- Simple lexical distance may miss a one-token factual substitution or overreact to harmless rephrasing.
- Synthetic fixtures can be cleaner than real regressions; live customer validation will still be required.
- Results from four synthetic RAG cases cannot establish broad performance for every LLM workload.
- Small live-control counts cannot prove a production false-alert SLA.
- Provider retries, safety behavior, outages, and rate limits can create operational anomalies distinct from model-quality drift.
- Frozen-context RAG tests do not monitor the retriever or corpus.
- Raw prompts and outputs create future privacy, retention, residency, and security obligations that this local spike intentionally postpones.

## 12. Documentation references

Provider details must be rechecked when their client task begins and again before live execution:

- [OpenAI model catalog](https://developers.openai.com/api/docs/models)
- [OpenAI Responses API — create response](https://developers.openai.com/api/reference/cli/resources/responses/methods/create)
- [Anthropic models overview](https://platform.claude.com/docs/en/models/overview)
- [Anthropic model IDs and versioning](https://platform.claude.com/docs/en/about-claude/models/model-ids-and-versions)
- [Anthropic Messages API — create message](https://platform.claude.com/docs/en/api/http/messages/create)
- [ReqLLM repository and documentation](https://github.com/agentjido/req_llm)

## 13. Decision log

- **2026-09-03:** Created the original Hermes-authored spike plan to preserve business context between implementation sessions.
- **2026-09-07:** Confirmed Phoenix is intentional as the future SaaS shell; the spike will remain isolated from web/database layers.
- **2026-09-07:** Chose RAG generation as the provisional first workload, using frozen embedded context rather than a live retriever.
- **2026-09-07:** Defined two product signals: deterministic quality degradation and direction-neutral drift requiring review.
- **2026-09-07:** Limited initial monitoring to each provider/model configuration against its own history; migration comparison deferred.
- **2026-09-07:** Reduced initial providers to OpenAI and Anthropic, with staged testing across cost-oriented and capable models.
- **2026-09-07:** Assigned Codex to draft semantic fixtures and the user to approve their ground-truth labels.
- **2026-09-07:** Replaced raw mean cross-similarity with within/cross Jaccard energy distance, permutation testing, null calibration, and explicit false-alert gates.
- **2026-09-07:** Deferred a ReqLLM adapter evaluation until after the spike so provider abstraction, cost metadata, and telemetry can be assessed without changing the experimental transport mid-study.
- **2026-09-07:** A live `n=30` pilot showed that 256 output tokens truncated one-third of open-synthesis responses and that contiguous phrase checks rejected valid paraphrases. Raised the frozen baseline ceiling to 512, made incomplete responses explicit quality failures excluded from drift statistics, and introduced bounded grouped-fact checks before calibration.
