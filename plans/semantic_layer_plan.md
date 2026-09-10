# Silent Regression Next-Layer Experiment Plan

> **Status:** Proposed after the Task 11 lexical decision gate; not yet authorized
>
> **Last revised:** 2026-09-10
>
> **Purpose:** Define the separate experiment required before making label-free semantic-drift claims or expanding the provider/model matrix

This plan is a follow-up to the [feasibility spike](implementation_plan.md). It does not change the frozen v4 baseline, controls, calibration, approved Task 10 fixtures, or Task 11 result. It is not authorization to add embeddings, an LLM judge, dependencies, or live provider calls. Finish the original spike report first, then explicitly choose whether to run this experiment or pursue a deterministic-only product wedge.

## 1. Why this follow-up exists

Task 11 evaluated the 28 approved fixtures using the frozen OpenAI `gpt-5.6-luna` artifacts, seed `20260907`, and 999 permutations per case. The immutable local result is `results/drift_spike/fixture-comparison-20260910T152531Z-1.json`.

The result failed the lexical decision gate:

- the independent held-out control produced 0 drift reviews across 4 case comparisons;
- harmless-rewording and style-only batches produced 7 drift reviews across 8 case comparisons, an 87.5% false-review rate;
- the pure subtle-regression batch produced drift reviews for all 4 cases, but that is not useful separation because the harmless batches also alerted;
- mixed regressions produced drift reviews for 0/4 cases at 10%, 2/4 at 25%, and 4/4 at 50%; and
- combined deterministic-or-drift signals appeared in 19/20 seeded-regression case comparisons, but this aggregate includes deterministic failures and must not be presented as label-free semantic recall.

The failure is technically informative. Jaccard word sets react strongly to valid vocabulary and presentation changes, and the approved pure batches cycle one to three fixtures to reach 20 samples. That repeated-output concentration lowers within-candidate variability and magnifies energy distance for both harmless and harmful batches. The mixed batches reduce that concentration problem, but they also show that the lexical layer misses low-rate semantic changes.

The conclusion is therefore scoped: the current Jaccard distribution signal is not suitable for user-facing review alerts on these open-ended RAG outputs. This does not invalidate the deterministic evaluator results, and it does not establish that every semantic approach will fail.

## 2. Follow-up objective

Determine whether an explainable, monitor-specific semantic layer can distinguish supported meaning-preserving variation from grounded RAG failures at useful failure rates, without weakening provenance, calibration isolation, or human-review boundaries.

The experiment should answer:

1. Can a non-cycled, diversity-matched fixture design measure false alerts fairly?
2. Can generic, configured primitives detect citation misattribution, unsupported claims, omissions, and failed abstention across different case content rather than hard-coded phrases?
3. Can a cheap representation improve open-synthesis drift separation before introducing an external semantic model?
4. If a model-based semantic layer is necessary, does its incremental accuracy justify its cost, latency, privacy exposure, and reproducibility risk?

## 3. Experimental corrections before another metric

The next experiment must correct the fixture-distribution confound before comparing algorithms.

### 3.1 Diversity-matched paired batches

For the open-synthesis pilot, start from 20 distinct held-out control outputs and create paired derivatives:

- one meaning-preserving rewrite per source output;
- one style-only rewrite per source output;
- one subtle semantic regression per source output; and
- optional obvious regressions for sanity checks, kept out of tuning decisions.

Each derived batch must therefore contain 20 distinct outputs rather than cycling a small pool. Preserve a stable parent observation ID so every derivative can be inspected beside the original. Report within-candidate diversity and duplicate counts before calculating drift.

Codex may draft these derivatives, but the user must approve each label. Authoring examples and any algorithm-tuning subset must be separated from the final held-out evaluation subset. A future customer workflow will need the same distinction between contract-authoring examples and evidence used to report performance.

### 3.2 Preserve historical evidence

- Do not modify or overwrite the v4 baseline, controls, calibration, Task 10 fixtures, or Task 11 comparison.
- Store each new representation's calibration in a new immutable artifact with its method and version.
- Use baseline/control observations only for threshold calibration.
- Do not tune thresholds, weights, or prompts on the held-out regression labels used for final sensitivity reporting.

## 4. Candidate layers, in order

### Layer A — field-aware and attribution-aware deterministic contracts

