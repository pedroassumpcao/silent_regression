defmodule SilentRegression.ProductAnalytics do
  @moduledoc """
  Records a deliberately small, content-free product-learning event allowlist.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.ProductAnalytics.ProductEvent
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @property_allowlist %{
    "monitor_setup.started" => ["step"],
    "monitor_setup.step_completed" => ["step", "completed_count", "total_count"],
    "monitor_setup.left" => ["step", "completed_count", "total_count"],
    "monitor_setup.completed" => ["completed_count", "total_count"]
  }

  def record!(
        %Scope{
          workspace: %Workspace{} = workspace,
          membership: %Membership{},
          user: %User{} = user
        },
        name,
        monitor_id,
        properties
      )
      when is_binary(name) and is_map(properties) do
    :ok = validate_properties(name, properties)

    %ProductEvent{}
    |> ProductEvent.record_changeset(%{
      name: name,
      target_type: "monitor",
      target_id: monitor_id,
      properties: properties,
      occurred_at: DateTime.utc_now(:second),
      workspace_id: workspace.id,
      actor_user_id: user.id
    })
    |> Repo.insert!()
  end

  def list_events(%Scope{
        workspace: %Workspace{id: workspace_id},
        membership: %Membership{}
      }) do
    ProductEvent
    |> where([event], event.workspace_id == ^workspace_id)
    |> order_by([event], asc: event.occurred_at, asc: event.inserted_at)
    |> Repo.all()
  end

  def list_events(%Scope{}), do: {:error, :workspace_required}

  defp validate_properties(name, properties) do
    with {:ok, allowed_keys} <- Map.fetch(@property_allowlist, name),
         [] <- Map.keys(properties) -- allowed_keys,
         :ok <- validate_property_values(properties) do
      :ok
    else
      _reason -> raise ArgumentError, "invalid product event or properties"
    end
  end

  defp validate_property_values(properties) do
    valid? =
      Enum.all?(properties, fn
        {"step", value} ->
          value in ~w(purpose connection prompt cases review)

        {key, value} when key in ["completed_count", "total_count"] ->
          is_integer(value) and value >= 0 and value <= 5

        _property ->
          false
      end)

    if valid?, do: :ok, else: :error
  end
end
