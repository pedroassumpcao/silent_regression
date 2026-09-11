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

- Approved: 90/120 judgments
- Tuning: 60/60 approved — complete
- Held-out: 30/60 approved
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

## Remaining batches

- [ ] Held-out parents 11–15
- [ ] Held-out parents 16–20
