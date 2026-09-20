defmodule SilentRegression.Notifications.AlertEmail do
  @moduledoc false

  import Swoosh.Email

  alias SilentRegression.Accounts.User
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.RunResults.Alert
  alias SilentRegressionWeb.PublicMetadata

  def build(%Alert{} = alert, %Monitor{} = monitor, %User{} = recipient, workspace_slug) do
    link =
      PublicMetadata.absolute_url(
        "/app/#{workspace_slug}/monitors/#{monitor.id}/runs/#{alert.capture_run_id}"
      )

    new()
    |> to(recipient.email)
    |> from(Application.fetch_env!(:silent_regression, :notification_email_from))
    |> subject("#{severity_label(alert.severity)} alert for #{monitor.name}")
    |> text_body("""
    An actionable monitor alert is ready for review.

    Monitor: #{monitor.name}
    Category: #{category_label(alert.category)}
    Severity: #{severity_label(alert.severity)}

    Review the authenticated evidence:
    #{link}

    This email intentionally excludes prompts, contexts, outputs, and rule evidence.
    """)
  end

  defp category_label(:contract_failure), do: "Deterministic contract failure"
  defp category_label(:case_expectation_failure), do: "Case-specific expectation failure"
  defp category_label(:operational_anomaly), do: "Operational anomaly"
  defp severity_label(:critical), do: "Critical"
  defp severity_label(:warning), do: "Warning"
end
