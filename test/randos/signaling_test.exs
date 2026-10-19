defmodule Randos.SignalingTest do
  use ExUnit.Case, async: true

  alias Randos.Matchmaking.{Entry, Match}
  alias Randos.Signaling

  defp match do
    entry = fn id ->
      %Entry{
        audio?: true,
        id: id,
        pid: self(),
        topic: "topic:#{id}",
        speaks_language: "en",
        listens_language: "es"
      }
    end

    %Match{id: "match-1", participant_a: entry.("a"), participant_b: entry.("b")}
  end

  test "casts supported signaling types without creating atoms from unknown input" do
    assert {:ok, :offer} = Signaling.cast_type("offer")
    assert {:ok, :ice_candidate} = Signaling.cast_type(:ice_candidate)
    assert {:error, :unsupported_signal_type} = Signaling.cast_type("not_a_supported_signal")
  end

  test "builds a relay message for the peer" do
    call = %Randos.Calls.Call{id: "call-1", pid: self(), match: match()}

    assert {:ok, message} =
             Signaling.build_message(call, "a", "offer", %{"sdp" => "mock-sdp"})

    assert message.call_id == "call-1"
    assert message.type == :offer
    assert message.from_participant_id == "a"
    assert message.to_participant_id == "b"
    assert message.payload == %{"sdp" => "mock-sdp"}
    assert is_integer(message.sent_at_unix_ms)
  end
end
