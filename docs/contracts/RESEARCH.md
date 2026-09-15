# Deterministic Contract Engine Research

## Scope

Task 7 defines the product-owned contract language and the pure evaluator that interprets an
immutable output. It does not add contract authoring screens or approval persistence (Task 8), and
it does not add durable capture runs, observations, evaluations, or rule-result tables (Task 9).

The task nevertheless defines immutable in-memory observation and evaluation records. That lets
Task 9 persist the exact semantics without coupling provider execution to evaluator internals, and
it proves that the same observation can be rescored into a new evaluation record.

## Product boundary

The engine can determine only whether customer-approved, machine-checkable expectations hold. It
does not infer correctness from a baseline, detect general semantic drift, or decide whether an
unconstrained answer is good. Literal text checks recognize only alternatives declared in the
monitor's contract.

The spike remains isolated. Its generic lessons informed this design, but product code does not
call `SilentRegression.Spike`, import its RAG cases, accept its arbitrary regular expressions, or
contain any of its fixture-specific facts.

## Approaches considered

### Full JSON Schema plus custom text extensions

JSON Schema is capable for structured output, but it would introduce a large authoring surface and
a second error/evidence model before the alpha establishes which constraints customers actually
need. Custom non-JSON extensions would still be necessary for labels, literal facts, abstention,
and citations.

### Reuse the spike check maps directly

The spike checks proved useful mechanics, but their schema permits fixture-shaped operations and
customer-supplied regular expressions. They also conflate malformed contracts with ordinary failed
checks and do not provide independently versioned engine records.

### Bounded declarative DSL (selected)

Version 1 uses a deliberately small recursive JSON document. Every rule has a stable customer-
visible ID. Composite rules express `all`, `any`, and `not`; leaf rules cover the deterministic
requirements selected for the private alpha. Unknown fields and rule types fail parsing.

This design is easier to render as Task 8 forms, easier to explain per rule, and safer to evaluate
against untrusted customer content. A later schema version can add a repeatedly requested primitive
without silently changing existing contracts.

## Contract envelope

A contract contains:

- `schema_version`, fixed at `1`;
- a stable `contract_id` and positive `contract_version`;
- the owning `monitor_id` so configuration cannot be treated as global truth; and
- one root rule, usually an `all` group.

The parser computes a SHA-256 fingerprint from the schema version and normalized root rule. Identity
and version remain separate provenance, so two versions with byte-equivalent behavior have the same
content fingerprint while retaining distinct identities.

The authoritative machine-readable interchange schema is
[`deterministic-contract-v1.schema.json`](deterministic-contract-v1.schema.json). Runtime parsing is
stricter than merely decoding JSON: input must use string keys, contain only known fields, obey all
bounds, contain unique rule IDs, and use only version-1 operations.

## Version-1 primitives

### JSON

- `json_valid` requires one strict raw JSON value. Markdown fences or surrounding prose are not JSON.
- `json_path_exists` requires an RFC 6901 JSON Pointer to resolve.
- `json_path_type` checks `object`, `array`, `string`, `number`, `integer`, `boolean`, or `null`.
- `json_path_equals` compares an exact JSON value with explicit `strict` or `mathematical` numeric
  semantics.
- `json_path_allowed_values` requires equality with one configured value.
- `json_path_number` supports inclusive minimum/maximum bounds and/or an inclusive target tolerance.

The empty pointer addresses the document root. Pointer tokens use RFC 6901 `~0` and `~1` escaping;
array indices are canonical non-negative integers without leading zeroes. Duplicate object keys are
rejected because accepting a parser's last-key-wins behavior would make a contract ambiguous.

### Classification and literal text

- `classification` compares the entire normalized output with an allowed label.
- `required_text` requires any configured literal alternative.
- `forbidden_text` fails when any configured literal alternative is present.
- `required_abstention` requires any customer-approved abstention alternative.

Normalization is fixed as `unicode-casefold-tokens-v1`: validate UTF-8, apply Unicode NFKC, apply
full Unicode case folding, replace non-letter/non-number runs with one space, collapse whitespace,
and trim. Matching uses complete normalized token sequences, so `six` does not match `sixteen`.
This deliberately erases punctuation and compatibility distinctions for configured labels and
phrases only. It is not a semantic similarity or drift claim.

`required_abstention` proves only that an approved abstention phrase is present. When an invented
answer must also be prohibited, Task 8 composes it with an explicit `forbidden_text` rule. The engine
does not guess unsupported-claim patterns.

### Citations

