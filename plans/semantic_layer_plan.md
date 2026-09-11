# Silent Regression Next-Layer Experiment Plan

> **Status:** Follow-up Tasks A-D complete; Task D gate failed and Task E is next
>
> **Last revised:** 2026-09-11
>
> **Purpose:** Define the separate experiment required before making label-free semantic-drift claims or expanding the provider/model matrix

This plan is a follow-up to the [feasibility spike](implementation_plan.md). The user authorized the staged local experiment after approving the Task 13 verdict. It does not change the frozen v4 baseline, controls, calibration, approved Task 10 fixtures, or Task 11 result. The authorization covers the local artifact, paired-fixture, generic-contract, and cheap-representation tasks; it does not authorize Layer C model-based semantics, new dependencies, or live provider calls.

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

**Status:** Complete

Define versioned paired-fixture, representation, calibration, and result schemas. Record parent observation IDs, fixture approval, authoring/tuning/held-out split, duplicate counts, and method versions.

**Gate:** Schema tests prove that approved labels cannot enter null calibration and that Task 11 artifacts remain unchanged.

**Result:** Added strict, versioned JSON-compatible contracts for paired fixture sets, representation specifications, semantic calibrations, and benchmark results, plus atomic no-overwrite storage restricted to those artifact types. Parent observations cannot cross authoring/tuning/held-out partitions; every parent must have meaning-preserving, style-only, and subtle-regression derivatives with consistent provenance; stored duplicate counts must match the actual outputs; representation fitting and null calibration accept only baseline/control sources and explicitly exclude fixture labels; and final benchmark results accept held-out batches only with one unique parent per sample and every predeclared seed. Focused tests round-trip all four contracts, exercise leakage failures, and prove that the semantic storage boundary refuses Task 11 artifact types without changing their bytes.

### Follow-up Task B — Unique paired fixture candidates

**Status:** Complete

Draft diversity-matched open-synthesis derivatives from distinct held-out outputs. Stop for human review before promotion. Do not cycle fixtures to reach a target sample size.

**Gate:** The user approves every semantic label and the final held-out partition is frozen.

**Review progress:** 120/120 judgments approved. On 2026-09-10, the product owner completed the tuning and held-out reviews and explicitly approved all three proposed judgments for every parent, with no corrections. No benchmark was run and no evaluator, representation, threshold, weight, or seed was changed during held-out review. The candidate artifacts remain immutable and unapproved by design; the complete decisions are recorded in the semantic review log and were applied only to separately generated approved fixture artifacts.

**Promotion result:** Promotion revision `cf032248e6bb05ff2e25923f18017992ceaa8157` verified the complete review log against both exact candidate hashes, required 20 distinct parents and 60 judgments in each split, and refused cross-split parent, fixture-ID, or output overlap. It created approved tuning artifact SHA-256 `0fb83b02e6573ceadb058aa9900b1ab717f888d3f09a25d274c6e72991d712e4` and approved held-out artifact SHA-256 `6fdbfef04ee5a23c90223c295406982f39fbb4ccbc4cc912d6d2fc4ce4c7614b`, with reviewer `product_owner` and timestamp `2026-09-11T03:46:46Z`. The candidate bytes did not change, zero provider calls were made, and a repository test freezes both approved hashes and checks content equivalence apart from approval metadata. The held-out partition is now sealed; Task B's gate is satisfied.

**Candidate result:** The existing approved Task 10 examples remain authoring references. Control `control-20260909T143004Z-1` supplies 20 distinct tuning parents and control `control-20260910T042832Z-1` supplies 20 distinct held-out parents. Each parent has one meaning-preserving rewrite, one presentation-only restyle, and one controlled subtle regression, producing 60 candidates per split and 120 judgments in total. The regressions cover small changes to crossing time, target year, fleet size, habitat-window start, and speed cap, plus pile-driving reversal and wrong source attribution; Task 10 retains the broader omission, unsupported-claim, and abstention authoring examples. Every label batch has 20 unique parents and 20 unique outputs, the two splits have zero candidate-output overlap, and all 80 proposed valid candidates pass the frozen v4 deterministic checks. The artifacts remain `candidate`; no approval identity or timestamp has been recorded.

The lexical diagnostic confirms that uniqueness is substantive rather than a changed prefix on a repeated template. Tuning candidate within-Jaccard means are 0.345909, 0.341914, and 0.367166 for meaning-preserving, style-only, and subtle-regression batches versus 0.348307 for their parents. Held-out means are 0.318068, 0.288057, and 0.314121 versus 0.293690. Drafting refuses a batch whose within-candidate mean falls below 75% of its parent mean. These values describe fixture-distribution quality only; they are not semantic performance results and will not select or tune a representation.

