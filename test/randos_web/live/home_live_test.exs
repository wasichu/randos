defmodule RandosWeb.HomeLiveTest do
  use RandosWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the product skeleton and disables search until the acknowledgment is checked", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#conversation-form")
    assert has_element?(view, "#find-rando-button[disabled]")

    view
    |> form("#conversation-form",
      conversation: %{
        speaking_language: "en",
        listening_language: "es",
        adult_acknowledgment: "true"
      }
    )
    |> render_change()

    refute has_element?(view, "#find-rando-button[disabled]")
  end

  test "shows validation when searching without the adult acknowledgment", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#conversation-form",
      conversation: %{
        speaking_language: "en",
        listening_language: "es",
        adult_acknowledgment: "false"
      }
    )
    |> render_submit()

    assert has_element?(view, "#idle-panel")
    assert has_element?(view, "#matchmaking-error")
  end

  test "matches two compatible browser sessions and assigns roles", %{conn: conn} do
    {:ok, view_a, _html} = live(conn, ~p"/")

    view_a
    |> form("#conversation-form",
      conversation: %{
        speaking_language: "en",
        listening_language: "es",
        adult_acknowledgment: "true"
      }
    )
    |> render_submit()

    assert has_element?(view_a, "#looking-panel")

    {:ok, view_b, _html} = live(conn, ~p"/")

    view_b
    |> form("#conversation-form",
      conversation: %{
        speaking_language: "es",
        listening_language: "en",
        adult_acknowledgment: "true"
      }
    )
    |> render_submit()

    assert has_element?(view_b, "#connecting-panel")
    assert has_element?(view_b, "#match-role-label")

    render(view_a)
    assert has_element?(view_a, "#connecting-panel")
    assert has_element?(view_a, "#match-role-label")
  end

  test "can leave the queue before a match", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#conversation-form",
      conversation: %{
        speaking_language: "en",
        listening_language: "es",
        adult_acknowledgment: "true"
      }
    )
    |> render_submit()

    assert has_element?(view, "#looking-panel")

    view |> element("#cancel-search-button") |> render_click()
    assert has_element?(view, "#idle-panel")
  end
end
