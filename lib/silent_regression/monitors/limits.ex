defmodule SilentRegression.Monitors.Limits do
  @moduledoc false

  def fetch!(key) do
    :silent_regression
    |> Application.fetch_env!(:monitor_domain)
    |> Keyword.fetch!(key)
  end
end
