defmodule SilentRegression.PartnershipsTest do
  use SilentRegression.DataCase, async: true

  alias SilentRegression.Partnerships
  alias SilentRegression.Partnerships.DesignPartnerApplication

  describe "design-partner applications" do
    test "stores the approved public fields with normalized email and new status" do
      assert {:ok, application} =
               Partnerships.submit_design_partner_application(valid_attributes())

      assert application.name == "Ada Lovelace"
      assert application.work_email == "ada@example.com"
      assert application.provider == :openai
      assert application.feedback_willingness
      assert application.status == :new
    end

    test "does not allow public submission to set qualification status" do
      attrs = Map.put(valid_attributes(), "status", "invited")

      assert {:ok, application} = Partnerships.submit_design_partner_application(attrs)
      assert application.status == :new
    end

    test "returns validation errors for missing, malformed, or underspecified fields" do
      changeset = Partnerships.change_design_partner_application(%DesignPartnerApplication{}, %{})

      assert errors_on(changeset).name == ["can't be blank"]
      assert errors_on(changeset).provider == ["can't be blank"]

      invalid_attrs =
        valid_attributes(%{
          "work_email" => "not-an-email",
          "provider" => "unsupported",
          "workflow_description" => "Too short",
          "current_problem" => "Also short"
        })

      invalid_changeset =
        Partnerships.change_design_partner_application(
          %DesignPartnerApplication{},
          invalid_attrs
        )

      assert "must be a valid work email" in errors_on(invalid_changeset).work_email
      assert "is invalid" in errors_on(invalid_changeset).provider

      assert "should be at least 20 character(s)" in errors_on(invalid_changeset).workflow_description

      assert "should be at least 20 character(s)" in errors_on(invalid_changeset).current_problem
    end

    test "handles case-insensitive duplicate submissions without creating another record" do
      assert {:ok, first_application} =
               Partnerships.submit_design_partner_application(valid_attributes())

      duplicate_attrs = valid_attributes(%{"work_email" => " ADA@EXAMPLE.COM "})

      assert {:ok, :duplicate} =
               Partnerships.submit_design_partner_application(duplicate_attrs)

      assert Repo.aggregate(DesignPartnerApplication, :count) == 1
      assert first_application.work_email == "ada@example.com"
    end

    test "defines only the approved internal qualification statuses" do
      assert DesignPartnerApplication.statuses() == [
               :new,
               :contacted,
               :qualified,
               :invited,
               :declined,
               :withdrawn
             ]
    end
  end

  defp valid_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => " Ada Lovelace ",
        "work_email" => " ADA@EXAMPLE.COM ",
        "company" => " Analytical Engines ",
        "role" => " Head of AI ",
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
