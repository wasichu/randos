defmodule Tui.AppTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event
  alias ExRatatui.Runtime
  alias Tui.App
  alias Tui.Model

  @languages [
    %{"code" => "en", "name" => "English (EN)"},
    %{"code" => "es", "name" => "Español (ES)"}
  ]

  defp server_state(status, extra \\ %{}) do
    Map.merge(%{"status" => status, "webrtc_role" => nil, "error" => nil, "call" => nil}, extra)
  end

  defp model(status, extra \\ %{}) do
    {model, []} =
      Model.joined(Model.new(1_000), %{
        "state" => server_state(status, extra),
        "languages" => @languages
      })

    model
  end

  defp render_text(model) do
    state = %{model: model, uri: "ws://localhost:4000/participant/websocket"}
    terminal = ExRatatui.init_test_terminal(100, 24)
    :ok = ExRatatui.draw(terminal, App.render(state, %ExRatatui.Frame{width: 100, height: 24}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp key(pid, code), do: Runtime.inject_event(pid, %Event.Key{code: code, kind: "press"})

  describe "screens" do
    test "connecting" do
      text = render_text(Model.new())
      assert text =~ "Connecting to the server"
      assert text =~ "no audio yet"
    end

    test "idle form shows languages, the 18+ box, and key help" do
      text = render_text(model("idle"))
      assert text =~ "I will speak:"
      assert text =~ "English (EN)"
      assert text =~ "Español (ES)"
      assert text =~ "[ ] I'm 18+"
      assert text =~ "enter find"
    end

    test "looking, matched, in call with a countdown, and the vote" do
      assert render_text(model("looking")) =~ "Looking for a rando"
      assert render_text(model("connecting")) =~ "Matched!"

      in_call =
        model("in_call", %{"call" => %{"status" => "active", "call_deadline_unix_ms" => 91_000}})

      assert render_text(in_call) =~ "1:30 remaining"

      vote =
        model("extension_pending", %{
          "call" => %{"status" => "extension_pending", "extension_deadline_unix_ms" => 21_000}
        })

      text = render_text(vote)
      assert text =~ "Continue for another 10 minutes?"
      assert text =~ "0:20 to decide"
    end
  end

  test "the running app turns keys into protocol pushes and refuses audio" do
    pid =
      start_supervised!(
        {App, name: nil, test_mode: {100, 24}, connection: self(), test_pid: self()}
      )

    send(pid, {:randos, {:joined, %{"state" => server_state("idle"), "languages" => @languages}}})
    assert_receive {:tui_model, %Model{status: :idle}}

    for code <- [" ", "enter"], do: key(pid, code)

    assert_receive {:"$gen_cast",
                    {:push, "find", %{speaks: "en", listens: "es", adult_acknowledged: true}}}

    send(pid, {:randos, {:push, "state", server_state("in_call")}})
    assert_receive {:tui_model, %Model{status: :in_call}}

    send(pid, {:randos, {:push, "signal", %{"type" => "offer", "call_id" => "call-1"}}})

    assert_receive {:"$gen_cast",
                    {:push, "signal",
                     %{type: "connection_failed", payload: %{reason: "audio_unsupported"}}}}

    key(pid, "e")
    assert_receive {:"$gen_cast", {:push, "end_call", %{}}}

    ref = Process.monitor(pid)
    key(pid, "q")
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end
end
