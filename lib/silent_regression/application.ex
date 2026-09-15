defmodule SilentRegression.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SilentRegressionWeb.Telemetry,
      SilentRegression.Repo,
      {Oban, Application.fetch_env!(:silent_regression, Oban)},
      SilentRegression.Vault,
      {DNSCluster, query: Application.get_env(:silent_regression, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SilentRegression.PubSub},
      # Start a worker by calling: SilentRegression.Worker.start_link(arg)
      # {SilentRegression.Worker, arg},
      # Start to serve requests, typically the last entry
      SilentRegressionWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SilentRegression.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SilentRegressionWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
