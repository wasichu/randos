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

    ice = [%{"urls" => "stun:stun.example:3478"}]

    assert encoded(4, {:call_start, "offerer", ice, "device", "device"}) == %{
             "id" => 4,
             "cmd" => "call_start",
             "role" => "offerer",
             "ice_servers" => ice,
             "in" => "device",
             "out" => "device"
           }

    assert encoded(5, {:call_start, "answerer", nil, "sine", "null"})["ice_servers"] == []

    payload = %{"sdp" => %{"type" => "offer", "sdp" => "v=0"}}

    assert encoded(6, {:call_signal, "offer", payload}) ==
             %{"id" => 6, "cmd" => "call_signal", "type" => "offer", "payload" => payload}

    assert encoded(7, :call_stop) == %{"id" => 7, "cmd" => "call_stop"}
    assert encoded(9, :devices) == %{"id" => 9, "cmd" => "devices"}

    assert encoded(8, {:call_mute, true}) == %{"id" => 8, "cmd" => "call_mute", "muted" => true}
  end

  test "decodes replies, errors, and events" do
    assert Protocol.decode(~s({"reply":1,"ok":"pong"})) == {:reply, 1, {:ok, "pong"}}
    assert Protocol.decode(~s({"reply":2,"error":"nope"})) == {:reply, 2, {:error, "nope"}}
    assert Protocol.decode(~s({"reply":null,"error":"bad"})) == {:reply, nil, {:error, "bad"}}

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
