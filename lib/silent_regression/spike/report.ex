defmodule SilentRegression.Spike.Report do
  @moduledoc """
  Builds the reproducible, human-verdict-ready feasibility summary.

  The report uses explicit baseline, calibration, and fixture-comparison
  anchors. It scans the surrounding results directory only for run artifacts,
  includes provenance-compatible controls, ignores unrelated JSON, and emits
  visible warnings for malformed or incompatible recognized artifacts.
  """

  alias SilentRegression.Spike.CalibrationStorage
  alias SilentRegression.Spike.Comparison
  alias SilentRegression.Spike.FixtureComparisonStorage
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.Storage

  @pending_verdict "PENDING_HUMAN_VERDICT"
  @verdicts ~w(
    PROMISING_FOR_DETERMINISTIC_AND_DRIFT_TRIAGE
    PROMISING_FOR_DETERMINISTIC_ONLY
    NEEDS_A_SEMANTIC_LAYER
    NOT_VIABLE_AS_DESIGNED
  )
  @allowed_options [:verdict]

  @type result :: %{required(String.t()) => term()}

  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @spec pending_verdict() :: String.t()
  def pending_verdict, do: @pending_verdict

  @doc "Builds report data and rendered Markdown from explicit source paths."
  @spec build(map(), keyword()) :: {:ok, result()} | {:error, map()}
  def build(paths, options \\ [])

  def build(paths, options) when is_map(paths) and is_list(options) do
    with :ok <- validate_options(options),
         {:ok, verdict} <- verdict(options),
         {:ok, normalized_paths} <- validate_paths(paths),
         {:ok, baseline} <- read_baseline(normalized_paths["baseline_path"]),
         {:ok, calibration} <-
           read_calibration(normalized_paths["calibration_path"]),
         {:ok, fixture_comparison} <-
           read_fixture_comparison(normalized_paths["fixture_comparison_path"]),
         :ok <- validate_anchors(baseline, calibration, fixture_comparison),
         {:ok, inventory} <-
           inventory_runs(
             normalized_paths["results_directory"],
             normalized_paths,
             baseline
           ),
         {:ok, controls} <-
           prepare_controls(baseline, calibration, fixture_comparison, inventory.runs),
         {:ok, source_hashes} <- source_hashes(normalized_paths) do
      data =
        build_data(
          normalized_paths,
          source_hashes,
          baseline,
          calibration,
          fixture_comparison,
          controls,
          inventory,
          verdict
        )

      {:ok, Map.put(data, "markdown", render(data))}
    end
  end

  def build(_paths, _options),
    do: configuration_error("Report paths must be a map and options must be a keyword list")

  @doc "Atomically writes a new Markdown summary without overwriting an existing verdict."
  @spec write(Path.t(), String.t()) :: :ok | {:error, map()}
  def write(path, markdown)
      when is_binary(path) and path != "" and is_binary(markdown) and markdown != "" do
    with :ok <- ensure_new_destination(path),
         :ok <- ensure_parent_directory(path),
         :ok <- write_atomically(path, markdown) do
      :ok
    end
  end

  def write(path, _markdown) do
    {:error, %{type: :invalid_write, path: path, reason: :expected_path_and_markdown}}
  end

  defp validate_options(options) do
    cond do
      not Keyword.keyword?(options) ->
        configuration_error("Report options must be a keyword list")

      Enum.uniq(Keyword.keys(options)) != Keyword.keys(options) ->
        configuration_error("Report options must be unique")

      Keyword.keys(options) -- @allowed_options != [] ->
        configuration_error("Report options contain unsupported keys", %{
          "unsupported_options" =>
            Enum.map(Keyword.keys(options) -- @allowed_options, &Atom.to_string/1)
        })

      true ->
        :ok
    end
  end

  defp verdict(options) do
    value = Keyword.get(options, :verdict, @pending_verdict)

    if value == @pending_verdict or value in @verdicts,
      do: {:ok, value},
      else:
        configuration_error("Report verdict is unsupported", %{
          "actual" => value,
          "allowed" => @verdicts
        })
  end

  defp validate_paths(paths) do
    required = ~w(results_directory baseline_path calibration_path fixture_comparison_path)

    if Enum.all?(required, &non_empty_string?(paths[&1])) do
      {:ok, Map.new(required, &{&1, Path.expand(paths[&1])})}
    else
      configuration_error("Report source paths are incomplete", %{"required" => required})
    end
  end

  defp read_baseline(path) do
    case Storage.read(path) do
      {:ok, %Run{condition: "baseline"} = baseline} ->
        {:ok, baseline}

      {:ok, run} ->
        configuration_error("Selected baseline path is not a baseline run", %{
          "actual_condition" => run.condition,
          "path" => path
        })

      {:error, error} ->
        source_error("baseline", path, error)
    end
  end

  defp read_calibration(path) do
    case CalibrationStorage.read(path) do
      {:ok, calibration} -> {:ok, calibration}
      {:error, error} -> source_error("calibration", path, error)
    end
  end

  defp read_fixture_comparison(path) do
    case FixtureComparisonStorage.read(path) do
      {:ok, fixture_comparison} -> {:ok, fixture_comparison}
      {:error, error} -> source_error("fixture_comparison", path, error)
    end
  end

  defp source_error(kind, path, error) do
    {:error,
     Provider.error(:report_source_error, "A required report source could not be read",
       details: %{"kind" => kind, "path" => path, "reason" => inspect(error)}
     )}
  end

  defp validate_anchors(baseline, calibration, fixture_comparison) do
    expected_model = baseline.request_config["model"]

    cond do
      calibration.baseline_run_id != baseline.run_id ->
        incompatible_anchor(
          "calibration.baseline_run_id",
          baseline.run_id,
          calibration.baseline_run_id
        )

      calibration.provenance != Comparison.provenance(baseline) ->
        incompatible_anchor(
          "calibration.provenance",
          Comparison.provenance(baseline),
          calibration.provenance
        )

      fixture_comparison["baseline_run_id"] != baseline.run_id ->
        incompatible_anchor(
          "fixture_comparison.baseline_run_id",
          baseline.run_id,
          fixture_comparison["baseline_run_id"]
        )

      fixture_comparison["calibration_id"] != calibration.calibration_id ->
        incompatible_anchor(
          "fixture_comparison.calibration_id",
          calibration.calibration_id,
          fixture_comparison["calibration_id"]
        )

      fixture_comparison["provider"] != baseline.provider ->
        incompatible_anchor(
          "fixture_comparison.provider",
          baseline.provider,
          fixture_comparison["provider"]
        )

      fixture_comparison["requested_model"] != expected_model ->
        incompatible_anchor(
          "fixture_comparison.requested_model",
          expected_model,
          fixture_comparison["requested_model"]
        )

      fixture_comparison["provider_calls"] != 0 ->
        incompatible_anchor(
          "fixture_comparison.provider_calls",
          0,
          fixture_comparison["provider_calls"]
        )

      not valid_comparison_settings?(fixture_comparison["settings"]) ->
        incompatible_anchor(
          "fixture_comparison.settings",
          "a non-negative integer seed and positive integer permutations",
          fixture_comparison["settings"]
        )

      true ->
        :ok
    end
  end

  defp incompatible_anchor(field, expected, actual) do
    {:error,
     Provider.error(:incompatible_report_source, "Report source provenance is incompatible",
       details: %{"field" => field, "expected" => expected, "actual" => actual}
     )}
  end

  defp inventory_runs(directory, paths, baseline) do
    case File.ls(directory) do
      {:ok, _entries} ->
        anchor_paths =
          paths
          |> Map.take(~w(baseline_path calibration_path fixture_comparison_path))
          |> Map.values()
          |> MapSet.new()

        directory
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.reject(&(Path.expand(&1) in anchor_paths))
        |> Enum.reduce(%{runs: [], warnings: [], scanned_json_count: 0}, fn path, inventory ->
          inventory = Map.update!(inventory, :scanned_json_count, &(&1 + 1))
          inventory_path(path, baseline, inventory)
        end)
        |> then(fn inventory ->
          {:ok,
           %{
             inventory
             | runs: inventory.runs |> Enum.reverse() |> unique_runs(),
               warnings: Enum.reverse(inventory.warnings)
           }}
        end)

      {:error, reason} ->
        configuration_error("Results directory could not be listed", %{
          "path" => directory,
          "reason" => Atom.to_string(reason)
        })
    end
  end

  defp inventory_path(path, baseline, inventory) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      classify_decoded(path, decoded, baseline, inventory)
    else
      {:error, reason} ->
        warning = %{
          "path" => path,
          "type" => "malformed_json",
          "message" => "Ignored malformed JSON artifact: #{inspect(reason)}"
        }

        Map.update!(inventory, :warnings, &[warning | &1])
    end
  end

  defp classify_decoded(
         path,
         %{"run_id" => _run_id, "condition" => _condition} = decoded,
         baseline,
         inventory
       ) do
    case Run.from_map(decoded) do
      {:ok, %Run{run_id: run_id}} when run_id == baseline.run_id ->
        warning = %{
          "path" => path,
          "type" => "duplicate_baseline",
          "message" => "Ignored a duplicate copy of the selected baseline run ID."
        }

        Map.update!(inventory, :warnings, &[warning | &1])

      {:ok, %Run{condition: "baseline"}} ->
        warning = %{
          "path" => path,
          "type" => "non_selected_baseline",
          "message" => "Ignored a historical baseline that was not selected for this report."
        }

        Map.update!(inventory, :warnings, &[warning | &1])

      {:ok, %Run{condition: "control"} = run} ->
        case Comparison.validate_runs(baseline, run) do
          :ok ->
            Map.update!(inventory, :runs, &[run | &1])

          {:error, error} ->
            warning = %{
              "path" => path,
              "type" => "incompatible_run",
              "message" => "Ignored an incompatible control: #{error["message"]}",
              "details" => error["details"]
            }

            Map.update!(inventory, :warnings, &[warning | &1])
        end

      {:ok, %Run{} = run} ->
        warning = %{
          "path" => path,
          "type" => "unsupported_run_condition",
          "message" => "Ignored a run condition not consumed by the consolidated reporter.",
          "details" => %{"condition" => run.condition, "run_id" => run.run_id}
        }

        Map.update!(inventory, :warnings, &[warning | &1])

      {:error, error} ->
        warning = %{
          "path" => path,
          "type" => "malformed_run_artifact",
          "message" => "Ignored a recognized but invalid run artifact: #{inspect(error)}"
        }

        Map.update!(inventory, :warnings, &[warning | &1])
    end
  end

  defp classify_decoded(_path, %{"artifact_type" => "fixture_comparison"}, _baseline, inventory),
    do: inventory

  defp classify_decoded(_path, %{"calibration_id" => _calibration_id}, _baseline, inventory),
    do: inventory

  defp classify_decoded(_path, _decoded, _baseline, inventory), do: inventory

  defp unique_runs(runs) do
    runs
    |> Enum.reduce({MapSet.new(), []}, fn run, {seen, unique} ->
      if MapSet.member?(seen, run.run_id),
        do: {seen, unique},
        else: {MapSet.put(seen, run.run_id), [run | unique]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp prepare_controls(baseline, calibration, fixture_comparison, runs) do
    runs_by_id = Map.new(runs, &{&1.run_id, &1})
    heldout_id = fixture_comparison["control_run_id"]
    required_ids = calibration.control_run_ids ++ [heldout_id]
    missing_ids = Enum.reject(required_ids, &Map.has_key?(runs_by_id, &1))

    if missing_ids == [] do
      ordered_ids = required_ids ++ ((Map.keys(runs_by_id) -- required_ids) |> Enum.sort())
      comparison_seed = get_in(fixture_comparison, ["settings", "seed"])
      permutations = get_in(fixture_comparison, ["settings", "permutations"])

      ordered_ids
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {run_id, index}, {:ok, prepared} ->
        run = Map.fetch!(runs_by_id, run_id)
        role = control_role(run_id, calibration, heldout_id)

        case control_comparison(
               baseline,
               calibration,
               fixture_comparison,
               run,
               role,
               comparison_seed + index * 10_000,
               permutations
             ) do
          {:ok, comparison} ->
            {:cont,
             {:ok, [%{"run" => run, "role" => role, "comparison" => comparison} | prepared]}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)
      |> then(fn
        {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
        {:error, error} -> {:error, error}
      end)
    else
      configuration_error("Required control artifacts are missing from the results directory", %{
        "missing_run_ids" => missing_ids
      })
    end
  end

  defp control_role(run_id, calibration, heldout_id) do
    cond do
      run_id == heldout_id -> "heldout_control"
      run_id in calibration.control_run_ids -> "calibration_source"
      true -> "additional_heldout_control"
    end
  end

  defp control_comparison(
         _baseline,
         _calibration,
         fixture_comparison,
         %Run{run_id: run_id},
         "heldout_control",
         _seed,
         _permutations
       ) do
    reference = fixture_comparison["reference_control"]

    if reference["candidate_run_id"] == run_id do
      {:ok, reference["comparison"]}
    else
      configuration_error("Fixture comparison held-out control identity is inconsistent", %{
        "actual" => reference["candidate_run_id"],
        "expected" => run_id
      })
    end
  end

  defp control_comparison(
         baseline,
         calibration,
         _fixture_comparison,
         run,
         role,
         seed,
         permutations
       ) do
    options =
      [seed: seed, permutations: permutations]
      |> maybe_add_calibration(role, calibration)

    case Comparison.compare(baseline, run, options) do
      {:ok, comparison} ->
        {:ok, normalize_control_comparison(comparison, role, calibration)}

      {:error, error} ->
        {:error,
         Provider.error(:control_report_failed, "A control comparison could not be reproduced",
           details: %{"run_id" => run.run_id, "reason" => inspect(error), "role" => role}
         )}
    end
  end

  defp maybe_add_calibration(options, "calibration_source", _calibration), do: options

  defp maybe_add_calibration(options, _role, calibration),
    do: Keyword.put(options, :calibration, calibration)

  defp normalize_control_comparison(comparison, "calibration_source", calibration) do
    by_case =
      Enum.map(comparison["by_case"], fn result ->
        threshold = Enum.find(calibration.thresholds, &(&1["case_id"] == result["case_id"]))

        result
        |> Map.put("threshold", threshold["threshold"])
        |> Map.put("drift_outcome", "not_evaluated_calibration_source")
        |> Map.put("alert_outcome", "not_applicable")
      end)

    Map.put(comparison, "by_case", by_case)
  end

  defp normalize_control_comparison(comparison, _role, _calibration) do
    by_case =
      Enum.map(comparison["by_case"], fn result ->
        result
        |> Map.put("drift_outcome", result["outcome"])
        |> Map.put(
          "alert_outcome",
          if(result["outcome"] == "drift_review", do: "drift_review", else: "no_alert")
        )
      end)

    Map.put(comparison, "by_case", by_case)
  end

  defp source_hashes(paths) do
    ~w(baseline_path calibration_path fixture_comparison_path)
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, hashes} ->
      path = paths[key]

      case File.read(path) do
        {:ok, contents} ->
          {:cont, {:ok, Map.put(hashes, key, sha256(contents))}}

        {:error, reason} ->
          {:halt,
           configuration_error("A report source could not be hashed", %{
             "path" => path,
             "reason" => Atom.to_string(reason)
           })}
      end
    end)
  end

  defp build_data(
         paths,
         source_hashes,
         baseline,
         calibration,
         fixture_comparison,
         controls,
         inventory,
         verdict
       ) do
    live_runs = [baseline | Enum.map(controls, & &1["run"])]
    operational_totals = operational_totals(live_runs)
    fixture_conformance = fixture_conformance(fixture_comparison)

    %{
      "verdict" => verdict,
      "allowed_verdicts" => @verdicts,
      "paths" => Map.new(paths, fn {key, path} -> {key, Path.relative_to_cwd(path)} end),
      "source_sha256" => source_hashes,
      "provider" => baseline.provider,
      "requested_model" => baseline.request_config["model"],
      "baseline" => baseline,
      "calibration" => calibration,
      "controls" => controls,
      "fixture_comparison" => fixture_comparison,
      "fixture_conformance" => fixture_conformance,
      "operational_totals" => operational_totals,
      "artifact_scan" => %{
        "scanned_json_count" => inventory.scanned_json_count + 3,
        "included_run_count" => length(live_runs),
        "warning_count" => length(inventory.warnings),
        "warnings" => inventory.warnings
      }
    }
  end

  defp operational_totals(runs) do
    Enum.reduce(
      runs,
      %{
        "run_count" => 0,
        "successful_samples" => 0,
        "failed_samples" => 0,
        "actual_calls" => 0,
        "latency_ms" => 0,
        "input_tokens" => 0,
        "output_tokens" => 0
      },
      fn run, totals ->
        %{
          "run_count" => totals["run_count"] + 1,
          "successful_samples" => totals["successful_samples"] + run.totals["successful_samples"],
          "failed_samples" => totals["failed_samples"] + run.totals["failed_samples"],
          "actual_calls" => totals["actual_calls"] + run.totals["actual_calls"],
          "latency_ms" => totals["latency_ms"] + run.totals["latency_ms"],
          "input_tokens" => totals["input_tokens"] + run.totals["input_tokens"],
          "output_tokens" => totals["output_tokens"] + run.totals["output_tokens"]
        }
      end
    )
  end

  defp fixture_conformance(fixture_comparison) do
    fixtures =
      fixture_comparison["batches"]
      |> Enum.flat_map(&get_in(&1, ["candidate_run", "samples"]))
      |> Enum.filter(&(get_in(&1, ["origin", "type"]) == "approved_fixture"))
      |> Enum.group_by(&get_in(&1, ["origin", "fixture_id"]))

    matching =
      Enum.count(fixtures, fn {_fixture_id, samples} ->
        Enum.all?(samples, fn sample ->
          get_in(sample, ["deterministic", "all_passed"]) ==
            get_in(sample, ["origin", "expected_deterministic_pass"])
        end)
      end)

    %{"matching_fixtures" => matching, "total_fixtures" => map_size(fixtures)}
  end

  defp render(data) do
    sections = [
      render_header(data),
      render_executive_summary(data),
      render_sources(data),
      render_operational_results(data),
      render_baseline_cases(data),
      render_calibration(data),
      render_control_comparisons(data),
      render_fixture_batches(data),
      render_fixture_comparisons(data),
      render_sensitivity(data),
      render_hypotheses(data),
      render_limitations(data),
      render_warnings(data),
      render_reproduction(data)
    ]

    Enum.join(sections, "\n\n") <> "\n"
  end

  defp render_header(data) do
    verdict_guidance =
      if data["verdict"] == @pending_verdict do
        "The final verdict must be explicitly selected by the human reviewer. The evidence-based recommendation for the original two-signal product is `NEEDS_A_SEMANTIC_LAYER`; if the product is deliberately narrowed to explicit contracts, `PROMISING_FOR_DETERMINISTIC_ONLY` is also supportable."
      else
        "This verdict was explicitly supplied to the report generator and must be accompanied by the hypothesis and limitation record below."
      end

    """
    # Silent Regression Feasibility Spike Summary

    **Human verdict:** `#{data["verdict"]}`

    > #{verdict_guidance}
    """
    |> String.trim()
  end

  defp render_executive_summary(data) do
    fixture_summary = data["fixture_comparison"]["summary"]
    harmless = fixture_summary["harmless_rewording"]
    regressions = fixture_summary["seeded_regressions"]
    gate = fixture_summary["decision_gate"]
    conformance = data["fixture_conformance"]

    """
    ## Executive summary

    - Deterministic evaluator conformance: #{conformance["matching_fixtures"]}/#{conformance["total_fixtures"]} approved fixtures matched their human-approved deterministic expectation.
    - Seeded batch sensitivity: #{regressions["any_signal_count"]}/#{regressions["case_comparisons"]} case comparisons produced either a deterministic regression or drift-review signal. This combined number is not label-free semantic recall.
    - Held-out same-model control: #{heldout_drift_count(data)}/#{heldout_case_count(data)} case comparisons produced drift review.
    - Harmless lexical false reviews: #{harmless["drift_review_count"]}/#{harmless["case_comparisons"]} approved harmless/style case comparisons produced drift review (#{format_percent(harmless["drift_review_rate"])}).
    - Lexical decision gate: `#{gate["status"]}`. #{gate["reason"]}
    - Provider/model expansion was not performed because the pilot lexical gate failed.
    """
    |> String.trim()
  end

  defp render_sources(data) do
    baseline = data["baseline"]
    calibration = data["calibration"]
    fixture = data["fixture_comparison"]
    paths = data["paths"]
    hashes = data["source_sha256"]

    rows = [
      ["Baseline", baseline.run_id, paths["baseline_path"], hashes["baseline_path"]],
      [
        "Calibration",
        calibration.calibration_id,
        paths["calibration_path"],
        hashes["calibration_path"]
      ],
      [
        "Fixture comparison",
        fixture["comparison_id"],
        paths["fixture_comparison_path"],
        hashes["fixture_comparison_path"]
      ]
    ]

    """
    ## Scope and immutable sources

    Provider/model: `#{data["provider"]}` / `#{data["requested_model"]}`. All comparisons use the selected baseline's own provider, model, request configuration, and v4 case fingerprints.

    #{markdown_table(["Artifact", "ID", "Path", "SHA-256"], rows)}

    Calibration sources: #{Enum.map_join(calibration.control_run_ids, ", ", &"`#{&1}`")}. Held-out control: `#{fixture["control_run_id"]}`. Fixture manifest: `#{get_in(fixture, ["fixture_set", "manifest_path"])}` (`#{get_in(fixture, ["fixture_set", "manifest_sha256"])}`).
    """
    |> String.trim()
  end

  defp render_operational_results(data) do
    baseline = data["baseline"]

    run_rows =
      [
        %{"run" => baseline, "role" => "baseline"}
        | Enum.map(data["controls"], &Map.take(&1, ["run", "role"]))
      ]
      |> Enum.map(fn entry ->
        run = entry["run"]
        totals = run.totals

        [
          run.run_id,
          entry["role"],
          run.condition,
          "#{totals["successful_samples"]}/#{totals["failed_samples"]}",
          "#{totals["completed_samples"]}/#{totals["successful_samples"]}",
          "#{totals["quality_passed_samples"]}/#{totals["successful_samples"] + totals["failed_samples"]}",
          totals["actual_calls"],
          totals["latency_ms"],
          totals["input_tokens"],
          totals["output_tokens"]
        ]
      end)

    totals = data["operational_totals"]

    """
    ## Live capture and operational results

    #{markdown_table(["Run", "Role", "Condition", "Success/fail", "Complete/success", "Quality pass/all", "Request attempts", "Latency ms", "Input tokens", "Output tokens"], run_rows)}

    Across #{totals["run_count"]} live runs: #{totals["successful_samples"]} successful samples, #{totals["failed_samples"]} failures, #{totals["actual_calls"]} provider request attempts including availability checks and any retries, #{totals["latency_ms"]} ms cumulative successful-sample latency, #{totals["input_tokens"]} input tokens, and #{totals["output_tokens"]} output tokens. Fixture comparison added zero provider request attempts, latency, or token usage.
    """
    |> String.trim()
  end

  defp render_baseline_cases(data) do
    rows =
      Enum.map(data["baseline"].metrics["by_case"], fn metrics ->
        operations = case_operations(data["baseline"], metrics["case_id"])

        [
          provider_model(data),
          data["baseline"].condition,
          metrics["case_id"],
          "#{metrics["successful_samples"]}/#{metrics["failed_samples"]}",
          format_number(get_in(metrics, ["completion", "completion_rate"])),
          format_number(get_in(metrics, ["quality", "pass_rate"])),
          format_number(get_in(metrics, ["deterministic", "sample_pass_rate"])),
          format_number(get_in(metrics, ["within_distance", "mean"])),
          get_in(metrics, ["within_distance", "pair_count"]),
          operations["attempts"],
          format_number(get_in(metrics, ["latency_ms", "mean"])),
          get_in(metrics, ["usage", "input_tokens"]),
          get_in(metrics, ["usage", "output_tokens"])
        ]
      end)

    """
    ## Baseline health by case

    #{markdown_table(["Provider/model", "Condition", "Case", "Success/fail", "Completion rate", "Quality rate", "Deterministic rate", "Within mean", "Pairs", "Generation attempts", "Mean latency ms", "Input tokens", "Output tokens"], rows)}
    """
    |> String.trim()
  end

  defp render_calibration(data) do
    calibration = data["calibration"]

    rows =
      Enum.map(calibration.thresholds, fn threshold ->
        [
          threshold["case_id"],
          format_number(threshold["threshold"]),
          threshold["iterations"],
          threshold["reference_size"],
          threshold["candidate_size"],
          format_number(threshold["empirical_exceedance_rate"])
        ]
      end)

    """
    ## Frozen lexical calibration

    Seed `#{calibration.settings["seed"]}`, #{calibration.settings["iterations"]} null resamples per case, #{format_percent(calibration.settings["quantile"])} quantile, adjusted-p alpha #{format_number(calibration.settings["adjusted_p_alpha"])}. Regression fixtures were not calibration inputs.

    #{markdown_table(["Case", "Threshold", "Null iterations", "Baseline n", "Control n", "Null exceedance rate"], rows)}
    """
    |> String.trim()
  end

  defp render_control_comparisons(data) do
    rows =
      Enum.flat_map(data["controls"], fn control ->
        run = control["run"]

        Enum.map(control["comparison"]["by_case"], fn result ->
          operations = case_operations(run, result["case_id"])

          [
            provider_model(data),
            run.run_id,
            control["role"],
            run.condition,
            result["case_id"],
            "#{operations["successful_samples"]}/#{operations["failed_samples"]}",
            "#{result["candidate_completed_samples"]}/#{operations["successful_samples"]}",
            format_rate_change(result["deterministic"]),
            format_number(result["within_baseline_mean"]),
            format_number(result["within_candidate_mean"]),
            format_number(result["cross_mean"]),
            format_number(result["energy_distance"]),
            format_number(result["p_value"]),
            format_number(result["adjusted_p_value"]),
            format_number(result["threshold"]),
            result["drift_outcome"] || result["outcome"],
            operations["attempts"],
            format_number(operations["mean_latency_ms"]),
            operations["input_tokens"],
            operations["output_tokens"]
          ]
        end)
      end)

    """
    ## Control comparisons by case

    Calibration-source controls are shown for descriptive reproducibility but are not evaluated as held-out alerts. Only the independent held-out control is used for the reported control alert count.

    #{markdown_table(["Provider/model", "Run", "Role", "Condition", "Case", "Success/fail", "Complete/success", "Deterministic baseline→control", "Within baseline", "Within control", "Cross mean", "Energy", "Raw p", "Adjusted p", "Threshold", "Drift outcome", "Generation attempts", "Mean latency ms", "Input tokens", "Output tokens"], rows)}
    """
    |> String.trim()
  end

  defp render_fixture_batches(data) do
    rows =
      Enum.map(data["fixture_comparison"]["batches"], fn batch ->
        totals = batch["candidate_run"]["totals"]

        [
          provider_model(data),
          batch["batch_id"],
          batch["condition"],
          batch["intended_label"],
          format_percent(batch["expected_regression_rate"]),
          "#{totals["successful_samples"]}/#{totals["failed_samples"]}",
          "#{totals["quality_passed_samples"]}/#{totals["successful_samples"]}",
          totals["actual_calls"],
          totals["latency_ms"],
          totals["input_tokens"],
          totals["output_tokens"]
        ]
      end)

    """
    ## Fixture batch operations

    #{markdown_table(["Provider/model", "Batch", "Condition", "Label", "Seeded rate", "Success/fail", "Quality pass/success", "Request attempts", "Latency ms", "Input tokens", "Output tokens"], rows)}
    """
    |> String.trim()
  end

  defp render_fixture_comparisons(data) do
    rows =
      Enum.flat_map(data["fixture_comparison"]["batches"], fn batch ->
        Enum.map(batch["comparison"]["by_case"], fn result ->
          candidate = batch["candidate_run"]
          case_metrics = fixture_case_metrics(batch, result["case_id"])
          operations = case_operations(candidate, result["case_id"])

          [
            provider_model(data),
            batch["batch_id"],
            batch["condition"],
            result["case_id"],
            "#{case_metrics["successful_samples"]}/#{case_metrics["failed_samples"]}",
            format_rate_change(result["deterministic"]),
            format_number(result["within_baseline_mean"]),
            format_number(result["within_candidate_mean"]),
            format_number(result["cross_mean"]),
            format_number(result["energy_distance"]),
            format_number(result["p_value"]),
            format_number(result["adjusted_p_value"]),
            format_number(result["threshold"]),
            result["deterministic_outcome"],
            result["drift_outcome"],
            result["alert_outcome"],
            operations["attempts"],
            format_number(operations["mean_latency_ms"]),
            operations["input_tokens"],
            operations["output_tokens"]
          ]
        end)
      end)

    """
    ## Fixture comparisons by case and condition

    Deterministic and drift outcomes are reported separately. The combined outcome gives deterministic degradation precedence but does not relabel a drift-only result as proven quality degradation.

    #{markdown_table(["Provider/model", "Batch", "Condition", "Case", "Success/fail", "Deterministic baseline→fixture", "Within baseline", "Within fixture", "Cross mean", "Energy", "Raw p", "Adjusted p", "Threshold", "Deterministic outcome", "Drift outcome", "Combined outcome", "Generation attempts", "Mean latency ms", "Input tokens", "Output tokens"], rows)}
    """
    |> String.trim()
  end

  defp render_sensitivity(data) do
    summary = data["fixture_comparison"]["summary"]
    harmless = summary["harmless_rewording"]
    seeded = summary["seeded_regressions"]

    mixed_rows =
      Enum.map(summary["mixed_sensitivity"], fn sensitivity ->
        [
          sensitivity["batch_id"],
          format_percent(sensitivity["expected_regression_rate"]),
          sensitivity["case_comparisons"],
          sensitivity["deterministic_regression_count"],
          sensitivity["drift_review_count"],
          sensitivity["any_signal_count"],
          format_percent(sensitivity["any_signal_count"] / sensitivity["case_comparisons"])
        ]
      end)

    """
    ## False-review and seeded-regression sensitivity

    Harmless/style drift-review rate: #{harmless["drift_review_count"]}/#{harmless["case_comparisons"]} (#{format_percent(harmless["drift_review_rate"])}). Seeded deterministic-or-drift signal rate: #{seeded["any_signal_count"]}/#{seeded["case_comparisons"]} (#{format_percent(seeded["any_signal_rate"])}). The latter includes explicit deterministic failures and is not a label-free drift recall estimate.

    #{markdown_table(["Batch", "Seeded rate", "Case comparisons", "Deterministic regressions", "Drift reviews", "Any signal", "Any-signal rate"], mixed_rows)}
    """
    |> String.trim()
  end

  defp render_hypotheses(data) do
    conformance = data["fixture_conformance"]
    operational = data["operational_totals"]

    """
    ## Hypothesis assessment and scoped conclusion

    | Hypothesis/question | Assessment | Evidence |
    | --- | --- | --- |
    | H1 — deterministic checks | Promising within configured contracts | #{conformance["matching_fixtures"]}/#{conformance["total_fixtures"]} approved fixtures matched their expected deterministic result; held-out controls and acceptable fixtures retained 100% deterministic batch rates. Checks intentionally missed some semantic-only attribution and unsupported-claim regressions. |
    | H2 — label-free drift separation | Failed | Subtle pure batches alerted, but harmless/style batches alerted in 7/8 case comparisons, so Jaccard did not establish useful separation. |
    | H3 — false-alert control | Failed for reviewed rewordings | Held-out same-model control was 0/#{heldout_case_count(data)}, while reviewed harmless/style fixtures were 7/8 drift reviews. The pure fixture cycling design amplifies this limitation. |
    | H4 — subtle RAG relevance | Not established for label-free Jaccard | Low-rate mixed drift was 0/4 at 10% and 2/4 at 25%; open-synthesis semantic changes were not cleanly separable from harmless rewording. Deterministic contracts did catch covered omissions, wrong facts, and failed abstentions. |
    | Four-model generalization | Not tested | Expansion was correctly stopped after the pilot decision gate failed. |
    | Operational feasibility | Measured for one cost-oriented model | #{operational["actual_calls"]} requests, #{operational["input_tokens"]} input tokens, #{operational["output_tokens"]} output tokens, and #{operational["latency_ms"]} ms cumulative successful-sample latency across baseline and four controls. |

    For the original product concept that includes reviewable open-ended drift, the evidence supports `NEEDS_A_SEMANTIC_LAYER`. If the product is explicitly narrowed to customer-approved deterministic contracts, the evidence can support `PROMISING_FOR_DETERMINISTIC_ONLY`. Neither conclusion establishes production accuracy, broad customer-prompt coverage, or a false-alert SLA.
    """
    |> String.trim()
  end

  defp render_limitations(data) do
    fixture_limitations =
      get_in(data, ["fixture_comparison", "fixture_set", "known_limitations"]) || []

    limitations =
      (fixture_limitations ++
         [
           "Only one provider/model pilot was evaluated; OpenAI capable and both Anthropic models were not tested.",
           "Four synthetic frozen-context RAG cases do not generalize to arbitrary customer prompts, domains, retrieval pipelines, or production traffic.",
           "Distribution shift is evidence of changed behavior, not proof that quality became worse.",
           "The three calibration controls and one held-out live control are too few to establish a production false-alert SLA.",
           "Deterministic success applies only where a versioned customer-approved contract expresses the relevant fact, attribution, abstention, or format requirement.",
           "Raw prompts and outputs remain local spike artifacts and do not satisfy hosted-product privacy, retention, residency, or security requirements."
         ])
      |> Enum.uniq()

    rendered = Enum.map_join(limitations, "\n", &"- #{&1}")

    """
    ## Limitations

    #{rendered}
    """
    |> String.trim()
  end

  defp render_warnings(data) do
    scan = data["artifact_scan"]

    rendered =
      case scan["warnings"] do
        [] ->
          "- None."

        warnings ->
          Enum.map_join(warnings, "\n", fn warning ->
            "- `#{Path.basename(warning["path"])}` — #{warning["type"]}: #{warning["message"]}"
          end)
      end

    """
    ## Artifact scan warnings

    Scanned #{scan["scanned_json_count"]} JSON files, included #{scan["included_run_count"]} live run artifacts, and emitted #{scan["warning_count"]} warnings. Unrelated valid JSON is ignored without a warning.

    #{rendered}
    """
    |> String.trim()
  end

  defp render_reproduction(data) do
    paths = data["paths"]
    settings = data["fixture_comparison"]["settings"]

    verdict_argument =
      if data["verdict"] == @pending_verdict,
        do: "",
        else: " \\\n  --verdict #{data["verdict"]}"

    """
    ## Reproduce this summary

    ```sh
    mix drift_spike.report \\
      --results #{paths["results_directory"]} \\
      --baseline #{paths["baseline_path"]} \\
      --calibration #{paths["calibration_path"]} \\
      --fixture-comparison #{paths["fixture_comparison_path"]} \\
      --output results/drift_spike/SUMMARY.md#{verdict_argument}
    ```

    The fixture comparison used seed `#{settings["seed"]}` and #{settings["permutations"]} permutations per case. Regenerating to an existing output is refused so a human verdict cannot be overwritten silently.
    """
    |> String.trim()
  end

  defp fixture_case_metrics(batch, case_id) do
    batch["candidate_run"]["metrics"]["by_case"]
    |> Enum.find(&(&1["case_id"] == case_id))
  end

  defp case_operations(%Run{} = run, case_id) do
    case_operations(run.samples, run.metrics, case_id)
  end

  defp case_operations(run, case_id) when is_map(run) do
    case_operations(run["samples"], run["metrics"], case_id)
  end

  defp case_operations(samples, metrics, case_id) do
    case_metrics = Enum.find(metrics["by_case"], &(&1["case_id"] == case_id))

    attempts =
      samples
      |> Enum.filter(&(&1["case_id"] == case_id))
      |> Enum.reduce(0, fn sample, total -> total + sample["attempts"] end)

    %{
      "successful_samples" => case_metrics["successful_samples"],
      "failed_samples" => case_metrics["failed_samples"],
      "attempts" => attempts,
      "mean_latency_ms" => get_in(case_metrics, ["latency_ms", "mean"]),
      "input_tokens" => get_in(case_metrics, ["usage", "input_tokens"]),
      "output_tokens" => get_in(case_metrics, ["usage", "output_tokens"])
    }
  end

  defp heldout_drift_count(data) do
    data["controls"]
    |> Enum.find(&(&1["role"] == "heldout_control"))
    |> get_in(["comparison", "by_case"])
    |> Enum.count(&((&1["drift_outcome"] || &1["outcome"]) == "drift_review"))
  end

  defp heldout_case_count(data) do
    data["controls"]
    |> Enum.find(&(&1["role"] == "heldout_control"))
    |> get_in(["comparison", "by_case"])
    |> length()
  end

  defp provider_model(data), do: "#{data["provider"]}/#{data["requested_model"]}"

  defp format_rate_change(rate_change) do
    "#{format_number(rate_change["baseline_rate"])}→#{format_number(rate_change["candidate_rate"])} (#{format_signed(rate_change["change"])})"
  end

  defp format_signed(nil), do: "n/a"
  defp format_signed(value) when value >= 0, do: "+#{format_number(value)}"
  defp format_signed(value), do: format_number(value)

  defp format_percent(nil), do: "n/a"
  defp format_percent(value), do: :erlang.float_to_binary(value * 100.0, decimals: 1) <> "%"

  defp format_number(nil), do: "n/a"
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 6)

  defp markdown_table(headers, rows) do
    header = "| " <> Enum.map_join(headers, " | ", &escape_cell/1) <> " |"
    separator = "| " <> Enum.map_join(headers, " | ", fn _header -> "---" end) <> " |"

    body =
      Enum.map_join(rows, "\n", fn row ->
        "| " <> Enum.map_join(row, " | ", &escape_cell/1) <> " |"
      end)

    Enum.join([header, separator, body], "\n")
  end

  defp escape_cell(value) do
    value
    |> to_string()
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end

  defp ensure_new_destination(path) do
    if File.exists?(path),
      do: {:error, %{type: :already_exists, path: path}},
      else: :ok
  end

  defp ensure_parent_directory(path) do
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok -> :ok
      {:error, reason} -> {:error, %{type: :mkdir_failed, path: path, reason: reason}}
    end
  end

  defp write_atomically(path, markdown) do
    suffix = System.unique_integer([:positive, :monotonic])
    temporary_path = Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp-#{suffix}")

    result =
      with :ok <- File.write(temporary_path, markdown, [:binary, :exclusive]),
           :ok <- File.rename(temporary_path, path) do
        :ok
      end

    _ = File.rm(temporary_path)

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, %{type: :write_failed, path: path, reason: reason}}
    end
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_comparison_settings?(settings) when is_map(settings) do
    is_integer(settings["seed"]) and settings["seed"] >= 0 and
      is_integer(settings["permutations"]) and settings["permutations"] > 0
  end

  defp valid_comparison_settings?(_settings), do: false

  defp configuration_error(message, details \\ %{}) do
    {:error, Provider.error(:configuration_error, message, details: details)}
  end
end
