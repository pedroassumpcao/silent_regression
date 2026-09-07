defmodule SilentRegressionWeb.PageController do
  use SilentRegressionWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
