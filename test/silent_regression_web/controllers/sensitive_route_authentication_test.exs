defmodule SilentRegressionWeb.SensitiveRouteAuthenticationTest do
  use SilentRegressionWeb.ConnCase, async: true

  @stale_authenticated_at DateTime.add(DateTime.utc_now(:second), -11, :minute)

  setup :register_and_log_in_workspace

  @tag token_authenticated_at: @stale_authenticated_at
  test "credential lifecycle mutations require recent primary authentication", %{
    user: user,
    workspace: workspace
  } do
    credential_id = Ecto.UUID.generate()
    base = "/app/#{workspace.slug}/credentials"

    requests = [
      {:post, base, %{"provider_credential" => %{}}},
      {:post, "#{base}/#{credential_id}/validate", %{}},
      {:post, "#{base}/#{credential_id}/rotate", %{"provider_credential" => %{}}},
      {:post, "#{base}/#{credential_id}/activate-replacement", %{}},
      {:delete, "#{base}/#{credential_id}", %{}}
    ]

    assert_recent_authentication_required(user, requests, base)
  end

  @tag token_authenticated_at: @stale_authenticated_at
  test "provider-call and future-spend mutations require recent primary authentication", %{
    user: user,
    workspace: workspace
  } do
    monitor_id = Ecto.UUID.generate()
    base = "/app/#{workspace.slug}/monitors/#{monitor_id}"
    return_to = "#{base}/operations"

    requests = [
      {:post, "#{base}/successor/validate-model", %{}},
      {:post, "#{base}/successor/activate", %{}},
      {:post, "#{base}/baseline/validate-model", %{}},
      {:post, "#{base}/baseline/authorize", %{}},
      {:patch, "#{base}/operations/schedule", %{"schedule" => %{"cadence" => "daily"}}},
      {:post, "#{base}/operations/run-now", %{}},
      {:post, "#{base}/operations/resume", %{}},
      {:post, "#{base}/operations/authentication-recovery", %{}}
    ]

    assert_recent_authentication_required(user, requests, return_to)
  end

  @tag token_authenticated_at: @stale_authenticated_at
  test "destructive workspace mutations require recent primary authentication", %{
    user: user,
    workspace: workspace
  } do
    return_to = "/app/#{workspace.slug}/settings/data"

    requests = [
      {:post, "#{return_to}/close", %{"confirmation" => workspace.slug}},
      {:post, "#{return_to}/delete", %{"confirmation" => workspace.slug}}
    ]

    assert_recent_authentication_required(user, requests, return_to)
  end

  test "read-only workspace evidence remains available without sudo mode", %{
    user: user,
    workspace: workspace
  } do
    stale_conn =
      build_conn()
      |> log_in_user(user, token_authenticated_at: @stale_authenticated_at)
      |> get("/app/#{workspace.slug}/credentials")

    assert html_response(stale_conn, 200)
  end

  defp assert_recent_authentication_required(user, requests, return_to) do
    Enum.each(requests, fn {method, path, params} ->
      response =
        build_conn()
        |> log_in_user(user, token_authenticated_at: @stale_authenticated_at)
        |> put_req_header("referer", "http://www.example.com#{return_to}")
        |> perform_request(method, path, params)

      assert redirected_to(response) == ~p"/users/log-in"
      assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "re-authenticate"
      assert get_session(response, :user_return_to) == return_to
    end)
  end

  defp perform_request(conn, :post, path, params), do: post(conn, path, params)
  defp perform_request(conn, :patch, path, params), do: patch(conn, path, params)
  defp perform_request(conn, :delete, path, params), do: delete(conn, path, params)
end
