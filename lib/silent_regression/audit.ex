defmodule SilentRegression.Audit do
  @moduledoc """
  Records allowlisted operational events without prompts, outputs, credentials,
  bearer tokens, or other customer content.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit.AuditEvent
  alias SilentRegression.Repo

  def record_event(attrs) when is_map(attrs) do
    %AuditEvent{}
    |> AuditEvent.record_changeset(attrs)
    |> Repo.insert()
  end

  def record_event!(attrs) when is_map(attrs) do
    %AuditEvent{}
    |> AuditEvent.record_changeset(attrs)
    |> Repo.insert!()
  end

  def list_workspace_events(%Scope{workspace: %{id: workspace_id}}) do
    AuditEvent
    |> where([event], event.workspace_id == ^workspace_id)
    |> order_by([event], desc: event.occurred_at, desc: event.inserted_at)
    |> Repo.all()
  end

  def list_workspace_events(%Scope{}), do: {:error, :workspace_required}
end
