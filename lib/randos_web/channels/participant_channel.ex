defmodule RandosWeb.ParticipantChannel do
  @moduledoc """
  One anonymous participant over a channel: the same `Randos.Participant`
  core and `RandosWeb.ParticipantShell` as the browser's LiveView, with a
  JSON protocol for clients like the TUI.

  The protocol (events, payloads, pushes) is documented in
  `docs/architecture/participant_channel.md`, which is the client contract.
  A new channel is a new participant; there is no resume.
  """
  use Phoenix.Channel

  alias Randos.ConversationLanguages
  alias Randos.Matchmaking.Matchmaker
  alias Randos.Participant
  alias Randos.Signaling
  alias RandosWeb.ParticipantShell

  # `find` token bucket: a burst of 5, then one more every 6 seconds.
  @find_capacity 5
  @find_refill_ms 6_000

  @default_preferences %{speaks: "en", listens: "es", adult_acknowledged?: false}

  @impl true
  def join("participant", _params, socket) do
    participant = Participant.new(@default_preferences)
    Phoenix.PubSub.subscribe(Randos.PubSub, participant.topic)
    state = ParticipantShell.client_state(participant)

    socket =
      assign(socket,
        participant: participant,
        client_state: state,
        find_tokens: @find_capacity,
        find_refilled_at: System.monotonic_time(:millisecond)
      )

    {:ok, %{state: state, languages: languages()}, socket}
  end

  @impl true
  def handle_in(
        "find",
        %{"speaks" => speaks, "listens" => listens, "adult_acknowledged" => ack},
        socket
      )
      when is_binary(speaks) and is_binary(listens) and is_boolean(ack) do
    case take_find_token(socket) do
      {:ok, socket} ->
        preferences = %{speaks: speaks, listens: listens, adult_acknowledged?: ack}
        {:reply, :ok, run(socket, {:find, preferences})}

      {:error, socket} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  def handle_in("cancel_search", _payload, socket), do: {:reply, :ok, run(socket, :cancel_search)}
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

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "invalid_message"}}, socket}
  end

  @impl true
  def handle_info({:call_updated, _call} = event, socket), do: {:noreply, run(socket, event)}
  def handle_info({:signaling, _message} = event, socket), do: {:noreply, run(socket, event)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket) do
    Matchmaker.leave(self())
    :ok
  end

  ## Helpers

  defp run(socket, event) do
    {participant, client_effects} = ParticipantShell.run(socket.assigns.participant, event)
    Enum.each(client_effects, &deliver(socket, &1))
    socket = assign(socket, :participant, participant)
    push_state_if_changed(socket)
  end

  # Supported conversation languages, so clients never hardcode the list.
  defp languages do
    Enum.map(ConversationLanguages.all(), fn {name, code} -> %{code: code, name: name} end)
  end

  defp deliver(socket, {:push_signal, message}), do: push(socket, "signal", message)

  defp deliver(socket, {:ice_servers, servers}),
    do: push(socket, "ice_servers", %{ice_servers: servers})

  defp push_state_if_changed(socket) do
    state = ParticipantShell.client_state(socket.assigns.participant)

    if state == socket.assigns.client_state do
      socket
    else
      push(socket, "state", state)
      assign(socket, :client_state, state)
    end
  end

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
