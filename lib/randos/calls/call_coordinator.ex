defmodule Randos.Calls.CallCoordinator do
  @moduledoc """
  Per-call coordination process, implemented as a `:gen_statem`.

  States mirror `Randos.Calls.Call` status (`:connecting`, `:active`,
  `:extension_pending`); the process stops when the call ends. Every timer is a
  `state_timeout`, so leaving a state cancels its timer automatically:

    * `:connecting` — for a call with audio, waits until both participants
      report their media `connected` (then `:active`, and the call clock
      starts), or ends `:connection_failed` after `connect_timeout_ms`. A
      text-only call (neither client has audio) becomes `:active` after
      `activation_delay_ms`.
    * `:active` — runs the call segment, then asks for an extension
    * `:extension_pending` — waits for both votes, or times out and ends

  It owns call health: participants report their raw `media_state`
  (`Randos.Signaling.classify/2`); a participant `disconnected` longer than
  `disconnected_grace_ms` (a per-participant timer that survives status
  changes), or reporting `failed`, ends the call `:connection_failed`.

  The coordinator also monitors both participants, relays WebRTC media
  signaling between them, and broadcasts `{:call_updated, %Call{}}` to both
  on every status or media change; that and `{:signaling, message}` are the only messages
  participants receive about a call. It never touches
  audio. It is `:temporary`: a finished call is never restarted.
  """

  @behaviour :gen_statem

  require Logger

  alias Randos.Calls.Call
  alias Randos.Calls.Lifecycle
  alias Randos.Matchmaking.Match
  alias Randos.Signaling

  # A call that never connected stops with this reason (a normal exit to
  # OTP), so the Matchmaker knows not to keep the two apart: they can be
  # matched again straight away. Every other ending stops :normal.
  @failed {:shutdown, :connection_failed}

  @overridable [
    :pubsub,
    :ice_transport_policy,
    :activation_delay_ms,
    :connect_timeout_ms,
    :disconnected_grace_ms,
    :call_duration_ms,
    :extension_duration_ms,
    :extension_response_timeout_ms
  ]

  defstruct [
    :call,
    :started_at,
    pubsub: Randos.PubSub,
    extension_votes: %{},
    monitors: %{},
    ice_transport_policy: "all",
    activation_delay_ms: 750,
    connect_timeout_ms: Lifecycle.connect_timeout_seconds() * 1_000,
    disconnected_grace_ms: Lifecycle.disconnected_grace_seconds() * 1_000,
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
      |> Map.merge(%{
        call: Call.new(self(), match, data_policy(opts)),
        monitors: monitor_participants(match),
        started_at: System.monotonic_time()
      })

    # Every log line from this process carries the call and match ids.
    Logger.metadata(call_id: data.call.id, match_id: match.id)
    Logger.info("call started")

    :telemetry.execute([:randos, :call, :start], %{system_time: System.system_time()}, %{
      call_id: data.call.id
    })

    {:ok, :connecting, data}
  end

  @impl :gen_statem
  # Entering a state: arm its timer and tell both participants.
  def handle_event(:enter, _old, :connecting, data) do
    broadcast(data)

    if Lifecycle.audio?(data.call),
      do: {:keep_state_and_data, [{:state_timeout, data.connect_timeout_ms, :connect_timeout}]},
      else: {:keep_state_and_data, [{:state_timeout, data.activation_delay_ms, :activate}]}
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
    Logger.info("call activated")
    {:next_state, :active, %{data | call: Lifecycle.activate(data.call)}}
  end

  def handle_event(:state_timeout, :connect_timeout, :connecting, data) do
    Logger.info("call media never connected", media: inspect(data.call.media))
    {:stop, @failed, end_call(data, :connection_failed)}
  end

  def handle_event({:timeout, {:grace, participant_id}}, :grace, _state, data) do
    if Map.get(data.call.media, participant_id) == :disconnected do
      Logger.info("call media stayed disconnected")
      {:stop, @failed, end_call(data, :connection_failed)}
    else
      :keep_state_and_data
    end
  end

  def handle_event(event_type, :time_up, :active, data)
      when event_type in [:state_timeout, :cast] do
    Logger.info("call time limit reached")
    {:next_state, :extension_pending, %{data | call: Lifecycle.request_extension(data.call)}}
  end

  def handle_event(:state_timeout, :vote_timeout, :extension_pending, data) do
    Logger.info("call extension vote timed out")
    {:stop, :normal, end_call(data, :extension_timeout)}
  end

  # Participant requests.
  def handle_event({:call, from}, {:hang_up, _participant_id}, state, data) do
    Logger.info("call hung up", status: state)
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
        Logger.info("call extension declined")
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

  def handle_event({:call, from}, {:relay_signal, participant_id, type, payload}, state, data) do
    with {:ok, message} <- Signaling.build_message(data.call, participant_id, type, payload),
         {:ok, action} <- Signaling.classify(message.type, message.payload) do
      handle_signal(action, message, from, state, data)
    else
      {:error, reason} -> {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # A participant's LiveView went away.
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data)
      when is_map_key(data.monitors, ref) do
    Logger.info("call participant went away", reason: inspect(reason))
    {:stop, :normal, end_call(data, :disconnected)}
  end

  # Stale casts (e.g. time_up outside :active) and unrelated messages.
  def handle_event(_event_type, _event, _state, _data), do: :keep_state_and_data

  ## Helpers

  defp handle_signal(:relay, message, from, _state, data) do
    case enforce_policy(data.call, message) do
      {:ok, message} ->
        Logger.debug("call signal relayed", status: message.type)
        relay_signal_to_peer(data, message)

      # A direct candidate in a relay-only call: the peer must never see it.
      # The sender isn't told (an older client would only retry).
      :drop ->
        Logger.debug("call signal dropped (relay-only)", status: message.type)
    end

    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  defp handle_signal(:leave, _message, from, _state, data),
    do: {:stop_and_reply, :normal, [{:reply, from, :ok}], end_call(data, :peer_disconnected)}

  defp handle_signal({:media, :failed}, _message, from, _state, data),
    do: {:stop_and_reply, @failed, [{:reply, from, :ok}], end_call(data, :connection_failed)}

  defp handle_signal({:media, media}, message, from, state, data) do
    id = message.from_participant_id
    unchanged? = Map.get(data.call.media, id) == media
    data = %{data | call: Lifecycle.put_media(data.call, id, media)}
    # Only a change arms or cancels the grace timer (a repeated
    # `disconnected` must not extend it).
    timers = if unchanged?, do: [], else: grace_timer(id, media, state, data)
    actions = [{:reply, from, :ok} | timers]

    cond do
      state == :connecting and Lifecycle.audio?(data.call) and
          Lifecycle.media_connected?(data.call) ->
        Logger.info("call media connected")
        {:next_state, :active, %{data | call: Lifecycle.activate(data.call)}, actions}

      unchanged? ->
        {:keep_state, data, actions}

      true ->
        broadcast(data)
        {:keep_state, data, actions}
    end
  end

  # While connecting, the connect timeout covers a disconnect.
  defp grace_timer(_id, _media, :connecting, _data), do: []

  defp grace_timer(id, :disconnected, _state, data),
    do: [{{:timeout, {:grace, id}}, data.disconnected_grace_ms, :grace}]

  defp grace_timer(id, :connected, _state, _data), do: [{{:timeout, {:grace, id}}, :cancel}]

  defp extend_call(from, data) do
    case Lifecycle.extend(data.call) do
      {:ok, call} ->
        Logger.info("call extended")
        {:next_state, :active, %{data | call: call}, [{:reply, from, :ok}]}

      {:error, :max_extensions} ->
        {:stop_and_reply, :normal, [{:reply, from, :ok}], end_call(data, :max_duration_reached)}
    end
  end

  defp end_call(data, reason) do
    Logger.info("call ended", reason: reason, status: data.call.status)
    demonitor_participants(data)
    data = %{data | call: Lifecycle.end_call(data.call, reason)}

    :telemetry.execute(
      [:randos, :call, :stop],
      %{duration: System.monotonic_time() - data.started_at},
      %{call_id: data.call.id, reason: reason, extension_count: data.call.extension_count}
    )

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
    :telemetry.execute([:randos, :call, :status], %{count: 1}, %{
      call_id: call.id,
      status: call.status
    })

    Phoenix.PubSub.broadcast(data.pubsub, match.participant_a.topic, {:call_updated, call})
    Phoenix.PubSub.broadcast(data.pubsub, match.participant_b.topic, {:call_updated, call})
  end

  defp enforce_policy(%Call{ice_transport_policy: "relay"}, message) do
    with {:ok, payload} <- Signaling.relay_only(message.type, message.payload),
         do: {:ok, %{message | payload: payload}}
  end

  defp enforce_policy(_call, message), do: {:ok, message}

  defp data_policy(opts), do: Keyword.get(opts, :ice_transport_policy, "all")

  defp relay_signal_to_peer(data, message) do
    {:ok, peer} = Match.peer(data.call.match, message.from_participant_id)
    Phoenix.PubSub.broadcast(data.pubsub, peer.topic, {:signaling, message})
  end
end
