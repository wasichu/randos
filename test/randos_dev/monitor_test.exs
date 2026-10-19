defmodule RandosDev.MonitorTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event
  alias ExRatatui.Runtime
  alias RandosDev.Monitor
  alias RandosDev.Monitor.State

  defp snapshot, do: %{queued_count: 2, queues: %{{"en", "es", true} => ["a", "b"]}}

  defp render_to_text(state, width \\ 100, height \\ 30) do
    terminal = ExRatatui.init_test_terminal(width, height)

    :ok =
      ExRatatui.draw(
        terminal,
        Monitor.render(state, %ExRatatui.Frame{width: width, height: height})
      )

    ExRatatui.get_buffer_content(terminal)
  end

  test "renders queues, live calls, events, and the summary" do
    now = DateTime.utc_now()

    data =
      State.new()
      |> State.put_snapshot(snapshot())
      |> State.apply_event([:randos, :call, :start], %{}, %{call_id: "call-abcdef123"}, now)
      |> State.apply_event(
        [:randos, :call, :status],
        %{count: 1},
        %{call_id: "call-abcdef123", status: :active},
        now
      )

    state = %{data: data, call_rows: State.call_rows(data, now), now: now}
    text = render_to_text(state)

    assert text =~ "Randos dev monitor"
    assert text =~ "waiting 2"
    assert text =~ "live calls 1"
    assert text =~ ~r/en\s+es\s+yes\s+2/
    assert text =~ ~r/call-abcdef\s+active/
    assert text =~ "call-abcdef started"
  end

  test "the running app folds real telemetry events and quits on q" do
    pid =
      start_supervised!(
        {Monitor, name: nil, test_mode: {100, 30}, test_pid: self(), snapshot: &snapshot/0}
      )

    assert_receive {:monitor_updated, %{queued_count: 2}}

    :telemetry.execute([:randos, :call, :start], %{system_time: 0}, %{call_id: "call-live1"})
    assert_receive {:monitor_updated, %{calls: %{"call-live1" => %{status: :connecting}}}}

    :telemetry.execute(
      [:randos, :call, :stop],
      %{duration: System.convert_time_unit(3, :second, :native)},
      %{call_id: "call-live1", reason: :hangup, extension_count: 0}
    )

    assert_receive {:monitor_updated, %{calls: calls, ended_count: 1}} when calls == %{}

    ref = Process.monitor(pid)
    :ok = Runtime.inject_event(pid, %Event.Key{code: "q", kind: "press"})
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "survives the matchmaker being unavailable" do
    down = fn -> exit(:noproc) end

    start_supervised!(
      {Monitor, name: nil, test_mode: {100, 30}, test_pid: self(), snapshot: down}
    )

    assert_receive {:monitor_updated, %{queued_count: 0}}
  end
end
