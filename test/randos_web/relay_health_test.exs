defmodule RandosWeb.RelayHealthTest do
  # Against a fake TURN server on 127.0.0.1: never the internet.
  use ExUnit.Case, async: true

  alias Randos.FakeTurn
  alias RandosWeb.RelayHealth
  alias RandosWeb.RelayHealth.Turn

  defp server(transport, port, credential),
    do: %{
      transport: transport,
      host: "127.0.0.1",
      port: port,
      username: "1760000000",
      credential: credential
    }

  describe "the TURN client" do
    test "over UDP: allocates with the long-term credential, then releases" do
      %{port: port} = FakeTurn.start_udp("secret")
      assert Turn.check(server(:udp, port, "secret")) == :ok
      assert_received {:fake_turn, :allocated}
      assert_received {:fake_turn, :released}
    end

    test "over TLS too" do
      %{port: port, client_ssl: ssl} = FakeTurn.start_tls("secret")
      assert Turn.check(server(:tls, port, "secret"), ssl: ssl) == :ok
      assert_receive {:fake_turn, :allocated}
      assert_receive {:fake_turn, :released}
    end

    test "says why with a code, never with an address" do
      %{port: port} = FakeTurn.start_udp("secret")
      assert Turn.check(server(:udp, port, "wrong")) == {:error, :credentials_refused}

      # Nothing listening: no answer (two short tries).
      {:ok, closed} = :gen_udp.open(0, ip: {127, 0, 0, 1})
      {:ok, unused} = :inet.port(closed)
      :gen_udp.close(closed)
      assert Turn.check(server(:udp, unused, "secret"), timeout: 100) == {:error, :no_answer}

      # A TLS server we don't trust.
      %{port: tls_port} = FakeTurn.start_tls("secret")

      assert Turn.check(server(:tls, tls_port, "secret"), timeout: 5_000) ==
               {:error, :tls_failed}
    end

    test "finds one UDP and one TLS server in an ICE server list" do
      creds = %{"username" => "u", "credential" => "c"}

      servers =
        Turn.servers([
          %{"urls" => "stun:relay.example:3478"},
          Map.put(creds, "urls", "turn:relay.example:3478"),
          Map.put(creds, "urls", "turn:relay.example:3478?transport=tcp"),
          Map.put(creds, "urls", "turns:relay.example:5349")
        ])

      assert %{udp: %{port: 3478, host: "relay.example"}, tls: %{port: 5349}} = servers
      assert Turn.servers([%{"urls" => "stun:relay.example:3478"}]) == %{}
    end
  end

  describe "the health process" do
    test "checks at start and announces the results; none configured means nothing is sent" do
      pubsub = :"relay_health_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      Phoenix.PubSub.subscribe(pubsub, RelayHealth.topic())

      %{port: port} = FakeTurn.start_udp("secret")

      ice = [
        %{
          "urls" => "turn:127.0.0.1:#{port}",
          "username" => "1760000000",
          "credential" => "secret"
        }
      ]

      health =
        start_supervised!(
          {RelayHealth, name: nil, pubsub: pubsub, servers: fn -> ice end},
          id: :configured
        )

      assert_receive {:relay_health, %{configured: true, checking: true}}
      assert_receive {:relay_health, %{checking: false, results: %{udp: %{ok: true}}}}, 5_000
      assert %{checked_at: %DateTime{}} = RelayHealth.status(health)

      # A fresh result isn't checked again on demand.
      RelayHealth.refresh_if_stale(health)
      refute_receive {:relay_health, %{checking: true}}, 200

      none =
        start_supervised!({RelayHealth, name: nil, pubsub: pubsub, servers: fn -> [] end},
          id: :none
        )

      assert_receive {:relay_health, %{configured: false}}
      assert %{configured: false, results: %{}} = RelayHealth.status(none)
    end
  end
end
