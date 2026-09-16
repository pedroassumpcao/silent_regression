defmodule SilentRegression.RateLimits do
  @moduledoc """
  Durable fixed-window limits with HMAC-only subjects for cross-node enforcement.
  """

  import Ecto.Query

  alias SilentRegression.RateLimits.Bucket
  alias SilentRegression.Repo

  @actions [:login, :invitation_acceptance, :credential_validation, :run_authorization]

  def check(action, subject_parts, options \\ [])

  def check(action, subject_parts, options)
      when action in @actions and is_list(subject_parts) do
    config = Keyword.fetch!(Application.fetch_env!(:silent_regression, :rate_limits), action)
    limit = Keyword.get(options, :limit, Keyword.fetch!(config, :limit))

    window_seconds =
      Keyword.get(options, :window_seconds, Keyword.fetch!(config, :window_seconds))

    at = Keyword.get(options, :at, DateTime.utc_now())
    window_started_at = window_start(at, window_seconds)
    expires_at = DateTime.add(window_started_at, window_seconds, :second)
    subject_hash = hash_subject(action, subject_parts)
    now = DateTime.utc_now()

    result =
      Repo.query!(
        """
        INSERT INTO rate_limit_buckets AS bucket (
          id, action, subject_hash, window_started_at, expires_at, hits, inserted_at, updated_at
        )
        VALUES ($1, $2, $3, $4, $5, 1, $6, $6)
        ON CONFLICT (action, subject_hash, window_started_at)
        DO UPDATE SET hits = bucket.hits + 1, updated_at = EXCLUDED.updated_at
        WHERE bucket.hits < $7
        RETURNING hits
        """,
        [
          Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          Atom.to_string(action),
          subject_hash,
          window_started_at,
          expires_at,
          now,
          limit
        ]
      )

    case result.rows do
      [[hits]] -> {:ok, %{hits: hits, limit: limit, resets_at: expires_at}}
      [] -> {:error, %{limit: limit, retry_after: max(DateTime.diff(expires_at, at), 1)}}
    end
  end

  @doc false
  def delete_expired(limit \\ 1000) when is_integer(limit) and limit > 0 do
    ids =
      Bucket
      |> where([bucket], bucket.expires_at < ^DateTime.utc_now())
      |> order_by([bucket], asc: bucket.expires_at)
      |> limit(^limit)
      |> select([bucket], bucket.id)

    Bucket
    |> where([bucket], bucket.id in subquery(ids))
    |> Repo.delete_all()
  end

  defp hash_subject(action, subject_parts) do
    normalized =
      subject_parts
      |> Enum.map(&normalize_part/1)
      |> Enum.join("\u0000")

    :crypto.mac(
      :hmac,
      :sha256,
      Application.fetch_env!(:silent_regression, :rate_limit_hmac_key),
      Atom.to_string(action) <> "\u0000" <> normalized
    )
  end

  defp normalize_part(value) when is_binary(value), do: String.trim(value)
  defp normalize_part(value), do: to_string(value)

  defp window_start(at, window_seconds) do
    unix = DateTime.to_unix(at, :second)
    DateTime.from_unix!(div(unix, window_seconds) * window_seconds, :second)
  end
end
