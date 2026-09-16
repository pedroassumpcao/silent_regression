defmodule SilentRegression.RateLimitsTest do
  use SilentRegression.DataCase, async: true

  import Ecto.Query

  alias SilentRegression.RateLimits
  alias SilentRegression.RateLimits.Bucket
  alias SilentRegression.Repo

  test "atomically enforces a fixed window without storing the raw subject" do
    at = ~U[2026-09-16 20:20:30Z]
    subject = ["ip", "203.0.113.10", "person@example.com"]

    assert {:ok, %{hits: 1, limit: 2}} =
             RateLimits.check(:login, subject, at: at, limit: 2, window_seconds: 60)

    assert {:ok, %{hits: 2, limit: 2}} =
             RateLimits.check(:login, subject, at: at, limit: 2, window_seconds: 60)

    assert {:error, %{limit: 2, retry_after: 30}} =
             RateLimits.check(:login, subject, at: at, limit: 2, window_seconds: 60)

    assert {:ok, %{hits: 1}} =
             RateLimits.check(:login, ["ip", "203.0.113.11"],
               at: at,
               limit: 2,
               window_seconds: 60
             )

    assert [first, second] =
             Bucket
             |> order_by([bucket], asc: bucket.subject_hash)
             |> Repo.all()

    assert byte_size(first.subject_hash) == 32
    assert byte_size(second.subject_hash) == 32
    refute inspect([first, second]) =~ "person@example.com"
    refute inspect([first, second]) =~ "203.0.113"
  end

  test "a new fixed window accepts the same subject again" do
    subject = ["workspace", Ecto.UUID.generate()]

    assert {:ok, %{hits: 1}} =
             RateLimits.check(:run_authorization, subject,
               at: ~U[2026-09-16 20:00:00Z],
               limit: 1,
               window_seconds: 60
             )

    assert {:error, _state} =
             RateLimits.check(:run_authorization, subject,
               at: ~U[2026-09-16 20:00:59Z],
               limit: 1,
               window_seconds: 60
             )

    assert {:ok, %{hits: 1}} =
             RateLimits.check(:run_authorization, subject,
               at: ~U[2026-09-16 20:01:00Z],
               limit: 1,
               window_seconds: 60
             )
  end
end
