defmodule SilentRegression.RateLimits.Bucket do
  @moduledoc """
  A fixed-window counter keyed only by an HMAC digest of the request subject.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rate_limit_buckets" do
    field :action, Ecto.Enum,
      values: [
        login: "login",
        invitation_acceptance: "invitation_acceptance",
        credential_validation: "credential_validation",
        run_authorization: "run_authorization"
      ]

    field :subject_hash, :binary
    field :window_started_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :hits, :integer

    timestamps(type: :utc_datetime_usec)
  end
end
