defmodule RandosWeb.HomeLiveTest do
  use RandosWeb.ConnCase

  import Randos.Eventually

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

  test "hearing languages: a summary line over chips, open on a fresh page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Open on load, and it keeps whatever the person does with it after.
    assert has_element?(view, "#hearing-languages #hearing-details[open][phx-mounted]")

    assert has_element?(
             view,
             "#hearing-details #hearing-summary #hearing-summary-text[data-hearing='en']"
           )

    # Every language is a chip with a real checkbox inside, in one labelled group.
    assert has_element?(view, "#hearing-languages legend")

    for {_name, code} <- Randos.ConversationLanguages.all() do
      assert has_element?(
               view,
               "#hearing-chips #hearing-chip-#{code} input#hearing-language-#{code}[type=checkbox]"
             )
    end

    # The summary follows the choice.
    view
    |> form("#conversation-form",
      conversation: %{hearing_languages: ["", "en", "es", "fr", "de"]}
    )
    |> render_change()

    assert has_element?(view, "#hearing-summary-text[data-hearing='en es fr de']")

    view
    |> form("#conversation-form", conversation: %{hearing_languages: [""]})
    |> render_change()

    assert has_element?(view, "#hearing-summary-text[data-hearing='']")
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
    conn = put_connect_params(conn, %{"browser_locale" => "mr-IN"})

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
    # ICE restart (obligation 10): the generation to act on, and whether
    # this call restarts (these test sessions didn't declare it).
    assert has_element?(
             view_a,
             "#webrtc-audio[data-ice-generation='0'][data-ice-restart='false']"
           )

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

    # Audio down: both are told it's reconnecting (the recovery budget);
    # back up, the notice goes.
    refute has_element?(view_a, "#call-recovering")

    render_hook(view_b, "signal", %{
      "type" => "media_state",
      "payload" => %{"state" => "disconnected"}
    })

    assert eventually_has_element?(view_a, "#call-recovering")
    assert eventually_has_element?(view_b, "#call-recovering")
    connect_media(view_b)
    assert eventually_gone?(view_a, "#call-recovering")

    assert {:ok, call_pid} = eventually_call_pid(call_id(view_a))
    CallCoordinator.force_time_up(call_pid)

    assert eventually_has_element?(view_a, "#extension-panel")
    refute has_element?(view_a, "#call-countdown")
    assert has_element?(view_a, "#webrtc-audio[data-webrtc-role='offerer']")
    assert has_element?(view_a, "#continue-call-button")
    assert has_element?(view_a, "#end-call-button")
    refute has_element?(view_a, "#find-new-after-extension-button")
    refute has_element?(view_a, "#extension-countdown")
    refute has_element?(view_a, "#extension-waiting")

    # Your counted `continue` shows in place of the button; your rando
    # still has the choice.
    view_b |> element("#continue-call-button") |> render_click()
    assert eventually_has_element?(view_b, "#extension-waiting")
    refute has_element?(view_b, "#continue-call-button")
    assert has_element?(view_b, "#end-call-button")
    assert has_element?(view_a, "#continue-call-button")
    refute has_element?(view_a, "#extension-waiting")

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

  defp eventually_gone?(view, selector),
    do: eventually(fn -> not has_element?(view, selector) end)

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

  # Up to 5 s (500 × 10 ms), like assert_receive's default here: a busy CI
  # runner can be slow; only a failing wait takes that long.
  defp eventually_has_element?(view, selector),
    do: eventually(fn -> has_element?(view, selector) end)

  # This view's call (the page renders its id): not just any call under the
  # app-wide supervisor, which other tests running meanwhile may have too.
  defp call_id(view) do
    [id] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id^='call-media-']")
      |> LazyHTML.attribute("id")

    String.replace_prefix(id, "call-media-", "")
  end

  defp eventually_call_pid(call_id) do
    pid = eventually(fn -> call_pid(call_id) end)
    if pid, do: {:ok, pid}, else: :error
  end

  defp call_pid(call_id) do
    Randos.Calls.CallSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {_, pid, _, _} when is_pid(pid) -> if coordinator_call_id(pid) == call_id, do: pid
      _child -> nil
    end)
  end

  defp coordinator_call_id(pid) do
    {_state, data} = :sys.get_state(pid)
    data.call.id
  catch
    :exit, _gone -> nil
  end

  describe "invitations" do
    defp acknowledge(view, speaks \\ "en", hears \\ ["de"]) do
      view
      |> form("#conversation-form",
        conversation: %{
          speaking_language: speaks,
          hearing_languages: hears,
          adult_acknowledgment: "true"
        }
      )
      |> render_change()
    end

    defp invite(conn, speaks \\ "en", hears \\ ["de"]) do
      {:ok, view, _html} = live(conn, ~p"/")
      acknowledge(view, speaks, hears)
      view |> element("#invite-button") |> render_click()
      assert has_element?(view, "#inviting-panel")

      [url] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#invitation-url")
        |> LazyHTML.attribute("value")

      [_, token] = String.split(url, "#")
      {view, url, token}
    end

    defp join(conn, token) do
      {:ok, view, _html} = live(conn, ~p"/join")
      render_hook(view, "join_link", %{"has_token" => true})

      view
      |> form("#join-form", conversation: %{adult_acknowledgment: "true"})
      |> render_submit(%{"token" => token})

      view
    end

    test "the invite button waits for the 18+ acknowledgment, like Find", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#invite-button[disabled]")
      acknowledge(view)
      refute has_element?(view, "#invite-button[disabled]")
    end

    test "inviting shows the link to share, which can be withdrawn", %{conn: conn} do
      {view, url, _token} = invite(conn)
      assert url =~ ~r"/join#.{22,}$"
      assert has_element?(view, "#copy-invitation-button[phx-hook='CopyLink'][data-url='#{url}']")
      assert has_element?(view, "#state-progress-looking.bg-stone-950")

      view |> element("#cancel-invitation-button") |> render_click()
      assert has_element?(view, "#conversation-form")
    end

    test "/join asks for the 18+ acknowledgment; loading it claims nothing", %{conn: conn} do
      {creator, _url, token} = invite(conn)

      {:ok, view, _html} = live(conn, ~p"/join")
      assert has_element?(view, "#join-form[phx-hook='JoinLink']")
      assert has_element?(view, "#join-call-button[disabled]")
      render_hook(view, "join_link", %{"has_token" => true})

      # Still waiting: the page loading (and its hook) took nothing.
      assert has_element?(creator, "#inviting-panel")

      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      assert {:matched, match} =
               Randos.Matchmaking.Matchmaker.accept(token, %{
                 id: "anon-other",
                 pid: other,
                 topic: "participant:anon-other",
                 accepted_adult_terms: true,
                 audio?: true
               })

      CallCoordinator.hang_up(match.call_pid, "anon-other")
    end

    test "a link without its token says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/join")
      render_hook(view, "join_link", %{"has_token" => false})
      assert has_element?(view, "#join-link-missing")
      refute has_element?(view, "#join-form")
    end

    test "joining through the link: the call, no Next, and both idle after", %{conn: conn} do
      {creator, _url, token} = invite(conn, "en", ["de", "ja"])
      joiner = join(conn, token)
      assert_patch(joiner, ~p"/")
      assert has_element?(joiner, "#connecting-panel")
      assert eventually_has_element?(creator, "#connecting-panel")

      connect_media(creator)
      connect_media(joiner)
      assert eventually_has_element?(creator, "#call-panel")
      assert eventually_has_element?(joiner, "#call-panel")
      refute has_element?(creator, "#next-rando-button")
      assert has_element?(creator, "#end-call-button")
      # The creator hears the joiner may speak any language they hear.
      assert has_element?(creator, "#remote-waveform-language", "Deutsch (DE) or 日本語 (JA)")
      assert has_element?(joiner, "#remote-waveform-language", "English (EN)")

      joiner |> element("#end-call-button") |> render_click()
      assert eventually_has_element?(creator, "#conversation-form")
      assert has_element?(joiner, "#conversation-form")
    end

    test "a used or unknown link shows why, and stays on the join page", %{conn: conn} do
      view = join(conn, "not-a-real-token")
      assert has_element?(view, "#join-panel")
      assert has_element?(view, "#matchmaking-error", "doesn't work any more")
    end
  end
end
