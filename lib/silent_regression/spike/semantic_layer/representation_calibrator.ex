defmodule SilentRegression.Spike.SemanticLayer.RepresentationCalibrator do
  @moduledoc """
  Fits one local representation and builds its immutable null calibration.

  Callers provide run structs together with exact artifact hashes. Fixture
  data is not accepted by this boundary.
  """

  alias SilentRegression.Spike.Comparison
  alias SilentRegression.Spike.Run
  alias SilentRegression.Spike.SemanticLayer.Calibration
  alias SilentRegression.Spike.SemanticLayer.Representation
  alias SilentRegression.Spike.SemanticLayer.RepresentationSpec
  alias SilentRegression.Spike.SemanticLayer.Storage
  alias SilentRegression.Spike.Statistics

  @allowed_options [
    :adjusted_p_alpha,
    :calibration_id,
    :case_id,
    :clock,
    :excluded_run_ids,
    :git_revision,
    :iterations,
    :quantile,
    :representation_id,
    :seed
  ]

  @type source :: %{required(:run) => Run.t(), required(:artifact_sha256) => String.t()}
  @type bundle :: %{
          required(:spec) => RepresentationSpec.t(),
          required(:spec_sha256) => String.t(),
          required(:model) => struct(),
          required(:calibration) => Calibration.t(),
          required(:calibration_sha256) => String.t()
        }

  @spec build(module(), source(), [source()], keyword()) ::
          {:ok, bundle()} | {:error, map()}
  def build(module, baseline_source, control_sources, options \\ [])

  def build(module, %{run: %Run{} = baseline} = baseline_source, control_sources, options)
      when is_list(control_sources) and is_list(options) do
    controls = Enum.map(control_sources, &Map.get(&1, :run))

    with :ok <- validate_options(options),
         :ok <- validate_method(module),
         :ok <- validate_sources(baseline_source, control_sources),
         :ok <- validate_runs(baseline, controls),
         :ok <- reject_excluded_runs(baseline, controls, options),
         {:ok, case_id} <- case_id(baseline, options),
         {:ok, created_at} <- timestamp(options),
         {:ok, git_revision} <- git_revision(options),
         {:ok, spec} <-
           build_spec(
             module,
             baseline_source,
             control_sources,
             case_id,
             created_at,
             git_revision,
             options
           ),
         {:ok, spec_sha256} <- Storage.sha256(spec),
         {:ok, model} <- fit_model(module, baseline, controls, case_id),
         {:ok, calibration} <-
           build_calibration(
             spec,
             spec_sha256,
             model,
             baseline_source,
             control_sources,
             case_id,
             created_at,
             git_revision,
             options
           ),
         {:ok, calibration_sha256} <- Storage.sha256(calibration) do
      {:ok,
       %{
         spec: spec,
         spec_sha256: spec_sha256,
         model: model,
         calibration: calibration,
         calibration_sha256: calibration_sha256
       }}
    end
  end

  def build(_module, _baseline_source, _control_sources, _options),
    do: error(:invalid_calibration_input)

  defp validate_options(options) do
    keys = Keyword.keys(options)

    cond do
      not Keyword.keyword?(options) ->
        error(:options_must_be_a_keyword_list)

      Enum.uniq(keys) != keys ->
        error(:options_must_be_unique)

      keys -- @allowed_options != [] ->
        error(:unsupported_options, options: keys -- @allowed_options)

      true ->
        :ok
    end
  end

  defp validate_method(module) do
    if module in Representation.methods(), do: :ok, else: error(:unsupported_representation)
  end

  defp validate_sources(baseline_source, control_sources) do
    sources = [baseline_source | control_sources]

    cond do
      control_sources == [] ->
        error(:at_least_one_control_required)

      not Enum.all?(sources, &valid_source?/1) ->
        error(:invalid_source_reference)

      Map.get(baseline_source, :run).condition != "baseline" ->
        error(:baseline_source_required)

      not Enum.all?(control_sources, &(Map.get(&1, :run).condition == "control")) ->
        error(:control_sources_required)

      sources |> Enum.map(&Map.get(&1, :run).run_id) |> Enum.uniq() |> length() !=
          length(sources) ->
        error(:source_run_ids_must_be_unique)

      true ->
        :ok
    end
  end

  defp valid_source?(%{run: %Run{}, artifact_sha256: sha256}), do: sha256?(sha256)
  defp valid_source?(_source), do: false

  defp validate_runs(baseline, controls) do
    Enum.reduce_while(controls, :ok, fn control, :ok ->
      case Comparison.validate_runs(baseline, control) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp reject_excluded_runs(baseline, controls, options) do
    excluded = Keyword.get(options, :excluded_run_ids, [])

    cond do
      not (is_list(excluded) and Enum.all?(excluded, &is_binary/1)) ->
        error(:excluded_run_ids_must_be_strings)

      Enum.any?([baseline | controls], &(&1.run_id in excluded)) ->
        error(:reserved_run_cannot_be_a_fit_source)

      true ->
        :ok
    end
  end

  defp case_id(baseline, options) do
    case_id = Keyword.get(options, :case_id)

    if is_binary(case_id) and Enum.any?(baseline.cases, &(&1.id == case_id)),
      do: {:ok, case_id},
      else: error(:case_id_must_reference_baseline)
  end

  defp timestamp(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)

    case clock.() do
      %DateTime{} = timestamp -> {:ok, timestamp}
      _value -> error(:clock_must_return_datetime)
    end
  rescue
    exception -> error(:clock_raised, exception: inspect(exception.__struct__))
  end

  defp git_revision(options) do
    value = Keyword.get(options, :git_revision)

    if is_nil(value) or (is_binary(value) and String.trim(value) != ""),
      do: {:ok, value},
      else: error(:git_revision_must_be_a_string)
  end

  defp build_spec(
         module,
         baseline_source,
         control_sources,
         case_id,
         created_at,
         git_revision,
         options
       ) do
    method = Representation.metadata(module)

    RepresentationSpec.new(%{
      representation_id:
        Keyword.get(options, :representation_id, default_id("semantic-representation", method)),
      created_at: created_at,
      git_revision: git_revision,
      method: method,
      case_ids: [case_id],
      fit_sources: Enum.map([baseline_source | control_sources], &source_reference/1),
      fit_observation_ids:
        Enum.flat_map([baseline_source | control_sources], &observation_ids(&1.run, case_id)),
      fit_policy: %{
        "version" => 1,
        "fixture_labels_used" => false,
        "allowed_conditions" => ~w(baseline control)
      }
    })
  end

  defp fit_model(module, baseline, controls, case_id) do
    documents =
      Enum.flat_map([baseline | controls], &Comparison.completed_outputs(&1, case_id))

    Representation.fit(module, documents)
  end

  defp build_calibration(
         spec,
         spec_sha256,
         model,
         baseline_source,
         control_sources,
         case_id,
         created_at,
         git_revision,
         options
       ) do
    baseline = baseline_source.run
    controls = Enum.map(control_sources, & &1.run)
    seed = Keyword.get(options, :seed, 20_260_907)
    iterations = Keyword.get(options, :iterations, 2_000)
    quantile = Keyword.get(options, :quantile, 0.95)
    adjusted_p_alpha = Keyword.get(options, :adjusted_p_alpha, 0.05)
    baseline_size = Comparison.completed_outputs(baseline, case_id) |> length()
    control_sizes = Enum.map(controls, &(Comparison.completed_outputs(&1, case_id) |> length()))

    with :ok <- validate_calibration_settings(seed, iterations, quantile, adjusted_p_alpha),
         {:ok, control_size} <- common_control_size(control_sizes),
         {:ok, threshold} <-
           calibrate_threshold(
             model,
             baseline,
             controls,
             case_id,
             seed,
             iterations,
             quantile,
             baseline_size,
             control_size
           ) do
      method = spec.method

      Calibration.new(%{
        calibration_id:
          Keyword.get(options, :calibration_id, default_id("semantic-calibration", method)),
        created_at: created_at,
        git_revision: git_revision,
        status: "frozen",
        representation: %{
          "representation_id" => spec.representation_id,
          "artifact_sha256" => spec_sha256,
          "method_name" => method["name"],
          "method_version" => method["version"],
          "parameters_sha256" => deterministic_sha256(method["parameters"])
        },
        case_ids: [case_id],
        source_runs: Enum.map([baseline_source | control_sources], &source_reference/1),
        settings: %{
          "seed" => seed,
          "iterations" => iterations,
          "quantile" => quantile * 1.0,
          "adjusted_p_alpha" => adjusted_p_alpha * 1.0,
          "baseline_group_size" => baseline_size,
          "control_group_size" => control_size
        },
        thresholds: [threshold]
      })
    end
  end

  defp validate_calibration_settings(seed, iterations, quantile, alpha) do
    if is_integer(seed) and seed >= 0 and is_integer(iterations) and iterations > 0 and
         probability?(quantile) and quantile > 0 and quantile < 1 and probability?(alpha) and
         alpha > 0 and alpha < 1,
       do: :ok,
       else: error(:invalid_calibration_settings)
  end

  defp common_control_size([size | rest])
       when is_integer(size) and size >= 2 do
    if Enum.all?(rest, &(&1 == size)),
      do: {:ok, size},
      else: error(:control_sample_sizes_must_match)
  end

  defp common_control_size(_sizes), do: error(:controls_require_two_complete_samples)

  defp calibrate_threshold(
         model,
         baseline,
         controls,
         case_id,
         seed,
         iterations,
         quantile,
         baseline_size,
         control_size
       ) do
    batches =
      Enum.map([baseline | controls], fn run ->
        %{
          "condition" => run.condition,
          "samples" => Comparison.completed_outputs(run, case_id)
        }
      end)

    options =
      Representation.statistics_options(model) ++
        [
          seed: seed,
          iterations: iterations,
          quantile: quantile,
          reference_size: baseline_size,
          candidate_size: control_size
        ]

    case Statistics.calibrate_threshold(batches, options) do
      {:ok, result} ->
        null_energies = result["null_energies"]
        exceedances = Enum.count(null_energies, &(&1 > result["threshold"]))

        {:ok,
         %{
           "case_id" => case_id,
           "threshold" => result["threshold"],
           "null_energies" => null_energies,
           "iterations" => iterations,
           "baseline_size" => baseline_size,
           "control_size" => control_size,
           "empirical_exceedance_rate" => exceedances / iterations
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp observation_ids(run, case_id) do
    run.samples
    |> Enum.filter(fn sample ->
      sample["case_id"] == case_id and sample["status"] == "ok" and
        get_in(sample, ["completion", "passed"]) == true
    end)
    |> Enum.sort_by(& &1["sample_index"])
    |> Enum.map(&"#{run.run_id}:#{case_id}:#{&1["sample_index"]}")
  end

  defp source_reference(source) do
    %{
      "run_id" => source.run.run_id,
      "condition" => source.run.condition,
      "artifact_sha256" => source.artifact_sha256
    }
  end

  defp default_id(prefix, method) do
    method_name = String.replace(method["name"], "_", "-")
    "#{prefix}-#{method_name}-v#{method["version"]}"
  end

  defp deterministic_sha256(value) do
    encoded = :erlang.term_to_binary(value, [:deterministic])
    :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  end

  defp sha256?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1
  defp error(reason, details \\ []), do: {:error, Map.new([{:type, reason} | details])}
end
