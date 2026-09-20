defmodule SilentRegression.Repo.Migrations.ExpandProductEventsForGuidedDemo do
  use Ecto.Migration

  @existing_names ~w(
    monitor_setup.started
    monitor_setup.step_completed
    monitor_setup.left
    monitor_setup.completed
    baseline.approved
    schedule.activated
    review.recorded
    review.action_started
    founder.assistance_recorded
    monitor_successor.started
    monitor_successor.activated
  )

  @demo_names @existing_names ++
                ~w(
                  demo.started
                  demo.step_completed
                  demo.completed
                )

  def up do
    replace_constraints(@demo_names, true)
  end

  def down do
    replace_constraints(@existing_names, false)
  end

  defp replace_constraints(names, demo?) do
    drop constraint(:product_events, :product_events_name_check)
    drop constraint(:product_events, :product_events_target_check)

    create constraint(:product_events, :product_events_name_check,
             check: "name IN (#{quoted(names)})"
           )

    target_check =
      if demo? do
        "target_id IS NOT NULL AND target_type IN ('monitor', 'workspace') AND " <>
          "((name LIKE 'demo.%' AND target_type = 'workspace') OR " <>
          "(name = 'founder.assistance_recorded') OR " <>
          "(name NOT LIKE 'demo.%' AND target_type = 'monitor'))"
      else
        "target_type = 'monitor' AND target_id IS NOT NULL"
      end

    create constraint(:product_events, :product_events_target_check, check: target_check)
  end

  defp quoted(names), do: Enum.map_join(names, ", ", &("'" <> &1 <> "'"))
end
