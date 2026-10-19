defmodule Randos.Calls.CallCoordinator do
  @moduledoc """
  Per-call coordination process.

  Owns one call's `Randos.Calls.Call` plus everything ephemeral around it:
  timers, participant monitors, hangups, extension votes, and signaling relay.
  Status rules come from `Randos.Calls.Lifecycle`. It never touches audio.

  A coordinator lives exactly as long as its call: it is `:temporary`, so the
  supervisor never restarts a finished call.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Randos.Calls.Call
  alias Randos.Calls.Lifecycle
  alias Randos.Signaling

  @overridable [
    :pubsub,
    :activation_delay_ms,
    :call_duration_ms,
    :extension_duration_ms,
    :extension_response_timeout_ms
  ]

  defstruct [
    :call,
    :timeout_ref,
    :extension_timeout_ref,
    pubsub: Randos.PubSub,
    extension_votes: %{},
    monitors: %{},
    activation_delay_ms: 750,
    call_duration_ms: Lifecycle.call_duration_seconds() * 1_000,
    extension_duration_ms: Lifecycle.extension_duration_seconds() * 1_000,
    extension_response_timeout_ms: Lifecycle.extension_response_timeout_seconds() * 1_000
  ]

  @doc """
  Starts a coordinator for `match` under the call supervisor.

  Options: `:supervisor`, plus test overrides for `#{Enum.join(@overridable, ", ")}`.
  """
  @spec start_match(map(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_match(match, opts \\ []) do
    {supervisor, opts} = Keyword.pop(opts, :supervisor, Randos.Calls.CallSupervisor)
    DynamicSupervisor.start_child(supervisor, {__MODULE__, Keyword.put(opts, :match, match)})
  end

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Ends the call on behalf of `participant_id`."
  @spec hang_up(pid(), String.t()) :: :ok | {:error, :call_unavailable}
  def hang_up(call_pid, participant_id) do
    safe_call(call_pid, {:hang_up, participant_id})
  end

  @doc "Records a participant's extension vote while the call is `:extension_pending`."
  @spec vote_extension(pid(), String.t(), :continue | :end) ::
          :ok | {:error, :not_extension_pending | :call_unavailable}
  def vote_extension(call_pid, participant_id, vote) when vote in [:continue, :end] do
    safe_call(call_pid, {:extension_vote, participant_id, vote})
  end

  @doc "Relays a WebRTC signaling message to the participant's peer."
  @spec relay_signal(pid(), String.t(), atom() | String.t(), map()) ::
          :ok | {:error, atom()}
  def relay_signal(call_pid, participant_id, type, payload \\ %{}) do
    safe_call(call_pid, {:relay_signal, participant_id, type, payload})
  end

  @doc false
  # Test helper: jump straight to the end of the current call segment.
  def force_time_up(call_pid) do
    send(call_pid, :call_time_limit_reached)
    :ok
  end

  @impl true
  def init(opts) do
    match = Keyword.fetch!(opts, :match)

    state =
      struct!(__MODULE__, Keyword.take(opts, @overridable))
      |> Map.merge(%{call: Call.new(self(), match), monitors: monitor_participants(match)})

    Process.send_after(self(), :activate_call, state.activation_delay_ms)
    Logger.info("call_coordinator_started call_id=#{state.call.id} match_id=#{match.id}")

    {:ok, state}
  end

  @impl true
  def handle_call({:hang_up, _participant_id}, _from, state) do
    Logger.info("call_hangup call_id=#{state.call.id} status=#{state.call.status}")
    {:stop, :normal, :ok, end_call(state, :hangup)}
  end

  def handle_call(
        {:extension_vote, participant_id, vote},
        _from,
        %{call: %Call{status: :extension_pending}} = state
      ) do
    state = %{state | extension_votes: Map.put(state.extension_votes, participant_id, vote)}

    cond do
      vote == :end ->
        Logger.info("call_extension_declined call_id=#{state.call.id}")
        {:stop, :normal, :ok, end_call(state, :extension_declined)}

      both_participants_voted_continue?(state) ->
        Logger.info("call_extension_accepted call_id=#{state.call.id}")
        extend_call(state)

      true ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:extension_vote, _participant_id, _vote}, _from, state) do
    {:reply, {:error, :not_extension_pending}, state}
  end

  def handle_call({:relay_signal, participant_id, type, payload}, _from, state) do
    case Signaling.build_message(state.call, participant_id, type, payload) do
      {:ok, message} ->
        Logger.debug(
          "call_signal_relay call_id=#{message.call_id} type=#{message.type} from=#{message.from_participant_id}"
        )

        relay_signal_to_peer(state, message)
        maybe_end_after_lifecycle_signal(state, message)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:activate_call, %{call: %Call{status: :connecting}} = state) do
    Logger.info("call_activated call_id=#{state.call.id}")

    state =
      %{state | call: Lifecycle.activate(state.call)}
      |> schedule_call_timeout(state.call_duration_ms)

    broadcast(state, {:call_active, state.call})
    {:noreply, state}
  end

  def handle_info(:call_time_limit_reached, %{call: %Call{status: :active}} = state) do
    Logger.info("call_time_limit_reached call_id=#{state.call.id}")

    call = %{
      Lifecycle.request_extension(state.call)
      | extension_deadline_unix_ms: deadline(state.extension_response_timeout_ms)
    }

    state = %{
      state
      | call: call,
        timeout_ref: nil,
        extension_votes: %{},
        extension_timeout_ref:
          Process.send_after(
            self(),
            :extension_response_timeout,
            state.extension_response_timeout_ms
          )
    }

    broadcast(state, {:call_extension_pending, state.call})
    {:noreply, state}
  end

  def handle_info(:extension_response_timeout, %{call: %Call{status: :extension_pending}} = state) do
    Logger.info("call_extension_timeout call_id=#{state.call.id}")
    {:stop, :normal, end_call(state, :extension_timeout)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.monitors, ref) do
    Logger.info("call_participant_down call_id=#{state.call.id} reason=#{inspect(reason)}")
    {:stop, :normal, end_call(state, :disconnected)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp monitor_participants(match) do
    Map.new([:participant_a, :participant_b], fn role ->
      participant = Map.fetch!(match, role)
      {Process.monitor(participant.pid), role}
    end)
  end

  defp schedule_call_timeout(state, duration_ms) do
    cancel_timer(state.timeout_ref)

    %{
      state
      | timeout_ref: Process.send_after(self(), :call_time_limit_reached, duration_ms),
        call: %{state.call | call_deadline_unix_ms: deadline(duration_ms)}
    }
  end

  defp deadline(duration_ms), do: System.system_time(:millisecond) + duration_ms

  defp both_participants_voted_continue?(%{call: %Call{match: match}} = state) do
    Enum.all?([match.participant_a.id, match.participant_b.id], fn participant_id ->
      Map.get(state.extension_votes, participant_id) == :continue
    end)
  end

  defp extend_call(state) do
    case Lifecycle.extend(state.call) do
      {:ok, call} ->
        cancel_timer(state.extension_timeout_ref)
        Logger.info("call_extended call_id=#{call.id}")

        state =
          %{state | call: call, extension_timeout_ref: nil, extension_votes: %{}}
          |> schedule_call_timeout(state.extension_duration_ms)

        broadcast(state, {:call_extended, state.call})
        {:reply, :ok, state}

      {:error, :max_extensions} ->
        {:stop, :normal, :ok, end_call(state, :max_duration_reached)}
    end
  end

  defp end_call(state, reason) do
    Logger.info(
      "call_ended call_id=#{state.call.id} reason=#{reason} status=#{state.call.status}"
    )

    cancel_timer(state.timeout_ref)
    cancel_timer(state.extension_timeout_ref)
    demonitor_participants(state)

    state = %{state | call: Lifecycle.end_call(state.call, reason)}
    broadcast(state, {:call_ended, state.call})
    state
  end

  defp maybe_end_after_lifecycle_signal(state, %{type: type})
       when type in [:connection_failed, :peer_disconnected] do
    {:stop, :normal, :ok, end_call(state, type)}
  end

  defp maybe_end_after_lifecycle_signal(state, _message), do: {:reply, :ok, state}

  defp safe_call(call_pid, message) when is_pid(call_pid) do
    GenServer.call(call_pid, message)
  catch
    :exit, {:noproc, _} -> {:error, :call_unavailable}
    :exit, {:normal, _} -> {:error, :call_unavailable}
    :exit, {:shutdown, _} -> {:error, :call_unavailable}
  end

  defp demonitor_participants(state) do
    Enum.each(Map.keys(state.monitors), &Process.demonitor(&1, [:flush]))
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp broadcast(%{call: %Call{match: match}} = state, message) do
    Phoenix.PubSub.broadcast(state.pubsub, match.participant_a.topic, message)
    Phoenix.PubSub.broadcast(state.pubsub, match.participant_b.topic, message)
  end

  defp relay_signal_to_peer(state, message) do
    {:ok, peer} = Signaling.peer_for(state.call.match, message.from_participant_id)
    Phoenix.PubSub.broadcast(state.pubsub, peer.topic, {:signaling, message})
  end
end
