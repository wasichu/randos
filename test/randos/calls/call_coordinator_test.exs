defmodule Randos.Calls.CallCoordinatorTest do
  use ExUnit.Case

  alias Randos.Calls.CallCoordinator
  alias Randos.Matchmaking.{Entry, Match}

  defp waiting_pid do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Text-only by default: those calls activate on a short delay, which is
  # what the timer tests need. Media tests pass `audio?: true`.
  defp participant(id, pid, speaks_language, hears_language, audio?) do
    %Entry{
      audio?: audio?,
      id: id,
      pid: pid,
      topic: "test:call:#{id}:#{System.unique_integer([:positive])}",
      speaks_language: speaks_language,
      hears_languages: [hears_language]
    }
  end

  defp match(audio? \\ false) do
    pid_a = waiting_pid()
    pid_b = waiting_pid()
    participant_a = participant("a", pid_a, "en", "es", audio?)
    participant_b = participant("b", pid_b, "es", "en", audio?)

    match = Match.new(participant_a, participant_b)

    Phoenix.PubSub.subscribe(Randos.PubSub, participant_a.topic)
    Phoenix.PubSub.subscribe(Randos.PubSub, participant_b.topic)

    {match, [pid_a, pid_b]}
  end

  defp start_call(match, opts \\ []) do
    start_supervised!(
      {CallCoordinator,
       Keyword.merge(
         [
           match: match,
           activation_delay_ms: 1,
           call_duration_ms: 20,
           extension_duration_ms: 20,
           extension_response_timeout_ms: 20
         ],
         opts
       )}
    )
  end

  test "activates a matched call after a short delay and asks for extension at time limit" do
    {match, pids} = match()
    start_call(match)

    assert_receive {:call_updated,
                    %{status: :active, extension_count: 0, call_deadline_unix_ms: deadline_a}}

    assert_receive {:call_updated,
                    %{status: :active, extension_count: 0, call_deadline_unix_ms: deadline_b}}

    assert is_integer(deadline_a)
    assert deadline_a == deadline_b
    assert deadline_a > System.system_time(:millisecond)

    assert_receive {:call_updated,
                    %{
                      status: :extension_pending,
                      extension_deadline_unix_ms: extension_deadline_a
                    }}

    assert_receive {:call_updated,
                    %{
                      status: :extension_pending,
                      extension_deadline_unix_ms: extension_deadline_b
                    }}

    assert is_integer(extension_deadline_a)
    assert extension_deadline_a == extension_deadline_b
    assert extension_deadline_a > System.system_time(:millisecond)

    Enum.each(pids, &send(&1, :stop))
  end

  test "extends only after both participants vote to continue" do
    {match, pids} = match()
    call_pid = start_call(match, call_duration_ms: 5)

    assert_receive {:call_updated, %{status: :active, call_deadline_unix_ms: first_deadline}}
    assert_receive {:call_updated, %{status: :active, call_deadline_unix_ms: ^first_deadline}}

    assert_receive {:call_updated,
                    %{status: :extension_pending, extension_deadline_unix_ms: extension_deadline}}

    assert_receive {:call_updated,
                    %{status: :extension_pending, extension_deadline_unix_ms: ^extension_deadline}}

    assert :ok = CallCoordinator.vote_extension(call_pid, "a", :continue)
    refute_receive {:call_updated, %{status: :active}}, 5

    assert :ok = CallCoordinator.vote_extension(call_pid, "b", :continue)

    assert_receive {:call_updated,
                    %{
                      status: :active,
                      extension_count: 1,
                      call_deadline_unix_ms: extension_deadline
                    }}

    assert_receive {:call_updated,
                    %{
                      status: :active,
                      extension_count: 1,
                      call_deadline_unix_ms: ^extension_deadline
                    }}

    assert extension_deadline > first_deadline

    Enum.each(pids, &send(&1, :stop))
  end

  test "ends when either participant declines extension" do
    {match, pids} = match()
    call_pid = start_call(match, call_duration_ms: 5)

    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :extension_pending}}
    assert_receive {:call_updated, %{status: :extension_pending}}

    assert :ok = CallCoordinator.vote_extension(call_pid, "a", :end)
    assert_receive {:call_updated, %{status: :ended, ended_reason: :extension_declined}}
    assert_receive {:call_updated, %{status: :ended, ended_reason: :extension_declined}}

    Enum.each(pids, &send(&1, :stop))
  end

  test "ends when extension response grace period expires" do
    {match, pids} = match()
    start_call(match, call_duration_ms: 5, extension_response_timeout_ms: 5)

    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :extension_pending}}
    assert_receive {:call_updated, %{status: :extension_pending}}
    assert_receive {:call_updated, %{status: :ended, ended_reason: :extension_timeout}}
    assert_receive {:call_updated, %{status: :ended, ended_reason: :extension_timeout}}

    Enum.each(pids, &send(&1, :stop))
  end

  test "hangup ends the call for both participants" do
    {match, pids} = match()
    call_pid = start_call(match)

    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :active}}

    assert :ok = CallCoordinator.hang_up(call_pid, "a")
    assert_receive {:call_updated, %{status: :ended, ended_reason: :hangup}}
    assert_receive {:call_updated, %{status: :ended, ended_reason: :hangup}}

    Enum.each(pids, &send(&1, :stop))
  end

  test "duplicate hangup after call process exits is safe" do
    {match, pids} = match()
    call_pid = start_call(match)

    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :active}}

    assert :ok = CallCoordinator.hang_up(call_pid, "a")
    assert_receive {:call_updated, %{status: :ended, ended_reason: :hangup}}
    assert_receive {:call_updated, %{status: :ended, ended_reason: :hangup}}

    assert {:error, :call_unavailable} = CallCoordinator.hang_up(call_pid, "a")

    Enum.each(pids, &send(&1, :stop))
  end

  test "relays future WebRTC signaling messages only to the peer" do
    {match, pids} = match()
    call_pid = start_call(match)

    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :active}}

    assert :ok =
             CallCoordinator.relay_signal(call_pid, "a", "offer", %{
               "sdp" => "mock-offer"
             })

    assert_receive {:signaling,
                    %{
                      type: :offer,
                      from_participant_id: "a",
                      to_participant_id: "b",
                      payload: %{"sdp" => "mock-offer"}
                    }}

    Enum.each(pids, &send(&1, :stop))
  end

  test "a relay-only call never relays a direct address to the peer" do
    {match, pids} = match()
    call_pid = start_call(match, ice_transport_policy: "relay")

    assert_receive {:call_updated, %{status: :active, ice_transport_policy: "relay"}}
    assert_receive {:call_updated, %{status: :active}}

    candidate = fn line -> %{"candidate" => %{"candidate" => line, "sdpMid" => "0"}} end
    host = "candidate:1 1 udp 2122260223 192.168.1.5 54321 typ host"

    relay =
      "candidate:3 1 udp 41885439 203.0.113.9 50000 typ relay raddr 198.51.100.7 rport 61234"

    # Accepted (an older client isn't told), but never relayed.
    assert :ok = CallCoordinator.relay_signal(call_pid, "a", "ice_candidate", candidate.(host))
    assert :ok = CallCoordinator.relay_signal(call_pid, "a", "ice_candidate", candidate.(relay))

    assert_receive {:signaling,
                    %{type: :ice_candidate, payload: %{"candidate" => %{"candidate" => relayed}}}}

    assert relayed ==
             "candidate:3 1 udp 41885439 203.0.113.9 50000 typ relay raddr 0.0.0.0 rport 0"

    refute_received {:signaling, _}

    Enum.each(pids, &send(&1, :stop))
  end

  test "lifecycle signals are acted on, never relayed: failed ends the call" do
    {match, pids} = match()
    call_pid = start_call(match)

    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :active}}

    assert :ok =
             CallCoordinator.relay_signal(call_pid, "a", "media_state", %{"state" => "failed"})

    assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}
    assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}
    refute_received {:signaling, _}

    Enum.each(pids, &send(&1, :stop))
  end

  describe "call health (calls with audio)" do
    defp start_audio_call(opts \\ []) do
      {match, pids} = match(true)

      call_pid =
        start_call(
          match,
          Keyword.merge([connect_timeout_ms: 300, recovery_budget_ms: 100], opts)
        )

      assert_receive {:call_updated, %{status: :connecting}}
      assert_receive {:call_updated, %{status: :connecting}}
      {call_pid, pids}
    end

    defp report(call_pid, id, state),
      do: CallCoordinator.relay_signal(call_pid, id, "media_state", %{"state" => state})

    defp connect_both(call_pid) do
      :ok = report(call_pid, "a", "connected")
      assert_receive {:call_updated, %{status: :connecting, media: %{"a" => :connected}}}
      assert_receive {:call_updated, %{status: :connecting, media: %{"a" => :connected}}}
      :ok = report(call_pid, "b", "connected")
      assert_receive {:call_updated, %{status: :active, call_deadline_unix_ms: deadline}}
      assert_receive {:call_updated, %{status: :active}}
      deadline
    end

    test "stays connecting until both report connected; then the clock starts" do
      {call_pid, pids} = start_audio_call()
      before = System.system_time(:millisecond)
      deadline = connect_both(call_pid)
      # The call clock (20 ms in these tests) starts at connection, not the match.
      assert deadline >= before + 20
      refute_received {:signaling, _}
      Enum.each(pids, &send(&1, :stop))
    end

    test "a call that connected reports its connected length when it ends" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "#{inspect(ref)}",
        [:randos, :call, :stop],
        fn _event, measurements, _metadata, _ -> send(test_pid, {ref, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

      {call_pid, pids} = start_audio_call()
      connect_both(call_pid)
      :ok = CallCoordinator.hang_up(call_pid, "a")

      assert_receive {^ref, %{connected: connected}}
      assert is_integer(connected)
      Enum.each(pids, &send(&1, :stop))
    end

    test "never connecting ends the call after the connect timeout" do
      {call_pid, pids} = start_audio_call()
      ref = Process.monitor(call_pid)
      :ok = report(call_pid, "a", "connected")

      assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}, 5_000
      # So the Matchmaker can tell a failed call from a finished one.
      assert_receive {:DOWN, ^ref, :process, ^call_pid, {:shutdown, :connection_failed}}
      Enum.each(pids, &send(&1, :stop))
    end

    test "a disconnect past the recovery budget ends the call" do
      {call_pid, pids} = start_audio_call(call_duration_ms: 5_000)
      connect_both(call_pid)

      :ok = report(call_pid, "b", "disconnected")
      assert_receive {:call_updated, %{status: :active, media: %{"b" => :disconnected}}}

      assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}, 5_000
      Enum.each(pids, &send(&1, :stop))
    end

    test "reconnecting within the recovery budget keeps the call" do
      {call_pid, pids} = start_audio_call(call_duration_ms: 5_000, recovery_budget_ms: 200)
      connect_both(call_pid)

      :ok = report(call_pid, "b", "disconnected")
      :ok = report(call_pid, "b", "disconnected")
      :ok = report(call_pid, "b", "connected")

      refute_receive {:call_updated, %{status: :ended}}, 400
      Enum.each(pids, &send(&1, :stop))
    end

    test "the older connection_established / connection_failed still count" do
      {call_pid, pids} = start_audio_call()
      :ok = CallCoordinator.relay_signal(call_pid, "a", "connection_established", %{})
      assert_receive {:call_updated, %{media: %{"a" => :connected}}}

      :ok = CallCoordinator.relay_signal(call_pid, "b", "connection_failed", %{"reason" => "x"})
      assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}
      Enum.each(pids, &send(&1, :stop))
    end

    test "a malformed media_state is rejected" do
      {call_pid, pids} = start_audio_call()
      assert {:error, :invalid_media_state} = report(call_pid, "a", "great")

      assert {:error, :invalid_media_state} =
               CallCoordinator.relay_signal(call_pid, "a", "media_state", %{})

      Enum.each(pids, &send(&1, :stop))
    end
  end

  describe "a participant whose connection drops" do
    alias Randos.Calls.ResumeTicket

    # Each participant's ticket, as their topic received it.
    defp tickets(call_pid) do
      for _ <- 1..2, into: %{} do
        assert_receive {:resume_ticket, ^call_pid, ticket}
        {:ok, ^call_pid, id} = ResumeTicket.lookup(ticket)
        {id, ticket}
      end
    end

    # A long call, so only the reconnect grace can end it.
    defp active(match, opts) do
      call_pid = start_call(match, [call_duration_ms: 60_000] ++ opts)
      tickets = tickets(call_pid)
      assert_receive {:call_updated, %{status: :active}}
      assert_receive {:call_updated, %{status: :active}}
      {call_pid, tickets}
    end

    test "is waited for, and the call ends if they don't come back in time" do
      {match, [pid_a, pid_b]} = match()
      {_call_pid, _tickets} = active(match, recovery_budget_ms: 50)

      Process.exit(pid_a, :kill)
      # Not ended: "a" is away, and both hear about it.
      assert_receive {:call_updated, %{status: :active, away: ["a"]}}
      refute_received {:call_updated, %{status: :ended}}

      assert_receive {:call_updated, %{status: :ended, ended_reason: :disconnected}}, 500
      assert_receive {:call_updated, %{status: :ended, ended_reason: :disconnected}}
      send(pid_b, :stop)
    end

    test "comes back with their ticket within the budget: same seat, a fresh ticket" do
      {match, [pid_a, pid_b]} = match()
      {call_pid, %{"a" => ticket}} = active(match, recovery_budget_ms: 200)

      Process.exit(pid_a, :kill)
      assert_receive {:call_updated, %{away: ["a"]}}

      new_pid = waiting_pid()

      assert {:ok, %{call: call, entry: %{id: "a", pid: ^new_pid}, ticket: fresh}} =
               CallCoordinator.resume(call_pid, "a", ticket, new_pid)

      assert call.away == [] and call.status == :active and fresh != ticket
      assert_receive {:call_updated, %{status: :active, away: []}}

      # Past the old grace, the call goes on.
      refute_receive {:call_updated, %{status: :ended}}, 300

      # Each ticket works once; the fresh one is live.
      assert {:error, :invalid_ticket} = CallCoordinator.resume(call_pid, "a", ticket, new_pid)
      assert {:ok, ^call_pid, "a"} = ResumeTicket.lookup(fresh)

      # The new process is the one the call watches now.
      Process.exit(new_pid, :kill)
      assert_receive {:call_updated, %{away: ["a"]}}
      send(pid_b, :stop)
    end

    test "a drop while connecting: after the resume, the repeated report makes the call active" do
      {call_pid, [pid_a, pid_b]} =
        start_audio_call(
          connect_timeout_ms: 400,
          recovery_budget_ms: 300,
          call_duration_ms: 60_000
        )

      %{"b" => ticket} = tickets(call_pid)
      :ok = report(call_pid, "a", "connected")
      assert_receive {:call_updated, %{status: :connecting, media: %{"a" => :connected}}}

      # "b" connected too, but its report was lost in the drop (obligation 9).
      Process.exit(pid_b, :kill)
      assert_receive {:call_updated, %{status: :connecting, away: ["b"]}}

      new_pid = waiting_pid()

      assert {:ok, %{call: %{status: :connecting}}} =
               CallCoordinator.resume(call_pid, "b", ticket, new_pid)

      # A repeat changes nothing; "b"'s report, repeated, makes it active.
      :ok = report(call_pid, "a", "connected")
      :ok = report(call_pid, "b", "connected")
      assert_receive {:call_updated, %{status: :active, away: []}}
      refute_receive {:call_updated, %{status: :ended}}, 500
      Enum.each([pid_a, new_pid], &send(&1, :stop))
    end

    test "a drop while connecting, without the repeated report, ends at the connect timeout" do
      {call_pid, [pid_a, pid_b]} =
        start_audio_call(connect_timeout_ms: 150, recovery_budget_ms: 300)

      %{"b" => ticket} = tickets(call_pid)
      :ok = report(call_pid, "a", "connected")
      Process.exit(pid_b, :kill)
      new_pid = waiting_pid()
      {:ok, _} = CallCoordinator.resume(call_pid, "b", ticket, new_pid)

      assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}, 5_000
      Enum.each([pid_a, new_pid], &send(&1, :stop))
    end

    test "a ticket only opens its own seat, and junk is refused" do
      {match, pids} = match()
      {call_pid, %{"a" => ticket_a}} = active(match, [])

      assert {:error, :invalid_ticket} = CallCoordinator.resume(call_pid, "b", ticket_a, self())
      assert {:error, :invalid_ticket} = CallCoordinator.resume(call_pid, "a", "nope", self())
      assert :error = ResumeTicket.lookup("nope")
      assert :error = ResumeTicket.lookup(String.duplicate("x", 500))
      assert :error = ResumeTicket.lookup(nil)
      Enum.each(pids, &send(&1, :stop))
    end

    test "an old process not yet noticed gone is told it was replaced, and let go" do
      {match, [pid_a, pid_b]} = match()
      observer = self()

      # "a"'s old process: alive, its connection dead but not noticed yet.
      old =
        spawn(fn ->
          receive do
            msg -> send(observer, {:old_got, msg})
          end

          receive do
            :stop -> :ok
          end
        end)

      match = %{match | participant_a: %{match.participant_a | pid: old}}
      {call_pid, %{"a" => ticket}} = active(match, [])

      new_pid = waiting_pid()
      {:ok, _} = CallCoordinator.resume(call_pid, "a", ticket, new_pid)
      assert_receive {:old_got, {:resumed_elsewhere, ^call_pid}}

      # The old process going away now means nothing to the call.
      Process.exit(old, :kill)
      refute_receive {:call_updated, %{away: ["a"]}}, 100
      Enum.each([pid_a, pid_b, new_pid], &send(&1, :stop))
    end

    test "tickets die with the call" do
      {match, pids} = match()
      {call_pid, %{"a" => ticket}} = active(match, [])

      :ok = CallCoordinator.hang_up(call_pid, "a")
      assert_receive {:call_updated, %{status: :ended}}
      refute Process.alive?(call_pid)
      # Refused at once (the call is gone)...
      assert {:error, _} = CallCoordinator.resume(call_pid, "a", ticket, self())
      # ...and the registry forgets it as soon as it notices the call ended.
      assert Enum.any?(1..50, fn _ ->
               Process.sleep(10)
               ResumeTicket.lookup(ticket) == :error
             end)

      Enum.each(pids, &send(&1, :stop))
    end

    test "leaving on purpose still ends the call at once" do
      {match, pids} = match()
      {call_pid, _tickets} = active(match, recovery_budget_ms: 60_000)

      :ok = CallCoordinator.relay_signal(call_pid, "a", "peer_disconnected", %{})
      assert_receive {:call_updated, %{status: :ended, ended_reason: :peer_disconnected}}
      Enum.each(pids, &send(&1, :stop))
    end
  end

  test "extension vote after ended call is safe" do
    {match, pids} = match()
    call_pid = start_call(match, call_duration_ms: 5)

    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :extension_pending}}
    assert_receive {:call_updated, %{status: :extension_pending}}

    assert :ok = CallCoordinator.vote_extension(call_pid, "a", :end)
    assert_receive {:call_updated, %{status: :ended, ended_reason: :extension_declined}}
    assert_receive {:call_updated, %{status: :ended, ended_reason: :extension_declined}}

    assert {:error, :call_unavailable} = CallCoordinator.vote_extension(call_pid, "b", :continue)

    Enum.each(pids, &send(&1, :stop))
  end

  defp start_supervised_call(match) do
    {:ok, call_pid} =
      CallCoordinator.start_match(match,
        activation_delay_ms: 1,
        call_duration_ms: 1_000,
        extension_duration_ms: 1_000,
        extension_response_timeout_ms: 1_000
      )

    assert_receive {:call_updated, %{status: :active, id: call_id}}
    assert_receive {:call_updated, %{status: :active, id: ^call_id}}
    {call_pid, call_id}
  end

  defp flush_call_updates(call_id) do
    receive do
      {:call_updated, %{id: ^call_id}} -> flush_call_updates(call_id)
    after
      0 -> :ok
    end
  end

  test "emits telemetry when a call starts and stops" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      "#{inspect(ref)}",
      [[:randos, :call, :start], [:randos, :call, :stop]],
      fn event, measurements, metadata, _ ->
        send(test_pid, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

    {match, _pids} = match()
    call_pid = start_call(match)
    # The two speaking languages, sorted (for Randos.Stats' aggregate counts).
    assert_receive {^ref, [:randos, :call, :start], _, %{call_id: call_id, languages: languages}}

    assert languages ==
             Enum.sort([match.participant_a.speaks_language, match.participant_b.speaks_language])

    assert_receive {:call_updated, %{status: :active}}

    :ok = CallCoordinator.hang_up(call_pid, "a")

    assert_receive {^ref, [:randos, :call, :stop], %{duration: duration, connected: connected},
                    %{call_id: ^call_id, reason: :hangup}}

    assert duration > 0
    # It was active, so its connected length is known (and shorter).
    assert is_integer(connected) and connected <= duration
  end

  describe "recovery: one budget, whatever goes wrong (and what the clients can do)" do
    # A long, connected call with audio; short timings. `capable`: which
    # clients can restart ICE (obligation 10).
    defp recovering_call(capable \\ {true, true}) do
      {match, [pid_a, pid_b]} = match(true)
      {cap_a, cap_b} = capable

      match = %{
        match
        | participant_a: %{match.participant_a | ice_restart?: cap_a},
          participant_b: %{match.participant_b | ice_restart?: cap_b}
      }

      call_pid =
        start_call(match,
          call_duration_ms: 60_000,
          connect_timeout_ms: 300,
          recovery_budget_ms: 400,
          ice_restart_delay_ms: 50,
          ice_restart_retry_ms: 100
        )

      assert_receive {:call_updated, %{status: :connecting}}
      assert_receive {:call_updated, %{status: :connecting}}
      tickets = tickets(call_pid)
      connect_both(call_pid)
      {call_pid, [pid_a, pid_b], tickets}
    end

    defp go_away(pid, id) do
      Process.exit(pid, :kill)
      assert_receive {:call_updated, %{away: [^id], recovering: true}}
    end

    defp come_back(call_pid, id, ticket) do
      new_pid = waiting_pid()
      {:ok, _} = CallCoordinator.resume(call_pid, id, ticket, new_pid)
      new_pid
    end

    defp stop_all(pids), do: Enum.each(pids, &send(&1, :stop))

    test "a short blip: nothing is asked for, and the call stays healthy" do
      {call_pid, pids, _} = recovering_call()
      :ok = report(call_pid, "b", "disconnected")
      assert_receive {:call_updated, %{recovering: true}}
      :ok = report(call_pid, "b", "connected")
      assert_receive {:call_updated, %{recovering: false, ice_generation: 0}}
      refute_receive {:call_updated, %{ice_generation: 1}}, 150
      refute_receive {:call_updated, %{status: :ended}}, 400
      stop_all(pids)
    end

    test "a network change, both can restart: wait for them, restart at once, recover" do
      {call_pid, [pid_a, pid_b], %{"a" => ticket}} = recovering_call()
      go_away(pid_a, "a")
      :ok = report(call_pid, "b", "disconnected")
      # Nobody to send an offer to: no restart while "a" is away.
      refute_receive {:call_updated, %{ice_generation: 1}}, 150

      new_pid = come_back(call_pid, "a", ticket)
      assert_receive {:call_updated, %{away: [], ice_generation: 1, recovering: true}}, 100

      :ok = report(call_pid, "b", "connected")
      assert_receive {:call_updated, %{recovering: false}}
      refute_receive {:call_updated, %{status: :ended}}, 500
      stop_all([pid_b, new_pid])
    end

    test "a network change with an older client: no restart, and the budget ends it on time" do
      {call_pid, [pid_a, pid_b], %{"a" => ticket}} = recovering_call({true, false})
      started = System.monotonic_time(:millisecond)
      go_away(pid_a, "a")
      :ok = report(call_pid, "b", "disconnected")
      new_pid = come_back(call_pid, "a", ticket)

      # Back, but the media never is: one deadline from the first trouble.
      assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}, 600
      assert System.monotonic_time(:millisecond) - started < 550
      refute_received {:call_updated, %{ice_generation: 1}}
      stop_all([pid_b, new_pid])
    end

    test "someone gone for good: the call ends at the budget, as disconnected" do
      {_call_pid, [pid_a, pid_b], _} = recovering_call()
      go_away(pid_a, "a")
      refute_receive {:call_updated, %{status: :ended}}, 300
      assert_receive {:call_updated, %{status: :ended, ended_reason: :disconnected}}, 300
      send(pid_b, :stop)
    end

    test "the relay dead, both still here: restarts until the budget, then connection_failed" do
      {call_pid, pids, _} = recovering_call()
      :ok = report(call_pid, "b", "disconnected")
      assert_receive {:call_updated, %{ice_generation: 1}}, 200
      assert_receive {:call_updated, %{ice_generation: 2}}, 200
      assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}, 400
      stop_all(pids)
    end

    test "failed, with restart: restart at once (no delay), and recover" do
      {call_pid, pids, _} = recovering_call()
      :ok = report(call_pid, "a", "failed")
      assert_receive {:call_updated, %{ice_generation: 1, recovering: true}}, 30
      :ok = report(call_pid, "a", "connected")
      assert_receive {:call_updated, %{recovering: false}}
      refute_receive {:call_updated, %{status: :ended}}, 500
      stop_all(pids)
    end

    test "failed, without restart: nothing can fix it, so the call ends at once" do
      {call_pid, pids, _} = recovering_call({false, true})
      :ok = report(call_pid, "a", "failed")
      assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}, 100
      stop_all(pids)
    end

    test "only the connection to the server dropped, media still flowing: back, and healthy" do
      {call_pid, [pid_a, pid_b], %{"a" => ticket}} = recovering_call()
      go_away(pid_a, "a")
      new_pid = come_back(call_pid, "a", ticket)
      assert_receive {:call_updated, %{away: [], recovering: false, ice_generation: 0}}
      refute_receive {:call_updated, %{status: :ended}}, 500
      stop_all([pid_b, new_pid])
    end

    test "a call without audio isn't unhealthy for media it never has" do
      {match, pids} = match(false)
      start_call(match, call_duration_ms: 60_000, recovery_budget_ms: 100)
      assert_receive {:call_updated, %{status: :active, recovering: false}}, 5_000
      refute_receive {:call_updated, %{status: :ended}}, 300
      stop_all(pids)
    end
  end

  describe "lifecycle under the call supervisor" do
    test "is not restarted after the call ends" do
      {match, _pids} = match()
      {call_pid, call_id} = start_supervised_call(match)
      ref = Process.monitor(call_pid)

      assert :ok = CallCoordinator.hang_up(call_pid, "a")
      assert_receive {:DOWN, ^ref, :process, ^call_pid, :normal}

      # Drain this call's own updates; a restarted (ghost) call would send
      # updates under a new id.
      flush_call_updates(call_id)
      refute_receive {:call_updated, _}, 100

      refute Enum.any?(
               DynamicSupervisor.which_children(Randos.Calls.CallSupervisor),
               fn {_, pid, _, _} -> pid == call_pid end
             )
    end
  end
end
