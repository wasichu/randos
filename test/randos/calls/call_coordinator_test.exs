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

  defp participant(id, pid, speaks_language, listens_language) do
    %Entry{
      id: id,
      pid: pid,
      topic: "test:call:#{id}:#{System.unique_integer([:positive])}",
      speaks_language: speaks_language,
      listens_language: listens_language
    }
  end

  defp match do
    pid_a = waiting_pid()
    pid_b = waiting_pid()
    participant_a = participant("a", pid_a, "en", "es")
    participant_b = participant("b", pid_b, "es", "en")

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

  test "connection failure signal notifies peer and ends call" do
    {match, pids} = match()
    call_pid = start_call(match)

    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :active}}

    assert :ok =
             CallCoordinator.relay_signal(call_pid, "a", "connection_failed", %{
               "reason" => "ice_failed"
             })

    assert_receive {:signaling,
                    %{
                      type: :connection_failed,
                      from_participant_id: "a",
                      to_participant_id: "b",
                      payload: %{"reason" => "ice_failed"}
                    }}

    assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}
    assert_receive {:call_updated, %{status: :ended, ended_reason: :connection_failed}}

    Enum.each(pids, &send(&1, :stop))
  end

  test "participant disconnect ends the call" do
    {match, [pid_a, pid_b]} = match()
    start_call(match)

    assert_receive {:call_updated, %{status: :active}}
    assert_receive {:call_updated, %{status: :active}}

    Process.exit(pid_a, :kill)
    assert_receive {:call_updated, %{status: :ended, ended_reason: :disconnected}}
    assert_receive {:call_updated, %{status: :ended, ended_reason: :disconnected}}

    send(pid_b, :stop)
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
    assert_receive {^ref, [:randos, :call, :start], _, %{call_id: call_id}}
    assert_receive {:call_updated, %{status: :active}}

    :ok = CallCoordinator.hang_up(call_pid, "a")

    assert_receive {^ref, [:randos, :call, :stop], %{duration: duration},
                    %{call_id: ^call_id, reason: :hangup}}

    assert duration > 0
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
