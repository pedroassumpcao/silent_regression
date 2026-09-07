# LLM Drift-Detection Spike — Implementation Plan

> **For Codex:** This file is the persistent reference for this project. Before starting any task below, read this entire document for context. Each task is self-contained but assumes the goal, constraints, and prior tasks described here. Work one task at a time; do not skip ahead or combine tasks. Commit after each task completes and its verification passes.

**Goal:** Build a small Elixir program that tests whether comparing an LLM's output distribution across repeated runs (today vs. a stored baseline) can reliably distinguish a REAL quality regression from ordinary model non-determinism — cheaply, without a trained judge model or a rubric. This is a feasibility spike, not a product. Success is a clear answer (yes/no/partially) backed by numbers, not a shipped feature.

**Why this matters (business context):** I am evaluating a SaaS idea: continuous cross-vendor LLM quality monitoring, where a customer brings their own prompts and API keys and the product periodically re-tests them, alerting when a model's behavior degrades — especially the hard case where output is still well-formed (valid JSON, right shape) but subtly wrong. Existing tools mostly detect obvious breaks (schema/format failures) or require a customer-authored rubric/judge. The hypothesis, validated in user interviews, is that comparing the DISTRIBUTION of outputs for a fixed prompt over time — without needing to define "correct" upfront — can catch subtle regressions cheaply and with few false alarms. This spike tests that hypothesis directly before any product work begins. If it fails, the product idea needs rethinking; if it succeeds, this becomes the core detection engine.

**Architecture:** A plain Elixir program (no database) with three layers: (1) thin HTTP clients per LLM provider normalizing responses to a common struct, (2) a small set of fixed test prompts used as the constant input across all experiments, (3) scoring functions that compute how similar/different two sets of outputs are, using cheap deterministic + lexical methods first (embeddings/LLM-judge are explicitly out of scope unless the cheap methods prove insufficient — see "Escalation path" below). A Mix task orchestrates running prompts against providers N times and comparing runs against a stored baseline.

**Tech Stack:** Elixir, `Req` (HTTP client, has built-in retry + `Req.Test` mocking) or maybe `ReqLLM` for provider clients, `Jason` (JSON). No embeddings library, no ML library, no web framework — deliberately minimal.

---

## Ground rules for every task

1. **One task at a time.** Read the task, implement only what it describes, run the verification, commit, stop.
2. **Never call live LLM APIs from `mix test`.** All automated tests use `Req.Test` stubs or hand-written fixtures. Live API calls only happen when a human runs a Mix task manually (see "Manual-only steps" below).
3. **Don't add dependencies not listed in this document** without flagging it — if a task seems to need something beyond `req`/`jason`, stop and ask rather than reaching for embeddings, Tribunal, or an ML library, even if it seems like the "better" solution. This is a constraint, not an oversight: the point of the spike is to test whether the CHEAP method works before justifying anything heavier.
4. **Never fabricate results.** If a live API call fails or a test doesn't pass, report that plainly rather than working around it silently.
5. **Commit message format:** `feat(spike): <what task accomplished>` — one commit per task.

## Manual-only steps (Codex should NOT do these — flagged inline at the relevant task)
- Writing the "subtle wrong answer" fixtures (Task 10) — requires human judgment about what's genuinely hard to distinguish from correct.
- Running any live multi-provider comparison (Tasks 8, 9, 10 execution) — a human runs these manually to control API spend and sanity-check results as they land.
- The final TRUSTWORTHY / NEEDS-MORE-LAYERS / NOT-VIABLE verdict (Task 11) — a human judgment call based on the numbers Codex's tooling produces.

