defmodule SilentRegression.Spike.SemanticLayer.CheapBenchmarkFreeze do
  @moduledoc """
  Loads and validates the tracked pre-held-out Task D freeze manifest.

  The manifest pins the tuning result, selected method, threshold, seeds, and
  held-out fixture hash before final labels are evaluated.
  """

  alias SilentRegression.Spike.SemanticLayer.CheapBenchmarkConfig

  @path "priv/drift_spike/semantic_layer/cheap-benchmark-freeze-v1.json"
  @top_level_keys ~w(schema_version artifact_type freeze_id frozen_at method_git_revision case_id tuning_result selected_representation calibration heldout_fixture_set settings selection_policy)

  @spec path() :: Path.t()
  def path, do: @path

  @spec load(Path.t()) :: {:ok, map()} | {:error, map()}
  def load(path \\ @path) do
    with {:ok, contents} <- File.read(path),
         {:ok, freeze} <- Jason.decode(contents),
         :ok <- validate(freeze) do
      {:ok, freeze}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, %{type: :invalid_freeze_json, path: path, reason: reason}}

      {:error, reason} when is_atom(reason) ->
        {:error, %{type: :freeze_read_failed, path: path, reason: reason}}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec validate(term()) :: :ok | {:error, map()}
  def validate(freeze) when is_map(freeze) do
    config = CheapBenchmarkConfig.settings()
    heldout = CheapBenchmarkConfig.heldout()

    cond do
      Map.keys(freeze) |> Enum.sort() != Enum.sort(@top_level_keys) ->
        error(:invalid_freeze_shape)

      freeze["schema_version"] != 1 or
          freeze["artifact_type"] != "semantic_benchmark_freeze" ->
        error(:unsupported_freeze_schema)

      not non_empty_strings?([
        freeze["freeze_id"],
        freeze["frozen_at"],
        freeze["method_git_revision"],
        freeze["case_id"]
      ]) ->
        error(:invalid_freeze_identity)

      freeze["case_id"] != CheapBenchmarkConfig.case_id() ->
        error(:case_id_mismatch)

      not valid_reference?(freeze["tuning_result"], ~w(result_id path artifact_sha256)) ->
        error(:invalid_tuning_reference)

      not valid_selected_representation?(freeze["selected_representation"]) ->
        error(:invalid_selected_representation)

      not valid_calibration?(freeze["calibration"]) ->
        error(:invalid_calibration_reference)

      freeze["heldout_fixture_set"] != %{
        "fixture_set_id" => heldout.fixture_set_id,
        "path" => heldout.path,
        "artifact_sha256" => heldout.artifact_sha256
      } ->
        error(:heldout_fixture_mismatch)

      freeze["settings"] != %{
        "seeds" => config.evaluation_seeds,
        "permutations" => config.permutations,
        "adjusted_p_alpha" => config.adjusted_p_alpha,
        "multiple_comparison_family" => config.multiple_comparison_family,
        "harmless_review_rate_maximum" => config.harmless_review_rate_maximum,
        "subtle_review_rate_minimum" => config.subtle_review_rate_minimum,
        "provider_calls" => 0
      } ->
        error(:settings_mismatch)

      not valid_selection_policy?(freeze["selection_policy"], freeze) ->
        error(:invalid_selection_policy)

      true ->
        :ok
    end
  end

  def validate(_freeze), do: error(:freeze_must_be_a_json_object)

  defp valid_reference?(reference, keys) do
    is_map(reference) and Map.keys(reference) |> Enum.sort() == Enum.sort(keys) and
      non_empty_strings?(Enum.map(keys -- ["artifact_sha256"], &reference[&1])) and
      sha256?(reference["artifact_sha256"])
  end

  defp valid_selected_representation?(representation) do
    keys =
      ~w(representation_id path artifact_sha256 method_name method_version parameters_sha256)

    is_map(representation) and Map.keys(representation) |> Enum.sort() == Enum.sort(keys) and
      non_empty_strings?([
        representation["representation_id"],
        representation["path"],
        representation["method_name"]
      ]) and sha256?(representation["artifact_sha256"]) and
      representation["method_name"] == "field_aware" and
      representation["method_version"] == 2 and sha256?(representation["parameters_sha256"])
  end

  defp valid_calibration?(calibration) do
    keys =
      ~w(calibration_id path artifact_sha256 threshold seed iterations quantile)

    is_map(calibration) and Map.keys(calibration) |> Enum.sort() == Enum.sort(keys) and
      non_empty_strings?([calibration["calibration_id"], calibration["path"]]) and
      sha256?(calibration["artifact_sha256"]) and is_number(calibration["threshold"]) and
      is_integer(calibration["seed"]) and calibration["seed"] >= 0 and
      is_integer(calibration["iterations"]) and calibration["iterations"] > 0 and
      is_number(calibration["quantile"]) and calibration["quantile"] > 0 and
      calibration["quantile"] < 1
  end

  defp valid_selection_policy?(policy, freeze) do
    policy == %{
      "version" => 1,
      "winner_rule" => "largest_separation_margin_then_predeclared_order",
      "selected_on_split" => "tuning",
      "selected_representation_ids" => [
        freeze["selected_representation"]["representation_id"]
      ],
      "heldout_labels_used" => false
    }
  end

  defp non_empty_strings?(values),
    do: Enum.all?(values, &(is_binary(&1) and String.trim(&1) != ""))

  defp sha256?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp error(reason), do: {:error, %{type: reason}}
end
