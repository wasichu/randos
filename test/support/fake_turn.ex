defmodule Randos.FakeTurn do
  @moduledoc """
  A tiny TURN server for tests, on 127.0.0.1 (UDP, or TLS with a throwaway
  certificate): it answers an unauthenticated Allocate with 401 (realm and
  nonce), checks MESSAGE-INTEGRITY with the long-term credential, and
  answers Allocate and Refresh with success. `password` is what it expects;
  `allocations` counts the allocations it granted and released.
  """

  alias RandosWeb.RelayHealth.Turn

  @realm "test.realm"
  @nonce "nonce-1"

  @doc "Starts a fake on UDP; returns `%{port, pid}`."
  def start_udp(password) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    test = self()
    pid = spawn_link(fn -> udp_loop(socket, password, test) end)
    :ok = :gen_udp.controlling_process(socket, pid)
    %{port: port, pid: pid}
  end

  @doc """
  Starts a fake on TLS; returns `%{port, pid, client_ssl}`, where
  `client_ssl` are the `:ssl` options a client needs to trust it.
  """
  def start_tls(password) do
    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: ecdsa(), peer: ecdsa()},
        client_chain: %{root: ecdsa(), peer: ecdsa()}
      })

    {:ok, listen} =
      :ssl.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++ server)

    {:ok, {_ip, port}} = :ssl.sockname(listen)
    test = self()
    pid = spawn_link(fn -> tls_accept(listen, password, test) end)
    :ok = :ssl.controlling_process(listen, pid)

    # The test chain's client config (it trusts the test root, and carries
    # the client certificate the test server asks for). The certificate
    # names no 127.0.0.1, so the hostname check is waived here (the real
    # client checks hostnames).
    client_ssl =
      client ++
        [
          server_name_indication: :disable,
          customize_hostname_check: [match_fun: fn _reference, _presented -> true end]
        ]

    %{port: port, pid: pid, client_ssl: client_ssl}
  end

  # P-256 keys signed with SHA-256: the defaults are refused by modern TLS.
  defp ecdsa, do: [key: {:namedCurve, :secp256r1}, digest: :sha256]

  defp udp_loop(socket, password, test) do
    case :gen_udp.recv(socket, 0, 30_000) do
      {:ok, {ip, port, data}} ->
        :ok = :gen_udp.send(socket, ip, port, reply(data, password, test))
        udp_loop(socket, password, test)

      {:error, _closed} ->
        :ok
    end
  end

  defp tls_accept(listen, password, test) do
    with {:ok, transport} <- :ssl.transport_accept(listen, 30_000),
         {:ok, socket} <- :ssl.handshake(transport, 5_000) do
      tls_loop(socket, password, test)
    end

    tls_accept(listen, password, test)
  end

  defp tls_loop(socket, password, test) do
    with {:ok, <<_::16, length::16, _::binary>> = header} <- :ssl.recv(socket, 20, 30_000),
         {:ok, body} <- if(length > 0, do: :ssl.recv(socket, length, 5_000), else: {:ok, <<>>}) do
      :ok = :ssl.send(socket, reply(header <> body, password, test))
      tls_loop(socket, password, test)
    end
  end

  # The server side of the exchange.
  defp reply(data, password, test) do
    {:ok, type, tid, attrs} = Turn.decode(data)
    username = Map.get(attrs, 0x0006)

    cond do
      username == nil ->
        error(type, tid, 401, [{0x0014, @realm}, {0x0015, @nonce}])

      valid?(data, username, password) ->
        if type == 0x0003, do: send(test, {:fake_turn, :allocated})
        if type == 0x0004, do: send(test, {:fake_turn, :released})
        Turn.encode(type + 0x0100, tid, [])

      true ->
        error(type, tid, 401, [{0x0014, @realm}, {0x0015, @nonce}])
    end
  end

  # The integrity attribute is last (no FINGERPRINT from our client).
  defp valid?(data, username, password) do
    size = byte_size(data) - 24
    <<signed::binary-size(^size), 0x0008::16, 20::16, mac::binary-20>> = data
    key = :crypto.hash(:md5, "#{username}:#{@realm}:#{password}")
    :crypto.mac(:hmac, :sha, key, signed) == mac
  end

  defp error(type, tid, code, attrs) do
    value = <<0::21, div(code, 100)::3, rem(code, 100)::8, "Unauthorized">>
    Turn.encode(type + 0x0110, tid, [{0x0009, value} | attrs])
  end
end
