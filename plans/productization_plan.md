# Silent Regression Productization Plan

> **Status:** Draft for use only after the feasibility spike decision gate
>
> **Last revised:** 2026-09-08
>
> **Purpose:** Record the gaps, architectural changes, validation work, and product decisions required to turn the spike into a trustworthy hosted product

This document is a post-spike planning reference. It must not be treated as authorization to implement product features or expand the current experiment. Complete the [feasibility spike](implementation_plan.md), review its evidence, and explicitly decide whether the signal is useful enough to productize before scheduling this work.

## 1. Product boundary

Silent Regression is intended to be a hosted service for teams that depend on third-party LLM behavior. A customer supplies:

- prompts and frozen representative inputs;
- the provider, model, and effective request configuration;
- machine-checkable expectations or examples when available;
- provider credentials for managed replay; and
- human review decisions for ambiguous changes.

Customers do not need to install an SDK or library in their production environment. Initial ingestion can happen through the web application, file import, or a hosted API. Managed replay calls the configured provider from Silent Regression; importing historical production observations can be considered separately without requiring resident instrumentation.

The initial comparison remains a monitor against its own history: same customer case, prompt/input version, provider, requested model, and behavior-affecting generation configuration. Cross-provider comparisons and model-migration simulations are future features, not implicit extensions of a baseline.

## 2. What the spike can and cannot establish

The spike can test whether the following mechanics work on controlled RAG cases:

- reproducible capture with complete request and response provenance;
- explicit deterministic quality contracts;
- same-model baseline and control comparisons;
- empirical, leakage-resistant threshold calibration;
- separation of deterministic degradation from reviewable drift; and
- operational feasibility in calls, tokens, latency, and failure handling.

Even a successful spike cannot establish that Silent Regression understands arbitrary customer outputs. Four synthetic cases cannot demonstrate broad domain coverage, a production false-alert rate, customer willingness to pay, privacy readiness, or a universal quality metric. A distribution change is evidence of different behavior, not proof that behavior became worse.

Productization must therefore preserve this boundary:

1. Deterministic degradation is asserted only when an explicit, versioned contract defines direction.
2. Open-ended behavioral change is routed to review unless separate labeled evidence establishes quality direction.
3. Human decisions are evidence for a particular monitor and contract; they are not automatically generalized across customers.

## 3. Core design principles

### 3.1 Separate observation from interpretation

A provider observation is immutable evidence of what happened during one call. It should contain the normalized response, completion status, requested and returned model, request identity, usage, latency, timestamps, and safe provenance. It must not own a permanently embedded interpretation of quality.

An evaluation is a separate, reproducible derivative that references:

- an observation ID;
- an evaluation-contract version and fingerprint;
- an evaluator-engine version;
- the result of every check; and
- the time and code version used to evaluate it.

This separation allows stored outputs to be rescored locally when a checker improves. Changing an evaluator must create a new evaluation record, never mutate an observation or silently rewrite historical results.

### 3.2 Make semantics monitor-specific

Generic evaluator primitives can be reused across customers, but their configured expectations belong to a specific monitor. A baseline alone cannot identify every factual or semantic error. Each monitor needs a versioned contract derived from the customer's prompt, context, output requirements, and review decisions.

### 3.3 Keep thresholds local and frozen

Calibration artifacts must remain specific to compatible provenance. Do not pool providers, models, prompts, case versions, or behavior-affecting request configurations into a global threshold. Calibration sources and held-out evaluation runs must remain disjoint and auditable.

### 3.4 Prefer explainable evidence

Alerts should show the concrete failed expectations, representative output differences, baseline context, statistical evidence, and operational anomalies. A single unexplained score is not sufficient for a user to decide whether a change matters.

### 3.5 Treat user review as governed data

Review decisions must be explicit, attributable, reversible through a new decision, and tied to the exact comparison and contract version. Reviews must not silently modify contracts or thresholds. Any later supervised learning must use a documented train/calibration/held-out split.

## 4. Generic evaluation contracts

The spike's case definitions are controlled experimental fixtures. The product needs a declarative contract model that customers can author directly or approve after Silent Regression drafts it.

Initial reusable primitives should cover:

- exact or normalized labels;
- JSON shape, schema, required fields, and typed values;
- required and forbidden facts;
- required source attribution and citation placement;
- supported abstention behavior;
- numeric and quantity relationships, including bounded unit inheritance such as “from 34 minutes to 19”;
- allowed ranges, sets, and tolerances;
- output-language and length constraints when genuinely material; and
- composable all/any/not groups with bounded proximity where appropriate.