Review uses `mix drift_spike.review_semantic_pairs` in five-parent pages. The task validates the exact source artifact hash and every parent output hash before rendering the original beside its three derivatives. Review the tuning split first, then the held-out split. Held-out judgments may correct fixture labels or fixture text before sealing, but they must never drive evaluator logic, representation choice, weights, thresholds, or seeds. No benchmark is run until those choices are predeclared and frozen.

### Follow-up Task C — Generic contract primitives

**Status:** Complete

Implement and test field/fact/source-attribution relationships as reusable configured evaluators. Rescore all approved examples without changing the stored observations.

**Gate:** Held-out valid paraphrases do not fail, and approved attribution, unsupported-claim, omission, and abstention regressions produce explainable failures where the contract provides enough information.

**Result:** Added reusable JSON-field equality, normalized required/forbidden fact, fact-to-source attribution, allowed-source, grouped-fact, and abstention operations. Monitor-specific values live in versioned contract data tied to the frozen source-case fingerprints; the original cases and observations were not edited. Contract set `rag-semantic-contracts-v1` has fingerprint `ed622e2939fff8a3d8090f741242cc44fba8caab793833d56c26b4416b69b2cd`. The source citation primitive treats an exact bracketed source ID as trailing support for the immediately preceding citation segment and returns the matched fact, observed source IDs, and reason for every failure.

The evaluator was tuned only against the 28 Task 10 authoring fixtures and 60 approved tuning fixtures. That pre-held-out pass matched 88/88 judgments: 52/52 expected-valid outputs passed and 36/36 expected regressions failed. The method was then frozen in revisions `2579285`, `12047d9`, and `d455be7` before opening the held-out artifact.

The immutable held-out rescore `semantic-contract-rescore-heldout-20260911T125722Z-1` at `results/drift_spike/semantic-contract-rescore-heldout-20260911T125631Z-1.json` has SHA-256 `f66853f5c3aa54503e959a96799008e7bdec8326dfc4f93280ea10ca525605da`. It again matched 88/88 combined authoring and held-out judgments: all 52 expected-valid outputs passed, including 40/40 held-out paraphrase/style fixtures, and all 36 expected regressions failed, including 20/20 held-out regressions. Across the non-mutually-exclusive failure-mode labels, it detected constraint reversal 3/3, failed abstention 3/3, omission 2/2, unsupported claim 5/5, wrong attribution 9/9, and wrong fact 19/19. Every fixture result retains its contract fingerprint and explainable per-check evidence. The task made zero provider calls, and all previously frozen artifact hashes remained unchanged. Task C's gate is satisfied.

These counts establish conformance on the reviewed fixture suites, not general semantic recall. In particular, unsupported-claim detection remains limited to configured forbidden facts, and citation attribution remains limited to the declared trailing-bracket convention. Unconfigured meanings still require review or a separately approved semantic layer.

### Follow-up Task D — Cheap representation benchmark

**Status:** Complete; held-out gate failed

Implement the approved local representations behind a common behavior. Calibrate each one only from the existing compatible baseline/control pools, freeze new thresholds, and evaluate the diversity-matched held-out batches.

**Gate:** At most 10% of harmless held-out batch comparisons request drift review; at least one subtle open-synthesis batch requests review; and the result is stable across predeclared seeds. If no representation passes, do not combine or retune them on held-out labels.

**Implementation and null calibration:** The three local methods use one behavior and the unchanged energy-distance/permutation engine with method-specific sparse cosine distances. Word unigrams/bigrams retain local order; character 3-5-grams operate inside normalized word boundaries; and field-aware features extract generic JSON paths/values, citations, quantities, normalized polarity, and segment-local citation relationships. Sublinear term frequency and smoothed inverse-document frequency are fitted from 70 unlabeled null observations only: 30 baseline observations plus the 20-sample controls `control-20260908T141227Z-1` and `control-20260909T005844Z-1`. The tuning-parent control and held-out-parent control are explicit excluded fit sources. Calibration uses seed `20260907`, 2,000 resamples, the 0.95 quantile, baseline/control group sizes 30/20, and adjusted-p alpha 0.05. Evaluation uses 999 permutations at predeclared seeds `20260907`, `20260917`, and `20260927`; each seed corrects one family containing every representation/batch comparison.

**Tuning iteration v1:** Immutable result `results/drift_spike/semantic-layer/semantic-benchmark-method-selection-v1.json` has SHA-256 `ace8a0230140658596b9197c4ba9578f457a750624c9ababd24810997772e1bf`. Word n-grams requested review for 6/6 harmless comparisons and 0/3 subtle comparisons; character n-grams did the same. Field-aware v1 requested review for 3/6 harmless and 3/3 subtle comparisons. Inspection showed a generic extractor defect: Markdown ordered-list counters such as `1.` and `2.` were treated as semantic quantities. No held-out fixture was read.

