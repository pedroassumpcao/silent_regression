defmodule SilentRegressionWeb.InertiaHelpers do
  @moduledoc """
  Helpers for rendering Inertia responses with server-owned page metadata.
  """

  import Inertia.Controller, only: [assign_prop: 3]

  def render_inertia(conn, component) do
    conn
    |> maybe_assign_page_title()
    |> Inertia.Controller.render_inertia(component)
  end

  def render_inertia(conn, component, inline_props) when is_map(inline_props) do
    conn
    |> maybe_assign_page_title()
    |> Inertia.Controller.render_inertia(component, inline_props)
  end

  def render_inertia(conn, component, opts) when is_list(opts) do
    conn
    |> maybe_assign_page_title()
    |> Inertia.Controller.render_inertia(component, opts)
  end

  def render_inertia(conn, component, inline_props, opts)
      when is_map(inline_props) and is_list(opts) do
    conn
    |> maybe_assign_page_title()
    |> Inertia.Controller.render_inertia(component, inline_props, opts)
  end

  defp maybe_assign_page_title(conn) do
    case conn.assigns[:page_title] do
      nil -> conn
      page_title -> assign_prop(conn, :page_title, page_title)
    end
  end
end
