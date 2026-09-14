defmodule SilentRegressionWeb.SEOControllerTest do
  use SilentRegressionWeb.ConnCase, async: true

  alias SilentRegressionWeb.PublicMetadata

  test "GET /robots.txt allows public pages and excludes product/private routes", %{conn: conn} do
    body = conn |> get(~p"/robots.txt") |> response(200)

    assert body =~ "Allow: /"
    assert body =~ "Disallow: /app"
    assert body =~ "Disallow: /design-partner/apply/thanks"
    assert body =~ "Sitemap: #{PublicMetadata.absolute_url("/sitemap.xml")}"
  end

  test "GET /sitemap.xml contains only indexable public pages", %{conn: conn} do
    conn = get(conn, ~p"/sitemap.xml")
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") == ["application/xml; charset=utf-8"]

    for path <- ["/", "/security", "/privacy", "/terms", "/design-partner/apply"] do
      assert body =~ "<loc>#{PublicMetadata.absolute_url(path)}</loc>"
    end

    refute body =~ "<loc>#{PublicMetadata.absolute_url("/app")}</loc>"
    refute body =~ "<loc>#{PublicMetadata.absolute_url("/design-partner/apply/thanks")}</loc>"
  end
end
