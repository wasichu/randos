defmodule Tui.AppTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event
  alias ExRatatui.Runtime
  alias Tui.App
  alias Tui.Media.State, as: MediaState
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

  defp render_text(model, extra \\ %{}) do
    state =
      Map.merge(
        %{
          model: model,
          uri: "ws://localhost:4000/participant/websocket",
          media_state: MediaState.new(false)
        },
        extra
      )

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

    test "the mic test hint, progress, result, and failure" do
      refute render_text(model("idle")) =~ "t mic test"

      with_media = fn mic_test ->
        render_text(model("idle"), %{
          media_state: %MediaState{available?: true, mic_test: mic_test}
        })
      end

      assert with_media.(nil) =~ "Press t to test your mic"
      assert with_media.(nil) =~ "t mic test"

      assert with_media.(%{phase: :starting, stats: nil, error: nil}) =~
               "you should hear yourself"

      stats = %{"latency_ms" => 81.2, "input_peak_dbfs" => -40.4}

      assert with_media.(%{phase: :done, stats: stats, error: nil}) =~
               "Mic test done: ≈81 ms delay, input peak -40 dBFS"

      assert with_media.(%{phase: :failed, stats: nil, error: "no mic"}) =~
               "Mic test failed: no mic"
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

  test "the running app turns keys into protocol pushes and ends calls offering audio" do
    pid =
      start_supervised!(
        {App, name: nil, test_mode: {100, 24}, connection: self(), test_pid: self()}
      )

    send(pid, {:randos, {:joined, %{"state" => server_state("idle"), "languages" => @languages}}})
    assert_receive {:tui_model, ^pid, %Model{status: :idle}}

    for code <- [" ", "enter"], do: key(pid, code)

    assert_receive {:"$gen_cast",
                    {:push, "find",
                     %{speaks: "en", listens: "es", adult_acknowledged: true, audio: false}}}

    send(pid, {:randos, {:push, "state", server_state("in_call")}})
    assert_receive {:tui_model, ^pid, %Model{status: :in_call}}

    send(pid, {:randos, {:push, "signal", %{"type" => "offer", "call_id" => "call-1"}}})

    assert_receive {:"$gen_cast", {:push, "end_call", %{}}}

    key(pid, "n")
    assert_receive {:"$gen_cast", {:push, "next", %{}}}

    ref = Process.monitor(pid)
    key(pid, "q")
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  describe "mic test (t)" do
    defp idle_app(media, opts \\ []) do
      app =
        start_supervised!(
          {App,
           [name: nil, test_mode: {100, 24}, connection: self(), test_pid: self(), media: media] ++
             opts}
        )

      send(
        app,
        {:randos, {:joined, %{"state" => server_state("idle"), "languages" => @languages}}}
      )

      assert_receive {:tui_model, ^app, %Model{status: :idle}}
      app
    end

    @tag :native
    @tag :capture_log
    test "runs a loopback through Tui.Media and shows its stats" do
      app = idle_app(:app_test_media, mic_test: {"sine", "null"})
      start_supervised!({Tui.Media, name: :app_test_media, notify: app})

      key(app, "t")
      assert_receive {:tui_media, ^app, %{mic_test: %{phase: :starting}}}
      assert_receive {:tui_media, ^app, %{mic_test: %{phase: :running, stats: nil}}}

      assert_receive {:tui_media, ^app,
                      %{mic_test: %{phase: :running, stats: %{"codec_ms" => 26.5}}}},
                     2_000

      # The helper dying mid-test is reported, not left showing "running".
      media = Process.whereis(:app_test_media)
      {:os_pid, os_pid} = Port.info(:sys.get_state(media).port, :os_pid)
      System.cmd("kill", ["-9", Integer.to_string(os_pid)])

      assert_receive {:tui_media, ^app,
                      %{mic_test: %{phase: :failed, error: "the audio helper restarted"}}},
                     2_000
    end

    test "without a media helper it explains instead of crashing" do
      app = idle_app(nil)
      key(app, "t")

      assert_receive {:tui_media, ^app,
                      %{mic_test: %{phase: :failed, error: "no audio helper" <> _}}}
    end

    test "with the helper down it explains instead of crashing" do
      app = idle_app(:no_such_media)
      key(app, "t")

      assert_receive {:tui_media, ^app,
                      %{mic_test: %{phase: :failed, error: "the audio helper isn't running" <> _}}}
    end
  end
end
