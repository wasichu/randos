defmodule Tui.ModelTest do
  use ExUnit.Case, async: true

  alias Tui.Model

  @languages [
    %{"code" => "en", "name" => "English (EN)"},
    %{"code" => "es", "name" => "Español (ES)"},
    %{"code" => "fr", "name" => "Français (FR)"}
  ]

  defp state(status, extra \\ %{}) do
    Map.merge(%{"status" => status, "webrtc_role" => nil, "error" => nil, "call" => nil}, extra)
  end

  defp joined(status \\ "idle") do
    {model, []} =
      Model.joined(Model.new(), %{"state" => state(status), "languages" => @languages})

    model
  end

  defp keys(model, keys) do
    Enum.reduce(keys, {model, []}, fn key, {model, commands} ->
      {model, more} = Model.key(model, key)
      {model, commands ++ more}
    end)
  end

  test "the join reply gives the status and the server's languages" do
    model = joined()

    assert model.connection == :connected
    assert model.status == :idle
    assert Model.language_name(model, :speaks) == "English (EN)"
    assert Model.language_name(model, :listens) == "Español (ES)"
    assert model.log == ["connected to the server"]
  end

  test "keys are ignored until connected" do
    assert {%Model{}, []} = Model.key(Model.new(), "enter")
  end

  test "the idle form picks languages, toggles 18+, and finds" do
    {model, commands} = keys(joined(), ["right", "tab", "right", "right", "tab", " ", "enter"])

    assert commands == [
             {:push, "find",
              %{speaks: "es", listens: "en", adult_acknowledged: true, audio: false}}
           ]

    assert model.adult_acknowledged?
  end

  test "status-specific keys map to protocol events" do
    assert {_, [{:push, "cancel_search", %{}}]} = Model.key(joined("looking"), "c")
    assert {_, [{:push, "end_call", %{}}]} = Model.key(joined("in_call"), "e")
    assert {_, [{:push, "next", %{}}]} = Model.key(joined("connecting"), "n")

    assert {_, [{:push, "vote", %{vote: "continue"}}]} =
             Model.key(joined("extension_pending"), "y")

    assert {_, [{:push, "vote", %{vote: "end"}}]} = Model.key(joined("extension_pending"), "n")
    assert {_, []} = Model.key(joined("looking"), "enter")
  end

  test "state pushes update the status and log changes and errors" do
    model = joined()
    {model, []} = Model.push(model, "state", state("looking"))
    {model, []} = Model.push(model, "state", state("idle", %{"error" => "unsupported_language"}))

    assert model.status == :idle
    assert model.error == "unsupported_language"

    assert ["error: unsupported_language", "looking for a rando", "connected to the server"] =
             model.log
  end

  test "errors show the server's words when it sends them" do
    {model, []} =
      Model.push(joined("in_call"), "state", %{
        "status" => "idle",
        "error" => "microphone_denied",
        "error_message" => "The call ended because microphone access was blocked."
      })

    assert model.error == "The call ended because microphone access was blocked."
    assert hd(model.log) =~ "microphone access was blocked"
  end

  test "an unknown status from a newer server keeps the current one" do
    {model, []} = Model.push(joined("looking"), "state", state("teleporting"))
    assert model.status == :looking
  end

  test "with audio, an offer is left to the media layer and find says audio: true" do
    model = Model.set_audio(joined("in_call"), true)
    offer = %{"type" => "offer", "call_id" => "call-1", "payload" => %{}}
    assert {^model, []} = Model.push(model, "signal", offer)

    idle = Model.set_audio(joined("idle"), true)
    {idle, []} = Model.key(idle, " ")
    assert {_, [{:push, "find", %{audio: true}}]} = Model.key(idle, "enter")
  end

  test "a peer's offer ends the call with end_call, so only the peer is requeued" do
    offer = %{"type" => "offer", "call_id" => "call-1", "payload" => %{}}
    {model, commands} = Model.push(joined("in_call"), "signal", offer)

    assert commands == [{:push, "end_call", %{reason: "audio_unavailable"}}]
    assert hd(model.log) =~ "peer offered audio"

    assert {_, []} =
             Model.push(model, "signal", %{"type" => "ice_candidate", "call_id" => "call-1"})
  end

  test "a reconnect is logged as a new participant" do
    {model, []} = Model.disconnected(joined("in_call"))
    assert model.connection == :connecting

    {model, []} = Model.joined(model, %{"state" => state("idle"), "languages" => @languages})
    assert model.status == :idle
    assert hd(model.log) == "reconnected as a new participant"
  end

  test "error replies are logged" do
    {model, []} = Model.reply(joined(), "find", {:error, %{"reason" => "rate_limited"}})
    assert hd(model.log) == "find refused: rate_limited"
  end

  test "seconds left follows the segment, then the vote deadline" do
    model = Model.tick(joined(), 10_000)

    {model, []} =
      Model.push(
        model,
        "state",
        state("in_call", %{"call" => %{"status" => "active", "call_deadline_unix_ms" => 70_500}})
      )

    assert Model.seconds_left(model) == 61

    {model, []} =
      Model.push(
        model,
        "state",
        state("extension_pending", %{
          "call" => %{
            "status" => "extension_pending",
            "call_deadline_unix_ms" => nil,
            "extension_deadline_unix_ms" => 25_000
          }
        })
      )

    assert Model.seconds_left(model) == 15
    assert Model.seconds_left(joined()) == nil
  end
end
