defmodule RandosWeb.HomeLiveTest do
  use RandosWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Randos.Calls.CallCoordinator

  test "serves the home page on the initial HTTP request", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    document = LazyHTML.from_document(html)

    refute Enum.empty?(LazyHTML.query(document, "#hero-panel"))
    refute Enum.empty?(LazyHTML.query(document, "#conversation-form"))
  end

  test "renders the product skeleton and disables search until the acknowledgment is checked", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#conversation-form")
    assert has_element?(view, "#find-rando-button[disabled]")
    assert has_element?(view, "#theme-toggle[data-theme-toggle]")
    # Outside a call, the language switcher shows.
    assert has_element?(view, "#locale-switcher-slot")
    refute has_element?(view, "#locale-switcher-slot.hidden")
    assert has_element?(view, "#conversation_speaking_language option[value='zh']")
    assert has_element?(view, "#conversation_speaking_language option[value='hi']")
    assert has_element?(view, "#conversation_speaking_language option[value='ar']")
    assert has_element?(view, "#conversation_speaking_language option[value='id']")
    assert has_element?(view, "#hearing-languages #hearing-language-zh")
    assert has_element?(view, "#hearing-languages #hearing-language-hi")
    assert has_element?(view, "#hearing-languages #hearing-language-ar")
    assert has_element?(view, "#hearing-languages #hearing-language-id")

    view
    |> form("#conversation-form",
      conversation: %{
        speaking_language: "en",
        hearing_languages: ["es"],
        adult_acknowledgment: "true"
      }
    )
    |> render_change()

    refute has_element?(view, "#find-rando-button[disabled]")
  end

  test "defaults the speaking language from the browser locale, checked among the hearing ones",
       %{conn: conn} do
    conn = put_connect_params(conn, %{"browser_locale" => "pt-BR"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#conversation_speaking_language option[value='pt'][selected]")
    assert has_element?(view, "#hearing-language-pt[checked]")
    refute has_element?(view, "#hearing-language-en[checked]")
  end

  test "an unsupported locale falls back to English", %{conn: conn} do
    conn = put_connect_params(conn, %{"browser_locale" => "tl-PH"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#conversation_speaking_language option[value='en'][selected]")
    assert has_element?(view, "#hearing-language-en[checked]")
  end

  test "the speaking language starts checked; after that, hearing choices are left alone", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    # First load: the speaking language is pre-checked.
    assert has_element?(view, "#hearing-language-en[checked]")

    # Changing the speaking language doesn't touch what's checked.
    view
    |> form("#conversation-form",
      conversation: %{speaking_language: "es", hearing_languages: ["", "en"]}
    )
    |> render_change()

    assert has_element?(view, "#hearing-language-en[checked]")
    refute has_element?(view, "#hearing-language-es[checked]")

    # A free choice, including nothing at all (the browser still sends the
    # "" placeholder), kept through another change of speaking language.
    view
    |> form("#conversation-form", conversation: %{hearing_languages: [""]})
    |> render_change()

    refute has_element?(view, "#hearing-languages input[type=checkbox][checked]")

    view
    |> form("#conversation-form",
      conversation: %{speaking_language: "ja", hearing_languages: ["", "fr", "de"]}
    )
    |> render_change()

    assert has_element?(view, "#hearing-language-fr[checked]")
    assert has_element?(view, "#hearing-language-de[checked]")
    refute has_element?(view, "#hearing-language-ja[checked]")
  end

  test "shows validation when searching without the adult acknowledgment", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    submit(view, %{
      speaking_language: "en",
      hearing_languages: ["es"],
      adult_acknowledgment: "false"
    })

    assert has_element?(view, "#idle-panel")
    assert has_element?(view, "#matchmaking-error")
  end

  test "names up to three hearing languages while looking; past that, a count", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    submit(view, %{
      speaking_language: "en",
      hearing_languages: ["es", "fr"],
      adult_acknowledgment: "true"
    })

    assert has_element?(view, "#looking-status", "who speaks Español (ES) or Français (FR) and")
    render_click(view, "cancel_search")

    submit(view, %{
      speaking_language: "en",
      hearing_languages: ~w(es fr de it ja),
      adult_acknowledgment: "true"
    })

    assert has_element?(
             view,
             "#looking-status",
             "who speaks any of the 5 languages you picked and"
           )
  end

  test "matches two compatible browser sessions and assigns roles", %{conn: conn} do
    {:ok, view_a, _html} = live(conn, ~p"/")

    submit(view_a, %{
      speaking_language: "en",
      hearing_languages: ["es"],
      adult_acknowledgment: "true"
    })

    assert has_element?(view_a, "#looking-panel")

    assert has_element?(
             view_a,
             "#looking-status",
             "Looking for a rando who speaks Español (ES) and wants to hear English (EN)."
           )

    {:ok, view_b, _html} = live(conn, ~p"/")

    submit(view_b, %{
      speaking_language: "es",
      hearing_languages: ["en"],
      adult_acknowledgment: "true"
    })

    assert has_element?(view_b, "#connecting-panel")
    assert has_element?(view_b, "#match-connection-label")

    render(view_a)
    assert has_element?(view_a, "#connecting-panel")
    assert has_element?(view_a, "#match-connection-label")
    assert has_element?(view_a, "#connecting-panel[data-webrtc-role='offerer']")
    refute has_element?(view_a, "#call-countdown")

    # The call becomes active (and the clock starts) once both browsers'
    # media is connected; their WebRTC hooks report it as a signal.
    connect_media(view_a)
    connect_media(view_b)
    assert eventually_has_element?(view_a, "#call-panel")
    # Switching language reloads the page, which would end the call.
    assert has_element?(view_a, "#locale-switcher-slot.hidden")
    assert has_element?(view_a, "#call-countdown")
    # Each sees the language the other actually speaks.
    assert has_element?(view_a, "#remote-waveform-language", "Español (ES)")
    assert eventually_has_element?(view_b, "#remote-waveform-language")
    assert has_element?(view_b, "#remote-waveform-language", "English (EN)")
    assert has_element?(view_a, "#webrtc-audio[data-webrtc-role='offerer']")
    assert has_element?(view_a, "#webrtc-audio[data-ice-servers*='stun:']")
    # No TURN server in tests, so the call may be direct.
    assert has_element?(view_a, "#webrtc-audio[data-ice-transport-policy='all']")
    # The hook's own text (Mute/Unmute, connection states) comes translated.
    [labels] =
      view_a
      |> element("#webrtc-audio")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-labels")

    assert %{"unmute" => "Unmute", "state_connected" => "connected"} = JSON.decode!(labels)

    # No voice processor unless RANDOS_VOICE_PROCESSOR names one: the mic is sent as is.
    refute has_element?(view_a, "#webrtc-audio[data-voice-processor]")
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
    CallCoordinator.force_time_up(call_pid)

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

    submit(view_a, %{
      speaking_language: "en",
      hearing_languages: ["es"],
      adult_acknowledgment: "true"
    })

    {:ok, view_b, _html} = live(conn, ~p"/")

    submit(view_b, %{
      speaking_language: "es",
      hearing_languages: ["en"],
      adult_acknowledgment: "true"
    })

    # The call becomes active (and the clock starts) once both browsers'
    # media is connected; their WebRTC hooks report it as a signal.
    connect_media(view_a)
    connect_media(view_b)
    assert eventually_has_element?(view_a, "#call-panel")

    view_a |> element("#end-call-button") |> render_click()

    assert eventually_has_element?(view_a, "#idle-panel")
    assert eventually_has_element?(view_b, "#looking-panel")
    refute has_element?(view_b, "#idle-panel")
  end

  test "can leave the queue before a match", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    submit(view, %{
      speaking_language: "en",
      hearing_languages: ["es"],
      adult_acknowledgment: "true"
    })

    assert has_element?(view, "#looking-panel")

    view |> element("#cancel-search-button") |> render_click()
    assert has_element?(view, "#idle-panel")
    refute has_element?(view, "#call-countdown")
    refute has_element?(view, "#extension-countdown")
  end

  defp connect_media(view),
    do:
      render_hook(view, "signal", %{
        "type" => "media_state",
        "payload" => %{"state" => "connected"}
      })

  # As a person would: the speaking language first (the page then checks it
  # among the hearing languages), then everything else, then Find.
  defp submit(view, conversation) do
    view
    |> form("#conversation-form", conversation: Map.take(conversation, [:speaking_language]))
    |> render_change()

    view
    |> form("#conversation-form", conversation: conversation)
    |> render_submit()
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
