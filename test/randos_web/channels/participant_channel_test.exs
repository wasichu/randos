defmodule RandosWeb.ParticipantChannelTest do
  # Uses the app-wide Matchmaker, so not async; each test uses its own
  # language pair so tests never match each other.
  use RandosWeb.ChannelCase, async: false

  import Phoenix.ConnTest

  import Phoenix.LiveViewTest,
    only: [
      live: 2,
      form: 3,
      render_submit: 1,
      render_hook: 3,
      assert_push_event: 3,
      has_element?: 2
    ]

  alias Randos.Matchmaking.Matchmaker
  alias RandosWeb.ParticipantSocket

  defp join_participant do
    {:ok, %{state: state, languages: [_ | _]}, socket} =
      ParticipantSocket
      |> socket(nil, %{})
      |> subscribe_and_join(RandosWeb.ParticipantChannel, "participant")

    {state, socket}
  end

  defp find(socket, speaks, hears, ack \\ true, extra \\ %{}) do
    ref =
      push(
        socket,
        "find",
        Map.merge(
          %{"speaks" => speaks, "hears" => List.wrap(hears), "adult_acknowledged" => ack},
          extra
        )
      )

    assert_reply ref, :ok
  end

  test "joining gives an idle participant with no call or identifiers" do
    {state, _socket} = join_participant()
    assert state == %{status: :idle, webrtc_role: nil, error: nil, error_message: nil, call: nil}
  end

  test "the join reply lists the supported languages" do
    {:ok, %{languages: languages}, _socket} =
      ParticipantSocket
      |> socket(nil, %{})
      |> subscribe_and_join(RandosWeb.ParticipantChannel, "participant")

    assert %{code: "en", name: "English (EN)"} in languages
    assert length(languages) == length(Randos.ConversationLanguages.codes())
  end

  test "find without the 18+ acknowledgment reports an error in state" do
    {_state, socket} = join_participant()
    find(socket, "fr", "de", false)
    assert_push "state", %{status: :idle, error: :adult_terms_required}
  end

  test "find queues the participant; cancel_search leaves the queue" do
    {_state, socket} = join_participant()
    find(socket, "it", "pt")
    assert_push "state", %{status: :looking}
    assert %{queues: %{{"it", ["pt"], false} => [_]}} = Matchmaker.snapshot()

    ref = push(socket, "cancel_search", %{})
    assert_reply ref, :ok
    assert_push "state", %{status: :idle}
    refute Map.has_key?(Matchmaker.snapshot().queues, {"it", ["pt"], false})
  end

  test "find takes several hearing languages, or the single listens of older clients" do
    {_state, socket} = join_participant()
    find(socket, "it", ["pt", "it"])
    assert_push "state", %{status: :looking}
    assert %{queues: %{{"it", ["pt", "it"], false} => [_]}} = Matchmaker.snapshot()
    push(socket, "cancel_search", %{}) |> assert_reply(:ok)
    assert_push "state", %{status: :idle}

    # The v0.2.0 TUI's payload.
    ref =
      push(socket, "find", %{"speaks" => "de", "listens" => "fr", "adult_acknowledged" => true})

    assert_reply ref, :ok
    assert_push "state", %{status: :looking}
    assert %{queues: %{{"de", ["fr"], false} => [_]}} = Matchmaker.snapshot()
    push(socket, "cancel_search", %{}) |> assert_reply(:ok)
    assert_push "state", %{status: :idle}

    # Nothing to hear: the matchmaker's own error.
    find(socket, "de", [])
    assert_push "state", %{status: :idle, error: :unsupported_language}

    # Not a list of strings: rejected before anything runs.
    for hears <- [[1], "fr", %{"a" => 1}] do
      ref =
        push(socket, "find", %{"speaks" => "de", "hears" => hears, "adult_acknowledged" => true})

      assert_reply ref, :error, %{reason: "invalid_message"}
    end
  end

  test "closing the channel leaves the queue" do
    {_state, socket} = join_participant()
    find(socket, "tr", "id")
    assert_push "state", %{status: :looking}

    Process.unlink(socket.channel_pid)
    ref = leave(socket)
    assert_reply ref, :ok
    Process.sleep(50)
    refute Map.has_key?(Matchmaker.snapshot().queues, {"tr", ["id"], false})
  end

  test "end_call takes an optional reason from the documented list" do
    {_state, socket} = join_participant()
    ref = push(socket, "end_call", %{"reason" => "dancing"})
    assert_reply ref, :error, %{reason: "invalid_message"}

    ref = push(socket, "end_call", %{"reason" => "microphone_denied"})
    assert_reply ref, :ok
  end

  test "malformed messages are rejected without touching state" do
    {_state, socket} = join_participant()

    for {event, payload} <- [
          {"find", %{"speaks" => 1}},
          {"find",
           %{"speaks" => "en", "listens" => "es", "adult_acknowledged" => true, "audio" => "yes"}},
          {"vote", %{"vote" => "maybe"}},
          {"signal", %{"type" => "offer"}},
          {"bogus", %{}}
        ] do
      ref = push(socket, event, payload)
      assert_reply ref, :error, %{reason: "invalid_message"}
    end

    ref = push(socket, "signal", %{"type" => "not_a_signal", "payload" => %{}})
    assert_reply ref, :error, %{reason: :unsupported_signal_type}
  end

  test "status replies with the public status page's data, in any status" do
    {_state, socket} = join_participant()

    ref = push(socket, "status", %{})
    assert_reply ref, :ok, %{"relay" => relay, "usage" => usage} = status

    # The same map as /status (RandosWeb.Status.snapshot/0), JSON-safe.
    assert Map.keys(status) == ["relay", "usage"]
    assert %{"state" => _, "scope" => "this_node", "transports" => _} = relay
    assert %{"calls_started" => _, "language_pairs" => _, "nodes" => _} = usage
    assert {:ok, _json} = Jason.encode(status)

    # Nothing about this participant: no id or topic anywhere in it.
    refute inspect(status) =~ socket.assigns.participant.id

    # Also while looking.
    find(socket, "tr", "id")
    assert_push "state", %{status: :looking}
    ref = push(socket, "status", %{})
    assert_reply ref, :ok, %{"relay" => _}
  end

  test "find is rate limited per connection" do
    {_state, socket} = join_participant()

    for _ <- 1..5, do: find(socket, "fr", "de", false)

    ref =
      push(socket, "find", %{"speaks" => "fr", "listens" => "de", "adult_acknowledged" => false})

    assert_reply ref, :error, %{reason: "rate_limited"}
  end

  defp browser_find(speaks, listens) do
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> form("#conversation-form",
      conversation: %{
        speaking_language: speaks,
        hearing_languages: [listens],
        adult_acknowledgment: "true"
      }
    )
    |> render_submit()

    view
  end

  test "a text-only channel participant is never matched with a browser" do
    {_state, socket} = join_participant()
    find(socket, "hi", "bn")
    assert_push "state", %{status: :looking}

    view = browser_find("bn", "hi")

    # (The browser hears only what was checked: changing its speaking
    # language leaves that alone.)
    assert %{queues: %{{"hi", ["bn"], false} => [_], {"bn", ["hi"], true} => [_]}} =
             Matchmaker.snapshot()

    refute_push "state", %{status: :connecting}
    assert has_element?(view, "#looking-panel")
  end

  test "a channel participant and a browser participant can call each other" do
    {_state, socket} = join_participant()
    find(socket, "ja", "ko", true, %{"audio" => true})
    assert_push "state", %{status: :looking}

    view = browser_find("ko", "ja")

    # The channel participant was waiting first, so it offers. The call's
    # ICE servers and both sides' media state come with the state push.
    assert_push "state", %{
      status: :connecting,
      webrtc_role: :offerer,
      call: %{
        id: call_id,
        ice_servers: [_ | _],
        ice_transport_policy: "all",
        media: %{self: :connecting, peer: :connecting}
      }
    }

    assert "call-" <> _ = call_id

    # Both report their media connected; then the call becomes active.
    ref =
      push(socket, "signal", %{"type" => "media_state", "payload" => %{"state" => "connected"}})

    assert_reply ref, :ok

    render_hook(view, "signal", %{"type" => "media_state", "payload" => %{"state" => "connected"}})

    assert_push "state",
                %{
                  status: :in_call,
                  call: %{status: :active, media: %{self: :connected, peer: :connected}}
                },
                2_000

    # Channel -> browser
    ref = push(socket, "signal", %{"type" => "offer", "payload" => %{"sdp" => "v=0"}})
    assert_reply ref, :ok
    assert_push_event(view, "randos:signal", %{type: "offer", payload: %{"sdp" => "v=0"}})

    # Browser -> channel
    render_hook(view, "signal", %{"type" => "answer", "payload" => %{"sdp" => "v=0 answer"}})
    assert_push "signal", %{type: "answer", payload: %{"sdp" => "v=0 answer"}} = signal
    refute Map.has_key?(signal, :from_participant_id)

    # Ending from the channel: the channel goes idle, the browser back to looking.
    ref = push(socket, "end_call", %{})
    assert_reply ref, :ok
    assert_push "state", %{status: :idle, call: nil}, 1_000
    refute_push "ice_servers", _
  end
end
