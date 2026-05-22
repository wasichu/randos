defmodule Randos.Matchmaking.MatchmakerTest do
  use ExUnit.Case, async: true

  alias Randos.Matchmaking.Matchmaker

  defp start_matchmaker(_) do
    name = :"matchmaker_#{System.unique_integer([:positive])}"
    call_starter = fn _match, _call_options -> {:ok, self()} end
    start_supervised!({Matchmaker, name: name, call_starter: call_starter})
    %{matchmaker: name}
  end

  defp participant(attrs) do
    attrs = Map.new(attrs)
    id = Map.get(attrs, :id, "participant-#{System.unique_integer([:positive])}")

    %{
      id: id,
      pid: Map.fetch!(attrs, :pid),
      topic: "test:matchmaking:#{id}",
      speaks_language: Map.fetch!(attrs, :speaks_language),
      listens_language: Map.fetch!(attrs, :listens_language),
      accepted_adult_terms: Map.get(attrs, :accepted_adult_terms, true)
    }
  end

  defp waiting_pid do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  setup :start_matchmaker

  test "does not leave queued participants behind when call start fails" do
    name = :"matchmaker_failure_#{System.unique_integer([:positive])}"
    call_starter = fn _match, _call_options -> {:error, :supervisor_down} end
    start_supervised!({Matchmaker, name: name, call_starter: call_starter}, id: name)

    pid_a = waiting_pid()
    pid_b = waiting_pid()

    assert :queued =
             Matchmaker.join(
               name,
               participant(id: "a", pid: pid_a, speaks_language: "en", listens_language: "es")
             )

    assert {:error, :call_start_failed} =
             Matchmaker.join(
               name,
               participant(id: "b", pid: pid_b, speaks_language: "es", listens_language: "en")
             )

    assert %{queued_count: 0} = Matchmaker.snapshot(name)

    send(pid_a, :stop)
    send(pid_b, :stop)
  end

  test "matches compatible participants and notifies both topics", %{matchmaker: matchmaker} do
    pid_a = waiting_pid()
    pid_b = waiting_pid()

    participant_a =
      participant(id: "a", pid: pid_a, speaks_language: "en", listens_language: "es")

    participant_b =
      participant(id: "b", pid: pid_b, speaks_language: "es", listens_language: "en")

    Phoenix.PubSub.subscribe(Randos.PubSub, participant_a.topic)
    Phoenix.PubSub.subscribe(Randos.PubSub, participant_b.topic)

    assert :queued = Matchmaker.join(matchmaker, participant_a)
    assert {:matched, match} = Matchmaker.join(matchmaker, participant_b)

    assert match.participant_a.id == "a"
    assert match.participant_b.id == "b"
    assert match.offerer == :participant_a
    assert match.answerer == :participant_b

    assert_receive {:randos_match, ^match}
    assert_receive {:randos_match, ^match}
    assert %{queued_count: 0} = Matchmaker.snapshot(matchmaker)

    send(pid_a, :stop)
    send(pid_b, :stop)
  end

  test "does not match incompatible participants", %{matchmaker: matchmaker} do
    pid_a = waiting_pid()
    pid_b = waiting_pid()

    assert :queued =
             Matchmaker.join(
               matchmaker,
               participant(id: "a", pid: pid_a, speaks_language: "en", listens_language: "es")
             )

    assert :queued =
             Matchmaker.join(
               matchmaker,
               participant(id: "b", pid: pid_b, speaks_language: "fr", listens_language: "en")
             )

    assert %{queued_count: 2} = Matchmaker.snapshot(matchmaker)

    send(pid_a, :stop)
    send(pid_b, :stop)
  end

  test "rejects participants without adult terms acceptance", %{matchmaker: matchmaker} do
    pid = waiting_pid()

    assert {:error, :adult_terms_required} =
             Matchmaker.join(
               matchmaker,
               participant(
                 id: "a",
                 pid: pid,
                 speaks_language: "en",
                 listens_language: "es",
                 accepted_adult_terms: false
               )
             )

    assert %{queued_count: 0} = Matchmaker.snapshot(matchmaker)
    send(pid, :stop)
  end

  test "prevents double queueing", %{matchmaker: matchmaker} do
    pid = waiting_pid()
    participant = participant(id: "a", pid: pid, speaks_language: "en", listens_language: "es")

    assert :queued = Matchmaker.join(matchmaker, participant)
    assert {:error, :already_queued} = Matchmaker.join(matchmaker, participant)
    assert %{queued_count: 1} = Matchmaker.snapshot(matchmaker)

    send(pid, :stop)
  end

  test "leaves the queue", %{matchmaker: matchmaker} do
    pid = waiting_pid()

    assert :queued =
             Matchmaker.join(
               matchmaker,
               participant(id: "a", pid: pid, speaks_language: "en", listens_language: "es")
             )

    assert :ok = Matchmaker.leave(matchmaker, pid)
    assert %{queued_count: 0} = Matchmaker.snapshot(matchmaker)

    send(pid, :stop)
  end

  test "cleans up when a queued participant process disconnects", %{matchmaker: matchmaker} do
    pid = waiting_pid()
    ref = Process.monitor(pid)

    assert :queued =
             Matchmaker.join(
               matchmaker,
               participant(id: "a", pid: pid, speaks_language: "en", listens_language: "es")
             )

    assert %{queued_count: 1} = Matchmaker.snapshot(matchmaker)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    _state = :sys.get_state(matchmaker)

    assert %{queued_count: 0} = Matchmaker.snapshot(matchmaker)
  end

  test "handles concurrent compatible joins without matching a participant twice", %{
    matchmaker: matchmaker
  } do
    participants =
      for index <- 1..20 do
        pid = waiting_pid()
        language_pair = if rem(index, 2) == 0, do: {"es", "en"}, else: {"en", "es"}

        participant(
          id: "participant-#{index}",
          pid: pid,
          speaks_language: elem(language_pair, 0),
          listens_language: elem(language_pair, 1)
        )
      end

    results =
      participants
      |> Task.async_stream(&Matchmaker.join(matchmaker, &1), timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)

    matches =
      for {:matched, match} <- results do
        [match.participant_a.id, match.participant_b.id]
      end

    matched_ids = List.flatten(matches)

    assert length(matches) == 10
    assert Enum.uniq(matched_ids) == matched_ids
    assert %{queued_count: 0} = Matchmaker.snapshot(matchmaker)

    Enum.each(participants, fn participant -> send(participant.pid, :stop) end)
  end
end
