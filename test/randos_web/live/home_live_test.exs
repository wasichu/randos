defmodule RandosWeb.HomeLiveTest do
  use RandosWeb.ConnCase, async: true

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

  test "walks through the mocked conversation states", %{conn: conn} do
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

    view |> element("#mock-connect-button") |> render_click()
    assert has_element?(view, "#connecting-panel")

    view |> element("#enter-call-button") |> render_click()
    assert has_element?(view, "#call-panel")
    assert has_element?(view, "#local-waveform")
    assert has_element?(view, "#remote-waveform")

    view |> element("#time-up-button") |> render_click()
    assert has_element?(view, "#extension-panel")

    view |> element("#continue-call-button") |> render_click()
    assert has_element?(view, "#call-panel")

    view |> element("#hang-up-button") |> render_click()
    assert has_element?(view, "#idle-panel")
  end
end
