defmodule SilentRegression.Notifications.CoverageEmail do
  @moduledoc false

  import Swoosh.Email

  alias SilentRegression.Accounts.User
  alias SilentRegression.Monitors.Monitor
  alias SilentRegression.Notifications.Delivery
  alias SilentRegressionWeb.PublicMetadata

  def build(
        %Delivery{} = delivery,
        %Monitor{} = monitor,
        %User{} = recipient,
        workspace_slug
      ) do
    link =
      PublicMetadata.absolute_url("/app/#{workspace_slug}/monitors/#{monitor.id}/operations")

    new()
    |> to(recipient.email)
    |> from(Application.fetch_env!(:silent_regression, :notification_email_from))
    |> subject("Monitoring coverage is waiting for #{monitor.name}")
    |> text_body("""
    A scheduled monitor check is waiting for temporary workspace capacity.

    Monitor: #{monitor.name}
    Reason: #{reason_label(delivery.coverage_reason)}
    Original UTC check: #{DateTime.to_iso8601(delivery.coverage_intended_at)}
    Automatic UTC retry: #{DateTime.to_iso8601(delivery.coverage_retry_at)}

    Review monitoring coverage:
    #{link}

    No prompt, context, output, case, or rule evidence is included in this email.
    """)
  end

  defp reason_label(:workspace_run_limit), do: "Daily workspace run limit reached"
  defp reason_label(:workspace_call_limit), do: "Daily workspace call limit reached"
end
