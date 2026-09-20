defmodule SilentRegression.Audit do
  @moduledoc """
  Records allowlisted operational events without prompts, outputs, credentials,
  bearer tokens, or other customer content.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Audit.AuditEvent
  alias SilentRegression.Repo

  @base_contract_keys ~w(
    monitor_id version status template_key assistance_mode fingerprint
  )

  @metadata_keys_by_action %{
    "user.logged_in" => ~w(method),
    "user.logged_out" => [],
    "user.login_failed" => ~w(method),
    "user.login_link_requested" => [],
    "user.email_change_requested" => [],
    "user.password_updated" => [],
    "user.email_changed" => [],
    "workspace.created" => ~w(source),
    "workspace.closed" => ~w(request_id request_type),
    "workspace.reopened" => ~w(request_id),
    "invitation.created" => ~w(role source),
    "invitation.revoked" => [],
    "invitation.accepted" => ~w(role),
    "membership.created" => ~w(role),
    "monitor.created" => [],
    "monitor.metadata_updated" => [],
    "monitor.state_changed" => ~w(from to),
    "monitor.paused" => ~w(from to reason),
    "monitor.resumed" => ~w(from to cadence next_run_at),
    "monitor.archived" => ~w(from to),
    "monitor.baseline_prepared" => ~w(monitor_version_id),
    "monitor_version.created" => ~w(monitor_id version provider requested_model),
    "monitor_version.activated" => ~w(monitor_id version provider requested_model),
    "contract_version.created" => @base_contract_keys,
    "contract_version.updated" => @base_contract_keys,
    "contract_version.approved" =>
      @base_contract_keys ++
        ~w(fixture_count rescore_observation_count rescore_pass_count rescore_fail_count interpretation_changed proof_schema_version proof_fingerprint coverage_waiver_count),
    "contract_version.revision_created" => @base_contract_keys ++ ~w(predecessor_id),
    "contract_fixture.created" => ~w(contract_version_id expected_status position fingerprint),
    "contract_fixture.updated" => ~w(contract_version_id expected_status position fingerprint),
    "contract_fixture.deleted" => ~w(contract_version_id expected_status position fingerprint),
    "contract_coverage_waiver.created_or_updated" =>
      ~w(contract_version_id monitor_id rule_id rule_fingerprint),
    "contract_coverage_waiver.removed" =>
      ~w(contract_version_id monitor_id rule_id rule_fingerprint),
    "baseline.authorized" =>
      ~w(capture_run_id planned_call_count maximum_call_count samples_per_case),
    "baseline.approved" =>
      ~w(approval_mode capture_run_id deterministic_failure_count member_count),
    "baseline.rejected" => ~w(capture_run_id),
    "alert.acknowledged" => ~w(capture_run_id category severity code at),
    "alert.resolved" => ~w(capture_run_id category severity code at),
    "review_decision.recorded" =>
      ~w(action capture_run_id classification review_key supersedes_id),
    "review_decision.contract_revision_started" => ~w(contract_version_id origin_id),
    "monitor.schedule_configured" => ~w(cadence next_run_at),
    "monitor.run_now_requested" => ~w(capture_run_id maximum_call_count),
    "monitor.scheduled" => ~w(capture_run_id intended_at next_run_at),
    "monitor.schedule_skipped_overlap" => ~w(intended_at next_run_at),
    "monitor.auto_paused" => ~w(reason),
    "provider_credential.created" => ~w(provider),
    "provider_credential.revoked" => ~w(provider),
    "provider_credential.superseded" => ~w(provider successor_id),
    "provider_credential.rotated" => ~w(provider supersedes_id),
    "provider_credential.validation_succeeded" =>
      ~w(provider attempts requested_model returned_model provider_request_id),
    "provider_credential.validation_failed" =>
      ~w(provider attempts requested_model returned_model provider_request_id category)
  }

  def record_event(attrs) when is_map(attrs) do
    with :ok <- validate_event(attrs) do
      %AuditEvent{}
      |> AuditEvent.record_changeset(attrs)
      |> Repo.insert()
    end
  end

  def record_event!(attrs) when is_map(attrs) do
    case validate_event(attrs) do
      :ok ->
        %AuditEvent{}
        |> AuditEvent.record_changeset(attrs)
        |> Repo.insert!()

      {:error, reason} ->
        raise ArgumentError, "invalid audit event: #{reason}"
    end
  end

  @doc false
  def metadata_allowlist(action), do: Map.get(@metadata_keys_by_action, action)

  @doc false
  def metadata_allowlists, do: @metadata_keys_by_action

  def list_workspace_events(%Scope{workspace: %{id: workspace_id}}) do
    AuditEvent
    |> where([event], event.workspace_id == ^workspace_id)
    |> order_by([event], desc: event.occurred_at, desc: event.inserted_at)
    |> Repo.all()
  end

  def list_workspace_events(%Scope{}), do: {:error, :workspace_required}

  defp validate_event(attrs) do
    action = attrs[:action]
    metadata = attrs[:metadata] || %{}

    with {:ok, allowed_keys} <- Map.fetch(@metadata_keys_by_action, action),
         true <- is_map(metadata),
         [] <- Map.keys(metadata) -- allowed_keys,
         true <- Enum.all?(metadata, &safe_metadata_entry?/1) do
      :ok
    else
      _reason -> {:error, :action_or_metadata_not_allowlisted}
    end
  end

  defp safe_metadata_entry?({key, value}) when is_binary(key) do
    is_nil(value) or is_boolean(value) or is_integer(value) or
      (is_binary(value) and byte_size(value) <= 256)
  end

  defp safe_metadata_entry?(_entry), do: false
end
