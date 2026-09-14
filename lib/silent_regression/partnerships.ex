defmodule SilentRegression.Partnerships do
  @moduledoc """
  Public design-partner applications and their private-alpha qualification state.
  """

  alias Ecto.Changeset
  alias SilentRegression.Partnerships.DesignPartnerApplication
  alias SilentRegression.Repo

  @doc """
  Returns a changeset for rendering or validating a design-partner application.
  """
  def change_design_partner_application(application \\ %DesignPartnerApplication{}, attrs \\ %{}) do
    DesignPartnerApplication.application_changeset(application, attrs)
  end

  @doc """
  Persists a design-partner application.

  A case-insensitive duplicate email is treated as an idempotent submission. The
  public caller receives no signal that an address already exists.
  """
  def submit_design_partner_application(attrs) when is_map(attrs) do
    %DesignPartnerApplication{}
    |> DesignPartnerApplication.application_changeset(attrs)
    |> Repo.insert()
    |> normalize_duplicate_result()
  end

  defp normalize_duplicate_result({:error, %Changeset{} = changeset} = error) do
    if duplicate_email_error?(changeset), do: {:ok, :duplicate}, else: error
  end

  defp normalize_duplicate_result(result), do: result

  defp duplicate_email_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:work_email, {_message, metadata}} ->
        metadata[:constraint] == :unique and
          metadata[:constraint_name] == "design_partner_applications_work_email_index"

      _other ->
        false
    end)
  end
end
