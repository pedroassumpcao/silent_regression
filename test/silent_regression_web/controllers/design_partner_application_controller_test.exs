defmodule SilentRegressionWeb.DesignPartnerApplicationControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  alias SilentRegression.Partnerships.DesignPartnerApplication
  alias SilentRegression.Repo

  test "GET /design-partner/apply renders a server-submitted form with only approved fields", %{
    conn: conn
  } do
    html = conn |> get(~p"/design-partner/apply") |> html_response(200)
    document = LazyHTML.from_document(html)
    form = LazyHTML.query(document, "#design-partner-application-form")

    assert LazyHTML.attribute(form, "action") == [~p"/design-partner/apply"]
    assert LazyHTML.attribute(form, "method") == ["post"]

    assert LazyHTML.attribute(LazyHTML.query(form, "input, select, textarea"), "name")
           |> Enum.sort() ==
             Enum.sort([
               "_csrf_token",
               "design_partner_application[company]",
               "design_partner_application[current_problem]",
               "design_partner_application[feedback_willingness]",
               "design_partner_application[name]",
               "design_partner_application[provider]",
               "design_partner_application[role]",
               "design_partner_application[work_email]",
               "design_partner_application[workflow_description]"
             ])
  end

  test "POST /design-partner/apply persists a valid application and redirects", %{conn: conn} do
    conn =
      post(conn, ~p"/design-partner/apply", %{
        "design_partner_application" => valid_attributes()
      })

    assert redirected_to(conn) == ~p"/design-partner/apply/thanks"

    application = Repo.one!(DesignPartnerApplication)
    assert application.work_email == "ada@example.com"
    assert application.status == :new
  end

  test "POST /design-partner/apply returns accessible errors without persisting invalid data", %{
    conn: conn
  } do
    invalid_attributes =
      valid_attributes(%{"work_email" => "invalid", "current_problem" => "short"})

    html =
      conn
      |> post(~p"/design-partner/apply", %{
        "design_partner_application" => invalid_attributes
      })
      |> html_response(422)

    document = LazyHTML.from_document(html)

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#application-error-summary"),
             "role"
           ) == ["alert"]

    assert LazyHTML.query(document, "#design_partner_application_work_email")
           |> LazyHTML.attribute("value") == ["invalid"]

    assert Repo.aggregate(DesignPartnerApplication, :count) == 0
  end

  test "case-insensitive duplicate submissions receive the same redirect and stay singular", %{
    conn: conn
  } do
    assert conn
           |> post(~p"/design-partner/apply", %{
             "design_partner_application" => valid_attributes()
           })
           |> redirected_to() == ~p"/design-partner/apply/thanks"

    assert conn
           |> recycle()
           |> post(~p"/design-partner/apply", %{
             "design_partner_application" =>
               valid_attributes(%{"work_email" => "ADA@EXAMPLE.COM"})
           })
           |> redirected_to() == ~p"/design-partner/apply/thanks"

    assert Repo.aggregate(DesignPartnerApplication, :count) == 1
  end

  test "GET /design-partner/apply/thanks is not indexable", %{conn: conn} do
    html = conn |> get(~p"/design-partner/apply/thanks") |> html_response(200)
    document = LazyHTML.from_document(html)

    assert ["noindex,nofollow"] =
             document |> LazyHTML.query("meta[name='robots']") |> LazyHTML.attribute("content")
  end

  defp valid_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Ada Lovelace",
        "work_email" => "ada@example.com",
        "company" => "Analytical Engines",
        "role" => "Head of AI",
        "workflow_description" =>
          "We extract structured policy data from long customer documents.",
        "current_problem" =>
          "Provider updates can silently change required fields without obvious errors.",
        "provider" => "openai",
        "feedback_willingness" => "true"
      },
      overrides
    )
  end
end