The documented alpha citation syntax is an exact bracketed source ID such as `[policy-7]`. IDs are
case-sensitive and restricted to ASCII letters, numbers, `.`, `_`, `:`, and `-`. Markdown links do not
count as citations.

- `required_source_ids` requires every configured ID.
- `allowed_source_ids` rejects cited IDs outside a configured set and may require at least one.
- `fact_citation` requires one declared literal fact and one allowed trailing source ID in the same
  sentence segment, within a configured character distance.

Citation parsing uses only a fixed application-owned regular expression. Customer strings are never
compiled as regex. Placement is intentionally bounded and syntactic; richer claim attribution is a
future primitive only if design-partner evidence justifies it.

### Length and composition

- `length` applies inclusive minimum and/or maximum bounds to Unicode graphemes or normalized words.
- `all`, `any`, and `not` compose rules. Every child is evaluated for evidence. Any child evaluator
  error makes the composite an evaluator error so uncertainty is never hidden behind another pass or
  failure.

## Pass, fail, and evaluator error

A rule fails when the observed content does not satisfy a valid contract: malformed JSON, a missing
path, a wrong value, absent required text, or a prohibited fact are ordinary failures.

An evaluator error means the engine could not safely determine the contract outcome, such as an
unsupported engine version, invalid UTF-8, an output beyond the inspection limit, or an unexpected
internal rule failure. It is never reported as content degradation. Contract parsing errors are
rejected before evaluation and cannot be approved in Task 8.

Each rule result contains its stable ID, type, status, concise explanation, and bounded structured
evidence. Composite results also reference child rule IDs. Raw outputs and full large configured
values are not copied into evidence.

## Bounds

Version 1 fixes conservative application limits:

- 100,000 encoded bytes per contract;
- 100 total rule nodes;
- five levels of rule nesting and twenty children per group;
- 80 characters per rule ID and 1,000 characters per JSON Pointer;
- 32 pointer tokens;
- 20 alternatives or source IDs per rule;
- 500 encoded bytes per configured text alternative;
- numeric range/tolerance configuration within the interoperable JSON integer magnitude of
  `±9,007,199,254,740,991`;
- 1,000,000 encoded bytes per observed output; and
- 500 encoded bytes per individual evidence excerpt.

These are evaluator/schema-version semantics. Raising them requires an explicit compatibility review,
not a hidden runtime configuration change.

## Observation and rescoring boundary

An observation contains a stable ID and the immutable output bytes. Evaluation creates a separate
record containing a new evaluation ID, timestamp, exact contract identity/fingerprint, evaluator
engine version, overall status, and all rule results. Rescoring the same observation creates another
evaluation record and leaves the observation untouched.

`deterministic-v1` is the first engine version. Changing normalization, pointer behavior, numeric
comparison, citation scope, composite truth rules, or evidence meaning requires a new engine version.
Adding a compatible explanation-only field may not, but must still be reviewed explicitly.

Task 9 will persist these boundaries in PostgreSQL and add capture/provider provenance. It must not
embed a mutable evaluation inside an observation.

## Testing and approval

- Unit matrices cover positive, negative, malformed-contract, exact-boundary, and adversarial cases
  for every primitive.
- Property-oriented loops cover pointer escaping, literal token boundaries, numeric limits, evidence
  bounds, uniqueness, and deterministic repeated evaluation without adding a generator dependency.
- Candidate conformance fixtures use domains beyond the spike's RAG examples and remain separately
  identified from held-out examples.
- Human approval records expected outcomes; it does not claim measured cross-customer accuracy.

## Deferred needs

- Unit-aware quantity relationships and contradiction detection need their own primitive and
  fixtures; version 1 numeric checks operate on JSON numbers only.
- Output-language detection is deferred because reliable language identification is not provided by
  the deterministic standard library and was not selected for the alpha task.
- General claim extraction, semantic equivalence, retrieval quality, and free-form citation styles
  remain outside the deterministic wedge.
- Task 8 owns database-backed contract/fixture lifecycle, owner approval, sealing, and authoring UI.
- Task 9 owns durable observation/evaluation/rule-result persistence and provider execution.
- Task 12 owns alert severity and alert policy; evaluation truth remains independent of notification
  policy.

## References

- [RFC 6901: JSON Pointer](https://www.rfc-editor.org/rfc/rfc6901.html)
- [RFC 8259: The JSON Data Interchange Format](https://www.rfc-editor.org/rfc/rfc8259.html)
- [Elixir `String` Unicode normalization and grapheme documentation](https://hexdocs.pm/elixir/String.html)
- [OWASP: Regular expression denial of service](https://owasp.org/www-community/attacks/Regular_expression_Denial_of_Service_-_ReDoS)
