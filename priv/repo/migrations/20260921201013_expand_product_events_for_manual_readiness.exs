defmodule SilentRegression.Repo.Migrations.ExpandProductEventsForManualReadiness do
  use Ecto.Migration

  @existing_names ~w(
    monitor_setup.started monitor_setup.step_completed monitor_setup.left monitor_setup.completed
    baseline.approved schedule.activated review.recorded review.action_started
    founder.assistance_recorded monitor_successor.started monitor_successor.activated
    demo.started demo.step_completed demo.completed
  )

  def up do
    replace_constraint(@existing_names ++ ["monitor.activated"], true)
  end

  def down do
    # Preserve append-only history on rollback while enforcing old names on new writes.
    replace_constraint(@existing_names, false)
  end

  defp replace_constraint(names, validate?) do
    drop constraint(:product_events, :product_events_name_check)

    create constraint(:product_events, :product_events_name_check,
             check: "name IN (#{Enum.map_join(names, ", ", &("'" <> &1 <> "'"))})",
             validate: validate?
           )
  end
end
