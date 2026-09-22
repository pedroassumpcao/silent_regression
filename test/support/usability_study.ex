defmodule SilentRegression.UsabilityStudy do
  @moduledoc "Local-only Stage 6 setup. Compiled exclusively under MIX_ENV=test."
  alias SilentRegression.{
    Accounts,
    AccountsFixtures,
    ProviderCredentials,
    Repo,
    Workspaces,
    WorkspacesFixtures
  }

  alias SilentRegression.Accounts.Scope
  alias SilentRegression.Providers.{FakeOpenAI, FakeAnthropic, UsabilityOpenAI}

  @database "silent_regression_test_usability"
  @port 4010
  @model "gpt-5.6-luna"

  def model, do: @model

  def validate_environment!(environment, partition, repo, adapters, mailer) do
    unless environment == :test and partition == "_usability" and
             repo[:database] == @database and repo[:hostname] in ["localhost", "127.0.0.1"] and
             is_nil(repo[:url]) and is_nil(repo[:socket_dir]) and
             adapters == [openai: FakeOpenAI, anthropic: FakeAnthropic] and
             mailer[:adapter] == Swoosh.Adapters.Test do
      raise ArgumentError,
            "Study requires test environment, _usability partition, local isolated database and fake adapters/mailer."
    end

    :ok
  end

  def participant!(participant) do
    unless is_binary(participant) and Regex.match?(~r/\A[a-z][a-z0-9-]{1,23}\z/, participant),
      do:
        raise(
          ArgumentError,
          "Use a pseudonymous session ID such as p01 or rehearsal01 (2–24 characters)."
        )

    participant
  end

  def configure!(participant) do
    participant!(participant)

    if Process.whereis(SilentRegression.Supervisor),
      do: raise(ArgumentError, "Run with --no-start; do not reconfigure a running application.")

    repo = Application.fetch_env!(:silent_regression, Repo)

    validate_environment!(
      Mix.env(),
      System.get_env("MIX_TEST_PARTITION"),
      repo,
      Application.fetch_env!(:silent_regression, :provider_adapters),
      Application.fetch_env!(:silent_regression, SilentRegression.Mailer)
    )

    Application.put_env(
      :silent_regression,
      Repo,
      Keyword.put(repo, :pool, DBConnection.ConnectionPool)
    )

    Application.put_env(:silent_regression, :provider_adapters,
      openai: UsabilityOpenAI,
      anthropic: FakeAnthropic
    )

    Application.put_env(:silent_regression, :dns_cluster_query, :ignore)

    Application.put_env(:silent_regression, Oban,
      repo: Repo,
      engine: Oban.Engines.Basic,
      notifier: Oban.Notifiers.Postgres,
      testing: :disabled,
      queues: [capture: 2],
      plugins: [],
      cron: false
    )

    endpoint = Application.fetch_env!(:silent_regression, SilentRegressionWeb.Endpoint)

    Application.put_env(
      :silent_regression,
      SilentRegressionWeb.Endpoint,
      Keyword.merge(endpoint,
        server: true,
        watchers: [],
        http: [ip: {127, 0, 0, 1}, port: @port],
        url: [host: "127.0.0.1", port: @port, scheme: "http"]
      )
    )
  end

  def seed!(participant) do
    participant!(participant)

    unless Application.fetch_env!(:silent_regression, :provider_adapters)[:openai] ==
             UsabilityOpenAI,
           do: raise(ArgumentError, "Study adapter must be configured before seeding.")

    email = "#{participant}@usability.example.test"
    slug = "usability-#{participant}"

    Repo.transaction(fn ->
      case Accounts.get_user_by_email(email) do
        nil ->
          scope =
            WorkspacesFixtures.workspace_scope_fixture(%{
              email: email,
              workspace_slug: slug,
              workspace_name: "FAKE study — #{participant}"
            })

          AccountsFixtures.set_password(scope.user)

          {:ok, credential} =
            ProviderCredentials.create_credential(scope, %{
              provider: :openai,
              label: "FAKE study connection — no live calls",
              secret: "sk-usability-pass"
            })

          {:ok, _} =
            ProviderCredentials.validate_credential(scope, credential.id, %{model: @model})

          scope

        user ->
          {:ok, scope} = Workspaces.scope_for_slug(Scope.for_user(user), slug)
          scope
      end
    end)
    |> case do
      {:ok, scope} -> scope
      {:error, reason} -> raise "Study seeding failed: #{inspect(reason)}"
    end
  end

  def instructions(scope) do
    """
    FAKE-PROVIDER USABILITY STUDY — NO LIVE MODEL CALLS
    Local database: #{@database}; loopback only; capture workers only.
    Login: http://127.0.0.1:#{@port}/users/log-in
    Fictional email: #{scope.user.email}
    Test-only password: #{AccountsFixtures.valid_user_password()}
    Start: http://127.0.0.1:#{@port}/app/#{scope.workspace.slug}/monitors
    Model label for task cards: #{@model} (simulated, not an availability claim)
    Same session ID resumes data; use a new ID for a fresh participant. Nothing is reset.
    Never enter real keys or customer data. Stop with Ctrl-C twice. Do not expose this server publicly.
    Study protocol: docs/monitor-setup/usability/README.md
    """
  end
end
