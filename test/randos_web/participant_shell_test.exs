defmodule RandosWeb.ParticipantShellTest do
  use ExUnit.Case, async: true

  alias Randos.Calls.Call
  alias Randos.Matchmaking.{Entry, Match}
  alias Randos.Participant
  alias RandosWeb.ParticipantShell

  @prefs %{speaks: "en", listens: "es", adult_acknowledged?: true, audio?: true}

  test "client state never exposes the match, the peer, ids, or pids" do
    participant = Participant.new(@prefs)

    entry = fn id ->
      %Entry{
        id: id,
        pid: self(),
        topic: "t:#{id}",
        speaks_language: "en",
        listens_language: "es",
        audio?: true
      }
    end

    match = %Match{
      id: "match-1",
      participant_a: entry.(participant.id),
      participant_b: entry.("peer")
    }

    call = %Call{
      id: "call-1",
      pid: self(),
      match: match,
      status: :active,
      call_deadline_unix_ms: 5
    }

    participant = %{
      participant
      | status: :in_call,
        call: call,
        call_pid: self(),
        webrtc_role: :offerer
    }

    state = ParticipantShell.client_state(participant)

    assert state == %{
             status: :in_call,
             webrtc_role: :offerer,
             error: nil,
             call: %{
               id: "call-1",
               status: :active,
               call_deadline_unix_ms: 5,
               extension_deadline_unix_ms: nil,
               extension_count: 0,
               ended_reason: nil
             }
           }

    encoded = Jason.encode!(state)
    refute encoded =~ participant.id
    refute encoded =~ "peer"
    refute encoded =~ "match-1"
  end

  test "an idle participant has no call" do
    assert %{status: :idle, call: nil} = ParticipantShell.client_state(Participant.new(@prefs))
  end
end
