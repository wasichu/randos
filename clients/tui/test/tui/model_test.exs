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
    assert Model.language_name(model, model.speaks) == "English (EN)"
    # The speaking language starts checked among the hearing ones.
    assert model.hears == ["en"]
    assert model.log == ["connected to the server"]
  end

  test "after a dropped connection: back in the call, or a fresh participant" do
    call = %{"id" => "call-1", "status" => "active"}
    in_call = %{joined("in_call") | call: call}
    {dropped, []} = Model.disconnected(in_call)
    assert dropped.connection == :connecting

    # Resumed: the same participant, still in the call, said so in the log.
    reply = %{"state" => state("in_call", %{"call" => call}), "languages" => @languages}
    {back, []} = Model.joined(dropped, Map.put(reply, "resumed", true))
    assert {back.connection, back.status, back.call} == {:connected, :in_call, call}
    assert hd(back.log) == "reconnected; back in the call"
    # No "status changed" line: it never left the call.
    refute "in call" in Enum.take(back.log, 1)

    # Refused (the call ended meanwhile): a fresh participant.
    {fresh, []} =
      Model.joined(dropped, %{
        "state" => state("idle"),
        "languages" => @languages,
        "resumed" => false
      })

    assert {fresh.status, hd(fresh.log)} == {:idle, "reconnected as a new participant"}
  end

  test "keys are ignored until connected" do
    assert {%Model{}, []} = Model.key(Model.new(), "enter")
  end

  test "the idle form picks a speaking language, hearing languages, 18+, and finds" do
    {model, commands} =
      keys(joined(), [
        # Speak Spanish: the hearing languages stay as they were (English,
        # checked at the start).
        "right",
        # The hearing row: also check French.
        "tab",
        "right",
        "right",
        " ",
        # 18+, then find.
        "tab",
        " ",
        "enter"
      ])

    assert commands == [
             {:push, "find",
              %{
                speaks: "es",
                hears: ["en", "fr"],
                adult_acknowledged: true,
                audio: false,
                ice_restart: false
              }}
           ]

    assert model.adult_acknowledged?
  end

  test "the speaking language starts checked; changing it leaves the hearing languages alone" do
    assert {joined().speaks, joined().hears} == {"en", ["en"]}

    {model, []} = keys(joined(), ["right", "right"])
    assert {model.speaks, model.hears} == {"fr", ["en"]}

    # Choices made by hand stay too, even unchecking everything.
    {model, []} = keys(joined(), ["tab", "right", " ", "up", "right"])
    assert {model.speaks, model.hears} == {"es", ["en", "es"]}
    {model, []} = keys(model, ["tab", "left", " ", "right", " ", "up", "right"])
    assert {model.speaks, model.hears} == {"fr", []}
  end

  test "with nothing to hear, Enter says so instead of finding" do
    {model, commands} = keys(joined(), ["tab", " ", "enter"])
    assert model.hears == []
    assert commands == []
    assert [line | _] = model.log
    assert line =~ "at least one language"
  end

  test "settings restore the form; codes the server doesn't offer are dropped" do
    saved = %{"speaks" => "fr", "hears" => ["es", "xx"], "adult_acknowledged" => true}
    model = Model.restore(Model.new(), saved)

    {model, []} =
      Model.joined(model, %{"state" => state("idle"), "languages" => @languages})

    assert {model.speaks, model.hears, model.adult_acknowledged?} == {"fr", ["es"], true}

    assert Model.saved(model) == %{
             "speaks" => "fr",
             "hears" => ["es"],
             "adult_acknowledged" => true
           }

    # Nothing usable: the defaults.
    model = Model.restore(Model.new(), %{"speaks" => 7, "hears" => "en"})
    assert {model.speaks, model.hears, model.adult_acknowledged?} == {"en", ["en"], false}
  end

  test "the call map says which language the rando speaks" do
    model = joined("in_call")
    assert Model.peer_speaks(model) == nil

    {model, []} =
      Model.push(model, "state", state("in_call", %{"call" => %{"peer_speaks" => "fr"}}))

    assert Model.peer_speaks(model) == "fr"
    assert Model.language_name(model, "fr") == "Français (FR)"
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

  describe "the status screen" do
    @snapshot %{"relay" => %{"state" => "ok", "transports" => []}, "usage" => %{}}

    test "s on the idle screen opens it and asks the server; s or esc goes back" do
      {model, [{:push, "status", %{}}]} = Model.key(joined(), "s")
      assert %{snapshot: nil, unavailable?: false} = model.status_page

      {model, []} = Model.reply(model, "status", {:ok, @snapshot})
      assert model.status_page.snapshot == @snapshot

      for back <- ["s", "esc"], do: assert({%{status_page: nil}, []} = Model.key(model, back))
    end

    test "while it's open, the form's keys do nothing and r asks again" do
      {model, _ask} = Model.key(joined(), "s")
      assert {^model, []} = keys(model, ["enter", " ", "right", "tab"])
      assert {_model, [{:push, "status", %{}}]} = Model.key(model, "r")
    end

    test "it asks again every 30 s while open, never when closed" do
      {model, _ask} = Model.key(Model.tick(joined(), 1_000), "s")
      assert {_model, []} = Model.refresh_status(Model.tick(model, 30_999))
      assert {model, [{:push, "status", %{}}]} = Model.refresh_status(Model.tick(model, 31_000))
      assert model.status_page.asked_ms == 31_000

      assert {_model, []} = Model.refresh_status(Model.tick(joined(), 99_000))
    end

    test "a server from before the request: the screen says so; a late reply after closing is ignored" do
      {model, _ask} = Model.key(joined(), "s")
      {model, []} = Model.reply(model, "status", {:error, %{"reason" => "invalid_message"}})
      assert model.status_page.unavailable?
      # Not logged as a refusal: the screen already says it.
      refute Enum.any?(model.log, &(&1 =~ "status refused"))

      {closed, []} = Model.key(model, "esc")
      assert {^closed, []} = Model.reply(closed, "status", {:ok, @snapshot})
    end
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
