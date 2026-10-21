defmodule RandosWeb.RelayHealth.Turn do
  @moduledoc """
  The smallest TURN client that proves a relay works (RFC 8656 over
  RFC 8489): an Allocate, answered 401 with a realm and nonce, sent again
  with the long-term credential's MESSAGE-INTEGRITY, then a Refresh with
  lifetime 0 to release the allocation at once. Over UDP (`turn:`) or TLS
  (`turns:`, TURN over TLS on TCP: the same messages, back to back).

  `check/2` returns `:ok` or `{:error, reason}`, where `reason` is a short
  phrase safe to show anyone: it never carries an address, a credential, or
  the server's own words.
  """

  @magic 0x2112A442

  # Message types (method | class bits).
  @allocate 0x0003
  @allocate_ok 0x0103
  @allocate_error 0x0113
  @refresh 0x0004
  @refresh_ok 0x0104
  @refresh_error 0x0114

  # Attributes.
  @username 0x0006
  @message_integrity 0x0008
  @error_code 0x0009
  @lifetime 0x000D
  @realm 0x0014
  @nonce 0x0015
  @requested_transport 0x0019

  @udp_protocol 17
  @timeout 4_000

  @type server :: %{
          transport: :udp | :tls,
          host: String.t(),
          port: :inet.port_number(),
          username: String.t(),
          credential: String.t()
        }

  @doc """
  Checks `server` can allocate a relay. `opts`: `:timeout` (ms per reply,
  default #{@timeout}), `:ssl` (extra or overriding `:ssl` options; tests
  trust their own certificate).
  """
  @spec check(server(), keyword()) :: :ok | {:error, String.t()}
  def check(server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    with {:ok, conn} <- connect(server, opts, timeout) do
      try do
        allocate_and_release(conn, server, timeout)
      after
        close(conn)
      end
    end
  end

  @doc """
  The TURN servers in an ICE server list (as `RandosWeb.IceServers.list/0`
  hands out): at most one UDP (`turn:`) and one TLS (`turns:`) server.
  """
  @spec servers([map()]) :: %{optional(:udp | :tls) => server()}
  def servers(ice_servers) do
    for %{"urls" => urls} = entry <- ice_servers,
        url <- List.wrap(urls),
        server = parse(url, entry),
        reduce: %{} do
      acc -> Map.put_new(acc, server.transport, server)
    end
  end

  defp parse(url, %{"username" => username, "credential" => credential}) do
    case Regex.run(~r/\A(turns?):([^:?]+)(?::(\d+))?(\?transport=(\w+))?\z/, url) do
      [_, "turn", host | rest] when rest == [] or tl(rest) in [[], ["?transport=udp", "udp"]] ->
        server(:udp, host, rest, 3478, username, credential)

      [_, "turns", host | rest] ->
        server(:tls, host, rest, 5349, username, credential)

      _other ->
        nil
    end
  end

  defp parse(_url, _entry), do: nil

  defp server(transport, host, rest, default_port, username, credential) do
    port =
      case rest do
        [port | _] when port != "" -> String.to_integer(port)
        _none -> default_port
      end

    %{transport: transport, host: host, port: port, username: username, credential: credential}
  end

  ## The exchange

  defp allocate_and_release(conn, server, timeout) do
    transport = <<@udp_protocol, 0, 0, 0>>

    with {:ok, @allocate_error, attrs} <-
           request(conn, @allocate, [{@requested_transport, transport}], timeout),
         {401, realm, nonce} <- challenge(attrs),
         key = :crypto.hash(:md5, "#{server.username}:#{realm}:#{server.credential}"),
         auth = [{@username, server.username}, {@realm, realm}, {@nonce, nonce}],
         {:ok, @allocate_ok, _attrs} <-
           signed(conn, @allocate, [{@requested_transport, transport} | auth], key, timeout),
         :ok <- release(conn, auth, key, timeout) do
      :ok
    else
      {:ok, @allocate_error, attrs} -> {:error, refused(attrs)}
      {:ok, _type, _attrs} -> {:error, "unexpected reply"}
      {:error, reason} -> {:error, reason}
      _no_challenge -> {:error, "no authentication challenge"}
    end
  end

  # Lifetime 0 frees the relay now rather than in 10 minutes. A stale
  # nonce (438) is fine: the allocation was made, which is what we checked.
  defp release(conn, auth, key, timeout) do
    case signed(conn, @refresh, [{@lifetime, <<0::32>>} | auth], key, timeout) do
      {:ok, @refresh_ok, _attrs} -> :ok
      {:ok, @refresh_error, _attrs} -> :ok
      {:ok, _type, _attrs} -> {:error, "unexpected reply"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp challenge(attrs) do
    {error_code(attrs), Map.get(attrs, @realm), Map.get(attrs, @nonce)}
  end

  defp refused(attrs) do
    case error_code(attrs) do
      401 -> "credentials refused"
      code when is_integer(code) -> "error #{code}"
      nil -> "refused"
    end
  end

  defp error_code(%{@error_code => <<_::21, class::3, number::8, _reason::binary>>}),
    do: class * 100 + number

  defp error_code(_attrs), do: nil

  defp request(conn, type, attrs, timeout) do
    tid = :crypto.strong_rand_bytes(12)
    exchange(conn, encode(type, tid, attrs), tid, timeout)
  end

  defp signed(conn, type, attrs, key, timeout) do
    tid = :crypto.strong_rand_bytes(12)
    exchange(conn, encode_signed(type, tid, attrs, key), tid, timeout)
  end

  ## Encoding (RFC 8489 section 5, 14)

  @doc false
  def encode(type, tid, attrs) do
    body = IO.iodata_to_binary(Enum.map(attrs, &attribute/1))
    <<type::16, byte_size(body)::16, @magic::32, tid::binary-12, body::binary>>
  end

  @doc false
  # MESSAGE-INTEGRITY: HMAC-SHA1 over the message up to it, with the header's
  # length already counting the integrity attribute (24 bytes).
  def encode_signed(type, tid, attrs, key) do
    body = IO.iodata_to_binary(Enum.map(attrs, &attribute/1))
    header = <<type::16, byte_size(body) + 24::16, @magic::32, tid::binary-12>>
    mac = :crypto.mac(:hmac, :sha, key, header <> body)
    header <> body <> <<@message_integrity::16, 20::16, mac::binary>>
  end

  defp attribute({type, value}) do
    pad = rem(4 - rem(byte_size(value), 4), 4)
    <<type::16, byte_size(value)::16, value::binary, 0::size(pad * 8)>>
  end

  @doc false
  def decode(<<type::16, length::16, @magic::32, tid::binary-12, body::binary-size(length)>>),
    do: {:ok, type, tid, attributes(body, %{})}

  def decode(_other), do: :error

  defp attributes(<<type::16, length::16, rest::binary>>, acc) when byte_size(rest) >= length do
    <<value::binary-size(^length), rest::binary>> = rest
    pad = rem(4 - rem(length, 4), 4)

    rest =
      if byte_size(rest) >= pad, do: binary_part(rest, pad, byte_size(rest) - pad), else: <<>>

    attributes(rest, Map.put_new(acc, type, value))
  end

  defp attributes(_rest, acc), do: acc

  ## Transports

  defp connect(%{transport: :udp, host: host, port: port}, _opts, _timeout) do
    with {:ok, ip} <- resolve(host),
         {:ok, socket} <- :gen_udp.open(0, [:binary, active: false]) do
      {:ok, {:udp, socket, ip, port}}
    end
  end

  defp connect(%{transport: :tls, host: host, port: port}, opts, timeout) do
    ssl =
      Keyword.merge(
        [
          mode: :binary,
          active: false,
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ],
        Keyword.get(opts, :ssl, [])
      )

    case :ssl.connect(String.to_charlist(host), port, ssl, timeout) do
      {:ok, socket} -> {:ok, {:tls, socket}}
      {:error, {:tls_alert, {alert, _}}} -> {:error, "TLS failed (#{alert})"}
      {:error, :timeout} -> {:error, "no answer"}
      {:error, _reason} -> {:error, "couldn't connect"}
    end
  end

  defp resolve(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> {:error, "couldn't resolve the server"}
    end
  end

  defp close({:udp, socket, _ip, _port}), do: :gen_udp.close(socket)
  defp close({:tls, socket}), do: :ssl.close(socket)

  # UDP: one retransmission (a lost packet isn't a broken relay).
  defp exchange({:udp, socket, ip, port}, packet, tid, timeout) do
    Enum.reduce_while(1..2, {:error, "no answer"}, fn _attempt, acc ->
      :ok = :gen_udp.send(socket, ip, port, packet)

      case receive_udp(socket, tid, timeout) do
        {:ok, _type, _attrs} = reply -> {:halt, reply}
        :timeout -> {:cont, acc}
      end
    end)
  end

  defp exchange({:tls, socket}, packet, tid, timeout) do
    with :ok <- :ssl.send(socket, packet),
         {:ok, header} <- :ssl.recv(socket, 20, timeout),
         <<_type::16, length::16, _::binary>> = header,
         {:ok, body} <- if(length > 0, do: :ssl.recv(socket, length, timeout), else: {:ok, <<>>}),
         {:ok, type, ^tid, attrs} <- decode(header <> body) do
      {:ok, type, attrs}
    else
      {:error, :timeout} -> {:error, "no answer"}
      {:error, _closed} -> {:error, "connection closed"}
      _mismatch -> {:error, "unexpected reply"}
    end
  end

  # The reply to this transaction, or nil for a stray datagram.
  defp ours({:ok, type, tid, attrs}, tid), do: {:ok, type, attrs}
  defp ours(_other, _tid), do: nil

  defp receive_udp(socket, tid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      left = max(deadline - System.monotonic_time(:millisecond), 0)

      case :gen_udp.recv(socket, 0, left) do
        {:ok, {_ip, _port, data}} -> ours(decode(data), tid)
        {:error, _timeout_or_closed} -> :timeout
      end
    end)
    |> Enum.find(& &1)
  end
end
