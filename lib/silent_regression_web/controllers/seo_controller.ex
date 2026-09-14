defmodule SilentRegressionWeb.SEOController do
  use SilentRegressionWeb, :controller

  alias SilentRegressionWeb.PublicMetadata

  @public_paths ["/", "/security", "/privacy", "/terms", "/design-partner/apply"]

  def robots(conn, _params) do
    body = """
    User-agent: *
    Allow: /
    Disallow: /app
    Disallow: /dev
    Disallow: /design-partner/apply/thanks

    Sitemap: #{PublicMetadata.absolute_url("/sitemap.xml")}
    """

    text(conn, body)
  end

  def sitemap(conn, _params) do
    urls =
      Enum.map_join(@public_paths, "\n", fn path ->
        "    <url><loc>#{PublicMetadata.absolute_url(path)}</loc></url>"
      end)

    body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{urls}
    </urlset>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(:ok, body)
  end
end
