defmodule RandosWeb.ParticipantChannelTest do
  # Uses the app-wide Matchmaker, so not async; each test uses its own
  # language pair so tests never match each other.
  use RandosWeb.ChannelCase, async: false

  import Phoenix.ConnTest

  import Phoenix.LiveViewTest,
    only: [live: 2, form: 3, render_submit: 1, render_hook: 3, assert_push_event: 3]

  alias Randos.Matchmaking.Matchmaker
  alias RandosWeb.ParticipantSocket

  defp join_participant do
    {:ok, state, socket} =
      ParticipantSocket
      |> socket(nil, %{})
      |> subscribe_and_join(RandosWeb.ParticipantChannel, "participant")

    {state, socket}
  end

  defp find(socket, speaks, listens, ack \\ true) do
    ref =
      push(socket, "find", %{
        "speaks" => speaks,
        "listens" => listens,
        "adult_acknowledged" => ack
      })

    assert_reply ref, :ok
  end

  test "joining gives an idle participant with no call or identifiers" do
    {state, _socket} = join_participant()
    assert state == %{status: :idle, webrtc_role: nil, error: nil, call: nil}
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
    assert %{queues: %{{"it", "pt"} => [_]}} = Matchmaker.snapshot()

    ref = push(socket, "cancel_search", %{})
    assert_reply ref, :ok
    assert_push "state", %{status: :idle}
    refute Map.has_key?(Matchmaker.snapshot().queues, {"it", "pt"})
  end

  test "closing the channel leaves the queue" do
    {_state, socket} = join_participant()
    find(socket, "tr", "id")
    assert_push "state", %{status: :looking}

    Process.unlink(socket.channel_pid)
    ref = leave(socket)
    assert_reply ref, :ok
    Process.sleep(50)
    refute Map.has_key?(Matchmaker.snapshot().queues, {"tr", "id"})
  end

  test "malformed messages are rejected without touching state" do
    {_state, socket} = join_participant()

    for {event, payload} <- [
          {"find", %{"speaks" => 1}},
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

  test "find is rate limited per connection" do
    {_state, socket} = join_participant()

    for _ <- 1..5, do: find(socket, "fr", "de", false)

    ref =
      push(socket, "find", %{"speaks" => "fr", "listens" => "de", "adult_acknowledged" => false})

    assert_reply ref, :error, %{reason: "rate_limited"}
  end

  test "a channel participant and a browser participant can call each other" do
    {_state, socket} = join_participant()
    find(socket, "ja", "ko")
    assert_push "state", %{status: :looking}

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> form("#conversation-form",
      conversation: %{
        speaking_language: "ko",
        listening_language: "ja",
        adult_acknowledgment: "true"
      }
    )
    |> render_submit()

    # The channel participant was waiting first, so it offers.
    assert_push "ice_servers", %{ice_servers: [_ | _]}
    assert_push "state", %{status: :connecting, webrtc_role: :offerer}
    assert_push "state", %{status: :in_call, call: %{status: :active}}, 2_000

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
    assert_push "ice_servers", %{ice_servers: nil}
  end
end
