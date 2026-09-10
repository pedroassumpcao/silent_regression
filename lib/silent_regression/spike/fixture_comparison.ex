defmodule SilentRegression.Spike.FixtureComparison do
  @moduledoc """
  Builds approved fixture batches and compares them with a frozen baseline.

  Every candidate is assembled locally from the held-out control's provider
  provenance. No provider request is made. Individual samples retain an origin
  record identifying either the held-out control observation or the exact
  approved fixture that replaced it.
  """

  alias SilentRegression.Spike.AlertOutcome
  alias SilentRegression.Spike.Calibration
  alias SilentRegression.Spike.Comparison
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Response
  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.RunAnalysis

  @schema_version 1
  @artifact_type "fixture_comparison"
  @default_deterministic_drop_threshold 0.0
  @allowed_options [
    :clock,
    :comparison_id,
    :deterministic_drop_threshold,
    :git_revision,
    :permutations,
    :seed
  ]

  @type report :: %{required(String.t()) => term()}

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec artifact_type() :: String.t()
  def artifact_type, do: @artifact_type

  @doc "Evaluates all approved fixture blueprints without provider calls."
  @spec run(Run.t(), Calibration.t(), Run.t(), map(), keyword()) ::
          {:ok, report()} | {:error, map()}
  def run(%Run{} = baseline, %Calibration{} = calibration, %Run{} = control, fixture_set, options)
      when is_map(fixture_set) and is_list(options) do
    with :ok <- validate_options(options),
         {:ok, seed} <- required_integer(options, :seed),
         {:ok, permutations} <- positive_integer(options, :permutations, 999),
         {:ok, deterministic_threshold} <- deterministic_threshold(options),
         :ok <- validate_fixture_set(fixture_set),
         :ok <- validate_control(control),
         :ok <- validate_sample_size(fixture_set, calibration),
         {:ok, created_at} <- timestamp(options),
         {:ok, comparison_id} <- comparison_id(options, created_at),
         {:ok, git_revision} <- git_revision(options),
         {:ok, reference_comparison} <-
           Comparison.compare(baseline, control,
             seed: seed,
             permutations: permutations,
             calibration: calibration
           ),
         reference <-
           build_reference_result(reference_comparison, deterministic_threshold),
         {:ok, batches} <-
           build_batches(
             baseline,
             calibration,
             control,
             fixture_set,
             comparison_id,
             created_at,
             git_revision,
             seed,
             permutations,
             deterministic_threshold
           ) do
      report =
        build_report(
          baseline,
          calibration,
          control,
          fixture_set,
          comparison_id,
          created_at,
          git_revision,
          seed,
          permutations,
          deterministic_threshold,
          reference,
          batches
        )

      case validate_report(report) do
        :ok -> {:ok, report}
        {:error, error} -> {:error, error}
      end
    end
  end

  def run(_baseline, _calibration, _control, _fixture_set, _options) do
    configuration_error(
      "Fixture comparison requires baseline, calibration, control, fixture set, and keyword options"
    )
  end

  @doc "Validates the persisted Task 11 fixture-comparison schema."
  @spec validate_report(map()) :: :ok | {:error, map()}
  def validate_report(report) when is_map(report) do
    cond do
      report["schema_version"] != @schema_version ->
        invalid_report("schema_version is unsupported")

      report["artifact_type"] != @artifact_type ->
        invalid_report("artifact_type is invalid")

      not Enum.all?(
        ~w(comparison_id created_at baseline_run_id calibration_id control_run_id),
        &non_empty_string?(report[&1])
      ) ->
        invalid_report("artifact identity is incomplete")

      get_in(report, ["fixture_set", "status"]) != "approved" ->
        invalid_report("fixture set is not approved")

      not (is_list(report["batches"]) and report["batches"] != []) ->
        invalid_report("batches must be a non-empty list")

      not Enum.all?(report["batches"], &valid_batch?/1) ->
        invalid_report("a batch is invalid")

      not valid_alert_outcomes?(report["batches"]) ->
        invalid_report("an alert outcome is invalid")

      not is_map(report["summary"]) ->
        invalid_report("summary must be a JSON object")

      true ->
        :ok
    end
  end

  def validate_report(_report), do: invalid_report("report must be a JSON object")

  defp validate_options(options) do
    cond do
      not Keyword.keyword?(options) ->
        configuration_error("Fixture comparison options must be a keyword list")

      Enum.uniq(Keyword.keys(options)) != Keyword.keys(options) ->
        configuration_error("Fixture comparison options must be unique")

      Keyword.keys(options) -- @allowed_options != [] ->
        configuration_error("Fixture comparison options contain unsupported keys", %{
          "unsupported_options" =>
            Enum.map(Keyword.keys(options) -- @allowed_options, &Atom.to_string/1)
        })

      true ->
        :ok
    end
  end

  defp validate_fixture_set(%{
         "manifest" => %{
           "status" => "approved",
           "review_required" => false,
           "batch_blueprints" => blueprints
         },
         "manifest_sha256" => fingerprint,
         "fixtures" => fixtures,
         "fixtures_by_case" => fixtures_by_case
       })
       when is_list(blueprints) and blueprints != [] and is_binary(fingerprint) and
              is_list(fixtures) and fixtures != [] and is_map(fixtures_by_case),
       do: :ok

  defp validate_fixture_set(_fixture_set) do
    configuration_error("Fixture set must be loaded from the approved manifest")
  end

  defp validate_control(%Run{condition: "control"}), do: :ok

  defp validate_control(%Run{} = control) do
    configuration_error("Fixture comparison requires a held-out control run", %{
      "actual_condition" => control.condition
    })
  end

  defp validate_sample_size(fixture_set, calibration) do
    fixture_size = get_in(fixture_set, ["manifest", "sample_size"])
    calibrated_size = calibration.settings["control_group_size"]

    if fixture_size == calibrated_size do
      :ok
    else
      configuration_error("Fixture sample size does not match frozen calibration", %{
        "calibration_sample_size" => calibrated_size,
        "fixture_sample_size" => fixture_size
      })
    end
  end

  defp build_batches(
         baseline,
         calibration,
         control,
         fixture_set,
         comparison_id,
         created_at,
         git_revision,
         seed,
         permutations,
         deterministic_threshold
       ) do
    fixture_set["manifest"]["batch_blueprints"]
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {blueprint, batch_index}, {:ok, batches} ->
      batch_seed = seed + (batch_index + 1) * 10_000

      with {:ok, candidate} <-
             build_candidate_run(
               baseline,
               control,
               fixture_set,
               blueprint,
               comparison_id,
               created_at,
               git_revision
             ),
           {:ok, comparison} <-
             Comparison.compare(baseline, candidate,
               seed: batch_seed,
               permutations: permutations,
               calibration: calibration
             ) do
        batch =
          build_batch_result(
            blueprint,
            candidate,
            comparison,
            deterministic_threshold,
            batch_seed
          )

        {:cont, {:ok, [batch | batches]}}
      else
        {:error, error} -> {:halt, {:error, add_batch_context(error, blueprint["id"])}}
      end
    end)
    |> then(fn
      {:ok, batches} -> {:ok, Enum.reverse(batches)}
      {:error, error} -> {:error, error}
    end)
  end

  defp build_candidate_run(
         baseline,
         control,
         fixture_set,
         blueprint,
         comparison_id,
         created_at,
         git_revision
       ) do
    sample_size = blueprint["sample_size"]

    with {:ok, samples} <-
           build_candidate_samples(
             baseline,
             control,
             fixture_set,
             blueprint,
             created_at,
             sample_size
           ),
         {:ok, %{"samples" => scored_samples, "metrics" => metrics}} <-
           RunAnalysis.analyze(baseline.cases, samples),
         totals <- candidate_totals(scored_samples, metrics),
         {:ok, run} <-
           Run.new(%{
             run_id: "#{comparison_id}:#{blueprint["id"]}",
             label: "approved fixture batch #{blueprint["id"]}",
             condition: blueprint["condition"],
             started_at: created_at,
             completed_at: created_at,
             git_revision: git_revision,
             provider: baseline.provider,
             request_config: Map.put(baseline.request_config, "samples_per_case", sample_size),
             cases: baseline.cases,
             samples: scored_samples,
             metrics: metrics,
             totals: totals
           }) do
      {:ok, run}
    end
  end

  defp build_candidate_samples(
         baseline,
         control,
         fixture_set,
         blueprint,
         created_at,
         sample_size
       ) do
    baseline.cases
    |> Enum.reduce_while({:ok, []}, fn case_definition, {:ok, all_samples} ->
      with {:ok, control_samples} <-
             control_samples(control, case_definition.id, sample_size),
           {:ok, fixtures} <- matching_fixtures(fixture_set, blueprint, case_definition.id),
           {:ok, case_samples} <-
             assemble_case_samples(
               control,
               control_samples,
               fixtures,
               blueprint,
               case_definition,
               created_at
             ) do
        {:cont, {:ok, Enum.reverse(case_samples, all_samples)}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, samples} -> {:ok, Enum.reverse(samples)}
      {:error, error} -> {:error, error}
    end)
  end

  defp control_samples(control, case_id, sample_size) do
    samples =
      control.samples
      |> Enum.filter(&(&1["case_id"] == case_id))
      |> Enum.sort_by(& &1["sample_index"])

    indexes = Enum.map(samples, & &1["sample_index"])
    expected_indexes = Enum.to_list(0..(sample_size - 1))

    complete? =
      Enum.all?(samples, fn sample ->
        sample["status"] == "ok" and get_in(sample, ["completion", "passed"]) == true
      end)

    if indexes == expected_indexes and complete? do
      {:ok, samples}
    else
      configuration_error("Held-out control samples are incomplete or unordered", %{
        "actual_indexes" => indexes,
        "case_id" => case_id,
        "expected_indexes" => expected_indexes
      })
    end
  end

  defp matching_fixtures(fixture_set, blueprint, case_id) do
    filter = blueprint["assembly"]["fixture_filter"]

    fixtures =
      fixture_set["fixtures_by_case"]
      |> Map.get(case_id, [])
      |> Enum.filter(fn fixture ->
        Enum.all?(filter, fn {key, value} -> fixture[key] == value end)
      end)

    if fixtures == [] do
      configuration_error("Approved batch has no matching fixture for a case", %{
        "batch_id" => blueprint["id"],
        "case_id" => case_id
      })
    else
      {:ok, fixtures}
    end
  end

  defp assemble_case_samples(
         control,
         control_samples,
         fixtures,
         %{"assembly" => %{"type" => "cycle_matching_fixtures"}} = blueprint,
         case_definition,
         created_at
       ) do
    control_samples
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {control_sample, index}, {:ok, samples} ->
      fixture = Enum.at(fixtures, rem(index, length(fixtures)))
      origin = fixture_origin(fixture, control, control_sample, blueprint)

      case local_sample(
             control_sample,
             case_definition,
             fixture["output_text"],
             origin,
             created_at
           ) do
        {:ok, sample} -> {:cont, {:ok, [sample | samples]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_result()
  end

  defp assemble_case_samples(
         control,
         control_samples,
         fixtures,
         %{
           "assembly" => %{
             "type" => "replace_control_samples",
             "sample_indexes" => replacement_indexes
           }
         } = blueprint,
         case_definition,
         created_at
       ) do
    fixtures_by_index =
      replacement_indexes
      |> Enum.with_index()
      |> Map.new(fn {sample_index, fixture_index} ->
        {sample_index, Enum.at(fixtures, rem(fixture_index, length(fixtures)))}
      end)

    control_samples
    |> Enum.reduce_while({:ok, []}, fn control_sample, {:ok, samples} ->
      fixture = Map.get(fixtures_by_index, control_sample["sample_index"])

      {output_text, origin} =
        if fixture do
          {fixture["output_text"], fixture_origin(fixture, control, control_sample, blueprint)}
        else
          {get_in(control_sample, ["response", "output_text"]),
           control_origin(control, control_sample, blueprint)}
        end

      case local_sample(control_sample, case_definition, output_text, origin, created_at) do
        {:ok, sample} -> {:cont, {:ok, [sample | samples]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_result()
  end

  defp assemble_case_samples(
         _control,
         _control_samples,
         _fixtures,
         blueprint,
         case_definition,
         _created_at
       ) do
    configuration_error("Approved batch assembly type is unsupported", %{
      "batch_id" => blueprint["id"],
      "case_id" => case_definition.id
    })
  end

  defp local_sample(control_sample, case_definition, output_text, origin, created_at) do
    control_response = control_sample["response"] || %{}

    response_attributes = %{
      "provider" => control_response["provider"],
      "requested_model" => control_response["requested_model"],
      "returned_model" => control_response["returned_model"],
      "output_text" => output_text,
      "request_id" =>
        local_request_id(origin, case_definition.id, control_sample["sample_index"]),
      "usage" => %{"input_tokens" => 0, "output_tokens" => 0},
      "latency_ms" => 0,
      "finish_reason" => "completed",
      "captured_at" => DateTime.to_iso8601(created_at),
      "raw" => %{
        "local_fixture_comparison" => true,
        "origin" => origin
      },
      "attempts" => 1
    }

    case Response.from_map(response_attributes) do
      {:ok, response} ->
        {:ok,
         %{
           "case_id" => case_definition.id,
           "case_fingerprint" => case_definition.fingerprint,
           "sample_index" => control_sample["sample_index"],
           "status" => "ok",
           "attempts" => 0,
           "origin" => origin,
           "response" => Response.to_map(response)
         }}

      {:error, reason} ->
        configuration_error("Local fixture response is invalid", %{
          "case_id" => case_definition.id,
          "reason" => inspect(reason),
          "sample_index" => control_sample["sample_index"]
        })
    end
  end

  defp fixture_origin(fixture, control, control_sample, blueprint) do
    %{
      "type" => "approved_fixture",
      "batch_id" => blueprint["id"],
      "fixture_id" => fixture["id"],
      "fixture_condition" => fixture["condition"],
      "variant_type" => fixture["variant_type"],
      "intended_label" => fixture["intended_label"],
      "severity" => fixture["severity"],
      "failure_modes" => fixture["failure_modes"],
      "expected_deterministic_pass" => fixture["expected_deterministic_pass"],
      "source_control_run_id" => control.run_id,
      "source_control_sample_index" => control_sample["sample_index"],
      "source_control_request_id" => get_in(control_sample, ["response", "request_id"])
    }
  end

  defp control_origin(control, control_sample, blueprint) do
    %{
      "type" => "heldout_control",
      "batch_id" => blueprint["id"],
      "fixture_id" => nil,
      "intended_label" => "acceptable",
      "failure_modes" => [],
      "source_control_run_id" => control.run_id,
      "source_control_sample_index" => control_sample["sample_index"],
      "source_control_request_id" => get_in(control_sample, ["response", "request_id"])
    }
  end

  defp local_request_id(origin, case_id, sample_index) do
    fixture_id = origin["fixture_id"] || "control"
    "local-fixture/#{origin["batch_id"]}/#{case_id}/#{sample_index}/#{fixture_id}"
  end

  defp candidate_totals(samples, metrics) do
    success_totals = RunAnalysis.success_totals(samples)
    completion = metrics["overall"]["completion"]
    quality = metrics["overall"]["quality"]

    %{
      "planned_samples" => length(samples),
      "planned_calls" => 0,
      "maximum_calls" => 0,
      "actual_calls" => 0,
      "availability_calls" => 0,
      "generation_calls" => 0,
      "successful_samples" => length(samples),
      "failed_samples" => 0,
      "completed_samples" => completion["completed_samples"],
      "incomplete_samples" => completion["incomplete_samples"],
      "unknown_completion_samples" => completion["unknown_samples"],
      "quality_passed_samples" => quality["passed_samples"],
      "quality_failed_samples" => quality["failed_samples"],
      "latency_ms" => success_totals["latency_ms"],
      "input_tokens" => success_totals["input_tokens"],
      "output_tokens" => success_totals["output_tokens"],
      "returned_models" => success_totals["returned_models"],
      "approved_fixture_samples" =>
        Enum.count(samples, &(get_in(&1, ["origin", "type"]) == "approved_fixture")),
      "heldout_control_samples" =>
        Enum.count(samples, &(get_in(&1, ["origin", "type"]) == "heldout_control")),
      "seeded_regression_samples" =>
        Enum.count(samples, &(get_in(&1, ["origin", "intended_label"]) == "regression"))
    }
  end

  defp build_reference_result(comparison, deterministic_threshold) do
    by_case = augment_case_results(comparison["by_case"], deterministic_threshold, nil)

    %{
      "batch_id" => "heldout_control",
      "condition" => "control",
      "intended_label" => "acceptable",
      "candidate_run_id" => comparison["candidate_run_id"],
      "comparison" =>
        comparison
        |> Map.put("by_case", by_case)
        |> Map.put("summary", outcome_summary(by_case))
    }
  end

  defp build_batch_result(
         blueprint,
         candidate,
         comparison,
         deterministic_threshold,
         batch_seed
       ) do
    by_case = augment_case_results(comparison["by_case"], deterministic_threshold, candidate)

    %{
      "batch_id" => blueprint["id"],
      "label" => candidate.label,
      "condition" => blueprint["condition"],
      "intended_label" => blueprint["intended_label"],
      "expected_regression_rate" => blueprint["expected_regression_rate"],
      "sample_size" => blueprint["sample_size"],
      "rationale" => blueprint["rationale"],
      "assembly" => blueprint["assembly"],
      "comparison_seed" => batch_seed,
      "candidate_run" => Run.to_map(candidate),
      "comparison" =>
        comparison
        |> Map.put("by_case", by_case)
        |> Map.put("summary", outcome_summary(by_case))
    }
  end

  defp augment_case_results(results, deterministic_threshold, candidate) do
    Enum.map(results, fn result ->
      deterministic_outcome =
        AlertOutcome.deterministic(result["deterministic"], deterministic_threshold)

      drift_outcome = result["outcome"]
      alert_outcome = AlertOutcome.combine(deterministic_outcome, drift_outcome)

      result
      |> Map.put("deterministic_drop_threshold", deterministic_threshold)
      |> Map.put("deterministic_outcome", deterministic_outcome)
      |> Map.put("drift_outcome", drift_outcome)
      |> Map.put("alert_outcome", alert_outcome)
      |> Map.put("seeded_samples", seeded_sample_summary(candidate, result["case_id"]))
    end)
  end

  defp seeded_sample_summary(nil, _case_id), do: nil

  defp seeded_sample_summary(candidate, case_id) do
    samples = Enum.filter(candidate.samples, &(&1["case_id"] == case_id))
    seeded = Enum.count(samples, &(get_in(&1, ["origin", "intended_label"]) == "regression"))

    semantic_only =
      Enum.count(samples, fn sample ->
        get_in(sample, ["origin", "intended_label"]) == "regression" and
          get_in(sample, ["origin", "expected_deterministic_pass"]) == true
      end)

    %{
      "total_samples" => length(samples),
      "seeded_regression_samples" => seeded,
      "seeded_regression_rate" => ratio(seeded, length(samples)),
      "semantic_only_regression_samples" => semantic_only
    }
  end

  defp outcome_summary(by_case) do
    %{
      "case_count" => length(by_case),
      "deterministic_regression_count" =>
        Enum.count(by_case, &(&1["deterministic_outcome"] == "deterministic_regression")),
      "drift_review_count" => Enum.count(by_case, &(&1["drift_outcome"] == "drift_review")),
      "alert_outcome_counts" => Enum.frequencies_by(by_case, & &1["alert_outcome"])
    }
  end

  defp build_report(
         baseline,
         calibration,
         control,
         fixture_set,
         comparison_id,
         created_at,
         git_revision,
         seed,
         permutations,
         deterministic_threshold,
         reference,
         batches
       ) do
    %{
      "schema_version" => @schema_version,
      "artifact_type" => @artifact_type,
      "comparison_id" => comparison_id,
      "created_at" => DateTime.to_iso8601(created_at),
      "git_revision" => git_revision,
      "baseline_run_id" => baseline.run_id,
      "calibration_id" => calibration.calibration_id,
      "control_run_id" => control.run_id,
      "provider" => baseline.provider,
      "requested_model" => baseline.request_config["model"],
      "provider_calls" => 0,
      "fixture_set" => fixture_set_summary(fixture_set),
      "settings" => %{
        "seed" => seed,
        "permutations" => permutations,
        "deterministic_drop_threshold" => deterministic_threshold
      },
      "reference_control" => reference,
      "batches" => batches,
      "summary" => report_summary(reference, batches)
    }
  end

  defp fixture_set_summary(fixture_set) do
    manifest = fixture_set["manifest"]

    %{
      "status" => manifest["status"],
      "approval_record" => manifest["approval_record"],
      "manifest_path" => Path.relative_to_cwd(fixture_set["manifest_path"]),
      "manifest_sha256" => fixture_set["manifest_sha256"],
      "file_sha256s" => fixture_set["file_sha256s"],
      "fixture_count" => length(fixture_set["fixtures"]),
      "batch_count" => length(manifest["batch_blueprints"]),
      "known_limitations" => manifest["known_limitations"]
    }
  end

  defp report_summary(reference, batches) do
    batch_case_results = all_batch_case_results(batches)

    acceptable_results =
      batches
      |> Enum.filter(&(&1["intended_label"] == "acceptable"))
      |> all_batch_case_results()

    regression_results =
      batches
      |> Enum.filter(&(&1["intended_label"] == "regression"))
      |> all_batch_case_results()

    %{
      "batch_count" => length(batches),
      "case_comparison_count" => length(batch_case_results),
      "alert_outcome_counts" => Enum.frequencies_by(batch_case_results, & &1["alert_outcome"]),
      "harmless_rewording" => %{
        "case_comparisons" => length(acceptable_results),
        "drift_review_count" =>
          Enum.count(acceptable_results, &(&1["drift_outcome"] == "drift_review")),
        "drift_review_rate" =>
          ratio(
            Enum.count(acceptable_results, &(&1["drift_outcome"] == "drift_review")),
            length(acceptable_results)
          )
      },
      "seeded_regressions" => %{
        "case_comparisons" => length(regression_results),
        "deterministic_regression_count" =>
          Enum.count(
            regression_results,
            &(&1["deterministic_outcome"] == "deterministic_regression")
          ),
        "drift_review_count" =>
          Enum.count(regression_results, &(&1["drift_outcome"] == "drift_review")),
        "any_signal_count" =>
          Enum.count(
            regression_results,
            &(&1["alert_outcome"] in ["deterministic_regression", "drift_review"])
          ),
        "any_signal_rate" =>
          ratio(
            Enum.count(
              regression_results,
              &(&1["alert_outcome"] in ["deterministic_regression", "drift_review"])
            ),
            length(regression_results)
          )
      },
      "mixed_sensitivity" => mixed_sensitivity(batches),
      "decision_gate" => decision_gate(reference, batches)
    }
  end

  defp mixed_sensitivity(batches) do
    batches
    |> Enum.filter(&(&1["condition"] == "mixed_regression"))
    |> Enum.map(fn batch ->
      results = batch["comparison"]["by_case"]

      %{
        "batch_id" => batch["batch_id"],
        "expected_regression_rate" => batch["expected_regression_rate"],
        "case_comparisons" => length(results),
        "deterministic_regression_count" =>
          Enum.count(results, &(&1["deterministic_outcome"] == "deterministic_regression")),
        "drift_review_count" => Enum.count(results, &(&1["drift_outcome"] == "drift_review")),
        "any_signal_count" =>
          Enum.count(
            results,
            &(&1["alert_outcome"] in ["deterministic_regression", "drift_review"])
          ),
        "by_case" =>
          Enum.map(results, fn result ->
            %{
              "case_id" => result["case_id"],
              "seeded_regression_rate" => result["seeded_samples"]["seeded_regression_rate"],
              "deterministic_outcome" => result["deterministic_outcome"],
              "drift_outcome" => result["drift_outcome"],
              "alert_outcome" => result["alert_outcome"]
            }
          end)
      }
    end)
  end

  defp decision_gate(reference, batches) do
    subtle = Enum.find(batches, &(&1["batch_id"] == "subtle_regression"))
    harmless = Enum.filter(batches, &(&1["intended_label"] == "acceptable"))
    case_ids = Enum.map(subtle["comparison"]["by_case"], & &1["case_id"])

    by_case =
      Enum.map(case_ids, fn case_id ->
        subtle_result = find_case_result(subtle, case_id)

        reference_results =
          [
            find_case_result(reference, case_id)
            | Enum.map(harmless, &find_case_result(&1, case_id))
          ]

        reference_alerts =
          Enum.filter(reference_results, &(&1["drift_outcome"] == "drift_review"))

        %{
          "case_id" => case_id,
          "subtle_regression_drift_outcome" => subtle_result["drift_outcome"],
          "reference_drift_review_count" => length(reference_alerts),
          "separated" =>
            subtle_result["drift_outcome"] == "drift_review" and reference_alerts == []
        }
      end)

    open_synthesis = Enum.find(by_case, &(&1["case_id"] == "rag_open_synthesis"))
    passed? = open_synthesis && open_synthesis["separated"]

    %{
      "required_case_id" => "rag_open_synthesis",
      "status" => if(passed?, do: "pass", else: "needs_semantic_layer"),
      "reason" =>
        if(
          passed?,
          do:
            "Jaccard separated the subtle open-synthesis batch from the held-out control and approved harmless rewordings.",
          else:
            "Jaccard did not cleanly separate the subtle open-synthesis batch from every control/rewording reference."
        ),
      "separated_case_ids" =>
        by_case |> Enum.filter(& &1["separated"]) |> Enum.map(& &1["case_id"]),
      "by_case" => by_case
    }
  end

  defp find_case_result(%{"comparison" => %{"by_case" => results}}, case_id) do
    Enum.find(results, &(&1["case_id"] == case_id))
  end

  defp all_batch_case_results(batches) do
    Enum.flat_map(batches, &get_in(&1, ["comparison", "by_case"]))
  end

  defp valid_batch?(batch) when is_map(batch) do
    non_empty_string?(batch["batch_id"]) and non_empty_string?(batch["condition"]) and
      batch["intended_label"] in ["acceptable", "regression"] and
      is_map(batch["candidate_run"]) and is_map(batch["comparison"]) and
      is_list(get_in(batch, ["candidate_run", "samples"])) and
      is_list(get_in(batch, ["comparison", "by_case"]))
  end

  defp valid_batch?(_batch), do: false

  defp valid_alert_outcomes?(batches) do
    batches
    |> Enum.flat_map(&get_in(&1, ["comparison", "by_case"]))
    |> Enum.all?(&(&1["alert_outcome"] in AlertOutcome.outcomes()))
  end

  defp required_integer(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> configuration_error("#{name} must be an integer")
      :error -> configuration_error("#{name} is required")
    end
  end

  defp positive_integer(options, name, default) do
    value = Keyword.get(options, name, default)

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: configuration_error("#{name} must be a positive integer")
  end

  defp deterministic_threshold(options) do
    value =
      Keyword.get(
        options,
        :deterministic_drop_threshold,
        @default_deterministic_drop_threshold
      )

    if is_number(value) and value >= 0 and value <= 1,
      do: {:ok, value * 1.0},
      else: configuration_error("deterministic_drop_threshold must be between zero and one")
  end

  defp timestamp(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)

    case clock.() do
      %DateTime{} = value -> {:ok, value}
      _value -> configuration_error("Fixture comparison clock must return a DateTime")
    end
  rescue
    exception ->
      configuration_error("Fixture comparison clock raised", %{
        "exception" => inspect(exception.__struct__)
      })
  end

  defp comparison_id(options, timestamp) do
    value =
      Keyword.get_lazy(options, :comparison_id, fn ->
        formatted = Calendar.strftime(timestamp, "%Y%m%dT%H%M%SZ")
        suffix = System.unique_integer([:positive, :monotonic])
        "fixture-comparison-#{formatted}-#{suffix}"
      end)

    if non_empty_string?(value),
      do: {:ok, value},
      else: configuration_error("Fixture comparison ID must be a non-empty string")
  end

  defp git_revision(options) do
    value = Keyword.get_lazy(options, :git_revision, &current_git_revision/0)

    if is_nil(value) or non_empty_string?(value),
      do: {:ok, value},
      else: configuration_error("Fixture comparison git revision is invalid")
  end

  defp current_git_revision do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} ->
        case String.trim(revision) do
          "" -> nil
          value -> value
        end

      {_output, _status} ->
        nil
    end
  rescue
    _error -> nil
  end

  defp add_batch_context(error, batch_id) when is_map(error) do
    details = Map.get(error, "details", %{}) |> Map.put("batch_id", batch_id)
    Map.put(error, "details", details)
  end

  defp add_batch_context(error, _batch_id), do: error

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result({:error, error}), do: {:error, error}

  defp ratio(_numerator, 0), do: nil
  defp ratio(numerator, denominator), do: numerator / denominator
  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp invalid_report(reason) do
    {:error,
     Provider.error(:invalid_fixture_comparison, "Fixture comparison report is invalid",
       details: %{"reason" => reason}
     )}
  end

  defp configuration_error(message, details \\ %{}) do
    {:error, Provider.error(:configuration_error, message, details: details)}
  end
end