Every primitive needs:

- a versioned machine-readable schema;
- positive, negative, and adversarial fixture tests;
- explainable result details;
- documented normalization behavior;
- explicit handling of missing or malformed outputs; and
- protection against unsafe user input such as unbounded regular expressions or atom creation.

Drafted contracts are proposals, not truth. Before activation, the customer should review the expectations and approve a small fixture set containing both valid paraphrases and invalid counterexamples. A change to behavior-affecting contract data or evaluator semantics must produce a new version and fingerprint.

## 5. Evaluation layers and alert semantics

### 5.1 Deterministic contract evaluation

Use deterministic checks where the expected property can be stated precisely. Report both per-check outcomes and aggregate rates. A regression policy may compare pass-rate changes against a configured or empirically validated tolerance, but it must retain the underlying failed examples.

One failed sample should not automatically become a production incident unless the contract or alert policy says that property is zero-tolerance. The product must distinguish a sample failure, a batch-rate degradation, and a confirmed incident.

### 5.2 Label-free drift detection

Use baseline/control distributions to identify unusual behavior in open-ended output. The spike starts with lexical Jaccard energy distance and a seeded permutation test. If the spike decision gate fails, stop and design the next semantic layer separately rather than hiding the failure behind another metric.

Potential later layers include embeddings, claim extraction, structured semantic comparisons, or an LLM judge. Each option requires its own cost, reproducibility, provider-dependence, privacy, calibration, and adversarial-reliability analysis. No semantic judge should be described as objective ground truth.

### 5.3 Operational signals

Provider errors, incomplete responses, returned-model mismatches, latency changes, token changes, and rate-limit behavior are operational evidence. They should be visible and alertable, but kept distinct from content-quality conclusions.

### 5.4 Human review

Reviewable drift should present representative baseline/current samples, the facts or tokens responsible for the signal, deterministic results, and provenance. Review choices should include at least:

- meaningful degradation;
- meaningful improvement;
- harmless change;
- evaluator false positive;
- insufficient information; and
- operational/provider anomaly.

The review record should allow a short rationale and optional proposed contract update. Contract changes then go through a separate approval and offline-rescoring workflow.

## 6. Target domain model

The exact Ecto schemas should be designed only when product work begins, but the model should preserve these boundaries:

| Entity | Responsibility |
|---|---|
| Workspace | Tenant, membership, roles, retention, and billing boundary |
| Provider credential | Encrypted, scoped credential metadata; never included in artifacts or logs |
| Monitor | Customer-owned monitoring objective and active configuration lineage |
| Case/input version | Frozen prompt, context, input, response format, and fingerprint |
| Evaluation contract version | Approved deterministic expectations and evaluator compatibility |
| Capture batch | One planned baseline, control, or current run with spend and provenance limits |
| Observation | Immutable normalized result of one provider call |
| Evaluation run/result | Rescorable interpretation of observations under a contract and engine version |
| Baseline snapshot | Immutable membership in the reference population |
| Calibration | Immutable thresholds, source IDs, seeds, method versions, and null diagnostics |
| Comparison | Candidate-versus-baseline evidence with corrected statistics and outcomes |
| Alert | User-facing lifecycle around actionable evidence |
| Review decision | Attributable human label and rationale tied to exact evidence |
| Fixture suite | Approved examples used to test a contract without provider calls |

Deleting customer data must follow an explicit retention and deletion policy across database rows, object storage, logs, backups, and derived artifacts.

## 7. Major gaps from the spike

