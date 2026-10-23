defmodule Tui.Media.StateTest do
  use ExUnit.Case, async: true

  alias Tui.Media.State

  @endpoints {"device", "device"}
  # Silent: whatever the endpoints say, nothing is played back.
  @start {:loopback_start, "device", "null"}

  defp running do
    {state, _} = State.toggle_mic_test(State.new(true), @endpoints)
    {state, _} = State.reply(state, @start, {:ok, %{}})
    state
  end

  test "t opens the mic, silently, and keeps it open until pressed again" do
    {state, commands} = State.toggle_mic_test(State.new(true), @endpoints)
    assert %{phase: :starting, levels: nil} = state.mic_test
    assert commands == [{:request, @start}]

    # No timer: it stays on.
    {state, commands} = State.reply(state, @start, {:ok, %{"input" => "mic"}})
    assert %{phase: :running, stats: nil} = state.mic_test
    assert commands == []

    assert State.toggle_mic_test(state, @endpoints) ==
             {%{state | mic_test: nil}, [{:request, :loopback_stop}]}
  end

  test "the meter's bars and the stats are kept while it runs; late ones after a stop are ignored" do
    {state, []} = State.event(running(), "loopback_levels", %{"you" => [0.5, 0.1]})
    {state, []} = State.event(state, "loopback_stats", %{"input_peak_dbfs" => -12.0})
    assert %{levels: [0.5, 0.1], stats: %{"input_peak_dbfs" => -12.0}} = state.mic_test

    {stopped, _} = State.toggle_mic_test(state, @endpoints)
    assert State.event(stopped, "loopback_levels", %{"you" => [0.9]}) == {stopped, []}
    assert State.event(stopped, "loopback_stats", %{}) == {stopped, []}
  end

  test "pressing t while it's still starting stops it (the helper takes requests in order)" do
    {starting, _} = State.toggle_mic_test(State.new(true), @endpoints)

    assert {%{mic_test: nil}, [{:request, :loopback_stop}]} =
             State.toggle_mic_test(starting, @endpoints)
  end

  test "failures: no helper, a refused start, a failed loopback, a restarted helper" do
    {state, []} = State.toggle_mic_test(State.new(false), @endpoints)
    assert %{phase: :failed, error: "no audio helper" <> _} = state.mic_test

    {starting, _} = State.toggle_mic_test(State.new(true), @endpoints)
    {state, []} = State.reply(starting, @start, {:error, "no 48 kHz config"})
    assert %{phase: :failed, error: "no 48 kHz config"} = state.mic_test

    {state, []} = State.event(running(), "loopback_failed", %{"error" => "device gone"})
    assert %{phase: :failed, error: "device gone"} = state.mic_test

    {state, [{:request, :devices}]} = State.event(starting, "ready", %{})
    assert %{phase: :failed, error: "the audio helper restarted"} = state.mic_test
  end

  test "t on a failure hides it; t again retries" do
    {starting, _} = State.toggle_mic_test(State.new(true), @endpoints)
    {failed, []} = State.reply(starting, @start, {:error, "x"})

    {hidden, []} = State.toggle_mic_test(failed, @endpoints)
    assert hidden.mic_test == nil

    assert {%{mic_test: %{phase: :starting}}, [{:request, @start}]} =
             State.toggle_mic_test(hidden, @endpoints)
  end

  test "events and replies with no test in progress change nothing" do
    idle = State.new(true)
    # A fresh helper: ask what devices there are.
    assert State.event(idle, "ready", %{}) == {idle, [{:request, :devices}]}
    # With test endpoints (a tone, no output), there are no devices to choose.
    test_tone = State.new(true, {"sine", "null"})
    assert State.event(test_tone, "ready", %{}) == {test_tone, []}
    assert State.helper_started(test_tone) == {test_tone, []}
    assert State.event(idle, "loopback_stats", %{}) == {idle, []}
    assert State.event(idle, "loopback_levels", %{"you" => [0.1]}) == {idle, []}
    assert State.reply(idle, :loopback_stop, {:ok, true}) == {idle, []}
  end

  describe "call audio" do
    @ice [%{"urls" => "stun:stun.example:3478"}]
    @start {:call_start, "offerer", @ice, "sine", "null", false}
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

    test "a relay-only call (the server's ice_transport_policy) starts relay-only" do
      call = Map.put(@call, "ice_transport_policy", "relay")

      assert {_, [{:request, {:call_start, "offerer", @ice, "sine", "null", true}}]} =
               State.server_state(audio(), :connecting, "offerer", call)

      # Anything else (or nothing: an older server) allows direct calls.
      for policy <- ["all", nil] do
        call = Map.put(@call, "ice_transport_policy", policy)

        assert {_, [{:request, {:call_start, _, _, _, _, false}}]} =
                 State.server_state(audio(), :connecting, "offerer", call)
      end
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

    test "back in the call after a dropped connection, the last report again (obligation 9)" do
      # Nothing reported yet (still connecting), or no call: nothing to repeat.
      assert State.resumed(in_call()) == {in_call(), []}
      assert State.resumed(audio()) == {audio(), []}

      {state, _} = State.event(in_call(), "call_state", %{"state" => "connected"})

      assert State.resumed(state) ==
               {state, [{:push, "signal", %{type: "media_state", payload: %{state: :connected}}}]}
    end

    test "a session that stopped mid-call ends it with a reason (no restart can help)" do
      assert {%{call: nil, last_call_error: "audio_failed"},
              [{:request, :call_stop}, {:push, "end_call", %{reason: "audio_failed"}}]} =
               State.event(in_call(), "call_state", %{
                 "state" => "failed",
                 "reason" => "ice timeout"
               })
    end

    test "out of reach past the call's offline limit: the helper's call stops (obligation 11)" do
      {state, _} =
        State.server_state(
          in_call(),
          :in_call,
          "offerer",
          Map.put(@call, "offline_limit_seconds", 17)
        )

      assert {offline, [{:after, 17_000, {:offline_limit, drop}}]} = State.offline(state)
      assert {%{call: nil}, [{:request, :call_stop}]} = State.offline_limit(offline, drop)
    end

    test "a reconnect inside the limit keeps the call, and an old drop's limit can't end a later one" do
      {state, _} =
        State.server_state(
          in_call(),
          :in_call,
          "offerer",
          Map.put(@call, "offline_limit_seconds", 17)
        )

      {offline, [{:after, _, {:offline_limit, first}}]} = State.offline(state)
      {back, []} = State.online(offline)
      assert {%{call: %{}}, []} = State.offline_limit(back, first)

      {again, [{:after, _, {:offline_limit, second}}]} = State.offline(back)
      assert {%{call: %{}}, []} = State.offline_limit(again, first)
      assert {%{call: nil}, _} = State.offline_limit(again, second)
    end

    test "no call, or a server that sent no limit: nothing to time" do
      assert {_, []} = State.offline(audio())
      assert {_, []} = State.offline(in_call())
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
                {:push, "end_call", %{reason: "audio_failed"}}
              ]} = State.event(in_call(), "ready", %{})
    end

    test "a call stops a running mic test; the mic test waits during a call" do
      {state, _} = State.toggle_mic_test(audio(), {"sine", "null"})
      {state, _} = State.reply(state, {:loopback_start, "sine", "null"}, {:ok, %{}})

      assert {%{mic_test: nil}, [{:request, :loopback_stop}, {:request, @start}]} =
               State.server_state(state, :connecting, "offerer", @call)

      assert State.toggle_mic_test(in_call(), {"sine", "null"}) == {in_call(), []}
    end

    test "obligation 10: the offerer restarts when the server's ice_generation grows, once each" do
      gen = fn n -> Map.put(@call, "ice_generation", n) end
      restart = [{:request, {:call_restart, @ice}}]

      # The generation the call started with is acted on already.
      {state, []} = State.server_state(in_call(), :in_call, "offerer", gen.(0))

      {state, commands} = State.server_state(state, :in_call, "offerer", gen.(1))
      assert commands == restart
      assert state.call.generation == 1

      # The same generation again (any later state push): nothing.
      assert {_, []} = State.server_state(state, :in_call, "offerer", gen.(1))
      # A resume reply with a generation asked for while we were away.
      assert {_, ^restart} = State.server_state(state, :extension_pending, "offerer", gen.(3))
    end

    test "the answerer only notes the generation: its helper re-gathers on the restart offer" do
      {state, _} = State.server_state(audio(), :in_call, "answerer", @call)

      {state, []} =
        State.reply(state, {:call_start, "answerer", @ice, "sine", "null", false}, {:ok, %{}})

      assert {%{call: %{generation: 2}}, []} =
               State.server_state(
                 state,
                 :in_call,
                 "answerer",
                 Map.put(@call, "ice_generation", 2)
               )
    end

    test "a call that starts at a later generation doesn't restart for it" do
      call = Map.put(@call, "ice_generation", 4)

      {state, [{:request, {:call_start, _, _, _, _, _}}]} =
        State.server_state(audio(), :connecting, "offerer", call)

      assert state.call.generation == 4
      assert {_, []} = State.server_state(state, :in_call, "offerer", call)
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

      assert {_, [{:request, {:loopback_start, "device:Shokz", "null"}}]} =
               State.toggle_mic_test(state, {"device", "device"})

      assert {_, [{:request, {:loopback_start, "sine", "null"}}]} =
               State.toggle_mic_test(state, {"sine", "null"})
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
