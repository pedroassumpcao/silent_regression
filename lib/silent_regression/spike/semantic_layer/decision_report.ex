defmodule SilentRegression.Spike.SemanticLayer.DecisionReport do
  @moduledoc """
  Builds the Task E comparison and decision report from pinned spike artifacts.

  The report keeps the denominators for deterministic fixtures, lexical case
  comparisons, and seeded semantic batch comparisons separate. It recommends
  an outcome from the evidence but never converts that recommendation into the
  human-owned product decision.
  """

  alias SilentRegression.Spike.FixtureComparisonStorage
  alias SilentRegression.Spike.SemanticLayer.BenchmarkResult
  alias SilentRegression.Spike.SemanticLayer.ContractRescoreResult
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage
  alias SilentRegression.Spike.Storage

  @schema_version 1
  @pending_decision "PENDING_HUMAN_DECISION"
  @decisions ~w(
    CHEAP_LAYER_PROMISING
    DETERMINISTIC_ONLY_WEDGE
    EVALUATE_MODEL_BASED_SEMANTICS
    STOP_TECHNICAL_VALIDATION
  )
  @allowed_options [:clock, :decision]
  @reference_url "https://airc.nist.gov/airmf-resources/airmf/5-sec-core/"

  @type result :: %{required(String.t()) => term()}

  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  @spec pending_decision() :: String.t()
  def pending_decision, do: @pending_decision

  @doc "Builds the report from a versioned manifest of immutable source artifacts."
  @spec build(Path.t(), keyword()) :: {:ok, result()} | {:error, map()}
  def build(manifest_path, options \\ [])

  def build(manifest_path, options) when is_binary(manifest_path) and is_list(options) do
    with :ok <- validate_options(options),
         {:ok, decision} <- decision(options),
         {:ok, created_at} <- timestamp(options),
         {:ok, manifest} <- read_manifest(manifest_path),
         :ok <- validate_manifest(manifest),
         {:ok, evidence} <- load_evidence(manifest),
         :ok <- validate_evidence(evidence) do
      {:ok, compile(manifest, evidence, decision, created_at)}
    end
  end

  def build(_manifest_path, _options),
    do: error(:invalid_configuration, "Manifest path and keyword options are required")

  @doc false
  @spec build_from_evidence(map(), map(), keyword()) :: {:ok, result()} | {:error, map()}
  def build_from_evidence(manifest, evidence, options \\ [])

  def build_from_evidence(manifest, evidence, options)
      when is_map(manifest) and is_map(evidence) and is_list(options) do
    with :ok <- validate_options(options),
         {:ok, decision} <- decision(options),
         {:ok, created_at} <- timestamp(options),
         :ok <- validate_manifest(manifest),
         :ok <- validate_evidence(evidence) do
      {:ok, compile(manifest, evidence, decision, created_at)}
    end
  end

  def build_from_evidence(_manifest, _evidence, _options),
    do: error(:invalid_configuration, "Manifest, evidence, and keyword options are required")

  @doc false
  @spec compile(map(), map(), String.t(), DateTime.t()) :: result()
  def compile(manifest, evidence, decision, created_at) do
    live = summarize_live_operations(manifest["live_runs"], evidence.live_runs)
    deterministic = summarize_deterministic(evidence.contract_rescore)
    lexical = summarize_lexical(evidence.fixture_comparison)
    semantic = summarize_semantic(evidence.semantic_tuning, evidence.semantic_heldout)
    recommendation = recommendation(deterministic, semantic)

    report = %{
      "schema_version" => @schema_version,
      "report_id" => manifest["report_id"],
      "created_at" => DateTime.to_iso8601(created_at),
      "recommendation" => recommendation,
      "human_decision" => decision,
      "provider_calls" => 0,
      "sources" => source_references(manifest),
      "live_operations" => live,
      "deterministic_contracts" => deterministic,
      "lexical_distribution" => lexical,
      "cheap_semantic" => semantic,
      "decision_options" => decision_options(deterministic, semantic, recommendation),
      "limitations" => limitations(),
      "methodology_reference" => @reference_url
    }

    Map.put(report, "markdown", render(report))
  end

  @doc "Atomically writes a new report and refuses to overwrite an existing decision record."
  @spec write(Path.t(), String.t()) :: :ok | {:error, map()}
  def write(path, markdown)
      when is_binary(path) and path != "" and is_binary(markdown) and markdown != "" do
    with :ok <- ensure_new_destination(path),
         :ok <- ensure_parent_directory(path),
         :ok <- write_atomically(path, markdown) do
      :ok
    end
  end

  def write(path, _markdown),
    do: error(:invalid_write, "A non-empty path and report are required", %{path: path})

  defp validate_options(options) do
    cond do
      not Keyword.keyword?(options) ->
        error(:invalid_configuration, "Report options must be a keyword list")

      Enum.uniq(Keyword.keys(options)) != Keyword.keys(options) ->
        error(:invalid_configuration, "Report options must be unique")

      Keyword.keys(options) -- @allowed_options != [] ->
        error(:invalid_configuration, "Report options contain unsupported keys", %{
          unsupported_options: Keyword.keys(options) -- @allowed_options
        })

      true ->
        :ok
    end
  end

  defp decision(options) do
    value = Keyword.get(options, :decision, @pending_decision)

    if value == @pending_decision or value in @decisions,
      do: {:ok, value},
      else: error(:unsupported_decision, "Human decision is unsupported", %{allowed: @decisions})
  end

  defp timestamp(options) do
    case Keyword.get(options, :clock, &DateTime.utc_now/0).() do
      %DateTime{} = created_at -> {:ok, created_at}
      value -> error(:invalid_clock, "Report clock must return a DateTime", %{actual: value})
    end
  rescue
    exception -> error(:clock_exception, "Report clock raised", %{exception: inspect(exception)})
  end

  defp read_manifest(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        error(:invalid_manifest_json, "Decision manifest is not valid JSON", %{reason: reason})

      {:error, reason} ->
        error(:manifest_read_failed, "Decision manifest could not be read", %{reason: reason})

      false ->
        error(:invalid_manifest, "Decision manifest must be a JSON object")
    end
  end

  defp validate_manifest(manifest) do
    required =
      ~w(schema_version report_id live_runs fixture_comparison contract_rescore semantic_tuning semantic_heldout)

    cond do
      Map.keys(manifest) |> Enum.sort() != Enum.sort(required) ->
        error(:invalid_manifest, "Decision manifest keys are invalid", %{required: required})

      manifest["schema_version"] != @schema_version ->
        error(:invalid_manifest, "Decision manifest schema version is unsupported")

      not non_empty_string?(manifest["report_id"]) ->
        error(:invalid_manifest, "Decision report ID is missing")

      not valid_live_references?(manifest["live_runs"]) ->
        error(:invalid_manifest, "Live-run references are invalid")

      not Enum.all?(
        ~w(fixture_comparison contract_rescore semantic_tuning semantic_heldout),
        fn key ->
          valid_reference?(manifest[key], false)
        end
      ) ->
        error(:invalid_manifest, "A local-evaluation reference is invalid")

      true ->
        :ok
    end
  end

  defp valid_live_references?(references) when is_list(references) do
    roles = Enum.map(references, & &1["role"])

    references != [] and Enum.all?(references, &valid_reference?(&1, true)) and
      Enum.count(roles, &(&1 == "baseline")) == 1 and
      Enum.count(roles, &(&1 == "heldout_control")) == 1 and
      Enum.all?(roles, &(&1 in ~w(baseline calibration_source heldout_control))) and
      unique?(references, "artifact_id") and unique?(references, "path")
  end

  defp valid_live_references?(_references), do: false

  defp valid_reference?(reference, include_role?) when is_map(reference) do
    required =
      if include_role?,
        do: ~w(role artifact_id path artifact_sha256),
        else: ~w(artifact_id path artifact_sha256)

    Map.keys(reference) |> Enum.sort() == Enum.sort(required) and
      non_empty_string?(reference["artifact_id"]) and
      non_empty_string?(reference["path"]) and valid_sha256?(reference["artifact_sha256"])
  end

  defp valid_reference?(_reference, _include_role?), do: false

  defp load_evidence(manifest) do
    with {:ok, live_runs} <- load_live_runs(manifest["live_runs"]),
         {:ok, fixture_comparison} <-
           load_source(manifest["fixture_comparison"], &FixtureComparisonStorage.read/1),
         {:ok, contract_rescore} <-
           load_source(manifest["contract_rescore"], &SemanticStorage.read/1),
         {:ok, semantic_tuning} <-
           load_source(manifest["semantic_tuning"], &SemanticStorage.read/1),
         {:ok, semantic_heldout} <-
           load_source(manifest["semantic_heldout"], &SemanticStorage.read/1) do
      evidence = %{
        live_runs: live_runs,
        fixture_comparison: fixture_comparison,
        contract_rescore: contract_rescore,
        semantic_tuning: semantic_tuning,
        semantic_heldout: semantic_heldout
      }

      validate_identities(manifest, evidence)
    end
  end

  defp load_live_runs(references) do
    references
    |> Enum.reduce_while({:ok, []}, fn reference, {:ok, runs} ->
      case load_source(reference, &Storage.read/1) do
        {:ok, run} -> {:cont, {:ok, [run | runs]}}
        {:error, _error} = failure -> {:halt, failure}
      end
    end)
    |> then(fn
      {:ok, runs} -> {:ok, Enum.reverse(runs)}
      failure -> failure
    end)
  end

  defp load_source(reference, reader) do
    path = Path.expand(reference["path"])

    with {:ok, contents} <- File.read(path),
         :ok <- verify_hash(reference, contents),
         {:ok, artifact} <- reader.(path) do
      {:ok, artifact}
    else
      {:error, %{type: :source_hash_mismatch}} = failure ->
        failure

      {:error, %{type: _type} = cause} ->
        error(:source_read_failed, "A decision-report source is invalid", %{
          artifact_id: reference["artifact_id"],
          path: reference["path"],
          cause: cause
        })

      {:error, reason} ->
        error(:source_read_failed, "A decision-report source could not be read", %{
          artifact_id: reference["artifact_id"],
          path: reference["path"],
          reason: reason
        })
    end
  end

  defp verify_hash(reference, contents) do
    actual = sha256(contents)

    if actual == reference["artifact_sha256"],
      do: :ok,
      else:
        error(:source_hash_mismatch, "A pinned decision-report source changed", %{
          artifact_id: reference["artifact_id"],
          expected: reference["artifact_sha256"],
          actual: actual
        })
  end

  defp validate_identities(manifest, evidence) do
    actual_ids =
      (manifest["live_runs"]
       |> Enum.zip(evidence.live_runs)
       |> Enum.map(fn {reference, run} -> {reference["artifact_id"], run.run_id} end)) ++
        [
          {manifest["fixture_comparison"]["artifact_id"],
           evidence.fixture_comparison["comparison_id"]},
          {manifest["contract_rescore"]["artifact_id"], evidence.contract_rescore.evaluation_id},
          {manifest["semantic_tuning"]["artifact_id"], evidence.semantic_tuning.result_id},
          {manifest["semantic_heldout"]["artifact_id"], evidence.semantic_heldout.result_id}
        ]

    with :ok <- validate_live_roles(manifest["live_runs"], evidence.live_runs),
         :ok <- validate_heldout_control_identity(manifest, evidence.fixture_comparison) do
      case Enum.find(actual_ids, fn {expected, actual} -> expected != actual end) do
        nil ->
          {:ok, evidence}

        {expected, actual} ->
          error(:source_identity_mismatch, "A pinned artifact ID changed", %{
            expected: expected,
            actual: actual
          })
      end
    end
  end

  defp validate_live_roles(references, runs) do
    mismatch =
      Enum.zip(references, runs)
      |> Enum.find(fn {reference, run} ->
        expected_condition = if reference["role"] == "baseline", do: "baseline", else: "control"
        run.condition != expected_condition
      end)

    case mismatch do
      nil ->
        :ok

      {reference, run} ->
        error(:source_role_mismatch, "A live run does not match its pinned report role", %{
          artifact_id: reference["artifact_id"],
          role: reference["role"],
          condition: run.condition
        })
    end
  end

  defp validate_heldout_control_identity(manifest, fixture_comparison) do
    heldout = Enum.find(manifest["live_runs"], &(&1["role"] == "heldout_control"))

    if fixture_comparison["control_run_id"] == heldout["artifact_id"],
      do: :ok,
      else:
        error(
          :source_identity_mismatch,
          "Lexical evidence does not use the pinned held-out control",
          %{expected: heldout["artifact_id"], actual: fixture_comparison["control_run_id"]}
        )
  end

  defp validate_evidence(evidence) do
    baseline = Enum.find(evidence.live_runs, &(&1.condition == "baseline"))
    controls = Enum.reject(evidence.live_runs, &(&1.condition == "baseline"))
    fixture = evidence.fixture_comparison
    contract = evidence.contract_rescore
    tuning = evidence.semantic_tuning
    heldout = evidence.semantic_heldout

    cond do
      is_nil(baseline) ->
        error(:incompatible_evidence, "A baseline run is required")

      not Enum.all?(controls, &(&1.condition == "control")) ->
        error(:incompatible_evidence, "Every non-baseline live run must be a control")

      not Enum.all?(evidence.live_runs, fn run ->
        run.provider == baseline.provider and
            get_in(run.request_config, ["model"]) ==
              get_in(baseline.request_config, ["model"])
      end) ->
        error(:incompatible_evidence, "Live runs do not share provider/model provenance")

      fixture["baseline_run_id"] != baseline.run_id ->
        error(:incompatible_evidence, "Lexical comparison does not reference the pinned baseline")

      fixture["provider_calls"] != 0 or contract.provider_calls != 0 or
        get_in(tuning.settings, ["provider_calls"]) != 0 or
          get_in(heldout.settings, ["provider_calls"]) != 0 ->
        error(:incompatible_evidence, "Local evaluations must make zero provider calls")

      not match?(%ContractRescoreResult{}, contract) ->
        error(:incompatible_evidence, "Contract evidence has the wrong artifact type")

      not match?(%BenchmarkResult{evaluation_role: "method_selection"}, tuning) ->
        error(:incompatible_evidence, "Semantic tuning evidence has the wrong role")

      not match?(%BenchmarkResult{evaluation_role: "final_evaluation"}, heldout) ->
        error(:incompatible_evidence, "Semantic held-out evidence has the wrong role")

      not compatible_semantic_selection?(tuning, heldout) ->
        error(:incompatible_evidence, "Held-out semantics do not use the frozen tuning winner")

      true ->
        :ok
    end
  end

  defp compatible_semantic_selection?(tuning, heldout) do
    selected = get_in(tuning.summary, ["selected_representation_ids"])
    heldout_ids = Enum.map(heldout.representations, & &1["representation_id"])
    selected != [] and selected == heldout_ids
  end

  defp summarize_live_operations(references, runs) do
    rows =
      Enum.zip(references, runs)
      |> Enum.map(fn {reference, run} ->
        %{
          "role" => reference["role"],
          "run_id" => run.run_id,
          "successful_samples" => total(run, "successful_samples"),
          "failed_samples" => total(run, "failed_samples"),
          "actual_calls" => total(run, "actual_calls"),
          "latency_ms" => total(run, "latency_ms"),
          "input_tokens" => total(run, "input_tokens"),
          "output_tokens" => total(run, "output_tokens")
        }
      end)

    totals =
      ~w(successful_samples failed_samples actual_calls latency_ms input_tokens output_tokens)
      |> Map.new(fn field -> {field, Enum.sum(Enum.map(rows, & &1[field]))} end)

    %{
      "runs" => rows,
      "totals" => totals,
      "latency_definition" => "cumulative successful-sample provider latency",
      "monetary_cost" => %{
        "status" => "not_computable",
        "reason" =>
          "Historical provider price snapshots and billable-token categories were not frozen with the runs."
      },
      "local_evaluation_cost" => %{
        "provider_calls" => 0,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "wall_clock_status" => "not_instrumented"
      }
    }
  end

  defp summarize_deterministic(result) do
    summary = result.summary
    valid_count = summary["expected_pass_count"]
    valid_accepted = summary["expected_pass_matched_count"]
    regression_count = summary["expected_fail_count"]
    regressions_detected = summary["expected_fail_matched_count"]

    %{
      "fixture_count" => summary["fixture_count"],
      "matched_expectation_count" => summary["matched_expectation_count"],
      "valid_fixture_count" => valid_count,
      "valid_accepted_count" => valid_accepted,
      "false_failure_count" => valid_count - valid_accepted,
      "regression_fixture_count" => regression_count,
      "regression_detected_count" => regressions_detected,
      "missed_regression_count" => regression_count - regressions_detected,
      "by_split" => summary["by_split"],
      "by_case" => summary["by_case"],
      "by_failure_mode" => summary["by_failure_mode"],
      "provider_calls" => result.provider_calls,
      "gate_status" =>
        if(summary["matched_expectation_count"] == summary["fixture_count"],
          do: "passed",
          else: "failed"
        ),
      "scope" =>
        "Exact conformance to user-configured, versioned contracts; not label-free semantic understanding."
    }
  end

  defp summarize_lexical(result) do
    batches =
      Enum.map(result["batches"], fn batch ->
        comparisons = batch["comparison"]["by_case"]
        case_count = length(comparisons)
        drift_reviews = Enum.count(comparisons, &(&1["drift_outcome"] == "drift_review"))

        deterministic =
          Enum.count(comparisons, &(&1["deterministic_outcome"] == "deterministic_regression"))

        any_signal = Enum.count(comparisons, &(&1["alert_outcome"] != "no_alert"))

        %{
          "batch_id" => batch["batch_id"],
          "intended_label" => batch["intended_label"],
          "seeded_failure_rate" => batch["expected_regression_rate"],
          "case_comparison_count" => case_count,
          "drift_review_count" => drift_reviews,
          "deterministic_regression_count" => deterministic,
          "any_signal_count" => any_signal,
          "false_review_count" =>
            if(batch["intended_label"] == "acceptable", do: drift_reviews, else: nil)
        }
      end)

    harmless = Enum.filter(batches, &(&1["intended_label"] == "acceptable"))
    harmless_count = Enum.sum(Enum.map(harmless, & &1["case_comparison_count"]))
    false_reviews = Enum.sum(Enum.map(harmless, & &1["false_review_count"]))
    reference_cases = result["reference_control"]["comparison"]["by_case"]

    %{
      "method" => "Jaccard word-set energy distance",
      "independent_control_case_comparisons" => length(reference_cases),
      "independent_control_drift_review_count" =>
        Enum.count(reference_cases, &(&1["drift_outcome"] == "drift_review")),
      "harmless_case_comparison_count" => harmless_count,
      "false_review_count" => false_reviews,
      "false_review_rate" => ratio(false_reviews, harmless_count),
      "batches" => batches,
      "by_case" => lexical_by_case(result),
      "gate_status" => get_in(result, ["summary", "decision_gate", "status"]),
      "provider_calls" => result["provider_calls"],
      "denominator_note" =>
        "Each count is a case-level distribution comparison; it is not a count of independent output judgments."
    }
  end

  defp summarize_semantic(tuning, heldout) do
    tuning_summary = hd(tuning.summary["by_representation"])
    heldout_summary = hd(heldout.summary["by_representation"])

    batches =
      Enum.map(heldout.batches, fn batch ->
        representation = hd(batch["representation_results"])
        seed_results = representation["seed_results"]

        %{
          "batch_id" => batch["batch_id"],
          "case_id" => batch["case_id"],
          "label" => batch["label"],
          "seeded_failure_rate" => if(batch["label"] == "subtle_regression", do: 1.0, else: 0.0),
          "parent_count" => batch["unique_parent_count"],
          "seed_comparison_count" => length(seed_results),
          "drift_review_count" => Enum.count(seed_results, &(&1["outcome"] == "drift_review")),
          "energy_distance" => hd(seed_results)["energy_distance"],
          "threshold" => hd(seed_results)["threshold"]
        }
      end)

    %{
      "method" => hd(heldout.representations)["representation_id"],
      "tuning_gate_status" => tuning.summary["gate_status"],
      "tuning_harmless_review_count" => tuning_summary["harmless_drift_review_count"],
      "tuning_harmless_comparison_count" => tuning_summary["harmless_comparison_count"],
      "tuning_subtle_review_count" => tuning_summary["subtle_drift_review_count"],
      "tuning_subtle_comparison_count" => tuning_summary["subtle_comparison_count"],
      "heldout_gate_status" => heldout.summary["gate_status"],
      "heldout_harmless_review_count" => heldout_summary["harmless_drift_review_count"],
      "heldout_harmless_comparison_count" => heldout_summary["harmless_comparison_count"],
      "heldout_harmless_review_rate" => heldout_summary["harmless_drift_review_rate"],
      "heldout_subtle_review_count" => heldout_summary["subtle_drift_review_count"],
      "heldout_subtle_comparison_count" => heldout_summary["subtle_comparison_count"],
      "stable_across_seeds" => heldout_summary["stable_across_seeds"],
      "batches" => batches,
      "provider_calls" => tuning.settings["provider_calls"] + heldout.settings["provider_calls"],
      "denominator_note" =>
        "The three seeds repeat the same 20-parent batch with different permutation randomness; they demonstrate decision stability, not three independent content samples."
    }
  end

  defp recommendation(deterministic, semantic) do
    cond do
      semantic["heldout_gate_status"] == "passed" -> "CHEAP_LAYER_PROMISING"
      deterministic["gate_status"] == "passed" -> "DETERMINISTIC_ONLY_WEDGE"
      true -> "STOP_TECHNICAL_VALIDATION"
    end
  end

  defp lexical_by_case(result) do
    batches = result["batches"]
    reference_cases = result["reference_control"]["comparison"]["by_case"]

    Enum.map(reference_cases, fn reference ->
      case_id = reference["case_id"]
      case_batches = Enum.map(batches, &case_comparison(&1, case_id))
      harmless = Enum.filter(case_batches, &(&1["intended_label"] == "acceptable"))

      %{
        "case_id" => case_id,
        "control_review_count" => review_count([reference]),
        "control_comparison_count" => 1,
        "harmless_review_count" => review_count(harmless),
        "harmless_comparison_count" => length(harmless),
        "subtle_review" => batch_review(case_batches, "subtle_regression"),
        "obvious_review" => batch_review(case_batches, "obvious_regression"),
        "mixed_10_review" => batch_review(case_batches, "mixed_regression_10"),
        "mixed_25_review" => batch_review(case_batches, "mixed_regression_25"),
        "mixed_50_review" => batch_review(case_batches, "mixed_regression_50")
      }
    end)
  end

  defp case_comparison(batch, case_id) do
    batch["comparison"]["by_case"]
    |> Enum.find(&(&1["case_id"] == case_id))
    |> Map.merge(%{
      "batch_id" => batch["batch_id"],
      "intended_label" => batch["intended_label"]
    })
  end

  defp review_count(comparisons),
    do: Enum.count(comparisons, &(&1["drift_outcome"] == "drift_review"))

  defp batch_review(comparisons, batch_id) do
    case Enum.find(comparisons, &(&1["batch_id"] == batch_id)) do
      nil -> nil
      comparison -> comparison["drift_outcome"] == "drift_review"
    end
  end

  defp decision_options(deterministic, semantic, recommendation) do
    [
      %{
        "decision" => "CHEAP_LAYER_PROMISING",
        "evidence_status" =>
          if(semantic["heldout_gate_status"] == "passed", do: "supported", else: "rejected"),
        "reason" =>
          "Requires the frozen cheap semantic method to pass its held-out false-review and sensitivity gate."
      },
      %{
        "decision" => "DETERMINISTIC_ONLY_WEDGE",
        "evidence_status" =>
          if(deterministic["gate_status"] == "passed", do: "supported", else: "unsupported"),
        "reason" =>
          "Ships only explicit contract checks and preserves review for meaning that users did not configure."
      },
      %{
        "decision" => "EVALUATE_MODEL_BASED_SEMANTICS",
        "evidence_status" => "requires_new_plan",
        "reason" =>
          "The cheap layer failed, but this option needs new untouched domains plus explicit cost, privacy, and latency gates."
      },
      %{
        "decision" => "STOP_TECHNICAL_VALIDATION",
        "evidence_status" =>
          if(recommendation == "STOP_TECHNICAL_VALIDATION",
            do: "supported",
            else: "available_not_recommended"
          ),
        "reason" =>
          "Remains a business choice, but the deterministic evidence preserves a narrower viable wedge."
      }
    ]
  end

  defp limitations do
    [
      "All live evidence uses one provider/model pair: OpenAI gpt-5.6-luna.",
      "Contract results measure exact conformance to explicit configured rules on curated fixtures, not arbitrary semantic correctness.",
      "The lexical fixture design cycles a small number of outputs and is retained only as a failed historical experiment.",
      "The cheap semantic held-out result covers one RAG open-synthesis domain and one 20-parent content set.",
      "Permutation seeds measure statistical-decision stability on the same content, not independent content generalization.",
      "Historical dollar cost cannot be reconstructed because price snapshots and billable-token categories were not captured.",
      "Local evaluation wall-clock latency was not persisted, so only provider latency and zero-provider-call status are reportable."
    ]
  end

  defp source_references(manifest) do
    manifest["live_runs"] ++
      Enum.map(~w(fixture_comparison contract_rescore semantic_tuning semantic_heldout), fn key ->
        Map.put(manifest[key], "role", key)
      end)
  end

  defp render(report) do
    live = report["live_operations"]
    deterministic = report["deterministic_contracts"]
    lexical = report["lexical_distribution"]
    semantic = report["cheap_semantic"]

    """
    # Silent Regression Task E Decision Report

    **Report:** `#{report["report_id"]}`

    **Generated:** `#{report["created_at"]}`

    **Evidence-based recommendation:** `#{report["recommendation"]}`

    **Human decision:** `#{report["human_decision"]}`

    **Provider calls made by this report:** `0`

    ## Executive conclusion

    The evidence supports a contract-first product wedge, but it does not support a user-facing claim of generic label-free semantic drift detection. The deterministic evaluator matched #{deterministic["matched_expectation_count"]}/#{deterministic["fixture_count"]} approved expectations. The original lexical layer produced #{lexical["false_review_count"]}/#{lexical["harmless_case_comparison_count"]} false reviews, and the frozen cheap semantic winner produced #{semantic["heldout_harmless_review_count"]}/#{semantic["heldout_harmless_comparison_count"]} harmless held-out reviews despite detecting #{semantic["heldout_subtle_review_count"]}/#{semantic["heldout_subtle_comparison_count"]} subtle seeded comparisons.

    `#{report["recommendation"]}` is a recommendation, not an approved product decision. A different human choice may reflect strategic appetite for the cost, privacy, and latency of another semantic experiment.

    ## Denominator rules

    - Deterministic contract counts are independent approved fixture judgments.
    - Lexical counts are case-level distribution comparisons.
    - Cheap-semantic counts are batch decisions repeated across permutation seeds on the same 20 parents.

    These units are deliberately not pooled into a single accuracy or recall number.

    ## Immutable sources

    | Role | Artifact | Path | SHA-256 |
    | --- | --- | --- | --- |
    #{render_sources(report["sources"])}

    ## Operational evidence

    | Role | Run | Success/fail | Provider calls | Successful-sample latency ms | Input tokens | Output tokens |
    | --- | --- | --- | ---: | ---: | ---: | ---: |
    #{render_live_rows(live["runs"])}

    Across #{length(live["runs"])} live runs: #{live["totals"]["successful_samples"]} successful samples, #{live["totals"]["failed_samples"]} failures, #{live["totals"]["actual_calls"]} provider requests, #{live["totals"]["latency_ms"]} ms cumulative successful-sample latency, #{live["totals"]["input_tokens"]} input tokens, and #{live["totals"]["output_tokens"]} output tokens.

    Historical dollar cost is **not computable**: #{live["monetary_cost"]["reason"]} All fixture, contract, lexical-comparison, and cheap-semantic evaluation artifacts made zero provider calls. Local evaluation wall-clock latency was not instrumented.

    ## Deterministic contract evidence

    | Split | Fixtures | Valid accepted | Regressions detected | Matched expectations |
    | --- | ---: | ---: | ---: | ---: |
    #{render_contract_splits(deterministic["by_split"])}

    Overall: #{deterministic["valid_accepted_count"]}/#{deterministic["valid_fixture_count"]} valid fixtures accepted, #{deterministic["regression_detected_count"]}/#{deterministic["regression_fixture_count"]} regressions detected, #{deterministic["false_failure_count"]} false deterministic failures, and #{deterministic["missed_regression_count"]} missed configured regressions.

    | Failure mode | Detected/fixtures |
    | --- | ---: |
    #{render_failure_modes(deterministic["by_failure_mode"])}

    | Case | Fixtures | Valid accepted | Regressions detected | Matched expectations |
    | --- | ---: | ---: | ---: | ---: |
    #{render_contract_cases(deterministic["by_case"])}

    Scope: #{deterministic["scope"]}

    ## Original lexical distribution evidence

    Independent held-out control: #{lexical["independent_control_drift_review_count"]}/#{lexical["independent_control_case_comparisons"]} case comparisons requested review.

    | Batch | Seeded failure rate | Case comparisons | False reviews | Drift reviews | Deterministic regressions | Any signal |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    #{render_lexical_batches(lexical["batches"])}

    Harmless false-review rate: #{format_ratio(lexical["false_review_count"], lexical["harmless_case_comparison_count"])}. Gate: `#{lexical["gate_status"]}`.

    | Case | Held-out control | Harmless false reviews | 10% drift | 25% drift | 50% drift | Subtle 100% | Obvious 100% |
    | --- | ---: | ---: | --- | --- | --- | --- | --- |
    #{render_lexical_cases(lexical["by_case"])}

    #{lexical["denominator_note"]}

    ## Cheap semantic evidence

    Selected method: `#{semantic["method"]}`. Tuning gate: `#{semantic["tuning_gate_status"]}`. Frozen held-out gate: `#{semantic["heldout_gate_status"]}`.

    | Case | Held-out batch | Seeded failure rate | Parents | Seed comparisons | Reviews | Energy distance | Threshold |
    | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    #{render_semantic_batches(semantic["batches"])}

    Held-out harmless reviews: #{format_ratio(semantic["heldout_harmless_review_count"], semantic["heldout_harmless_comparison_count"])}. Held-out subtle sensitivity at the tested 100% seeded rate: #{format_ratio(semantic["heldout_subtle_review_count"], semantic["heldout_subtle_comparison_count"])}. Decisions were stable across seeds: `#{semantic["stable_across_seeds"]}`.

    #{semantic["denominator_note"]}

    ## Decision matrix

    | Option | Evidence status | Interpretation |
    | --- | --- | --- |
    #{render_decisions(report["decision_options"])}

    ## Limitations that carry forward

    #{render_limitations(report["limitations"])}

    Methodological reference: [NIST AI RMF Core](#{report["methodology_reference"]}) emphasizes documented test sets, metrics, uncertainty, deployment-context validity, and limits on generalizability.

    ## Human decision

    Current value: `#{report["human_decision"]}`.

    The final value must be one of: #{Enum.map_join(@decisions, ", ", &"`#{&1}`")}.
    """
  end

  defp render_sources(sources) do
    Enum.map_join(sources, "\n", fn source ->
      "| #{source["role"]} | `#{source["artifact_id"]}` | `#{source["path"]}` | `#{source["artifact_sha256"]}` |"
    end)
  end

  defp render_live_rows(rows) do
    Enum.map_join(rows, "\n", fn row ->
      "| #{row["role"]} | `#{row["run_id"]}` | #{row["successful_samples"]}/#{row["failed_samples"]} | #{row["actual_calls"]} | #{row["latency_ms"]} | #{row["input_tokens"]} | #{row["output_tokens"]} |"
    end)
  end

  defp render_contract_splits(splits) do
    Enum.map_join(splits, "\n", fn split ->
      "| #{split["split"]} | #{split["fixture_count"]} | #{split["expected_pass_matched_count"]}/#{split["expected_pass_count"]} | #{split["expected_fail_matched_count"]}/#{split["expected_fail_count"]} | #{split["matched_expectation_count"]}/#{split["fixture_count"]} |"
    end)
  end

  defp render_failure_modes(modes) do
    Enum.map_join(modes, "\n", fn mode ->
      "| #{mode["failure_mode"]} | #{mode["detected_count"]}/#{mode["fixture_count"]} |"
    end)
  end

  defp render_contract_cases(cases) do
    Enum.map_join(cases, "\n", fn contract_case ->
      "| #{contract_case["case_id"]} | #{contract_case["fixture_count"]} | #{contract_case["expected_pass_matched_count"]}/#{contract_case["expected_pass_count"]} | #{contract_case["expected_fail_matched_count"]}/#{contract_case["expected_fail_count"]} | #{contract_case["matched_expectation_count"]}/#{contract_case["fixture_count"]} |"
    end)
  end

  defp render_lexical_batches(batches) do
    Enum.map_join(batches, "\n", fn batch ->
      false_reviews =
        if is_nil(batch["false_review_count"]), do: "—", else: batch["false_review_count"]

      "| #{batch["batch_id"]} | #{percent(batch["seeded_failure_rate"])} | #{batch["case_comparison_count"]} | #{false_reviews} | #{batch["drift_review_count"]} | #{batch["deterministic_regression_count"]} | #{batch["any_signal_count"]} |"
    end)
  end

  defp render_semantic_batches(batches) do
    Enum.map_join(batches, "\n", fn batch ->
      "| #{batch["case_id"]} | #{batch["label"]} | #{percent(batch["seeded_failure_rate"])} | #{batch["parent_count"]} | #{batch["seed_comparison_count"]} | #{batch["drift_review_count"]} | #{format_float(batch["energy_distance"])} | #{format_float(batch["threshold"])} |"
    end)
  end

  defp render_lexical_cases(cases) do
    Enum.map_join(cases, "\n", fn lexical_case ->
      "| #{lexical_case["case_id"]} | #{lexical_case["control_review_count"]}/#{lexical_case["control_comparison_count"]} | #{lexical_case["harmless_review_count"]}/#{lexical_case["harmless_comparison_count"]} | #{review_label(lexical_case["mixed_10_review"])} | #{review_label(lexical_case["mixed_25_review"])} | #{review_label(lexical_case["mixed_50_review"])} | #{review_label(lexical_case["subtle_review"])} | #{review_label(lexical_case["obvious_review"])} |"
    end)
  end

  defp render_decisions(decisions) do
    Enum.map_join(decisions, "\n", fn decision ->
      "| `#{decision["decision"]}` | `#{decision["evidence_status"]}` | #{decision["reason"]} |"
    end)
  end

  defp render_limitations(limitations), do: Enum.map_join(limitations, "\n", &"- #{&1}")

  defp ensure_new_destination(path) do
    if File.exists?(path),
      do:
        error(:already_exists, "Decision reports are immutable and cannot be overwritten", %{
          path: path
        }),
      else: :ok
  end

  defp ensure_parent_directory(path) do
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok ->
        :ok

      {:error, reason} ->
        error(:mkdir_failed, "Report directory could not be created", %{
          path: path,
          reason: reason
        })
    end
  end

  defp write_atomically(path, contents) do
    suffix = System.unique_integer([:positive, :monotonic])
    temporary_path = Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp-#{suffix}")

    result =
      with :ok <- File.write(temporary_path, contents, [:binary, :exclusive]),
           :ok <- File.rename(temporary_path, path) do
        :ok
      end

    _ = File.rm(temporary_path)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        error(:write_failed, "Decision report could not be written", %{path: path, reason: reason})
    end
  end

  defp total(run, field), do: Map.get(run.totals, field, 0)
  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator
  defp percent(value), do: :erlang.float_to_binary(value * 100, decimals: 1) <> "%"

  defp format_ratio(numerator, denominator),
    do: "#{numerator}/#{denominator} (#{percent(ratio(numerator, denominator))})"

  defp format_float(value), do: :erlang.float_to_binary(value / 1, decimals: 6)
  defp review_label(true), do: "review"
  defp review_label(false), do: "no review"
  defp review_label(nil), do: "not tested"
  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_sha256?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp unique?(references, field),
    do: references |> Enum.map(& &1[field]) |> Enum.uniq() |> length() == length(references)

  defp error(type, message, details \\ %{}),
    do: {:error, %{type: type, message: message, details: details}}
end
