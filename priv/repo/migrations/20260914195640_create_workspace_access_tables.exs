defmodule SilentRegression.Repo.Migrations.CreateWorkspaceAccessTables do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :citext, null: false
      add :status, :string, null: false, default: "active"
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :alpha_access, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspaces, [:slug])

    create constraint(:workspaces, :workspaces_status_check,
             check: "status IN ('active', 'suspended', 'closed')"
           )

    create table(:workspace_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_memberships, [:workspace_id, :user_id])
    create index(:workspace_memberships, [:user_id])

    create constraint(:workspace_memberships, :workspace_memberships_role_check,
             check: "role IN ('owner', 'member')"
           )

    create table(:workspace_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :role, :string, null: false
      add :token_hash, :binary, null: false
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime
      add :revoked_at, :utc_datetime

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :invited_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :accepted_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_invitations, [:token_hash])
    create index(:workspace_invitations, [:workspace_id, :status, :inserted_at])

    create unique_index(:workspace_invitations, [:workspace_id, :email],
             where: "status = 'pending'",
             name: :workspace_invitations_pending_email_index
           )

    create constraint(:workspace_invitations, :workspace_invitations_role_check,
             check: "role IN ('owner', 'member')"
           )

    create constraint(:workspace_invitations, :workspace_invitations_status_check,
             check: "status IN ('pending', 'accepted', 'revoked', 'expired')"
           )

    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime, null: false

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :nilify_all)

      add :actor_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_events, [:workspace_id, :occurred_at])
    create index(:audit_events, [:actor_user_id, :occurred_at])
    create index(:audit_events, [:action, :occurred_at])
  end
end
