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
      listens_language: "es"
    }
  end

  setup do
    %{match: Match.new(entry("a"), entry("b"))}
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
