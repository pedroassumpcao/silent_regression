defmodule SilentRegression.RunResults.Provenance do
  @moduledoc false

  alias SilentRegression.Baselines.BaselineSnapshot
  alias SilentRegression.Captures.CaptureRun

  @fields [
    :workspace_id,
    :monitor_id,
    :monitor_version_id,
    :provider_credential_id,
    :provider,
    :requested_model,
    :monitor_fingerprint,
    :case_set_fingerprint,
    :contract_semantics_fingerprint,
    :evaluator_engine_version
  ]

  def compare(%CaptureRun{}, nil), do: %{compatible?: false, mismatches: [:baseline_missing]}

  def compare(%CaptureRun{} = run, %BaselineSnapshot{} = baseline) do
    mismatches = Enum.reject(@fields, &(Map.fetch!(run, &1) == Map.fetch!(baseline, &1)))

    %{
      compatible?: mismatches == [] and run.baseline_snapshot_id == baseline.id,
      mismatches:
        if(run.baseline_snapshot_id == baseline.id,
          do: mismatches,
          else: [:baseline_identity | mismatches]
        )
    }
  end
end
