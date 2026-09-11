# Semantic fixture review

These artifacts are candidate-only evidence for Follow-up Task B in
`plans/semantic_layer_plan.md`. They are not production fixtures and cannot be
used by the semantic benchmark until every judgment is explicitly approved.

## Allocation

- `candidates/tuning-pairs.json`: 20 parents from
  `control-20260909T143004Z-1`, with 60 proposed judgments.
- `candidates/heldout-pairs.json`: 20 parents from
  `control-20260910T042832Z-1`, with 60 proposed judgments.
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
