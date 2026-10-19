defmodule RandosDev.Monitor.StateTest do
  use ExUnit.Case, async: true

  alias RandosDev.Monitor.State

  @t0 ~U[2026-10-19 12:00:00Z]

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  test "queue snapshots become sorted rows with counts" do
    state =
      State.put_snapshot(State.new(), %{
        queued_count: 3,
        queues: %{{"fr", "de"} => ["a"], {"en", "es"} => ["b", "c"]}
      })

    assert state.queued_count == 3
    assert state.queues == [{"en", "es", 2}, {"fr", "de", 1}]
  end

  test "a call is tracked from start through status changes to its end" do
    duration = System.convert_time_unit(125, :second, :native)

    state =
      State.new()
      |> State.apply_event([:randos, :call, :start], %{}, %{call_id: "call-abcdef123"}, at(0))
      |> State.apply_event(
        [:randos, :call, :status],
        %{count: 1},
        %{call_id: "call-abcdef123", status: :active},
        at(1)
      )

    assert %{"call-abcdef123" => %{status: :active}} = state.calls
    assert State.call_rows(state, at(65)) == [["call-abcdef", "active", "1:05"]]

    state =
      State.apply_event(
        state,
        [:randos, :call, :stop],
        %{duration: duration},
        %{call_id: "call-abcdef123", reason: :hangup, extension_count: 0},
        at(125)
      )

    assert state.calls == %{}
    assert state.ended_count == 1
    assert ["12:02:05  call-abcdef ended (hangup, 2:05)" | _] = state.events
  end

  test "status for a call that started before the monitor still shows up" do
    state =
      State.apply_event(
        State.new(),
        [:randos, :call, :status],
        %{count: 1},
        %{call_id: "call-zzz", status: :extension_pending},
        at(0)
      )

    assert %{"call-zzz" => %{status: :extension_pending}} = state.calls
  end

  test "joins are counted by result; only non-queued results are logged" do
    state =
      Enum.reduce([:queued, :queued, :matched, :unsupported_language], State.new(), fn result,
                                                                                       acc ->
        State.apply_event(
          acc,
          [:randos, :matchmaking, :join],
          %{queue_size: 1},
          %{result: result},
          at(0)
        )
      end)

    assert state.joins == %{queued: 2, matched: 1, unsupported_language: 1}
    assert length(state.events) == 2
  end

  test "the event log is bounded" do
    state =
      Enum.reduce(1..80, State.new(), fn _, acc ->
        State.apply_event(
          acc,
          [:randos, :matchmaking, :join],
          %{queue_size: 0},
          %{result: :matched},
          at(0)
        )
      end)

    assert length(state.events) == 50
  end

  test "unknown events are ignored" do
    assert State.apply_event(State.new(), [:other], %{}, %{}, at(0)) == State.new()
  end
end
