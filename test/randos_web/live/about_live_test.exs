defmodule RandosWeb.AboutLiveTest do
  use RandosWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Randos.Calls.Lifecycle

  test "renders a minimal public about page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/about")

    assert has_element?(view, "h1", "About randos")
    assert has_element?(view, "img[src='/images/logo.svg']")
    assert has_element?(view, "a[href='/about']", "About")
    assert has_element?(view, "a[href='https://github.com/wasichu/randos']", "View on GitHub")
    assert has_element?(view, "#theme-toggle[data-theme-toggle]")
    assert has_element?(view, "svg#about-illustration[aria-hidden='true']")
  end

  test "states the call length from the lifecycle, not hardcoded", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/about")

    minutes = div(Lifecycle.call_duration_seconds(), 60)
    max = div(Lifecycle.max_call_duration_seconds(), 60)
    assert has_element?(view, "#about-call-length", "lasts #{minutes} minutes")
    assert has_element?(view, "#about-call-length", "up to #{max} minutes")
  end

  test "links to the about page from the app header", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "a[href='/about']", "About")
  end
end