| Spike state | Product requirement | Why it matters |
|---|---|---|
| Four hard-coded RAG cases | Customer-owned, versioned monitors and evaluation contracts | Hard-coded facts do not generalize to arbitrary prompts |
| Evaluation embedded in run artifacts | Immutable observations plus separately versioned evaluations | Checkers must improve without recapturing provider outputs |
| Local JSON artifacts | Transactional metadata storage plus controlled object storage where needed | Multi-user access, querying, retention, and durability require stronger storage |
| Local files imply trust | Tenant isolation, authorization, audit logs, and secure secrets | Prompts, outputs, and credentials are sensitive customer data |
| CLI-only execution | Guided web onboarding, dry-run review, progress, cancellation, and result inspection | Users need a safe workflow, not internal Mix tasks |
| In-memory concurrent work | Durable scheduling, idempotency, retries, cancellation, and recovery | Hosted runs must survive deploys and worker failures without duplicate spend |
| One lexical statistic | Evidence-backed semantic strategy or a documented limitation | Lexical distance can miss factual substitutions and overreact to paraphrases |
| Manual artifact inspection | Explainable comparisons, alert lifecycle, and review UI | Human judgment is part of the product contract |
| One synthetic workload | Cross-domain, held-out, customer-labeled validation | Controlled RAG evidence cannot support general product claims |
| Basic call caps | Workspace budgets, quotas, cost estimates, provider rate limits, and billing attribution | Managed replay creates direct and potentially surprising spend |
| Raw provider bodies retained locally | Data minimization, field allowlists, encryption, retention, and deletion | Provider payloads may include sensitive data and unstable fields |
| Provider-specific Req clients | Stable adapter boundary and an evidence-based ReqLLM decision | Dependency choice must not leak into the domain model |

## 8. Hosted execution and ingestion

### 8.1 Onboarding flow

A safe initial flow should be:

1. Create a monitor and choose the provider/model.
2. Supply the prompt, frozen inputs/context, response requirements, and sampling plan.
3. Draft or author deterministic expectations.
4. Review positive and negative fixtures for the contract.
5. Validate credentials without exposing them.
6. Preview exact calls, concurrency, estimated tokens/cost where available, and retention behavior.
7. Explicitly authorize baseline capture.
8. Inspect baseline health before allowing calibration or scheduling.

No baseline should silently substitute a provider or model. A returned-model mismatch must remain visible even when the call succeeds.

### 8.2 Execution reliability

Hosted captures need durable job semantics with:

- idempotency keys for batches and provider calls where supported;
- immutable planned-versus-actual call accounting;
- workspace concurrency and spend limits;
- bounded, policy-driven retries counted against the budget;
- safe cancellation that stops scheduling new calls;
- recovery after deploys or process failure;
- progress events and terminal batch states; and
- separate provider, evaluation, storage, and internal failure categories.

Select a durable job mechanism during product architecture work; do not add a dependency to the spike merely to anticipate it.

### 8.3 Provider abstraction

Keep a normalized provider contract independent of Req, ReqLLM, or any provider SDK. Evaluate ReqLLM after the spike using the criteria already listed in optional Task 14: API coverage, exact provenance access, retry/call accounting, testability, returned-model fidelity, streaming needs, and maintenance cost. Adopt it only if it reduces adapter complexity without weakening those guarantees.

## 9. Privacy, security, and governance

Before accepting customer data, define and test:

- encryption in transit and at rest;
- secrets storage, rotation, scoping, and access auditing;
- strict tenant isolation and role-based access;
- prompt/output retention defaults and configurable deletion;
- log and telemetry redaction with field allowlists;
- whether raw provider payloads are necessary at all;
- regional storage and subprocessors;
- provider data-use settings and customer-visible configuration;
- export and deletion workflows;
- backup retention behavior;
- incident response and audit evidence; and
- prompt-injection boundaries for any LLM-assisted contract drafting or judging.

Customers must understand which data is sent to their selected provider and which data, if any, is sent to a separate model used for drafting or semantic evaluation. Cross-customer training or threshold pooling must be opt-in and separately justified.

## 10. Validation strategy beyond the spike

### 10.1 Evaluator conformance

For every deterministic primitive, maintain held-out valid paraphrases, invalid counterexamples, boundary values, malformed outputs, and adversarial cases. Measure false positives and false negatives by primitive and by monitor type. Do not count fixtures used to author a rule as held-out evidence.

### 10.2 Cross-case generalization

Build labeled suites across multiple domains and response shapes. At minimum, include structured extraction, grounded support answers, abstention, summarization, classification, and open synthesis before making broad claims. Use leave-case-out or leave-domain-out evaluation where practical.

### 10.3 Design-partner validation

Run in shadow mode with a small number of design partners. Customers review alerts without relying on them operationally. Measure:

- alert precision by outcome type;
- deterministic regression recall on approved mutations;
- harmless-change false-alert rate;
- review completion and disagreement rates;
- time from alert to confident decision;
- baseline/control stability over time;
- calls, tokens, latency, and provider failures; and
- the percentage of monitors for which customers can define useful expectations.

Targets should be set with design partners before the alpha, not inferred from the four spike cases. Report confidence intervals and sample counts rather than a percentage without its denominator.

### 10.4 Leakage controls

