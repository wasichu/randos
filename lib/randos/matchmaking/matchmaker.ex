defmodule Randos.Matchmaking.Matchmaker do
  @moduledoc """
  In-memory anonymous matchmaking queue.

  This process owns live queue membership only. Queue state is intentionally not
  represented by Ash resources and disappears when the process or server stops.
  """

  use GenServer

  alias Randos.Calls.CallCoordinator
  alias Randos.ConversationLanguages

  @type language_code :: String.t()
  @type participant_id :: String.t()

  @type participant :: %{
          id: participant_id(),
          pid: pid(),
          topic: String.t(),
          speaks_language: language_code(),
          listens_language: language_code()
        }

  @type match :: %{
          id: String.t(),
          participant_a: participant(),
          participant_b: participant(),
          offerer: :participant_a,
          answerer: :participant_b
        }

  defstruct queues: %{},
            participants: %{},
            monitors: %{},
            pubsub: Randos.PubSub,
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
       pubsub: Keyword.get(opts, :pubsub, Randos.PubSub),
       call_supervisor: Keyword.get(opts, :call_supervisor, Randos.Calls.CallSupervisor),
       call_options: Keyword.get(opts, :call_options, []),
       call_starter: Keyword.get(opts, :call_starter, {CallCoordinator, :start_match})
     }}
  end

  @impl true
  def handle_call({:join, attrs}, _from, state) do
    participant = participant_from_attrs(attrs)

    cond do
      participant.accepted_adult_terms != true ->
        {:reply, {:error, :adult_terms_required}, state}

      not supported_language?(participant.speaks_language) or
          not supported_language?(participant.listens_language) ->
        {:reply, {:error, :unsupported_language}, state}

      Map.has_key?(state.participants, participant.pid) ->
        {:reply, {:error, :already_queued}, state}

      true ->
        join_queue(participant, state)
    end
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
        {:noreply, remove_participant(pid, state)}

      _monitors ->
        {:noreply, state}
    end
  end

  defp join_queue(participant, state) do
    compatible_key = {participant.listens_language, participant.speaks_language}

    case pop_waiting_participant(state, compatible_key) do
      {%{} = waiting_participant, state} ->
        match = build_match(waiting_participant, participant)
        {:ok, call_pid} = start_call(match, state)
        match = Map.merge(match, %{call_pid: call_pid})
        notify_match(state.pubsub, match)
        {:reply, {:matched, match}, state}

      {nil, state} ->
        state = add_participant(participant, state)
        {:reply, :queued, state}
    end
  end

  defp add_participant(participant, state) do
    key = {participant.speaks_language, participant.listens_language}
    ref = Process.monitor(participant.pid)

    %{
      state
      | queues: Map.update(state.queues, key, [participant], &(&1 ++ [participant])),
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

  defp participant_from_attrs(attrs) do
    %{
      id: Map.fetch!(attrs, :id),
      pid: Map.fetch!(attrs, :pid),
      topic: Map.fetch!(attrs, :topic),
      speaks_language: Map.fetch!(attrs, :speaks_language),
      listens_language: Map.fetch!(attrs, :listens_language),
      accepted_adult_terms: Map.get(attrs, :accepted_adult_terms, false)
    }
  end

  defp supported_language?(code), do: code in @supported_language_codes

  defp build_match(participant_a, participant_b) do
    %{
      id: deterministic_match_id(participant_a.id, participant_b.id),
      participant_a: Map.drop(participant_a, [:accepted_adult_terms]),
      participant_b: Map.drop(participant_b, [:accepted_adult_terms]),
      offerer: :participant_a,
      answerer: :participant_b
    }
  end

  defp start_call(match, state) do
    call_options =
      state.call_options
      |> Keyword.put(:supervisor, state.call_supervisor)

    with {:ok, pid} <- apply_call_starter(state.call_starter, match, call_options) do
      {:ok, pid}
    end
  end

  defp apply_call_starter({module, function}, match, call_options) do
    apply(module, function, [match, call_options])
  end

  defp apply_call_starter(function, match, call_options) when is_function(function, 2) do
    function.(match, call_options)
  end

  defp deterministic_match_id(participant_a_id, participant_b_id) do
    :crypto.hash(:sha256, participant_a_id <> ":" <> participant_b_id)
    |> Base.url_encode64(padding: false)
  end

  defp notify_match(pubsub, match) do
    Phoenix.PubSub.broadcast(pubsub, match.participant_a.topic, {:randos_match, match})
    Phoenix.PubSub.broadcast(pubsub, match.participant_b.topic, {:randos_match, match})
  end
end
