defmodule SilentRegression.Spike.AlertOutcome do
  @moduledoc """
  Combines deterministic and direction-neutral drift signals.

  Deterministic degradation takes precedence because it establishes quality
  direction. A drift-only signal requests review without claiming that quality
  became worse. Missing rates or an unavailable drift comparison produce an
  explicit insufficient-data outcome.
  """

  @outcomes ~w(deterministic_regression drift_review no_alert insufficient_data)

  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "Returns the deterministic outcome for one baseline/candidate rate change."
  @spec deterministic(map(), number()) :: String.t()
  def deterministic(rate_change, threshold \\ 0.0)

  def deterministic(%{"baseline_rate" => baseline, "candidate_rate" => candidate}, threshold)
      when is_number(baseline) and is_number(candidate) and is_number(threshold) and
             threshold >= 0 do
    if baseline - candidate > threshold,
      do: "deterministic_regression",
      else: "no_deterministic_regression"
  end

  def deterministic(_rate_change, _threshold), do: "insufficient_data"

  @doc "Combines already-separated deterministic and drift outcomes."
  @spec combine(String.t(), String.t()) :: String.t()
  def combine("insufficient_data", _drift_outcome), do: "insufficient_data"
  def combine(_deterministic_outcome, "insufficient_data"), do: "insufficient_data"

  def combine("deterministic_regression", _drift_outcome),
    do: "deterministic_regression"

  def combine("no_deterministic_regression", "drift_review"), do: "drift_review"
  def combine("no_deterministic_regression", "no_drift_review"), do: "no_alert"
  def combine(_deterministic_outcome, _drift_outcome), do: "insufficient_data"
end
