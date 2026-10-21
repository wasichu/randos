defmodule RandosDev.Monitor.State do
  @moduledoc """
  What the dev monitor shows, folded from telemetry events and matchmaker
  snapshots. Pure: no processes, no terminal, so it is tested directly.

  Everything the view needs is derived here, in the transition, so
  `RandosDev.Monitor.render/2` only lays it out.
  """

  @max_events 50

  @type call :: %{
          status: atom(),
          started_at: DateTime.t(),
          extension_count: non_neg_integer()
        }

  @type t :: %__MODULE__{
          queues: [{String.t(), String.t(), boolean(), non_neg_integer()}],
          queued_count: non_neg_integer(),
          calls: %{String.t() => call()},
          ended_count: non_neg_integer(),
          joins: %{atom() => non_neg_integer()},
          events: [String.t()]
        }

  defstruct queues: [],
            queued_count: 0,
            calls: %{},
            ended_count: 0,
            joins: %{},
            events: []

  @doc "Telemetry events the monitor folds; attach handlers to exactly these."
  @spec telemetry_events() :: [[atom()]]
  def telemetry_events do
    [
      [:randos, :call, :start],
      [:randos, :call, :status],
      [:randos, :call, :stop],
      [:randos, :matchmaking, :join]
    ]
  end

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Replaces the queue view with a `Matchmaker.snapshot/0` result."
  @spec put_snapshot(t(), %{queued_count: non_neg_integer(), queues: map()}) :: t()
  def put_snapshot(state, %{queued_count: queued_count, queues: queues}) do
    rows =
      queues
      |> Enum.map(fn {{speaks, hears, audio?}, ids} ->
        {speaks, hears |> List.wrap() |> Enum.join(", "), audio?, length(ids)}
      end)
      |> Enum.sort()

    %{state | queues: rows, queued_count: queued_count}
  end

  @doc "Folds one telemetry event (`now` is when it was received)."
  @spec apply_event(t(), [atom()], map(), map(), DateTime.t()) :: t()
  def apply_event(state, [:randos, :call, :start], _measurements, %{call_id: id}, now) do
    call = %{status: :connecting, started_at: now, extension_count: 0}

    state
    |> put_in([Access.key(:calls), id], call)
    |> log(now, "#{short(id)} started")
  end

  def apply_event(state, [:randos, :call, :status], _measurements, %{call_id: id} = meta, now) do
    case Map.fetch(state.calls, id) do
      {:ok, call} ->
        state
        |> put_in([Access.key(:calls), id], %{call | status: meta.status})
        |> log(now, "#{short(id)} #{meta.status}")

      # Monitor started mid-call: track it from here on.
      :error ->
        call = %{status: meta.status, started_at: now, extension_count: 0}
        put_in(state, [Access.key(:calls), id], call)
    end
  end

  def apply_event(state, [:randos, :call, :stop], measurements, %{call_id: id} = meta, now) do
    seconds = System.convert_time_unit(measurements.duration, :native, :second)

    %{state | calls: Map.delete(state.calls, id), ended_count: state.ended_count + 1}
    |> log(now, "#{short(id)} ended (#{meta.reason}, #{format_duration(seconds)})")
  end

  def apply_event(state, [:randos, :matchmaking, :join], _measurements, %{result: result}, now) do
    joins = Map.update(state.joins, result, 1, &(&1 + 1))

    case result do
      :queued -> %{state | joins: joins}
      result -> log(%{state | joins: joins}, now, "join #{result}")
    end
  end

  def apply_event(state, _event, _measurements, _metadata, _now), do: state

  @doc "Live calls as display rows, longest-running first."
  @spec call_rows(t(), DateTime.t()) :: [[String.t()]]
  def call_rows(state, now) do
    state.calls
    |> Enum.sort_by(fn {_id, call} -> call.started_at end, DateTime)
    |> Enum.map(fn {id, call} ->
      age = DateTime.diff(now, call.started_at, :second)
      [short(id), to_string(call.status), format_duration(age)]
    end)
  end

  @doc "Short, stable display form of a call id."
  @spec short(String.t()) :: String.t()
  def short("call-" <> rest), do: "call-" <> String.slice(rest, 0, 6)
  def short(id), do: String.slice(id, 0, 11)

  @spec format_duration(integer()) :: String.t()
  def format_duration(seconds) when seconds < 0, do: "0:00"

  def format_duration(seconds) do
    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp log(state, now, line) do
    stamp = Calendar.strftime(now, "%H:%M:%S")
    %{state | events: Enum.take(["#{stamp}  #{line}" | state.events], @max_events)}
  end
end
