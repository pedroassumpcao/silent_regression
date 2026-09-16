defmodule SilentRegression.MonitorOperations.Schedule do
  @moduledoc false

  @seconds %{daily: 86_400, weekly: 604_800}

  def cast(value) when value in [:manual, "manual"], do: {:ok, :manual}
  def cast(value) when value in [:daily, "daily"], do: {:ok, :daily}
  def cast(value) when value in [:weekly, "weekly"], do: {:ok, :weekly}
  def cast(_value), do: {:error, :invalid_cadence}

  def first_run_at(:manual, _now), do: nil

  def first_run_at(cadence, %DateTime{} = now) when cadence in [:daily, :weekly] do
    DateTime.add(now, Map.fetch!(@seconds, cadence), :second)
  end

  def advance(:manual, _intended_at, _now), do: nil

  def advance(cadence, %DateTime{} = intended_at, %DateTime{} = now)
      when cadence in [:daily, :weekly] do
    seconds = Map.fetch!(@seconds, cadence)
    elapsed = max(DateTime.diff(now, intended_at, :second), 0)
    intervals = div(elapsed, seconds) + 1
    DateTime.add(intended_at, intervals * seconds, :second)
  end

  def identity(monitor_id, %DateTime{} = intended_at) do
    "scheduled:#{monitor_id}:#{DateTime.to_iso8601(intended_at)}"
  end
end
