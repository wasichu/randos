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
  end

  test "decodes replies, errors, and events" do
    assert Protocol.decode(~s({"reply":1,"ok":"pong"})) == {:reply, 1, {:ok, "pong"}}
    assert Protocol.decode(~s({"reply":2,"error":"nope"})) == {:reply, 2, {:error, "nope"}}
    assert Protocol.decode(~s({"reply":null,"error":"bad"})) == {:reply, nil, {:error, "bad"}}

    assert Protocol.decode(~s({"event":"loopback_failed","error":"gone"})) ==
             {:event, "loopback_failed", %{"error" => "gone"}}
  end

  test "anything else is invalid, not a crash" do
    assert Protocol.decode("not json") == {:invalid, "not json"}
    assert Protocol.decode(~s({"what":1})) == {:invalid, ~s({"what":1})}
  end
end
