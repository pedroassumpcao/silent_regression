defmodule SilentRegression.ContractAuthoring.FixtureJudgment do
  @moduledoc false

  def expected_statuses(%{"id" => root_id, "type" => "all", "rules" => rules}, status, failed_ids)
      when is_list(rules) do
    with {:ok, status} <- cast_status(status),
         {:ok, failed_ids} <- normalize_failed_ids(failed_ids),
         child_ids <- Enum.map(rules, & &1["id"]),
         :ok <- validate_failed_ids(status, failed_ids, child_ids) do
      statuses =
        Map.new(child_ids, fn rule_id ->
          {rule_id, if(rule_id in failed_ids, do: "fail", else: "pass")}
        end)

      {:ok, status, Map.put(statuses, root_id, Atom.to_string(status))}
    end
  end

  def expected_statuses(_root, _status, _failed_ids),
    do: {:error, :expected_rule_statuses, "cannot be built for this contract"}

  def complete?(%{"id" => root_id, "rules" => rules}, statuses) when is_map(statuses) do
    expected_ids = [root_id | Enum.map(rules, & &1["id"])] |> Enum.sort()

    Enum.sort(Map.keys(statuses)) == expected_ids and
      Enum.all?(statuses, fn {_id, status} -> status in ~w(pass fail) end)
  end

  def complete?(_root, _statuses), do: false

  def failed_rule_ids(%{"id" => root_id}, statuses) when is_map(statuses) do
    statuses
    |> Enum.filter(fn {rule_id, status} -> rule_id != root_id and status == "fail" end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp cast_status(:pass), do: {:ok, :pass}
  defp cast_status(:fail), do: {:ok, :fail}
  defp cast_status("pass"), do: {:ok, :pass}
  defp cast_status("fail"), do: {:ok, :fail}
  defp cast_status(_status), do: {:error, :expected_status, "must be pass or fail"}

  defp normalize_failed_ids(nil), do: {:ok, []}

  defp normalize_failed_ids(ids) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1),
      do: {:ok, ids |> Enum.reject(&(&1 == "")) |> Enum.uniq()},
      else: {:error, :expected_rule_statuses, "contain an invalid rule ID"}
  end

  defp normalize_failed_ids(_ids),
    do: {:error, :expected_rule_statuses, "must be a list of rule IDs"}

  defp validate_failed_ids(status, failed_ids, child_ids) do
    cond do
      failed_ids -- child_ids != [] ->
        {:error, :expected_rule_statuses, "contain an unknown rule ID"}

      status == :pass and failed_ids != [] ->
        {:error, :expected_rule_statuses, "must all pass when the fixture should pass"}

      status == :fail and failed_ids == [] ->
        {:error, :expected_rule_statuses, "must identify at least one expected failing rule"}

      true ->
        :ok
    end
  end
end
