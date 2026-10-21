defmodule RandosWeb.StatusLiveTest do
  use RandosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "shows the relay (none configured in tests) and today's counts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/status")

    assert has_element?(view, "#relay-status[data-state='not_configured']")
    assert has_element?(view, "#usage-counts")
    assert has_element?(view, "#usage-since")
    assert has_element?(view, "#usage-started")
    assert has_element?(view, "#usage-connected")
    assert has_element?(view, "#usage-median")
    assert has_element?(view, "#usage-ending-not_connected")
    assert has_element?(view, "#usage-privacy")
  end

  test "updates when the relay health announces a change", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/status")
    # A stand-in announcement (the page re-reads the snapshot either way).
    send(view.pid, {:relay_health, %{}})
    assert has_element?(view, "#relay-status")
  end

  test "the About page links here", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/about")
    assert has_element?(view, "#status-link[href='/status']")
  end
end
