defmodule SilentRegression.RunResults.IncidentOccurrence do
  @moduledoc """
  Immutable link from one incident episode to exact per-run alert evidence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SilentRegression.Captures.CaptureRun
  alias SilentRegression.RunResults.{Alert, Incident}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "result_incident_occurrences" do
    field :ordinal, :integer
    field :occurred_at, :utc_datetime_usec
    field :case_fingerprints, {:array, :string}, default: []
    field :exceptional_reference, :boolean, default: false

    belongs_to :incident, Incident, foreign_key: :result_incident_id
    belongs_to :alert, Alert, foreign_key: :result_alert_id
    belongs_to :capture_run, CaptureRun

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(occurrence, incident, alert, run, attrs) do
    occurrence
    |> cast(attrs, [:ordinal, :occurred_at, :case_fingerprints, :exceptional_reference])
    |> change(
      result_incident_id: incident.id,
      result_alert_id: alert.id,
      capture_run_id: run.id
    )
    |> validate_required([
      :ordinal,
      :occurred_at,
      :case_fingerprints,
      :exceptional_reference,
      :result_incident_id,
      :result_alert_id,
      :capture_run_id
    ])
    |> validate_number(:ordinal, greater_than: 0)
    |> foreign_key_constraint(:result_incident_id)
    |> foreign_key_constraint(:result_alert_id)
    |> foreign_key_constraint(:capture_run_id)
    |> unique_constraint(:result_alert_id)
    |> unique_constraint([:result_incident_id, :ordinal])
    |> unique_constraint([:result_incident_id, :capture_run_id],
      name: :incident_occurrences_incident_run_index
    )
    |> check_constraint(:ordinal, name: :result_incident_occurrences_ordinal_check)
  end
end
