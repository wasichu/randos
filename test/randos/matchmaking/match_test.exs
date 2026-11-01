defmodule Randos.Matchmaking.MatchTest do
  use ExUnit.Case, async: true

  alias Randos.Matchmaking.{Entry, Match}

  defp entry(id) do
    %Entry{
      audio?: true,
      id: id,
      pid: self(),
      topic: "topic:#{id}",
      speaks_language: "en",
      hears_languages: ["es"]
    }
  end

  setup do
    %{match: Match.new(entry("a"), entry("b"))}
  end

  test "multiple speaking choices match by intersections, with stable per-call assignments" do
    a = %{entry("a") | offered_languages: ["es", "en"], hears_languages: ["fr", "de"]}
    b = %{entry("b") | offered_languages: ["fr", "de"], hears_languages: ["es", "en"]}
    assert Entry.compatible?(a, b)
    match = Match.new(a, b)
    assert match.participant_a.speaks_language == "en"
    assert match.participant_b.speaks_language == "de"
    assert Entry.speaks_any(match.participant_a) == ["en"]
    assert Entry.offered_languages(match.participant_a) == ["es", "en"]

    reversed =
      Match.new(%{a | offered_languages: ["en", "es"]}, %{b | offered_languages: ["de", "fr"]})

    assert reversed.participant_a.speaks_language == "en"
    assert reversed.participant_b.speaks_language == "de"
    refute Entry.compatible?(a, %{b | hears_languages: ["ja"]})
    refute Entry.compatible?(a, %{b | offered_languages: ["ja"]})
    refute Entry.compatible?(a, %{b | audio?: false})
  end

  test "new matches get a random id and no call yet", %{match: match} do
    assert "match-" <> _ = match.id
    refute match.id == Match.new(entry("a"), entry("b")).id
    assert match.call_pid == nil
  end

  test "participant A offers and participant B answers", %{match: match} do
    assert Match.webrtc_role(match, "a") == :offerer
    assert Match.webrtc_role(match, "b") == :answerer
    assert Match.webrtc_role(match, "stranger") == nil
  end

  test "membership and peers", %{match: match} do
    assert Match.member?(match, "a") and Match.member?(match, "b")
    refute Match.member?(match, "stranger")

    assert {:ok, %Entry{id: "b"}} = Match.peer(match, "a")
    assert {:ok, %Entry{id: "a"}} = Match.peer(match, "b")
    assert {:error, :unknown_participant} = Match.peer(match, "stranger")
  end
end
