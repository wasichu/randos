defmodule RandosWeb.ParticipantChannel do
  @moduledoc """
  One anonymous participant over a channel: the same `Randos.Participant`
  core and `RandosWeb.ParticipantShell` as the browser's LiveView, with a
  JSON protocol for clients like the TUI.

  The protocol (events, payloads, pushes) is documented in
  `docs/architecture/participant_channel.md`, which is the client contract.
  A new channel is a new participant, unless it joins with the resume
  ticket of a call its connection dropped out of (`resume_ticket` in the
  join params): then it takes that participant's place in the call.
  """
  use Phoenix.Channel

  alias Randos.ConversationLanguages
  alias Randos.Matchmaking.Matchmaker
  alias Randos.Participant
  alias Randos.Signaling
  alias RandosWeb.ParticipantShell
  alias RandosWeb.RelayHealth
  alias RandosWeb.Status

  # `find` token bucket: a burst of 5, then one more every 6 seconds.
  @find_capacity 5
  @find_refill_ms 6_000

  @default_preferences %{speaks: "en", hears: ["en"], adult_acknowledged?: false, audio?: false}

  @impl true
  def join("participant", params, socket) do
    {participant, ticket, ice_servers} =
      case resume(params) do
        {:ok, participant, ticket} -> {participant, ticket, RandosWeb.IceServers.list()}
        :error -> {Participant.new(@default_preferences), nil, nil}
      end

    Phoenix.PubSub.subscribe(Randos.PubSub, participant.topic)
    state = participant |> ParticipantShell.client_state() |> with_ice_servers(ice_servers)

    socket =
      assign(socket,
        participant: participant,
        client_state: state,
        ice_servers: ice_servers,
        find_tokens: @find_capacity,
        find_refilled_at: System.monotonic_time(:millisecond)
      )

    # The fresh ticket comes right after the join reply, as tickets always do.
    if ticket, do: send(self(), {:push_resume_ticket, ticket})

    {:ok, %{state: state, languages: languages(), resumed: ticket != nil}, socket}
  end

  defp resume(%{"resume_ticket" => ticket}) when is_binary(ticket),
    do: ParticipantShell.resume(ticket)

  defp resume(_params), do: :error

  @impl true
  def handle_in(
        "find",
        %{"speaks" => speaks, "adult_acknowledged" => ack} = payload,
        socket
      )
      when is_binary(speaks) and is_boolean(ack) and
             (not is_map_key(payload, "audio") or is_boolean(:erlang.map_get("audio", payload))) do
    with {:ok, hears} <- hears(payload),
         {:ok, socket} <- take_find_token(socket) do
      # Clients that don't say they carry audio are matched only with each other.
      preferences = %{
        speaks: speaks,
        hears: hears,
        adult_acknowledged?: ack,
        audio?: Map.get(payload, "audio", false)
      }

      {:reply, :ok, run(socket, {:find, preferences})}
    else
      :invalid -> {:reply, {:error, %{reason: "invalid_message"}}, socket}
      {:error, socket} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  def handle_in("cancel_search", _payload, socket), do: {:reply, :ok, run(socket, :cancel_search)}

  def handle_in("end_call", %{"reason" => reason}, socket) when is_binary(reason) do
    case Participant.cast_end_call_reason(reason) do
      {:ok, reason} -> {:reply, :ok, run(socket, {:end_call, reason})}
      :error -> {:reply, {:error, %{reason: "invalid_message"}}, socket}
    end
  end

  def handle_in("end_call", _payload, socket), do: {:reply, :ok, run(socket, :end_call)}
  def handle_in("next", _payload, socket), do: {:reply, :ok, run(socket, :next)}

  def handle_in("vote", %{"vote" => vote}, socket) when vote in ["continue", "end"] do
    {:reply, :ok, run(socket, {:vote, String.to_existing_atom(vote)})}
  end

  def handle_in("signal", %{"type" => type, "payload" => payload}, socket)
      when is_binary(type) and is_map(payload) do
    case Signaling.cast_type(type) do
      {:ok, _type} -> {:reply, :ok, run(socket, {:client_signal, type, payload})}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # The public status page's data (RandosWeb.Status.snapshot/0: the relay's
  # health and today's aggregate counts, nothing per person), in any status.
  # A stale relay result starts a fresh check, as the page does; the reply
  # doesn't wait for it.
  def handle_in("status", _payload, socket) do
    RelayHealth.refresh_if_stale()
    {:reply, {:ok, Status.snapshot()}, socket}
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "invalid_message"}}, socket}
  end

  @impl true
  def handle_info({:call_updated, _call} = event, socket), do: {:noreply, run(socket, event)}
  def handle_info({:signaling, _message} = event, socket), do: {:noreply, run(socket, event)}

  def handle_info({:resume_ticket, _pid, _ticket} = event, socket),
    do: {:noreply, run(socket, event)}

  def handle_info({:resumed_elsewhere, _pid} = event, socket), do: {:noreply, run(socket, event)}

  def handle_info({:push_resume_ticket, ticket}, socket) do
    push(socket, "resume_ticket", %{ticket: ticket})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    Matchmaker.leave(self())
    :ok
  end

  ## Helpers

  defp run(socket, event) do
    {participant, client_effects} = ParticipantShell.run(socket.assigns.participant, event)
    # The participant first: an effect may replace it (`:detach`).
    socket = assign(socket, :participant, participant)
    socket = Enum.reduce(client_effects, socket, &deliver(&2, &1))
    push_state_if_changed(socket)
  end

  # Supported conversation languages, so clients never hardcode the list.
  defp languages do
    Enum.map(ConversationLanguages.all(), fn {name, code} -> %{code: code, name: name} end)
  end

  defp deliver(socket, {:push_signal, message}) do
    push(socket, "signal", message)
    socket
  end

  defp deliver(socket, {:resume_ticket, ticket}) do
    push(socket, "resume_ticket", %{ticket: ticket})
    socket
  end

  # Another connection took this participant's seat: let go and start over.
  defp deliver(socket, :detach) do
    Phoenix.PubSub.unsubscribe(Randos.PubSub, socket.assigns.participant.topic)
    participant = Participant.new(@default_preferences)
    Phoenix.PubSub.subscribe(Randos.PubSub, participant.topic)
    assign(socket, participant: participant, ice_servers: nil)
  end

  # Minted once per call (fresh TURN credentials); every state push for that
  # call carries them in its `call` map.
  defp deliver(socket, {:ice_servers, servers}), do: assign(socket, :ice_servers, servers)

  defp push_state_if_changed(socket) do
    state =
      socket.assigns.participant
      |> ParticipantShell.client_state()
      |> with_ice_servers(socket.assigns.ice_servers)

    if state == socket.assigns.client_state do
      socket
    else
      push(socket, "state", state)
      assign(socket, :client_state, state)
    end
  end

  defp with_ice_servers(%{call: %{} = call} = state, servers),
    do: %{state | call: Map.put(call, :ice_servers, servers)}

  defp with_ice_servers(state, _servers), do: state

  # The languages the person is happy to hear: `hears`, a list of codes, or
  # (clients before it, like the v0.2.0 TUI) a single `listens`. The
  # matchmaker checks they're supported and that there's at least one.
  defp hears(%{"hears" => hears}) when is_list(hears) and length(hears) <= 32 do
    if Enum.all?(hears, &is_binary/1), do: {:ok, hears}, else: :invalid
  end

  defp hears(%{"listens" => listens}) when is_binary(listens), do: {:ok, [listens]}
  defp hears(_payload), do: :invalid

  defp take_find_token(socket) do
    now = System.monotonic_time(:millisecond)
    refilled = div(now - socket.assigns.find_refilled_at, @find_refill_ms)
    tokens = min(@find_capacity, socket.assigns.find_tokens + refilled)

    # Only advance the refill clock by whole refills, keeping partial progress.
    refilled_at =
      if tokens == @find_capacity,
        do: now,
        else: socket.assigns.find_refilled_at + refilled * @find_refill_ms

    socket = assign(socket, find_refilled_at: refilled_at)

    if tokens > 0 do
      {:ok, assign(socket, :find_tokens, tokens - 1)}
    else
      {:error, assign(socket, :find_tokens, 0)}
    end
  end
end
