defmodule SilentRegression.MonitorOperations.ScheduleTest do
  use ExUnit.Case, async: true

  alias SilentRegression.MonitorOperations.Schedule

  test "casts only the deliberately small cadence set" do
    assert {:ok, :manual} = Schedule.cast("manual")
    assert {:ok, :daily} = Schedule.cast(:daily)
    assert {:ok, :weekly} = Schedule.cast("weekly")
    assert {:error, :invalid_cadence} = Schedule.cast("hourly")
  end

  test "anchors the first daily and weekly executions from an explicit time" do
    now = ~U[2026-09-16 15:00:00.123456Z]

    assert Schedule.first_run_at(:manual, now) == nil
    assert Schedule.first_run_at(:daily, now) == ~U[2026-09-17 15:00:00.123456Z]
    assert Schedule.first_run_at(:weekly, now) == ~U[2026-09-23 15:00:00.123456Z]
  end

  test "advances a delayed schedule to the first future slot without catch-up" do
    intended_at = ~U[2026-09-10 12:00:00Z]

    assert Schedule.advance(:daily, intended_at, ~U[2026-09-10 12:01:00Z]) ==
             ~U[2026-09-11 12:00:00Z]

    assert Schedule.advance(:daily, intended_at, ~U[2026-09-13 13:00:00Z]) ==
             ~U[2026-09-14 12:00:00Z]

    assert Schedule.advance(:weekly, intended_at, ~U[2026-09-25 12:00:00Z]) ==
             ~U[2026-10-01 12:00:00Z]
  end

  test "creates a stable scheduled-run identity for an intended slot" do
    assert Schedule.identity("monitor-id", ~U[2026-09-16 15:00:00Z]) ==
             "scheduled:monitor-id:2026-09-16T15:00:00Z"
  end
end
