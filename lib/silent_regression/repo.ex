defmodule SilentRegression.Repo do
  use Ecto.Repo,
    otp_app: :silent_regression,
    adapter: Ecto.Adapters.Postgres
end
