defmodule SilentRegressionWeb.PageControllerTest do
  use SilentRegressionWeb.ConnCase

  test "GET / explains the deterministic wedge and its limitations", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, "#hero h1") |> LazyHTML.text() =~
             "LLM output contract quietly breaks"

    assert LazyHTML.query(document, "#workflows") |> LazyHTML.text() =~
             "Structured extraction"

    assert LazyHTML.query(document, "#limitations") |> LazyHTML.text() =~
             "does not claim semantic understanding"

    evidence_example = LazyHTML.query(document, "#contract-evidence-example") |> LazyHTML.text()

    assert evidence_example =~ "configured fact needs an approved trailing source"
    assert evidence_example =~ "[policy-7]"
    refute evidence_example =~ "every factual claim"

    assert LazyHTML.attribute(
             LazyHTML.query(document, "a[href='/design-partner/apply']"),
             "href"
           ) != []
  end

  test "public pages contain canonical, description, Open Graph, and index metadata", %{
    conn: conn
  } do
    for path <- [~p"/", ~p"/security", ~p"/privacy", ~p"/terms", ~p"/design-partner/apply"] do
      html = conn |> recycle() |> get(path) |> html_response(200)
      document = LazyHTML.from_document(html)

      assert [_description] =
               document
               |> LazyHTML.query("meta[name='description']")
               |> LazyHTML.attribute("content")

      assert [canonical] =
               document |> LazyHTML.query("link[rel='canonical']") |> LazyHTML.attribute("href")

      assert String.ends_with?(canonical, path)

      assert ["index,follow"] =
               document |> LazyHTML.query("meta[name='robots']") |> LazyHTML.attribute("content")

      assert [_title] =
               document
               |> LazyHTML.query("meta[property='og:title']")
               |> LazyHTML.attribute("content")

      assert [^canonical] =
               document
               |> LazyHTML.query("meta[property='og:url']")
               |> LazyHTML.attribute("content")
    end
  end

  test "security and legal pages state their current alpha boundary", %{conn: conn} do
    security = conn |> get(~p"/security") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(security, "#security-page") |> LazyHTML.text() =~
             "without compliance theater"

    privacy = conn |> recycle() |> get(~p"/privacy") |> html_response(200)
    terms = conn |> recycle() |> get(~p"/terms") |> html_response(200)

    assert privacy =~ "Draft—legal review required"
    assert terms =~ "Draft—legal review required"
  end
end
