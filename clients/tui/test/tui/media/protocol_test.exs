defmodule Tui.Media.ProtocolTest do
  use ExUnit.Case, async: true

  alias Tui.Media.Protocol

  defp encoded(id, command),
    do: id |> Protocol.encode(command) |> IO.iodata_to_binary() |> Jason.decode!()

  test "encodes requests with their id" do
    assert encoded(1, :ping) == %{"id" => 1, "cmd" => "ping"}

    assert encoded(2, {:loopback_start, "sine", "null"}) ==
             %{"id" => 2, "cmd" => "loopback_start", "in" => "sine", "out" => "null"}

    assert encoded(3, :loopback_stop) == %{"id" => 3, "cmd" => "loopback_stop"}

    assert encoded(14, {:audition_start, 9, "sine", "null", "off"}) ==
             %{
               "id" => 14,
               "cmd" => "loopback_start",
               "in" => "sine",
               "out" => "null",
               "masking" => "off",
               "audition" => 9
             }

    assert encoded(12, {:loopback_masking, 9, "off"}) ==
             %{"id" => 12, "cmd" => "loopback_masking", "masking" => "off"}

    assert encoded(13, {:loopback_masking, 9, "higher_resonance_pitch"})["masking"] ==
             "higher_resonance_pitch"

    ice = [%{"urls" => "stun:stun.example:3478"}]

    assert encoded(4, {:call_start, "offerer", ice, "device", "device", true}) == %{
             "id" => 4,
             "cmd" => "call_start",
             "role" => "offerer",
             "ice_servers" => ice,
             "in" => "device",
             "out" => "device",
             "relay_only" => true
           }

    assert encoded(5, {:call_start, "answerer", nil, "sine", "null", false})["ice_servers"] == []

    payload = %{"sdp" => %{"type" => "offer", "sdp" => "v=0"}}

    assert encoded(6, {:call_signal, "offer", payload}) ==
             %{"id" => 6, "cmd" => "call_signal", "type" => "offer", "payload" => payload}

    assert encoded(7, :call_stop) == %{"id" => 7, "cmd" => "call_stop"}
    assert encoded(9, :devices) == %{"id" => 9, "cmd" => "devices"}

    assert encoded(8, {:call_mute, true}) == %{"id" => 8, "cmd" => "call_mute", "muted" => true}

    assert encoded(10, {:call_restart, nil}) == %{"id" => 10, "cmd" => "call_restart"}

    assert encoded(11, {:call_restart, ice}) ==
             %{"id" => 11, "cmd" => "call_restart", "ice_servers" => ice}
  end

  test "decodes replies, errors, and events" do
    assert Protocol.decode(~s({"reply":1,"ok":"pong"})) == {:reply, 1, {:ok, "pong"}}
    assert Protocol.decode(~s({"reply":2,"error":"nope"})) == {:reply, 2, {:error, "nope"}}
    assert Protocol.decode(~s({"reply":null,"error":"bad"})) == {:reply, nil, {:error, "bad"}}

    assert Protocol.decode(~s({"event":"loopback_failed","audition":9,"error":"gone"})) ==
             {:event, "loopback_failed", %{"audition" => 9, "error" => "gone"}}

    assert Protocol.decode(~s({"event":"loopback_failed","error":"gone"})) ==
             {:event, "loopback_failed", %{"error" => "gone"}}

    assert Protocol.decode(~s({"event":"call_signal","type":"answer","payload":{"sdp":{}}})) ==
             {:event, "call_signal", %{"type" => "answer", "payload" => %{"sdp" => %{}}}}
  end

  test "anything else is invalid, not a crash" do
    assert Protocol.decode("not json") == {:invalid, "not json"}
    assert Protocol.decode(~s({"what":1})) == {:invalid, ~s({"what":1})}
  end
end
