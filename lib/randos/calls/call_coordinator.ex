defmodule Randos.Calls.CallCoordinator do
  @moduledoc """
  Per-call coordination process, implemented as a `:gen_statem`.

  States mirror `Randos.Calls.Call` status (`:connecting`, `:active`,
  `:extension_pending`); the process stops when the call ends. Every timer is a
  `state_timeout`, so leaving a state cancels its timer automatically:

    * `:connecting` — waits `activation_delay_ms`, then becomes `:active`
    * `:active` — runs the call segment, then asks for an extension
    * `:extension_pending` — waits for both votes, or times out and ends

  The coordinator also monitors both participants, relays WebRTC signaling
  between them, and broadcasts `{:call_updated, %Call{}}` to both on every
  status change; that and `{:signaling, message}` are the only messages
  participants receive about a call. It never touches
  audio. It is `:temporary`: a finished call is never restarted.
  """

  @behaviour :gen_statem

  require Logger

  alias Randos.Calls.Call
  alias Randos.Calls.Lifecycle
  alias Randos.Matchmaking.Match
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
    pubsub: Randos.PubSub,
    extension_votes: %{},
    monitors: %{},
    activation_delay_ms: 750,
    call_duration_ms: Lifecycle.call_duration_seconds() * 1_000,
    extension_duration_ms: Lifecycle.extension_duration_seconds() * 1_000,
    extension_response_timeout_ms: Lifecycle.extension_response_timeout_seconds() * 1_000
  ]

  ## Public API

  @doc """
  Starts a coordinator for `match` under the call supervisor.

  Options: `:supervisor`, plus test overrides for `#{Enum.join(@overridable, ", ")}`.
  """
  @spec start_match(Match.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_match(match, opts \\ []) do
    {supervisor, opts} = Keyword.pop(opts, :supervisor, Randos.Calls.CallSupervisor)
    DynamicSupervisor.start_child(supervisor, {__MODULE__, Keyword.put(opts, :match, match)})
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc false
  def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

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
    :gen_statem.cast(call_pid, :time_up)
  end

  ## :gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  def init(opts) do
    match = Keyword.fetch!(opts, :match)

    data =
      struct!(__MODULE__, Keyword.take(opts, @overridable))
      |> Map.merge(%{call: Call.new(self(), match), monitors: monitor_participants(match)})

    Logger.info("call_coordinator_started call_id=#{data.call.id} match_id=#{match.id}")
    {:ok, :connecting, data}
  end

  @impl :gen_statem
  # Entering a state: arm its timer and tell both participants.
  def handle_event(:enter, _old, :connecting, data) do
    broadcast(data)
    {:keep_state_and_data, [{:state_timeout, data.activation_delay_ms, :activate}]}
  end

  def handle_event(:enter, old, :active, data) do
    duration_ms =
      case old do
        :connecting -> data.call_duration_ms
        :extension_pending -> data.extension_duration_ms
      end

    data = put_in(data.call.call_deadline_unix_ms, deadline(duration_ms))
    broadcast(data)
    {:keep_state, data, [{:state_timeout, duration_ms, :time_up}]}
  end

  def handle_event(:enter, :active, :extension_pending, data) do
    timeout_ms = data.extension_response_timeout_ms
    data = put_in(data.call.extension_deadline_unix_ms, deadline(timeout_ms))
    data = %{data | extension_votes: %{}}
    broadcast(data)
    {:keep_state, data, [{:state_timeout, timeout_ms, :vote_timeout}]}
  end

  # Timers.
  def handle_event(:state_timeout, :activate, :connecting, data) do
    Logger.info("call_activated call_id=#{data.call.id}")
    {:next_state, :active, %{data | call: Lifecycle.activate(data.call)}}
  end

  def handle_event(event_type, :time_up, :active, data)
      when event_type in [:state_timeout, :cast] do
    Logger.info("call_time_limit_reached call_id=#{data.call.id}")
    {:next_state, :extension_pending, %{data | call: Lifecycle.request_extension(data.call)}}
  end

  def handle_event(:state_timeout, :vote_timeout, :extension_pending, data) do
    Logger.info("call_extension_timeout call_id=#{data.call.id}")
    {:stop, :normal, end_call(data, :extension_timeout)}
  end

  # Participant requests.
  def handle_event({:call, from}, {:hang_up, _participant_id}, state, data) do
    Logger.info("call_hangup call_id=#{data.call.id} status=#{state}")
    {:stop_and_reply, :normal, [{:reply, from, :ok}], end_call(data, :hangup)}
  end

  def handle_event(
        {:call, from},
        {:extension_vote, participant_id, vote},
        :extension_pending,
        data
      ) do
    data = %{data | extension_votes: Map.put(data.extension_votes, participant_id, vote)}

    cond do
      vote == :end ->
        Logger.info("call_extension_declined call_id=#{data.call.id}")
        {:stop_and_reply, :normal, [{:reply, from, :ok}], end_call(data, :extension_declined)}

      both_participants_voted_continue?(data) ->
        extend_call(from, data)

      true ->
        {:keep_state, data, [{:reply, from, :ok}]}
    end
  end

  def handle_event({:call, from}, {:extension_vote, _participant_id, _vote}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_extension_pending}}]}
  end

  def handle_event({:call, from}, {:relay_signal, participant_id, type, payload}, _state, data) do
    case Signaling.build_message(data.call, participant_id, type, payload) do
      {:ok, message} ->
        Logger.debug(
          "call_signal_relay call_id=#{message.call_id} type=#{message.type} from=#{message.from_participant_id}"
        )

        relay_signal_to_peer(data, message)

        if message.type in [:connection_failed, :peer_disconnected] do
          {:stop_and_reply, :normal, [{:reply, from, :ok}], end_call(data, message.type)}
        else
          {:keep_state_and_data, [{:reply, from, :ok}]}
        end

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # A participant's LiveView went away.
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data)
      when is_map_key(data.monitors, ref) do
    Logger.info("call_participant_down call_id=#{data.call.id} reason=#{inspect(reason)}")
    {:stop, :normal, end_call(data, :disconnected)}
  end

  # Stale casts (e.g. time_up outside :active) and unrelated messages.
  def handle_event(_event_type, _event, _state, _data), do: :keep_state_and_data

  ## Helpers

  defp extend_call(from, data) do
    case Lifecycle.extend(data.call) do
      {:ok, call} ->
        Logger.info("call_extended call_id=#{call.id}")
        {:next_state, :active, %{data | call: call}, [{:reply, from, :ok}]}

      {:error, :max_extensions} ->
        {:stop_and_reply, :normal, [{:reply, from, :ok}], end_call(data, :max_duration_reached)}
    end
  end

  defp end_call(data, reason) do
    Logger.info("call_ended call_id=#{data.call.id} reason=#{reason} status=#{data.call.status}")
    demonitor_participants(data)
    data = %{data | call: Lifecycle.end_call(data.call, reason)}
    broadcast(data)
    data
  end

  defp both_participants_voted_continue?(%{call: %Call{match: match}} = data) do
    Enum.all?([match.participant_a.id, match.participant_b.id], fn participant_id ->
      Map.get(data.extension_votes, participant_id) == :continue
    end)
  end

  defp monitor_participants(match) do
    Map.new([:participant_a, :participant_b], fn role ->
      participant = Map.fetch!(match, role)
      {Process.monitor(participant.pid), role}
    end)
  end

  defp demonitor_participants(data) do
    Enum.each(Map.keys(data.monitors), &Process.demonitor(&1, [:flush]))
  end

  defp deadline(duration_ms), do: System.system_time(:millisecond) + duration_ms

  defp safe_call(call_pid, message) when is_pid(call_pid) do
    :gen_statem.call(call_pid, message)
  catch
    :exit, {:noproc, _} -> {:error, :call_unavailable}
    :exit, {:normal, _} -> {:error, :call_unavailable}
    :exit, {:shutdown, _} -> {:error, :call_unavailable}
  end

  # The single call-event message: `{:call_updated, %Call{}}`, sent to both
  # participants on every status change (including the initial :connecting).
  defp broadcast(%{call: %Call{match: match} = call} = data) do
    Phoenix.PubSub.broadcast(data.pubsub, match.participant_a.topic, {:call_updated, call})
    Phoenix.PubSub.broadcast(data.pubsub, match.participant_b.topic, {:call_updated, call})
  end

  defp relay_signal_to_peer(data, message) do
    {:ok, peer} = Match.peer(data.call.match, message.from_participant_id)
    Phoenix.PubSub.broadcast(data.pubsub, peer.topic, {:signaling, message})
  end
end
