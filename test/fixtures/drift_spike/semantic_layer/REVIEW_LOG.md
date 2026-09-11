# Semantic fixture review log

This log records explicit human judgments without mutating the immutable
candidate artifacts. Once all 120 judgments are complete, an approved fixture
set will be created as a new artifact; the two candidate files remain intact.

## Evidence under review

- Generator commit: `a8e4802fcfae1c02b70d87b1df0f8663b4a38244`
- Candidate capture commit: `621c57a`
- Tuning candidate SHA-256:
  `ba7de36e1801296b99270c05a3f3cd641da3f47402d978eef3bdf63c6e204d8a`
- Held-out candidate SHA-256:
  `89a2b5799d13437e191dcdf67b3af278c3cc01e193cd7f5122556480e3be992d`
- Review method: explicit product-owner judgment in the Codex task, after the
  provenance-checked original and three derivatives were presented together.

## Progress

- Approved: 120/120 judgments — complete
- Tuning: 60/60 approved — complete
- Held-out: 60/60 approved — complete
- Corrections requested: 0

## Decisions

### 2026-09-10 — tuning parents 1–5

- Scope: source sample indexes 0–4, inclusive.
- Fixtures: 15 total; meaning-preserving, style-only, and subtle-regression for
  each parent.
- Decision: all 15 proposed labels, expected contract outcomes, failure modes,
  and rationales approved without correction.
- Explicit approval: `Approve tuning parents 1–5`.

### 2026-09-10 — tuning parents 6–10

- Scope: source sample indexes 5–9, inclusive.
- Fixtures: 15 total; meaning-preserving, style-only, and subtle-regression for
  each parent.
- Decision: all 15 proposed labels, expected contract outcomes, failure modes,
  and rationales approved without correction.
- Explicit approval: `Approve tuning parents 6–10`.

### 2026-09-10 — tuning parents 11–15

- Scope: source sample indexes 10–14, inclusive.
- Fixtures: 15 total; meaning-preserving, style-only, and subtle-regression for
  each parent.
- Decision: all 15 proposed labels, expected contract outcomes, failure modes,
  and rationales approved without correction.
- Explicit approval: `Approve tuning parents 11–15`.

### 2026-09-10 — tuning parents 16–20

- Scope: source sample indexes 15–19, inclusive.
- Fixtures: 15 total; meaning-preserving, style-only, and subtle-regression for
  each parent.
- Decision: all 15 proposed labels, expected contract outcomes, failure modes,
  and rationales approved without correction. This completes the tuning
  partition at 60/60 approved judgments.
- Explicit approval: `Approve tuning parents 16–20`.

### 2026-09-10 — held-out parents 1–5

- Scope: source sample indexes 0–4, inclusive.
- Fixtures: 15 total; meaning-preserving, style-only, and subtle-regression for
  each parent.
- Decision: all 15 proposed labels, expected contract outcomes, failure modes,
  and rationales approved without correction.
- Held-out boundary: no benchmark was run and no evaluator, representation,
  threshold, weight, or seed was changed during review.
- Explicit approval: `Approve held-out parents 1–5`.

### 2026-09-10 — held-out parents 6–10

- Scope: source sample indexes 5–9, inclusive.
- Fixtures: 15 total; meaning-preserving, style-only, and subtle-regression for
  each parent.
- Decision: all 15 proposed labels, expected contract outcomes, failure modes,
  and rationales approved without correction.
- Held-out boundary: no benchmark was run and no evaluator, representation,
  threshold, weight, or seed was changed during review.
- Explicit approval: `Approve held-out parents 6–10`.

### 2026-09-10 — held-out parents 11–15

- Scope: source sample indexes 10–14, inclusive.
- Fixtures: 15 total; meaning-preserving, style-only, and subtle-regression for
  each parent.
- Decision: all 15 proposed labels, expected contract outcomes, failure modes,
  and rationales approved without correction.
- Held-out boundary: no benchmark was run and no evaluator, representation,
  threshold, weight, or seed was changed during review.
- Explicit approval: `Approve held-out parents 11–15`.

### 2026-09-10 — held-out parents 16–20

- Scope: source sample indexes 15–19, inclusive.
- Fixtures: 15 total; meaning-preserving, style-only, and subtle-regression for
  each parent.
- Decision: all 15 proposed labels, expected contract outcomes, failure modes,
  and rationales approved without correction. This completes the held-out
  partition and all 120 fixture judgments.
- Held-out boundary: no benchmark was run and no evaluator, representation,
  threshold, weight, or seed was changed during review.
- Explicit approval: `Approve held-out parents 16–20`.

## Remaining batches

- None. All candidate judgments have explicit product-owner approval.

## Promotion

- Promotion implementation revision:
  `cf032248e6bb05ff2e25923f18017992ceaa8157`.
- Reviewer recorded on every fixture: `product_owner`.
- Reviewed at: `2026-09-11T03:46:46Z`.
- Approved tuning fixture set:
  `semantic-pairs-tuning-control-20260909T143004Z-1-v1-approved`.
- Approved tuning SHA-256:
  `0fb83b02e6573ceadb058aa9900b1ab717f888d3f09a25d274c6e72991d712e4`.
- Approved held-out fixture set:
  `semantic-pairs-heldout-control-20260910T042832Z-1-v1-approved`.
- Approved held-out SHA-256:
  `6fdbfef04ee5a23c90223c295406982f39fbb4ccbc4cc912d6d2fc4ce4c7614b`.
- Candidate artifacts remained byte-for-byte unchanged.
- Provider calls: 0.