## Escalation path (only if the cheap method proves insufficient)
The spike starts with the cheapest possible scoring method: Jaccard lexical similarity on word sets. If Task 10's verification shows this can't separate a genuinely subtle wrong-but-well-formed answer from a correct one, the NEXT thing to try (not part of this plan yet — would need a new task written after discussion) is embedding-based cosine similarity (e.g. OpenAI's `text-embedding-3-small` via a new `Providers.Embeddings` module). Do not jump to this preemptively — only if Task 10 shows the simple method failing.

---

## Task list

### Task 1: Add dependencies and create placeholder modules
**Objective:** Get the project compiling with the dependencies in place and empty module skeletons for what's to come.
**Files:**
- Modify: `mix.exs` (add deps)
- Create: `lib/silent_regression/response.ex`
- Create: `lib/silent_regression/providers.ex` (moduledoc only)
- Create: `lib/silent_regression/prompt_set.ex` (moduledoc only)
- Create: `lib/silent_regression/scoring.ex` (moduledoc only)
- Create: `lib/silent_regression/experiment.ex` (moduledoc only)

**Steps:**
1. Add `{:req, "~> 0.5"}` and `{:jason, "~> 1.4"}` to `mix.exs` deps (or use `ReqLLM`).
2. Run `mix deps.get`.
3. Define `SilentRegression.Response` struct in `lib/silent_regression/response.ex` with fields `:text, :raw, :model, :latency_ms, :tokens`.
4. Create the four placeholder modules listed above, each with just `defmodule` + a one-line `@moduledoc` describing its future purpose (Providers = "HTTP clients per LLM provider", PromptSet = "Fixed test prompts used across all experiments", Scoring = "Functions comparing sets of LLM outputs for drift", Experiment = "Mix tasks orchestrating baseline capture and comparison runs").
5. Run `mix compile` — must succeed with no warnings about the new files.

**Verify:** `mix compile` succeeds. `git log -1` shows the commit.

---

### Task 2: OpenAI provider client
**Objective:** Implement and prove the HTTP + normalization pattern for one provider before replicating it to others.
**Files:**
- Create: `lib/silent_regression/providers/open_ai.ex`

**Steps:**
1. Implement `SilentRegression.Providers.OpenAI.complete(prompt, opts \\ [])`.
2. Read API key via `System.get_env("OPENAI_API_KEY")`; return `{:error, :missing_api_key}` immediately if nil, without making an HTTP call.
3. Accept `opts[:model]` (default `"gpt-4o-mini"`) and `opts[:temperature]` (default `0.7`).
4. Call the OpenAI chat completions endpoint via `Req.post`, with `retry: :transient` (or equivalent Req retry option) for 429/5xx handling.
5. On success, return `{:ok, %SilentRegression.Response{text: <content>, raw: <full decoded body>, model: <model used>, latency_ms: <measured>, tokens: %{prompt: ..., completion: ...}}}`.
6. On any HTTP or API-level error, return `{:error, reason}` — never let this function raise.

**Verify:** `mix compile` succeeds. Then — **run this manually, not via Codex** — with a real `OPENAI_API_KEY` set:
```
iex -S mix
SilentRegression.Providers.OpenAI.complete("Say hi in 3 words")
```
Confirm a real `{:ok, %SilentRegression.Response{}}` comes back with sensible fields before proceeding to Task 3.

---

### Task 3: OpenAI provider tests (mocked)
**Objective:** Lock in the normalization/error-handling behavior using `Req.Test`, with zero live network calls.
**Files:**
- Create: `test/silent_regression/providers/open_ai_test.exs`

**Steps:**
1. Use `Req.Test` to stub the OpenAI endpoint.
2. Test: a successful mocked response is correctly parsed into a `%SilentRegression.Response{}` with correct field values.
3. Test: missing API key returns `{:error, :missing_api_key}` and makes NO network call (verify via `Req.Test` assertion that no request was made, or by not stubbing anything and confirming it doesn't crash).
4. Test: a mocked 401 or 500 response returns `{:error, reason}` without raising.

**Verify:** `mix test test/silent_regression/providers/open_ai_test.exs` — all pass, zero real HTTP calls made.

---

### Task 4: Anthropic and OpenRouter provider clients + tests
**Objective:** Replicate the now-proven OpenAI pattern to the other two providers.
**Files:**
- Create: `lib/silent_regression/providers/anthropic.ex`
- Create: `lib/silent_regression/providers/open_router.ex`
- Create: `test/silent_regression/providers/anthropic_test.exs`
- Create: `test/silent_regression/providers/open_router_test.exs`

**Steps:**
1. `SilentRegression.Providers.Anthropic.complete/2` — same signature/struct/error-handling shape as OpenAI. Uses Anthropic's messages API, `ANTHROPIC_API_KEY` env var, default model `"claude-3-5-haiku-latest"`.
2. `SilentRegression.Providers.OpenRouter.complete/2` — same shape, OpenRouter's OpenAI-compatible chat completions endpoint, `OPENROUTER_API_KEY` env var. Model must be passed explicitly via `opts[:model]` (no silent default — OpenRouter serves many models and picking one implicitly would be confusing); default to `"meta-llama/llama-3.1-8b-instruct"` only if truly unset.
3. Mirror the exact test structure from Task 3 for both.

**Verify:** `mix test` — all pass. Manually smoke-test both with real keys the same way as Task 2, before moving on.

---

### Task 5: Fixed prompt set
**Objective:** Define the 3 constant test prompts used throughout every experiment.
**Files:**
- Modify: `lib/silent_regression/prompt_set.ex`

**Steps:**
1. Implement `SilentRegression.PromptSet.all/0` returning a list of 3 maps with keys `:id, :type, :prompt_text, :expected`.
2. Prompt 1 — `:extract_person`, type `:extraction`: a prompt embedding a short fixed bio paragraph, asking for JSON extraction of name/age/city. `:expected` is the correct map, e.g. `%{"name" => "...", "age" => ..., "city" => "..."}`.
3. Prompt 2 — `:classify_ticket`, type `:classification`: a prompt embedding a fixed support-ticket text, asking to classify as one of "billing"/"technical"/"account"/"other". `:expected` is the correct label string.
4. Prompt 3 — `:generate_description`, type `:generation`: a prompt asking for a 2-sentence product description of a fixed product. `:expected` is `nil` (no fixed correct answer for open-ended generation).

**Verify:** Read the three prompts and their `:expected` values yourself — confirm the extraction and classification ones have a truly unambiguous correct answer given the fixed input text embedded in the prompt. This matters for every later comparison.

---

### Task 6: Scoring functions (deterministic + lexical similarity)
**Objective:** Implement the actual comparison logic, deliberately starting at the cheapest possible method.
**Files:**
- Modify: `lib/silent_regression/scoring.ex`

**Steps:**
1. `valid_json?(text)` — returns boolean.
2. `matches_expected?(text, expected)` — for a map `expected` (extraction case), parse `text` as JSON and loosely compare keys/values; for a string `expected` (classification case), case-insensitive substring match.
3. `length_stats(texts)` — takes a list of strings, returns `%{mean: float, stddev: float}` of character lengths.
4. `lexical_similarity(text_a, text_b)` — Jaccard similarity: lowercase both, strip punctuation, split into word sets, return `intersection_size / union_size` (0.0 to 1.0).
5. `mean_pairwise_similarity(baseline_texts, comparison_texts)` — average `lexical_similarity` across pairs (all pairs if lists are small, e.g. ≤20×20; sample if larger), returning `%{mean: float, stddev: float}`.

**Verify:** proceed to Task 7 for actual verification via tests.

---

### Task 7: Scoring tests (fixtures only)
**Objective:** Prove the scoring functions behave sanely on known inputs before trusting them on real model output.
**Files:**
- Create: `test/silent_regression/scoring_test.exs`

**Steps:**
1. Test `valid_json?/1` — one clearly-valid-JSON case, one clearly-invalid case.
2. Test `matches_expected?/2` — one true and one false case for a map expected value; one true and one false case for a string label.
3. Test `length_stats/1` — a known list of strings where you (Codex) compute the expected mean/stddev by hand in the test assertion.
4. Test `lexical_similarity/2` — identical strings return `1.0`; two completely unrelated sentences return a low value (assert `< 0.3`); two sentences sharing some words but differing in others return a mid-range value.
5. Test `mean_pairwise_similarity/2` — two small hand-written lists (2-3 strings each) where the expected result is computed by hand in the test.

**Verify:** `mix test test/silent_regression/scoring_test.exs` all pass. **Then a human should read the mid-range lexical_similarity assertion and the mean_pairwise_similarity expected values** — confirm the numbers are ones a person would independently agree look reasonable, not just whatever Codex happened to compute.

---

### Task 8: Baseline-capture Mix task
**Objective:** A command that runs N samples per prompt against a chosen provider/model and stores the results.
**Files:**
- Create: `lib/mix/tasks/drift_spike.baseline.ex`

**Steps:**
1. Mix task `drift_spike.baseline`, accepting `--provider` (default `"openai"`), `--model` (provider-specific default), `--n` (default `10`) CLI options.
2. For each prompt in `SilentRegression.PromptSet.all/0`, call the selected provider's `complete/2` N times. Use `Task.async_stream` with `max_concurrency: 3` for the calls, but collect and store results in a stable order.
3. Compute Layer A/B scores across the N samples: `valid_json?`/`matches_expected?` rates where applicable, `length_stats`.
4. Write raw responses + computed stats to `results/<prompt_id>_baseline_<provider>_<model>.json`. Create `results/` if missing; add `results/` to `.gitignore`.
5. Print a summary table to stdout: prompt id, successful call count, mean/stddev length, % matching expected (where applicable).

**Verify — MANUAL, not Codex:** run `mix drift_spike.baseline --provider openai --n 10` yourself with a real API key. Confirm the results file and printed summary look sensible (e.g. `matches_expected?` rate should be high and consistent for an easy prompt on a good model) before proceeding.

---

### Task 9: Comparison Mix task
**Objective:** The core comparison logic — run a fresh set of samples and compare against a stored baseline.
**Files:**
- Create: `lib/mix/tasks/drift_spike.compare.ex`

**Steps:**
1. Mix task `drift_spike.compare`, accepting `--baseline-file` (path), `--provider`, `--model`, `--n` (default `10`), `--label` (free-text name for this run, e.g. `"obvious_regression"` or `"control"`).
2. Load the baseline file's stored texts per prompt.
3. Run N fresh calls against the specified provider/model for the same prompts.
4. Compute the same Layer A scores for the new run, plus `mean_pairwise_similarity` between the new run's texts and the baseline's texts, per prompt.
5. Print a summary table: per prompt — baseline mean length vs. new mean length, `mean_pairwise_similarity` (mean + stddev), and whether `valid_json?`/`matches_expected?` rates changed vs. baseline.
6. Write full results to `results/<label>_<prompt_id>_<timestamp>.json`.

**Verify — MANUAL, not Codex.** A human runs, one prompt/condition at a time, controlling API spend:
```
mix drift_spike.compare --baseline-file results/extract_person_baseline_openai_gpt-4o-mini.json --provider openai --model gpt-3.5-turbo --label obvious_regression
mix drift_spike.compare --baseline-file results/extract_person_baseline_openai_gpt-4o-mini.json --provider openai --model gpt-4o-mini --label control
```
**Sanity gate before continuing to Task 10:** the `obvious_regression` similarity score should be clearly LOWER than the `control` similarity score. If they look similar, STOP — the mechanism isn't separating signal from noise, and the escalation path (embeddings) or a rethink is needed before investing further.

---

### Task 10: Fixture-based comparison (the subtle "well-formed and wrong" test)
**Objective:** Test the hardest, most important case — a subtly wrong but structurally valid answer — without needing to find a real model that fails this way.

**MANUAL STEP FIRST (human, not Codex):** for the extraction and classification prompts, hand-write 10 "plausible but wrong" responses each — same JSON shape / same label format as correct, but with a subtly wrong value (e.g. correct city swapped for a different plausible city; correct label swapped for an adjacent-but-wrong one). Save as `results/subtle_regression_fixtures.json` with a shape mirroring the baseline files' text arrays.

**Files (Codex, once fixtures exist):**
- Create: `lib/mix/tasks/drift_spike.compare_fixtures.ex`

**Steps:**
1. Mix task `drift_spike.compare_fixtures`, same shape as `drift_spike.compare` but reads its "new run" texts from a local fixture JSON file (`--fixture-file`) instead of calling a live provider.
2. Compute the same `mean_pairwise_similarity` and `valid_json?`/`matches_expected?` comparisons against a baseline file.
3. Print the same summary table format as Task 9.

**Verify — MANUAL, the actual go/no-go moment:**
```
mix drift_spike.compare_fixtures --baseline-file results/extract_person_baseline_openai_gpt-4o-mini.json --fixture-file results/subtle_regression_fixtures.json --label subtle_regression
```
Compare `subtle_regression` similarity against `control` (from Task 9). Two things to check:
1. `matches_expected?` should correctly drop (the values are genuinely wrong — this is the easy check).
2. **The real test:** does `mean_pairwise_similarity` ALSO drop meaningfully? This matters because it proves the distribution-comparison method — not just an exact-match check — would catch this on its own, which is essential for the generation-type prompt where there's no `expected` value to check against at all.

If `mean_pairwise_similarity` stays high despite genuinely wrong answers, lexical similarity isn't sensitive enough — see "Escalation path" above.

---

### Task 11: Consolidated report
**Objective:** Turn all the raw results into one summary artifact.
**Files:**
- Create: `lib/mix/tasks/drift_spike.report.ex`

**Steps:**
1. Mix task `drift_spike.report` reads all JSON files in `results/`.
2. Prints one consolidated table: rows = prompts, columns = condition (baseline/control/obvious_regression/subtle_regression/reworded, whichever exist), values = `mean_pairwise_similarity` and `matches_expected` rate.
3. Writes the same table to `results/SUMMARY.md` as markdown.

**Verify:** `mix drift_spike.report` runs and produces a sensible `results/SUMMARY.md`.

**FINAL STEP — human, not Codex:** write a short verdict at the top of `results/SUMMARY.md`: **TRUSTWORTHY / NEEDS-MORE-LAYERS / NOT-VIABLE**, based on whether `obvious_regression` and `subtle_regression` scores clearly separate from `control` (and `reworded`, if run) scores.

---

## Open questions / risks (surface these if they come up, don't silently resolve them)
- Lexical (Jaccard) similarity may be too crude for the open-ended generation prompt, where wording naturally varies a lot between runs even with no regression — watch for high baseline-vs-baseline variance on that prompt specifically; if the "control" condition itself shows low similarity even with no model change, that's a sign the metric is too noisy for that prompt type before we even get to testing real regressions.
- Provider APIs may return different response shapes than expected during implementation — if the actual OpenAI/Anthropic/OpenRouter response format differs from what's assumed above, flag it rather than guessing silently.
- This plan deliberately does not cover cost controls beyond `--n` — if a task risks an unexpectedly large number of API calls, flag it before running.

## Decision log
- 2026-09-03: I requested a persistent implementation-plan document (not just a step list) so Codex retains full context (goal, business rationale, constraints, escalation path) across every incremental invocation rather than re-deriving it per-prompt. This PLAN.md is designed to be copied into the actual Elixir project repo root, with Codex instructed to read it before each task and told simply "implement Task N" per invocation.
