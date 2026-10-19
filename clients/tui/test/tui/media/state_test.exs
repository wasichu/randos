defmodule Tui.Media.StateTest do
  use ExUnit.Case, async: true

  alias Tui.Media.State

  @endpoints {"device", "device"}
  @start {:loopback_start, "device", "device"}

  defp running do
    {state, _} = State.start_mic_test(State.new(true), @endpoints)
    {state, _} = State.reply(state, @start, {:ok, %{}})
    state
  end

  test "a mic test asks the helper to start, then runs for five seconds" do
    {state, commands} = State.start_mic_test(State.new(true), @endpoints)
    assert %{phase: :starting} = state.mic_test
    assert commands == [{:request, @start}]

    {state, commands} = State.reply(state, @start, {:ok, %{"input" => "mic"}})
    assert %{phase: :running, stats: nil} = state.mic_test
    assert commands == [{:after, 5_000, :mic_test_done}]
  end

  test "stats show while running; time up stops the helper and keeps the result" do
    state = State.event(running(), "loopback_stats", %{"latency_ms" => 81.0})

    {state, commands} = State.mic_test_done(state)
    assert %{phase: :done, stats: %{"latency_ms" => 81.0}} = state.mic_test
    assert commands == [{:request, :loopback_stop}]

    # Late stats from a stopped test are ignored.
    assert State.event(state, "loopback_stats", %{"latency_ms" => 99.0}) == state
  end

  test "pressing t again during a test does nothing" do
    state = running()
    assert State.start_mic_test(state, @endpoints) == {state, []}
  end

  test "failures: no helper, a refused start, a failed loopback, a restarted helper" do
    {state, []} = State.start_mic_test(State.new(false), @endpoints)
    assert %{phase: :failed, error: "no audio helper" <> _} = state.mic_test

    {starting, _} = State.start_mic_test(State.new(true), @endpoints)
    {state, []} = State.reply(starting, @start, {:error, "no 48 kHz config"})
    assert %{phase: :failed, error: "no 48 kHz config"} = state.mic_test

    state = State.event(running(), "loopback_failed", %{"error" => "device gone"})
    assert %{phase: :failed, error: "device gone"} = state.mic_test

    state = State.event(starting, "ready", %{})
    assert %{phase: :failed, error: "the audio helper restarted"} = state.mic_test
  end

  test "a failed test can be retried" do
    {failed, []} =
      State.reply(
        elem(State.start_mic_test(State.new(true), @endpoints), 0),
        @start,
        {:error, "x"}
      )

    assert {%{mic_test: %{phase: :starting}}, [{:request, @start}]} =
             State.start_mic_test(failed, @endpoints)
  end

  test "events and replies with no test in progress change nothing" do
    idle = State.new(true)
    assert State.event(idle, "ready", %{}) == idle
    assert State.event(idle, "loopback_stats", %{}) == idle
    assert State.reply(idle, :loopback_stop, {:ok, true}) == {idle, []}
    assert State.mic_test_done(idle) == {idle, []}
  end
end
