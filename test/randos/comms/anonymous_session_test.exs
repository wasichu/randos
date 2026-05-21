defmodule Randos.Comms.AnonymousSessionTest do
  use ExUnit.Case

  alias Randos.Comms.AnonymousSession

  describe "create_session" do
    test "creates a transient anonymous session with language preferences" do
      assert {:ok, session} =
               AnonymousSession
               |> Ash.Changeset.for_create(:create_session, %{
                 speaks_language: "en",
                 listens_language: "es"
               })
               |> Ash.create()

      assert session.speaks_language == "en"
      assert session.listens_language == "es"
      assert session.auto_requeue == false
      assert session.accepted_adult_terms == false
      refute AnonymousSession.matchmaking_ready?(session)
    end

    test "rejects unsupported language codes" do
      assert {:error, _error} =
               AnonymousSession
               |> Ash.Changeset.for_create(:create_session, %{
                 speaks_language: "xx",
                 listens_language: "es"
               })
               |> Ash.create()
    end
  end

  describe "accept_adult_terms" do
    test "marks an anonymous session ready for matchmaking later" do
      {:ok, session} =
        AnonymousSession
        |> Ash.Changeset.for_create(:create_session, %{
          speaks_language: "en",
          listens_language: "es"
        })
        |> Ash.create()

      assert {:ok, accepted_session} =
               session
               |> Ash.Changeset.for_update(:accept_adult_terms)
               |> Ash.update()

      assert accepted_session.accepted_adult_terms == true
      assert AnonymousSession.matchmaking_ready?(accepted_session)
    end
  end
end
