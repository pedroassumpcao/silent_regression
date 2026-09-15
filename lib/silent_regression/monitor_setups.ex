defmodule SilentRegression.MonitorSetups do
  @moduledoc """
  Workspace-scoped, resumable monitor setup and immutable-version promotion.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.MonitorSetups.Setup

  alias SilentRegression.Monitors.{
    CaseImport,
    CaseInput,
    GenerationConfig,
    Limits,
    ModelCatalog,
    Monitor,
    ResponseFormat
  }

  alias SilentRegression.{Monitors, ProductAnalytics, Repo}
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @steps [:purpose, :connection, :prompt, :cases]
  @generation_keys ~w(max_output_tokens temperature top_p reasoning_effort)

  def start(
        %Scope{
          workspace: %Workspace{} = workspace,
          membership: %Membership{},
          user: %User{} = user
        } = scope,
        attrs
      )
      when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, monitor} <- Monitors.create_monitor(scope, attrs),
           {:ok, setup} <-
             %Setup{}
             |> Setup.create_changeset(workspace, monitor, user)
             |> Repo.insert() do
        ProductAnalytics.record!(scope, "monitor_setup.started", monitor.id, %{
          "step" => "purpose"
        })

        ProductAnalytics.record!(scope, "monitor_setup.step_completed", monitor.id, %{
          "step" => "purpose",
          "completed_count" => 1,
          "total_count" => length(@steps)
        })

        %{monitor: monitor, setup: Repo.preload(setup, :monitor)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def start(%Scope{}, _attrs), do: {:error, :workspace_required}

  def list(%Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}}) do
    Setup
    |> where([setup], setup.workspace_id == ^workspace_id)
    |> order_by([setup], desc: setup.updated_at, desc: setup.id)
    |> preload(:monitor)
    |> Repo.all()
  end

  def list(%Scope{}), do: {:error, :workspace_required}

  def list_summaries(%Scope{} = scope) do
    case list(scope) do
      setups when is_list(setups) ->
        Enum.map(setups, fn setup -> %{setup: setup, progress: progress(scope, setup)} end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         %Setup{} = setup <- load_setup(workspace_id, monitor_id) do
      {:ok, Repo.preload(setup, :monitor)}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  def update_purpose(%Scope{} = scope, monitor_id, attrs) when is_map(attrs) do
    update_setup(scope, monitor_id, :purpose, fn setup ->
      with {:ok, monitor} <- Monitors.update_monitor_metadata(scope, monitor_id, attrs) do
        {:ok, %{setup | monitor: monitor}}
      end
    end)
  end

  def update_purpose(%Scope{}, _monitor_id, _attrs), do: {:error, :invalid_input}

  def update_connection(%Scope{} = scope, monitor_id, attrs) when is_map(attrs) do
    update_setup(scope, monitor_id, :connection, fn setup ->
      with {:ok, {provider, requested_model}} <- normalize_provider_model(attrs),
           {:ok, credential_id} <- credential_id(attrs),
           %ProviderCredential{} = credential <-
             selectable_credential(scope.workspace.id, credential_id),
           :ok <- credential_matches(credential, provider),
           {:ok, setup} <-
             setup
             |> Setup.connection_changeset(credential, provider, requested_model)
             |> Repo.update() do
        {:ok, Repo.preload(setup, :monitor, force: true)}
      else
        nil ->
          invalid_setup(setup, :provider_credential_id, "is not available")

        :error ->
          invalid_setup(setup, :provider_credential_id, "is invalid")

        {:error, :model_not_allowed} ->
          invalid_setup(setup, :requested_model, "is not allowlisted for this provider")

        {:error, :credential_provider_mismatch} ->
          invalid_setup(setup, :provider_credential_id, "does not match the selected provider")

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end)
  end

  def update_connection(%Scope{}, _monitor_id, _attrs), do: {:error, :invalid_input}

  def update_prompt(%Scope{} = scope, monitor_id, attrs) when is_map(attrs) do
    update_setup(scope, monitor_id, :prompt, fn setup ->
      case normalize_prompt_attributes(attrs) do
        {:ok, normalized} ->
          setup
          |> Setup.prompt_changeset(normalized)
          |> Repo.update()
          |> preload_setup_result()

        {:error, {field, message}} ->
          invalid_setup(setup, field, message)
      end
    end)
  end

  def update_prompt(%Scope{}, _monitor_id, _attrs), do: {:error, :invalid_input}

  def update_cases(%Scope{} = scope, monitor_id, cases) when is_list(cases) do
    update_setup(scope, monitor_id, :cases, fn setup ->
      with {:ok, case_attributes} <- normalize_manual_cases(cases),
           {:ok, normalized} <- CaseInput.normalize_many(case_attributes) do
        persist_cases(setup, normalized)
      else
        {:error, _reason} -> invalid_setup(setup, :cases, "contain invalid or incomplete data")
      end
    end)
  end

  def update_cases(%Scope{}, _monitor_id, _cases), do: {:error, :invalid_input}

  def import_cases(%Scope{} = scope, monitor_id, encoded) when is_binary(encoded) do
    update_setup(scope, monitor_id, :cases, fn setup ->
      case CaseImport.parse(encoded) do
        {:ok, normalized} -> persist_cases(setup, normalized)
        {:error, _reason} -> invalid_setup(setup, :cases, "import is invalid or exceeds a limit")
      end
    end)
  end

  def import_cases(%Scope{}, _monitor_id, _encoded), do: {:error, :invalid_input}

  def leave(%Scope{} = scope, monitor_id, step) do
    with {:ok, step} <- cast_step(step),
         {:ok, setup} <- get(scope, monitor_id),
         %{completed_count: completed_count, total_count: total_count} <- progress(scope, setup) do
      ProductAnalytics.record!(scope, "monitor_setup.left", setup.monitor_id, %{
        "step" => Atom.to_string(step),
        "completed_count" => completed_count,
        "total_count" => total_count
      })

      {:ok, setup}
    else
      :error -> {:error, :invalid_step}
      {:error, reason} -> {:error, reason}
    end
  end

  def complete(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{}
        } = scope,
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      Repo.transaction(fn ->
        with %Setup{} = setup <- locked_setup(workspace_id, monitor_id),
             :ok <- ensure_in_progress(setup),
             setup <- Repo.preload(setup, :monitor),
             %{ready?: true} = setup_progress <- progress(scope, setup),
             %ProviderCredential{} = credential <-
               selectable_credential(workspace_id, setup.provider_credential_id),
             :ok <- credential_matches(credential, setup.provider),
             {:ok, version} <-
               Monitors.create_version(scope, monitor_id, version_attributes(setup)),
             {:ok, monitor} <-
               setup.monitor |> Monitor.credential_changeset(credential) |> Repo.update(),
             {:ok, completed_setup} <-
               setup
               |> Setup.complete_changeset(version, DateTime.utc_now(:second))
               |> Repo.update() do
          ProductAnalytics.record!(scope, "monitor_setup.completed", monitor_id, %{
            "completed_count" => setup_progress.completed_count,
            "total_count" => setup_progress.total_count
          })

          %{setup: completed_setup, monitor: monitor, version: version}
        else
          nil -> Repo.rollback(:not_found)
          %{ready?: false} -> Repo.rollback(:setup_incomplete)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def complete(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  def progress(
        %Scope{workspace: %Workspace{id: workspace_id}} = scope,
        %Setup{workspace_id: workspace_id} = setup
      ) do
    setup = Repo.preload(setup, :monitor)

    completed =
      if setup.status == :completed do
        Map.new(@steps, &{&1, true})
      else
        %{
          purpose: purpose_ready?(setup.monitor),
          connection: connection_ready?(scope, setup),
          prompt: prompt_ready?(setup),
          cases: cases_ready?(setup)
        }
      end

    completed_count = Enum.count(@steps, &Map.fetch!(completed, &1))
    next_step = Enum.find(@steps, &(not Map.fetch!(completed, &1))) || :review

    %{
      completed: completed,
      completed_count: completed_count,
      total_count: length(@steps),
      percent: div(completed_count * 100, length(@steps)),
      next_step: next_step,
      ready?: completed_count == length(@steps)
    }
  end

  def progress(%Scope{}, %Setup{}), do: {:error, :not_found}

  def stored_cases(%Setup{cases: %{"items" => cases}}) when is_list(cases), do: cases
  def stored_cases(%Setup{}), do: []

  def steps, do: @steps

  defp update_setup(
         %Scope{workspace: %Workspace{id: workspace_id}} = scope,
         monitor_id,
         step,
         callback
       ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      Repo.transaction(fn ->
        with %Setup{} = setup <- locked_setup(workspace_id, monitor_id),
             :ok <- ensure_in_progress(setup),
             setup <- Repo.preload(setup, :monitor),
             before_progress <- progress(scope, setup),
             {:ok, updated_setup} <- callback.(setup) do
          updated_setup = Repo.preload(updated_setup, :monitor)
          after_progress = progress(scope, updated_setup)
          record_step_completion(scope, updated_setup, step, before_progress, after_progress)
          updated_setup
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  defp update_setup(%Scope{}, _monitor_id, _step, _callback),
    do: {:error, :workspace_required}

  defp record_step_completion(scope, setup, step, before_progress, after_progress) do
    if not Map.fetch!(before_progress.completed, step) and
         Map.fetch!(after_progress.completed, step) do
      ProductAnalytics.record!(scope, "monitor_setup.step_completed", setup.monitor_id, %{
        "step" => Atom.to_string(step),
        "completed_count" => after_progress.completed_count,
        "total_count" => after_progress.total_count
      })
    end
  end

  defp normalize_provider_model(attrs) do
    ModelCatalog.validate(value(attrs, :provider, nil), value(attrs, :requested_model, nil))
  end

  defp credential_id(attrs) do
    attrs |> value(:provider_credential_id, nil) |> Ecto.UUID.cast()
  end

  defp selectable_credential(workspace_id, credential_id) do
    ProviderCredential
    |> where([credential], credential.workspace_id == ^workspace_id)
    |> where([credential], credential.id == ^credential_id)
    |> where([credential], credential.status == :valid)
    |> select([credential], struct(credential, [:id, :workspace_id, :provider, :status]))
    |> Repo.one()
  end

  defp credential_matches(%ProviderCredential{provider: provider}, provider), do: :ok

  defp credential_matches(%ProviderCredential{}, _provider),
    do: {:error, :credential_provider_mismatch}

  defp normalize_prompt_attributes(attrs) do
    with {:ok, system_prompt} <- prompt(attrs, :system_prompt, false),
         {:ok, user_prompt_template} <- prompt(attrs, :user_prompt_template, true),
         {:ok, response_format} <-
           attrs |> value(:response_format, nil) |> ResponseFormat.normalize(),
         {:ok, generation_config} <-
           attrs |> value(:generation_config, %{}) |> normalize_generation_config() do
      {:ok,
       %{
         system_prompt: system_prompt,
         user_prompt_template: user_prompt_template,
         response_format: response_format,
         generation_config: generation_config
       }}
    end
  end

  defp prompt(attrs, field, required?) do
    prompt = value(attrs, field, "")

    if is_binary(prompt) and String.valid?(prompt) and
         byte_size(prompt) <= Limits.fetch!(:max_prompt_bytes) and
         (not required? or String.trim(prompt) != "") do
      {:ok, prompt}
    else
      {:error, {field, "is invalid or exceeds the prompt limit"}}
    end
  end

  defp normalize_generation_config(config) when is_map(config) do
    with {:ok, config} <- SilentRegression.Monitors.JsonValue.normalize(config),
         [] <- Map.keys(config) -- @generation_keys,
         {:ok, config} <- cast_generation_values(config),
         {:ok, normalized} <- GenerationConfig.normalize(config) do
      {:ok, normalized}
    else
      _reason -> {:error, {:generation_config, "contains an invalid value"}}
    end
  end

  defp normalize_generation_config(_config),
    do: {:error, {:generation_config, "is invalid"}}

  defp cast_generation_values(config) do
    with {:ok, max_output_tokens} <- parse_integer(Map.get(config, "max_output_tokens", 512)),
         {:ok, temperature} <- parse_optional_float(Map.get(config, "temperature")),
         {:ok, top_p} <- parse_optional_float(Map.get(config, "top_p")) do
      normalized =
        config
        |> Map.put("max_output_tokens", max_output_tokens)
        |> put_optional("temperature", temperature)
        |> put_optional("top_p", top_p)

      {:ok, normalized}
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _result -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_optional_float(nil), do: {:ok, nil}
  defp parse_optional_float(""), do: {:ok, nil}
  defp parse_optional_float(value) when is_integer(value) or is_float(value), do: {:ok, value}

  defp parse_optional_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> {:ok, float}
      _result -> :error
    end
  end

  defp parse_optional_float(_value), do: :error

  defp put_optional(map, key, nil), do: Map.delete(map, key)
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp normalize_manual_cases(cases) do
    cases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attributes, index}, {:ok, normalized} ->
      case normalize_manual_case(attributes, index) do
        {:ok, case_attributes} -> {:cont, {:ok, [case_attributes | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_manual_case(attributes, position) when is_map(attributes) do
    with {:ok, input_variables} <- input_variables(attributes) do
      {:ok,
       %{
         "case_key" => value(attributes, :case_key, ""),
         "name" => value(attributes, :name, ""),
         "position" => position,
         "status" => value(attributes, :status, "active"),
         "input_variables" => input_variables,
         "frozen_context" => value(attributes, :frozen_context, "")
       }}
    end
  end

  defp normalize_manual_case(_attributes, _position), do: {:error, :invalid_case}

  defp input_variables(attributes) do
    case value(attributes, :input_variables, nil) do
      variables when is_map(variables) ->
        {:ok, variables}

      nil ->
        decode_input_variables(value(attributes, :input_variables_json, "{}"))

      _variables ->
        {:error, :invalid_input_variables}
    end
  end

  defp decode_input_variables(encoded) when is_binary(encoded) do
    with {:ok, variables} when is_map(variables) <- Jason.decode(encoded) do
      {:ok, variables}
    else
      _reason -> {:error, :invalid_input_variables}
    end
  end

  defp decode_input_variables(_encoded), do: {:error, :invalid_input_variables}

  defp persist_cases(setup, normalized) do
    serialized = Enum.map(normalized, &serialize_case/1)

    setup
    |> Setup.cases_changeset(serialized)
    |> Repo.update()
    |> preload_setup_result()
  end

  defp serialize_case(case_attributes) do
    %{
      "case_key" => case_attributes.case_key,
      "name" => case_attributes.name,
      "position" => case_attributes.position,
      "status" => Atom.to_string(case_attributes.status),
      "input_variables" => case_attributes.input_variables,
      "frozen_context" => case_attributes.frozen_context
    }
  end

  defp version_attributes(setup) do
    %{
      provider: Atom.to_string(setup.provider),
      requested_model: setup.requested_model,
      system_prompt: setup.system_prompt,
      user_prompt_template: setup.user_prompt_template,
      response_format: setup.response_format,
      generation_config: setup.generation_config,
      cases: stored_cases(setup)
    }
  end

  defp purpose_ready?(%Monitor{name: name}) when is_binary(name), do: String.trim(name) != ""
  defp purpose_ready?(%Monitor{}), do: false

  defp connection_ready?(scope, setup) do
    with id when not is_nil(id) <- setup.provider_credential_id,
         {:ok, credential} <- SilentRegression.ProviderCredentials.get_credential(scope, id),
         true <- credential.status == :valid,
         true <- credential.provider == setup.provider,
         {:ok, {_provider, _model}} <-
           ModelCatalog.validate(setup.provider, setup.requested_model) do
      true
    else
      _reason -> false
    end
  end

  defp prompt_ready?(setup) do
    attributes =
      Map.take(setup, [
        :system_prompt,
        :user_prompt_template,
        :response_format,
        :generation_config
      ])

    match?({:ok, _normalized}, normalize_prompt_attributes(attributes))
  end

  defp cases_ready?(setup) do
    case CaseInput.normalize_many(stored_cases(setup)) do
      {:ok, _cases} -> true
      {:error, _reason} -> false
    end
  end

  defp ensure_in_progress(%Setup{status: :in_progress}), do: :ok
  defp ensure_in_progress(%Setup{}), do: {:error, :already_completed}

  defp load_setup(workspace_id, monitor_id) do
    Setup
    |> where([setup], setup.workspace_id == ^workspace_id)
    |> where([setup], setup.monitor_id == ^monitor_id)
    |> Repo.one()
  end

  defp locked_setup(workspace_id, monitor_id) do
    Setup
    |> where([setup], setup.workspace_id == ^workspace_id)
    |> where([setup], setup.monitor_id == ^monitor_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp preload_setup_result({:ok, setup}), do: {:ok, Repo.preload(setup, :monitor, force: true)}
  defp preload_setup_result({:error, changeset}), do: {:error, changeset}

  defp invalid_setup(setup, field, message),
    do: {:error, Setup.error_changeset(setup, field, message)}

  defp cast_step(step) when step in @steps, do: {:ok, step}
  defp cast_step("purpose"), do: {:ok, :purpose}
  defp cast_step("connection"), do: {:ok, :connection}
  defp cast_step("prompt"), do: {:ok, :prompt}
  defp cast_step("cases"), do: {:ok, :cases}
  defp cast_step("review"), do: {:ok, :review}
  defp cast_step(_step), do: :error

  defp value(attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
