defmodule SilentRegression.Repo.Migrations.CreateDesignPartnerApplications do
  use Ecto.Migration

  def change do
    create table(:design_partner_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :work_email, :string, null: false
      add :company, :string, null: false
      add :role, :string, null: false
      add :workflow_description, :text, null: false
      add :current_problem, :text, null: false
      add :provider, :string, null: false
      add :feedback_willingness, :boolean, null: false
      add :status, :string, null: false, default: "new"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:design_partner_applications, ["lower(work_email)"],
             name: :design_partner_applications_work_email_index
           )

    create index(:design_partner_applications, [:status, :inserted_at])

    create constraint(:design_partner_applications, :design_partner_applications_provider_check,
             check: "provider IN ('openai', 'anthropic', 'both')"
           )

    create constraint(:design_partner_applications, :design_partner_applications_status_check,
             check:
               "status IN ('new', 'contacted', 'qualified', 'invited', 'declined', 'withdrawn')"
           )
  end
end
