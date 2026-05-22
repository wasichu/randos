defmodule Randos.Calls.CallCoordinatorTest do
  use ExUnit.Case

  alias Randos.Calls.CallCoordinator

  defp waiting_pid do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp participant(id, pid, speaks_language, listens_language) do
    %{
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

    match = %{
      id: "match-#{System.unique_integer([:positive])}",
      participant_a: participant_a,
      participant_b: participant_b,
      offerer: :participant_a,
      answerer: :participant_b
    }

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

    assert_receive {:mock_call_active,
                    %{status: :active, extension_count: 0, call_deadline_unix_ms: deadline_a}}

    assert_receive {:mock_call_active,
                    %{status: :active, extension_count: 0, call_deadline_unix_ms: deadline_b}}

    assert is_integer(deadline_a)
    assert deadline_a == deadline_b
    assert deadline_a > System.system_time(:millisecond)

    assert_receive {:mock_call_extension_pending,
                    %{
                      status: :extension_pending,
                      extension_deadline_unix_ms: extension_deadline_a
                    }}

    assert_receive {:mock_call_extension_pending,
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

    assert_receive {:mock_call_active, %{status: :active, call_deadline_unix_ms: first_deadline}}
    assert_receive {:mock_call_active, %{status: :active, call_deadline_unix_ms: ^first_deadline}}

    assert_receive {:mock_call_extension_pending,
                    %{status: :extension_pending, extension_deadline_unix_ms: extension_deadline}}

    assert_receive {:mock_call_extension_pending,
                    %{status: :extension_pending, extension_deadline_unix_ms: ^extension_deadline}}

    assert :ok = CallCoordinator.vote_extension(call_pid, "a", :continue)
    refute_receive {:mock_call_extended, _call}, 5

    assert :ok = CallCoordinator.vote_extension(call_pid, "b", :continue)

    assert_receive {:mock_call_extended,
                    %{
                      status: :active,
                      extension_count: 1,
                      call_deadline_unix_ms: extension_deadline
                    }}

    assert_receive {:mock_call_extended,
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

    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_extension_pending, %{status: :extension_pending}}
    assert_receive {:mock_call_extension_pending, %{status: :extension_pending}}

    assert :ok = CallCoordinator.vote_extension(call_pid, "a", :end)
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :extension_declined}}
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :extension_declined}}

    Enum.each(pids, &send(&1, :stop))
  end

  test "ends when extension response grace period expires" do
    {match, pids} = match()
    start_call(match, call_duration_ms: 5, extension_response_timeout_ms: 5)

    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_extension_pending, %{status: :extension_pending}}
    assert_receive {:mock_call_extension_pending, %{status: :extension_pending}}
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :extension_timeout}}
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :extension_timeout}}

    Enum.each(pids, &send(&1, :stop))
  end

  test "hangup ends the call for both participants" do
    {match, pids} = match()
    call_pid = start_call(match)

    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_active, %{status: :active}}

    assert :ok = CallCoordinator.hang_up(call_pid, "a")
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :hangup}}
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :hangup}}

    Enum.each(pids, &send(&1, :stop))
  end

  test "duplicate hangup after call process exits is safe" do
    {match, pids} = match()
    call_pid = start_call(match)

    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_active, %{status: :active}}

    assert :ok = CallCoordinator.hang_up(call_pid, "a")
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :hangup}}
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :hangup}}

    assert {:error, :call_unavailable} = CallCoordinator.hang_up(call_pid, "a")

    Enum.each(pids, &send(&1, :stop))
  end

  test "relays future WebRTC signaling messages only to the peer" do
    {match, pids} = match()
    call_pid = start_call(match)

    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_active, %{status: :active}}

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

    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_active, %{status: :active}}

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

    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :connection_failed}}
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :connection_failed}}

    Enum.each(pids, &send(&1, :stop))
  end

  test "participant disconnect ends the call" do
    {match, [pid_a, pid_b]} = match()
    start_call(match)

    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_active, %{status: :active}}

    Process.exit(pid_a, :kill)
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :disconnected}}
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :disconnected}}

    send(pid_b, :stop)
  end

  test "extension vote after ended call is safe" do
    {match, pids} = match()
    call_pid = start_call(match, call_duration_ms: 5)

    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_extension_pending, %{status: :extension_pending}}
    assert_receive {:mock_call_extension_pending, %{status: :extension_pending}}

    assert :ok = CallCoordinator.vote_extension(call_pid, "a", :end)
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :extension_declined}}
    assert_receive {:mock_call_ended, %{status: :ended, ended_reason: :extension_declined}}

    assert {:error, :call_unavailable} = CallCoordinator.vote_extension(call_pid, "b", :continue)

    Enum.each(pids, &send(&1, :stop))
  end
end
