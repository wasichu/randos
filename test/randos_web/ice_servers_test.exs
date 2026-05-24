defmodule RandosWeb.IceServersTest do
  use ExUnit.Case, async: false

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
      System.put_env("TURN_HOST", "turn.slowinput.org")
      System.put_env("TURN_SHARED_SECRET", "shared-secret")
      System.put_env("TURN_CREDENTIAL_TTL_SECONDS", "900")

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

  test "supports explicit STUN, TURN, and TURNS URLs from environment variables" do
    with_restored_env(fn ->
      System.put_env("TURN_STUN_URL", "stun:turn.example.com:3478")
      System.put_env("TURN_SERVER_URL", "turn:turn.example.com:3478")
      System.put_env("TURNS_SERVER_URL", "turns:turn.example.com:5349")
      System.put_env("TURN_SHARED_SECRET", "shared-secret")

      assert [
               %{"urls" => "stun:turn.example.com:3478"},
               %{"urls" => "turn:turn.example.com:3478"},
               %{"urls" => "turns:turn.example.com:5349"}
             ] = IceServers.list()
    end)
  end

  test "falls back to configured STUN when TURN secret is missing" do
    with_restored_env(fn ->
      System.put_env("TURN_HOST", "turn.slowinput.org")

      assert IceServers.list() == [
               %{"urls" => "stun:stun.l.google.com:19302"}
             ]
    end)
  end

  defp with_restored_env(fun) do
    original_config = Application.get_env(:randos, IceServers)

    original_env =
      Map.new(env_names(), fn name ->
        {name, System.get_env(name)}
      end)

    try do
      Enum.each(env_names(), &System.delete_env/1)
      fun.()
    after
      Application.put_env(:randos, IceServers, original_config)

      Enum.each(original_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp env_names do
    [
      "TURN_HOST",
      "TURN_STUN_URL",
      "TURN_SERVER_URL",
      "TURNS_SERVER_URL",
      "TURN_SHARED_SECRET",
      "TURN_CREDENTIAL_TTL_SECONDS"
    ]
  end

  defp turn_credential(username, shared_secret) do
    :crypto.mac(:hmac, :sha, shared_secret, username)
    |> Base.encode64()
  end
end
