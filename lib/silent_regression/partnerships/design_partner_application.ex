defmodule SilentRegression.Partnerships.DesignPartnerApplication do
  @moduledoc """
  A prospective design partner's application to the private alpha.

  Submission fields are intentionally narrow. Operational metadata, credentials,
  prompts, and model outputs do not belong in this record.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers [:openai, :anthropic, :both]
  @statuses [:new, :contacted, :qualified, :invited, :declined, :withdrawn]

  schema "design_partner_applications" do
    field :name, :string
    field :work_email, :string
    field :company, :string
    field :role, :string
    field :workflow_description, :string
    field :current_problem, :string
    field :provider, Ecto.Enum, values: @providers
    field :feedback_willingness, :boolean
    field :status, Ecto.Enum, values: @statuses, default: :new

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @public_fields [
    :name,
    :work_email,
    :company,
    :role,
    :workflow_description,
    :current_problem,
    :provider,
    :feedback_willingness
  ]

  @doc """
  Builds a changeset for a public application submission.
  """
  def application_changeset(application, attrs) do
    application
    |> cast(attrs, @public_fields)
    |> normalize_text_fields()
    |> validate_required(@public_fields)
    |> validate_length(:name, max: 120)
    |> validate_length(:work_email, max: 320)
    |> validate_length(:company, max: 160)
    |> validate_length(:role, max: 160)
    |> validate_length(:workflow_description, min: 20, max: 2_000)
    |> validate_length(:current_problem, min: 20, max: 2_000)
    |> validate_format(:work_email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/u,
      message: "must be a valid work email"
    )
    |> unique_constraint(:work_email,
      name: :design_partner_applications_work_email_index,
      message: "has already been submitted"
    )
    |> check_constraint(:provider, name: :design_partner_applications_provider_check)
  end

  def providers, do: @providers
  def statuses, do: @statuses

  defp normalize_text_fields(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> update_change(:work_email, &(String.trim(&1) |> String.downcase()))
    |> update_change(:company, &String.trim/1)
    |> update_change(:role, &String.trim/1)
    |> update_change(:workflow_description, &String.trim/1)
    |> update_change(:current_problem, &String.trim/1)
  end
end
