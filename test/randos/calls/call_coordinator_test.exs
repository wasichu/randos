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

    assert_receive {:mock_call_active, %{status: :active, extension_count: 0}}
    assert_receive {:mock_call_active, %{status: :active, extension_count: 0}}

    assert_receive {:mock_call_extension_pending, %{status: :extension_pending}}
    assert_receive {:mock_call_extension_pending, %{status: :extension_pending}}

    Enum.each(pids, &send(&1, :stop))
  end

  test "extends only after both participants vote to continue" do
    {match, pids} = match()
    call_pid = start_call(match, call_duration_ms: 5)

    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_active, %{status: :active}}
    assert_receive {:mock_call_extension_pending, %{status: :extension_pending}}
    assert_receive {:mock_call_extension_pending, %{status: :extension_pending}}

    assert :ok = CallCoordinator.vote_extension(call_pid, "a", :continue)
    refute_receive {:mock_call_extended, _call}, 5

    assert :ok = CallCoordinator.vote_extension(call_pid, "b", :continue)
    assert_receive {:mock_call_extended, %{status: :active, extension_count: 1}}
    assert_receive {:mock_call_extended, %{status: :active, extension_count: 1}}

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
end
