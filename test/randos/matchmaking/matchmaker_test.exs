defmodule Randos.Matchmaking.MatchmakerTest do
  use ExUnit.Case, async: true

  alias Randos.Matchmaking.Match
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
      hears_languages: Map.fetch!(attrs, :hears_languages),
      accepted_adult_terms: Map.get(attrs, :accepted_adult_terms, true),
      audio?: Map.get(attrs, :audio?, true)
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

  test "keeps the waiting participant queued when call start fails" do
    name = :"matchmaker_failure_#{System.unique_integer([:positive])}"
    call_starter = fn _match, _call_options -> {:error, :supervisor_down} end
    start_supervised!({Matchmaker, name: name, call_starter: call_starter}, id: name)

    pid_a = waiting_pid()
    pid_b = waiting_pid()

    assert :queued =
             Matchmaker.join(
               name,
               participant(id: "a", pid: pid_a, speaks_language: "en", hears_languages: ["es"])
             )

    assert {:error, :call_start_failed} =
             Matchmaker.join(
               name,
               participant(id: "b", pid: pid_b, speaks_language: "es", hears_languages: ["en"])
             )

    # The joiner gets the error; the person who was already waiting keeps
    # their place at the front of the queue instead of silently vanishing.
    assert %{queued_count: 1, queues: %{{"en", ["es"], true} => ["a"]}} =
             Matchmaker.snapshot(name)

    send(pid_a, :stop)
    send(pid_b, :stop)
  end

  test "matches compatible participants and starts their call", %{matchmaker: matchmaker} do
    pid_a = waiting_pid()
    pid_b = waiting_pid()

    participant_a =
      participant(id: "a", pid: pid_a, speaks_language: "en", hears_languages: ["es"])

    participant_b =
      participant(id: "b", pid: pid_b, speaks_language: "es", hears_languages: ["en"])

    assert :queued = Matchmaker.join(matchmaker, participant_a)
    assert {:matched, match} = Matchmaker.join(matchmaker, participant_b)

    assert match.participant_a.id == "a"
    assert match.participant_b.id == "b"
    assert Match.webrtc_role(match, "a") == :offerer
    assert Match.webrtc_role(match, "b") == :answerer
    assert is_pid(match.call_pid)

    assert %{queued_count: 0} = Matchmaker.snapshot(matchmaker)

    send(pid_a, :stop)
    send(pid_b, :stop)
  end

  test "emits telemetry for each join with its result", %{matchmaker: matchmaker} do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "#{inspect(ref)}",
      [:randos, :matchmaking, :join],
      fn _event, measurements, metadata, _ -> send(test_pid, {ref, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

    pid = waiting_pid()

    Matchmaker.join(
      matchmaker,
      participant(pid: pid, speaks_language: "en", hears_languages: ["es"])
    )

    assert_receive {^ref, %{queue_size: 1}, %{result: :queued}}

    Matchmaker.join(
      matchmaker,
      participant(pid: waiting_pid(), speaks_language: "es", hears_languages: ["en"])
    )

    assert_receive {^ref, %{queue_size: 0}, %{result: :matched}}
  end

  test "does not match incompatible participants", %{matchmaker: matchmaker} do
    pid_a = waiting_pid()
    pid_b = waiting_pid()

    assert :queued =
             Matchmaker.join(
               matchmaker,
               participant(id: "a", pid: pid_a, speaks_language: "en", hears_languages: ["es"])
             )

    assert :queued =
             Matchmaker.join(
               matchmaker,
               participant(id: "b", pid: pid_b, speaks_language: "fr", hears_languages: ["en"])
             )

    assert %{queued_count: 2} = Matchmaker.snapshot(matchmaker)

    send(pid_a, :stop)
    send(pid_b, :stop)
  end

  test "only matches clients that agree on carrying audio", %{matchmaker: matchmaker} do
    join = fn id, speaks, listens, audio? ->
      Matchmaker.join(
        matchmaker,
        participant(
          id: id,
          pid: waiting_pid(),
          speaks_language: speaks,
          hears_languages: List.wrap(listens),
          audio?: audio?
        )
      )
    end

    assert :queued = join.("text-only", "en", "es", false)
    # Same languages, but this one has audio: no silent call with the text-only client.
    assert :queued = join.("browser", "es", "en", true)

    assert %{
             queues: %{
               {"en", ["es"], false} => ["text-only"],
               {"es", ["en"], true} => ["browser"]
             }
           } =
             Matchmaker.snapshot(matchmaker)

    assert {:matched, %Match{}} = join.("another-browser", "en", "es", true)
    assert {:matched, %Match{}} = join.("another-text-only", "es", "en", false)
    assert %{queued_count: 0} = Matchmaker.snapshot(matchmaker)
  end

  test "a join without audio? counts as no audio", %{matchmaker: matchmaker} do
    attrs =
      participant(
        id: "old-client",
        pid: waiting_pid(),
        speaks_language: "en",
        hears_languages: ["es"]
      )

    assert :queued = Matchmaker.join(matchmaker, Map.delete(attrs, :audio?))
    assert %{queues: %{{"en", ["es"], false} => ["old-client"]}} = Matchmaker.snapshot(matchmaker)
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
                 hears_languages: ["es"],
                 accepted_adult_terms: false
               )
             )

    assert %{queued_count: 0} = Matchmaker.snapshot(matchmaker)
    send(pid, :stop)
  end

  test "prevents double queueing", %{matchmaker: matchmaker} do
    pid = waiting_pid()
    participant = participant(id: "a", pid: pid, speaks_language: "en", hears_languages: ["es"])

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
               participant(id: "a", pid: pid, speaks_language: "en", hears_languages: ["es"])
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
               participant(id: "a", pid: pid, speaks_language: "en", hears_languages: ["es"])
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
          hears_languages: [elem(language_pair, 1)]
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

  describe "several hearing languages" do
    defp join(matchmaker, id, speaks, hears) do
      Matchmaker.join(
        matchmaker,
        participant(id: id, pid: waiting_pid(), speaks_language: speaks, hears_languages: hears)
      )
    end

    test "matches crosstalk and the same language both ways", %{matchmaker: matchmaker} do
      # Crosstalk: each speaks what the other hears.
      assert :queued = join(matchmaker, "a", "es", ["en", "fr"])
      assert {:matched, %Match{participant_a: %{id: "a"}}} = join(matchmaker, "b", "en", ["es"])

      # The same language both ways.
      assert :queued = join(matchmaker, "c", "ja", ["ja"])

      assert {:matched, %Match{participant_a: %{id: "c"}}} =
               join(matchmaker, "d", "ja", ["ja", "ko"])
    end

    test "never one-sided: both must hear what the other speaks", %{matchmaker: matchmaker} do
      assert :queued = join(matchmaker, "a", "es", ["en"])
      # b hears Spanish, but a doesn't hear German.
      assert :queued = join(matchmaker, "b", "de", ["es"])
      assert %{waiting: ["a", "b"]} = Matchmaker.snapshot(matchmaker)
    end

    test "the compatible person who has waited longest is matched", %{matchmaker: matchmaker} do
      assert :queued = join(matchmaker, "incompatible", "de", ["de"])
      assert :queued = join(matchmaker, "oldest", "es", ["en"])
      assert :queued = join(matchmaker, "newer", "fr", ["en"])

      # Hears Spanish and French: both fit; the one waiting longer wins.
      assert {:matched, %Match{participant_a: %{id: "oldest"}}} =
               join(matchmaker, "joiner", "en", ["es", "fr"])

      assert %{waiting: ["incompatible", "newer"]} = Matchmaker.snapshot(matchmaker)
    end

    test "nothing to hear, or an unsupported language, is refused", %{matchmaker: matchmaker} do
      assert {:error, :unsupported_language} = join(matchmaker, "a", "en", [])
      assert {:error, :unsupported_language} = join(matchmaker, "b", "en", ["es", "xx"])
      assert {:error, :unsupported_language} = join(matchmaker, "c", "xx", ["en"])
      assert %{queued_count: 0} = Matchmaker.snapshot(matchmaker)
    end
  end

  describe "not rematching the same two people" do
    # A matchmaker whose calls are processes the test controls, with a short
    # rematch window.
    defp start_with_calls(window_ms) do
      name = :"matchmaker_rematch_#{System.unique_integer([:positive])}"
      test = self()

      call_starter = fn match, _options ->
        call =
          spawn(fn ->
            receive do
              :end_call -> :ok
            end
          end)

        send(test, {:call, match, call})
        {:ok, call}
      end

      start_supervised!(
        {Matchmaker, name: name, call_starter: call_starter, rematch_window_ms: window_ms},
        id: name
      )

      name
    end

    defp person(id), do: %{id: id, pid: waiting_pid()}

    defp join_as(matchmaker, %{id: id, pid: pid}, speaks, hears) do
      Matchmaker.join(
        matchmaker,
        participant(id: id, pid: pid, speaks_language: speaks, hears_languages: hears)
      )
    end

    defp end_call(call) do
      ref = Process.monitor(call)
      send(call, :end_call)
      assert_receive {:DOWN, ^ref, _, _, _}
    end

    test "a pair isn't matched again until the window after their call has passed" do
      matchmaker = start_with_calls(200)
      {a, b, c} = {person("a"), person("b"), person("c")}

      assert :queued = join_as(matchmaker, a, "en", ["es"])
      assert {:matched, _} = join_as(matchmaker, b, "es", ["en"])
      assert_receive {:call, _match, call}

      # Requeued before the matchmaker even hears the call ended: still apart.
      assert :queued = join_as(matchmaker, a, "en", ["es"])
      assert :queued = join_as(matchmaker, b, "es", ["en"])
      end_call(call)

      # Someone new is matched straight away; "a" waited longest.
      assert {:matched, %Match{participant_a: %{id: "a"}}} = join_as(matchmaker, c, "es", ["en"])
      assert_receive {:call, _match, _call}
      assert %{waiting: ["b"]} = Matchmaker.snapshot(matchmaker)
    end

    test "when the window closes and both still wait, they're matched" do
      matchmaker = start_with_calls(100)
      {a, b} = {person("a"), person("b")}

      assert :queued = join_as(matchmaker, a, "en", ["es"])
      assert {:matched, _} = join_as(matchmaker, b, "es", ["en"])
      assert_receive {:call, _match, call}
      end_call(call)

      assert :queued = join_as(matchmaker, a, "en", ["es"])
      assert :queued = join_as(matchmaker, b, "es", ["en"])
      refute_receive {:call, _match, _call}, 50

      # The one who waited longer offers.
      assert_receive {:call, %Match{participant_a: %{id: "a"}, participant_b: %{id: "b"}}, _call},
                     1_000

      assert %{queued_count: 0} = Matchmaker.snapshot(matchmaker)
    end
  end
end
