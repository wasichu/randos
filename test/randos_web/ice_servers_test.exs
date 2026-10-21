defmodule RandosWeb.IceServersTest do
  use ExUnit.Case, async: false

  # Short TTLs are logged as warnings on purpose.
  @moduletag :capture_log

  alias Randos.Calls.Lifecycle
  alias RandosWeb.IceServers

  test "returns default public STUN config" do
    assert IceServers.list() == [
             %{"urls" => "stun:stun.l.google.com:19302"}
           ]
  end

  test "normalizes configured TURN-ready server maps for browser JSON" do
    with_restored_env(fn ->
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
    end)
  end

  test "uses coturn environment variables with short-lived credentials" do
    with_restored_env(fn ->
      put_turn("TURN_HOST", "turn.slowinput.org")
      put_turn("TURN_SHARED_SECRET", "shared-secret")
      put_turn("TURN_CREDENTIAL_TTL_SECONDS", "900")

      assert [
               %{"urls" => "stun:turn.slowinput.org:3478"},
               %{
                 "urls" => "turn:turn.slowinput.org:3478",
                 "username" => username,
                 "credential" => credential
               },
               %{
                 "urls" => "turns:turn.slowinput.org:5349",
                 "username" => turns_username,
                 "credential" => turns_credential
               }
             ] = IceServers.list()

      assert turns_username == username
      assert turns_credential == credential
      assert {expires_at, ""} = Integer.parse(username)
      assert expires_at > System.system_time(:second)
      assert credential == turn_credential(username, "shared-secret")
    end)
  end

  test "credentials always outlive the longest possible call" do
    floor = Lifecycle.max_call_duration_seconds() + 600

    with_restored_env(fn ->
      put_turn("TURN_HOST", "turn.slowinput.org")
      put_turn("TURN_SHARED_SECRET", "shared-secret")

      for {configured, minimum} <- [{"900", floor}, {nil, 3_600}, {"7200", 7_200}] do
        if configured,
          do: put_turn("TURN_CREDENTIAL_TTL_SECONDS", configured),
          else: put_turn("TURN_CREDENTIAL_TTL_SECONDS", nil)

        [_stun, %{"username" => username} | _] = IceServers.list()
        {expires_at, ""} = Integer.parse(username)
        ttl = expires_at - System.system_time(:second)

        assert ttl in (minimum - 2)..minimum,
               "TTL #{inspect(configured)} gave #{ttl}s, expected ~#{minimum}s"
      end
    end)
  end

  test "supports explicit STUN, TURN, and TURNS URLs from environment variables" do
    with_restored_env(fn ->
      put_turn("TURN_STUN_URL", "stun:turn.example.com:3478")
      put_turn("TURN_SERVER_URL", "turn:turn.example.com:3478")
      put_turn("TURNS_SERVER_URL", "turns:turn.example.com:5349")
      put_turn("TURN_SHARED_SECRET", "shared-secret")

      assert [
               %{"urls" => "stun:turn.example.com:3478"},
               %{"urls" => "turn:turn.example.com:3478"},
               %{"urls" => "turns:turn.example.com:5349"}
             ] = IceServers.list()
    end)
  end

  test "falls back to configured STUN when TURN secret is missing" do
    with_restored_env(fn ->
      put_turn("TURN_HOST", "turn.slowinput.org")

      assert IceServers.list() == [
               %{"urls" => "stun:stun.l.google.com:19302"}
             ]
    end)
  end

  describe "the transport policy" do
    test "relay-only whenever there's a TURN server" do
      with_restored_env(fn ->
        put_turn("TURN_HOST", "turn.example.com")
        put_turn("TURN_SHARED_SECRET", "shared-secret")

        assert IceServers.transport_policy() == "relay"
      end)
    end

    test "direct calls, with the relay as the fallback, when allowed" do
      with_restored_env(fn ->
        put_turn("TURN_HOST", "turn.example.com")
        put_turn("TURN_SHARED_SECRET", "shared-secret")
        Application.put_env(:randos, :allow_direct_calls, true)

        assert IceServers.transport_policy() == "all"
      end)
    end

    test "direct without a TURN server (development, tests), which production refuses" do
      with_restored_env(fn ->
        assert IceServers.transport_policy() == "all"
        assert IceServers.check!() == :ok

        Application.put_env(:randos, :require_relay, true)
        assert_raise RuntimeError, ~r/RANDOS_ALLOW_DIRECT_CALLS/, &IceServers.check!/0

        put_turn("TURN_SERVER_URL", "turns:turn.example.com:5349")
        put_turn("TURN_SHARED_SECRET", "shared-secret")
        assert IceServers.check!() == :ok
      end)
    end

    test "a TURN server configured as plain ICE servers counts too" do
      assert IceServers.transport_policy([%{"urls" => ["stun:a:3478", "turn:a:3478"]}]) == "relay"
      assert IceServers.transport_policy([%{"urls" => "stun:a:3478"}]) == "all"
    end
  end

  defp with_restored_env(fun) do
    original_config = Application.get_env(:randos, IceServers)
    original_turn = Application.get_env(:randos, :turn)

    original_flags =
      Map.new([:allow_direct_calls, :require_relay], &{&1, Application.get_env(:randos, &1)})

    try do
      Application.put_env(:randos, :turn, %{})
      fun.()
    after
      Application.put_env(:randos, IceServers, original_config)
      Application.put_env(:randos, :turn, original_turn || %{})

      Enum.each(original_flags, fn
        {key, nil} -> Application.delete_env(:randos, key)
        {key, value} -> Application.put_env(:randos, key, value)
      end)
    end
  end

  # As config/runtime.exs would have read it from the environment at boot.
  defp put_turn(name, value) do
    turn = Application.get_env(:randos, :turn, %{})
    Application.put_env(:randos, :turn, Map.put(turn, name, value))
  end

  defp turn_credential(username, shared_secret) do
    :crypto.mac(:hmac, :sha, shared_secret, username)
    |> Base.encode64()
  end
end
