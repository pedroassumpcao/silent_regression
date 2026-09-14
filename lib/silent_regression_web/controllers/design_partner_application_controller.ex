defmodule SilentRegressionWeb.DesignPartnerApplicationController do
  use SilentRegressionWeb, :controller

  alias SilentRegression.Partnerships
  alias SilentRegressionWeb.PublicMetadata

  def new(conn, _params) do
    form =
      Partnerships.change_design_partner_application()
      |> Phoenix.Component.to_form()

    conn
    |> assign_metadata()
    |> render(:new, form: form, has_errors: false)
  end

  def create(conn, %{"design_partner_application" => application_params}) do
    case Partnerships.submit_design_partner_application(application_params) do
      {:ok, _application_or_duplicate} ->
        redirect(conn, to: ~p"/design-partner/apply/thanks")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> assign_metadata()
        |> render(:new, form: Phoenix.Component.to_form(changeset), has_errors: true)
    end
  end

  def create(conn, _params) do
    create(conn, %{"design_partner_application" => %{}})
  end

  def thanks(conn, _params) do
    conn
    |> PublicMetadata.assign(
      page_title: "Application received",
      meta_description: "Your Silent Regression private-alpha application has been received.",
      canonical_path: ~p"/design-partner/apply/thanks",
      robots: "noindex,nofollow"
    )
    |> render(:thanks)
  end

  defp assign_metadata(conn) do
    PublicMetadata.assign(conn,
      page_title: "Apply for design-partner access",
      meta_description:
        "Tell us about a deterministic LLM workflow that would benefit from repeated, evidence-backed regression checks.",
      canonical_path: ~p"/design-partner/apply"
    )
  end
end
