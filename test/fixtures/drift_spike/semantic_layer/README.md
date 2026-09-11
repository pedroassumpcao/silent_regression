# Semantic fixture artifacts

These artifacts are the reviewed evidence for Follow-up Task B in
`plans/semantic_layer_plan.md`. The original candidates remain immutable, and
the separately generated approved copies are the only versions eligible for
the semantic benchmark.

## Allocation

- `candidates/tuning-pairs.json`: 20 parents from
  `control-20260909T143004Z-1`, with 60 proposed judgments.
- `candidates/heldout-pairs.json`: 20 parents from
  `control-20260910T042832Z-1`, with 60 proposed judgments.
- `approved/tuning-pairs.json`: the 60 explicitly approved tuning judgments.
- `approved/heldout-pairs.json`: the 60 explicitly approved held-out
  judgments, now frozen against evaluator or benchmark tuning.
- Every parent has a meaning-preserving rewrite, a style-only restyle, and a
  subtle regression.
- Derivatives never cross partitions. Every label batch contains 20 unique
  parents and 20 unique outputs; candidate outputs do not overlap across the
  two partitions.
- Candidate within-Jaccard diversity is 0.98x-1.08x the corresponding parent
  diversity. This is a fixture-distribution diagnostic, not a semantic quality
  score or representation-selection result.

The approved Task 10 fixtures are authoring references only. The baseline and
the remaining compatible controls are reserved for null calibration.

## Review workflow

Review tuning first in four five-parent pages:

```console
mix drift_spike.review_semantic_pairs \
  --fixtures test/fixtures/drift_spike/semantic_layer/candidates/tuning-pairs.json \
  --source results/drift_spike/control-20260909T143004Z-1.json \
  --from 1 \
  --count 5
```

Repeat with `--from 6`, `11`, and `16`. Then review held-out in the same four
pages:

```console
mix drift_spike.review_semantic_pairs \
  --fixtures test/fixtures/drift_spike/semantic_layer/candidates/heldout-pairs.json \
  --source results/drift_spike/control-20260910T042832Z-1.json \
  --from 1 \
  --count 5
```

For each candidate, verify:

1. `meaning_preserving` retains every material fact, distinction, constraint,
   and source attribution while changing the wording.
2. `style_only` changes presentation but not meaning. Here it numbers the
   source paragraphs without rewriting their contents.
3. `subtle_regression` contains the one stated semantic defect, keeps the other
   facts intact, and has an accurate failure mode and rationale.

Approve all three candidates for a parent, or identify the fixture ID and the
required correction. The review command is read-only: it makes no provider
calls and writes no approval.

## Held-out boundary

Held-out judgments may be corrected before the artifact is approved and
sealed. Once sealed, do not change semantic evaluator behavior,
representations, weights, thresholds, or predeclared seeds in response to its
benchmark results. If the gate fails, report the failure rather than retuning
on this partition.

## Promotion workflow

After all 120 judgments are recorded as complete, validate the exact candidate
hashes and preview the immutable approved copies:

```console
mix drift_spike.promote_semantic_pairs \
  --tuning test/fixtures/drift_spike/semantic_layer/candidates/tuning-pairs.json \
  --heldout test/fixtures/drift_spike/semantic_layer/candidates/heldout-pairs.json \
  --review-log test/fixtures/drift_spike/semantic_layer/REVIEW_LOG.md \
  --reviewer product_owner \
  --output test/fixtures/drift_spike/semantic_layer/approved \
  --dry-run
```

Remove `--dry-run` only after checking the preview. Promotion creates new files
and refuses existing destinations; it never edits the reviewed candidates.

The completed promotion used implementation revision
`cf032248e6bb05ff2e25923f18017992ceaa8157` and reviewer `product_owner` at
`2026-09-11T03:46:46Z`. The immutable approved artifact hashes are:

- tuning: `0fb83b02e6573ceadb058aa9900b1ab717f888d3f09a25d274c6e72991d712e4`
- held-out: `6fdbfef04ee5a23c90223c295406982f39fbb4ccbc4cc912d6d2fc4ce4c7614b`

Promotion made zero provider calls. A repository test verifies both hashes and
proves that every judgment field still matches its reviewed candidate.
