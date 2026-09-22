defmodule SilentRegression.GuidedSetups do
  @moduledoc "Workspace-scoped recipe authoring with stale-tab guards and explicit proof review."
  import Ecto.Query
  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Workspaces.{Membership, Workspace}
  alias SilentRegression.GuidedSetups.{Draft, Proof, Recipes, Routing}
  alias SilentRegression.{Audit, ContractAuthoring, MonitorSetups, ProviderCredentials, Repo}

  def create(scope, recipe \\ "routing")

  def create(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %{id: user_id}
        },
        recipe
      )
      when recipe in ~w(routing json sources text) do
    Repo.transaction(fn ->
      draft =
        Repo.insert!(%Draft{
          workspace_id: workspace_id,
          created_by_user_id: user_id,
          recipe: recipe,
          raw: Recipes.empty(recipe)
        })

      audit!(draft, user_id, "created")
      draft
    end)
  end

  def create(%Scope{}, _), do: {:error, :invalid_recipe}

  def list(%Scope{workspace: %Workspace{id: id}, membership: %Membership{}}) do
    Repo.all(
      from draft in Draft,
        where: draft.workspace_id == ^id and is_nil(draft.sealed_at),
        order_by: [desc: draft.updated_at]
    )
  end

  def list(%Scope{}), do: []

  def get(%Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Draft{} = draft <- Repo.get_by(Draft, id: id, workspace_id: workspace_id) do
      {:ok, draft}
    else
      _ -> {:error, :not_found}
    end
  end

  def get(%Scope{}, _), do: {:error, :not_found}

  def guided_monitor?(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id
      ) do
    Repo.exists?(
      from draft in Draft,
        where: draft.workspace_id == ^workspace_id and draft.monitor_id == ^monitor_id
    )
  end

  def guided_monitor?(%Scope{}, _monitor_id), do: false

  def save(scope, id, revision, raw) do
    mutate(scope, id, revision, fn draft ->
      case Recipes.validate_raw(draft.recipe, raw) do
        :ok ->
          reviews = if raw == draft.raw, do: draft.reviews, else: %{}
          updated = update!(draft, raw: raw, reviews: reviews)
          audit!(updated, scope.user.id, "saved")
          updated

        _ ->
          Repo.rollback(:invalid_draft)
      end
    end)
  end

  def review(scope, id, revision, judgments)
      when is_list(judgments) and length(judgments) <= 60 do
    mutate(scope, id, revision, fn draft ->
      with {:ok, compiled} <- Recipes.compile(draft),
           true <- valid_partial_judgments?(compiled.proof, judgments) do
        now = DateTime.to_iso8601(DateTime.utc_now(:second))

        reviews =
          Map.new(judgments, fn judgment ->
            row = Enum.find(compiled.proof, &(&1.fingerprint == judgment["fingerprint"]))

            {judgment["fingerprint"],
             Map.merge(Map.take(judgment, ~w(fingerprint shared specific)), %{
               "actor_user_id" => scope.user.id,
               "reviewed_at" => now,
               "output_text" => row.output,
               "failed_rule_ids" => row.failed_rule_ids,
               "case_key" => row.case_key,
               "case_fingerprint" => row.case_fingerprint,
               "expectation_fingerprint" => row.expectation_fingerprint,
               "configuration_and_checks_fingerprint" => compiled.identity,
               "evaluator_engine" => SilentRegression.Contracts.evaluator_engine_version()
             })}
          end)

        if byte_size(Jason.encode!(reviews)) > 90_000, do: Repo.rollback(:proof_review_required)
        updated = update!(draft, reviews: reviews)
        audit!(updated, scope.user.id, "proof_reviewed", %{"fingerprint" => compiled.identity})
        updated
      else
        _ -> Repo.rollback(:proof_review_required)
      end
    end)
  end

  def review(_scope, _id, _revision, _judgments), do: {:error, :proof_review_required}

  def state(scope, %Draft{} = draft) do
    with {:ok, current} <- get(scope, draft.id),
         true <- current.revision == draft.revision do
      state_for(scope, current)
    else
      false -> {:error, :stale_draft}
      error -> error
    end
  end

  def seal(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}} = scope,
        id,
        revision
      ) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn ->
        case locked(workspace_id, id) do
          nil ->
            Repo.rollback(:not_found)

          %Draft{sealed_at: at} = draft when not is_nil(at) ->
            draft

          %Draft{} = draft ->
            ensure_revision!(draft, revision)

            with %{stage: :review} <- state_for(scope, draft),
                 {:ok, compiled} <- Recipes.compile(draft),
                 {:ok, %{monitor: monitor}} <-
                   MonitorSetups.start(scope, %{
                     name: draft.raw["name"],
                     description: draft.raw["description"]
                   }),
                 {:ok, _} <-
                   MonitorSetups.update_connection(scope, monitor.id, %{
                     provider: draft.raw["provider"],
                     requested_model: draft.raw["model"],
                     provider_credential_id: draft.raw["credentialId"]
                   }),
                 {:ok, _} <-
                   MonitorSetups.update_prompt(
                     scope,
                     monitor.id,
                     Map.take(compiled.attributes, [
                       :request_mode,
                       :request_template,
                       :response_format,
                       :generation_config
                     ])
                   ),
                 {:ok, _} <-
                   MonitorSetups.import_cases(
                     scope,
                     monitor.id,
                     import_cases(compiled.attributes.cases)
                   ),
                 {:ok, _} <- MonitorSetups.complete(scope, monitor.id),
                 {:ok, _} <-
                   ContractAuthoring.save_draft(scope, monitor.id, %{
                     template_key: Recipes.template(draft.recipe),
                     assistance_mode: "self_serve",
                     root: compiled.root
                   }),
                 :ok <-
                   persist_shared_fixtures(
                     scope,
                     monitor.id,
                     compiled.proof,
                     draft.reviews,
                     draft.recipe
                   ) do
              sealed =
                update!(draft, monitor_id: monitor.id, sealed_at: DateTime.utc_now(:second))

              audit!(sealed, scope.user.id, "sealed", %{
                "monitor_id" => monitor.id,
                "fingerprint" => compiled.identity
              })

              sealed
            else
              {:error, reason} -> Repo.rollback(reason)
              _ -> Repo.rollback(:draft_incomplete)
            end
        end
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  def seal(%Scope{}, _, _), do: {:error, :not_found}

  defp state_for(scope, draft) do
    base = %{
      variables: Routing.variables(draft.raw),
      requests: [],
      proof: [],
      reviewed: false,
      blockers: []
    }

    cond do
      draft.sealed_at ->
        Map.merge(base, %{
          stage: :sealed,
          next_action: "Review checks and first-run authorization"
        })

      true ->
        compilation =
          with {:ok, _} <- Routing.configuration(draft.raw),
               :ok <- connection_ready(scope, draft.raw),
               do: Recipes.compile(draft)

        case compilation do
          {:error, {stage, message}} ->
            Map.merge(base, %{stage: stage, next_action: "Save and continue", blockers: [message]})

          {:ok, compiled} ->
            reviewed = valid_judgments?(compiled.proof, Map.values(draft.reviews))

            {stage, blockers} =
              cond do
                not reviewed ->
                  {:checks,
                   [
                     "Review each proposed judgment. Synthetic examples are not model results or independent ground truth."
                   ]}

                true ->
                  {:review, []}
              end

            Map.merge(base, %{
              stage: stage,
              blockers: blockers,
              proof: compiled.proof,
              requests: compiled.requests,
              reviewed: reviewed,
              identity: compiled.identity,
              next_action:
                if(stage == :review, do: "Prepare first-run review", else: "Save and continue")
            })
        end
    end
  end

  defp connection_ready(scope, raw) do
    if Enum.any?(
         ProviderCredentials.list_selectable_credentials(scope),
         &(&1.id == raw["credentialId"] and Atom.to_string(&1.provider) == raw["provider"])
       ) do
      :ok
    else
      {:error,
       {:request,
        "Select a validated workspace connection for this provider. Saving this draft makes no provider calls."}}
    end
  end

  defp valid_judgments?(proof, judgments) do
    length(proof) == length(judgments) and
      Enum.sort(Enum.map(proof, & &1.fingerprint)) ==
        Enum.sort(Enum.map(judgments, &if(is_map(&1), do: &1["fingerprint"], else: nil))) and
      Enum.all?(proof, fn row ->
        Enum.any?(judgments, fn judgment ->
          judgment["fingerprint"] == row.fingerprint and judgment["shared"] == row.proposed_shared and
            judgment["specific"] == row.proposed_case and row.shared == row.proposed_shared and
            row.specific == row.proposed_case
        end)
      end)
  end

  defp valid_partial_judgments?(proof, judgments) do
    ids = Enum.map(judgments, &if(is_map(&1), do: &1["fingerprint"], else: nil))
    selected = Enum.filter(proof, &(&1.fingerprint in ids))
    ids == Enum.uniq(ids) and valid_judgments?(selected, judgments)
  end

  defp mutate(
         %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}} = _scope,
         id,
         revision,
         fun
       ) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn ->
        case locked(workspace_id, id) do
          nil ->
            Repo.rollback(:not_found)

          %Draft{sealed_at: at} when not is_nil(at) ->
            Repo.rollback(:already_sealed)

          draft ->
            ensure_revision!(draft, revision)
            fun.(draft)
        end
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp mutate(%Scope{}, _, _, _), do: {:error, :not_found}

  defp locked(workspace_id, id),
    do:
      Repo.one(
        from draft in Draft,
          where: draft.workspace_id == ^workspace_id and draft.id == ^id,
          lock: "FOR UPDATE"
      )

  defp ensure_revision!(draft, revision) do
    if not is_integer(revision) or draft.revision != revision, do: Repo.rollback(:stale_draft)
  end

  defp update!(draft, attrs),
    do:
      draft
      |> Ecto.Changeset.change(attrs)
      |> Ecto.Changeset.change(revision: draft.revision + 1)
      |> Repo.update!()

  defp import_cases(cases) do
    Jason.encode!(%{
      schema_version: 2,
      cases: Enum.map(cases, &Map.delete(&1, :expectation_schema_version))
    })
  end

  defp persist_shared_fixtures(scope, monitor_id, proof, reviews, recipe) do
    fixtures =
      if recipe == "routing",
        do: Enum.uniq_by(proof, & &1.output),
        else: Proof.shared_fixtures(proof)

    fixtures
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {row, index}, :ok ->
      status = reviews[row.fingerprint]["shared"]

      attrs = %{
        name: "Reviewed #{recipe} proof #{index}",
        output_text: row.output,
        expected_status: status,
        expected_failed_rule_ids: row.failed_rule_ids
      }

      case ContractAuthoring.add_fixture(scope, monitor_id, attrs) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp audit!(draft, user_id, action, metadata \\ %{}) do
    Audit.record_event!(%{
      action: "guided_setup.#{action}",
      target_type: "guided_setup_draft",
      target_id: draft.id,
      workspace_id: draft.workspace_id,
      actor_user_id: user_id,
      metadata:
        Map.merge(
          %{
            "recipe" => draft.recipe,
            "recipe_version" => draft.recipe_version,
            "revision" => draft.revision
          },
          metadata
        )
    })
  end
end
