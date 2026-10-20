defmodule RandosDev.Monitor do
  @moduledoc """
  Dev-only terminal dashboard (`just top`): queue depth by language pair,
  live calls, and a feed of call/matchmaking events.

  Runs inside the dev server's VM, because telemetry handlers and the
  Matchmaker are local to it. Data comes from the `[:randos, ...]` telemetry
  events (see `RandosDev.Monitor.State`) plus a once-a-second
  `Matchmaker.snapshot/0`. Never part of a release (`dev/` only compiles in
  dev and test).

  Keys: `q` or `esc` quits.
  """
  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, List, Paragraph, Table}
  alias Randos.Matchmaking.Matchmaker
  alias RandosDev.Monitor.State

  @refresh_ms 1_000

  @impl true
  def mount(opts) do
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      handler_id,
      State.telemetry_events(),
      &__MODULE__.handle_telemetry/4,
      self()
    )

    send(self(), :refresh)

    {:ok,
     %{
       data: State.new(),
       call_rows: [],
       now: DateTime.utc_now(),
       handler_id: handler_id,
       snapshot: Keyword.get(opts, :snapshot, &Matchmaker.snapshot/0),
       test_pid: Keyword.get(opts, :test_pid)
     }}
  end

  @doc false
  # Telemetry handler: runs in the emitting process, so only forward.
  def handle_telemetry(event, measurements, metadata, monitor_pid) do
    send(monitor_pid, {:telemetry, event, measurements, metadata})
  end

  @impl true
  def handle_info({:telemetry, event, measurements, metadata}, state) do
    now = DateTime.utc_now()
    data = State.apply_event(state.data, event, measurements, metadata, now)
    {:noreply, update(state, data, now)}
  end

  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, @refresh_ms)
    data = State.put_snapshot(state.data, safe_snapshot(state.snapshot))
    {:noreply, update(state, data, DateTime.utc_now())}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_event(%Event.Key{code: code, kind: "press"}, state) when code in ["q", "esc"] do
    {:stop, state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
  end

  @impl true
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [summary_area, tables_area, events_area, help_area] =
      Layout.split(area, :vertical, [{:length, 3}, {:percentage, 45}, {:min, 5}, {:length, 1}])

    [queues_area, calls_area] =
      Layout.split(tables_area, :horizontal, [{:percentage, 40}, {:percentage, 60}])

    [
      {summary(state), summary_area},
      {queues_table(state.data), queues_area},
      {calls_table(state), calls_area},
      {events_list(state.data), events_area},
      {%Paragraph{text: " q quit", style: %Style{fg: :dark_gray}}, help_area}
    ]
  end

  ## Widgets

  defp summary(%{data: data}) do
    joins =
      data.joins
      |> Enum.sort()
      |> Enum.map_join("  ", fn {result, n} -> "#{result} #{n}" end)

    text =
      "waiting #{data.queued_count}   live calls #{map_size(data.calls)}   " <>
        "ended #{data.ended_count}   joins: #{if joins == "", do: "none", else: joins}"

    %Paragraph{text: text, block: panel(" randos dev monitor ")}
  end

  defp queues_table(data) do
    rows =
      Enum.map(data.queues, fn {speaks, listens, audio?, n} ->
        [speaks, listens, if(audio?, do: "yes", else: "no"), "#{n}"]
      end)

    %Table{
      header: ["Speaks", "Listens", "Audio", "Waiting"],
      rows: rows,
      widths: [{:length, 8}, {:length, 8}, {:length, 6}, {:min, 7}],
      block: panel(" Queue ")
    }
  end

  defp calls_table(state) do
    %Table{
      header: ["Call", "Status", "Age"],
      rows: state.call_rows,
      widths: [{:length, 13}, {:length, 18}, {:min, 6}],
      block: panel(" Live calls ")
    }
  end

  defp events_list(data) do
    %List{items: data.events, block: panel(" Events (UTC) ")}
  end

  defp panel(title) do
    %Block{title: title, borders: [:all], border_type: :rounded, border_style: %Style{fg: :cyan}}
  end

  ## Helpers

  # Everything render needs is derived here, not in render/2.
  defp update(state, data, now) do
    state = %{state | data: data, now: now, call_rows: State.call_rows(data, now)}
    if state.test_pid, do: send(state.test_pid, {:monitor_updated, state.data})
    state
  end

  # The monitor must survive a server restart in the same VM.
  defp safe_snapshot(snapshot_fun) do
    snapshot_fun.()
  catch
    :exit, _reason -> %{queued_count: 0, queues: %{}}
  end
end
