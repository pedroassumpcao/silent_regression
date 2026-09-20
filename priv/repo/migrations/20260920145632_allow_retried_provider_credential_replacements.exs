defmodule SilentRegression.Repo.Migrations.AllowRetriedProviderCredentialReplacements do
  use Ecto.Migration

  def change do
    drop unique_index(:provider_credentials, [:supersedes_id])

    create unique_index(:provider_credentials, [:supersedes_id],
             where: "supersedes_id IS NOT NULL AND status <> 'revoked'"
           )
  end
end
