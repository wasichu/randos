defmodule RandosWeb.HomeLiveTest do
  use RandosWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the product skeleton and disables search until the acknowledgment is checked", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#conversation-form")
    assert has_element?(view, "#find-rando-button[disabled]")
    assert has_element?(view, "#theme-toggle[data-theme-toggle]")
    assert has_element?(view, "#conversation_speaking_language option[value='zh']")
    assert has_element?(view, "#conversation_speaking_language option[value='hi']")
    assert has_element?(view, "#conversation_speaking_language option[value='ar']")
    assert has_element?(view, "#conversation_speaking_language option[value='id']")
    assert has_element?(view, "#conversation_listening_language option[value='zh']")
    assert has_element?(view, "#conversation_listening_language option[value='hi']")
    assert has_element?(view, "#conversation_listening_language option[value='ar']")
    assert has_element?(view, "#conversation_listening_language option[value='id']")

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

  test "renders browser ICE server metadata", %{conn: conn} do
    html = get(conn, ~p"/") |> html_response(200)

    assert html =~ ~s(name="randos-ice-servers")
    assert html =~ "stun:stun.l.google.com:19302"
  end

  test "defaults conversation languages from browser locale", %{conn: conn} do
    conn = put_connect_params(conn, %{"browser_locale" => "pt-BR"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#conversation_speaking_language option[value='pt'][selected]")
    assert has_element?(view, "#conversation_listening_language option[value='pt'][selected]")
  end

  test "falls back to English for unsupported browser locales", %{conn: conn} do
    conn = put_connect_params(conn, %{"browser_locale" => "tl-PH"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#conversation_speaking_language option[value='en'][selected]")
    assert has_element?(view, "#conversation_listening_language option[value='en'][selected]")
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
    assert has_element?(view_b, "#match-connection-label")

    render(view_a)
    assert has_element?(view_a, "#connecting-panel")
    assert has_element?(view_a, "#match-connection-label")
    assert has_element?(view_a, "#connecting-panel[data-webrtc-role='offerer']")
    refute has_element?(view_a, "#call-countdown")

    assert eventually_has_element?(view_a, "#call-panel")
    assert has_element?(view_a, "#call-countdown")
    assert has_element?(view_a, "#webrtc-audio[data-webrtc-role='offerer']")
    assert has_element?(view_a, "#mute-button[disabled]")
    assert has_element?(view_a, "#local-waveform-canvas[data-audio-visualizer='local']")
    assert has_element?(view_a, "#remote-waveform-canvas[data-audio-visualizer='remote']")
    assert has_element?(view_a, "#remote-audio")
    assert has_element?(view_a, "#remote-audio-status-label")
    refute has_element?(view_a, "#remote-audio-play-button")
    assert has_element?(view_a, "#webrtc-state-label")
    refute has_element?(view_a, "#speaking-language-label")
    refute has_element?(view_a, "#time-up-button")
    refute has_element?(view_a, "#stop-after-call-toggle")
    refute has_element?(view_a, "#extension-countdown")
    assert has_element?(view_a, "#call-panel[data-webrtc-role='offerer']")

    assert {:ok, call_pid} = eventually_call_pid()
    Randos.Calls.CallCoordinator.force_time_up(call_pid)

    assert eventually_has_element?(view_a, "#extension-panel")
    refute has_element?(view_a, "#call-countdown")
    assert has_element?(view_a, "#webrtc-audio[data-webrtc-role='offerer']")
    assert has_element?(view_a, "#continue-call-button")
    assert has_element?(view_a, "#end-call-button")
    refute has_element?(view_a, "#find-new-after-extension-button")
    refute has_element?(view_a, "#extension-countdown")

    view_a |> element("#end-call-button") |> render_click()
    assert eventually_has_element?(view_a, "#idle-panel")
  end

  test "ending an active call returns to idle instead of requeueing", %{conn: conn} do
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

    assert eventually_has_element?(view_a, "#call-panel")

    view_a |> element("#end-call-button") |> render_click()

    assert_redirect(view_a, ~p"/")
    assert eventually_has_element?(view_b, "#looking-panel")
    refute has_element?(view_b, "#idle-panel")
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

  defp eventually_call_pid(attempts \\ 120)

  defp eventually_call_pid(0), do: :error

  defp eventually_call_pid(attempts) do
    Randos.Calls.CallSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {_, pid, _, _} when is_pid(pid) -> pid
      _child -> nil
    end)
    |> case do
      nil ->
        Process.sleep(10)
        eventually_call_pid(attempts - 1)

      pid ->
        {:ok, pid}
    end
  end
end
