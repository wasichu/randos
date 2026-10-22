defmodule RandosWeb.TranslationsLiveTest do
  use RandosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RandosWeb.Translations

  test "About links here", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/about")
    assert has_element?(view, "#fix-translation-link[href='/translations']")
  end

  test "in English there's nothing to fix: only the language picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/translations")
    assert has_element?(view, "#translation-pick")
    assert has_element?(view, "#translation-lang-es")
    refute has_element?(view, "#translation-en")
    refute has_element?(view, "#translations-list")
  end

  test "a language lists every string with a link to fix it on GitHub", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/translations?lang=ar")
    entries = Translations.entries("ar")
    assert entries != []
    assert has_element?(view, "#translation-lang-ar[aria-current='page']")
    assert has_element?(view, "#translation-#{length(entries) - 1}")

    [href] =
      view
      |> element("#suggest-0")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("href")

    %URI{host: "github.com", path: "/wasichu/randos/issues/new", query: query} = URI.parse(href)
    params = URI.decode_query(query)

    assert %{"template" => "translation.yml", "labels" => "translation", "locale" => "ar"} =
             params

    assert params["english"] == hd(entries).msgid
    assert params["current"] == hd(entries).msgstr
    refute Map.has_key?(params, "fix")
  end

  test "a button's context goes with it, so the fix finds the right entry" do
    entry = Enum.find(Translations.entries("es"), &(&1.msgctxt == "button"))

    params =
      "es"
      |> Translations.suggest_url(entry)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert params["context"] == "button"
  end

  test "the search narrows the list by English or translation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/translations?lang=es")
    entry = Enum.find(Translations.entries("es"), &(&1.msgctxt == "button"))

    view |> form("#translation-filter", %{query: entry.msgid}) |> render_change()
    assert has_element?(view, "#translations-list li")

    view |> form("#translation-filter", %{query: "zzz no such phrase"}) |> render_change()
    assert has_element?(view, "#translation-none")
    refute has_element?(view, "#translations-list li")
  end

  test "an unknown language falls back to the picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/translations?lang=xx")
    assert has_element?(view, "#translation-pick")
  end
end