Extend generic contract primitives, not case-specific output phrases:

- associate claims or requested fields with the source IDs allowed to support them;
- detect required facts and quantities independently from surrounding prose;
- detect forbidden or unsupported quantities, entities, and source IDs;
- express omissions as required fact groups; and
- preserve explicit abstention policies.

The case-specific values remain data in a versioned contract. The evaluator code should implement reusable operations over different contracts and baselines. This layer can establish degradation direction and should remain separate from label-free drift.

### Layer B — cheaper representation benchmark

Before adding an external model, compare a small set of locally reproducible representations:

- word n-grams that retain limited ordering;
- character n-grams that tolerate punctuation and formatting differences; and
- field-aware feature sets for outputs with recoverable structure.

Any corpus-derived vocabulary or weighting must be fitted using baseline/control data only. Apply the same energy-distance, seeded permutation, multiple-comparison, and frozen-null discipline used in the original spike. Do not select the winner on final held-out regression outcomes.

This layer advances only if it materially reduces harmless false reviews while retaining subtle open-synthesis sensitivity. Merely changing which acceptable examples alert is not an improvement.

### Layer C — separately approved model-based semantics

If the cheap benchmark fails, stop again before implementation and evaluate embeddings, claim entailment, or an LLM judge as separate options. The evaluation must cover:

- provider and model choice, pinning, and deprecation behavior;
- per-sample and per-monitor cost and latency;
- whether customer content is sent to another provider;
- retention, regional processing, and credential implications;
- deterministic reproducibility and cached immutable inputs;
- calibration drift when the evaluator model changes;
- retry and spend accounting; and
- adversarial cases where a fluent but unsupported answer receives a high semantic-similarity score.

An LLM-derived score is evidence, not ground truth. It must produce inspectable claim-level reasons and continue to route ambiguous cases to human review.

## 5. Proposed implementation tasks

### Follow-up Task A — Benchmark and artifact contracts

Define versioned paired-fixture, representation, calibration, and result schemas. Record parent observation IDs, fixture approval, authoring/tuning/held-out split, duplicate counts, and method versions.

**Gate:** Schema tests prove that approved labels cannot enter null calibration and that Task 11 artifacts remain unchanged.

### Follow-up Task B — Unique paired fixture candidates

Draft diversity-matched open-synthesis derivatives from distinct held-out outputs. Stop for human review before promotion. Do not cycle fixtures to reach a target sample size.

**Gate:** The user approves every semantic label and the final held-out partition is frozen.

### Follow-up Task C — Generic contract primitives

Implement and test field/fact/source-attribution relationships as reusable configured evaluators. Rescore all approved examples without changing the stored observations.

**Gate:** Held-out valid paraphrases do not fail, and approved attribution, unsupported-claim, omission, and abstention regressions produce explainable failures where the contract provides enough information.

### Follow-up Task D — Cheap representation benchmark

Implement the approved local representations behind a common behavior. Calibrate each one only from the existing compatible baseline/control pools, freeze new thresholds, and evaluate the diversity-matched held-out batches.

**Gate:** At most 10% of harmless held-out batch comparisons request drift review; at least one subtle open-synthesis batch requests review; and the result is stable across predeclared seeds. If no representation passes, do not combine or retune them on held-out labels.

### Follow-up Task E — Next decision

Produce a comparison report with per-case denominators, false reviews, sensitivity by seeded failure rate, latency, and operational cost.

Choose one:

- `CHEAP_LAYER_PROMISING` — resume controlled provider/model expansion using the new frozen method;
- `DETERMINISTIC_ONLY_WEDGE` — stop label-free drift work and validate a contract-first product with design partners;
- `EVALUATE_MODEL_BASED_SEMANTICS` — approve a new research/implementation plan for embeddings, entailment, or an LLM judge; or
- `STOP_TECHNICAL_VALIDATION` — the expected value does not justify another layer.

## 6. Product interpretation

The deterministic results support further investigation of a contract-first product: customers provide or approve explicit facts, fields, citations, abstention rules, and tolerances, while ambiguous changes go to review. They do not yet justify a claim that Silent Regression generically understands arbitrary prompt outputs.

The [productization plan](productization_plan.md) remains the broader hosted-product reference. This experiment should change that plan only after a new gate passes and the user chooses a product direction.
