defmodule SilentRegression.Monitors.Provenance do
  @moduledoc """
  Exact configuration identity used to guard later baseline and run comparisons.

  Compatibility is deliberately strict: two observations may be compared only
  when they belong to the same monitor and retain the same executable fingerprint,
  provider/model pair, and case membership. Version IDs remain evidence, but a
  metadata-only successor does not invalidate an otherwise compatible baseline.
  """

  alias SilentRegression.Monitors.{CaseVersion, MonitorVersion}

  @enforce_keys [
    :schema_version,
    :monitor_id,
    :monitor_version_id,
    :monitor_version_fingerprint,
    :provider,
    :requested_model,
    :case_fingerprints
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          monitor_id: Ecto.UUID.t(),
          monitor_version_id: Ecto.UUID.t(),
          monitor_version_fingerprint: String.t(),
          provider: :openai | :anthropic,
          requested_model: String.t(),
          case_fingerprints: %{String.t() => String.t()}
        }

  def from_version(%MonitorVersion{cases: cases} = version) when is_list(cases) do
    case_fingerprints =
      Map.new(cases, fn %CaseVersion{} = case_version ->
        {case_version.case_key, case_version.fingerprint}
      end)

    %__MODULE__{
      schema_version: version.schema_version,
      monitor_id: version.monitor_id,
      monitor_version_id: version.id,
      monitor_version_fingerprint: version.fingerprint,
      provider: version.provider,
      requested_model: version.requested_model,
      case_fingerprints: case_fingerprints
    }
  end

  def from_version(%MonitorVersion{}) do
    raise ArgumentError, "monitor version cases must be preloaded before deriving provenance"
  end

  def ensure_compatible(%__MODULE__{} = reference, %__MODULE__{} = candidate) do
    mismatches =
      [
        :schema_version,
        :monitor_id,
        :monitor_version_fingerprint,
        :provider,
        :requested_model,
        :case_fingerprints
      ]
      |> Enum.reject(&(Map.fetch!(reference, &1) == Map.fetch!(candidate, &1)))

    case mismatches do
      [] -> :ok
      mismatches -> {:error, %{reason: :incompatible_provenance, mismatches: mismatches}}
    end
  end
end
