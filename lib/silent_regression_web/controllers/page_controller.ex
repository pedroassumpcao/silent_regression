defmodule SilentRegressionWeb.PageController do
  use SilentRegressionWeb, :controller

  alias SilentRegressionWeb.PublicMetadata

  def home(conn, _params) do
    render_public(conn, :home,
      page_title: "Deterministic monitoring for LLM workflows",
      meta_description:
        "Replay critical LLM workflows and catch failures in user-approved, deterministic output contracts.",
      canonical_path: ~p"/"
    )
  end

  def security(conn, _params) do
    render_public(conn, :security,
      page_title: "Security and data handling",
      meta_description:
        "Understand the planned private-alpha boundary for managed LLM replay, customer-provided credentials, and captured data.",
      canonical_path: ~p"/security"
    )
  end

  def privacy(conn, _params) do
    render_public(conn, :privacy,
      page_title: "Privacy notice",
      meta_description:
        "A plain-language placeholder describing the limited information collected for Silent Regression design-partner applications.",
      canonical_path: ~p"/privacy"
    )
  end

  def terms(conn, _params) do
    render_public(conn, :terms,
      page_title: "Private-alpha terms",
      meta_description:
        "Preliminary terms for evaluating Silent Regression through a controlled, invite-only private alpha.",
      canonical_path: ~p"/terms"
    )
  end

  defp render_public(conn, template, metadata) do
    conn
    |> PublicMetadata.assign(metadata)
    |> render(template)
  end
end
