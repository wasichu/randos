defmodule Randos.Comms.CallSessionTest do
  use ExUnit.Case, async: true

  alias Randos.Comms.CallSession

  defp create_connecting_call do
    CallSession
    |> Ash.Changeset.for_create(:create_connecting_call, %{
      speaks_language_a: "en",
      listens_language_a: "es",
      speaks_language_b: "es",
      listens_language_b: "en"
    })
    |> Ash.create()
  end

  test "creates a connecting call with default duration settings" do
    assert {:ok, call} = create_connecting_call()

    assert call.status == :connecting
    assert call.max_duration_seconds == CallSession.default_max_call_duration_seconds()
    assert call.extension_count == 0
    assert is_nil(call.started_at)
    assert is_nil(call.ended_at)
  end

  test "enforces the valid lifecycle transitions" do
    {:ok, call} = create_connecting_call()

    assert {:ok, active_call} =
             call
             |> Ash.Changeset.for_update(:mark_active)
             |> Ash.update()

    assert active_call.status == :active
    assert %DateTime{} = active_call.started_at

    assert {:ok, extension_pending_call} =
             active_call
             |> Ash.Changeset.for_update(:mark_extension_pending)
             |> Ash.update()

    assert extension_pending_call.status == :extension_pending

    assert {:ok, extended_call} =
             extension_pending_call
             |> Ash.Changeset.for_update(:extend_call)
             |> Ash.update()

    assert extended_call.status == :active
    assert extended_call.extension_count == 1

    assert {:ok, ended_call} =
             extended_call
             |> Ash.Changeset.for_update(:end_call, %{ended_reason: :hang_up})
             |> Ash.update()

    assert ended_call.status == :ended
    assert ended_call.ended_reason == :hang_up
    assert %DateTime{} = ended_call.ended_at
  end

  test "allows ending while connecting" do
    {:ok, call} = create_connecting_call()

    assert {:ok, ended_call} =
             call
             |> Ash.Changeset.for_update(:end_call, %{ended_reason: :canceled})
             |> Ash.update()

    assert ended_call.status == :ended
    assert ended_call.ended_reason == :canceled
  end

  test "rejects invalid lifecycle transitions cleanly" do
    {:ok, call} = create_connecting_call()

    assert {:error, _error} =
             call
             |> Ash.Changeset.for_update(:mark_extension_pending)
             |> Ash.update()

    {:ok, ended_call} =
      call
      |> Ash.Changeset.for_update(:end_call, %{ended_reason: :canceled})
      |> Ash.update()

    assert {:error, _error} =
             ended_call
             |> Ash.Changeset.for_update(:mark_active)
             |> Ash.update()
  end

  test "rejects unsupported language codes" do
    assert {:error, _error} =
             CallSession
             |> Ash.Changeset.for_create(:create_connecting_call, %{
               speaks_language_a: "en",
               listens_language_a: "es",
               speaks_language_b: "zz",
               listens_language_b: "en"
             })
             |> Ash.create()
  end
end
