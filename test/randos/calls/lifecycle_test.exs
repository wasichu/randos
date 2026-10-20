defmodule Randos.Calls.LifecycleTest do
  use ExUnit.Case, async: true

  alias Randos.Calls.Call
  alias Randos.Calls.Lifecycle
  alias Randos.Matchmaking.{Entry, Match}

  defp entry(id, audio?) do
    %Entry{
      id: id,
      pid: self(),
      topic: "t:#{id}",
      speaks_language: "en",
      listens_language: "es",
      audio?: audio?
    }
  end

  defp call(attrs \\ [], audio? \\ true) do
    match = Match.new(entry("a", audio?), entry("b", audio?))
    struct!(Call.new(self(), match), attrs)
  end

  test "new calls start connecting with no extensions and a random id" do
    call = call()

    assert call.status == :connecting
    assert call.extension_count == 0
    assert "call-" <> _ = call.id
    refute call.id == call().id
  end

  test "timing adds up to a thirty minute cap" do
    assert Lifecycle.call_duration_seconds() == 600
    assert Lifecycle.extension_duration_seconds() == 600
    assert Lifecycle.max_extension_count() == 2
    assert Lifecycle.max_call_duration_seconds() == 1_800
    assert Lifecycle.extension_response_timeout_seconds() == 20
  end

  test "walks the happy path through two extensions" do
    call = call() |> Lifecycle.activate()
    assert call.status == :active

    call = %{call | call_deadline_unix_ms: 123}
    call = Lifecycle.request_extension(call)
    assert call.status == :extension_pending
    assert call.call_deadline_unix_ms == nil

    assert {:ok, call} = Lifecycle.extend(%{call | extension_deadline_unix_ms: 456})
    assert call.status == :active
    assert call.extension_count == 1
    assert call.extension_deadline_unix_ms == nil

    assert {:ok, call} = call |> Lifecycle.request_extension() |> Lifecycle.extend()
    assert call.extension_count == 2

    assert {:error, :max_extensions} = call |> Lifecycle.request_extension() |> Lifecycle.extend()
  end

  test "any live status can end, with a reason" do
    for status <- [:connecting, :active, :extension_pending] do
      ended = Lifecycle.end_call(call(status: status), :hangup)
      assert ended.status == :ended
      assert ended.ended_reason == :hangup
    end
  end

  test "rejects transitions from the wrong status" do
    assert_raise FunctionClauseError, fn -> Lifecycle.activate(call(status: :active)) end

    assert_raise FunctionClauseError, fn ->
      Lifecycle.request_extension(call(status: :connecting))
    end

    assert_raise FunctionClauseError, fn -> Lifecycle.extend(call(status: :active)) end

    assert_raise FunctionClauseError, fn ->
      Lifecycle.end_call(call(status: :ended), :hangup)
    end
  end

  # Unknown reasons are rejected by end_call/2's guard, and the Elixir type
  # checker flags a literal unknown reason at compile time.
  test "accepts every documented ended reason" do
    for reason <- Lifecycle.ended_reasons() do
      assert %Call{ended_reason: ^reason} = Lifecycle.end_call(call(), reason)
    end
  end

  describe "media" do
    test "a new call has both participants connecting" do
      assert call().media == %{"a" => :connecting, "b" => :connecting}
    end

    test "connected only once both participants report connected" do
      one = Lifecycle.put_media(call(), "a", :connected)
      refute Lifecycle.media_connected?(one)

      both = Lifecycle.put_media(one, "b", :connected)
      assert Lifecycle.media_connected?(both)
      refute Lifecycle.media_connected?(Lifecycle.put_media(both, "b", :disconnected))
    end

    test "a call carries audio only when both clients do" do
      assert Lifecycle.audio?(call())
      refute Lifecycle.audio?(call([], false))
    end

    test "connect timeout and disconnected grace are the decided values" do
      assert Lifecycle.connect_timeout_seconds() == 15
      assert Lifecycle.disconnected_grace_seconds() == 5
    end
  end
end
