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

  @typedoc """
  What `join/1` needs; `accepted_adult_terms` must be `true`. `audio?`
  (default `false`) is whether the client carries call audio: only entries
  that agree are matched, and queues are keyed by `{speaks, listens, audio?}`.
  """
  @type join_attrs :: %{
          required(:id) => String.t(),
          required(:pid) => pid(),
          required(:topic) => String.t(),
          required(:speaks_language) => String.t(),
          required(:listens_language) => String.t(),
          optional(:accepted_adult_terms) => boolean(),
          optional(:audio?) => boolean()
        }

  @type join_result ::
          :queued
          | {:matched, Match.t()}
          | {:error,
             :adult_terms_required | :unsupported_language | :already_queued | :call_start_failed}

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
  @spec join(GenServer.server(), join_attrs()) :: join_result()
  def join(server \\ __MODULE__, attrs)

  def join(server, attrs) when is_map(attrs) do
    GenServer.call(server, {:join, attrs})
  end

  @doc """
  Leaves the queue if the participant is currently waiting.
  """
  @spec leave(pid()) :: :ok
  def leave(pid) when is_pid(pid), do: leave(__MODULE__, pid)

  @spec leave(GenServer.server(), pid()) :: :ok

  def leave(server, pid) when is_pid(pid) do
    GenServer.call(server, {:leave, pid})
  end

  @doc """
  Returns a lightweight snapshot for tests and diagnostics.
  """
  @spec snapshot(GenServer.server()) :: %{queued_count: non_neg_integer(), queues: map()}
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
    {reply, state} = do_join(attrs, state)

    result =
      case reply do
        {:matched, _match} -> :matched
        {:error, reason} -> reason
        :queued -> :queued
      end

    Logger.debug("matchmaking join", result: result)

    :telemetry.execute(
      [:randos, :matchmaking, :join],
      %{queue_size: map_size(state.participants)},
      %{result: result}
    )

    {:reply, reply, state}
  end

  def handle_call({:leave, pid}, _from, state) do
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
        Logger.info("matchmaking participant went away while queued")
        {:noreply, remove_participant(pid, state)}

      _monitors ->
        {:noreply, state}
    end
  end

  defp do_join(attrs, state) do
    participant = entry_from_attrs(attrs)

    cond do
      Map.get(attrs, :accepted_adult_terms) != true ->
        {{:error, :adult_terms_required}, state}

      not supported_language?(participant.speaks_language) or
          not supported_language?(participant.listens_language) ->
        {{:error, :unsupported_language}, state}

      Map.has_key?(state.participants, participant.pid) ->
        {{:error, :already_queued}, state}

      true ->
        join_queue(participant, state)
    end
  end

  defp join_queue(participant, state) do
    compatible_key =
      {participant.listens_language, participant.speaks_language, participant.audio?}

    case pop_waiting_participant(state, compatible_key) do
      {%{} = waiting_participant, state} ->
        match = Match.new(waiting_participant, participant)

        case start_call(match, state) do
          {:ok, call_pid} ->
            Logger.info("matchmaking matched", match_id: match.id)
            {{:matched, %{match | call_pid: call_pid}}, state}

          {:error, reason} ->
            Logger.warning("matchmaking call start failed",
              match_id: match.id,
              reason: inspect(reason)
            )

            # Not the waiting participant's fault: give them their place back.
            {{:error, :call_start_failed}, add_participant(waiting_participant, state, :front)}
        end

      {nil, state} ->
        {:queued, add_participant(participant, state)}
    end
  end

  defp add_participant(participant, state, position \\ :back) do
    key = {participant.speaks_language, participant.listens_language, participant.audio?}
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
      listens_language: Map.fetch!(attrs, :listens_language),
      audio?: Map.get(attrs, :audio?, false) == true
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
