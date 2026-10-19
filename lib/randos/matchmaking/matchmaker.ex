defmodule Randos.Matchmaking.Matchmaker do
  @moduledoc """
  In-memory anonymous matchmaking queue.

  This process owns live queue membership only. Queue state is intentionally
  transient and disappears when the process or server stops.
  """

  use GenServer

  require Logger

  alias Randos.Calls.CallCoordinator
  alias Randos.ConversationLanguages
  alias Randos.Matchmaking.Entry
  alias Randos.Matchmaking.Match

  defstruct queues: %{},
            participants: %{},
            monitors: %{},
            call_supervisor: Randos.Calls.CallSupervisor,
            call_options: [],
            call_starter: {CallCoordinator, :start_match}

  @supported_language_codes ConversationLanguages.codes()

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Joins the queue or immediately matches with a compatible waiting participant.

  On a match the call's coordinator is started and the joiner gets
  `{:matched, match}` (with `call_pid`); both participants then hear about the
  call only from the coordinator, as `{:call_updated, %Call{}}`.
  """
  def join(attrs), do: join(__MODULE__, attrs)

  def join(server, attrs) do
    GenServer.call(server, {:join, attrs})
  end

  @doc """
  Leaves the queue if the participant is currently waiting.
  """
  def leave(pid) when is_pid(pid), do: leave(__MODULE__, pid)

  def leave(server, pid) when is_pid(pid) do
    GenServer.call(server, {:leave, pid})
  end

  @doc """
  Returns a lightweight snapshot for tests and diagnostics.
  """
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       call_supervisor: Keyword.get(opts, :call_supervisor, Randos.Calls.CallSupervisor),
       call_options: Keyword.get(opts, :call_options, []),
       call_starter: Keyword.get(opts, :call_starter, {CallCoordinator, :start_match})
     }}
  end

  @impl true
  def handle_call({:join, attrs}, _from, state) do
    participant = entry_from_attrs(attrs)

    cond do
      Map.get(attrs, :accepted_adult_terms) != true ->
        {:reply, {:error, :adult_terms_required}, state}

      not supported_language?(participant.speaks_language) or
          not supported_language?(participant.listens_language) ->
        {:reply, {:error, :unsupported_language}, state}

      Map.has_key?(state.participants, participant.pid) ->
        {:reply, {:error, :already_queued}, state}

      true ->
        Logger.debug("matchmaking_join participant_id=#{participant.id}")
        join_queue(participant, state)
    end
  end

  def handle_call({:leave, pid}, _from, state) do
    Logger.debug(
      "matchmaking_leave pid=#{inspect(pid)} queued=#{Map.has_key?(state.participants, pid)}"
    )

    if Map.has_key?(state.participants, pid) do
      {:reply, :ok, remove_participant(pid, state)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      queued_count: map_size(state.participants),
      queues:
        Map.new(state.queues, fn {key, participants} ->
          {key, Enum.map(participants, & &1.id)}
        end)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.monitors do
      %{^ref => ^pid} ->
        Logger.info("matchmaking_participant_down pid=#{inspect(pid)}")
        {:noreply, remove_participant(pid, state)}

      _monitors ->
        {:noreply, state}
    end
  end

  defp join_queue(participant, state) do
    compatible_key = {participant.listens_language, participant.speaks_language}

    case pop_waiting_participant(state, compatible_key) do
      {%{} = waiting_participant, state} ->
        match = Match.new(waiting_participant, participant)

        case start_call(match, state) do
          {:ok, call_pid} ->
            match = %{match | call_pid: call_pid}
            Logger.info("matchmaking_matched match_id=#{match.id}")
            {:reply, {:matched, match}, state}

          {:error, reason} ->
            Logger.warning(
              "matchmaking_call_start_failed match_id=#{match.id} reason=#{inspect(reason)}"
            )

            # Not the waiting participant's fault: give them their place back.
            state = add_participant(waiting_participant, state, :front)
            {:reply, {:error, :call_start_failed}, state}
        end

      {nil, state} ->
        Logger.debug("matchmaking_queued participant_id=#{participant.id}")
        state = add_participant(participant, state)
        {:reply, :queued, state}
    end
  end

  defp add_participant(participant, state, position \\ :back) do
    key = {participant.speaks_language, participant.listens_language}
    ref = Process.monitor(participant.pid)

    enqueue =
      case position do
        :back -> &(&1 ++ [participant])
        :front -> &[participant | &1]
      end

    %{
      state
      | queues: Map.update(state.queues, key, [participant], enqueue),
        participants: Map.put(state.participants, participant.pid, {key, participant, ref}),
        monitors: Map.put(state.monitors, ref, participant.pid)
    }
  end

  defp pop_waiting_participant(state, key) do
    case Map.get(state.queues, key, []) do
      [] ->
        {nil, state}

      [participant | rest] ->
        {_key, _participant, ref} = Map.fetch!(state.participants, participant.pid)
        Process.demonitor(ref, [:flush])

        queues =
          if rest == [] do
            Map.delete(state.queues, key)
          else
            Map.put(state.queues, key, rest)
          end

        {participant,
         %{
           state
           | queues: queues,
             participants: Map.delete(state.participants, participant.pid),
             monitors: Map.delete(state.monitors, ref)
         }}
    end
  end

  defp remove_participant(pid, state) do
    case Map.pop(state.participants, pid) do
      {nil, participants} ->
        %{state | participants: participants}

      {{key, participant, ref}, participants} ->
        Process.demonitor(ref, [:flush])

        queues =
          state.queues
          |> Map.update(key, [], &Enum.reject(&1, fn queued -> queued.pid == participant.pid end))
          |> drop_empty_queue(key)

        %{
          state
          | queues: queues,
            participants: participants,
            monitors: Map.delete(state.monitors, ref)
        }
    end
  end

  defp drop_empty_queue(queues, key) do
    case Map.get(queues, key) do
      [] -> Map.delete(queues, key)
      _participants -> queues
    end
  end

  defp entry_from_attrs(attrs) do
    %Entry{
      id: Map.fetch!(attrs, :id),
      pid: Map.fetch!(attrs, :pid),
      topic: Map.fetch!(attrs, :topic),
      speaks_language: Map.fetch!(attrs, :speaks_language),
      listens_language: Map.fetch!(attrs, :listens_language)
    }
  end

  defp supported_language?(code), do: code in @supported_language_codes

  defp start_call(match, state) do
    call_options =
      state.call_options
      |> Keyword.put(:supervisor, state.call_supervisor)

    case apply_call_starter(state.call_starter, match, call_options) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp apply_call_starter({module, function}, match, call_options) do
    apply(module, function, [match, call_options])
  end

  defp apply_call_starter(function, match, call_options) when is_function(function, 2) do
    function.(match, call_options)
  end
end
