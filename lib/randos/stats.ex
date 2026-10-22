defmodule Randos.Stats do
  @moduledoc """
  Today's aggregate counts of calls, for the public status page
  (`RandosWeb.Status`): "we count calls, not people".

  Fed by the call coordinator's telemetry (`[:randos, :call, :start]` and
  `[:randos, :call, :stop]`). What's counted, for the current UTC day:

    * calls started, and calls that connected (became active);
    * how calls ended, in a few classes (`ending/1`);
    * calls continued past their first segment;
    * connected lengths, as a histogram of whole minutes (the median comes
      from it);
    * calls per language pair: the two speaking languages, unordered
      (`{"en", "es"}` covers both people's sides; `{"es", "es"}` is the
      same language both ways).

  Nothing else: no IPs, no participant or call ids, nothing per person (call
  ids arrive as telemetry metadata and are never stored). Counts live in
  this process's memory and reset at UTC midnight, and whenever the server
  restarts (Fly stops it when idle).

  ## Raw counters and what's published

  The raw counters (`raw/1`) are plain integers, so two nodes' counters for
  the same day add up exactly (`merge/2`); `publish/1` applies the
  publishing rules (small counts suppressed) and runs only after any merge:

      %{
        date: ~D[2026-10-21],
        since: ~U[2026-10-21 09:12:33Z],    # earliest start among the merged
        started: 12, connected: 9, extended: 2,
        endings: %{finished: 8, not_connected: 2, connection_lost: 1},
        lengths: %{0 => 1, 4 => 2, 10 => 5, 30 => 1},  # minute => calls; 30: 30+
        pairs: %{{"en", "es"} => 5, {"de", "fr"} => 1}
      }

  `:store` is the seam for keeping each node's daily counters across
  restarts later: a module with `load(Date.t()) :: raw | nil` and
  `save(Date.t(), raw)`. None is configured today (memory only).
  """

  use GenServer

  @topic "stats"

  # Publishing rules: a language pair shows only with at least this many
  # calls (the rest is "other"); the median needs this many connected calls.
  @min_published 3

  # One bucket per minute up to the longest possible call; the last bucket
  # also catches anything longer.
  @last_bucket div(Randos.Calls.Lifecycle.max_call_duration_seconds(), 60)

  @handler_id "randos-stats"

  # How long another node gets to answer with its counters.
  @cluster_timeout 1_000

  @doc "Options: `:name` (default `__MODULE__`), `:store`, `:pubsub` (nil: announce nothing), `:attach` (telemetry; default true), `:now` (a 0-arity fun returning a UTC DateTime, for tests)."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The fewest calls a language pair needs to be shown (fewer count as \"other\")."
  def min_published, do: @min_published

  @doc "The PubSub topic the stats announce changes on (`{:stats_updated, published}`)."
  def topic, do: @topic

  @doc "Today's raw counters (see the moduledoc); never published as they are."
  @spec raw(GenServer.server()) :: map()
  def raw(server \\ __MODULE__), do: GenServer.call(server, :raw)

  @doc """
  What may be published, for today, across the cluster: every connected
  node's raw counters (`cluster_raw/2`), merged, then `publish/1`d, plus
  `:nodes` (`%{answered: n, total: m}`). On one node, just this node's.
  """
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    {merged, nodes} = cluster_raw(server)
    merged |> publish() |> Map.put(:nodes, nodes)
  end

  @doc """
  Today's raw counters from this node and every connected one
  (`[node() | Node.list()]`), each node's stats process registered as
  `server`, added up with `merge/2`. A node that doesn't answer within
  `timeout` ms (or is on another UTC day) is left out; the second element
  says how many answered of how many asked. A `server` that's a pid (tests)
  is only ever this node's.
  """
  @spec cluster_raw(GenServer.server(), timeout()) ::
          {map(), %{answered: non_neg_integer(), total: pos_integer()}}
  def cluster_raw(server \\ __MODULE__, timeout \\ @cluster_timeout)

  def cluster_raw(server, timeout) when is_atom(server) do
    local = raw(server)
    nodes = [node() | Node.list()]

    answers =
      for {:ok, %{date: date} = raw} <-
            :erpc.multicall(nodes, __MODULE__, :raw, [server], timeout),
          date == local.date,
          do: raw

    merged = Enum.reduce(answers, empty(local.date, local.since), &merge/2)
    {merged, %{answered: length(answers), total: length(nodes)}}
  end

  def cluster_raw(server, _timeout), do: {raw(server), %{answered: 1, total: 1}}

  @doc """
  Two sets of raw counters for the same day, added up (each node's, in a
  cluster). `since` is the earlier of the two.
  """
  @spec merge(map(), map()) :: map()
  def merge(%{date: date} = a, %{date: date} = b) do
    %{
      date: date,
      since: Enum.min([a.since, b.since], DateTime),
      started: a.started + b.started,
      connected: a.connected + b.connected,
      extended: a.extended + b.extended,
      endings: add(a.endings, b.endings),
      lengths: add(a.lengths, b.lengths),
      pairs: add(a.pairs, b.pairs)
    }
  end

  @doc """
  The publishable view of raw counters: `:date`, `:since`, `:started`,
  `:connected`, `:extended`, `:endings`, `:median_minutes` (nil below
  #{@min_published} connected calls; a call's whole minutes, the last bucket
  meaning #{@last_bucket} or more), `:pairs` (`[{{a, b}, calls}]`, most common
  first, only pairs with at least #{@min_published} calls) and `:other_pairs`
  (the calls in the rest).
  """
  @spec publish(map()) :: map()
  def publish(raw) do
    {shown, hidden} =
      raw.pairs
      |> Enum.sort_by(fn {pair, n} -> {-n, pair} end)
      |> Enum.split_with(fn {_pair, n} -> n >= @min_published end)

    %{
      date: raw.date,
      since: raw.since,
      started: raw.started,
      connected: raw.connected,
      extended: raw.extended,
      endings: raw.endings,
      median_minutes: median(raw.lengths),
      pairs: shown,
      other_pairs: hidden |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    }
  end

  @doc "The ending class of an `ended_reason`."
  @spec ending(atom()) :: :finished | :not_connected | :connection_lost | :canceled
  def ending(:connection_failed), do: :not_connected
  def ending(:disconnected), do: :connection_lost
  def ending(:canceled), do: :canceled
  def ending(_finished), do: :finished

  @doc false
  # The telemetry handler: hands the event to the stats process.
  def handle_telemetry(event, measurements, metadata, server),
    do: GenServer.cast(server, {:event, event, measurements, metadata})

  ## Server

  @impl true
  def init(opts) do
    now_fun = Keyword.get(opts, :now, fn -> DateTime.utc_now() end)
    now = now_fun.()

    state = %{
      store: Keyword.get(opts, :store),
      pubsub: Keyword.get(opts, :pubsub, Randos.PubSub),
      now: now_fun,
      raw: nil
    }

    state = %{state | raw: fresh(state, DateTime.to_date(now), now)}

    if Keyword.get(opts, :attach, true) do
      name = Keyword.get(opts, :name, __MODULE__)
      # A restarted process replaces its predecessor's handler (the handler
      # casts by name, so it outlives a crash harmlessly).
      _ = :telemetry.detach({@handler_id, name})

      :telemetry.attach_many(
        {@handler_id, name},
        [[:randos, :call, :start], [:randos, :call, :stop]],
        &__MODULE__.handle_telemetry/4,
        name
      )
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:raw, _from, state) do
    state = roll_over(state)
    {:reply, state.raw, state}
  end

  @impl true
  def handle_cast({:event, event, measurements, metadata}, state) do
    state = roll_over(state)
    state = %{state | raw: count(state.raw, event, measurements, metadata)}
    save(state)

    if state.pubsub,
      do: Phoenix.PubSub.broadcast(state.pubsub, @topic, {:stats_updated, publish(state.raw)})

    {:noreply, state}
  end

  ## Counting

  defp count(raw, [:randos, :call, :start], _measurements, metadata) do
    raw = %{raw | started: raw.started + 1}

    case pair(Map.get(metadata, :languages)) do
      nil -> raw
      pair -> %{raw | pairs: Map.update(raw.pairs, pair, 1, &(&1 + 1))}
    end
  end

  defp count(raw, [:randos, :call, :stop], measurements, metadata) do
    raw = %{
      raw
      | endings: Map.update(raw.endings, ending(Map.get(metadata, :reason)), 1, &(&1 + 1))
    }

    raw =
      if Map.get(metadata, :extension_count, 0) > 0,
        do: %{raw | extended: raw.extended + 1},
        else: raw

    case Map.get(measurements, :connected) do
      connected when is_integer(connected) ->
        bucket =
          min(System.convert_time_unit(connected, :native, :second) |> div(60), @last_bucket)

        %{
          raw
          | connected: raw.connected + 1,
            lengths: Map.update(raw.lengths, bucket, 1, &(&1 + 1))
        }

      _never_connected ->
        raw
    end
  end

  defp count(raw, _event, _measurements, _metadata), do: raw

  defp pair([a, b]) when is_binary(a) and is_binary(b), do: Enum.min_max([a, b])
  defp pair(_unknown), do: nil

  defp add(a, b), do: Map.merge(a, b, fn _key, x, y -> x + y end)

  # The bucket holding the middle call (the lower one for an even count).
  defp median(lengths) do
    total = lengths |> Map.values() |> Enum.sum()
    if total < @min_published, do: nil, else: bucket_at(Enum.sort(lengths), div(total + 1, 2))
  end

  defp bucket_at([{minute, calls} | _rest], nth) when calls >= nth, do: minute
  defp bucket_at([{_minute, calls} | rest], nth), do: bucket_at(rest, nth - calls)

  ## The day

  @doc """
  Raw counters with nothing counted, for `date` from `since`: the starting
  point for adding up several nodes' (`Enum.reduce(nodes, empty, &merge/2)`).
  """
  @spec empty(Date.t(), DateTime.t()) :: map()
  def empty(date, since) do
    %{
      date: date,
      since: since,
      started: 0,
      connected: 0,
      extended: 0,
      endings: %{},
      lengths: %{},
      pairs: %{}
    }
  end

  defp fresh(state, date, since) do
    case state.store && state.store.load(date) do
      %{} = saved -> Map.merge(empty(date, since), saved)
      _none -> empty(date, since)
    end
  end

  # A new UTC day starts from zero, counting from its midnight.
  defp roll_over(state) do
    now = state.now.()
    today = DateTime.to_date(now)

    if today == state.raw.date,
      do: state,
      else: %{state | raw: fresh(state, today, DateTime.new!(today, ~T[00:00:00], "Etc/UTC"))}
  end

  defp save(%{store: nil}), do: :ok
  defp save(%{store: store, raw: raw}), do: store.save(raw.date, raw)
end
