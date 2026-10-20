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
    {state, []} = State.event(running(), "loopback_stats", %{"latency_ms" => 81.0})

    {state, commands} = State.mic_test_done(state)
    assert %{phase: :done, stats: %{"latency_ms" => 81.0}} = state.mic_test
    assert commands == [{:request, :loopback_stop}]

    # Late stats from a stopped test are ignored.
    assert State.event(state, "loopback_stats", %{"latency_ms" => 99.0}) == {state, []}
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

    {state, []} = State.event(running(), "loopback_failed", %{"error" => "device gone"})
    assert %{phase: :failed, error: "device gone"} = state.mic_test

    {state, []} = State.event(starting, "ready", %{})
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
    assert State.event(idle, "ready", %{}) == {idle, []}
    assert State.event(idle, "loopback_stats", %{}) == {idle, []}
    assert State.reply(idle, :loopback_stop, {:ok, true}) == {idle, []}
    assert State.mic_test_done(idle) == {idle, []}
  end

  describe "call audio" do
    @ice [%{"urls" => "stun:stun.example:3478"}]
    @start {:call_start, "offerer", @ice, "sine", "null"}
    @offer %{"sdp" => %{"type" => "offer", "sdp" => "v=0"}}

    defp audio, do: State.new(true, {"sine", "null"})

    # In a call, role and ICE servers known, call_start replied ok.
    defp in_call do
      {state, _} = State.server_state(audio(), :in_call, "offerer")
      {state, _} = State.ice_servers(state, @ice)
      {state, []} = State.reply(state, @start, {:ok, %{}})
      state
    end

    test "starts once in_call with a role and ICE servers, in either order" do
      {state, []} = State.server_state(audio(), :in_call, "offerer")
      assert {%{call: %{phase: :starting}}, [{:request, @start}]} = State.ice_servers(state, @ice)

      {state, []} = State.ice_servers(audio(), @ice)

      assert {%{call: %{phase: :starting}}, [{:request, @start}]} =
               State.server_state(state, :in_call, "offerer")
    end

    test "starts at the match (connecting), not before, and only once" do
      {state, []} = State.ice_servers(audio(), @ice)
      assert {_, []} = State.server_state(state, :looking, nil)

      assert {%{call: %{}}, [{:request, @start}]} =
               State.server_state(state, :connecting, "offerer")

      assert {_, []} = State.server_state(in_call(), :in_call, "offerer")
      assert {_, []} = State.server_state(in_call(), :extension_pending, "offerer")
    end

    test "signals that arrive before the call starts follow call_start" do
      # Matched, but the ICE servers haven't arrived yet: no call to start.
      {state, []} = State.server_state(audio(), :connecting, "answerer")
      {state, []} = State.remote_signal(state, "offer", @offer)

      assert {_,
              [
                {:request, {:call_start, "answerer", @ice, "sine", "null"}},
                {:request, {:call_signal, "offer", @offer}}
              ]} = State.ice_servers(state, @ice)
    end

    test "relays media signals both ways" do
      state = in_call()

      assert {_, [{:request, {:call_signal, "answer", @offer}}]} =
               State.remote_signal(state, "answer", @offer)

      assert {_, [{:push, "signal", %{type: "ice_candidate", payload: %{"c" => 1}}}]} =
               State.event(state, "call_signal", %{
                 "type" => "ice_candidate",
                 "payload" => %{"c" => 1}
               })
    end

    test "reports each change of the helper's connection to the server, once" do
      media = fn state, helper_state ->
        State.event(state, "call_state", %{"state" => helper_state})
      end

      push = fn s -> [{:push, "signal", %{type: "media_state", payload: %{state: s}}}] end

      {state, commands} = media.(in_call(), "connected")
      assert commands == push.(:connected)
      assert {_, []} = media.(state, "connected")

      {state, commands} = media.(state, "disconnected")
      assert commands == push.(:disconnected)
      assert {_, commands} = media.(state, "connected")
      assert commands == push.(:connected)
    end

    test "a failed session is reported with its reason; the server ends the call" do
      assert {%{call: %{connection: :failed}},
              [
                {:push, "signal",
                 %{type: "media_state", payload: %{state: :failed, reason: "ice timeout"}}}
              ]} =
               State.event(in_call(), "call_state", %{
                 "state" => "failed",
                 "reason" => "ice timeout"
               })
    end

    test "the call ending (the server's status) stops the helper's call" do
      assert {%{call: nil}, [{:request, :call_stop}]} = State.server_state(in_call(), :idle, nil)

      assert {%{call: nil}, [{:request, :call_stop}]} =
               State.server_state(in_call(), :looking, nil)
    end

    test "when the helper can't carry the call: end_call with a reason" do
      {starting, _} = State.server_state(State.new(true, {"sine", "null"}), :in_call, "offerer")
      {starting, _} = State.ice_servers(starting, @ice)

      assert {%{call: nil},
              [{:request, :call_stop}, {:push, "end_call", %{reason: "audio_unavailable"}}]} =
               State.reply(starting, @start, {:error, "no mic"})

      assert {%{call: nil},
              [{:request, :call_stop}, {:push, "end_call", %{reason: "audio_failed"}}]} =
               State.event(in_call(), "ready", %{})
    end

    test "a call stops a running mic test; the mic test waits during a call" do
      {state, _} = State.start_mic_test(audio(), {"sine", "null"})
      {state, _} = State.reply(state, {:loopback_start, "sine", "null"}, {:ok, %{}})
      {state, []} = State.ice_servers(state, @ice)

      assert {%{mic_test: %{phase: :done}}, [{:request, :loopback_stop}, {:request, @start}]} =
               State.server_state(state, :in_call, "offerer")

      assert State.start_mic_test(in_call(), {"sine", "null"}) == {in_call(), []}
    end

    test "stats are kept for display" do
      assert {%{call: %{stats: %{"packets_received" => 9}}}, []} =
               State.event(in_call(), "call_stats", %{"packets_received" => 9})
    end
  end
end
