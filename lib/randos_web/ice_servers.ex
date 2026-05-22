defmodule RandosWeb.IceServers do
  @moduledoc """
  Browser ICE server configuration for WebRTC calls.

  This boundary keeps STUN/TURN configuration in Phoenix instead of hardcoding
  it in JavaScript. It currently defaults to public STUN and is shaped so coturn
  STUN/TURN and temporary TURN credentials can be added later.
  """

  @default_ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  @doc """
  Returns ICE servers safe to expose to the browser.
  """
  def list do
    Application.get_env(:randos, __MODULE__, [])
    |> Keyword.get(:servers, @default_ice_servers)
    |> normalize_servers()
  end

  @doc """
  Returns JSON-encoded ICE servers for embedding into page metadata.
  """
  def json do
    Jason.encode!(list())
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
