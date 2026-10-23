defmodule Tui.Connection do
  @moduledoc """
  The participant channel connection (a Slipstream client).

  Joins `"participant"` on connect and forwards everything to an owner
  process as `{:randos, message}`:

    * `{:joined, reply}` — join reply (`%{"state" => _, "languages" => _,
      "resumed" => _}`); after a reconnect mid-call it's the same
      participant, back in its call (`"resumed" => true`), else a fresh one
    * `{:push, event, payload}` — server pushes (`state`, `signal`; `resume_ticket` stays here, below)
    * `{:reply, event, {:ok | :error, payload}}` — replies to our pushes
    * `:disconnected` — Slipstream reconnects (and we rejoin) automatically

  Send events with `push/3`.

  If the connection drops during a call, it rejoins with the call's latest
  resume ticket (the server's `resume_ticket` push, kept here in memory
  only), so the server puts us back in the call (Client obligation 9);
  the media helper's call keeps running meanwhile.
  """
  use Slipstream

  @topic "participant"

  @doc """
  Options: `:uri` (websocket URL, e.g.
  `ws://localhost:4000/participant/websocket`), `:owner` (pid), and
  `:test_mode?` for `Slipstream.SocketTest`.
  """
  def start_link(opts) do
    Slipstream.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Sends a client event (see the protocol doc) on the participant channel."
  @spec push(GenServer.server(), String.t(), map()) :: :ok
  def push(connection, event, payload), do: GenServer.cast(connection, {:push, event, payload})

  @doc """
  Says we're leaving the call on purpose (`signal` `peer_disconnected`,
  Client obligation 7) and waits for the server's reply, so it's sent
  before the channel closes. `:ok`, or `{:error, reason}` on a timeout or
  refusal (closing the channel still ends the call, as a lost connection).
  """
  @spec leave(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def leave(connection, timeout \\ 1_000) do
    GenServer.call(connection, :leave, timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  @impl Slipstream
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    {:ok, socket} = connect(Keyword.take(opts, [:uri, :test_mode?]))
    {:ok, assign(socket, owner: owner, pending: %{}, resume_ticket: nil)}
  end

  @doc false
  # Tests: the websocket connection's process, to drop it like a network
  # blip would.
  def __connection_pid__(connection), do: GenServer.call(connection, :connection_pid)

  @impl Slipstream
  def handle_connect(socket) do
    params =
      case socket.assigns.resume_ticket do
        nil -> %{}
        ticket -> %{resume_ticket: ticket}
      end

    {:ok, join(socket, @topic, params)}
  end

  @impl Slipstream
  def handle_join(@topic, reply, socket) do
    notify(socket, {:joined, reply})
    # A refused ticket (the call is over) is no use any more.
    socket = if reply["resumed"], do: socket, else: assign(socket, :resume_ticket, nil)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(@topic, "resume_ticket", %{"ticket" => ticket}, socket)
      when is_binary(ticket),
      do: {:ok, assign(socket, :resume_ticket, ticket)}

  def handle_message(@topic, event, payload, socket) do
    notify(socket, {:push, event, payload})
    # Out of a call: its ticket is spent.
    socket =
      if event == "state" and payload["call"] == nil,
        do: assign(socket, :resume_ticket, nil),
        else: socket

    {:ok, socket}
  end

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    {event, pending} = Map.pop(socket.assigns.pending, ref)

    case event do
      {:leave, from} ->
        GenServer.reply(from, if(match?({:ok, _}, reply), do: :ok, else: {:error, reply}))

      nil ->
        :ok

      event ->
        notify(socket, {:reply, event, reply})
    end

    {:ok, assign(socket, :pending, pending)}
  end

  @impl Slipstream
  def handle_call(:connection_pid, _from, socket),
    do: {:reply, Slipstream.Socket.channel_pid(socket), socket}

  def handle_call(:leave, from, socket) do
    payload = %{type: "peer_disconnected", payload: %{reason: "quit"}}

    case push(socket, @topic, "signal", payload) do
      {:ok, ref} -> {:noreply, update(socket, :pending, &Map.put(&1, ref, {:leave, from}))}
      {:error, reason} -> {:reply, {:error, reason}, socket}
    end
  end

  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    notify(socket, :disconnected)
    reconnect(socket)
  end

  @impl Slipstream
  def handle_cast({:push, event, payload}, socket) do
    case push(socket, @topic, event, payload) do
      {:ok, ref} ->
        {:noreply, update(socket, :pending, &Map.put(&1, ref, event))}

      {:error, reason} ->
        notify(socket, {:reply, event, {:error, %{"reason" => inspect(reason)}}})
        {:noreply, socket}
    end
  end

  defp notify(socket, message), do: send(socket.assigns.owner, {:randos, message})
end
