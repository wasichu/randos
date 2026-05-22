defmodule RandosWeb.IceServersTest do
  use ExUnit.Case, async: true

  alias RandosWeb.IceServers

  test "returns default public STUN config" do
    assert IceServers.list() == [
             %{"urls" => "stun:stun.l.google.com:19302"}
           ]
  end

  test "normalizes configured TURN-ready server maps for browser JSON" do
    original = Application.get_env(:randos, IceServers)

    try do
      Application.put_env(:randos, IceServers,
        servers: [
          %{urls: "stun:turn.example.com:3478"},
          %{urls: "turn:turn.example.com:3478", username: "user", credential: "secret"}
        ]
      )

      assert IceServers.list() == [
               %{"urls" => "stun:turn.example.com:3478"},
               %{
                 "urls" => "turn:turn.example.com:3478",
                 "username" => "user",
                 "credential" => "secret"
               }
             ]
    after
      Application.put_env(:randos, IceServers, original)
    end
  end
end
