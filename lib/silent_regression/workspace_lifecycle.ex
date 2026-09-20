defmodule SilentRegression.WorkspaceLifecycle do
  @moduledoc """
  Owner-requested workspace closure, recovery, retention, and irreversible purge.

  Closure immediately cancels provider work, pauses active monitors, revokes
  credentials, and removes the workspace from authenticated tenant scopes.
  Purge is an operator-only path and leaves only a keyed, content-free receipt.
  """

  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Audit
  alias SilentRegression.Captures
  alias SilentRegression.ContractAuthoring.{ContractVersion, Rescorer, RescoreRun}
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.Notifications.Delivery
  alias SilentRegression.ProviderCredentials.ProviderCredential
  alias SilentRegression.Repo
  alias SilentRegression.WorkspaceLifecycle.DeletionReceipt
  alias SilentRegression.WorkspaceLifecycle.DeletionLedger
  alias SilentRegression.Workspaces.{Invitation, Membership, Workspace}

  @closure_retention_days 30
  @closable_credential_statuses [:pending_validation, :valid, :invalid]

  def close_workspace(scope, mode, confirmation, opts \\ [])

  def close_workspace(
        %Scope{
          workspace: %Workspace{} = workspace,
          membership: %Membership{role: :owner},
          user: %User{} = user
        } = scope,
        mode,
        confirmation,
        opts
      )
      when mode in [:closure_retention, :explicit_request] and is_binary(confirmation) do
    if confirmation == workspace.slug do
      now = Keyword.get(opts, :at, DateTime.utc_now(:second)) |> DateTime.truncate(:second)
      purge_after = purge_after(mode, now)

      Repo.transaction(fn ->
        with %Workspace{status: :active} = locked <- lock_workspace(workspace.id),
             :ok <- halt_execution(scope, locked, user, now),
             {:ok, receipt} <- insert_receipt(locked, mode, now, purge_after),
             {:ok, closed} <-
               locked
               |> Workspace.close_changeset(user, mode, now, purge_after)
               |> Repo.update() do
          Audit.record_event!(%{
            action: "workspace.closed",
            target_type: "workspace",
            target_id: closed.id,
            workspace_id: closed.id,
            actor_user_id: user.id,
            metadata: %{
              "request_id" => receipt.request_id,
              "request_type" => Atom.to_string(mode)
            }
          })

          %{workspace: closed, receipt: receipt}
        else
          %Workspace{status: :closed} -> Repo.rollback(:already_closed)
          %Workspace{} -> Repo.rollback(:workspace_unavailable)
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :confirmation_mismatch}
    end
  end

  def close_workspace(%Scope{}, _mode, _confirmation, _opts), do: {:error, :owner_required}

  @doc "Operator-only recovery for an ordinary closure still inside its retention window."
  def operator_reopen(workspace_slug, actor_email, opts \\ [])
      when is_binary(workspace_slug) and is_binary(actor_email) do
    now = Keyword.get(opts, :at, DateTime.utc_now(:second)) |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      with %Workspace{} = workspace <- lock_workspace_by_slug(workspace_slug),
           :ok <- reopenable?(workspace, now),
           %User{} = actor <- owner_by_email(workspace.id, actor_email),
           %DeletionReceipt{} = receipt <- pending_receipt(workspace, :closure_retention),
           {:ok, reopened} <- workspace |> Workspace.reopen_changeset() |> Repo.update(),
           {:ok, _receipt} <- receipt |> DeletionReceipt.cancel_changeset(now) |> Repo.update() do
        Audit.record_event!(%{
          action: "workspace.reopened",
          target_type: "workspace",
          target_id: reopened.id,
          workspace_id: reopened.id,
          actor_user_id: actor.id,
          metadata: %{"request_id" => receipt.request_id}
        })

        reopened
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Returns an operator-safe summary without exposing workspace content."
  def purge_preview(workspace_slug, opts \\ []) when is_binary(workspace_slug) do
    now = Keyword.get(opts, :at, DateTime.utc_now(:second)) |> DateTime.truncate(:second)

    case Repo.get_by(Workspace, slug: workspace_slug) do
      %Workspace{} = workspace ->
        {:ok,
         %{
           workspace_slug: workspace.slug,
           status: workspace.status,
           request_type: request_type(workspace),
           purge_due_at: workspace.purge_after,
           due?: workspace.status == :closed and due?(workspace, now)
         }}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Operator-only, irreversible purge after the persisted retention deadline."
  def operator_purge_due_workspace(workspace_slug, opts \\ []) when is_binary(workspace_slug) do
    now = Keyword.get(opts, :at, DateTime.utc_now(:second)) |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      with %Workspace{} = workspace <- lock_workspace_by_slug(workspace_slug),
           :ok <- purgeable?(workspace, now),
           %DeletionReceipt{} = receipt <- pending_receipt(workspace, request_type(workspace)) do
        purge_locked_workspace!(workspace, receipt, now)
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Purges a bounded batch of due workspaces for periodic maintenance."
  def purge_due_workspaces(opts \\ []) do
    now = Keyword.get(opts, :at, DateTime.utc_now(:second)) |> DateTime.truncate(:second)

    limit =
      Keyword.get_lazy(opts, :limit, fn ->
        Application.fetch_env!(:silent_regression, :workspace_lifecycle)
        |> Keyword.fetch!(:purge_batch_size)
      end)

    workspace_ids =
      Workspace
      |> where(
        [workspace],
        workspace.status == :closed and not is_nil(workspace.purge_after) and
          workspace.purge_after <= ^now
      )
      |> order_by([workspace], asc: workspace.purge_after, asc: workspace.id)
      |> limit(^limit)
      |> select([workspace], workspace.id)
      |> Repo.all()

    results = Enum.map(workspace_ids, &purge_due_workspace_id(&1, now))
    failures = Enum.count(results, &match?({:error, _reason}, &1))

    if failures == 0 do
      {:ok, %{selected: length(workspace_ids), purged: length(results), failed: 0}}
    else
      {:error,
       %{selected: length(workspace_ids), purged: length(results) - failures, failed: failures}}
    end
  end

  @doc "Previews or executes deletion reconciliation from a verified content-free ledger."
  def reconcile_deletion_ledger(ledger, opts \\ []) when is_map(ledger) do
    now = Keyword.get(opts, :at, DateTime.utc_now(:second)) |> DateTime.truncate(:second)
    execute? = Keyword.get(opts, :execute, false)

    with {:ok, entries} <- DeletionLedger.verify(ledger) do
      actionable = Enum.filter(entries, &ledger_entry_actionable?(&1, now))

      results =
        Enum.map(actionable, fn entry ->
          case workspace_id_for_fingerprint(entry.workspace_fingerprint) do
            nil ->
              {:absent, entry.request_id}

            workspace_id when execute? ->
              case reconcile_workspace_deletion(workspace_id, entry, now) do
                {:ok, _receipt} -> {:reapplied, entry.request_id}
                {:error, reason} -> {:failed, entry.request_id, reason}
              end

            _workspace_id ->
              {:would_reapply, entry.request_id}
          end
        end)

      {:ok,
       %{
         ledger_entries: length(entries),
         actionable: length(actionable),
         absent: Enum.count(results, &match?({:absent, _request_id}, &1)),
         would_reapply: Enum.count(results, &match?({:would_reapply, _request_id}, &1)),
         reapplied: Enum.count(results, &match?({:reapplied, _request_id}, &1)),
         failed: Enum.count(results, &match?({:failed, _request_id, _reason}, &1)),
         request_ids: Enum.map(results, &elem(&1, 1))
       }}
    end
  end

  defp halt_execution(scope, workspace, user, now) do
    monitors =
      Monitor
      |> where([monitor], monitor.workspace_id == ^workspace.id)
      |> Repo.all()

    Enum.each(monitors, fn monitor ->
      _cancelled_runs = Captures.cancel_monitor_runs(scope, monitor.id)
    end)

    Monitor
    |> where([monitor], monitor.workspace_id == ^workspace.id and monitor.state == :active)
    |> Repo.update_all(
      set: [
        state: :paused,
        state_changed_at: now,
        next_run_at: nil,
        pause_reason: :workspace_closed,
        capacity_wait_reason: nil,
        capacity_retry_at: nil,
        capacity_intended_at: nil,
        coverage_interrupted_at: nil,
        updated_at: now
      ]
    )

    ProviderCredential
    |> where(
      [credential],
      credential.workspace_id == ^workspace.id and
        credential.status in ^@closable_credential_statuses
    )
    |> Repo.update_all(
      set: [status: :revoked, revoked_at: now, revoked_by_user_id: user.id, updated_at: now]
    )

    Invitation
    |> where(
      [invitation],
      invitation.workspace_id == ^workspace.id and invitation.status == :pending
    )
    |> Repo.update_all(set: [status: :revoked, revoked_at: now, updated_at: now])

    cancel_background_jobs(workspace.id)
    :ok
  end

  defp cancel_background_jobs(workspace_id) do
    delivery_ids =
      Delivery
      |> where([delivery], delivery.workspace_id == ^workspace_id)
      |> select([delivery], delivery.id)
      |> Repo.all()

    if delivery_ids != [] do
      query =
        from job in Oban.Job,
          where:
            fragment(
              "?->>'delivery_id' = ANY(?)",
              job.args,
              type(^delivery_ids, {:array, :string})
            )

      _cancelled = Oban.cancel_all_jobs(query)
    end

    rescore_run_ids =
      RescoreRun
      |> join(:inner, [run], contract in ContractVersion,
        on: contract.id == run.contract_version_id
      )
      |> where(
        [run, contract],
        contract.workspace_id == ^workspace_id and run.status in [:pending, :running]
      )
      |> select([run], run.id)
      |> Repo.all()

    if rescore_run_ids != [] do
      query =
        from job in Oban.Job,
          where:
            fragment(
              "?->>'rescore_run_id' = ANY(?)",
              job.args,
              type(^rescore_run_ids, {:array, :string})
            )

      _cancelled = Oban.cancel_all_jobs(query)

      Enum.each(rescore_run_ids, fn run_id ->
        {:ok, :ok} = Rescorer.fail_infrastructure(run_id, :workspace_closed)
      end)
    end

    :ok
  end

  defp insert_receipt(workspace, mode, requested_at, purge_due_at) do
    %DeletionReceipt{}
    |> DeletionReceipt.pending_changeset(%{
      request_id: Ecto.UUID.generate(),
      workspace_fingerprint: workspace_fingerprint(workspace.id),
      request_type: mode,
      requested_at: requested_at,
      purge_due_at: purge_due_at
    })
    |> Repo.insert()
  end

  defp pending_receipt(workspace, request_type) do
    fingerprint = workspace_fingerprint(workspace.id)

    DeletionReceipt
    |> where(
      [receipt],
      receipt.workspace_fingerprint == ^fingerprint and receipt.request_type == ^request_type and
        receipt.status == :pending
    )
    |> order_by([receipt], desc: receipt.requested_at)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp purge_due_workspace_id(workspace_id, now) do
    Repo.transaction(fn ->
      with %Workspace{} = workspace <- lock_workspace(workspace_id),
           :ok <- purgeable?(workspace, now),
           %DeletionReceipt{} = receipt <- pending_receipt(workspace, request_type(workspace)) do
        purge_locked_workspace!(workspace, receipt, now)
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp purge_locked_workspace!(workspace, receipt, now) do
    user_ids = workspace_user_ids(workspace.id)
    enable_customer_purge!()
    remove_workspace_data!(workspace.id)
    remove_unowned_users!(user_ids)

    if receipt.status != :completed do
      receipt
      |> DeletionReceipt.complete_changeset(now)
      |> Repo.update!()
    end

    %{request_id: receipt.request_id, completed_at: receipt.completed_at || now}
  end

  defp ledger_entry_actionable?(%{status: :completed}, _now), do: true

  defp ledger_entry_actionable?(%{purge_due_at: purge_due_at}, now) do
    DateTime.compare(purge_due_at, now) in [:lt, :eq]
  end

  defp workspace_id_for_fingerprint(fingerprint) do
    Workspace
    |> select([workspace], workspace.id)
    |> Repo.all()
    |> Enum.find(fn workspace_id ->
      Plug.Crypto.secure_compare(workspace_fingerprint(workspace_id), fingerprint)
    end)
  end

  defp reconcile_workspace_deletion(workspace_id, entry, now) do
    Repo.transaction(fn ->
      with %Workspace{} = workspace <- lock_workspace(workspace_id),
           :ok <- verify_workspace_fingerprint(workspace, entry.workspace_fingerprint),
           {:ok, receipt} <- ensure_authoritative_receipt(entry),
           {:ok, closed} <- ensure_workspace_closed_for_reconciliation(workspace, entry) do
        purge_locked_workspace!(closed, receipt, now)
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp verify_workspace_fingerprint(workspace, fingerprint) do
    if Plug.Crypto.secure_compare(workspace_fingerprint(workspace.id), fingerprint),
      do: :ok,
      else: {:error, :workspace_fingerprint_mismatch}
  end

  defp ensure_authoritative_receipt(entry) do
    case Repo.get_by(DeletionReceipt, request_id: entry.request_id) do
      nil ->
        %DeletionReceipt{}
        |> DeletionReceipt.pending_changeset(%{
          request_id: entry.request_id,
          workspace_fingerprint: entry.workspace_fingerprint,
          request_type: entry.request_type,
          requested_at: entry.requested_at,
          purge_due_at: entry.purge_due_at
        })
        |> Repo.insert()

      %DeletionReceipt{} = receipt ->
        if receipt.workspace_fingerprint == entry.workspace_fingerprint and
             receipt.request_type == entry.request_type do
          {:ok, receipt}
        else
          {:error, :receipt_identity_mismatch}
        end
    end
  end

  defp ensure_workspace_closed_for_reconciliation(
         %Workspace{status: :closed} = workspace,
         _entry
       ),
       do: {:ok, workspace}

  defp ensure_workspace_closed_for_reconciliation(%Workspace{status: :active} = workspace, entry) do
    with {%Membership{} = membership, %User{} = owner} <- first_owner(workspace.id),
         scope <- Scope.for_workspace(owner, workspace, membership),
         :ok <- halt_execution(scope, workspace, owner, entry.requested_at) do
      workspace
      |> Workspace.close_changeset(
        owner,
        entry.request_type,
        entry.requested_at,
        entry.purge_due_at
      )
      |> Repo.update()
    else
      nil -> {:error, :owner_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_workspace_closed_for_reconciliation(%Workspace{}, _entry),
    do: {:error, :workspace_unavailable}

  defp first_owner(workspace_id) do
    Membership
    |> join(:inner, [membership], user in assoc(membership, :user))
    |> where(
      [membership, _user],
      membership.workspace_id == ^workspace_id and membership.role == :owner
    )
    |> order_by([membership, _user], asc: membership.inserted_at, asc: membership.id)
    |> select([membership, user], {membership, user})
    |> limit(1)
    |> Repo.one()
  end

  defp workspace_fingerprint(workspace_id) do
    key = Application.fetch_env!(:silent_regression, :deletion_receipt_hmac_key)
    :crypto.mac(:hmac, :sha256, key, workspace_id)
  end

  defp lock_workspace(workspace_id) do
    Workspace
    |> where([workspace], workspace.id == ^workspace_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_workspace_by_slug(slug) do
    Workspace |> where([workspace], workspace.slug == ^slug) |> lock("FOR UPDATE") |> Repo.one()
  end

  defp owner_by_email(workspace_id, email) do
    User
    |> join(:inner, [user], membership in Membership, on: membership.user_id == user.id)
    |> where(
      [user, membership],
      membership.workspace_id == ^workspace_id and membership.role == :owner and
        user.email == ^String.trim(email)
    )
    |> Repo.one()
  end

  defp reopenable?(%Workspace{status: :closed, deletion_requested_at: nil} = workspace, now) do
    if DateTime.before?(now, workspace.purge_after), do: :ok, else: {:error, :retention_expired}
  end

  defp reopenable?(%Workspace{status: :closed}, _now), do: {:error, :deletion_is_irreversible}
  defp reopenable?(%Workspace{}, _now), do: {:error, :not_closed}

  defp purgeable?(%Workspace{status: :closed} = workspace, now) do
    if due?(workspace, now), do: :ok, else: {:error, :retention_active}
  end

  defp purgeable?(%Workspace{}, _now), do: {:error, :not_closed}

  defp due?(%Workspace{purge_after: purge_after}, now) do
    DateTime.compare(purge_after, now) in [:lt, :eq]
  end

  defp request_type(%Workspace{deletion_requested_at: nil}), do: :closure_retention
  defp request_type(%Workspace{}), do: :explicit_request

  defp purge_after(:closure_retention, now), do: DateTime.add(now, @closure_retention_days, :day)
  defp purge_after(:explicit_request, now), do: now

  defp workspace_user_ids(workspace_id) do
    Membership
    |> where([membership], membership.workspace_id == ^workspace_id)
    |> select([membership], membership.user_id)
    |> Repo.all()
  end

  defp enable_customer_purge! do
    Repo.query!("SELECT set_config('silent_regression.customer_purge', 'on', true)")
  end

  defp remove_workspace_data!(workspace_id) do
    statements = [
      """
      DELETE FROM oban_jobs WHERE
        args->>'capture_run_id' IN (SELECT id::text FROM capture_runs WHERE workspace_id = $1) OR
        args->>'delivery_id' IN (SELECT id::text FROM notification_deliveries WHERE workspace_id = $1) OR
        args->>'rescore_run_id' IN (
          SELECT run.id::text FROM contract_rescore_runs AS run
          JOIN contract_versions AS contract ON contract.id = run.contract_version_id
          WHERE contract.workspace_id = $1
        )
      """,
      "UPDATE capture_runs SET baseline_snapshot_id = NULL WHERE workspace_id = $1",
      "UPDATE result_alerts SET resolution_review_decision_id = NULL WHERE workspace_id = $1",
      """
      DELETE FROM review_contract_revision_origins WHERE review_decision_id IN
        (SELECT id FROM review_decisions WHERE workspace_id = $1)
      """,
      "DELETE FROM review_decisions WHERE workspace_id = $1",
      "DELETE FROM notification_deliveries WHERE workspace_id = $1",
      "DELETE FROM result_alerts WHERE workspace_id = $1",
      "DELETE FROM result_incidents WHERE workspace_id = $1",
      """
      DELETE FROM baseline_members WHERE baseline_snapshot_id IN
        (SELECT id FROM baseline_snapshots WHERE workspace_id = $1)
      """,
      "DELETE FROM baseline_snapshots WHERE workspace_id = $1",
      """
      DELETE FROM contract_rescore_items WHERE contract_rescore_run_id IN
        (SELECT run.id FROM contract_rescore_runs AS run
          JOIN contract_versions AS contract ON contract.id = run.contract_version_id
          WHERE contract.workspace_id = $1)
      """,
      """
      DELETE FROM contract_rescore_runs WHERE contract_version_id IN
        (SELECT id FROM contract_versions WHERE workspace_id = $1)
      """,
      "DELETE FROM capture_runs WHERE workspace_id = $1",
      """
      DELETE FROM contract_rescore_summaries WHERE contract_version_id IN
        (SELECT id FROM contract_versions WHERE workspace_id = $1)
      """,
      """
      DELETE FROM contract_fixtures WHERE contract_version_id IN
        (SELECT id FROM contract_versions WHERE workspace_id = $1)
      """,
      """
      DELETE FROM contract_coverage_waivers WHERE contract_version_id IN
        (SELECT id FROM contract_versions WHERE workspace_id = $1)
      """,
      "DELETE FROM contract_versions WHERE workspace_id = $1",
      "DELETE FROM monitor_setups WHERE workspace_id = $1",
      "DELETE FROM product_events WHERE workspace_id = $1",
      "DELETE FROM monitors WHERE workspace_id = $1",
      "DELETE FROM provider_credentials WHERE workspace_id = $1",
      "DELETE FROM notification_preferences WHERE workspace_id = $1",
      "DELETE FROM pilot_policies WHERE workspace_id = $1",
      "DELETE FROM workspace_invitations WHERE workspace_id = $1",
      "DELETE FROM audit_events WHERE workspace_id = $1",
      "DELETE FROM workspace_memberships WHERE workspace_id = $1",
      "DELETE FROM workspaces WHERE id = $1"
    ]

    Enum.each(statements, &Repo.query!(&1, [Ecto.UUID.dump!(workspace_id)]))
  end

  defp remove_unowned_users!([]), do: :ok

  defp remove_unowned_users!(user_ids) do
    dumped_ids = Enum.map(user_ids, &Ecto.UUID.dump!/1)

    Repo.query!(
      """
      DELETE FROM audit_events WHERE actor_user_id = ANY($1::uuid[]) AND NOT EXISTS (
        SELECT 1 FROM workspace_memberships WHERE user_id = audit_events.actor_user_id
      )
      """,
      [dumped_ids]
    )

    Repo.query!(
      """
      DELETE FROM users AS candidate WHERE candidate.id = ANY($1::uuid[]) AND NOT EXISTS (
        SELECT 1 FROM workspace_memberships WHERE user_id = candidate.id
      )
      """,
      [dumped_ids]
    )

    :ok
  end
end
