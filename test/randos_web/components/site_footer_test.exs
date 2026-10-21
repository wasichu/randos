defmodule RandosWeb.SiteFooterTest do
  # Sets the app's :commit, so not async.
  use RandosWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:randos, :commit)
    on_exit(fn -> Application.put_env(:randos, :commit, original || "") end)
  end

  test "every page links the status page, the privacy doc, and the source", %{conn: conn} do
    Application.put_env(:randos, :commit, "")

    for path <- [~p"/", ~p"/about", ~p"/status"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#site-footer #footer-status[href='/status']")
      assert has_element?(view, "#footer-privacy[href$='/docs/privacy.md']")
      assert has_element?(view, "#footer-source[href='https://github.com/wasichu/randos']")
      # No commit known (development): none shown.
      refute has_element?(view, "#footer-commit")
    end
  end

  test "the deployed commit links to itself; uncommitted changes are said so", %{conn: conn} do
    Application.put_env(:randos, :commit, "abc1234")
    {:ok, view, _html} = live(conn, ~p"/about")
    assert has_element?(view, "#footer-commit[href$='/commit/abc1234']", "abc1234")

    Application.put_env(:randos, :commit, "abc1234-dirty")
    {:ok, view, _html} = live(conn, ~p"/about")
    assert has_element?(view, "#footer-commit[href$='/commit/abc1234']", "abc1234-dirty")
    assert has_element?(view, "#footer-commit[title*='not yet committed']")
  end

  test "the About page links the privacy doc", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/about")
    assert has_element?(view, "#privacy-link[href$='/docs/privacy.md']")
  end
end
