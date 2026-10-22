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
    # The small-pairs rule sits behind the Languages spoken info icon.
    assert has_element?(view, "#usage-pairs #usage-pairs-info summary")
    assert has_element?(view, "#usage-pairs-info #usage-pairs-note")
  end

  test "updates when the relay health announces a change", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/status")
    # A stand-in announcement (the page re-reads the snapshot either way).
    send(view.pid, {:relay_health, %{}})
    assert has_element?(view, "#relay-status")
  end

  test "every page's header links here (an icon); the About page has no section for it", %{
    conn: conn
  } do
    for path <- [~p"/", ~p"/about"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#header-status-link[href='/status'] .hero-signal")
      # About is an icon too, so the toolbar is all icons (and the locale code).
      assert has_element?(
               view,
               "#header-about-link[href='/about'][title='About'] .hero-information-circle"
             )
    end

    {:ok, about, _html} = live(conn, ~p"/about")
    refute has_element?(about, "#about-status")
    assert has_element?(about, "#about-privacy #privacy-link")
  end
end
