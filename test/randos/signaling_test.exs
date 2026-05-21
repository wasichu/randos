defmodule Randos.SignalingTest do
  use ExUnit.Case, async: true

  alias Randos.Signaling

  defp match do
    %{
      participant_a: %{id: "a", topic: "topic:a"},
      participant_b: %{id: "b", topic: "topic:b"},
      offerer: :participant_a,
      answerer: :participant_b
    }
  end

  test "casts supported signaling types without creating atoms from unknown input" do
    assert {:ok, :offer} = Signaling.cast_type("offer")
    assert {:ok, :ice_candidate} = Signaling.cast_type(:ice_candidate)
    assert {:error, :unsupported_signal_type} = Signaling.cast_type("not_a_supported_signal")
  end

  test "builds a relay message for the peer" do
    call = %{call_id: "call-1", match: match()}

    assert {:ok, message} =
             Signaling.build_message(call, "a", "offer", %{"sdp" => "mock-sdp"})

    assert message.call_id == "call-1"
    assert message.type == :offer
    assert message.from_participant_id == "a"
    assert message.to_participant_id == "b"
    assert message.payload == %{"sdp" => "mock-sdp"}
    assert is_integer(message.sent_at_unix_ms)
  end

  test "returns assigned WebRTC roles" do
    assert Signaling.webrtc_role_for(match(), "a") == :offerer
    assert Signaling.webrtc_role_for(match(), "b") == :answerer
    assert is_nil(Signaling.webrtc_role_for(match(), "unknown"))
  end
end
