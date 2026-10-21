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

    {state, [{:request, :devices}]} = State.event(starting, "ready", %{})
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
    # A fresh helper: ask what devices there are.
    assert State.event(idle, "ready", %{}) == {idle, [{:request, :devices}]}
    assert State.event(idle, "loopback_stats", %{}) == {idle, []}
    assert State.reply(idle, :loopback_stop, {:ok, true}) == {idle, []}
    assert State.mic_test_done(idle) == {idle, []}
  end

  describe "call audio" do
    @ice [%{"urls" => "stun:stun.example:3478"}]
    @start {:call_start, "offerer", @ice, "sine", "null"}
    @offer %{"sdp" => %{"type" => "offer", "sdp" => "v=0"}}
    # The call map from the server's state push.
    @call %{"id" => "call-1", "ice_servers" => @ice}

    defp audio, do: State.new(true, {"sine", "null"})

    # In a call, role and ICE servers known, call_start replied ok.
    defp in_call do
      {state, _} = State.server_state(audio(), :in_call, "offerer", @call)
      {state, []} = State.reply(state, @start, {:ok, %{}})
      state
    end

    test "starts from one state push carrying the role and the call's ICE servers" do
      assert {%{call: %{phase: :starting}}, [{:request, @start}]} =
               State.server_state(audio(), :connecting, "offerer", @call)
    end

    test "starts at the match (connecting), not before, and only once" do
      assert {_, []} = State.server_state(audio(), :looking, nil)
      # A call map without ICE servers (shouldn't happen) starts nothing.
      assert {_, []} = State.server_state(audio(), :connecting, "offerer", %{"id" => "call-1"})
      assert {_, []} = State.server_state(in_call(), :in_call, "offerer", @call)
      assert {_, []} = State.server_state(in_call(), :extension_pending, "offerer", @call)
    end

    test "a signal with no call running is ignored (the server never sends one)" do
      assert State.remote_signal(audio(), "offer", @offer) == {audio(), []}
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
      {starting, _} = State.server_state(audio(), :connecting, "offerer", @call)

      assert {%{call: nil},
              [{:request, :call_stop}, {:push, "end_call", %{reason: "audio_unavailable"}}]} =
               State.reply(starting, @start, {:error, "no mic"})

      assert {%{call: nil},
              [
                {:request, :call_stop},
                {:push, "end_call", %{reason: "audio_failed"}},
                {:request, :devices}
              ]} = State.event(in_call(), "ready", %{})
    end

    test "a call stops a running mic test; the mic test waits during a call" do
      {state, _} = State.start_mic_test(audio(), {"sine", "null"})
      {state, _} = State.reply(state, {:loopback_start, "sine", "null"}, {:ok, %{}})

      assert {%{mic_test: %{phase: :done}}, [{:request, :loopback_stop}, {:request, @start}]} =
               State.server_state(state, :connecting, "offerer", @call)

      assert State.start_mic_test(in_call(), {"sine", "null"}) == {in_call(), []}
    end

    test "stats are kept for display" do
      assert {%{call: %{stats: %{"packets_received" => 9}}}, []} =
               State.event(in_call(), "call_stats", %{"packets_received" => 9})
    end

    test "mute toggles and asks the helper; nothing to do without a call" do
      {muted, [{:request, {:call_mute, true}}]} = State.toggle_mute(in_call())
      assert muted.call.muted

      assert {%{call: %{muted: false}}, [{:request, {:call_mute, false}}]} =
               State.toggle_mute(muted)

      assert State.toggle_mute(State.new(true)) == {State.new(true), []}
    end

    test "meter levels are kept for display, and nothing is sent" do
      levels = %{"you" => [0.5, 0.04], "peer" => [0.2, 0.04]}

      assert {%{call: %{levels: %{you: [0.5, 0.04], peer: [0.2, 0.04]}}}, []} =
               State.event(in_call(), "call_levels", levels)
    end
  end

  describe "devices" do
    @list %{
      "inputs" => ["MacBook Pro Microphone", "Shokz"],
      "outputs" => ["MacBook Pro Speakers"],
      "default_input" => "MacBook Pro Microphone",
      "default_output" => "MacBook Pro Speakers"
    }

    test "the list is kept; choices cycle default, each name, default" do
      {state, []} = State.reply(State.new(true), :devices, {:ok, @list})
      assert state.devices.inputs == ["MacBook Pro Microphone", "Shokz"]

      state = State.cycle_device(state, :input)
      assert state.choice.input == "MacBook Pro Microphone"
      state = state |> State.cycle_device(:input) |> State.cycle_device(:input)
      assert state.choice.input == nil, "back to the system default"
    end

    test "a chosen device is used by the mic test; test endpoints are left alone" do
      {state, []} = State.reply(State.new(true), :devices, {:ok, @list})
      state = state |> State.cycle_device(:input) |> State.cycle_device(:input)

      assert {_, [{:request, {:loopback_start, "device:Shokz", "device"}}]} =
               State.start_mic_test(state, {"device", "device"})

      assert {_, [{:request, {:loopback_start, "sine", "null"}}]} =
               State.start_mic_test(state, {"sine", "null"})
    end

    test "a helper already running when the app started is asked for devices" do
      assert State.helper_started(State.new(true)) == {State.new(true), [{:request, :devices}]}
      assert State.helper_started(State.new(false)) == {State.new(false), []}
    end

    test "nothing to cycle before the list arrives" do
      assert State.cycle_device(State.new(true), :input) == State.new(true)
    end
  end
end
