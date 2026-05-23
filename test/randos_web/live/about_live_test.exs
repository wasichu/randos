defmodule RandosWeb.AboutLiveTest do
  use RandosWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders a minimal public about page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/about")

    assert has_element?(view, "h1", "About Randos")
    assert has_element?(view, "img[src='/images/logo.svg']")
    assert has_element?(view, "a[href='/about']", "About")
    assert has_element?(view, "#theme-toggle[data-theme-toggle]")
  end

  test "links to the about page from the app header", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "a[href='/about']", "About")
  end
end
