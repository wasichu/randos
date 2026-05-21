defmodule Randos.Calls.CallCoordinator do
  @moduledoc """
  Per-call mock coordination process.

  This process owns ephemeral call state: timers, participant monitors, hangups,
  and extension votes. It updates the Ash `CallSession` resource for domain
  lifecycle validation, but it does not handle audio or WebRTC.
  """

  use GenServer

  alias Randos.Comms.CallSession

  defstruct [
    :match,
    :call_session,
    :status,
    :timeout_ref,
    :extension_timeout_ref,
    :call_deadline_unix_ms,
    pubsub: Randos.PubSub,
    extension_votes: %{},
    monitors: %{},
    activation_delay_ms: 750,
    call_duration_ms: CallSession.default_call_duration_seconds() * 1_000,
    extension_duration_ms: CallSession.extension_duration_seconds() * 1_000,
    extension_response_timeout_ms: CallSession.extension_response_timeout_seconds() * 1_000
  ]

  def start_match(match, opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, Randos.Calls.CallSupervisor)
    child_opts = Keyword.drop(opts, [:supervisor])

    DynamicSupervisor.start_child(
      supervisor,
      {__MODULE__, Keyword.put(child_opts, :match, match)}
    )
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def hang_up(call_pid, participant_id) do
    GenServer.call(call_pid, {:hang_up, participant_id})
  end

  def vote_extension(call_pid, participant_id, vote) when vote in [:continue, :end] do
    GenServer.call(call_pid, {:extension_vote, participant_id, vote})
  end

  def force_time_up(call_pid) do
    send(call_pid, :call_time_limit_reached)
    :ok
  end

  @impl true
  def init(opts) do
    match = Keyword.fetch!(opts, :match)

    with {:ok, call_session} <- create_call_session(match) do
      monitors = monitor_participants(match)
      activation_delay_ms = Keyword.get(opts, :activation_delay_ms, 750)
      Process.send_after(self(), :activate_call, activation_delay_ms)

      state = %__MODULE__{
        match: Map.merge(match, %{call_id: call_session.id, call_pid: self()}),
        call_session: call_session,
        status: :connecting,
        monitors: monitors,
        pubsub: Keyword.get(opts, :pubsub, Randos.PubSub),
        activation_delay_ms: activation_delay_ms,
        call_duration_ms:
          Keyword.get(
            opts,
            :call_duration_ms,
            CallSession.default_call_duration_seconds() * 1_000
          ),
        extension_duration_ms:
          Keyword.get(
            opts,
            :extension_duration_ms,
            CallSession.extension_duration_seconds() * 1_000
          ),
        extension_response_timeout_ms:
          Keyword.get(
            opts,
            :extension_response_timeout_ms,
            CallSession.extension_response_timeout_seconds() * 1_000
          )
      }

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:hang_up, _participant_id}, _from, state) do
    state = end_call(state, :hangup)
    {:stop, :normal, :ok, state}
  end

  def handle_call(
        {:extension_vote, participant_id, vote},
        _from,
        %{status: :extension_pending} = state
      ) do
    state = record_extension_vote(state, participant_id, vote)

    cond do
      vote == :end ->
        state = end_call(state, :extension_declined)
        {:stop, :normal, :ok, state}

      both_participants_voted_continue?(state) ->
        case extend_call(state) do
          {:ok, state} ->
            {:reply, :ok, state}

          {:error, state} ->
            state = end_call(state, :max_duration_reached)
            {:stop, :normal, :ok, state}
        end

      true ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:extension_vote, _participant_id, _vote}, _from, state) do
    {:reply, {:error, :not_extension_pending}, state}
  end

  @impl true
  def handle_info(:activate_call, %{status: :connecting} = state) do
    {:ok, call_session} =
      state.call_session
      |> Ash.Changeset.for_update(:mark_active)
      |> Ash.update()

    state =
      %{state | call_session: call_session, status: :active}
      |> schedule_call_timeout(state.call_duration_ms)

    broadcast(state, {:mock_call_active, public_call_state(state)})

    {:noreply, state}
  end

  def handle_info(:call_time_limit_reached, %{status: :active} = state) do
    {:ok, call_session} =
      state.call_session
      |> Ash.Changeset.for_update(:mark_extension_pending)
      |> Ash.update()

    extension_timeout_ref =
      Process.send_after(self(), :extension_response_timeout, state.extension_response_timeout_ms)

    state = %{
      state
      | call_session: call_session,
        status: :extension_pending,
        timeout_ref: nil,
        extension_timeout_ref: extension_timeout_ref,
        extension_votes: %{}
    }

    broadcast(state, {:mock_call_extension_pending, public_call_state(state)})

    {:noreply, state}
  end

  def handle_info(:extension_response_timeout, %{status: :extension_pending} = state) do
    state = end_call(state, :extension_timeout)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if Map.has_key?(state.monitors, ref) do
      state = end_call(state, :disconnected)
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp create_call_session(match) do
    CallSession
    |> Ash.Changeset.for_create(:create_connecting_call, %{
      speaks_language_a: match.participant_a.speaks_language,
      listens_language_a: match.participant_a.listens_language,
      speaks_language_b: match.participant_b.speaks_language,
      listens_language_b: match.participant_b.listens_language
    })
    |> Ash.create()
  end

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
        call_deadline_unix_ms: System.system_time(:millisecond) + duration_ms
    }
  end

  defp record_extension_vote(state, participant_id, vote) do
    %{state | extension_votes: Map.put(state.extension_votes, participant_id, vote)}
  end

  defp both_participants_voted_continue?(state) do
    participant_ids = [
      state.match.participant_a.id,
      state.match.participant_b.id
    ]

    Enum.all?(participant_ids, fn participant_id ->
      Map.get(state.extension_votes, participant_id) == :continue
    end)
  end

  defp extend_call(state) do
    case state.call_session
         |> Ash.Changeset.for_update(:extend_call)
         |> Ash.update() do
      {:ok, call_session} ->
        cancel_timer(state.extension_timeout_ref)

        state =
          %{
            state
            | call_session: call_session,
              status: :active,
              extension_timeout_ref: nil,
              extension_votes: %{}
          }
          |> schedule_call_timeout(state.extension_duration_ms)

        broadcast(state, {:mock_call_extended, public_call_state(state)})
        {:ok, state}

      {:error, _error} ->
        {:error, state}
    end
  end

  defp end_call(state, reason) do
    cancel_timer(state.timeout_ref)
    cancel_timer(state.extension_timeout_ref)

    call_session =
      if state.status == :ended do
        state.call_session
      else
        state.call_session
        |> Ash.Changeset.for_update(:end_call, %{ended_reason: reason})
        |> Ash.update!()
      end

    state = %{state | call_session: call_session, status: :ended}
    broadcast(state, {:mock_call_ended, public_call_state(state)})
    demonitor_participants(state)
    state
  end

  defp demonitor_participants(state) do
    Enum.each(Map.keys(state.monitors), &Process.demonitor(&1, [:flush]))
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(state.pubsub, state.match.participant_a.topic, message)
    Phoenix.PubSub.broadcast(state.pubsub, state.match.participant_b.topic, message)
  end

  defp public_call_state(state) do
    %{
      call_id: state.call_session.id,
      call_pid: self(),
      status: state.status,
      match: state.match,
      extension_count: state.call_session.extension_count,
      max_duration_seconds: state.call_session.max_duration_seconds,
      call_deadline_unix_ms: state.call_deadline_unix_ms,
      ended_reason: state.call_session.ended_reason
    }
  end
end
