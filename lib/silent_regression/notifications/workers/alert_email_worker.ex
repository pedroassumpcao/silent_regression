defmodule SilentRegression.Notifications.Workers.AlertEmailWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [period: 2_592_000, fields: [:worker, :args]]

  alias SilentRegression.Notifications

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}}) do
    Notifications.deliver_alert_email(delivery_id)
  end
end
