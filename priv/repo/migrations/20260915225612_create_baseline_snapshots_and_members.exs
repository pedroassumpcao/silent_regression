defmodule SilentRegression.Repo.Migrations.CreateBaselineSnapshotsAndMembers do
  use Ecto.Migration

  def change do
    create table(:baseline_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :authorization_key, :binary_id, null: false
      add :status, :string, null: false, default: "pending"
      add :approval_mode, :string
      add :approval_rationale, :text
      add :preview_fingerprint, :string, size: 64, null: false
      add :provider, :string, null: false
      add :requested_model, :string, null: false
      add :monitor_fingerprint, :string, size: 64, null: false
      add :case_set_fingerprint, :string, size: 64, null: false
      add :contract_fingerprint, :string, size: 64, null: false
      add :evaluator_engine_version, :string, null: false
      add :samples_per_case, :integer, null: false
      add :retry_limit, :integer, null: false
      add :planned_call_count, :integer, null: false
      add :maximum_call_count, :integer, null: false
      add :authorized_at, :utc_datetime_usec, null: false
      add :approved_at, :utc_datetime_usec
      add :superseded_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_id,
          references(:monitors, type: :binary_id, on_delete: :delete_all),
          null: false

      add :monitor_version_id,
          references(:monitor_versions, type: :binary_id),
          null: false

      add :contract_version_id,
          references(:contract_versions, type: :binary_id),
          null: false

      add :provider_credential_id,
          references(:provider_credentials, type: :binary_id),
          null: false

      add :capture_run_id,
          references(:capture_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :authorized_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :approved_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :rejected_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :superseded_by_id,
          references(:baseline_snapshots, type: :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:baseline_snapshots, [:authorization_key])
    create unique_index(:baseline_snapshots, [:capture_run_id])
    create index(:baseline_snapshots, [:workspace_id, :monitor_id, :inserted_at])
    create index(:baseline_snapshots, [:monitor_version_id])
    create index(:baseline_snapshots, [:contract_version_id])
    create index(:baseline_snapshots, [:preview_fingerprint])

    create unique_index(:baseline_snapshots, [:monitor_id],
             where: "status = 'pending'",
             name: :baseline_snapshots_one_pending_index
           )

    create unique_index(:baseline_snapshots, [:monitor_id],
             where: "status = 'approved'",
             name: :baseline_snapshots_one_approved_index
           )

    create constraint(:baseline_snapshots, :baseline_snapshots_status_check,
             check: "status IN ('pending', 'approved', 'superseded', 'rejected')"
           )

    create constraint(:baseline_snapshots, :baseline_snapshots_approval_mode_check,
             check: "approval_mode IS NULL OR approval_mode IN ('normal', 'exceptional')"
           )

    create constraint(:baseline_snapshots, :baseline_snapshots_provider_check,
             check: "provider IN ('openai', 'anthropic')"
           )

    create constraint(:baseline_snapshots, :baseline_snapshots_counts_check,
             check: """
             samples_per_case >= 1 AND samples_per_case <= 5 AND
             retry_limit >= 0 AND retry_limit <= 2 AND
             planned_call_count > 0 AND
             maximum_call_count >= planned_call_count AND
             maximum_call_count <= planned_call_count * (retry_limit + 1)
             """
           )

    create constraint(:baseline_snapshots, :baseline_snapshots_fingerprints_check,
             check: """
             preview_fingerprint ~ '^[0-9a-f]{64}$' AND
             monitor_fingerprint ~ '^[0-9a-f]{64}$' AND
             case_set_fingerprint ~ '^[0-9a-f]{64}$' AND
             contract_fingerprint ~ '^[0-9a-f]{64}$'
             """
           )

    create constraint(:baseline_snapshots, :baseline_snapshots_lifecycle_check,
             check: """
             (status = 'pending' AND approval_mode IS NULL AND approval_rationale IS NULL AND
               approved_at IS NULL AND approved_by_user_id IS NULL AND superseded_at IS NULL AND
               superseded_by_id IS NULL AND rejected_at IS NULL AND rejected_by_user_id IS NULL) OR
             (status = 'approved' AND approval_mode IS NOT NULL AND approved_at IS NOT NULL AND
               superseded_at IS NULL AND superseded_by_id IS NULL AND
               rejected_at IS NULL AND rejected_by_user_id IS NULL AND
               (approval_mode = 'normal' OR
                 (approval_mode = 'exceptional' AND approval_rationale IS NOT NULL AND
                   btrim(approval_rationale) <> ''))) OR
             (status = 'superseded' AND superseded_at IS NOT NULL AND superseded_by_id IS NOT NULL AND
               rejected_at IS NULL AND rejected_by_user_id IS NULL AND
               ((approval_mode IS NULL AND approval_rationale IS NULL AND approved_at IS NULL AND
                   approved_by_user_id IS NULL) OR
                 (approval_mode IS NOT NULL AND approved_at IS NOT NULL AND
                   (approval_mode = 'normal' OR
                     (approval_mode = 'exceptional' AND approval_rationale IS NOT NULL AND
                       btrim(approval_rationale) <> ''))))) OR
             (status = 'rejected' AND approval_mode IS NULL AND approval_rationale IS NULL AND
               approved_at IS NULL AND approved_by_user_id IS NULL AND superseded_at IS NULL AND
               superseded_by_id IS NULL AND rejected_at IS NOT NULL)
             """
           )

    create table(:baseline_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :position, :integer, null: false
      add :case_key, :string, null: false
      add :sample_index, :integer, null: false
      add :case_fingerprint, :string, size: 64, null: false
      add :request_fingerprint, :string, size: 64, null: false

      add :baseline_snapshot_id,
          references(:baseline_snapshots, type: :binary_id, on_delete: :delete_all),
          null: false

      add :capture_observation_id,
          references(:capture_observations, type: :binary_id),
          null: false

      add :case_version_id,
          references(:case_versions, type: :binary_id),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:baseline_members, [:baseline_snapshot_id, :capture_observation_id])
    create unique_index(:baseline_members, [:baseline_snapshot_id, :position])

    create unique_index(
             :baseline_members,
             [:baseline_snapshot_id, :case_version_id, :sample_index],
             name: :baseline_members_snapshot_case_sample_index
           )

    create constraint(:baseline_members, :baseline_members_position_check,
             check: "position >= 0 AND sample_index >= 0"
           )

    create constraint(:baseline_members, :baseline_members_fingerprints_check,
             check: """
             case_fingerprint ~ '^[0-9a-f]{64}$' AND
             request_fingerprint ~ '^[0-9a-f]{64}$'
             """
           )

    execute(
      """
      CREATE FUNCTION protect_baseline_snapshot_history()
      RETURNS trigger AS $$
      BEGIN
        IF ROW(
          NEW.authorization_key, NEW.preview_fingerprint, NEW.provider, NEW.requested_model,
          NEW.monitor_fingerprint, NEW.case_set_fingerprint, NEW.contract_fingerprint,
          NEW.evaluator_engine_version, NEW.samples_per_case, NEW.retry_limit,
          NEW.planned_call_count, NEW.maximum_call_count, NEW.authorized_at,
          NEW.workspace_id, NEW.monitor_id, NEW.monitor_version_id, NEW.contract_version_id,
          NEW.provider_credential_id, NEW.capture_run_id
        ) IS DISTINCT FROM ROW(
          OLD.authorization_key, OLD.preview_fingerprint, OLD.provider, OLD.requested_model,
          OLD.monitor_fingerprint, OLD.case_set_fingerprint, OLD.contract_fingerprint,
          OLD.evaluator_engine_version, OLD.samples_per_case, OLD.retry_limit,
          OLD.planned_call_count, OLD.maximum_call_count, OLD.authorized_at,
          OLD.workspace_id, OLD.monitor_id, OLD.monitor_version_id, OLD.contract_version_id,
          OLD.provider_credential_id, OLD.capture_run_id
        ) THEN
          RAISE EXCEPTION 'baseline authorization plan is immutable' USING ERRCODE = '23514';
        END IF;

        IF OLD.status = 'pending' AND NEW.status NOT IN ('pending', 'approved', 'superseded', 'rejected') THEN
          RAISE EXCEPTION 'invalid baseline lifecycle transition' USING ERRCODE = '23514';
        ELSIF OLD.status = 'approved' AND NEW.status NOT IN ('approved', 'superseded') THEN
          RAISE EXCEPTION 'invalid baseline lifecycle transition' USING ERRCODE = '23514';
        ELSIF OLD.status IN ('superseded', 'rejected') AND NEW.status <> OLD.status THEN
          RAISE EXCEPTION 'invalid baseline lifecycle transition' USING ERRCODE = '23514';
        END IF;

        IF OLD.status IN ('approved', 'superseded', 'rejected') AND ROW(
          NEW.approval_mode, NEW.approval_rationale, NEW.approved_at, NEW.rejected_at
        ) IS DISTINCT FROM ROW(
          OLD.approval_mode, OLD.approval_rationale, OLD.approved_at, OLD.rejected_at
        ) THEN
          RAISE EXCEPTION 'terminal baseline evidence is immutable' USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS protect_baseline_snapshot_history()"
    )

    execute(
      """
      CREATE TRIGGER baseline_snapshots_history_guard
      BEFORE UPDATE ON baseline_snapshots
      FOR EACH ROW EXECUTE FUNCTION protect_baseline_snapshot_history();
      """,
      "DROP TRIGGER IF EXISTS baseline_snapshots_history_guard ON baseline_snapshots"
    )

    execute(
      """
      CREATE FUNCTION protect_baseline_member_history()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'baseline membership is immutable' USING ERRCODE = '23514';
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS protect_baseline_member_history()"
    )

    execute(
      """
      CREATE TRIGGER baseline_members_history_guard
      BEFORE UPDATE ON baseline_members
      FOR EACH ROW EXECUTE FUNCTION protect_baseline_member_history();
      """,
      "DROP TRIGGER IF EXISTS baseline_members_history_guard ON baseline_members"
    )
  end
end
