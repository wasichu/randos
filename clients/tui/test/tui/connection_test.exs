defmodule Tui.ConnectionTest do
  # The test process plays the server (Slipstream.SocketTest); not async.
  use Slipstream.SocketTest

  alias Tui.Connection

  @uri "ws://test.invalid/participant/websocket"

  setup do
    client =
      start_supervised!({Connection, uri: @uri, owner: self(), test_mode?: true})

    %{client: client}
  end

  test "joins the participant topic and forwards the join reply", %{client: client} do
    reply = %{"state" => %{"status" => "idle"}, "languages" => []}
    connect_and_assert_join client, "participant", %{}, {:ok, reply}

    assert_receive {:randos, {:joined, ^reply}}
  end

  test "forwards server pushes", %{client: client} do
    connect_and_assert_join client, "participant", %{}, {:ok, %{}}

    push(client, "participant", "state", %{"status" => "looking"})
    assert_receive {:randos, {:push, "state", %{"status" => "looking"}}}
  end

  test "sends client events and forwards their replies with the event name", %{client: client} do
    connect_and_assert_join client, "participant", %{}, {:ok, %{}}

    Connection.push(client, "find", %{speaks: "en"})
    assert_push "participant", "find", %{speaks: "en"}, ref

    reply(client, ref, {:error, %{"reason" => "rate_limited"}})
    assert_receive {:randos, {:reply, "find", {:error, %{"reason" => "rate_limited"}}}}
  end

  test "leave says peer_disconnected and waits for the server's reply", %{client: client} do
    connect_and_assert_join client, "participant", %{}, {:ok, %{}}

    leaving = Task.async(fn -> Connection.leave(client) end)

    assert_push "participant",
                "signal",
                %{type: "peer_disconnected", payload: %{reason: "quit"}},
                ref

    reply(client, ref, {:ok, %{}})
    assert Task.await(leaving) == :ok
  end

  test "leave gives up after its timeout instead of blocking a quit", %{client: client} do
    connect_and_assert_join client, "participant", %{}, {:ok, %{}}
    assert {:error, _} = Connection.leave(client, 50)
  end

  test "reports disconnects", %{client: client} do
    connect_and_assert_join client, "participant", %{}, {:ok, %{}}

    disconnect(client, :heartbeat_timeout)
    assert_receive {:randos, :disconnected}
  end
end
