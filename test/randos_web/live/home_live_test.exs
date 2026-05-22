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
    assert has_element?(view_a, "#connecting-panel[data-webrtc-role='offerer']")
    refute has_element?(view_a, "#call-countdown")

    assert eventually_has_element?(view_a, "#call-panel")
    assert has_element?(view_a, "#call-countdown")
    assert has_element?(view_a, "#webrtc-audio[data-webrtc-role='offerer']")
    assert has_element?(view_a, "#mute-button[disabled]")
    assert has_element?(view_a, "#remote-audio")
    refute has_element?(view_a, "#extension-countdown")
    assert has_element?(view_a, "#call-panel[data-webrtc-role='offerer']")

    view_a |> element("#time-up-button") |> render_click()
    assert eventually_has_element?(view_a, "#extension-panel")
    refute has_element?(view_a, "#call-countdown")
    assert has_element?(view_a, "#webrtc-audio[data-webrtc-role='offerer']")
    assert has_element?(view_a, "#extension-countdown")

    view_a |> element("#end-call-button") |> render_click()
    assert eventually_missing_element?(view_a, "#call-countdown")
    assert eventually_missing_element?(view_a, "#webrtc-audio")
    assert eventually_missing_element?(view_a, "#extension-countdown")
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
    refute has_element?(view, "#call-countdown")
    refute has_element?(view, "#extension-countdown")
  end

  defp eventually_has_element?(view, selector, attempts \\ 120)

  defp eventually_has_element?(_view, _selector, 0), do: false

  defp eventually_has_element?(view, selector, attempts) do
    if has_element?(view, selector) do
      true
    else
      Process.sleep(10)
      eventually_has_element?(view, selector, attempts - 1)
    end
  end

  defp eventually_missing_element?(view, selector, attempts \\ 120)

  defp eventually_missing_element?(_view, _selector, 0), do: false

  defp eventually_missing_element?(view, selector, attempts) do
    if has_element?(view, selector) do
      Process.sleep(10)
      eventually_missing_element?(view, selector, attempts - 1)
    else
      true
    end
  end
end
