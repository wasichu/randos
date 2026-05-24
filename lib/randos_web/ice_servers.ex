defmodule RandosWeb.IceServers do
  @moduledoc """
  Browser ICE server configuration for WebRTC calls.

  This boundary keeps STUN/TURN configuration in Phoenix instead of hardcoding
  it in JavaScript. It defaults to public STUN and can expose coturn STUN/TURN
  servers with short-lived TURN REST API credentials when configured by env.
  """

  @default_ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]
  @default_turn_credential_ttl_seconds 900

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
  Returns JSON-encoded ICE servers for embedding into page metadata.
  """
  def json do
    Jason.encode!(list())
  end

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
    "TURN_CREDENTIAL_TTL_SECONDS"
    |> env()
    |> parse_positive_integer(@default_turn_credential_ttl_seconds)
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