Keep contract-authoring examples, calibration data, threshold sources, and held-out evaluation data separately identified. Never tune a contract, judge prompt, or threshold on the same regressions used to report detection performance.

## 11. Productization phases and gates

### Phase 0 — Finish the feasibility spike

- Complete the v4 pilot baseline/control/calibration sequence.
- Obtain user approval for semantic fixtures.
- Run held-out sensitivity analysis.
- Expand providers/models only if the pilot gate passes.
- Produce the consolidated report and explicit proceed/stop verdict.

**Gate:** Do not begin product implementation unless the evidence shows useful separation with acceptable false alerts or a clearly valuable deterministic-only wedge.

### Phase 1 — Product core refactor

- Define monitor, case, observation, contract, evaluation, calibration, and review schemas.
- Extract reusable logic from `SilentRegression.Spike` into product-owned contexts rather than turning the spike namespace directly into production code.
- Add evaluator-engine versioning and offline rescoring.
- Add transactional persistence and artifact migration/import tooling.
- Preserve the provider behavior boundary and spend accounting.

**Gate:** Reproduce the accepted spike report from imported immutable observations without making provider calls.

### Phase 2 — Internal hosted alpha

- Build authenticated monitor onboarding and contract approval.
- Add secure provider credentials and exact dry-run authorization.
- Add durable execution, progress, cancellation, budgets, and scheduling.
- Build baseline-health, comparison-evidence, and review interfaces.
- Complete privacy, security, deletion, and audit requirements for internal data.

**Gate:** End-to-end internal monitors run repeatedly without provenance mixing, duplicate spend, silent failures, or untraceable decisions.

### Phase 3 — Design-partner shadow beta

- Onboard a narrow, explicitly selected audience and workload.
- Import or create representative monitors without a production SDK.
- Collect held-out review labels and operational evidence.
- Refine onboarding, contracts, thresholds, and review workflows without using evaluation data as calibration data.

**Gate:** Meet predeclared usefulness and false-alert targets on adequate customer-labeled samples. If only deterministic checks provide value, narrow the product claim rather than overstating drift detection.

### Phase 4 — Provider and workload expansion

- Add providers/models only after adapter and validation gates pass.
- Add new evaluator primitives based on repeated customer needs.
- Consider model-migration simulation as a distinct workflow.
- Consider supervised monitor-specific learning only after sufficient governed labels exist.

## 12. Migration from the spike

If the decision is to proceed:

1. Tag and preserve the final spike code, artifacts, case fingerprints, calibration, and report.
2. Write an importer that treats spike outputs as immutable observations and produces separately versioned evaluation records.
3. Define an evaluator-engine version from the accepted deterministic behavior.
4. Reproduce the spike metrics through the new domain model before changing algorithms.
5. Move reusable lexical/statistical and provider code behind product context boundaries.
6. Replace local storage incrementally, retaining exportable and inspectable artifacts for reproducibility.
7. Add the hosted workflow only after the domain and replay equivalence tests pass.

Do not migrate by renaming `SilentRegression.Spike` modules in place. The spike should remain a reproducible reference while production structures evolve around explicit contracts and persisted identities.

## 13. Open product decisions

These decisions require customer research or separate technical evaluation:

1. Which initial buyer and RAG workflow has enough pain and repeat volume to justify monitoring?
2. Will customers create all observations through managed replay, import historical samples, or use both?
3. Which ingestion formats are required if no production SDK is installed?
4. Who owns contract authoring and alert review inside a customer team?
5. What retention, residency, and redaction controls are required by the initial audience?
6. Should provider credentials be long-lived, short-lived, or supplied through a customer-controlled proxy?
7. What monitoring frequency and sample size deliver acceptable value and cost?
8. What is the pricing/value metric: monitored cases, scheduled runs, provider calls, seats, or another unit?
9. When is a semantic evaluator sufficiently reliable to complement human review?
10. What review volume is necessary before monitor-specific supervised learning is allowed?

## 14. Explicit non-goals until validated

- Universal correctness judgments for arbitrary prompts.
- Automatic contract changes based on an unreviewed output.
- A single global drift threshold across customers or models.
- Cross-customer learning without explicit governance and consent.
- Monitoring retrieval, corpus freshness, or ranking under the frozen-context RAG design.
- Production SDK instrumentation.
- Provider/model migration recommendations presented as equivalent to historical monitoring.
- Production accuracy or false-alert SLAs inferred from synthetic spike results.
