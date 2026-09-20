defmodule SilentRegression.Repo.Migrations.ExpandProductEventsForMonitorSuccessors do
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
  )

  @successor_names @existing_names ++
                     ~w(
                       monitor_successor.started
                       monitor_successor.activated
                     )

  def up do
    replace_name_constraint(@successor_names)
  end

  def down do
    replace_name_constraint(@existing_names)
  end

  defp replace_name_constraint(names) do
    drop constraint(:product_events, :product_events_name_check)

    create constraint(:product_events, :product_events_name_check,
             check: "name IN (#{quoted(names)})"
           )
  end

  defp quoted(names), do: Enum.map_join(names, ", ", &("'" <> &1 <> "'"))
end
