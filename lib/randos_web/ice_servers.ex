defmodule RandosWeb.IceServers do
  @moduledoc """
  Browser ICE server configuration for WebRTC calls.

  This boundary keeps STUN/TURN configuration in Phoenix instead of hardcoding
  it in JavaScript. It defaults to public STUN and can expose coturn STUN/TURN
  servers with short-lived TURN REST API credentials when configured by env.

  Credentials are minted per call (see `RandosWeb.HomeLive`) and must outlive
  the longest possible call: coturn re-checks them when an allocation is
  refreshed, so expiry mid-call would drop relayed audio. A configured TTL
  below that floor is raised to it.

  **Calls are relay-only whenever there's a TURN server**
  (`ice_transport_policy` `"relay"`), so neither person ever learns the
  other's IP address. `RANDOS_ALLOW_DIRECT_CALLS=true` (`:allow_direct_calls`)
  allows direct calls, with the relay as the fallback (`"all"`). Without a
  TURN server (development, tests) calls are direct; production refuses to
  boot that way unless direct calls are allowed (`check!/0`).
  """

  require Logger

  @default_ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]
  @default_turn_credential_ttl_seconds 3_600
  # Longest call (30 min) plus time to connect and a margin.
  @min_turn_credential_ttl_seconds Randos.Calls.Lifecycle.max_call_duration_seconds() + 600

  @doc """
  Returns ICE servers safe to expose to the browser.
  """
  def list do
    case turn_servers_from_env() do
      [] -> configured_servers()
      servers -> servers
    end
  end

  @doc """
  A call's ICE configuration: its servers (fresh TURN credentials) and its
  `ice_transport_policy`, WebRTC's own values: `"relay"` (only the TURN
  relay, never a direct connection) or `"all"` (direct when possible).
  """
  @spec call_config() :: %{ice_servers: [map()], ice_transport_policy: String.t()}
  def call_config do
    servers = list()
    %{ice_servers: servers, ice_transport_policy: transport_policy(servers)}
  end

  @doc """
  The policy for `servers`: `"relay"` when there's a TURN server among them
  and direct calls aren't allowed, else `"all"`.
  """
  @spec transport_policy([map()]) :: String.t()
  def transport_policy(servers) do
    if Application.get_env(:randos, :allow_direct_calls, false) or
         not Enum.any?(servers, &turn?/1),
       do: "all",
       else: "relay"
  end

  @doc """
  At boot, where calls must be relay-only (`:require_relay`, set in
  production unless direct calls are allowed): raises unless a TURN server is
  configured, so a misconfiguration can't silently make calls direct.
  """
  @spec check!() :: :ok
  def check! do
    if Application.get_env(:randos, :require_relay, false) and transport_policy(list()) != "relay" do
      raise """
      no TURN server is configured, so calls would be direct and show each
      person's IP address to the other. Set TURN_SHARED_SECRET and TURN_HOST
      (or TURN_SERVER_URL / TURNS_SERVER_URL), or set
      RANDOS_ALLOW_DIRECT_CALLS=true to allow direct calls.
      """
    end

    :ok
  end

  defp turn?(%{"urls" => urls}), do: urls |> List.wrap() |> Enum.any?(&turn_url?/1)
  defp turn?(_server), do: false

  defp turn_url?(url), do: String.starts_with?(url, ["turn:", "turns:"])

  defp configured_servers do
    Application.get_env(:randos, __MODULE__, [])
    |> Keyword.get(:servers, @default_ice_servers)
    |> normalize_servers()
  end

  defp turn_servers_from_env do
    shared_secret = env("TURN_SHARED_SECRET")
    turn_urls = turn_urls_from_env()

    if shared_secret && turn_urls != [] do
      username = turn_username()
      credential = turn_credential(username, shared_secret)

      stun_urls_from_env() ++
        Enum.map(turn_urls, fn url ->
          %{
            "urls" => url,
            "username" => username,
            "credential" => credential
          }
        end)
    else
      []
    end
  end

  defp stun_urls_from_env do
    cond do
      url = env("TURN_STUN_URL") ->
        [%{"urls" => url}]

      host = env("TURN_HOST") ->
        [%{"urls" => "stun:#{host}:3478"}]

      true ->
        []
    end
  end

  defp turn_urls_from_env do
    explicit_urls =
      ["TURN_SERVER_URL", "TURNS_SERVER_URL"]
      |> Enum.map(&env/1)
      |> Enum.reject(&is_nil/1)

    cond do
      explicit_urls != [] ->
        explicit_urls

      host = env("TURN_HOST") ->
        ["turn:#{host}:3478", "turns:#{host}:5349"]

      true ->
        []
    end
  end

  defp turn_username do
    (System.system_time(:second) + turn_credential_ttl_seconds())
    |> Integer.to_string()
  end

  defp turn_credential(username, shared_secret) do
    :crypto.mac(:hmac, :sha, shared_secret, username)
    |> Base.encode64()
  end

  defp turn_credential_ttl_seconds do
    ttl =
      "TURN_CREDENTIAL_TTL_SECONDS"
      |> env()
      |> parse_positive_integer(@default_turn_credential_ttl_seconds)

    if ttl < @min_turn_credential_ttl_seconds do
      Logger.warning(
        "TURN_CREDENTIAL_TTL_SECONDS=#{ttl} is shorter than the longest call; using #{@min_turn_credential_ttl_seconds}"
      )

      @min_turn_credential_ttl_seconds
    else
      ttl
    end
  end

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _invalid -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp normalize_servers(servers) when is_list(servers) do
    Enum.map(servers, &normalize_server/1)
  end

  defp normalize_server(server) when is_map(server) do
    server
    |> Map.take([:urls, :username, :credential])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
