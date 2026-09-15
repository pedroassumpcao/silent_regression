defmodule SilentRegressionWeb.MonitorSetupController do
  use SilentRegressionWeb, :controller

  import Inertia.Controller, only: [assign_errors: 2]

  alias SilentRegression.{MonitorSetups, ProviderCredentials}
  alias SilentRegression.Monitors.{Limits, ModelCatalog}

  @steps ~w(purpose connection prompt cases review)

  def new(conn, _params) do
    conn
    |> assign(:page_title, "Create monitor")
    |> render_inertia("Monitors/New", %{release_stage: "Private alpha"})
  end

  def create(conn, params) do
    attrs = Map.get(params, "monitor", %{})

    case MonitorSetups.start(conn.assigns.current_scope, attrs) do
      {:ok, %{monitor: monitor}} ->
        conn
        |> put_flash(:info, "Monitor purpose saved. Continue with the provider connection.")
        |> redirect(to: setup_path(conn, monitor.id, :connection))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign_errors(%{changeset | action: :insert})
        |> redirect(to: new_monitor_path(conn))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "The monitor could not be created.")
        |> redirect(to: new_monitor_path(conn))
    end
  end

  def resume(conn, %{"monitor_id" => monitor_id}) do
    with {:ok, setup} <- MonitorSetups.get(conn.assigns.current_scope, monitor_id),
         progress <- MonitorSetups.progress(conn.assigns.current_scope, setup) do
      redirect(conn, to: setup_path(conn, monitor_id, progress.next_step))
    else
      {:error, :not_found} -> send_resp(conn, :not_found, "Not found")
    end
  end

  def show(conn, %{"monitor_id" => monitor_id, "step" => step}) when step in @steps do
    with {:ok, setup} <- MonitorSetups.get(conn.assigns.current_scope, monitor_id),
         progress <- MonitorSetups.progress(conn.assigns.current_scope, setup),
         :ok <- ensure_step_available(setup, progress, step) do
      render_setup(conn, setup, progress, step)
    else
      {:redirect, next_step} -> redirect(conn, to: setup_path(conn, monitor_id, next_step))
      {:error, :not_found} -> send_resp(conn, :not_found, "Not found")
    end
  end

  def show(conn, _params), do: send_resp(conn, :not_found, "Not found")

  def update(conn, %{"monitor_id" => monitor_id, "step" => step} = params)
      when step in @steps do
    scope = conn.assigns.current_scope

    with {:ok, setup} <- MonitorSetups.get(scope, monitor_id),
         progress <- MonitorSetups.progress(scope, setup),
         :ok <- ensure_step_available(setup, progress, step) do
      result = update_step(scope, monitor_id, step, params)
      handle_update_result(conn, monitor_id, step, result)
    else
      {:redirect, next_step} -> redirect(conn, to: setup_path(conn, monitor_id, next_step))
      {:error, :not_found} -> send_resp(conn, :not_found, "Not found")
    end
  end

  def update(conn, _params), do: send_resp(conn, :not_found, "Not found")

  def complete(conn, %{"monitor_id" => monitor_id}) do
    case MonitorSetups.complete(conn.assigns.current_scope, monitor_id) do
      {:ok, %{monitor: monitor}} ->
        conn
        |> put_flash(
          :info,
          "Workflow setup complete. Define its deterministic contract in the next product step."
        )
        |> redirect(to: setup_path(conn, monitor.id, :review))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, :setup_incomplete} ->
        conn
        |> put_flash(:error, "Complete every setup step before finishing.")
        |> redirect(to: setup_resume_path(conn, monitor_id))

      {:error, :already_completed} ->
        redirect(conn, to: setup_path(conn, monitor_id, :review))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Setup could not be completed. Review the saved configuration.")
        |> redirect(to: setup_path(conn, monitor_id, :review))
    end
  end

  def leave(conn, %{"monitor_id" => monitor_id} = params) do
    step = Map.get(params, "step", "review")

    case MonitorSetups.leave(conn.assigns.current_scope, monitor_id, step) do
      {:ok, _setup} ->
        conn
        |> put_flash(:info, "Setup saved. You can resume it at any time.")
        |> redirect(to: monitors_path(conn))

      {:error, :not_found} ->
        send_resp(conn, :not_found, "Not found")

      {:error, _reason} ->
        redirect(conn, to: setup_resume_path(conn, monitor_id))
    end
  end

  defp update_step(scope, monitor_id, "purpose", params) do
    MonitorSetups.update_purpose(scope, monitor_id, Map.get(params, "monitor", %{}))
  end

  defp update_step(scope, monitor_id, "connection", params) do
    MonitorSetups.update_connection(scope, monitor_id, Map.get(params, "connection", %{}))
  end

  defp update_step(scope, monitor_id, "prompt", params) do
    MonitorSetups.update_prompt(scope, monitor_id, Map.get(params, "prompt", %{}))
  end

  defp update_step(scope, monitor_id, "cases", params) do
    case Map.get(params, "case_import") do
      encoded when is_binary(encoded) and encoded != "" ->
        MonitorSetups.import_cases(scope, monitor_id, encoded)

      _encoded ->
        MonitorSetups.update_cases(scope, monitor_id, Map.get(params, "cases", []))
    end
  end

  defp update_step(_scope, _monitor_id, "review", _params), do: {:error, :invalid_step}

  defp handle_update_result(conn, monitor_id, step, {:ok, _setup}) do
    conn
    |> put_flash(:info, "Setup step saved.")
    |> redirect(to: setup_path(conn, monitor_id, next_step(step)))
  end

  defp handle_update_result(conn, monitor_id, step, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> assign_errors(%{changeset | action: :update})
    |> redirect(to: setup_path(conn, monitor_id, step))
  end

  defp handle_update_result(conn, monitor_id, step, {:error, _reason}) do
    conn
    |> put_flash(:error, "This setup step could not be saved.")
    |> redirect(to: setup_path(conn, monitor_id, step))
  end

  defp render_setup(conn, setup, progress, step) do
    scope = conn.assigns.current_scope
    credentials = ProviderCredentials.list_credentials(scope)
    active_case_count = Enum.count(MonitorSetups.stored_cases(setup), &(&1["status"] == "active"))

    conn
    |> assign(:page_title, "#{step_title(step)} · #{setup.monitor.name}")
    |> render_inertia("Monitors/Setup", %{
      active_case_count: active_case_count,
      credentials: Enum.map(credentials, &credential_prop/1),
      limits: limits_prop(),
      model_options: ModelCatalog.all(),
      progress: progress_prop(progress),
      release_stage: "Private alpha",
      setup: setup_prop(setup),
      step: step
    })
  end

  defp setup_prop(setup) do
    %{
      id: setup.id,
      status: setup.status,
      monitor: %{
        id: setup.monitor.id,
        name: setup.monitor.name,
        description: setup.monitor.description,
        state: setup.monitor.state
      },
      provider_credential_id: setup.provider_credential_id,
      provider: setup.provider,
      requested_model: setup.requested_model,
      system_prompt: setup.system_prompt,
      user_prompt_template: setup.user_prompt_template,
      response_format: setup.response_format,
      generation_config: setup.generation_config,
      cases: Enum.map(MonitorSetups.stored_cases(setup), &case_prop/1),
      completed_monitor_version_id: setup.completed_monitor_version_id,
      completed_at: setup.completed_at,
      updated_at: setup.updated_at
    }
  end

  defp case_prop(case_attributes) do
    Map.put(
      case_attributes,
      "input_variables_json",
      Jason.encode!(case_attributes["input_variables"], pretty: true)
    )
  end

  defp credential_prop(credential) do
    %{
      id: credential.id,
      provider: credential.provider,
      label: credential.label,
      secret_suffix: credential.secret_suffix,
      status: credential.status,
      last_returned_model: credential.last_returned_model
    }
  end

  defp progress_prop(progress) do
    %{
      completed: progress.completed,
      completed_count: progress.completed_count,
      total_count: progress.total_count,
      percent: progress.percent,
      next_step: progress.next_step,
      ready: progress.ready?
    }
  end

  defp limits_prop do
    %{
      max_active_cases: Limits.fetch!(:max_active_cases),
      max_total_cases: Limits.fetch!(:max_total_cases),
      max_prompt_bytes: Limits.fetch!(:max_prompt_bytes),
      max_context_bytes: Limits.fetch!(:max_context_bytes),
      max_variables_bytes: Limits.fetch!(:max_variables_bytes),
      max_import_bytes: Limits.fetch!(:max_import_bytes),
      max_output_tokens: Limits.fetch!(:max_output_tokens)
    }
  end

  defp ensure_step_available(%{status: :completed}, _progress, "review"), do: :ok
  defp ensure_step_available(%{status: :completed}, _progress, _step), do: {:redirect, :review}
  defp ensure_step_available(_setup, %{ready?: true}, _step), do: :ok

  defp ensure_step_available(_setup, progress, step) do
    if step_index(step) <= step_index(progress.next_step),
      do: :ok,
      else: {:redirect, progress.next_step}
  end

  defp step_index(step) when is_atom(step), do: step |> Atom.to_string() |> step_index()
  defp step_index(step), do: Enum.find_index(@steps, &(&1 == step)) || length(@steps)

  defp next_step("purpose"), do: :connection
  defp next_step("connection"), do: :prompt
  defp next_step("prompt"), do: :cases
  defp next_step("cases"), do: :review

  defp step_title("purpose"), do: "Purpose"
  defp step_title("connection"), do: "Provider and model"
  defp step_title("prompt"), do: "Prompt and configuration"
  defp step_title("cases"), do: "Representative cases"
  defp step_title("review"), do: "Review setup"

  defp setup_path(conn, monitor_id, step) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/setup/#{step}"
  end

  defp setup_resume_path(conn, monitor_id) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/#{monitor_id}/setup"
  end

  defp new_monitor_path(conn) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors/new"
  end

  defp monitors_path(conn) do
    ~p"/app/#{conn.assigns.current_scope.workspace.slug}/monitors"
  end
end
