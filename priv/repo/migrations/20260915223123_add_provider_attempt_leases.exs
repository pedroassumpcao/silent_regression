defmodule SilentRegression.Repo.Migrations.AddProviderAttemptLeases do
  use Ecto.Migration

  def change do
    alter table(:provider_attempts) do
      add :lease_expires_at, :utc_datetime_usec, null: false
    end

    create index(:provider_attempts, [:status, :lease_expires_at])

    create constraint(:provider_attempts, :provider_attempts_lease_check,
             check: "lease_expires_at > started_at"
           )
  end
end
