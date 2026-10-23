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
  (`Randos.Signaling.classify/2`). Once active, a call is unhealthy while
  anyone's media is down (in a call with audio) or anyone is away (their
  connection to the server dropped; `call.away`). From the moment it turns
  unhealthy it has one deadline, `recovery_budget_ms`
  (`Lifecycle.recovery_budget_seconds/0`), shown as `call.recovering`; it
  ends then with a reason from what's still wrong (`:disconnected` if
  someone is still away, else `:connection_failed`), and healthy again
  cancels it. Inside the budget the coordinator does the most useful thing
  it can:

    * someone away: wait for them. If they come back with their resume
      ticket (`resume/4`, `Randos.Calls.ResumeTicket`), the new process
      takes their place. Leaving on purpose (`peer_disconnected`, hanging
      up) still ends the call at once.
    * in a call whose two clients can restart ICE (`Call.ice_restart?`,
      obligation 10): media `disconnected` past `ice_restart_delay_ms`, or
      `failed`, or a resume with media down, bumps `call.ice_generation`,
      asking the offerer for an ICE restart, then again every
      `ice_restart_retry_ms` until healthy or out of budget. The server
      decides and only the offerer offers, so restart offers never cross.
    * otherwise: wait (ICE may recover by itself); `failed` without
      restart ends the call `:connection_failed` at once.

  While connecting, the connect timeout covers media; away still counts.

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
  alias Randos.Calls.ResumeTicket
  alias Randos.Matchmaking.Entry
  alias Randos.Matchmaking.Match
  alias Randos.Signaling

  # A call that never connected stops with this reason (a normal exit to
  # OTP), so the Matchmaker knows not to keep the two apart: they can be
  # matched again straight away. Every other ending stops :normal.
  @failed {:shutdown, :connection_failed}

  @overridable [
    :pubsub,
    :tickets,
    :recovery_budget_ms,
    :ice_transport_policy,
    :activation_delay_ms,
    :connect_timeout_ms,
    :ice_restart_delay_ms,
    :ice_restart_retry_ms,
    :call_duration_ms,
    :extension_duration_ms,
    :extension_response_timeout_ms
  ]

  defstruct [
    :call,
    :started_at,
    # When the call became active (monotonic), for its connected length.
    :activated_at,
    pubsub: Randos.PubSub,
    monitors: %{},
    # Participant id => the registry key of their current resume ticket.
    resume_keys: %{},
    tickets: ResumeTicket.registry(),
    recovery_budget_ms: Lifecycle.recovery_budget_seconds() * 1_000,
    ice_transport_policy: "all",
    # How soon a call without audio goes active (there's no media to wait
    # for). Not a Lifecycle constant: no client times anything by it.
    activation_delay_ms: 750,
    connect_timeout_ms: Lifecycle.connect_timeout_seconds() * 1_000,
    ice_restart_delay_ms: Lifecycle.ice_restart_delay_seconds() * 1_000,
    ice_restart_retry_ms: Lifecycle.ice_restart_retry_seconds() * 1_000,
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

  @doc """
  Puts `pid` in the seat of `participant_id`, whose resume `ticket` this is
  (its previous process went away, or is about to be replaced): the call
  monitors `pid` from now on and sends it this participant's messages.
  Replies with the call, the participant's queue entry, and a fresh ticket
  (each works once). `{:error, :invalid_ticket}` otherwise.
  """
  @spec resume(pid(), String.t(), String.t(), pid()) ::
          {:ok, %{call: Call.t(), entry: Entry.t(), ticket: String.t()}}
          | {:error, :invalid_ticket | :call_unavailable}
  def resume(call_pid, participant_id, ticket, pid) when is_binary(ticket) do
    safe_call(call_pid, {:resume, participant_id, ResumeTicket.key(ticket), pid})
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

    data = struct!(__MODULE__, Keyword.take(opts, @overridable))

    data =
      Map.merge(data, %{
        call: Call.new(self(), match, data.ice_transport_policy),
        monitors: monitor_participants(match),
        started_at: System.monotonic_time()
      })

    # Every log line from this process carries the call and match ids.
    Logger.metadata(call_id: data.call.id, match_id: match.id)
    Logger.info("call started")

    # The two speaking languages (sorted) feed the public, aggregate counts
    # (Randos.Stats); nothing about who is in the call.
    :telemetry.execute([:randos, :call, :start], %{system_time: System.system_time()}, %{
      call_id: data.call.id,
      languages:
        Enum.sort([match.participant_a.speaks_language, match.participant_b.speaks_language])
    })

    {:ok, :connecting, data}
  end

  @impl :gen_statem
  # Entering a state: arm its timer and tell both participants.
  def handle_event(:enter, _old, :connecting, data) do
    broadcast(data)
    # After the broadcast, so each participant already knows this call.
    data = Enum.reduce(participant_ids(data), data, &issue_ticket(&2, &1))

    if Lifecycle.audio?(data.call),
      do: {:keep_state, data, [{:state_timeout, data.connect_timeout_ms, :connect_timeout}]},
      else: {:keep_state, data, [{:state_timeout, data.activation_delay_ms, :activate}]}
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
    broadcast(data)
    {:keep_state, data, [{:state_timeout, timeout_ms, :vote_timeout}]}
  end

  # Timers.
  def handle_event(:state_timeout, :activate, :connecting, data) do
    Logger.info("call activated")
    {:next_state, :active, activate(data)}
  end

  def handle_event(:state_timeout, :connect_timeout, :connecting, data) do
    Logger.info("call media never connected", media: inspect(data.call.media))
    {:stop, @failed, end_call(data, :connection_failed)}
  end

  # Recovery (see the moduledoc): out of budget, the call ends with what's
  # still wrong.
  def handle_event({:timeout, :recovery}, :recovery, state, data) do
    cond do
      not unhealthy?(state, data) ->
        :keep_state_and_data

      data.call.away != [] ->
        Logger.info("call participant didn't come back")
        {:stop, :normal, end_call(data, :disconnected)}

      true ->
        Logger.info("call media didn't come back", media: inspect(data.call.media))
        {:stop, @failed, end_call(data, :connection_failed)}
    end
  end

  def handle_event({:timeout, :restart}, :restart, state, data) do
    if restart_now?(state, data), do: restart(data), else: :keep_state_and_data
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
    cond do
      vote == :end ->
        Logger.info("call extension declined")
        {:stop_and_reply, :normal, [{:reply, from, :ok}], end_call(data, :extension_declined)}

      participant_id in data.call.continuing ->
        # A repeat (after a resume, say): already counted.
        {:keep_state_and_data, [{:reply, from, :ok}]}

      true ->
        data = update_in(data.call.continuing, &[participant_id | &1])

        if both_participants_continuing?(data.call) do
          extend_call(from, data)
        else
          # So each client can show whether its vote counted.
          broadcast(data)
          {:keep_state, data, [{:reply, from, :ok}]}
        end
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

  # A participant's process went away (its connection dropped): wait for
  # them to come back with their ticket rather than ending the call.
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, state, data)
      when is_map_key(data.monitors, ref) do
    {role, monitors} = Map.pop(data.monitors, ref)
    id = Map.fetch!(data.call.match, role).id
    Logger.info("call participant went away; waiting for them", reason: inspect(reason))

    data = %{
      data
      | monitors: monitors,
        call: %{data.call | away: Enum.uniq([id | data.call.away])}
    }

    {data, actions} = reassess(state, data)
    broadcast(data)
    {:keep_state, data, actions}
  end

  def handle_event({:call, from}, {:resume, participant_id, key, pid}, state, data) do
    with ^key <- Map.get(data.resume_keys, participant_id),
         role when role != nil <- role_of(data.call.match, participant_id) do
      data = take_seat(data, role, participant_id, pid)
      {data, ticket} = issue_ticket(data, participant_id, :reply)
      Logger.info("call participant came back")
      # Whatever was asked while someone was away may never have arrived.
      {data, actions} = recover(state, data)
      entry = Map.fetch!(data.call.match, role)

      {:keep_state, data,
       [{:reply, from, {:ok, %{call: data.call, entry: entry, ticket: ticket}}} | actions]}
    else
      _invalid -> {:keep_state_and_data, [{:reply, from, {:error, :invalid_ticket}}]}
    end
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

  # `failed` is final for this connection: with ICE restart, restart now
  # (recorded as disconnected; the budget bounds it); without, the end.
  defp handle_signal({:media, :failed}, message, from, state, data) do
    if restarts?(state, data) do
      id = message.from_participant_id
      data = %{data | call: Lifecycle.put_media(data.call, id, :disconnected)}
      {data, actions} = recover(state, data)
      {:keep_state, data, [{:reply, from, :ok} | actions]}
    else
      {:stop_and_reply, @failed, [{:reply, from, :ok}], end_call(data, :connection_failed)}
    end
  end

  defp handle_signal({:media, media}, message, from, state, data) do
    id = message.from_participant_id
    unchanged? = Map.get(data.call.media, id) == media
    data = %{data | call: Lifecycle.put_media(data.call, id, media)}
    # Only a change starts anything (a repeated `disconnected` must not
    # push a restart back).
    {data, timers} = if unchanged?, do: {data, []}, else: reassess(state, data)
    actions = [{:reply, from, :ok} | timers ++ restart_delay(unchanged?, media, state, data)]

    cond do
      state == :connecting and Lifecycle.audio?(data.call) and
          Lifecycle.media_connected?(data.call) ->
        Logger.info("call media connected")
        {:next_state, :active, activate(data), actions}

      unchanged? ->
        {:keep_state, data, actions}

      true ->
        broadcast(data)
        {:keep_state, data, actions}
    end
  end

  # Healthy or not, after anything that can change it: unhealthy starts the
  # one recovery deadline (and shows `call.recovering`); healthy again ends
  # it and every restart timer.
  defp activate(data),
    do: %{data | call: Lifecycle.activate(data.call), activated_at: System.monotonic_time()}

  # The call may have just turned unhealthy (or come back): its budget
  # timer, and an ICE restart asked for now if one is due (with its
  # retry), told to both participants.
  defp recover(state, data) do
    {data, actions} = reassess(state, data)
    data = if restart_now?(state, data), do: bump_generation(data), else: data
    broadcast(data)
    {data, actions ++ retry_if_restarting(state, data)}
  end

  defp reassess(state, data) do
    case {unhealthy?(state, data), data.call.recovering} do
      {true, false} ->
        {put_in(data.call.recovering, true),
         [{{:timeout, :recovery}, data.recovery_budget_ms, :recovery}]}

      {false, true} ->
        {put_in(data.call.recovering, false),
         [{{:timeout, :recovery}, :cancel}, {{:timeout, :restart}, :cancel}]}

      _same ->
        {data, []}
    end
  end

  defp unhealthy?(state, data),
    do: data.call.away != [] or media_down?(state, data)

  # Media counts once the call is up, and only in a call with audio.
  defp media_down?(state, data),
    do:
      state in [:active, :extension_pending] and Lifecycle.audio?(data.call) and
        not Lifecycle.media_connected?(data.call)

  # A new `disconnected` in a restart call: ask for a restart if it lasts
  # (a short loss often recovers by itself).
  defp restart_delay(false, :disconnected, state, data) do
    if restarts?(state, data),
      do: [{{:timeout, :restart}, data.ice_restart_delay_ms, :restart}],
      else: []
  end

  defp restart_delay(_unchanged?, _media, _state, _data), do: []

  defp restarts?(state, data),
    do: data.call.ice_restart? and state in [:active, :extension_pending]

  # A restart can help: media down, everyone here to hear the offer.
  defp restart_now?(state, data),
    do: restarts?(state, data) and data.call.away == [] and media_down?(state, data)

  # Ask the offerer for an ICE restart (obligation 10), and again after
  # `ice_restart_retry_ms` while it's still down (the budget bounds it).
  defp restart(data) do
    data = bump_generation(data)
    broadcast(data)
    {:keep_state, data, [{{:timeout, :restart}, data.ice_restart_retry_ms, :restart}]}
  end

  defp bump_generation(data) do
    data = update_in(data.call.ice_generation, &(&1 + 1))
    Logger.info("call ICE restart requested", status: "generation #{data.call.ice_generation}")
    data
  end

  defp retry_if_restarting(state, data) do
    if restart_now?(state, data),
      do: [{{:timeout, :restart}, data.ice_restart_retry_ms, :restart}],
      else: []
  end

  defp participant_ids(%{call: %Call{match: match}}),
    do: [match.participant_a.id, match.participant_b.id]

  defp role_of(match, id) do
    cond do
      match.participant_a.id == id -> :participant_a
      match.participant_b.id == id -> :participant_b
      true -> nil
    end
  end

  # The new process takes the participant's seat: monitored from now on, and
  # the old one (if it's still around, not yet noticed gone) is let go and
  # told, so it stops acting for this participant.
  defp take_seat(data, role, participant_id, pid) do
    {old_refs, monitors} = Enum.split_with(data.monitors, fn {_ref, r} -> r == role end)
    old_pid = Map.fetch!(data.call.match, role).pid

    Enum.each(old_refs, fn {ref, _role} -> Process.demonitor(ref, [:flush]) end)
    if old_pid != pid, do: send(old_pid, {:resumed_elsewhere, self()})

    monitors = Map.put(Map.new(monitors), Process.monitor(pid), role)
    match = Map.update!(data.call.match, role, &%{&1 | pid: pid})
    call = %{data.call | match: match, away: List.delete(data.call.away, participant_id)}
    %{data | monitors: monitors, call: call}
  end

  # A fresh, single-use ticket for a participant, replacing their last one:
  # sent to them (when the call starts), or returned for a resume's reply.
  defp issue_ticket(data, participant_id),
    do: issue_ticket(data, participant_id, :send) |> elem(0)

  defp issue_ticket(data, participant_id, how) do
    {ticket, key} = ResumeTicket.new()

    if old = data.resume_keys[participant_id], do: Registry.unregister(data.tickets, old)
    {:ok, _owner} = Registry.register(data.tickets, key, participant_id)
    data = %{data | resume_keys: Map.put(data.resume_keys, participant_id, key)}

    if how == :send do
      role = role_of(data.call.match, participant_id)
      topic = Map.fetch!(data.call.match, role).topic
      Phoenix.PubSub.broadcast(data.pubsub, topic, {:resume_ticket, self(), ticket})
    end

    {data, ticket}
  end

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

    now = System.monotonic_time()

    # `connected`: how long the call was active (nil if it never was).
    :telemetry.execute(
      [:randos, :call, :stop],
      %{duration: now - data.started_at, connected: data.activated_at && now - data.activated_at},
      %{call_id: data.call.id, reason: reason, extension_count: data.call.extension_count}
    )

    broadcast(data)
    data
  end

  defp both_participants_continuing?(%Call{match: match, continuing: continuing}) do
    match.participant_a.id in continuing and match.participant_b.id in continuing
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

  defp relay_signal_to_peer(data, message) do
    {:ok, peer} = Match.peer(data.call.match, message.from_participant_id)
    Phoenix.PubSub.broadcast(data.pubsub, peer.topic, {:signaling, message})
  end
end
