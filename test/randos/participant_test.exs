defmodule Randos.ParticipantTest do
  use ExUnit.Case, async: true

  alias Randos.Calls.Call
  alias Randos.Participant

  @prefs %{speaks: "en", listens: "es", adult_acknowledged?: true}

  defp participant(attrs \\ []), do: struct!(Participant.new(@prefs), attrs)

  defp fake_pid, do: spawn(fn -> :ok end)

  # A match with `p` as participant_a (the offerer) unless told otherwise.
  defp match(p, opts \\ []) do
    me = %{id: p.id, topic: p.topic}
    peer = %{id: "anon-peer", topic: "participant:anon-peer"}
    {a, b} = if opts[:as] == :participant_b, do: {peer, me}, else: {me, peer}

    %{
      id: "match-1",
      participant_a: a,
      participant_b: b,
      offerer: :participant_a,
      answerer: :participant_b,
      call_pid: Keyword.get(opts, :call_pid, fake_pid())
    }
  end

  defp call(match, status, attrs \\ []) do
    struct!(%Call{id: "call-1", pid: match.call_pid, match: match, status: status}, attrs)
  end

  # Drive a fresh participant into a connected call.
  defp in_call(status \\ :active) do
    p = participant(status: :looking)
    m = match(p)
    {p, []} = Participant.handle(p, {:join_result, {:matched, m}})
    {p, []} = Participant.handle(p, {:call_updated, call(m, status)})
    {p, m}
  end

  describe "new/1" do
    test "starts idle with a random anonymous id and its own topic" do
      p = participant()
      assert p.status == :idle
      assert "anon-" <> _ = p.id
      assert p.topic == "participant:" <> p.id
      refute p.id == participant().id
    end
  end

  describe "finding someone" do
    test "find asks the shell to join the queue with the chosen languages" do
      prefs = %{@prefs | speaks: "fr", listens: "de"}
      {p, effects} = Participant.handle(participant(), {:find, prefs})

      assert p.preferences == prefs
      assert [{:join_queue, attrs}] = effects

      assert attrs == %{
               id: p.id,
               topic: p.topic,
               speaks_language: "fr",
               listens_language: "de",
               accepted_adult_terms: true
             }
    end

    test "find without the 18+ acknowledgment is an error and joins nothing" do
      prefs = %{@prefs | adult_acknowledged?: false}
      assert {p, []} = Participant.handle(participant(), {:find, prefs})
      assert p.error == :adult_terms_required
      assert p.status == :idle
    end

    test "find clears a previous error" do
      {p, [_join]} = Participant.handle(participant(error: :call_start_failed), {:find, @prefs})
      assert p.error == nil
    end

    test "find only applies when idle" do
      p = participant(status: :looking)
      assert {^p, []} = Participant.handle(p, {:find, @prefs})
    end

    test "preference updates are stored in any status" do
      prefs = %{@prefs | listens: "ja"}
      {p, []} = Participant.handle(participant(status: :in_call), {:update_preferences, prefs})
      assert p.preferences == prefs
    end
  end

  describe "join results" do
    test ":queued and :already_queued mean looking" do
      for result <- [:queued, {:error, :already_queued}] do
        assert {%{status: :looking}, []} =
                 Participant.handle(participant(), {:join_result, result})
      end
    end

    test "an immediate match goes straight to connecting as the right WebRTC role" do
      p = participant()
      m = match(p)
      {p, []} = Participant.handle(p, {:join_result, {:matched, m}})

      assert p.status == :connecting
      assert p.call_pid == m.call_pid
      assert p.webrtc_role == :offerer

      p2 = participant()
      {p2, []} = Participant.handle(p2, {:join_result, {:matched, match(p2, as: :participant_b)}})
      assert p2.webrtc_role == :answerer
    end

    test "errors return to idle with the reason (including call_start_failed)" do
      for reason <- [:adult_terms_required, :unsupported_language, :call_start_failed] do
        p = participant(status: :looking)
        assert {p, []} = Participant.handle(p, {:join_result, {:error, reason}})
        assert p.status == :idle
        assert p.error == reason
      end
    end
  end

  describe "cancelling a search" do
    test "leaves the queue and goes idle" do
      assert {%{status: :idle}, [:leave_queue]} =
               Participant.handle(participant(status: :looking), :cancel_search)
    end

    test "does nothing unless looking" do
      p = participant()
      assert {^p, []} = Participant.handle(p, :cancel_search)
    end
  end

  describe "call updates" do
    test "the current call moves the participant through its statuses" do
      {p, m} = in_call(:connecting)
      assert p.status == :connecting
      assert p.call.status == :connecting

      {p, []} = Participant.handle(p, {:call_updated, call(m, :active, call_deadline_unix_ms: 1)})
      assert p.status == :in_call
      assert p.call.call_deadline_unix_ms == 1

      {p, []} = Participant.handle(p, {:call_updated, call(m, :extension_pending)})
      assert p.status == :extension_pending

      {p, []} = Participant.handle(p, {:call_updated, call(m, :active, extension_count: 1)})
      assert p.status == :in_call
      assert p.call.extension_count == 1
    end

    test "a waiting participant adopts the call the matchmaker paired them into" do
      p = participant(status: :looking)
      m = match(p, as: :participant_b)
      {p, []} = Participant.handle(p, {:call_updated, call(m, :connecting)})

      assert p.status == :connecting
      assert p.call_pid == m.call_pid
      assert p.webrtc_role == :answerer
    end

    test "an idle participant declines a call they were matched into while cancelling" do
      p = participant()
      m = match(p)

      assert {^p, [{:hang_up, pid}]} =
               Participant.handle(p, {:call_updated, call(m, :connecting)})

      assert pid == m.call_pid
    end

    test "calls that aren't mine are ignored" do
      p = participant(status: :looking)
      other = %{match(participant()) | id: "someone-elses"}
      assert {^p, []} = Participant.handle(p, {:call_updated, call(other, :connecting)})
    end

    test "updates from a stale call are ignored" do
      {p, m} = in_call()
      stale = call(%{m | call_pid: fake_pid()}, :active)
      assert {^p, []} = Participant.handle(p, {:call_updated, stale})
    end

    test "an ended call is never adopted or declined" do
      p = participant()
      assert {^p, []} = Participant.handle(p, {:call_updated, call(match(p), :ended)})
    end
  end

  describe "when the current call ends" do
    test "goes back to looking (and rejoins) by default" do
      {p, m} = in_call()

      {p, effects} =
        Participant.handle(p, {:call_updated, call(m, :ended, ended_reason: :hangup)})

      assert p.status == :looking
      assert p.call_pid == nil and p.call == nil and p.webrtc_role == nil
      assert [{:join_queue, %{id: id}}] = effects
      assert id == p.id
    end

    test "goes idle when the participant chose to stop" do
      {p, m} = in_call()
      {p, [{:hang_up, _}]} = Participant.handle(p, :end_call)
      {p, effects} = Participant.handle(p, {:call_updated, call(m, :ended)})

      assert p.status == :idle
      assert p.stop_after_call? == false
      assert effects == []
    end
  end

  describe "leaving or extending a call" do
    test "end_call and next hang up the current call, differing only in what follows" do
      for status <- [:connecting, :active, :extension_pending] do
        {p, m} = in_call(status)
        pid = m.call_pid

        assert {%{stop_after_call?: true}, [{:hang_up, ^pid}]} =
                 Participant.handle(p, :end_call)

        assert {%{stop_after_call?: false}, [{:hang_up, ^pid}]} = Participant.handle(p, :next)
      end
    end

    test "end_call and next do nothing outside a call" do
      for event <- [:end_call, :next] do
        p = participant(status: :looking)
        assert {^p, []} = Participant.handle(p, event)
      end
    end

    test "votes go to the call while time is up; voting to end means stop afterwards" do
      {p, m} = in_call(:extension_pending)
      pid = m.call_pid

      assert {%{stop_after_call?: false}, [{:vote, ^pid, :continue}]} =
               Participant.handle(p, {:vote, :continue})

      assert {%{stop_after_call?: true}, [{:vote, ^pid, :end}]} =
               Participant.handle(p, {:vote, :end})
    end

    test "votes outside extension_pending are ignored" do
      {p, _m} = in_call(:active)
      assert {^p, []} = Participant.handle(p, {:vote, :continue})
    end
  end

  describe "signaling" do
    test "client signals are relayed to the current call" do
      {p, m} = in_call()
      payload = %{"sdp" => "x"}
      pid = m.call_pid

      assert {^p, [{:relay_signal, ^pid, "offer", ^payload}]} =
               Participant.handle(p, {:client_signal, "offer", payload})
    end

    test "client signals outside a call are dropped" do
      p = participant()
      assert {^p, []} = Participant.handle(p, {:client_signal, "offer", %{}})
    end

    test "peer signals for the current call reach the client without participant ids" do
      {p, _m} = in_call()

      message = %{
        call_id: "call-1",
        type: :offer,
        from_participant_id: "anon-peer",
        to_participant_id: p.id,
        payload: %{"sdp" => "x"},
        sent_at_unix_ms: 1
      }

      assert {^p, [{:push_signal, pushed}]} = Participant.handle(p, {:signaling, message})

      assert pushed == %{
               call_id: "call-1",
               type: "offer",
               payload: %{"sdp" => "x"},
               sent_at_unix_ms: 1
             }
    end

    test "peer signals for any other call are dropped" do
      {p, _m} = in_call()
      message = %{call_id: "call-other", type: :offer, payload: %{}, sent_at_unix_ms: 1}
      assert {^p, []} = Participant.handle(p, {:signaling, message})
    end
  end
end
