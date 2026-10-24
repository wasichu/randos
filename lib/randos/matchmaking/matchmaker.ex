defmodule Randos.Matchmaking.Matchmaker do
  @moduledoc """
  In-memory anonymous matchmaking queue.

  This process owns live queue membership only. Queue state is intentionally
  transient and disappears when the process or server stops.

  Everyone waits in one list, oldest first. A joiner is matched with the
  person who has waited longest among those they're compatible with
  (`Randos.Matchmaking.Entry.compatible?/2`: each speaks a language the other
  hears). Twenty languages and a small queue make a scan cheap.

  Two people who just had a call aren't matched with each other again for
  `Randos.Calls.Lifecycle.rematch_window_seconds/0` after it ends, so "Next"
  finds someone new. The pair is remembered by its two anonymous participant
  ids, in this process only, and forgotten when the window closes; if the
  two are still waiting then (and still compatible), they're matched. A call
  that never connected keeps no one apart (its coordinator exits
  `{:shutdown, :connection_failed}`): the two may be matched again at once.

  It also holds invitations (`invite/2`, `accept/3`): a person waiting to
  be found by a link's token instead of by language, kept apart from the
  waiting list so random matching never sees them. Only the token's
  SHA-256 is kept. Being one process, it serves two people claiming one
  link one after the other: the first gets the call. An invitation ends
  when it's used, cancelled, or expires
  (`Randos.Calls.Lifecycle.invitation_seconds/0`; the creator then gets
  `:invitation_expired`), or when its creator's process
  goes away. Its call keeps no one apart afterwards: the two chose each
  other.
  """

  use GenServer

  require Logger

  alias Randos.Calls.CallCoordinator
  alias Randos.Calls.Lifecycle
  alias Randos.ConversationLanguages
  alias Randos.Matchmaking.Entry
  alias Randos.Matchmaking.Match

  defstruct waiting: [],
            participants: %{},
            monitors: %{},
            calls: %{},
            recent: %{},
            # token hash => %{entry, ref, timer}; creator pid => token hash
            invitations: %{},
            inviters: %{},
            invitation_ms: Lifecycle.invitation_seconds() * 1_000,
            rematch_window_ms: Lifecycle.rematch_window_seconds() * 1_000,
            call_supervisor: Randos.Calls.CallSupervisor,
            call_options: [],
            call_starter: {CallCoordinator, :start_match}

  @supported_language_codes ConversationLanguages.codes()

  @typedoc """
  What `join/1` needs; `accepted_adult_terms` must be `true`.
  `hears_languages` are the languages the person is happy to hear (at least
  one, all supported). `audio?` (default `false`) is whether the client
  carries call audio: only entries that agree are matched.
  """
  @type join_attrs :: %{
          required(:id) => String.t(),
          required(:pid) => pid(),
          required(:topic) => String.t(),
          required(:speaks_language) => String.t(),
          required(:hears_languages) => [String.t()],
          optional(:accepted_adult_terms) => boolean(),
          optional(:audio?) => boolean(),
          optional(:ice_restart?) => boolean()
        }

  @type join_result ::
          :queued
          | {:matched, Match.t()}
          | {:error,
             :adult_terms_required | :unsupported_language | :already_queued | :call_start_failed}

  @type invite_result ::
          {:invited, token :: String.t(), expires_at_unix_ms :: integer()}
          | {:error, :adult_terms_required | :unsupported_language | :already_queued}

  @type accept_result ::
          {:matched, Match.t()}
          | {:error,
             :adult_terms_required
             | :invitation_invalid
             | :audio_mismatch
             | :already_queued
             | :call_start_failed}

  @doc """
  Options: `:name`, `:call_supervisor`, `:call_options`, `:call_starter`,
  `:rematch_window_ms` and `:invitation_ms` (tests).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Joins the queue or immediately matches with a compatible waiting participant.

  On a match the call's coordinator is started and the joiner gets
  `{:matched, match}` (with `call_pid`); both participants then hear about the
  call only from the coordinator, as `{:call_updated, %Call{}}`. (Two people
  matched when their rematch window closes hear only from the coordinator.)
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
  Makes an invitation instead of joining the queue: the same attributes
  and checks as `join/2`, and the creator waits to be found by the token
  (128 random bits, URL-safe) until `accept/3`, `cancel_invitation/2`,
  the expiry, or its process going away.
  """
  @spec invite(GenServer.server(), join_attrs()) :: invite_result()
  def invite(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(server, {:invite, attrs})
  end

  @doc """
  Joins the call an invitation offers. `attrs` are `join/2`'s without the
  languages: the joiner is taken to speak the creator's hearing languages
  (`Entry.speaks_any/1`). Unknown, used, expired, cancelled and one's own
  invitation are all `:invitation_invalid`; `:audio_mismatch` leaves it
  valid for someone whose client agrees.
  """
  @spec accept(GenServer.server(), String.t(), map()) :: accept_result()
  def accept(server \\ __MODULE__, token, attrs) when is_binary(token) and is_map(attrs) do
    GenServer.call(server, {:accept, token, attrs})
  end

  @doc "Withdraws the invitation `pid` made, if any (the link stops working)."
  @spec cancel_invitation(GenServer.server(), pid()) :: :ok
  def cancel_invitation(server \\ __MODULE__, pid) when is_pid(pid) do
    GenServer.call(server, {:cancel_invitation, pid})
  end

  @doc """
  Returns a lightweight snapshot for tests and diagnostics: who is waiting
  (oldest first) and the same people grouped by what they asked for.
  """
  @spec snapshot(GenServer.server()) :: %{
          queued_count: non_neg_integer(),
          waiting: [String.t()],
          queues: map()
        }
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       call_supervisor: Keyword.get(opts, :call_supervisor, Randos.Calls.CallSupervisor),
       call_options: Keyword.get(opts, :call_options, []),
       call_starter: Keyword.get(opts, :call_starter, {CallCoordinator, :start_match}),
       rematch_window_ms:
         Keyword.get(opts, :rematch_window_ms, Lifecycle.rematch_window_seconds() * 1_000),
       invitation_ms: Keyword.get(opts, :invitation_ms, Lifecycle.invitation_seconds() * 1_000)
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

  def handle_call({:invite, attrs}, _from, state) do
    entry = entry_from_attrs(attrs)

    case check(attrs, entry, state) do
      :ok ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        hash = hash(token)
        timer = Process.send_after(self(), {:invitation_over, hash}, state.invitation_ms)
        invitation = %{entry: entry, ref: Process.monitor(entry.pid), timer: timer}
        expires_at = System.system_time(:millisecond) + state.invitation_ms
        Logger.info("matchmaking invitation made")

        {:reply, {:invited, token, expires_at},
         %{
           state
           | invitations: Map.put(state.invitations, hash, invitation),
             inviters: Map.put(state.inviters, entry.pid, hash)
         }}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:accept, token, attrs}, _from, state) do
    {reply, state} = do_accept(hash(token), attrs, state)
    {:reply, reply, state}
  end

  def handle_call({:cancel_invitation, pid}, _from, state) do
    {:reply, :ok, drop_invitation(state, Map.get(state.inviters, pid))}
  end

  def handle_call({:leave, pid}, _from, state) do
    {:reply, :ok, remove_waiting(state, pid)}
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      queued_count: length(state.waiting),
      waiting: Enum.map(state.waiting, & &1.id),
      queues:
        state.waiting
        |> Enum.group_by(&{&1.speaks_language, &1.hears_languages, &1.audio?}, & &1.id)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      Map.get(state.monitors, ref) == pid ->
        Logger.info("matchmaking participant went away while queued")
        {:noreply, remove_waiting(state, pid)}

      Map.has_key?(state.calls, ref) ->
        {:noreply, call_ended(state, ref, reason)}

      Map.has_key?(state.inviters, pid) ->
        Logger.info("matchmaking inviter went away")
        {:noreply, drop_invitation(state, Map.fetch!(state.inviters, pid))}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:invitation_over, hash}, state) do
    case Map.get(state.invitations, hash) do
      %{entry: entry} ->
        send(entry.pid, :invitation_expired)
        {:noreply, drop_invitation(state, hash)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:rematch_window_over, pair}, state) do
    case Map.get(state.recent, pair) do
      expires_at when is_integer(expires_at) ->
        state = %{state | recent: Map.delete(state.recent, pair)}
        {:noreply, rematch(state, pair)}

      # Matched again meanwhile? Can't be (the pair was blocked), but a stale
      # timer must never unblock a pair that's in a call.
      _in_call_or_gone ->
        {:noreply, state}
    end
  end

  defp do_join(attrs, state) do
    participant = entry_from_attrs(attrs)

    case check(attrs, participant, state) do
      :ok -> join_queue(participant, state)
      error -> {error, state}
    end
  end

  # What joining the queue and making an invitation both need.
  defp check(attrs, entry, state) do
    cond do
      Map.get(attrs, :accepted_adult_terms) != true ->
        {:error, :adult_terms_required}

      not supported_language?(entry.speaks_language) or
        entry.hears_languages == [] or
          not Enum.all?(entry.hears_languages, &supported_language?/1) ->
        {:error, :unsupported_language}

      busy?(state, entry.pid) ->
        {:error, :already_queued}

      true ->
        :ok
    end
  end

  # Waiting in the queue, or waiting with an invitation: one at a time.
  defp busy?(state, pid),
    do: Map.has_key?(state.participants, pid) or Map.has_key?(state.inviters, pid)

  defp do_accept(hash, attrs, state) do
    invitation = Map.get(state.invitations, hash)
    pid = Map.fetch!(attrs, :pid)

    cond do
      Map.get(attrs, :accepted_adult_terms) != true ->
        {{:error, :adult_terms_required}, state}

      invitation == nil or invitation.entry.pid == pid ->
        {{:error, :invitation_invalid}, state}

      busy?(state, pid) ->
        {{:error, :already_queued}, state}

      invitation.entry.audio? != (Map.get(attrs, :audio?, false) == true) ->
        {{:error, :audio_mismatch}, state}

      true ->
        start_invitation_call(hash, invitation.entry, joiner(invitation.entry, attrs), state)
    end
  end

  # The joiner names no language: taken to speak what the creator hears.
  defp joiner(creator, attrs) do
    hears = creator.hears_languages

    entry_from_attrs(
      Map.merge(attrs, %{speaks_language: hd(hears), hears_languages: [creator.speaks_language]})
    )
    |> Map.put(:speaks_any, if(match?([_, _ | _], hears), do: hears))
  end

  defp start_invitation_call(hash, creator, joiner, state) do
    match = Match.new(creator, joiner, :invitation)

    case start_call(match, state) do
      {:ok, call_pid} ->
        Logger.info("matchmaking invitation used", match_id: match.id)
        state = state |> drop_invitation(hash) |> in_call(match, call_pid)
        {{:matched, %{match | call_pid: call_pid}}, state}

      {:error, reason} ->
        # The link stays valid: nobody's fault but ours.
        Logger.warning("matchmaking call start failed",
          match_id: match.id,
          reason: inspect(reason)
        )

        {{:error, :call_start_failed}, state}
    end
  end

  defp drop_invitation(state, nil), do: state

  defp drop_invitation(state, hash) do
    case Map.pop(state.invitations, hash) do
      {nil, _invitations} ->
        state

      {invitation, invitations} ->
        Process.demonitor(invitation.ref, [:flush])
        Process.cancel_timer(invitation.timer)

        %{
          state
          | invitations: invitations,
            inviters: Map.delete(state.inviters, invitation.entry.pid)
        }
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp join_queue(participant, state) do
    case Enum.find(state.waiting, &matchable?(state, &1, participant)) do
      nil ->
        {:queued, add_waiting(state, participant)}

      waiting_participant ->
        match = Match.new(waiting_participant, participant)

        case start_call(match, state) do
          {:ok, call_pid} ->
            Logger.info("matchmaking matched", match_id: match.id)

            state =
              state
              |> remove_waiting(waiting_participant.pid)
              |> in_call(match, call_pid)

            {{:matched, %{match | call_pid: call_pid}}, state}

          {:error, reason} ->
            # Not the waiting participant's fault: they keep their place.
            Logger.warning("matchmaking call start failed",
              match_id: match.id,
              reason: inspect(reason)
            )

            {{:error, :call_start_failed}, state}
        end
    end
  end

  # When the window closes and both are still waiting, they're matched (the
  # one who waited longer offers). Nobody else could have been matched with
  # either: that would have happened when they joined.
  defp rematch(state, {id_a, id_b}) do
    with [first, second] <- Enum.filter(state.waiting, &(&1.id in [id_a, id_b])),
         true <- matchable?(state, first, second),
         match = Match.new(first, second),
         {:ok, call_pid} <- start_call(match, state) do
      Logger.info("matchmaking matched", match_id: match.id)

      state
      |> remove_waiting(first.pid)
      |> remove_waiting(second.pid)
      |> in_call(match, call_pid)
    else
      {:error, reason} ->
        Logger.warning("matchmaking call start failed", reason: inspect(reason))

        state

      _not_both_waiting_or_incompatible ->
        state
    end
  end

  defp matchable?(state, a, b),
    do: a.pid != b.pid and Entry.compatible?(a, b) and not Map.has_key?(state.recent, pair(a, b))

  # The two stay unmatchable while their call runs (they could requeue
  # before its coordinator's DOWN arrives) and for the window after. Not
  # after an invitation's call: they chose each other, and both go idle.
  defp in_call(state, %Match{kind: :invitation}, _call_pid), do: state

  defp in_call(state, match, call_pid) do
    pair = pair(match.participant_a, match.participant_b)
    ref = Process.monitor(call_pid)

    %{
      state
      | calls: Map.put(state.calls, ref, pair),
        recent: Map.put(state.recent, pair, :in_call)
    }
  end

  # A call that never connected: no window, and the two (if both are back in
  # the queue) are matched at once.
  defp call_ended(state, ref, {:shutdown, :connection_failed}) do
    {pair, calls} = Map.pop(state.calls, ref)
    rematch(%{state | calls: calls, recent: Map.delete(state.recent, pair)}, pair)
  end

  defp call_ended(state, ref, _reason) do
    {pair, calls} = Map.pop(state.calls, ref)
    expires_at = System.monotonic_time(:millisecond) + state.rematch_window_ms
    Process.send_after(self(), {:rematch_window_over, pair}, state.rematch_window_ms)
    %{state | calls: calls, recent: Map.put(state.recent, pair, expires_at)}
  end

  # The same key whichever of the two is first.
  defp pair(%{id: a}, %{id: b}) when a <= b, do: {a, b}
  defp pair(%{id: a}, %{id: b}), do: {b, a}

  defp add_waiting(state, participant) do
    ref = Process.monitor(participant.pid)

    %{
      state
      | waiting: state.waiting ++ [participant],
        participants: Map.put(state.participants, participant.pid, ref),
        monitors: Map.put(state.monitors, ref, participant.pid)
    }
  end

  defp remove_waiting(state, pid) do
    case Map.pop(state.participants, pid) do
      {nil, _participants} ->
        state

      {ref, participants} ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | waiting: Enum.reject(state.waiting, &(&1.pid == pid)),
            participants: participants,
            monitors: Map.delete(state.monitors, ref)
        }
    end
  end

  defp entry_from_attrs(attrs) do
    %Entry{
      id: Map.fetch!(attrs, :id),
      pid: Map.fetch!(attrs, :pid),
      topic: Map.fetch!(attrs, :topic),
      speaks_language: Map.fetch!(attrs, :speaks_language),
      hears_languages: attrs |> Map.fetch!(:hears_languages) |> List.wrap() |> Enum.uniq(),
      audio?: Map.get(attrs, :audio?, false) == true,
      ice_restart?: Map.get(attrs, :ice_restart?, false) == true
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
