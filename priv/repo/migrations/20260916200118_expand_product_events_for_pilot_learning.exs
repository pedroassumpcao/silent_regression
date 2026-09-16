defmodule SilentRegression.Repo.Migrations.ExpandProductEventsForPilotLearning do
  use Ecto.Migration

  @existing_names ~w(
    monitor_setup.started
    monitor_setup.step_completed
    monitor_setup.left
    monitor_setup.completed
  )

  @pilot_names @existing_names ++
                 ~w(
                   baseline.approved
                   schedule.activated
                   review.recorded
                   review.action_started
                   founder.assistance_recorded
                 )

  def up do
    drop constraint(:product_events, :product_events_name_check)

    create constraint(:product_events, :product_events_name_check,
             check: "name IN (#{quoted(@pilot_names)})"
           )

    create constraint(:product_events, :product_events_target_check,
             check: "target_type = 'monitor' AND target_id IS NOT NULL"
           )
  end

  def down do
    drop constraint(:product_events, :product_events_target_check)
    drop constraint(:product_events, :product_events_name_check)

    create constraint(:product_events, :product_events_name_check,
             check: "name IN (#{quoted(@existing_names)})"
           )
  end

  defp quoted(names), do: Enum.map_join(names, ", ", &("'" <> &1 <> "'"))
end