**Tuning iteration v2 and freeze:** Field-aware v2 ignores ordered-list counters while retaining real quantities, with a regression test covering the generic rule. Immutable tuning result `results/drift_spike/semantic-layer/semantic-benchmark-method-selection-v2.json` has SHA-256 `386bf13a2b03b044d54db7b8e799ce0a5bdc0b3c3585a42797613d2d78088cc7`. Field-aware v2 requested 0/6 harmless reviews and 3/3 subtle reviews, with identical decisions across all three seeds and a positive separation margin of `0.22056770806112264`; it was the only passing method. Word and character n-grams remained rejected. The exact selected representation SHA-256 is `008008ee5063d1fa4013c7ee267ea7bb3eaa2ae65bf9ba58aaaf8cc858179951`, its calibration SHA-256 is `5ecb5787e07cb28a59ac3cfc93953dd1f5ccc8dc68de4c7791bb62e3d2f8a794`, and its frozen threshold is `0.028746273348138673`.

The machine-validated pre-held-out manifest at `priv/drift_spike/semantic_layer/cheap-benchmark-freeze-v1.json` pins the selected method, method revision `e1ba4220c0c08613e420c24d527ce3d33a4ed5b4`, parameters, threshold, tuning result, seeds, correction family, and held-out fixture hash. The final task refuses a dirty worktree or any hash/settings mismatch and opens the held-out fixture only after all freeze checks pass. No held-out benchmark result exists at this point, and all Task D work has made zero provider calls.

**Held-out result:** After commit `386a0b4` froze every decision above, the final task evaluated field-aware v2 once against the approved held-out fixture set. Immutable result `results/drift_spike/semantic-layer/semantic-benchmark-final-evaluation-v1.json` has SHA-256 `6c40506e6ad7532059012a27756373941d2798eb65db467c637b3f6b28ca5d5d`. The method requested review for 3/6 harmless comparisons (50%), comprising the meaning-preserving batch on all three seeds; it did not request review for the style-only batch. It requested review for the subtle-regression batch on all three seeds. All three batch decisions were stable across seeds, but the harmless rate exceeded the 10% maximum, so Task D's gate failed.

The held-out failure exposes a general compositional limitation rather than a case-specific phrase mismatch. The valid held-out rewrites use constructions such as “not permitted.” Field-aware v2 emits a normalized negative feature for “not” and, independently, a positive feature for “permitted”; it cannot represent that the negation scopes over the permission. The unseen valid construction therefore looks like a distributional semantic change. Fixing negation scope after viewing this result would be held-out tuning, so the method, threshold, and result remain unchanged and no second held-out run is allowed. Cheap handcrafted features have not earned a user-facing label-free drift claim.

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

## 7. Decision log

- **2026-09-10:** The user selected the semantic-layer experiment before the optional ReqLLM evaluation. The experiment will retain the working Req transports so representation quality remains the isolated variable.
- **2026-09-10:** Follow-up Task A adopted strict internal Elixir contracts rather than a new schema dependency, matching the completed spike's serialization approach. Parent-level partition isolation and baseline/control-only fit sources make leakage violations invalid artifacts rather than reporting conventions. The frozen Task 11 baseline, calibration, fixture comparison, and approved fixture manifest hashes remained unchanged.
- **2026-09-10:** Follow-up Task B allocated the September 9 control to tuning and the September 10 independent control to held-out evaluation. All derivatives of a parent remain in the same split. Candidate generation is local and call-free, and review is provenance-checked and read-only. The held-out benchmark may run only after evaluator and representation settings are frozen, preventing final-label performance from becoming a tuning input.
- **2026-09-11:** Follow-up Task C froze generic contract operations and versioned monitor data after authoring/tuning conformance reached 88/88, then evaluated the sealed held-out split without changing the method. The held-out rescore matched all 40 valid and 20 regression paired judgments, while the included Task 10 authoring set retained 28/28 agreement. This supports a contract-first deterministic layer within configured scope; it does not turn explicit forbidden-fact lists or trailing citation rules into general semantic understanding.
- **2026-09-11:** Follow-up Task D fitted three cheap representations from baseline and two calibration-only controls, excluding both fixture-parent controls. Tuning v1 revealed that ordered-list counters polluted field-aware quantity features; a generic, versioned v2 correction was made using tuning only. Field-aware v2 then passed the predeclared tuning gate and was frozen as the sole held-out candidate. The tracked freeze manifest was committed before any Task D held-out evaluation; neither n-gram method may be combined with it, and no setting may change after viewing held-out outcomes.
- **2026-09-11:** The single frozen Task D held-out evaluation detected the subtle batch consistently but falsely reviewed the meaning-preserving batch consistently, yielding a 50% harmless-review rate against the 10% gate. The post-result audit traced this to missing compositional negation handling for valid phrases such as “not permitted.” No post-held-out fix, combination, or rerun was performed. Task E must choose between the already-supported deterministic-only wedge, a separately approved model-based semantic evaluation, or stopping technical validation.
