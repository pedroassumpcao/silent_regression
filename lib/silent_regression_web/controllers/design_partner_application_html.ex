defmodule SilentRegressionWeb.DesignPartnerApplicationHTML do
  @moduledoc """
  Server-rendered pages for the private-alpha design-partner application.
  """

  use SilentRegressionWeb, :html

  embed_templates "design_partner_application_html/*"
end
