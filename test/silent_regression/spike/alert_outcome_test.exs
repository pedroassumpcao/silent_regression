defmodule SilentRegression.Spike.AlertOutcomeTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.AlertOutcome

  test "exposes all four product alert outcomes with deterministic precedence" do
    assert AlertOutcome.combine("deterministic_regression", "drift_review") ==
             "deterministic_regression"

    assert AlertOutcome.combine("no_deterministic_regression", "drift_review") ==
             "drift_review"

    assert AlertOutcome.combine("no_deterministic_regression", "no_drift_review") ==
             "no_alert"

    assert AlertOutcome.combine("insufficient_data", "no_drift_review") ==
             "insufficient_data"

    assert Enum.sort(AlertOutcome.outcomes()) ==
             Enum.sort(~w(deterministic_regression drift_review no_alert insufficient_data))
  end

  test "uses a configurable strict deterministic pass-rate drop" do
    rate_change = %{"baseline_rate" => 1.0, "candidate_rate" => 0.9}

    assert AlertOutcome.deterministic(rate_change, 0.0) == "deterministic_regression"
    assert AlertOutcome.deterministic(rate_change, 0.1) == "no_deterministic_regression"
    assert AlertOutcome.deterministic(%{"baseline_rate" => nil}, 0.0) == "insufficient_data"
  end
end
